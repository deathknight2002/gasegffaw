//
//  SceneResources.swift
//  Bornless Ritual — owns every scene-side MTLBuffer (RENDER_CONTRACT §1 `SceneResources`,
//  §2 row 0 SceneUpdate, §5 acceleration-structure slots; binding indices in
//  ShaderTypes.h `BufferIndex`).
//
//  Role: shared vertex/index buffers with a `MeshRegion` registry (SceneBuilder
//  registers meshes; SceneUpdater rewrites the sorcerer's vertices per tick),
//  triple-buffered per-frame buffers (instances, lights, flames, sigil/daemon/froxel/
//  post params, SDF scene, AS instance descriptors) addressed through `slot` and
//  `offset(for:)`, persistent buffers (materials, geometry ranges, ring history, sigil
//  filaments, ember instances, ember counter + indirect draw arguments) and the
//  acceleration-structure slots filled by Render/Scene/AccelerationStructures.swift.
//
//  Storage: iOS has unified memory, so CPU-written buffers are `.storageModeShared`;
//  GPU-only buffers (embers) are `.storageModePrivate`. Every slot offset is 256-byte
//  aligned. Dynamic meshes get one vertex slot per in-flight frame so a CPU rewrite
//  never races the GPU (their GeometryRange table has one entry per slot too).
//

import Foundation
import Metal
import simd

// MARK: - Capacities

/// Fixed buffer capacities chosen at construction.
struct SceneCapacities: Sendable {
    /// Total vertices across all meshes (dynamic meshes count once per slot).
    var maxVertices: Int = 131_072
    /// Total indices across all meshes.
    var maxIndices: Int = 393_216
    /// Instances per frame.
    var maxInstances: Int = 64
    /// Materials.
    var maxMaterials: Int = 32
    /// GeometryRange entries (dynamic meshes use one per slot).
    var maxGeometries: Int = 64
    /// Flames per frame (4 quarter + 2 altar + sigil/daemon proxies + slack).
    var maxFlames: Int = 16
    /// Sigil filament line-strip vertices.
    var maxSigilFilamentVertices: Int = 16_384

    /// Defaults sized for the chamber scene.
    static let `default` = SceneCapacities()
}

// MARK: - MeshRegion

/// A registered mesh: where its vertices and indices live in the shared buffers.
struct MeshRegion: Equatable, Sendable {
    /// Registry name (e.g. "room", "sorcerer", "candleEast").
    let name: String
    /// GeometryRange index for slot 0.
    let firstGeometryIndex: Int
    /// 1 for static meshes, `SceneResources.inflightSlots` for dynamic ones.
    let slotCount: Int
    /// Vertices in one slot.
    let vertexCountPerSlot: Int
    /// Index of the first vertex of slot 0 in the shared vertex buffer.
    let firstVertex: Int
    /// Range in the shared index buffer (indices are relative to the slot's base vertex).
    let indexRange: Range<Int>
    /// Cull mode the G-buffer pass should use for this mesh.
    let cullMode: MTLCullMode

    /// True when the vertices are rewritten per tick (sorcerer).
    var isDynamic: Bool { slotCount > 1 }
    /// Triangle count.
    var triangleCount: Int { indexRange.count / 3 }

    /// GeometryRange index to use for `slot` (static meshes ignore the slot).
    func geometryIndex(for slot: Int) -> Int {
        firstGeometryIndex + min(max(slot, 0), slotCount - 1)
    }

    /// Vertex index range for `slot`.
    func vertexRange(for slot: Int) -> Range<Int> {
        let start = firstVertex + min(max(slot, 0), slotCount - 1) * vertexCountPerSlot
        return start..<(start + vertexCountPerSlot)
    }

    /// Byte offset of the slot's first vertex in the shared vertex buffer.
    func vertexByteOffset(for slot: Int) -> Int {
        vertexRange(for: slot).lowerBound * MemoryLayout<Vertex>.stride
    }

    /// Byte offset of the first index in the shared index buffer.
    var indexByteOffset: Int {
        indexRange.lowerBound * MemoryLayout<UInt32>.stride
    }

