//
//  ProceduralTexturePass.swift
//  Bornless Ritual — startup texture synthesis pass (RENDER_CONTRACT §2 row 1
//  "ProceduralTexturePass (once at startup)": seed → albedo/normal atlases (7 layers,
//  1024², mipmapped by blit), blue noise 128², chalk mask 2048²; §1 `RenderPass`;
//  Shaders/ProceduralTextures.metal `proctex_*` kernels; ARCHITECTURE §6 everything
//  derives from the seed).
//
//  Role: on the first frame (and again whenever the seed changes) encodes, in order:
//    1. `proctex_material` per MaterialTextureLayer → albedo atlas layer + a private
//       rgba32Float surface scratch (roughness, height, slope scale);
//    2. `proctex_normals` per layer → normal atlas layer (normal xy, roughness, height);
//    3. blit `generateMipmaps` for both atlases;
//    4. `proctex_bluenoise_init` + `blueNoiseIterations` × `proctex_bluenoise_swap`
//       ping-ponging between the blue-noise texture and a private 128² scratch (an even
//       iteration count leaves the result in TextureIndexBlueNoise);
//    5. `proctex_chalk` → chalk mask from the double circle plus a ChalkSegment buffer
//       built by HebrewStrokes (the daemon's name at the four quarters + tick marks).
//  Afterwards the pass is a no-op and releases its scratch textures.
//
//  Binding numbers (ShaderTypes.h enums only, as the contract requires): the surface
//  scratch is bound at TextureIndexHeat, the blue-noise ping-pong destination at
//  TextureIndexHDRColor and the chalk segments at BufferIndexSigilVertices; these are
//  binding slots, not the resources of those names. `ChalkGenParams` is a locally
//  defined struct mirrored in ProceduralTextures.metal (40 bytes, alignment 8).
//

import Foundation
import Metal
import simd
import RitualCore
import os

// MARK: - ChalkGenParams (mirrored in ProceduralTextures.metal)

/// Parameters of `proctex_chalk`. Layout: float2, 4 × float, 4 × uint (40 bytes, alignment 8).
struct ChalkGenParams {
    /// Floor half extents (3, 3): world (x, z) = (uv − 0.5) · 2 · halfExtents.
    var floorHalfExtents: SIMD2<Float>
    /// Inner circle radius (1.45 m).
    var innerRadius: Float
    /// Outer circle radius (1.60 m).
    var outerRadius: Float
    /// Stroke width of the circles in metres.
    var circleWidth: Float
    /// Edge softness / raggedness in metres.
    var edgeSoftness: Float
    /// Number of `ChalkSegment` entries bound.
    var segmentCount: UInt32
    /// Mask edge length (2048).
    var size: UInt32
    /// Seed words.
    var seedLo: UInt32
    var seedHi: UInt32
}

// MARK: - ProceduralTexturePass

/// Generates the procedural atlases, blue noise and chalk mask once.
final class ProceduralTexturePass: RenderPass {

    let name = "ProceduralTextures"

    // MARK: Tunables

    /// Swap passes of the blue-noise annealing (even, so the result lands in TextureIndexBlueNoise).
    static let blueNoiseIterations = 48
    /// Chalk circle stroke width in metres.
    static let chalkCircleWidth: Float = 0.016
    /// Chalk letter stroke width in metres.
    static let chalkLetterWidth: Float = 0.012
    /// Chalk edge softness in metres (≈ 1.5 texels of the 2048² mask over 6 m).
    static let chalkEdgeSoftness: Float = 0.0045

    // MARK: State

    private let pipelines: PipelineCache
    private let daemon: DaemonProfile
    private var materialPipeline: MTLComputePipelineState?
    private var normalsPipeline: MTLComputePipelineState?
    private var blueNoiseInitPipeline: MTLComputePipelineState?
    private var blueNoiseSwapPipeline: MTLComputePipelineState?
    private var chalkPipeline: MTLComputePipelineState?
    private var surfaceScratch: MTLTexture?
    private var blueNoiseScratch: MTLTexture?
    private var chalkSegmentBuffer: MTLBuffer?
    private var chalkSegmentCount = 0
    private var generatedSeed: UInt64?
    private var loggedNotBuilt = false
    private let log = Logger(subsystem: "BornlessRitual", category: "ProceduralTexturePass")

    /// Creates the pass. `daemon` supplies the name letters drawn in chalk (default: the owner's).
    init(pipelines: PipelineCache, daemon: DaemonProfile = .owner) {
        self.pipelines = pipelines
        self.daemon = daemon
    }

    /// Seed the current textures were generated for (nil before the first frame).
    var currentSeed: UInt64? { generatedSeed }

