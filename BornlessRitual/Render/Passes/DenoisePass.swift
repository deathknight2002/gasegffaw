//
//  DenoisePass.swift
//  Bornless Ritual — SVGF-style denoise pass (RENDER_CONTRACT §2 row 5 "DenoisePass",
//  §1 `RenderPass`; ARCHITECTURE §6 warm-up accumulation; Shaders/Denoise.metal
//  `denoise_temporal` + `denoise_atrous`).
//
//  Role: one temporal dispatch (reprojection + moments, in place on DirectDiffuse /
//  DirectSpecular / Reflection, moments into TextureIndexMoments) followed by three
//  à-trous dispatches (step 1, 2, 4) that ping-pong
//      Direct* → scratch → History* → Direct*
//  so the final filtered signal lands back in Direct*, which `RenderResources.swapHistory()`
//  turns into next frame's History*. The scratch trio (rgba16Float, render size) is
//  owned here and recreated on resize. Denoise.metal's binding scheme: the à-trous
//  INPUT is always bound at the TextureIndexDirect* slots and its OUTPUT at the
//  TextureIndexHistory* slots, whichever textures currently play those roles; the
//  previous frame's moments (`RenderResources.momentsHistory`, no TextureIndex of its
//  own) are bound at slot `momentsHistoryTextureSlot` (28).
//
//  Pipelines: five specialisations of the shared function constants (0–2, from the
//  cache's `PipelineVariant`) plus the pass-local ones declared in Denoise.metal —
//  3 `kDenoiseWarmup` (bool), 4 `kDenoiseStep` (uint), 5 `kDenoiseFinal` (bool):
//  temporal ×2 (live / warm-up) and à-trous ×3. The warm-up variant is chosen per frame
//  from `FrameContext.isWarmup` (no motion, alpha = 1/(k+1)).
//
//  Debug views: for `DebugView.directDiffuse` / `.directSpecular` ("noisy") the pass
//  encodes nothing so CompositePass shows the raw one-sample estimates. `build` always
//  resets the temporal history: the Renderer creates fresh pass instances on every
//  rebuild, and a rebuild that is not already accompanied by a reset (a MetalFX or
//  debug-view change) leaves history that is stale for the new variant — after skipped
//  frames the alpha channels hold visibility / light distance, which the temporal
//  kernel would read as μ2. The reset costs one frame without reprojection.
//

import Foundation
import Metal
import os

/// Temporal accumulation + 3 à-trous iterations over diffuse, specular and reflection.
final class DenoisePass: RenderPass {

    // MARK: Configuration

    let name = "Denoise"

    /// Texture slot of the previous frame's moments (`DENOISE_TEXTURE_SLOT_MOMENTS_HISTORY`
    /// in Denoise.metal; outside the `TextureIndex` enum, which has no entry for it).
    static let momentsHistoryTextureSlot = 28

    /// Pass-local function-constant indices (Denoise.metal; 0–2 are the shared ones).
    enum LocalFunctionConstant: Int {
        /// `constant bool kDenoiseWarmup [[function_constant(3)]]`
        case warmup = 3
        /// `constant uint kDenoiseStep [[function_constant(4)]]`
        case step = 4
        /// `constant bool kDenoiseFinal [[function_constant(5)]]`
        case final = 5
    }

    /// À-trous step sizes in pixels, in dispatch order (the last one is the final iteration).
    static let atrousSteps: [UInt32] = [1, 2, 4]

    /// Debug views for which the pass leaves the raw lighting untouched.
    static func skipsDenoising(for debugView: DebugView) -> Bool {
        debugView == .directDiffuse || debugView == .directSpecular
    }

    // MARK: State

    private let pipelines: PipelineCache
    private var temporalLive: MTLComputePipelineState?
    private var temporalWarmup: MTLComputePipelineState?
    private var atrous: [MTLComputePipelineState] = []
    private var scratch: [MTLTexture] = []
    private var scratchSize = MTLSize(width: 0, height: 0, depth: 0)
    private var skipping = false
    private var loggedNotBuilt = false
    private let log = Logger(subsystem: "BornlessRitual", category: "DenoisePass")