    /// The GeometryRange record for `slot`.
    func geometryRange(for slot: Int) -> GeometryRange {
        var range = GeometryRange()
        range.firstIndex = UInt32(indexRange.lowerBound)
        range.indexCount = UInt32(indexRange.count)
        range.baseVertex = UInt32(vertexRange(for: slot).lowerBound)
        range.padding = 0
        return range
    }
}

// MARK: - Triple-buffered resources

/// Buffers that have one region per in-flight frame.
enum TripleBufferedResource: Int, CaseIterable, Sendable {
    /// `InstanceData[maxInstances]` — BufferIndexInstances.
    case instances
    /// `LightData[MAX_LIGHTS]` — BufferIndexLights.
    case lights
    /// `FlameData[maxFlames]` — BufferIndexFlames.
    case flames
    /// `SigilParams` — BufferIndexSigilParams.
    case sigilParams
    /// `DaemonParams` — BufferIndexDaemonParams.
    case daemonParams
    /// `FroxelParams` — BufferIndexFroxelParams.
    case froxelParams
    /// `PostParams` — BufferIndexPostParams.
    case postParams
    /// `SDFScene` — BufferIndexSDFScene.
    case sdfScene
    /// `MTLAccelerationStructureInstanceDescriptor[maxInstances]` (instance AS input).
    case instanceDescriptors
}

/// Errors raised by the scene buffers.
enum SceneResourceError: Error, CustomStringConvertible {
    /// A registration would exceed a capacity.
    case capacityExceeded(String)
    /// A mesh name was registered twice.
    case duplicateMesh(String)
    /// Indices must come in triangles.
    case malformedIndices(String)

    var description: String {
        switch self {
        case .capacityExceeded(let what): return "Scene capacity exceeded: \(what)"
        case .duplicateMesh(let name): return "Mesh '\(name)' is already registered"
        case .malformedIndices(let name): return "Mesh '\(name)' index count is not a multiple of 3"
        }
    }
}

// MARK: - SceneResources

/// All scene-side GPU buffers.
final class SceneResources {

    /// Frames in flight (matches the Renderer's semaphore).
    static let inflightSlots = 3
    /// Alignment of every slot region.
    static let slotAlignment = 256
    /// Byte offset of the atomic live-ember counter inside `emberCountBuffer`.
    static let emberCountOffset = 0
    /// Byte offset of the `MTLDrawPrimitivesIndirectArguments` inside `emberCountBuffer`.
    static let emberDrawArgumentsOffset = 16
    /// Vertices per ember quad (two triangles) written into the indirect arguments template.
    static let emberQuadVertexCount: UInt32 = 6

    /// Device the buffers belong to.
    let device: MTLDevice
    /// Capacities used at construction.
    let capacities: SceneCapacities

    // MARK: Geometry (shared, single slot)

    /// `Vertex[maxVertices]` — BufferIndexVertices (also the AS vertex source).
    let vertexBuffer: MTLBuffer
    /// `uint32[maxIndices]` — BufferIndexIndices.
    let indexBuffer: MTLBuffer
    /// `GeometryRange[maxGeometries]` — BufferIndexGeometryRanges.
    let geometryRangeBuffer: MTLBuffer
    /// `MaterialData[maxMaterials]` — BufferIndexMaterials.
    let materialBuffer: MTLBuffer

    /// Vertices allocated so far.
    private(set) var vertexCount = 0
    /// Indices allocated so far.
    private(set) var indexCount = 0
    /// GeometryRange entries allocated so far.
    private(set) var geometryCount = 0
    /// Materials written by `setMaterials`.
    private(set) var materialCount = 0
    /// Registered meshes in registration order.
    private(set) var meshRegions: [MeshRegion] = []
    private var meshByName: [String: MeshRegion] = [:]

    // MARK: Triple-buffered

    /// Current slot (0…2); advanced once per frame by the Renderer.
    private(set) var slot = 0
    private var buffers: [TripleBufferedResource: MTLBuffer] = [:]
    private var slotStrides: [TripleBufferedResource: Int] = [:]

    /// Instances written for the current slot.
    private(set) var instanceCount = 0
    /// Lights written for the current slot.
    private(set) var lightCount = 0
    /// Flames written for the current slot.
    private(set) var flameCount = 0

