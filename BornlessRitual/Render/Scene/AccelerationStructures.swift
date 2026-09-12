//
//  AccelerationStructures.swift
//  Bornless Ritual — ray-tracing acceleration structures (RENDER_CONTRACT §5 "RT scene":
//  one primitive AS per mesh, static meshes built once, the sorcerer refit each tick, one
//  instance AS rebuilt every frame, `useResources` on all primitive AS; RT.h invariants:
//  instance descriptor i ↔ InstanceData[i], primitive AS built from the shared vertex
//  buffer with the region's GeometryRange and the 64-byte `Vertex` stride).
//
//  Role: builds `MTLPrimitiveAccelerationStructureDescriptor`s from the `MeshRegion`
//  registry of `SceneResources` (vertex buffer + slot offset, stride, `.float3`, index
//  buffer + byte offset, `.uint32`, triangle count), allocates the structures and scratch
//  buffers from `device.accelerationStructureSizes(descriptor:)`, encodes the initial
//  builds on an `MTLAccelerationStructureCommandEncoder`, refits the dynamic (sorcerer)
//  regions from the current vertex slot every frame (`.refit` usage — Metal's name for the
//  "allow update" option), converts `InstanceData.model` into packed 3×4 instance
//  transforms and rebuilds the per-slot instance AS. Publishes the results into
//  `SceneResources.primitiveAS` / `instanceAS` for the tracing passes.
//
//  Index invariant: primitive AS `k` is the AS of `scene.meshRegions[k]`, so an instance
//  whose `geometryIndex` belongs to region `k` uses `accelerationStructureIndex = k`.
//  Instances whose material carries MATERIAL_FLAG_NO_SHADOW keep their slot (mask 0, so
//  no ray ever hits them) rather than being dropped, which preserves `instance_id ==
//  InstanceData index` for `reconstructHit`.
//
//  In-flight safety: the instance AS, its scratch buffer and the refit scratch are
//  triple-buffered per slot; the primitive AS objects are refit in place (GPU work on a
//  single queue executes in order, and the CPU never touches them).
//

import Foundation
import Metal
import simd

/// Errors raised while creating acceleration structures.
enum AccelerationStructureError: Error, CustomStringConvertible {
    /// `MTLDevice.makeAccelerationStructure(size:)` returned nil.
    case structureCreationFailed(String)
    /// A scratch buffer could not be allocated.
    case scratchCreationFailed(String)
    /// `MTLCommandBuffer.makeAccelerationStructureCommandEncoder()` returned nil.
    case encoderCreationFailed
    /// The device reports no ray-tracing support.
    case unsupportedDevice

    var description: String {
        switch self {
        case .structureCreationFailed(let what): return "Could not create acceleration structure '\(what)'"
        case .scratchCreationFailed(let what): return "Could not create AS scratch buffer '\(what)'"
        case .encoderCreationFailed: return "Could not create an acceleration-structure command encoder"
        case .unsupportedDevice: return "The device does not support ray tracing"
        }
    }
}

/// Owns the primitive and instance acceleration structures of the scene.
final class AccelerationStructures {

    // MARK: State

    /// Device the structures belong to.
    let device: MTLDevice
    /// Primitive AS per mesh region (index = position in `SceneResources.meshRegions`).
    private(set) var primitiveStructures: [MTLAccelerationStructure] = []
    /// Per region: one descriptor per vertex slot (static regions have one).
    private var primitiveDescriptors: [[MTLPrimitiveAccelerationStructureDescriptor]] = []
    /// Regions that are refit every frame (dynamic meshes).
    private var dynamicRegionIndices: [Int] = []
    /// Refit scratch per in-flight slot (sized for the largest dynamic region).
    private var refitScratch: [MTLBuffer] = []
    /// Instance AS per in-flight slot.
    private var instanceStructures: [MTLAccelerationStructure] = []
    /// Instance build scratch per in-flight slot.
    private var instanceScratch: [MTLBuffer] = []
    /// Instance descriptor reused for every rebuild (count and offset patched per frame).
    private let instanceDescriptor = MTLInstanceAccelerationStructureDescriptor()
    /// Instances the per-slot instance AS were sized for.
    private(set) var instanceCapacity = 0
    /// True once `buildPrimitives` encoded the initial builds.
    private(set) var isBuilt = false

