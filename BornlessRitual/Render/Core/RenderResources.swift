//
//  RenderResources.swift
//  Bornless Ritual — owns every texture in `TextureIndex` (RENDER_CONTRACT §1/§2).
//
//  Role: creates the G-buffer, lighting, history, froxel, post and procedural
//  textures for a (renderSize, outputSize) pair, resizes them, swaps current↔history
//  references at frame end and resets history after seeks / path changes.
//
//  Output format decision: `TextureIndexOutput` is `bgra8Unorm`, NOT `bgra8Unorm_srgb`.
//  sRGB pixel formats cannot be bound as compute `access::write` textures on iOS
//  (they are not in the shader-write capability set for Apple GPUs), and the tonemap
//  kernel is a compute pass. It therefore encodes sRGB manually
//  (`linear_to_srgb` in Common.h) and writes to a linear bgra8Unorm texture, which the
//  Renderer blits into an `MTKView` whose `colorPixelFormat` is `.bgra8Unorm`. The
//  bytes are still sRGB-encoded, so the display and the PNG readback look identical
//  to what a `_srgb` drawable would have shown. (RENDER_CONTRACT names `_srgb`; this
//  file supersedes that detail and the deviation is recorded in the caveats.)
//
//  All textures are `.private`; storage textures written by compute carry
//  `.shaderWrite`. History pairs share a usage set so they can be swapped by reference.
//

import Foundation
import Metal
import os

/// Errors raised while allocating GPU resources.
enum RenderResourceError: Error, CustomStringConvertible {
    /// `MTLDevice.makeTexture` returned nil.
    case textureCreationFailed(String)
    /// `MTLDevice.makeBuffer` returned nil.
    case bufferCreationFailed(String)

    var description: String {
        switch self {
        case .textureCreationFailed(let label): return "Could not create texture '\(label)'"
        case .bufferCreationFailed(let label): return "Could not create buffer '\(label)'"
        }
    }
}

/// Texture ownership for the frame graph.
final class RenderResources {

    // MARK: Constants

    /// Pixel format of `TextureIndexOutput` and of the MTKView drawable (see header).
    static let outputPixelFormat: MTLPixelFormat = .bgra8Unorm
    /// Froxel grid (RENDER_CONTRACT §2: 160×90×64).
    static let froxelSize = MTLSize(width: Int(FROXEL_X), height: Int(FROXEL_Y), depth: Int(FROXEL_Z))
    /// Procedural material atlas edge length.
    static let atlasSize = 1024
    /// Atlas layer count (`MaterialTextureLayerCount` in ShaderTypes.h).
    static let atlasLayerCount = 7
    /// Mip levels of a 1024² atlas (1024 → 1).
    static let atlasMipLevels = 11
    /// Blue-noise tile edge length.
    static let blueNoiseSize = 128
    /// Chalk decal mask edge length.
    static let chalkMaskSize = 2048
    /// Bloom chain mip count (base level at outputSize / 2).
    static let bloomMipLevels = 5

    /// Every `TextureIndex`, in declaration order (the imported enum is not CaseIterable).
    static let allIndices: [TextureIndex] = [
        .gBufferAlbedo, .gBufferNormal, .gBufferMotion, .gBufferEmissive, .depth,
        .directDiffuse, .directSpecular, .reflection,
        .historyDiffuse, .historySpecular, .historyReflection, .prevDepth, .prevNormal,
        .moments, .froxelScatter, .froxelLighting, .froxelHistory,
        .hdrColor, .heat, .upscaled, .bloom0, .output,
        .albedoAtlas, .normalAtlas, .blueNoise, .sssDiffuse, .prevHDR, .chalkMask,
    ]

    /// (current, history) pairs exchanged by `swapHistory()`.
    static let historyPairs: [(current: TextureIndex, history: TextureIndex)] = [
        (.directDiffuse, .historyDiffuse),
        (.directSpecular, .historySpecular),
        (.reflection, .historyReflection),
        (.depth, .prevDepth),
        (.gBufferNormal, .prevNormal),
        (.froxelLighting, .froxelHistory),
        (.upscaled, .prevHDR),
    ]

    /// Indices whose textures depend on `renderSize` or `outputSize` (recreated on resize).
    private static let sizedIndices: Set<TextureIndex> = Set(allIndices).subtracting(staticIndices)
    /// Indices created once at startup (procedural content, size-independent).
    private static let staticIndices: Set<TextureIndex> = [.albedoAtlas, .normalAtlas, .blueNoise, .chalkMask]

