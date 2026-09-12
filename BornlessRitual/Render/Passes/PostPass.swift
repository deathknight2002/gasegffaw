//
//  PostPass.swift
//  Bornless Ritual — bloom / heat shimmer / exposure / tonemap pass (RENDER_CONTRACT §2
//  row 13 "PostPass (Post.metal) | compute ×3 | bloom … heat shimmer … exposure + ACES +
//  dither → Output", §1 `RenderPass`; Shaders/Post.metal `post_bloom_prefilter`,
//  `post_bloom_downsample`, `post_bloom_upsample`, `post_shimmer_tonemap`;
//  ShaderTypes.h `PostParams` at BufferIndexPostParams).
//
//  Role: the last GPU pass. One compute encoder per frame:
//    1. prefilter    Upscaled → D[0]            (native/2)
//    2. downsample   D[k] → D[k+1], k = 0…3     (down to native/32)
//    3. upsample     U[k] = D[k] + tent(U[k+1]), k = 3…0, with U[4] = D[4]
//    4. tonemap      Upscaled + U[0] + Heat + BlueNoise → Output (bgra8Unorm, sRGB-encoded
//                    in-shader; the Renderer blits Output into the drawable and reads it
//                    back for captures).
//  Steps 1–3 are skipped when bloom is off (intensity ≤ 0) or a debug view is active;
//  the tonemap kernel then never samples the bloom texture.
//
//  Bloom textures: the downsample chain D[0…4] lives in `RenderResources`' Bloom0
//  texture (rgba16Float, native/2, 5 mips) and the upsample chain U[0…3] in a private
//  4-mip texture allocated here on build / resize. Compute kernels write single levels,
//  so every level is bound through an `MTLTexture` mip view (`makeTextureView`), which is
//  supported on every iOS GPU (unlike `write(…, lod)` for lod > 0). Views are rebuilt
//  in `build` (the Renderer calls it on every resize); `encode` verifies the views still
//  belong to the current Bloom0 texture before using them.
//
//  Bindings use ROLE slots (Post.metal `POST_SLOT_*`, mirrored in `PostPass.Slot`):
//  every slot is a `TextureIndex` value, see the shader header for the mapping.
//  Threadgroups are 16×16 (RENDER_CONTRACT §2 "16×16 for post"), reduced if a pipeline
//  reports a smaller `maxTotalThreadsPerThreadgroup`.
//
//  `PostParams` (bloom intensity / threshold, shimmer pixels, vignette) are written by
//  SceneUpdater (another job) into the scene's triple-buffered `.postParams` slot from
//  the same settings snapshot this pass sees; exposure and frame index come from
//  `FrameUniforms`. An unwritten (all-zero) slot yields no bloom, no shimmer and no
//  vignette — the kernel substitutes threshold 1.0 only.
//

import Foundation
import Metal
import os

/// Errors raised while building the post pass.
enum PostPassError: Error, CustomStringConvertible {
    /// `RenderResources`' Bloom0 texture has fewer mip levels than the chain needs.
    case bloomChainTooShallow(levels: Int, required: Int)
    /// `MTLTexture.makeTextureView` returned nil.
    case textureViewCreationFailed(String)

    var description: String {
        switch self {
        case .bloomChainTooShallow(let levels, let required):
            return "Bloom0 has \(levels) mip levels; the bloom chain needs \(required)"
        case .textureViewCreationFailed(let label):
            return "Could not create the texture view '\(label)'"
        }
    }
}

/// Bloom (5-level) → heat shimmer → exposure → ACES → dither → sRGB → Output.
final class PostPass: RenderPass {

    // MARK: Configuration

    let name = "Post"

    /// Texture slots by role, mirrored from Post.metal (`POST_SLOT_*`); each is a `TextureIndex`.
    enum Slot {
        /// Native HDR colour (prefilter source, tonemap input): `TextureIndexUpscaled`.
        static let color = TextureIndex.upscaled.rawValue
        /// The finer bloom level read (downsample source, upsample additive input, final bloom): `TextureIndexBloom0`.
        static let fine = TextureIndex.bloom0.rawValue
        /// The coarser bloom level read by the upsample: `TextureIndexHDRColor`.
        static let coarse = TextureIndex.hdrColor.rawValue
        /// Whatever the kernel writes (a chain level, or Output): `TextureIndexOutput`.
        static let target = TextureIndex.output.rawValue
    }

    /// Downsample levels D[0…4] (RenderResources allocates Bloom0 with this many mips).
    static let bloomLevelCount = RenderResources.bloomMipLevels
    /// Upsample levels U[0…3] (U[4] is D[4] itself).
    static var upsampleLevelCount: Int { max(bloomLevelCount - 1, 1) }

    // MARK: State