    // MARK: Init

    /// Creates the pass; pipelines and scratch textures are built in `build`.
    init(pipelines: PipelineCache) {
        self.pipelines = pipelines
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        skipping = DenoisePass.skipsDenoising(for: pipelines.variant.debugView)
        // A rebuild means a new variant (or size / path, which the Renderer has already
        // reset): start the accumulation over so no stale-variant history is blended in.
        resources.resetHistory()

        temporalLive = try pipelines.compute("denoise_temporal", constants: makeConstants(warmup: false, step: 1, final: false))
        temporalWarmup = try pipelines.compute("denoise_temporal", constants: makeConstants(warmup: true, step: 1, final: false))
        var atrousStates: [MTLComputePipelineState] = []
        for (iteration, step) in DenoisePass.atrousSteps.enumerated() {
            let isFinal = iteration == DenoisePass.atrousSteps.count - 1
            let state = try pipelines.compute("denoise_atrous", constants: makeConstants(warmup: false, step: step, final: isFinal))
            atrousStates.append(state)
        }
        atrous = atrousStates
        try ensureScratch(device: device, size: resources.renderSize)
        loggedNotBuilt = false
    }

    func encode(_ ctx: FrameContext) {
        if skipping {
            return
        }
        guard let temporal = ctx.isWarmup ? temporalWarmup : temporalLive,
              atrous.count == DenoisePass.atrousSteps.count,
              scratch.count == 3 else {
            if !loggedNotBuilt {
                log.error("DenoisePass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        let resources = ctx.resources
        if !RenderResources.sizesEqual(scratchSize, resources.renderSize) {
            // `build` is called again on resize; if it has not run yet, refuse rather than filter garbage.
            log.warning("DenoisePass scratch size does not match the render size; skipping this frame")
            return
        }

        encodeTemporal(ctx, pipeline: temporal)
        encodeAtrous(ctx)
    }

    // MARK: - Encoding

    /// Reprojection + moments, in place on the Direct* textures.
    private func encodeTemporal(_ ctx: FrameContext, pipeline: MTLComputePipelineState) {
        let resources = ctx.resources
        guard let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            log.error("Could not create the denoise temporal compute encoder")
            return
        }
        encoder.label = ctx.isWarmup ? "Denoise temporal (warm-up)" : "Denoise temporal"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)

        encoder.setTexture(resources.texture(.depth), index: TextureIndex.depth.rawValue)
        encoder.setTexture(resources.texture(.prevDepth), index: TextureIndex.prevDepth.rawValue)
        encoder.setTexture(resources.texture(.gBufferNormal), index: TextureIndex.gBufferNormal.rawValue)
        encoder.setTexture(resources.texture(.prevNormal), index: TextureIndex.prevNormal.rawValue)
        encoder.setTexture(resources.texture(.gBufferMotion), index: TextureIndex.gBufferMotion.rawValue)
        encoder.setTexture(resources.texture(.directDiffuse), index: TextureIndex.directDiffuse.rawValue)
        encoder.setTexture(resources.texture(.directSpecular), index: TextureIndex.directSpecular.rawValue)
        encoder.setTexture(resources.texture(.reflection), index: TextureIndex.reflection.rawValue)
        encoder.setTexture(resources.texture(.historyDiffuse), index: TextureIndex.historyDiffuse.rawValue)
        encoder.setTexture(resources.texture(.historySpecular), index: TextureIndex.historySpecular.rawValue)
        encoder.setTexture(resources.texture(.historyReflection), index: TextureIndex.historyReflection.rawValue)
        encoder.setTexture(resources.momentsHistory, index: DenoisePass.momentsHistoryTextureSlot)
        encoder.setTexture(resources.texture(.moments), index: TextureIndex.moments.rawValue)

        encoder.dispatchThreads(DenoisePass.grid(resources), threadsPerThreadgroup: FrameContext.threadgroup8x8)
        encoder.endEncoding()
    }

    /// Three à-trous iterations ping-ponging Direct* → scratch → History* → Direct*.
    /// Dispatches in one serial compute encoder see each other's writes in order.
    private func encodeAtrous(_ ctx: FrameContext) {
        let resources = ctx.resources
        let direct: [MTLTexture] = [resources.texture(.directDiffuse), resources.texture(.directSpecular), resources.texture(.reflection)]
        let history: [MTLTexture] = [resources.texture(.historyDiffuse), resources.texture(.historySpecular), resources.texture(.historyReflection)]
        let chain: [(input: [MTLTexture], output: [MTLTexture])] = [
            (direct, scratch),
            (scratch, history),
            (history, direct),
        ]

        guard let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            log.error("Could not create the denoise à-trous compute encoder")
            return
        }
        encoder.label = "Denoise à-trous ×\(DenoisePass.atrousSteps.count)"
        encoder.setBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setTexture(resources.texture(.depth), index: TextureIndex.depth.rawValue)
        encoder.setTexture(resources.texture(.gBufferNormal), index: TextureIndex.gBufferNormal.rawValue)
        encoder.setTexture(resources.texture(.moments), index: TextureIndex.moments.rawValue)

        let inputSlots: [Int] = [TextureIndex.directDiffuse.rawValue, TextureIndex.directSpecular.rawValue, TextureIndex.reflection.rawValue]
        let outputSlots: [Int] = [TextureIndex.historyDiffuse.rawValue, TextureIndex.historySpecular.rawValue, TextureIndex.historyReflection.rawValue]
        let grid = DenoisePass.grid(resources)
        for (iteration, pipeline) in atrous.enumerated() {
            let stage = chain[iteration]
            encoder.setComputePipelineState(pipeline)
            for signal in 0..<3 {
                encoder.setTexture(stage.input[signal], index: inputSlots[signal])
                encoder.setTexture(stage.output[signal], index: outputSlots[signal])
            }
            encoder.dispatchThreads(grid, threadsPerThreadgroup: FrameContext.threadgroup8x8)
        }
        encoder.endEncoding()
    }