    // MARK: State

    /// The device every texture belongs to.
    let device: MTLDevice
    /// Internal render resolution.
    private(set) var renderSize: MTLSize
    /// Native (drawable) resolution.
    private(set) var outputSize: MTLSize
    /// False after `resetHistory()` until the next `swapHistory()`.
    private(set) var historyValid: Bool = false
    /// Set by `resetHistory()`; consumed by `encodeHistoryClearIfNeeded(_:)`.
    private(set) var needsHistoryClear: Bool = true
    /// Previous-frame SVGF moments (companion of `.moments`; swapped with it).
    private(set) var momentsHistory: MTLTexture

    private var textures: [TextureIndex: MTLTexture] = [:]
    private let log = Logger(subsystem: "BornlessRitual", category: "RenderResources")

    // MARK: Init

    /// Creates every texture for the given sizes.
    ///
    /// - Parameters:
    ///   - device: The Metal device.
    ///   - renderSize: Internal resolution (`round(native × renderScale)`).
    ///   - outputSize: Native drawable resolution.
    /// - Throws: `RenderResourceError.textureCreationFailed` if any allocation fails.
    init(device: MTLDevice, renderSize: MTLSize, outputSize: MTLSize) throws {
        self.device = device
        self.renderSize = RenderResources.clampedSize(renderSize)
        self.outputSize = RenderResources.clampedSize(outputSize)
        self.momentsHistory = try RenderResources.makeTexture(device: device, label: "MomentsHistory",
                                                              format: .rgba16Float,
                                                              width: self.renderSize.width, height: self.renderSize.height,
                                                              usage: [.shaderRead, .shaderWrite, .renderTarget])
        for index in RenderResources.staticIndices {
            textures[index] = try makeStaticTexture(index)
        }
        for index in RenderResources.sizedIndices {
            textures[index] = try makeSizedTexture(index, renderSize: self.renderSize, outputSize: self.outputSize)
        }
    }

    // MARK: Contract API

    /// The texture currently bound to `index` (history pairs rotate every frame).
    ///
    /// Invariant: `init` populates every `TextureIndex` and `resize` only replaces
    /// entries, so the lookup cannot fail once construction succeeded.
    func texture(_ index: TextureIndex) -> MTLTexture {
        guard let texture = textures[index] else {
            fatalError("RenderResources invariant violated: no texture for TextureIndex \(index.rawValue)")
        }
        return texture
    }

    /// Recreates the size-dependent textures. No-op when both sizes are unchanged.
    /// On an allocation failure the previous textures are kept and the error is logged.
    func resize(renderSize newRenderSize: MTLSize, outputSize newOutputSize: MTLSize) {
        let renderSizeClamped = RenderResources.clampedSize(newRenderSize)
        let outputSizeClamped = RenderResources.clampedSize(newOutputSize)
        if RenderResources.sizesEqual(renderSizeClamped, renderSize) && RenderResources.sizesEqual(outputSizeClamped, outputSize) {
            return
        }
        var replacements: [TextureIndex: MTLTexture] = [:]
        do {
            for index in RenderResources.sizedIndices {
                replacements[index] = try makeSizedTexture(index, renderSize: renderSizeClamped, outputSize: outputSizeClamped)
            }
            let newMomentsHistory = try RenderResources.makeTexture(device: device, label: "MomentsHistory",
                                                                    format: .rgba16Float,
                                                                    width: renderSizeClamped.width, height: renderSizeClamped.height,
                                                                    usage: [.shaderRead, .shaderWrite, .renderTarget])
            for (index, texture) in replacements {
                textures[index] = texture
            }
            momentsHistory = newMomentsHistory
            renderSize = renderSizeClamped
            outputSize = outputSizeClamped
            resetHistory()
        } catch {
            log.error("resize failed, keeping previous textures: \(String(describing: error), privacy: .public)")
        }
    }

    /// Exchanges current↔history references for diffuse/specular/reflection/moments/
    /// depth/normal/froxel/HDR. Call once per frame after the command buffer is committed
    /// (the swap only touches CPU-side references; the encoded GPU work keeps the old
    /// bindings). Marks history valid.
    func swapHistory() {
        for pair in RenderResources.historyPairs {
            if let current = textures[pair.current], let history = textures[pair.history] {
                textures[pair.current] = history
                textures[pair.history] = current
            }
        }
        if let moments = textures[.moments] {
            textures[.moments] = momentsHistory
            momentsHistory = moments
        }
        historyValid = true
    }