    private let pipelines: PipelineCache
    private var prefilterPipeline: MTLComputePipelineState?
    private var downsamplePipeline: MTLComputePipelineState?
    private var upsamplePipeline: MTLComputePipelineState?
    private var tonemapPipeline: MTLComputePipelineState?

    /// The Bloom0 texture the down-level views were created from (identity check in `encode`).
    private var bloomBase: MTLTexture?
    /// Mip views of Bloom0, levels 0…4.
    private var downLevels: [MTLTexture] = []
    /// Private upsample chain (rgba16Float, native/2, 4 mips).
    private var bloomUp: MTLTexture?
    /// Mip views of `bloomUp`, levels 0…3.
    private var upLevels: [MTLTexture] = []

    private var debugViewActive = false
    private var loggedNotBuilt = false
    private var loggedStaleChain = false
    private let log = Logger(subsystem: "BornlessRitual", category: "PostPass")

    // MARK: Init

    /// Creates the pass; pipelines and bloom textures are built in `build`.
    init(pipelines: PipelineCache) {
        self.pipelines = pipelines
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        prefilterPipeline = try pipelines.compute("post_bloom_prefilter")
        downsamplePipeline = try pipelines.compute("post_bloom_downsample")
        upsamplePipeline = try pipelines.compute("post_bloom_upsample")
        tonemapPipeline = try pipelines.compute("post_shimmer_tonemap")
        try buildBloomChain(device: device, resources: resources)
        debugViewActive = pipelines.variant.debugView != .none
        loggedNotBuilt = false
        loggedStaleChain = false
    }

