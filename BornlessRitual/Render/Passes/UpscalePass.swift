//
//  UpscalePass.swift
//  Bornless Ritual — temporal upscaling pass (RENDER_CONTRACT §2 row 12 "UpscalePass
//  (Upscale.swift, TAA.metal) | MetalFX or compute", §1 `RenderPass`, §3 motion vectors
//  & jitter; ARCHITECTURE §6 warm-up / history reset; Shaders/TAA.metal `taa_resolve`).
//
//  Role: turns the internal-resolution HDRColor into the native-resolution Upscaled.
//  When the pipeline variant asks for MetalFX and `MTLFXTemporalScalerDescriptor
//  .supportsDevice` is true, an `MTLFXTemporalScaler` is created in `build` for the
//  current (renderSize, outputSize) and encoded every frame with HDRColor / Depth /
//  GBufferMotion → Upscaled; otherwise (unsupported device, or MetalFX switched off in
//  the debug panel, or the scaler failed to initialise) the custom TAA-upsample kernel
//  `taa_resolve` runs at native resolution with 8×8 threadgroups, using PrevHDR as its
//  history (RenderResources rotates Upscaled ↔ PrevHDR in `swapHistory()`).
//
//  MetalFX conventions used here:
//    · jitterOffsetX/Y are in INPUT pixels and are the sub-pixel position of the sample
//      relative to the pixel centre, texture space (x right, y down). UniformBuilder's
//      jitter satisfies ndc = unjitteredNDC + jitter with jitter = (2px/W, −2py/H), i.e.
//      the image is shifted by +px in texture space, so a pixel centre sampled the scene
//      at centre − px → jitterOffset = −px. `px` is recovered from `FrameUniforms.jitter`
//      (never from frameIndex) so the projection and the scaler cannot disagree; the
//      sign lives in one place (`metalFXJitterSign`) for a one-line flip if a device
//      check shows Apple's convention is the opposite (see caveats).
//    · motionVectorScaleX/Y = 1: GBuffer.metal writes motion in input-pixel units,
//      pointing from the current pixel to its previous position (contract §3).
//    · reset = !historyValid (after seek / path change / resize), isDepthReversed = true,
//      auto-exposure off, preExposure 1 (PostPass applies exposure).
//  Resource usage: HDRColor / Depth / GBufferMotion carry `.shaderRead`, Upscaled carries
//  `.shaderWrite` and `.renderTarget` (RenderResources), which is what the scaler needs.
//
//  `build` resets the temporal history: the Renderer creates fresh pass instances on
//  every rebuild, and a MetalFX toggle rebuilds without resetting, which would otherwise
//  hand a brand-new scaler (or the TAA kernel) a history it never produced.
//

import Foundation
import Metal
import MetalFX
import os

/// MetalFX temporal upscaling with a custom TAA-upsample fallback → Upscaled.
final class UpscalePass: RenderPass {

    // MARK: Configuration

    let name = "Upscale"

    /// Sign applied to the texture-space pixel jitter `px` when handing it to MetalFX
    /// (`jitterOffset = metalFXJitterSign · px`); −1 per the derivation in the header.
    static let metalFXJitterSign: Float = -1

    // MARK: State

    private let pipelines: PipelineCache
    private let capabilities: CapabilityProbe
    private var scaler: MTLFXTemporalScaler?
    private var scalerInputSize = MTLSize(width: 0, height: 0, depth: 0)
    private var scalerOutputSize = MTLSize(width: 0, height: 0, depth: 0)
    private var taaPipeline: MTLComputePipelineState?
    private var loggedNotBuilt = false
    private var loggedScalerSizeMismatch = false
    private let log = Logger(subsystem: "BornlessRitual", category: "UpscalePass")

    /// True when the MetalFX scaler is the active path (debug panel readout).
    private(set) var usesMetalFX = false

    // MARK: Init

    /// Creates the pass; the scaler and the fallback pipeline are built in `build`.
    ///
    /// - Parameters:
    ///   - pipelines: The shared pipeline cache (its `variant.metalFX` selects the path).
    ///   - capabilities: Device probe (`supportsMetalFXTemporal`).
    init(pipelines: PipelineCache, capabilities: CapabilityProbe) {
        self.pipelines = pipelines
        self.capabilities = capabilities
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        // A rebuild means a new variant, size or path: neither the new scaler nor the TAA
        // kernel has produced the history that PrevHDR / the scaler would otherwise reuse.
        resources.resetHistory()

        // The fallback kernel is always built so a scaler failure never leaves Upscaled unwritten.
        taaPipeline = try pipelines.compute("taa_resolve")

        scaler = nil
        usesMetalFX = false
        let wantsMetalFX = pipelines.variant.metalFX && capabilities.supportsMetalFXTemporal
        if wantsMetalFX {
            if let made = makeScaler(device: device, renderSize: resources.renderSize, outputSize: resources.outputSize) {
                scaler = made
                scalerInputSize = resources.renderSize
                scalerOutputSize = resources.outputSize
                usesMetalFX = true
                log.info("MetalFX temporal scaler \(resources.renderSize.width)×\(resources.renderSize.height) → \(resources.outputSize.width)×\(resources.outputSize.height)")
            } else {
                log.error("MTLFXTemporalScalerDescriptor.makeTemporalScaler returned nil; using the TAA fallback")
            }
        } else {
            log.info("Upscale path: TAA fallback (\(self.capabilities.supportsMetalFXTemporal ? "MetalFX disabled" : "MetalFX unsupported", privacy: .public))")
        }
        loggedNotBuilt = false
        loggedScalerSizeMismatch = false
    }