    // MARK: Persistent

    /// `RingHistoryEntry[RING_HISTORY_TICKS × RING_COUNT]` — BufferIndexRingHistory
    /// (index = (tick % RING_HISTORY_TICKS) · RING_COUNT + ring). Shared, persistent.
    let ringHistoryBuffer: MTLBuffer
    /// `SigilFilamentVertex[maxSigilFilamentVertices]` — BufferIndexSigilVertices.
    let sigilFilamentBuffer: MTLBuffer
    /// Filament vertices written by `writeSigilFilaments`.
    private(set) var sigilFilamentVertexCount = 0
    /// `EmberInstance[MAX_EMBERS]` — BufferIndexEmbers (GPU-written, private).
    let emberInstanceBuffer: MTLBuffer
    /// `uint` live count at `emberCountOffset` + `MTLDrawPrimitivesIndirectArguments` at
    /// `emberDrawArgumentsOffset` — BufferIndexEmberCount / BufferIndexDrawArgs (private).
    let emberCountBuffer: MTLBuffer
    /// Shared template blitted over `emberCountBuffer` each frame (count 0, args (6, 0, 0, 0)).
    let emberResetTemplateBuffer: MTLBuffer

    // MARK: Acceleration structures (filled by AccelerationStructures.swift)

    /// One primitive AS per mesh region / slot (built once for static meshes; refit for the sorcerer).
    var primitiveAS: [MTLAccelerationStructure] = []
    /// Instance AS rebuilt every frame (RT path only).
    var instanceAS: MTLAccelerationStructure?

    // MARK: Init

    /// Allocates every buffer.
    ///
    /// - Throws: `RenderResourceError.bufferCreationFailed` when an allocation fails.
    init(device: MTLDevice, capacities: SceneCapacities = .default) throws {
        self.device = device
        self.capacities = capacities

        vertexBuffer = try SceneResources.makeBuffer(device, "Vertices", capacities.maxVertices * MemoryLayout<Vertex>.stride, .storageModeShared)
        indexBuffer = try SceneResources.makeBuffer(device, "Indices", capacities.maxIndices * MemoryLayout<UInt32>.stride, .storageModeShared)
        geometryRangeBuffer = try SceneResources.makeBuffer(device, "GeometryRanges", capacities.maxGeometries * MemoryLayout<GeometryRange>.stride, .storageModeShared)
        materialBuffer = try SceneResources.makeBuffer(device, "Materials", capacities.maxMaterials * MemoryLayout<MaterialData>.stride, .storageModeShared)

        ringHistoryBuffer = try SceneResources.makeBuffer(device, "RingHistory", Int(RING_HISTORY_TICKS) * Int(RING_COUNT) * MemoryLayout<RingHistoryEntry>.stride, .storageModeShared)
        sigilFilamentBuffer = try SceneResources.makeBuffer(device, "SigilFilaments", capacities.maxSigilFilamentVertices * MemoryLayout<SigilFilamentVertex>.stride, .storageModeShared)
        emberInstanceBuffer = try SceneResources.makeBuffer(device, "EmberInstances", Int(MAX_EMBERS) * MemoryLayout<EmberInstance>.stride, .storageModePrivate)
        emberCountBuffer = try SceneResources.makeBuffer(device, "EmberCount+DrawArgs", 32, .storageModePrivate)
        emberResetTemplateBuffer = try SceneResources.makeBuffer(device, "EmberResetTemplate", 32, .storageModeShared)

        let sizes: [(TripleBufferedResource, Int)] = [
            (.instances, capacities.maxInstances * MemoryLayout<InstanceData>.stride),
            (.lights, Int(MAX_LIGHTS) * MemoryLayout<LightData>.stride),
            (.flames, capacities.maxFlames * MemoryLayout<FlameData>.stride),
            (.sigilParams, MemoryLayout<SigilParams>.stride),
            (.daemonParams, MemoryLayout<DaemonParams>.stride),
            (.froxelParams, MemoryLayout<FroxelParams>.stride),
            (.postParams, MemoryLayout<PostParams>.stride),
            (.sdfScene, MemoryLayout<SDFScene>.stride),
            (.instanceDescriptors, capacities.maxInstances * MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride),
        ]
        for (resource, byteSize) in sizes {
            let stride = SceneResources.alignUp(byteSize, to: SceneResources.slotAlignment)
            let buffer = try SceneResources.makeBuffer(device, "Triple.\(resource)", stride * SceneResources.inflightSlots, .storageModeShared)
            buffers[resource] = buffer
            slotStrides[resource] = stride
        }

        initialiseEmberResetTemplate()
        clearRingHistory()
    }