    /// Invalidates temporal history: sets `historyValid = false` and schedules a clear
    /// of every history texture (encoded by `encodeHistoryClearIfNeeded(_:)` at the start
    /// of the next frame so the reset is bit-deterministic).
    func resetHistory() {
        historyValid = false
        needsHistoryClear = true
    }

    /// Encodes clears of all history textures if `resetHistory()` was called since the
    /// last clear. 2-D targets are cleared through empty render passes; the 3-D froxel
    /// history uses layered rendering (`renderTargetArrayLength`), available on
    /// Apple4+ GPUs — on older devices it is skipped and FroxelPass must honour
    /// `historyValid` (every pass must anyway).
    func encodeHistoryClearIfNeeded(_ commandBuffer: MTLCommandBuffer) {
        guard needsHistoryClear else { return }
        needsHistoryClear = false

        let colorHistory: [MTLTexture] = [
            texture(.historyDiffuse), texture(.historySpecular), texture(.historyReflection),
            texture(.prevNormal), texture(.prevHDR), momentsHistory,
            texture(.directDiffuse), texture(.directSpecular), texture(.reflection), texture(.moments),
        ]
        for target in colorHistory {
            encodeColorClear(target, commandBuffer: commandBuffer)
        }
        encodeDepthClear(texture(.prevDepth), commandBuffer: commandBuffer)

        if device.supportsFamily(.apple4) {
            encodeColorClear(texture(.froxelHistory), commandBuffer: commandBuffer)
            encodeColorClear(texture(.froxelLighting), commandBuffer: commandBuffer)
        }
    }

    // MARK: Descriptions

    /// Human-readable summary for the debug panel.
    var description: String {
        "render \(renderSize.width)×\(renderSize.height), output \(outputSize.width)×\(outputSize.height), history \(historyValid ? "valid" : "reset")"
    }

    // MARK: - Private: creation

    private func makeStaticTexture(_ index: TextureIndex) throws -> MTLTexture {
        switch index {
        case .albedoAtlas:
            return try RenderResources.makeTexture(device: device, label: "AlbedoAtlas", format: .rgba8Unorm,
                                                   width: RenderResources.atlasSize, height: RenderResources.atlasSize,
                                                   usage: [.shaderRead, .shaderWrite], type: .type2DArray,
                                                   arrayLength: RenderResources.atlasLayerCount,
                                                   mipLevels: RenderResources.atlasMipLevels)
        case .normalAtlas:
            return try RenderResources.makeTexture(device: device, label: "NormalAtlas", format: .rgba8Unorm,
                                                   width: RenderResources.atlasSize, height: RenderResources.atlasSize,
                                                   usage: [.shaderRead, .shaderWrite], type: .type2DArray,
                                                   arrayLength: RenderResources.atlasLayerCount,
                                                   mipLevels: RenderResources.atlasMipLevels)
        case .blueNoise:
            return try RenderResources.makeTexture(device: device, label: "BlueNoise", format: .rgba8Unorm,
                                                   width: RenderResources.blueNoiseSize, height: RenderResources.blueNoiseSize,
                                                   usage: [.shaderRead, .shaderWrite])
        case .chalkMask:
            return try RenderResources.makeTexture(device: device, label: "ChalkMask", format: .r8Unorm,
                                                   width: RenderResources.chalkMaskSize, height: RenderResources.chalkMaskSize,
                                                   usage: [.shaderRead, .shaderWrite])
        default:
            throw RenderResourceError.textureCreationFailed("static texture \(index.rawValue)")
        }
    }