    func encode(_ ctx: FrameContext) {
        if usesMetalFX, let scaler = scaler {
            let resources = ctx.resources
            if RenderResources.sizesEqual(resources.renderSize, scalerInputSize)
                && RenderResources.sizesEqual(resources.outputSize, scalerOutputSize) {
                encodeMetalFX(ctx, scaler: scaler)
                return
            }
            // `build` runs again on resize; until then the fallback keeps Upscaled valid.
            if !loggedScalerSizeMismatch {
                log.warning("MetalFX scaler size does not match the current textures; using the TAA fallback until rebuild")
                loggedScalerSizeMismatch = true
            }
        }
        encodeTAA(ctx)
    }

    // MARK: - MetalFX

    /// Creates the temporal scaler for the given sizes (nil when MetalFX refuses).
    private func makeScaler(device: MTLDevice, renderSize: MTLSize, outputSize: MTLSize) -> MTLFXTemporalScaler? {
        let descriptor = MTLFXTemporalScalerDescriptor()
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.depthTextureFormat = .depth32Float
        descriptor.motionTextureFormat = .rg16Float
        descriptor.outputTextureFormat = .rgba16Float
        descriptor.inputWidth = max(renderSize.width, 1)
        descriptor.inputHeight = max(renderSize.height, 1)
        descriptor.outputWidth = max(outputSize.width, 1)
        descriptor.outputHeight = max(outputSize.height, 1)
        descriptor.isAutoExposureEnabled = false
        descriptor.requiresSynchronousInitialization = false

        guard let scaler = descriptor.makeTemporalScaler(device: device) else {
            return nil
        }
        scaler.inputContentWidth = max(renderSize.width, 1)
        scaler.inputContentHeight = max(renderSize.height, 1)
        scaler.motionVectorScaleX = 1
        scaler.motionVectorScaleY = 1
        scaler.isDepthReversed = true
        scaler.preExposure = 1
        return scaler
    }

    /// Binds this frame's textures and jitter and encodes the scaler.
    private func encodeMetalFX(_ ctx: FrameContext, scaler: MTLFXTemporalScaler) {
        let resources = ctx.resources
        let uniforms = ctx.uniforms

        // Texture-space pixel jitter recovered from the NDC jitter (see header).
        let jitterPixels = SIMD2<Float>(uniforms.jitter.x * uniforms.renderSize.x * 0.5,
                                        -uniforms.jitter.y * uniforms.renderSize.y * 0.5)

        scaler.colorTexture = resources.texture(.hdrColor)
        scaler.depthTexture = resources.texture(.depth)
        scaler.motionTexture = resources.texture(.gBufferMotion)
        scaler.outputTexture = resources.texture(.upscaled)
        scaler.jitterOffsetX = UpscalePass.metalFXJitterSign * jitterPixels.x
        scaler.jitterOffsetY = UpscalePass.metalFXJitterSign * jitterPixels.y
        scaler.motionVectorScaleX = 1
        scaler.motionVectorScaleY = 1
        scaler.reset = !ctx.historyValid
        scaler.isDepthReversed = true
        scaler.encode(commandBuffer: ctx.commandBuffer)
    }

    // MARK: - TAA fallback

    /// Dispatches `taa_resolve` over the native resolution.
    private func encodeTAA(_ ctx: FrameContext) {
        guard let pipeline = taaPipeline else {
            if !loggedNotBuilt {
                log.error("UpscalePass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        let resources = ctx.resources
        guard let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            log.error("Could not create the TAA compute encoder")
            return
        }
        encoder.label = ctx.historyValid ? "TAA upsample" : "TAA upsample (history reset)"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)

        encoder.setTexture(resources.texture(.hdrColor), index: TextureIndex.hdrColor.rawValue)
        encoder.setTexture(resources.texture(.depth), index: TextureIndex.depth.rawValue)
        encoder.setTexture(resources.texture(.gBufferMotion), index: TextureIndex.gBufferMotion.rawValue)
        encoder.setTexture(resources.texture(.prevHDR), index: TextureIndex.prevHDR.rawValue)
        encoder.setTexture(resources.texture(.upscaled), index: TextureIndex.upscaled.rawValue)

        let grid = MTLSize(width: resources.outputSize.width, height: resources.outputSize.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: FrameContext.threadgroup8x8)
        encoder.endEncoding()
    }
}
