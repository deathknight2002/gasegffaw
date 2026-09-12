//
//  CompositePass.swift
//  Bornless Ritual — deferred composite pass (RENDER_CONTRACT §2 row 8 "CompositePass",
//  §1 `RenderPass`; Shaders/Composite.metal `composite_main`).
//
//  Role: binds the G-buffer, the denoised lighting (DirectSpecular, Reflection), the
//  subsurface-blurred diffuse (SSSDiffuse), the moments (debug views), the integrated
//  froxel volume with its `FroxelParams` slot, and dispatches `composite_main` over the
//  internal resolution with 8×8 threadgroups. Outputs: TextureIndexHDRColor (lit image,
//  or the `kDebugView` visualisation — the pipeline is specialised by the cache's
//  current `PipelineVariant`, so a debug-view change rebuilds it) and TextureIndexHeat
//  cleared to 0 for the flame / sigil / daemon passes.
//
//  `FroxelParams` is written by SceneUpdater (another job) into the scene's
//  triple-buffered `.froxelParams` slot; the kernel falls back to 0.1 m / 12 m when the
//  slot still reads as zeros, and treats an all-zero froxel texel as "no fog".
//

import Foundation
import Metal
import os

/// albedo × SSSDiffuse + specular + reflection × Fresnel + emissive, fogged → HDRColor; clears Heat.
final class CompositePass: RenderPass {

    let name = "Composite"

    private let pipelines: PipelineCache
    private var pipeline: MTLComputePipelineState?
    private var loggedNotBuilt = false
    private let log = Logger(subsystem: "BornlessRitual", category: "CompositePass")

    /// Creates the pass; the pipeline is built in `build`.
    init(pipelines: PipelineCache) {
        self.pipelines = pipelines
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        pipeline = try pipelines.compute("composite_main")
        loggedNotBuilt = false
    }

    func encode(_ ctx: FrameContext) {
        guard let pipeline = pipeline else {
            if !loggedNotBuilt {
                log.error("CompositePass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        let resources = ctx.resources
        let scene = ctx.scene

        guard let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            log.error("Could not create the composite compute encoder")
            return
        }
        encoder.label = pipelines.variant.debugView == .none ? "Composite" : "Composite (debug: \(pipelines.variant.debugView.displayName))"
        encoder.setComputePipelineState(pipeline)

        encoder.setBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setBuffer(scene.buffer(for: .froxelParams), offset: scene.offset(for: .froxelParams), index: BufferIndex.froxelParams.rawValue)

        encoder.setTexture(resources.texture(.gBufferAlbedo), index: TextureIndex.gBufferAlbedo.rawValue)
        encoder.setTexture(resources.texture(.gBufferNormal), index: TextureIndex.gBufferNormal.rawValue)
        encoder.setTexture(resources.texture(.gBufferEmissive), index: TextureIndex.gBufferEmissive.rawValue)
        encoder.setTexture(resources.texture(.gBufferMotion), index: TextureIndex.gBufferMotion.rawValue)
        encoder.setTexture(resources.texture(.depth), index: TextureIndex.depth.rawValue)
        encoder.setTexture(resources.texture(.directDiffuse), index: TextureIndex.directDiffuse.rawValue)
        encoder.setTexture(resources.texture(.directSpecular), index: TextureIndex.directSpecular.rawValue)
        encoder.setTexture(resources.texture(.reflection), index: TextureIndex.reflection.rawValue)
        encoder.setTexture(resources.texture(.sssDiffuse), index: TextureIndex.sssDiffuse.rawValue)
        encoder.setTexture(resources.texture(.moments), index: TextureIndex.moments.rawValue)
        encoder.setTexture(resources.texture(.froxelScatter), index: TextureIndex.froxelScatter.rawValue)
        encoder.setTexture(resources.texture(.hdrColor), index: TextureIndex.hdrColor.rawValue)
        encoder.setTexture(resources.texture(.heat), index: TextureIndex.heat.rawValue)

        let grid = MTLSize(width: resources.renderSize.width, height: resources.renderSize.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: FrameContext.threadgroup8x8)
        encoder.endEncoding()
    }
}