    func encode(_ ctx: FrameContext) {
        guard let prefilter = prefilterPipeline, let downsample = downsamplePipeline,
              let upsample = upsamplePipeline, let tonemap = tonemapPipeline else {
            if !loggedNotBuilt {
                log.error("PostPass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        let resources = ctx.resources
        let scene = ctx.scene

        let chainReady = isBloomChainCurrent(resources)
        if !chainReady && !loggedStaleChain {
            log.warning("Bloom chain views do not match the current Bloom0 texture; bloom disabled until rebuild")
            loggedStaleChain = true
        }
        let bloomEnabled = chainReady && !debugViewActive && ctx.settings.bloomIntensity > 0

        guard let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            log.error("Could not create the post compute encoder")
            return
        }
        encoder.label = debugViewActive ? "Post (debug: \(pipelines.variant.debugView.displayName))" : "Post"
        encoder.setBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setBuffer(scene.buffer(for: .postParams), offset: scene.offset(for: .postParams), index: BufferIndex.postParams.rawValue)

        if bloomEnabled {
            encodeBloom(encoder: encoder, resources: resources,
                        prefilter: prefilter, downsample: downsample, upsample: upsample)
        }

        // Tonemap: Upscaled + U[0] + Heat + BlueNoise → Output.
        encoder.setComputePipelineState(tonemap)
        encoder.setTexture(resources.texture(.upscaled), index: Slot.color)
        // Bound even when bloom is off: the kernel only samples it for intensity > 0,
        // which Swift and PostParams derive from the same settings snapshot.
        if let finalBloom = upLevels.first, chainReady {
            encoder.setTexture(finalBloom, index: Slot.fine)
        } else {
            encoder.setTexture(resources.texture(.bloom0), index: Slot.fine)
        }
        encoder.setTexture(resources.texture(.heat), index: TextureIndex.heat.rawValue)
        encoder.setTexture(resources.texture(.blueNoise), index: TextureIndex.blueNoise.rawValue)
        encoder.setTexture(resources.texture(.output), index: Slot.target)
        let outputGrid = MTLSize(width: resources.outputSize.width, height: resources.outputSize.height, depth: 1)
        encoder.dispatchThreads(outputGrid, threadsPerThreadgroup: PostPass.threadgroupSize(for: tonemap))
        encoder.endEncoding()
    }

    // MARK: - Bloom encoding

    /// Prefilter, four downsamples and four additive upsamples, in dispatch order.
    /// Dispatches in one compute encoder see each other's writes in order; every
    /// dispatch reads and writes distinct mip levels.
    private func encodeBloom(encoder: MTLComputeCommandEncoder, resources: RenderResources,
                             prefilter: MTLComputePipelineState, downsample: MTLComputePipelineState,
                             upsample: MTLComputePipelineState) {
        let levelCount = downLevels.count
        guard levelCount >= 2, upLevels.count == levelCount - 1 else { return }

        // 1. Prefilter: Upscaled → D[0].
        encoder.setComputePipelineState(prefilter)
        encoder.setTexture(resources.texture(.upscaled), index: Slot.color)
        encoder.setTexture(downLevels[0], index: Slot.target)
        encoder.dispatchThreads(PostPass.grid(downLevels[0]), threadsPerThreadgroup: PostPass.threadgroupSize(for: prefilter))

        // 2. Downsample chain: D[k] → D[k+1].
        encoder.setComputePipelineState(downsample)
        let downsampleThreadgroup = PostPass.threadgroupSize(for: downsample)
        for level in 0..<(levelCount - 1) {
            encoder.setTexture(downLevels[level], index: Slot.fine)
            encoder.setTexture(downLevels[level + 1], index: Slot.target)
            encoder.dispatchThreads(PostPass.grid(downLevels[level + 1]), threadsPerThreadgroup: downsampleThreadgroup)
        }

        // 3. Upsample chain: U[k] = D[k] + tent(U[k+1]), starting from U[4] = D[4].
        encoder.setComputePipelineState(upsample)
        let upsampleThreadgroup = PostPass.threadgroupSize(for: upsample)
        var coarse: MTLTexture = downLevels[levelCount - 1]
        for level in stride(from: levelCount - 2, through: 0, by: -1) {
            encoder.setTexture(downLevels[level], index: Slot.fine)
            encoder.setTexture(coarse, index: Slot.coarse)
            encoder.setTexture(upLevels[level], index: Slot.target)
            encoder.dispatchThreads(PostPass.grid(upLevels[level]), threadsPerThreadgroup: upsampleThreadgroup)
            coarse = upLevels[level]
        }
    }

    // MARK: - Bloom chain textures

    /// (Re)creates the mip views of Bloom0 and the private upsample chain for the current sizes.
    private func buildBloomChain(device: MTLDevice, resources: RenderResources) throws {
        let base = resources.texture(.bloom0)
        let required = PostPass.bloomLevelCount
        guard base.mipmapLevelCount >= required else {
            throw PostPassError.bloomChainTooShallow(levels: base.mipmapLevelCount, required: required)
        }

        var down: [MTLTexture] = []
        for level in 0..<required {
            let view = try PostPass.makeLevelView(of: base, level: level, label: "Bloom down \(level)")
            down.append(view)
        }

        let upCount = PostPass.upsampleLevelCount
        let upTexture: MTLTexture
        if let existing = bloomUp, existing.width == base.width, existing.height == base.height,
           existing.mipmapLevelCount == upCount, existing.pixelFormat == base.pixelFormat {
            upTexture = existing
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: base.pixelFormat,
                                                                      width: max(base.width, 1),
                                                                      height: max(base.height, 1),
                                                                      mipmapped: true)
            descriptor.mipmapLevelCount = upCount
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let created = device.makeTexture(descriptor: descriptor) else {
                throw RenderResourceError.textureCreationFailed("BloomUpsample")
            }
            created.label = "BloomUpsample"
            upTexture = created
        }
        var up: [MTLTexture] = []
        for level in 0..<upCount {
            let view = try PostPass.makeLevelView(of: upTexture, level: level, label: "Bloom up \(level)")
            up.append(view)
        }

        bloomBase = base
        downLevels = down
        bloomUp = upTexture
        upLevels = up
    }

    /// True when the level views were created from the Bloom0 texture currently in `resources`.
    private func isBloomChainCurrent(_ resources: RenderResources) -> Bool {
        guard let base = bloomBase, downLevels.count == PostPass.bloomLevelCount,
              upLevels.count == PostPass.upsampleLevelCount else {
            return false
        }
        return base === resources.texture(.bloom0)
    }

    /// A single-mip 2D view of `texture` at `level`.
    private static func makeLevelView(of texture: MTLTexture, level: Int, label: String) throws -> MTLTexture {
        guard let view = texture.makeTextureView(pixelFormat: texture.pixelFormat,
                                                 textureType: .type2D,
                                                 levels: level..<(level + 1),
                                                 slices: 0..<1) else {
            throw PostPassError.textureViewCreationFailed(label)
        }
        view.label = label
        return view
    }

    // MARK: - Dispatch helpers

    /// Exact grid covering a level view.
    private static func grid(_ texture: MTLTexture) -> MTLSize {
        MTLSize(width: max(texture.width, 1), height: max(texture.height, 1), depth: 1)
    }

    /// 16×16 (RENDER_CONTRACT §2 "16×16 for post"), halved in height while the pipeline
    /// cannot hold that many threads per threadgroup.
    private static func threadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        var size = FrameContext.threadgroup16x16
        let maxTotal = max(pipeline.maxTotalThreadsPerThreadgroup, 1)
        while size.width * size.height > maxTotal && size.height > 1 {
            size.height /= 2
        }
        while size.width * size.height > maxTotal && size.width > 1 {
            size.width /= 2
        }
        return size
    }
}