    // MARK: Slot accessors

    /// The buffer backing `resource` (all three slots).
    ///
    /// Invariant: `init` allocates every `TripleBufferedResource`, so the lookup cannot fail.
    func buffer(for resource: TripleBufferedResource) -> MTLBuffer {
        guard let buffer = buffers[resource] else {
            fatalError("SceneResources invariant violated: missing buffer for \(resource)")
        }
        return buffer
    }

    /// Byte stride between slots of `resource` (256-byte aligned).
    func slotStride(for resource: TripleBufferedResource) -> Int {
        slotStrides[resource] ?? 0
    }

    /// Byte offset of the current slot's region of `resource`.
    func offset(for resource: TripleBufferedResource) -> Int {
        offset(for: resource, slot: slot)
    }

    /// Byte offset of an explicit slot's region of `resource`.
    func offset(for resource: TripleBufferedResource, slot: Int) -> Int {
        slotStride(for: resource) * (slot % SceneResources.inflightSlots)
    }

    /// Moves to the next slot; call once per frame before SceneUpdater writes.
    func advanceSlot() {
        slot = (slot + 1) % SceneResources.inflightSlots
        instanceCount = 0
        lightCount = 0
        flameCount = 0
    }

    // MARK: Mesh registry

    /// Appends a mesh to the shared buffers and its GeometryRange entries.
    ///
    /// - Parameters:
    ///   - name: Unique registry name.
    ///   - vertices: Vertex data for slot 0 (dynamic meshes get this copied to all slots).
    ///   - indices: Triangle list, relative to the mesh's first vertex.
    ///   - cullMode: Cull mode for rasterisation.
    ///   - isDynamic: True for meshes rewritten per tick (one vertex slot per in-flight frame).
    /// - Returns: The region record (also retrievable through `mesh(named:)`).
    @discardableResult
    func registerMesh(name: String, vertices: [Vertex], indices: [UInt32], cullMode: MTLCullMode = .back, isDynamic: Bool = false) throws -> MeshRegion {
        guard meshByName[name] == nil else { throw SceneResourceError.duplicateMesh(name) }
        guard indices.count % 3 == 0, !indices.isEmpty, !vertices.isEmpty else { throw SceneResourceError.malformedIndices(name) }
        let slotCount = isDynamic ? SceneResources.inflightSlots : 1
        let totalVertices = vertices.count * slotCount
        guard vertexCount + totalVertices <= capacities.maxVertices else { throw SceneResourceError.capacityExceeded("vertices for \(name)") }
        guard indexCount + indices.count <= capacities.maxIndices else { throw SceneResourceError.capacityExceeded("indices for \(name)") }
        guard geometryCount + slotCount <= capacities.maxGeometries else { throw SceneResourceError.capacityExceeded("geometries for \(name)") }

        let region = MeshRegion(name: name,
                                firstGeometryIndex: geometryCount,
                                slotCount: slotCount,
                                vertexCountPerSlot: vertices.count,
                                firstVertex: vertexCount,
                                indexRange: indexCount..<(indexCount + indices.count),
                                cullMode: cullMode)

        for slotIndex in 0..<slotCount {
            SceneResources.write(vertices, into: vertexBuffer, byteOffset: region.vertexByteOffset(for: slotIndex))
            SceneResources.write([region.geometryRange(for: slotIndex)], into: geometryRangeBuffer,
                                 byteOffset: (region.firstGeometryIndex + slotIndex) * MemoryLayout<GeometryRange>.stride)
        }
        SceneResources.write(indices, into: indexBuffer, byteOffset: region.indexByteOffset)

        vertexCount += totalVertices
        indexCount += indices.count
        geometryCount += slotCount
        meshRegions.append(region)
        meshByName[name] = region
        return region
    }