    /// Forces regeneration on the next frame.
    func invalidate() {
        generatedSeed = nil
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        // The kernels use no function constants; unspecialised pipelines are shared by every variant.
        materialPipeline = try pipelines.compute("proctex_material", variant: nil)
        normalsPipeline = try pipelines.compute("proctex_normals", variant: nil)
        blueNoiseInitPipeline = try pipelines.compute("proctex_bluenoise_init", variant: nil)
        blueNoiseSwapPipeline = try pipelines.compute("proctex_bluenoise_swap", variant: nil)
        chalkPipeline = try pipelines.compute("proctex_chalk", variant: nil)
        if chalkSegmentBuffer == nil {
            try buildChalkSegments(device: device)
        }
        loggedNotBuilt = false
        // Rebuilds after a resize / path change keep the generated textures (they are static).
    }

    func encode(_ ctx: FrameContext) {
        let seed = ctx.settings.seed
        if generatedSeed == seed {
            return
        }
        guard let materialPipeline = materialPipeline, let normalsPipeline = normalsPipeline,
              let blueNoiseInitPipeline = blueNoiseInitPipeline, let blueNoiseSwapPipeline = blueNoiseSwapPipeline,
              let chalkPipeline = chalkPipeline else {
            if !loggedNotBuilt {
                log.error("ProceduralTexturePass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        let device = ctx.resources.device
        do {
            if surfaceScratch == nil {
                surfaceScratch = try ProceduralTexturePass.makeScratch(device: device, label: "ProcTex surface scratch",
                                                                       format: .rgba32Float, size: RenderResources.atlasSize)
            }
            if blueNoiseScratch == nil {
                blueNoiseScratch = try ProceduralTexturePass.makeScratch(device: device, label: "ProcTex blue-noise scratch",
                                                                         format: .rgba8Unorm, size: RenderResources.blueNoiseSize)
            }
        } catch {
            log.error("Could not allocate scratch textures: \(String(describing: error), privacy: .public)")
            return
        }
        guard let surface = surfaceScratch, let noiseScratch = blueNoiseScratch else { return }

        let resources = ctx.resources
        let albedoAtlas = resources.texture(.albedoAtlas)
        let normalAtlas = resources.texture(.normalAtlas)
        let blueNoise = resources.texture(.blueNoise)
        let chalkMask = resources.texture(.chalkMask)
        let commandBuffer = ctx.commandBuffer

        // 1–2. Material atlases, one layer at a time.
        for layer in 0..<RenderResources.atlasLayerCount {
            var params = TextureGenParams()
            params.layer = UInt32(layer)
            params.size = UInt32(RenderResources.atlasSize)
            params.seedLo = seed.seedLo
            params.seedHi = seed.seedHi

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                log.error("Could not create the material atlas compute encoder")
                return
            }
            encoder.label = "ProcTex material layer \(layer)"
            encoder.setComputePipelineState(materialPipeline)
            encoder.setBytes(&params, length: MemoryLayout<TextureGenParams>.stride, index: BufferIndex.textureGenParams.rawValue)
            encoder.setTexture(albedoAtlas, index: TextureIndex.albedoAtlas.rawValue)
            encoder.setTexture(surface, index: TextureIndex.heat.rawValue)
            ProceduralTexturePass.dispatchSquare(encoder, size: RenderResources.atlasSize)

            encoder.setComputePipelineState(normalsPipeline)
            encoder.setBytes(&params, length: MemoryLayout<TextureGenParams>.stride, index: BufferIndex.textureGenParams.rawValue)
            encoder.setTexture(surface, index: TextureIndex.heat.rawValue)
            encoder.setTexture(normalAtlas, index: TextureIndex.normalAtlas.rawValue)
            ProceduralTexturePass.dispatchSquare(encoder, size: RenderResources.atlasSize)
            encoder.endEncoding()
        }

        // 3. Mip chains.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "ProcTex atlas mipmaps"
            blit.generateMipmaps(for: albedoAtlas)
            blit.generateMipmaps(for: normalAtlas)
            blit.endEncoding()
        } else {
            log.error("Could not create the mipmap blit encoder")
        }

        // 4. Blue noise: white noise, then deterministic swap passes (ping-pong).
        guard let noiseEncoder = commandBuffer.makeComputeCommandEncoder() else {
            log.error("Could not create the blue-noise compute encoder")
            return
        }
        noiseEncoder.label = "ProcTex blue noise"
        var noiseParams = TextureGenParams()
        noiseParams.layer = 0
        noiseParams.size = UInt32(RenderResources.blueNoiseSize)
        noiseParams.seedLo = seed.seedLo
        noiseParams.seedHi = seed.seedHi
        noiseEncoder.setComputePipelineState(blueNoiseInitPipeline)
        noiseEncoder.setBytes(&noiseParams, length: MemoryLayout<TextureGenParams>.stride, index: BufferIndex.textureGenParams.rawValue)
        noiseEncoder.setTexture(blueNoise, index: TextureIndex.blueNoise.rawValue)
        ProceduralTexturePass.dispatchSquare(noiseEncoder, size: RenderResources.blueNoiseSize)

        noiseEncoder.setComputePipelineState(blueNoiseSwapPipeline)
        let iterations = ProceduralTexturePass.blueNoiseIterations - (ProceduralTexturePass.blueNoiseIterations % 2)
        for iteration in 0..<iterations {
            noiseParams.layer = UInt32(iteration)
            let source = (iteration % 2 == 0) ? blueNoise : noiseScratch
            let destination = (iteration % 2 == 0) ? noiseScratch : blueNoise
            noiseEncoder.setBytes(&noiseParams, length: MemoryLayout<TextureGenParams>.stride, index: BufferIndex.textureGenParams.rawValue)
            noiseEncoder.setTexture(source, index: TextureIndex.blueNoise.rawValue)
            noiseEncoder.setTexture(destination, index: TextureIndex.hdrColor.rawValue)
            ProceduralTexturePass.dispatchSquare(noiseEncoder, size: RenderResources.blueNoiseSize)
        }
        noiseEncoder.endEncoding()

        // 5. Chalk mask.
        if let segments = chalkSegmentBuffer, let chalkEncoder = commandBuffer.makeComputeCommandEncoder() {
            chalkEncoder.label = "ProcTex chalk mask"
            var chalkParams = ChalkGenParams(floorHalfExtents: SIMD2<Float>(SceneLayout.chamberHalfExtents.x, SceneLayout.chamberHalfExtents.z),
                                             innerRadius: SceneLayout.chalkInnerRadius,
                                             outerRadius: SceneLayout.chalkOuterRadius,
                                             circleWidth: ProceduralTexturePass.chalkCircleWidth,
                                             edgeSoftness: ProceduralTexturePass.chalkEdgeSoftness,
                                             segmentCount: UInt32(chalkSegmentCount),
                                             size: UInt32(RenderResources.chalkMaskSize),
                                             seedLo: seed.seedLo,
                                             seedHi: seed.seedHi)
            chalkEncoder.setComputePipelineState(chalkPipeline)
            chalkEncoder.setBytes(&chalkParams, length: MemoryLayout<ChalkGenParams>.stride, index: BufferIndex.textureGenParams.rawValue)
            chalkEncoder.setBuffer(segments, offset: 0, index: BufferIndex.sigilVertices.rawValue)
            chalkEncoder.setTexture(chalkMask, index: TextureIndex.chalkMask.rawValue)
            ProceduralTexturePass.dispatchSquare(chalkEncoder, size: RenderResources.chalkMaskSize)
            chalkEncoder.endEncoding()
        } else {
            log.error("Chalk mask not generated (missing segment buffer or encoder)")
        }

        generatedSeed = seed
        // The scratch textures are only needed during generation; drop them once the
        // command buffer has been encoded (Metal keeps them alive until it completes).
        surfaceScratch = nil
        blueNoiseScratch = nil
        log.info("Procedural textures encoded for seed \(seed, privacy: .public) (\(self.chalkSegmentCount) chalk segments)")
    }

    // MARK: - Private

    /// Builds the chalk stroke buffer: the daemon's name at the four quarters plus tick marks.
    private func buildChalkSegments(device: MTLDevice) throws {
        let segments = HebrewStrokes.quarterNameSegments(letters: daemon.name.letters,
                                                         innerRadius: SceneLayout.chalkInnerRadius,
                                                         outerRadius: SceneLayout.chalkOuterRadius,
                                                         strokeWidth: ProceduralTexturePass.chalkLetterWidth)
        let byteCount = max(segments.count, 1) * MemoryLayout<ChalkSegment>.stride
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw RenderResourceError.bufferCreationFailed("ChalkSegments")
        }
        buffer.label = "ChalkSegments"
        if !segments.isEmpty {
            segments.withUnsafeBytes { raw in
                if let source = raw.baseAddress {
                    buffer.contents().copyMemory(from: source, byteCount: segments.count * MemoryLayout<ChalkSegment>.stride)
                }
            }
        }
        chalkSegmentBuffer = buffer
        chalkSegmentCount = segments.count
    }

    /// Private, compute-writable square scratch texture.
    private static func makeScratch(device: MTLDevice, label: String, format: MTLPixelFormat, size: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderResourceError.textureCreationFailed(label)
        }
        texture.label = label
        return texture
    }

    /// Dispatches `size × size` threads in 8×8 threadgroups (all sizes here are multiples of 8).
    private static func dispatchSquare(_ encoder: MTLComputeCommandEncoder, size: Int) {
        let groups = MTLSize(width: (size + 7) / 8, height: (size + 7) / 8, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: FrameContext.threadgroup8x8)
    }
}
