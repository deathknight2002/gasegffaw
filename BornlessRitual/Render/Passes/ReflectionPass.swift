//
//  ReflectionPass.swift
//  Bornless Ritual — traced glossy reflections compute pass (RENDER_CONTRACT §2 row 4
//  "ReflectionPass", §1 `RenderPass`, §5 RT closest hit needs the shared geometry
//  buffers + instance table; Shaders/Reflection.metal `reflection_trace`).
//
//  Role: binds the G-buffer, lights, materials, flames and — per render path — the
//  instance acceleration structure plus vertex / index / geometry-range / instance
//  buffers (RT, for `reconstructHit`) or the SDF scene (fallback), then dispatches
//  `reflection_trace` with 8×8 threadgroups over the internal resolution.
//
//  Flame count: `FrameUniforms` carries `lightCount` but no flame count, and the scene
//  flame slot may hold stale entries beyond `flameCount`. The pass therefore keeps a
//  private triple-buffered copy of exactly `maxFlames` (16) `FlameData` entries per
//  slot, copies the live flames in and zero-fills the rest (intensity 0 = ignored by
//  the kernel), and binds that copy at `BufferIndexFlames`.
//

import Foundation
import Metal
import os

/// One GGX-sampled reflection ray per glossy pixel → TextureIndexReflection.
final class ReflectionPass: RenderPass {

    let name = "Reflection"

    /// Flame entries scanned by the kernel (`kReflectionMaxFlames` in Reflection.metal).
    static let maxFlames = 16

    private let pipelines: PipelineCache
    private var pipeline: MTLComputePipelineState?
    private var flameCopyBuffer: MTLBuffer?
    private let flameSlotStride: Int
    private var loggedMissingAS = false
    private var loggedNotBuilt = false
    private let log = Logger(subsystem: "BornlessRitual", category: "ReflectionPass")

    /// Creates the pass; the pipeline and the flame copy buffer are built in `build`.
    init(pipelines: PipelineCache) {
        self.pipelines = pipelines
        let bytes = ReflectionPass.maxFlames * MemoryLayout<FlameData>.stride
        self.flameSlotStride = (bytes + SceneResources.slotAlignment - 1) / SceneResources.slotAlignment * SceneResources.slotAlignment
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        pipeline = try pipelines.compute("reflection_trace")
        if flameCopyBuffer == nil {
            guard let buffer = device.makeBuffer(length: flameSlotStride * SceneResources.inflightSlots, options: .storageModeShared) else {
                throw RenderResourceError.bufferCreationFailed("ReflectionPass flame copy")
            }
            buffer.label = "ReflectionPass flames"
            memset(buffer.contents(), 0, buffer.length)
            flameCopyBuffer = buffer
        }
        loggedMissingAS = false
        loggedNotBuilt = false
    }

    func encode(_ ctx: FrameContext) {
        guard let pipeline = pipeline, let flameBuffer = flameCopyBuffer else {
            if !loggedNotBuilt {
                log.error("ReflectionPass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        let scene = ctx.scene
        let resources = ctx.resources

        var accelerationStructure: MTLAccelerationStructure?
        if ctx.renderPath == .rt {
            guard let instanceAS = scene.instanceAS else {
                if !loggedMissingAS {
                    log.warning("RT path active but no instance acceleration structure is available; skipping reflections")
                    loggedMissingAS = true
                }
                return
            }
            accelerationStructure = instanceAS
        }

        let flameOffset = copyFlames(scene: scene, into: flameBuffer)

        guard let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            log.error("Could not create the reflection compute encoder")
            return
        }
        encoder.label = "Reflection (\(ctx.renderPath.displayName))"
        encoder.setComputePipelineState(pipeline)

        encoder.setBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setBuffer(scene.buffer(for: .lights), offset: scene.offset(for: .lights), index: BufferIndex.lights.rawValue)
        encoder.setBuffer(scene.materialBuffer, offset: 0, index: BufferIndex.materials.rawValue)
        encoder.setBuffer(flameBuffer, offset: flameOffset, index: BufferIndex.flames.rawValue)
        if let instanceAS = accelerationStructure {
            encoder.setBuffer(scene.vertexBuffer, offset: 0, index: BufferIndex.vertices.rawValue)
            encoder.setBuffer(scene.indexBuffer, offset: 0, index: BufferIndex.indices.rawValue)
            encoder.setBuffer(scene.geometryRangeBuffer, offset: 0, index: BufferIndex.geometryRanges.rawValue)
            encoder.setBuffer(scene.buffer(for: .instances), offset: scene.offset(for: .instances), index: BufferIndex.instances.rawValue)
            encoder.setAccelerationStructure(instanceAS, bufferIndex: BufferIndex.accel.rawValue)
            for primitiveAS in scene.primitiveAS {
                encoder.useResource(primitiveAS, usage: .read)
            }
        } else {
            encoder.setBuffer(scene.buffer(for: .sdfScene), offset: scene.offset(for: .sdfScene), index: BufferIndex.sdfScene.rawValue)
        }

        encoder.setTexture(resources.texture(.gBufferAlbedo), index: TextureIndex.gBufferAlbedo.rawValue)
        encoder.setTexture(resources.texture(.gBufferNormal), index: TextureIndex.gBufferNormal.rawValue)
        encoder.setTexture(resources.texture(.depth), index: TextureIndex.depth.rawValue)
        encoder.setTexture(resources.texture(.reflection), index: TextureIndex.reflection.rawValue)

        let grid = MTLSize(width: resources.renderSize.width, height: resources.renderSize.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: FrameContext.threadgroup8x8)
        encoder.endEncoding()
    }

    // MARK: - Flame copy

    /// Copies the live flames of the scene's current slot into the same slot of the
    /// private buffer (zero-filled beyond `flameCount`) and returns that slot's byte offset.
    private func copyFlames(scene: SceneResources, into buffer: MTLBuffer) -> Int {
        let slotOffset = (scene.slot % SceneResources.inflightSlots) * flameSlotStride
        let destination = buffer.contents().advanced(by: slotOffset)
        memset(destination, 0, flameSlotStride)
        let count = min(scene.flameCount, ReflectionPass.maxFlames)
        if count > 0 {
            let source = scene.buffer(for: .flames).contents().advanced(by: scene.offset(for: .flames))
            destination.copyMemory(from: source, byteCount: count * MemoryLayout<FlameData>.stride)
        }
        return slotOffset
    }
}
