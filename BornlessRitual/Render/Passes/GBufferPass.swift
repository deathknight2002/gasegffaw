//
//  GBufferPass.swift
//  Bornless Ritual — G-buffer rasterisation pass (RENDER_CONTRACT §2 row 2
//  "GBufferPass", §1 `RenderPass`; ShaderTypes.h `Vertex` layout and the
//  TextureIndexGBuffer* / TextureIndexDepth formats owned by RenderResources).
//
//  Role: builds the `gbuffer_vertex` / `gbuffer_fragment` render pipeline (vertex
//  descriptor matching `Vertex`, four colour attachments, depth32Float) and a
//  reversed-Z depth state (clear 0, compare greater), then draws every instance of the
//  current slot: one indexed draw per instance with `baseInstance` = instance index
//  (so `[[instance_id]]` addresses `InstanceData[]` directly), the vertex buffer offset
//  at the instance's geometry slot, and the cull mode of the owning `MeshRegion`
//  (the room is registered with `.none`, everything else `.back`). Instances whose
//  material carries MATERIAL_FLAG_NO_SHADOW (flame proxies, drawn by FlamePass) are
//  skipped so they never write depth in front of the flame quads.
//

import Foundation
import Metal
import simd
import os

/// Errors raised while building the G-buffer pass.
enum GBufferPassError: Error, CustomStringConvertible {
    /// `MTLDevice.makeDepthStencilState` returned nil.
    case depthStateCreationFailed

    var description: String {
        switch self {
        case .depthStateCreationFailed: return "Could not create the G-buffer depth-stencil state"
        }
    }
}

/// Rasterises the scene instances into albedo, normal + roughness, motion,
/// emissive + metallic and reversed-Z depth.
final class GBufferPass: RenderPass {

    // MARK: Configuration

    let name = "GBuffer"

    /// Front-facing winding of the scene meshes. SceneBuilder is assumed to emit
    /// counter-clockwise triangles (the usual convention); flip here if it does not.
    var frontFacingWinding: MTLWinding = .counterClockwise

    /// Colour attachments in slot order (`[[color(n)]]` in GBuffer.metal).
    static let colorTargets: [TextureIndex] = [.gBufferAlbedo, .gBufferNormal, .gBufferMotion, .gBufferEmissive]

    /// `MATERIAL_FLAG_NO_SHADOW` (ShaderTypes.h): flame proxies, drawn by FlamePass instead.
    private static let materialFlagNoShadow: UInt32 = 1 << 5

    // MARK: State

    private let pipelines: PipelineCache
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var regionBySlotGeometry: [Int: GeometrySlot] = [:]
    private var cachedRegionCount = -1
    private var loggedNotBuilt = false
    private let log = Logger(subsystem: "BornlessRitual", category: "GBufferPass")

    /// A mesh region together with the vertex slot a geometry index refers to.
    private struct GeometrySlot {
        let region: MeshRegion
        let slot: Int
    }

    /// One indexed draw call.
    private struct DrawItem {
        let instanceIndex: Int
        let vertexByteOffset: Int
        let indexByteOffset: Int
        let indexCount: Int
        let cullMode: MTLCullMode
    }

    // MARK: Init

    /// Creates the pass; pipelines are built in `build`.
    init(pipelines: PipelineCache) {
        self.pipelines = pipelines
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        let vertexDescriptor = GBufferPass.makeVertexDescriptor()
        pipeline = try pipelines.render(label: "GBuffer", vertexFunction: "gbuffer_vertex", fragmentFunction: "gbuffer_fragment") { descriptor in
            descriptor.vertexDescriptor = vertexDescriptor
            for (slot, index) in GBufferPass.colorTargets.enumerated() {
                descriptor.colorAttachments[slot].pixelFormat = resources.texture(index).pixelFormat
                descriptor.colorAttachments[slot].isBlendingEnabled = false
            }
            descriptor.depthAttachmentPixelFormat = resources.texture(.depth).pixelFormat
            descriptor.stencilAttachmentPixelFormat = .invalid
            descriptor.rasterSampleCount = 1
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.label = "GBuffer reversed-Z"
        depthDescriptor.depthCompareFunction = .greater
        depthDescriptor.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw GBufferPassError.depthStateCreationFailed
        }
        depthState = state
        loggedNotBuilt = false
    }