    /// Resources the tracing encoders must `useResource` (every primitive AS).
    var useResources: [MTLResource] { primitiveStructures.map { $0 as MTLResource } }

    /// Creates the manager; nothing is allocated until `buildPrimitives`.
    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Primitive structures

    /// Allocates one primitive AS per registered mesh region and encodes their initial
    /// builds (slot 0 vertices) on `commandBuffer`. Also allocates the per-slot instance
    /// AS sized for `scene.capacities.maxInstances`. Call once after `SceneBuilder.build`.
    ///
    /// - Throws: `AccelerationStructureError` when a Metal object cannot be created.
    func buildPrimitives(scene: SceneResources, commandBuffer: MTLCommandBuffer) throws {
        guard device.supportsRaytracing else { throw AccelerationStructureError.unsupportedDevice }
        guard !isBuilt else { return }

        var structures: [MTLAccelerationStructure] = []
        var descriptors: [[MTLPrimitiveAccelerationStructureDescriptor]] = []
        var dynamics: [Int] = []
        var maxBuildScratch = 0
        var maxRefitScratch = 0

        for (regionIndex, region) in scene.meshRegions.enumerated() {
            var slotDescriptors: [MTLPrimitiveAccelerationStructureDescriptor] = []
            for slot in 0..<region.slotCount {
                slotDescriptors.append(AccelerationStructures.makePrimitiveDescriptor(region: region, slot: slot, scene: scene))
            }
            // Invariant: `slotCount ≥ 1` (MeshRegion is only created by registerMesh).
            let sizes = device.accelerationStructureSizes(descriptor: slotDescriptors[0])
            guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize) else {
                throw AccelerationStructureError.structureCreationFailed(region.name)
            }
            structure.label = "PrimitiveAS \(region.name)"
            structures.append(structure)
            descriptors.append(slotDescriptors)
            maxBuildScratch = max(maxBuildScratch, sizes.buildScratchBufferSize)
            if region.isDynamic {
                dynamics.append(regionIndex)
                maxRefitScratch = max(maxRefitScratch, sizes.refitScratchBufferSize)
            }
        }

        // Instance AS per slot, sized for the instance capacity.
        let capacity = max(scene.capacities.maxInstances, 1)
        instanceDescriptor.instancedAccelerationStructures = structures
        instanceDescriptor.instanceCount = capacity
        instanceDescriptor.instanceDescriptorBuffer = scene.buffer(for: .instanceDescriptors)
        instanceDescriptor.instanceDescriptorBufferOffset = 0
        instanceDescriptor.instanceDescriptorStride = MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride
        instanceDescriptor.instanceDescriptorType = .default
        let instanceSizes = device.accelerationStructureSizes(descriptor: instanceDescriptor)

        var instanceAS: [MTLAccelerationStructure] = []
        var instanceScratchBuffers: [MTLBuffer] = []
        var refitBuffers: [MTLBuffer] = []
        for slot in 0..<SceneResources.inflightSlots {
            guard let structure = device.makeAccelerationStructure(size: instanceSizes.accelerationStructureSize) else {
                throw AccelerationStructureError.structureCreationFailed("instances slot \(slot)")
            }
            structure.label = "InstanceAS slot \(slot)"
            instanceAS.append(structure)
            instanceScratchBuffers.append(try makeScratch("InstanceAS scratch \(slot)", length: instanceSizes.buildScratchBufferSize))
            refitBuffers.append(try makeScratch("Refit scratch \(slot)", length: maxRefitScratch))
        }
        let buildScratch = try makeScratch("PrimitiveAS build scratch", length: maxBuildScratch)