    private func makeSizedTexture(_ index: TextureIndex, renderSize r: MTLSize, outputSize o: MTLSize) throws -> MTLTexture {
        let storage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        let storageAndTarget: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget]
        let target: MTLTextureUsage = [.renderTarget, .shaderRead]
        let device = self.device
        func make(_ label: String, _ format: MTLPixelFormat, _ size: MTLSize, _ usage: MTLTextureUsage) throws -> MTLTexture {
            try RenderResources.makeTexture(device: device, label: label, format: format,
                                            width: size.width, height: size.height, usage: usage)
        }
        switch index {
        case .gBufferAlbedo: return try make("GBufferAlbedo", .rgba8Unorm, r, target)
        case .gBufferNormal: return try make("GBufferNormal", .rgba16Float, r, storageAndTarget)
        case .gBufferMotion: return try make("GBufferMotion", .rg16Float, r, target)
        case .gBufferEmissive: return try make("GBufferEmissive", .rgba16Float, r, target)
        case .depth: return try make("Depth", .depth32Float, r, target)
        case .directDiffuse: return try make("DirectDiffuse", .rgba16Float, r, storageAndTarget)
        case .directSpecular: return try make("DirectSpecular", .rgba16Float, r, storageAndTarget)
        case .reflection: return try make("Reflection", .rgba16Float, r, storageAndTarget)
        case .historyDiffuse: return try make("HistoryDiffuse", .rgba16Float, r, storageAndTarget)
        case .historySpecular: return try make("HistorySpecular", .rgba16Float, r, storageAndTarget)
        case .historyReflection: return try make("HistoryReflection", .rgba16Float, r, storageAndTarget)
        case .prevDepth: return try make("PrevDepth", .depth32Float, r, target)
        case .prevNormal: return try make("PrevNormal", .rgba16Float, r, storageAndTarget)
        case .moments: return try make("Moments", .rgba16Float, r, storageAndTarget)
        case .froxelScatter:
            return try RenderResources.makeTexture(device: device, label: "FroxelScatter", format: .rgba16Float,
                                                   width: RenderResources.froxelSize.width, height: RenderResources.froxelSize.height,
                                                   usage: storage, type: .type3D, depth: RenderResources.froxelSize.depth)
        case .froxelLighting:
            return try RenderResources.makeTexture(device: device, label: "FroxelLighting", format: .rgba16Float,
                                                   width: RenderResources.froxelSize.width, height: RenderResources.froxelSize.height,
                                                   usage: storageAndTarget, type: .type3D, depth: RenderResources.froxelSize.depth)
        case .froxelHistory:
            return try RenderResources.makeTexture(device: device, label: "FroxelHistory", format: .rgba16Float,
                                                   width: RenderResources.froxelSize.width, height: RenderResources.froxelSize.height,
                                                   usage: storageAndTarget, type: .type3D, depth: RenderResources.froxelSize.depth)
        case .hdrColor: return try make("HDRColor", .rgba16Float, r, storageAndTarget)
        case .heat: return try make("Heat", .r16Float, r, storageAndTarget)
        case .upscaled: return try make("Upscaled", .rgba16Float, o, storageAndTarget)
        case .prevHDR: return try make("PrevHDR", .rgba16Float, o, storageAndTarget)
        case .bloom0:
            return try RenderResources.makeTexture(device: device, label: "Bloom0", format: .rgba16Float,
                                                   width: max(o.width / 2, 1), height: max(o.height / 2, 1),
                                                   usage: storage, mipLevels: RenderResources.bloomMipLevels)
        case .output: return try make("Output", RenderResources.outputPixelFormat, o, storage)
        case .sssDiffuse: return try make("SSSDiffuse", .rgba16Float, r, storage)
        default:
            throw RenderResourceError.textureCreationFailed("sized texture \(index.rawValue)")
        }
    }

    private static func makeTexture(device: MTLDevice, label: String, format: MTLPixelFormat,
                                    width: Int, height: Int, usage: MTLTextureUsage,
                                    type: MTLTextureType = .type2D, depth: Int = 1,
                                    arrayLength: Int = 1, mipLevels: Int = 1) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = type
        descriptor.pixelFormat = format
        descriptor.width = max(width, 1)
        descriptor.height = max(height, 1)
        descriptor.depth = max(depth, 1)
        descriptor.mipmapLevelCount = max(mipLevels, 1)
        descriptor.arrayLength = max(arrayLength, 1)
        descriptor.sampleCount = 1
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderResourceError.textureCreationFailed(label)
        }
        texture.label = label
        return texture
    }

    // MARK: - Private: clears

    private func encodeColorClear(_ target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if target.textureType == .type3D {
            pass.renderTargetArrayLength = target.depth
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Clear \(target.label ?? "history")"
        encoder.endEncoding()
    }

    private func encodeDepthClear(_ target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = target
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0   // reversed-Z: 0 = far / background
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Clear \(target.label ?? "depth history")"
        encoder.endEncoding()
    }

    // MARK: - Private: sizes

    /// Guards against zero-sized drawables (e.g. before the first layout).
    static func clampedSize(_ size: MTLSize) -> MTLSize {
        MTLSize(width: max(size.width, 1), height: max(size.height, 1), depth: max(size.depth, 1))
    }

    /// MTLSize is not Equatable; compare width/height/depth.
    static func sizesEqual(_ a: MTLSize, _ b: MTLSize) -> Bool {
        a.width == b.width && a.height == b.height && a.depth == b.depth
    }
}