    func encode(_ ctx: FrameContext) {
        guard let pipeline = pipeline, let depthState = depthState else {
            if !loggedNotBuilt {
                log.error("GBufferPass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        let resources = ctx.resources
        let scene = ctx.scene
        let draws = collectDraws(scene: scene)

        let pass = MTLRenderPassDescriptor()
        for (slot, index) in GBufferPass.colorTargets.enumerated() {
            let attachment = pass.colorAttachments[slot]
            attachment?.texture = resources.texture(index)
            attachment?.loadAction = .clear
            attachment?.storeAction = .store
            attachment?.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        pass.depthAttachment.texture = resources.texture(.depth)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0   // reversed-Z: 0 = far / background

        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            log.error("Could not create the G-buffer render command encoder")
            return
        }
        encoder.label = "GBuffer"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setFrontFacing(frontFacingWinding)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(resources.renderSize.width),
                                        height: Double(resources.renderSize.height),
                                        znear: 0, zfar: 1))

        encoder.setVertexBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setVertexBuffer(scene.buffer(for: .instances), offset: scene.offset(for: .instances), index: BufferIndex.instances.rawValue)
        encoder.setVertexBuffer(scene.vertexBuffer, offset: 0, index: BufferIndex.vertices.rawValue)
        encoder.setFragmentBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setFragmentBuffer(scene.materialBuffer, offset: 0, index: BufferIndex.materials.rawValue)
        encoder.setFragmentTexture(resources.texture(.albedoAtlas), index: TextureIndex.albedoAtlas.rawValue)
        encoder.setFragmentTexture(resources.texture(.normalAtlas), index: TextureIndex.normalAtlas.rawValue)
        encoder.setFragmentTexture(resources.texture(.chalkMask), index: TextureIndex.chalkMask.rawValue)

        for draw in draws {
            encoder.setCullMode(draw.cullMode)
            encoder.setVertexBufferOffset(draw.vertexByteOffset, index: BufferIndex.vertices.rawValue)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: draw.indexCount,
                                          indexType: .uint32,
                                          indexBuffer: scene.indexBuffer,
                                          indexBufferOffset: draw.indexByteOffset,
                                          instanceCount: 1,
                                          baseVertex: 0,
                                          baseInstance: draw.instanceIndex)
        }
        encoder.endEncoding()
    }

    // MARK: - Draw list

    /// Resolves the current slot's instances to draw calls (CPU-side read of the shared
    /// instance and material buffers written by SceneUpdater earlier this frame).
    private func collectDraws(scene: SceneResources) -> [DrawItem] {
        let instanceCount = scene.instanceCount
        guard instanceCount > 0 else { return [] }
        refreshRegionMap(scene: scene)

        let instanceBase = scene.buffer(for: .instances).contents().advanced(by: scene.offset(for: .instances))
        let materialBase = scene.materialBuffer.contents()
        let instanceStride = MemoryLayout<InstanceData>.stride
        let materialStride = MemoryLayout<MaterialData>.stride

        var draws: [DrawItem] = []
        draws.reserveCapacity(instanceCount)
        for instanceIndex in 0..<instanceCount {
            let instance = instanceBase.load(fromByteOffset: instanceIndex * instanceStride, as: InstanceData.self)
            guard let geometry = regionBySlotGeometry[Int(instance.geometryIndex)] else { continue }
            let materialIndex = Int(instance.materialIndex)
            if materialIndex < scene.materialCount {
                let material = materialBase.load(fromByteOffset: materialIndex * materialStride, as: MaterialData.self)
                if material.flags & GBufferPass.materialFlagNoShadow != 0 {
                    continue
                }
            }
            draws.append(DrawItem(instanceIndex: instanceIndex,
                                  vertexByteOffset: geometry.region.vertexByteOffset(for: geometry.slot),
                                  indexByteOffset: geometry.region.indexByteOffset,
                                  indexCount: geometry.region.indexRange.count,
                                  cullMode: geometry.region.cullMode))
        }
        return draws
    }

    /// Rebuilds the geometryIndex → (region, slot) map when meshes were registered.
    private func refreshRegionMap(scene: SceneResources) {
        guard scene.meshRegions.count != cachedRegionCount else { return }
        var map: [Int: GeometrySlot] = [:]
        for region in scene.meshRegions {
            for slot in 0..<region.slotCount {
                map[region.firstGeometryIndex + slot] = GeometrySlot(region: region, slot: slot)
            }
        }
        regionBySlotGeometry = map
        cachedRegionCount = scene.meshRegions.count
    }

    // MARK: - Vertex descriptor

    /// Vertex layout matching `Vertex` in ShaderTypes.h (position, normal, tangent, uv;
    /// 64-byte stride) at `BufferIndexVertices`; attribute indices match GBuffer.metal.
    static func makeVertexDescriptor() -> MTLVertexDescriptor {
        let bufferIndex = BufferIndex.vertices.rawValue
        let descriptor = MTLVertexDescriptor()

        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = MemoryLayout<Vertex>.offset(of: \Vertex.position) ?? 0
        descriptor.attributes[0].bufferIndex = bufferIndex

        descriptor.attributes[1].format = .float3
        descriptor.attributes[1].offset = MemoryLayout<Vertex>.offset(of: \Vertex.normal) ?? 16
        descriptor.attributes[1].bufferIndex = bufferIndex

        descriptor.attributes[2].format = .float4
        descriptor.attributes[2].offset = MemoryLayout<Vertex>.offset(of: \Vertex.tangent) ?? 32
        descriptor.attributes[2].bufferIndex = bufferIndex

        descriptor.attributes[3].format = .float2
        descriptor.attributes[3].offset = MemoryLayout<Vertex>.offset(of: \Vertex.uv) ?? 48
        descriptor.attributes[3].bufferIndex = bufferIndex

        descriptor.layouts[bufferIndex].stride = MemoryLayout<Vertex>.stride
        descriptor.layouts[bufferIndex].stepFunction = .perVertex
        descriptor.layouts[bufferIndex].stepRate = 1
        return descriptor
    }
}