    // MARK: - Helpers

    /// Shared constants (render path, MetalFX, debug view) plus the pass-local ones.
    private func makeConstants(warmup: Bool, step: UInt32, final: Bool) -> MTLFunctionConstantValues {
        let values = pipelines.variant.makeConstantValues()
        var warmupValue: Bool = warmup
        var stepValue: UInt32 = step
        var finalValue: Bool = final
        values.setConstantValue(&warmupValue, type: .bool, index: LocalFunctionConstant.warmup.rawValue)
        values.setConstantValue(&stepValue, type: .uint, index: LocalFunctionConstant.step.rawValue)
        values.setConstantValue(&finalValue, type: .bool, index: LocalFunctionConstant.final.rawValue)
        return values
    }

    /// (Re)creates the three scratch textures when the render size changed.
    private func ensureScratch(device: MTLDevice, size: MTLSize) throws {
        if scratch.count == 3 && RenderResources.sizesEqual(scratchSize, size) {
            return
        }
        var textures: [MTLTexture] = []
        for label in ["DenoiseScratchDiffuse", "DenoiseScratchSpecular", "DenoiseScratchReflection"] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                      width: max(size.width, 1),
                                                                      height: max(size.height, 1),
                                                                      mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RenderResourceError.textureCreationFailed(label)
            }
            texture.label = label
            textures.append(texture)
        }
        scratch = textures
        scratchSize = size
    }

    /// Exact dispatch grid over the internal resolution.
    private static func grid(_ resources: RenderResources) -> MTLSize {
        MTLSize(width: resources.renderSize.width, height: resources.renderSize.height, depth: 1)
    }
}
