//
//  DirectLightingPass.swift
//  Bornless Ritual — direct lighting compute pass (RENDER_CONTRACT §2 row 3
//  "DirectLightingPass", §1 `RenderPass`, §5 "useResources on all primitive AS in every
//  compute encoder that traces"; Shaders/Lighting.metal `lighting_direct`).
//
//  Role: binds the G-buffer, lights, materials and — per render path — the instance
//  acceleration structure (RT) or the SDF scene (fallback), then dispatches
//  `lighting_direct` over the internal resolution with 8×8 threadgroups
//  (`dispatchThreads`, exact size). The pipeline is specialised by the cache's current
//  `PipelineVariant` (function constant 0 = render path), so the kernel's optional
//  arguments (`accel` / `sdf`) exist only for the path being built.
//

import Foundation
import Metal
import os

/// One shadow ray per pixel toward an importance-chosen light → DirectDiffuse / DirectSpecular.
final class DirectLightingPass: RenderPass {

    let name = "DirectLighting"

    private let pipelines: PipelineCache
    private var pipeline: MTLComputePipelineState?
    private var loggedMissingAS = false
    private var loggedNotBuilt = false
    private let log = Logger(subsystem: "BornlessRitual", category: "DirectLightingPass")

    /// Creates the pass; the pipeline is built in `build`.
    init(pipelines: PipelineCache) {
        self.pipelines = pipelines
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        pipeline = try pipelines.compute("lighting_direct")
        loggedMissingAS = false
        loggedNotBuilt = false
    }

    func encode(_ ctx: FrameContext) {
        guard let pipeline = pipeline else {
            if !loggedNotBuilt {
                log.error("DirectLightingPass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        let scene = ctx.scene
        let resources = ctx.resources

        // The RT kernel dereferences the instance AS; skip the dispatch until it exists.
        var accelerationStructure: MTLAccelerationStructure?
        if ctx.renderPath == .rt {
            guard let instanceAS = scene.instanceAS else {
                if !loggedMissingAS {
                    log.warning("RT path active but no instance acceleration structure is available; skipping direct lighting")
                    loggedMissingAS = true
                }
                return
            }
            accelerationStructure = instanceAS
        }

        guard let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            log.error("Could not create the direct-lighting compute encoder")
            return
        }
        encoder.label = "DirectLighting (\(ctx.renderPath.displayName))"
        encoder.setComputePipelineState(pipeline)

        encoder.setBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setBuffer(scene.buffer(for: .lights), offset: scene.offset(for: .lights), index: BufferIndex.lights.rawValue)
        encoder.setBuffer(scene.materialBuffer, offset: 0, index: BufferIndex.materials.rawValue)
        if let instanceAS = accelerationStructure {
            encoder.setAccelerationStructure(instanceAS, bufferIndex: BufferIndex.accel.rawValue)
            for primitiveAS in scene.primitiveAS {
                encoder.useResource(primitiveAS, usage: .read)
            }
        } else {
            encoder.setBuffer(scene.buffer(for: .sdfScene), offset: scene.offset(for: .sdfScene), index: BufferIndex.sdfScene.rawValue)
        }

        encoder.setTexture(resources.texture(.gBufferAlbedo), index: TextureIndex.gBufferAlbedo.rawValue)
        encoder.setTexture(resources.texture(.gBufferNormal), index: TextureIndex.gBufferNormal.rawValue)
        encoder.setTexture(resources.texture(.gBufferEmissive), index: TextureIndex.gBufferEmissive.rawValue)
        encoder.setTexture(resources.texture(.depth), index: TextureIndex.depth.rawValue)
        encoder.setTexture(resources.texture(.directDiffuse), index: TextureIndex.directDiffuse.rawValue)
        encoder.setTexture(resources.texture(.directSpecular), index: TextureIndex.directSpecular.rawValue)

        let grid = MTLSize(width: resources.renderSize.width, height: resources.renderSize.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: FrameContext.threadgroup8x8)
        encoder.endEncoding()
    }
}
