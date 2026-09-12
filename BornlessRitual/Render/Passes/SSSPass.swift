//
//  SSSPass.swift
//  Bornless Ritual — separable screen-space subsurface pass (RENDER_CONTRACT §2 row 6
//  "SSSPass", §1 `RenderPass`; Shaders/SSS.metal `sss_horizontal` + `sss_vertical`).
//
//  Role: two dispatches in one compute encoder — horizontal blur of the denoised
//  DirectDiffuse into a pass-owned scratch texture (rgba16Float, render size), then the
//  vertical blur of the scratch into TextureIndexSSSDiffuse with the wax translucency
//  term added. Both kernels bind their INPUT at the TextureIndexDirectDiffuse slot and
//  their OUTPUT at the TextureIndexSSSDiffuse slot; this pass rotates the actual
//  textures (DirectDiffuse → scratch, scratch → SSSDiffuse). Non-SSS pixels are copied
//  through, so SSSDiffuse is a complete replacement for DirectDiffuse downstream.
//
//  Flames: like ReflectionPass, the kernel scans a fixed number of `FlameData` entries
//  (`kSSSMaxFlames` = 16 in SSS.metal) and `FrameUniforms` carries no flame count, so
//  the pass keeps a private triple-buffered copy of exactly `maxFlames` entries per
//  slot, copies the live flames of the scene's current slot in and zero-fills the rest
//  (intensity 0 = skipped), bound at `BufferIndexFlames`.
//

import Foundation
import Metal
import os

/// Jimenez-style separable subsurface blur + wax translucency → TextureIndexSSSDiffuse.
final class SSSPass: RenderPass {

    // MARK: Configuration

    let name = "SSS"

    /// Flame entries scanned by the kernel (`kSSSMaxFlames` in SSS.metal).
    static let maxFlames = 16

    // MARK: State

    private let pipelines: PipelineCache
    private var horizontal: MTLComputePipelineState?
    private var vertical: MTLComputePipelineState?
    private var scratch: MTLTexture?
    private var scratchSize = MTLSize(width: 0, height: 0, depth: 0)
    private var flameCopyBuffer: MTLBuffer?
    private let flameSlotStride: Int
    private var loggedNotBuilt = false
    private let log = Logger(subsystem: "BornlessRitual", category: "SSSPass")

    // MARK: Init

    /// Creates the pass; pipelines, the scratch texture and the flame copy are built in `build`.
    init(pipelines: PipelineCache) {
        self.pipelines = pipelines
        let bytes = SSSPass.maxFlames * MemoryLayout<FlameData>.stride
        self.flameSlotStride = (bytes + SceneResources.slotAlignment - 1) / SceneResources.slotAlignment * SceneResources.slotAlignment
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        horizontal = try pipelines.compute("sss_horizontal")
        vertical = try pipelines.compute("sss_vertical")
        try ensureScratch(device: device, size: resources.renderSize)
        if flameCopyBuffer == nil {
            guard let buffer = device.makeBuffer(length: flameSlotStride * SceneResources.inflightSlots, options: .storageModeShared) else {
                throw RenderResourceError.bufferCreationFailed("SSSPass flame copy")
            }
            buffer.label = "SSSPass flames"
            memset(buffer.contents(), 0, buffer.length)
            flameCopyBuffer = buffer
        }
        loggedNotBuilt = false
    }

    func encode(_ ctx: FrameContext) {
        guard let horizontal = horizontal, let vertical = vertical,
              let scratch = scratch, let flameBuffer = flameCopyBuffer else {
            if !loggedNotBuilt {
                log.error("SSSPass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        let resources = ctx.resources
        let scene = ctx.scene
        if !RenderResources.sizesEqual(scratchSize, resources.renderSize) {
            log.warning("SSSPass scratch size does not match the render size; skipping this frame")
            return
        }
        let flameOffset = copyFlames(scene: scene, into: flameBuffer)

        guard let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            log.error("Could not create the SSS compute encoder")
            return
        }
        encoder.label = "SSS (separable ×2)"
        encoder.setBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setBuffer(scene.materialBuffer, offset: 0, index: BufferIndex.materials.rawValue)
        encoder.setBuffer(flameBuffer, offset: flameOffset, index: BufferIndex.flames.rawValue)
        encoder.setTexture(resources.texture(.depth), index: TextureIndex.depth.rawValue)
        encoder.setTexture(resources.texture(.gBufferAlbedo), index: TextureIndex.gBufferAlbedo.rawValue)

        let grid = MTLSize(width: resources.renderSize.width, height: resources.renderSize.height, depth: 1)

        // Horizontal: DirectDiffuse → scratch.
        encoder.setComputePipelineState(horizontal)
        encoder.setTexture(resources.texture(.directDiffuse), index: TextureIndex.directDiffuse.rawValue)
        encoder.setTexture(scratch, index: TextureIndex.sssDiffuse.rawValue)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: FrameContext.threadgroup8x8)

        // Vertical (+ wax translucency): scratch → SSSDiffuse. Serial dispatches in one
        // encoder observe the previous dispatch's writes.
        encoder.setComputePipelineState(vertical)
        encoder.setTexture(scratch, index: TextureIndex.directDiffuse.rawValue)
        encoder.setTexture(resources.texture(.sssDiffuse), index: TextureIndex.sssDiffuse.rawValue)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: FrameContext.threadgroup8x8)

        encoder.endEncoding()
    }

    // MARK: - Helpers

    /// (Re)creates the scratch texture when the render size changed.
    private func ensureScratch(device: MTLDevice, size: MTLSize) throws {
        if scratch != nil && RenderResources.sizesEqual(scratchSize, size) {
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                  width: max(size.width, 1),
                                                                  height: max(size.height, 1),
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderResourceError.textureCreationFailed("SSSScratch")
        }
        texture.label = "SSSScratch"
        scratch = texture
        scratchSize = size
    }

    /// Copies the live flames of the scene's current slot into the same slot of the
    /// private buffer (zero-filled beyond `flameCount`) and returns that slot's byte offset.
    private func copyFlames(scene: SceneResources, into buffer: MTLBuffer) -> Int {
        let slotOffset = (scene.slot % SceneResources.inflightSlots) * flameSlotStride
        let destination = buffer.contents().advanced(by: slotOffset)
        memset(destination, 0, flameSlotStride)
        let count = min(scene.flameCount, SSSPass.maxFlames)
        if count > 0 {
            let source = scene.buffer(for: .flames).contents().advanced(by: scene.offset(for: .flames))
            destination.copyMemory(from: source, byteCount: count * MemoryLayout<FlameData>.stride)
        }
        return slotOffset
    }
}