    /// Looks up a registered mesh.
    func mesh(named name: String) -> MeshRegion? {
        meshByName[name]
    }

    /// Rewrites the current slot's vertices of a dynamic mesh (the sorcerer, per tick).
    /// `vertices.count` must equal `region.vertexCountPerSlot`; extra vertices are ignored
    /// and missing ones leave stale data (both are programmer errors, logged by callers).
    func rewriteVertices(of region: MeshRegion, vertices: [Vertex]) {
        let count = min(vertices.count, region.vertexCountPerSlot)
        guard count > 0 else { return }
        SceneResources.write(Array(vertices.prefix(count)), into: vertexBuffer, byteOffset: region.vertexByteOffset(for: slot))
    }

    /// Byte offset of the current slot's vertices for `region` (AS refit source).
    func currentVertexByteOffset(of region: MeshRegion) -> Int {
        region.vertexByteOffset(for: slot)
    }

    // MARK: Materials

    /// Replaces the material table (index = `InstanceData.materialIndex`).
    func setMaterials(_ materials: [MaterialData]) {
        let count = min(materials.count, capacities.maxMaterials)
        SceneResources.write(Array(materials.prefix(count)), into: materialBuffer, byteOffset: 0)
        materialCount = count
    }

    // MARK: Per-frame writes (current slot)

    /// Writes the frame's instances; returns the number actually written.
    @discardableResult
    func writeInstances(_ instances: [InstanceData]) -> Int {
        let count = min(instances.count, capacities.maxInstances)
        SceneResources.write(Array(instances.prefix(count)), into: buffer(for: .instances), byteOffset: offset(for: .instances))
        instanceCount = count
        return count
    }

    /// Writes the frame's lights (≤ MAX_LIGHTS); returns the number written.
    @discardableResult
    func writeLights(_ lights: [LightData]) -> Int {
        let count = min(lights.count, Int(MAX_LIGHTS))
        SceneResources.write(Array(lights.prefix(count)), into: buffer(for: .lights), byteOffset: offset(for: .lights))
        lightCount = count
        return count
    }

    /// Writes the frame's flames; returns the number written.
    @discardableResult
    func writeFlames(_ flames: [FlameData]) -> Int {
        let count = min(flames.count, capacities.maxFlames)
        SceneResources.write(Array(flames.prefix(count)), into: buffer(for: .flames), byteOffset: offset(for: .flames))
        flameCount = count
        return count
    }

    /// Writes `SigilParams` for the current slot.
    func writeSigilParams(_ params: SigilParams) {
        SceneResources.write([params], into: buffer(for: .sigilParams), byteOffset: offset(for: .sigilParams))
    }

    /// Writes `DaemonParams` for the current slot.
    func writeDaemonParams(_ params: DaemonParams) {
        SceneResources.write([params], into: buffer(for: .daemonParams), byteOffset: offset(for: .daemonParams))
    }

    /// Writes `FroxelParams` for the current slot.
    func writeFroxelParams(_ params: FroxelParams) {
        SceneResources.write([params], into: buffer(for: .froxelParams), byteOffset: offset(for: .froxelParams))
    }

    /// Writes `PostParams` for the current slot.
    func writePostParams(_ params: PostParams) {
        SceneResources.write([params], into: buffer(for: .postParams), byteOffset: offset(for: .postParams))
    }

    /// Writes the fallback SDF scene for the current slot (≤ MAX_SDF_PRIMITIVES primitives).
    /// The `SDFScene.primitives` C array is written through raw memory (Swift imports it
    /// as a 48-tuple), followed by `count`.
    func writeSDFScene(primitives: [SDFPrimitive]) {
        let count = min(primitives.count, Int(MAX_SDF_PRIMITIVES))
        let base = offset(for: .sdfScene)
        let sceneBuffer = buffer(for: .sdfScene)
        SceneResources.write(Array(primitives.prefix(count)), into: sceneBuffer, byteOffset: base)
        guard let countOffset = MemoryLayout<SDFScene>.offset(of: \SDFScene.count) else { return }
        SceneResources.write([UInt32(count), 0, 0, 0], into: sceneBuffer, byteOffset: base + countOffset)
    }