        // Initial builds (slot 0 vertices for every region).
        guard let encoder = commandBuffer.makeAccelerationStructureCommandEncoder() else {
            throw AccelerationStructureError.encoderCreationFailed
        }
        encoder.label = "Build primitive AS"
        for (regionIndex, structure) in structures.enumerated() {
            encoder.build(accelerationStructure: structure,
                          descriptor: descriptors[regionIndex][0],
                          scratchBuffer: buildScratch,
                          scratchBufferOffset: 0)
        }
        encoder.endEncoding()

        primitiveStructures = structures
        primitiveDescriptors = descriptors
        dynamicRegionIndices = dynamics
        instanceStructures = instanceAS
        instanceScratch = instanceScratchBuffers
        refitScratch = refitBuffers
        instanceCapacity = capacity
        isBuilt = true
        scene.primitiveAS = structures
    }

    // MARK: - Per-frame

    /// Refits every dynamic region's AS from the current slot's vertices (after
    /// `SceneResources.rewriteVertices` for this frame).
    func refitDynamic(scene: SceneResources, commandBuffer: MTLCommandBuffer) {
        guard isBuilt, !dynamicRegionIndices.isEmpty else { return }
        let slot = scene.slot % SceneResources.inflightSlots
        guard slot < refitScratch.count, let encoder = commandBuffer.makeAccelerationStructureCommandEncoder() else { return }
        encoder.label = "Refit dynamic AS (slot \(slot))"
        for regionIndex in dynamicRegionIndices {
            guard regionIndex < primitiveStructures.count, regionIndex < primitiveDescriptors.count else { continue }
            let slotDescriptors = primitiveDescriptors[regionIndex]
            let descriptor = slotDescriptors[min(slot, slotDescriptors.count - 1)]
            let structure = primitiveStructures[regionIndex]
            encoder.refit(sourceAccelerationStructure: structure,
                          descriptor: descriptor,
                          destinationAccelerationStructure: structure,
                          scratchBuffer: refitScratch[slot],
                          scratchBufferOffset: 0)
        }
        encoder.endEncoding()
    }

    /// Writes the instance descriptors for `instances` into the scene's current slot and
    /// encodes the instance AS rebuild; publishes it as `scene.instanceAS`.
    ///
    /// - Parameters:
    ///   - instances: This frame's `InstanceData` (same order as written to BufferIndexInstances).
    ///   - noShadowMaterials: Material indices carrying MATERIAL_FLAG_NO_SHADOW (masked out).
    ///   - scene: The scene buffers (current slot).
    ///   - commandBuffer: Frame command buffer.
    func rebuildInstances(instances: [InstanceData], noShadowMaterials: Set<UInt32>,
                          scene: SceneResources, commandBuffer: MTLCommandBuffer) {
        guard isBuilt else {
            scene.instanceAS = nil
            return
        }
        let slot = scene.slot % SceneResources.inflightSlots
        guard slot < instanceStructures.count, slot < instanceScratch.count else {
            scene.instanceAS = nil
            return
        }
        let regionByGeometry = geometryToRegionMap(scene: scene)
        var descriptors: [MTLAccelerationStructureInstanceDescriptor] = []
        descriptors.reserveCapacity(min(instances.count, instanceCapacity))
        for instance in instances.prefix(instanceCapacity) {
            var descriptor = MTLAccelerationStructureInstanceDescriptor()
            descriptor.transformationMatrix = AccelerationStructures.packedTransform(instance.model)
            descriptor.options = [.opaque, .triangleFrontFacingWindingCounterClockwise]
            let regionIndex = regionByGeometry[Int(instance.geometryIndex)] ?? 0
            descriptor.accelerationStructureIndex = UInt32(regionIndex)
            descriptor.intersectionFunctionTableOffset = 0
            let hidden = noShadowMaterials.contains(instance.materialIndex) || regionByGeometry[Int(instance.geometryIndex)] == nil
            descriptor.mask = hidden ? 0 : 0xFF
            descriptors.append(descriptor)
        }
        guard !descriptors.isEmpty else {
            scene.instanceAS = nil
            return
        }
        let written = scene.writeInstanceDescriptors(descriptors)

        instanceDescriptor.instanceCount = written
        instanceDescriptor.instanceDescriptorBuffer = scene.buffer(for: .instanceDescriptors)
        instanceDescriptor.instanceDescriptorBufferOffset = scene.offset(for: .instanceDescriptors)
        instanceDescriptor.instancedAccelerationStructures = primitiveStructures

        guard let encoder = commandBuffer.makeAccelerationStructureCommandEncoder() else {
            scene.instanceAS = nil
            return
        }
        encoder.label = "Build instance AS (slot \(slot))"
        encoder.build(accelerationStructure: instanceStructures[slot],
                      descriptor: instanceDescriptor,
                      scratchBuffer: instanceScratch[slot],
                      scratchBufferOffset: 0)
        encoder.endEncoding()
        scene.instanceAS = instanceStructures[slot]
        scene.primitiveAS = primitiveStructures
    }

    // MARK: - Helpers

    /// Triangle geometry descriptor of `region`'s vertex slot in the shared buffers.
    static func makePrimitiveDescriptor(region: MeshRegion, slot: Int, scene: SceneResources) -> MTLPrimitiveAccelerationStructureDescriptor {
        let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer = scene.vertexBuffer
        geometry.vertexBufferOffset = region.vertexByteOffset(for: slot)
        geometry.vertexStride = MemoryLayout<Vertex>.stride
        geometry.vertexFormat = .float3
        geometry.indexBuffer = scene.indexBuffer
        geometry.indexBufferOffset = region.indexByteOffset
        geometry.indexType = .uint32
        geometry.triangleCount = region.triangleCount
        geometry.opaque = true
        geometry.allowDuplicateIntersectionFunctionInvocation = false
        geometry.intersectionFunctionTableOffset = 0
        geometry.label = "\(region.name) slot \(slot)"

        let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
        descriptor.geometryDescriptors = [geometry]
        descriptor.usage = region.isDynamic ? [.refit] : []
        return descriptor
    }

    /// Column-major 3×4 packed transform from a 4×4 model matrix (columns 0…2 rotation/scale, column 3 translation).
    static func packedTransform(_ m: float4x4) -> MTLPackedFloat4x3 {
        var packed = MTLPackedFloat4x3()
        packed.columns.0 = MTLPackedFloat3Make(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        packed.columns.1 = MTLPackedFloat3Make(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        packed.columns.2 = MTLPackedFloat3Make(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        packed.columns.3 = MTLPackedFloat3Make(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        return packed
    }

    private var cachedGeometryMap: [Int: Int] = [:]
    private var cachedGeometryMapRegionCount = -1

    /// geometryIndex (any slot) → region index, refreshed when meshes are registered.
    private func geometryToRegionMap(scene: SceneResources) -> [Int: Int] {
        if cachedGeometryMapRegionCount == scene.meshRegions.count {
            return cachedGeometryMap
        }
        var map: [Int: Int] = [:]
        for (regionIndex, region) in scene.meshRegions.enumerated() {
            for slot in 0..<region.slotCount {
                map[region.firstGeometryIndex + slot] = regionIndex
            }
        }
        cachedGeometryMap = map
        cachedGeometryMapRegionCount = scene.meshRegions.count
        return map
    }

    private func makeScratch(_ label: String, length: Int) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: max(length, 256), options: .storageModePrivate) else {
            throw AccelerationStructureError.scratchCreationFailed(label)
        }
        buffer.label = label
        return buffer
    }
}