    /// Writes the instance descriptors consumed by the instance-AS build for the current slot.
    @discardableResult
    func writeInstanceDescriptors(_ descriptors: [MTLAccelerationStructureInstanceDescriptor]) -> Int {
        let count = min(descriptors.count, capacities.maxInstances)
        SceneResources.write(Array(descriptors.prefix(count)), into: buffer(for: .instanceDescriptors), byteOffset: offset(for: .instanceDescriptors))
        return count
    }

    // MARK: Persistent writes

    /// Writes the ring entries for `tick` into the ring-history ring buffer
    /// (`entries.count` should be RING_COUNT; extras are ignored).
    func writeRingHistory(tick: Int, entries: [RingHistoryEntry]) {
        let ringCount = Int(RING_COUNT)
        let count = min(entries.count, ringCount)
        guard count > 0, tick >= 0 else { return }
        let row = tick % Int(RING_HISTORY_TICKS)
        let byteOffset = row * ringCount * MemoryLayout<RingHistoryEntry>.stride
        SceneResources.write(Array(entries.prefix(count)), into: ringHistoryBuffer, byteOffset: byteOffset)
    }

    /// Zeroes the ring history (after a seek so stale ticks never leak).
    func clearRingHistory() {
        memset(ringHistoryBuffer.contents(), 0, ringHistoryBuffer.length)
    }

    /// Replaces the sigil filament vertices; returns the number written.
    @discardableResult
    func writeSigilFilaments(_ vertices: [SigilFilamentVertex]) -> Int {
        let count = min(vertices.count, capacities.maxSigilFilamentVertices)
        SceneResources.write(Array(vertices.prefix(count)), into: sigilFilamentBuffer, byteOffset: 0)
        sigilFilamentVertexCount = count
        return count
    }

    /// Resets the ember counter and indirect arguments for this frame (blit the template).
    /// Encode before the ember compute kernel runs.
    func encodeEmberReset(_ blit: MTLBlitCommandEncoder) {
        blit.copy(from: emberResetTemplateBuffer, sourceOffset: 0,
                  to: emberCountBuffer, destinationOffset: 0, size: 32)
    }

    // MARK: Debug

    /// Buffer usage summary for the debug panel.
    var description: String {
        "meshes \(meshRegions.count), vertices \(vertexCount)/\(capacities.maxVertices), indices \(indexCount)/\(capacities.maxIndices), materials \(materialCount), slot \(slot), instances \(instanceCount), lights \(lightCount), flames \(flameCount)"
    }

    // MARK: - Private

    private func initialiseEmberResetTemplate() {
        memset(emberResetTemplateBuffer.contents(), 0, emberResetTemplateBuffer.length)
        var args = MTLDrawPrimitivesIndirectArguments()
        args.vertexCount = SceneResources.emberQuadVertexCount
        args.instanceCount = 0
        args.vertexStart = 0
        args.baseInstance = 0
        SceneResources.write([args], into: emberResetTemplateBuffer, byteOffset: SceneResources.emberDrawArgumentsOffset)
    }

    private static func makeBuffer(_ device: MTLDevice, _ label: String, _ length: Int, _ options: MTLResourceOptions) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: max(length, 16), options: options) else {
            throw RenderResourceError.bufferCreationFailed(label)
        }
        buffer.label = label
        return buffer
    }

    /// Copies `values` into a shared buffer at `byteOffset` (bounds-clamped to the buffer length).
    private static func write<T>(_ values: [T], into buffer: MTLBuffer, byteOffset: Int) {
        guard !values.isEmpty else { return }
        let byteCount = values.count * MemoryLayout<T>.stride
        guard byteOffset >= 0, byteOffset + byteCount <= buffer.length else { return }
        values.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { return }
            buffer.contents().advanced(by: byteOffset).copyMemory(from: source, byteCount: byteCount)
        }
    }

    private static func alignUp(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }
}
