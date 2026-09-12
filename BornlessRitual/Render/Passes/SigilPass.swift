//
//  SigilPass.swift
//  Bornless Ritual — the fiery sigil pass (RENDER_CONTRACT §2 row 10 "SigilPass:
//  compute + render", §1 `RenderPass`; Shaders/Sigil.metal; ShaderTypes.h
//  BufferIndexRingHistory / SigilParams / SigilVertices / Embers / EmberCount / DrawArgs,
//  TextureIndexHDRColor / Heat / Depth; ARCHITECTURE §6 ember determinism).
//
//  Role, per frame (skipped entirely while `FrameUniforms.sigilErupt` is 0 — nothing is
//  visible and no ember can be alive):
//    1. compute encoder (serial): `sigil_embers_reset` (1 thread) → `sigil_embers` over
//       the RING_HISTORY_TICKS × EMBERS_PER_TICK_MAX grid (8×8 threadgroups; the kernel
//       guards the EMBER_LIFETIME_TICKS bound) appending live `EmberInstance`s with an
//       atomic counter → `sigil_embers_finalize` (1 thread) writing the clamped count into
//       the indirect draw arguments. The counter and the arguments share
//       `SceneResources.emberCountBuffer` (offsets `emberCountOffset` / `emberDrawArgumentsOffset`).
//    2. render encoder into HDRColor (color 0) + Heat (color 1), additive blending, depth
//       attachment = the G-buffer depth loaded and stored with a greater-equal (reversed-Z)
//       test and no depth write, cull none:
//         a. filament rune rings — `sigil_filament_vertex/fragment`, 6 vertices per
//            segment of the scene's filament segment list (`SceneResources.sigilFilamentBuffer`);
//         b. fire sheets — `sigil_sheet_vertex/fragment`, one annulus per ring (instanced);
//         c. embers — `sigil_ember_vertex/fragment`, instanced quads through
//            `drawPrimitives(type:indirectBuffer:indirectBufferOffset:)`.
//
//  Filament geometry: SceneUpdater (the scene job) writes Render/Scene/SigilFilaments'
//  layout into the scene buffer at construction. If the buffer is still empty when this
//  pass first encodes (`filamentSource == .sceneThenBuiltIn`, the default) — or always,
//  when `filamentSource == .builtIn` — the pass uploads Render/Passes/SigilGeometry's
//  layout (the job brief's ring assignment) built from `DaemonProfile.owner`. Both use the
//  same two-vertices-per-segment encoding the shader expects.
//

import Foundation
import Metal
import simd
import RitualCore
import os

/// Errors raised while building the sigil pass.
enum SigilPassError: Error, CustomStringConvertible {
    /// `MTLDevice.makeDepthStencilState` returned nil.
    case depthStateCreationFailed

    var description: String {
        switch self {
        case .depthStateCreationFailed: return "Could not create the sigil depth-stencil state"
        }
    }
}

/// Ember simulation + filament / fire-sheet / ember draws.
final class SigilPass: RenderPass {

    // MARK: Configuration

    let name = "Sigil"

    /// Where the filament segment list comes from.
    enum FilamentSource: Sendable {
        /// Use whatever the scene wrote; upload the built-in geometry only if the buffer is empty.
        case sceneThenBuiltIn
        /// Replace the scene's geometry with `SigilGeometry`'s layout once, before the first draw.
        case builtIn
    }

    /// Filament geometry policy (see the header). Set before the first frame.
    var filamentSource: FilamentSource = .sceneThenBuiltIn

    /// Ember kernel threadgroup (8×8) and the threadgroup grid covering
    /// RING_HISTORY_TICKS × EMBERS_PER_TICK_MAX threads.
    static let emberThreadgroup = MTLSize(width: 8, height: 8, depth: 1)
    static let emberThreadgroups = MTLSize(width: (Int(RING_HISTORY_TICKS) + 7) / 8,
                                           height: (Int(EMBERS_PER_TICK_MAX) + 7) / 8,
                                           depth: 1)
    /// Fire-sheet annulus segments (must equal `kSheetSegments` in Sigil.metal).
    static let sheetSegments = 48
    /// Vertices per fire-sheet instance (6 per segment).
    static let sheetVertexCount = sheetSegments * 6
    /// Vertices drawn per filament segment (two triangles).
    static let filamentVerticesPerSegment = 6
    /// Single-thread dispatch size for the reset / finalize kernels.
    private static let singleThread = MTLSize(width: 1, height: 1, depth: 1)

    // MARK: State

    private let pipelines: PipelineCache
    private let daemon: DaemonProfile
    private var resetPipeline: MTLComputePipelineState?
    private var emberPipeline: MTLComputePipelineState?
    private var finalizePipeline: MTLComputePipelineState?
    private var filamentPipeline: MTLRenderPipelineState?
    private var sheetPipeline: MTLRenderPipelineState?
    private var emberDrawPipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var builtInFilamentsUploaded = false
    private var loggedNotBuilt = false
    private let log = Logger(subsystem: "BornlessRitual", category: "SigilPass")

    // MARK: Init

    /// Creates the pass; pipelines are built in `build`.
    ///
    /// - Parameters:
    ///   - pipelines: Shared pipeline cache (variant already set by the Renderer).
    ///   - daemon: Profile whose name and kamea path the built-in filaments inscribe.
    init(pipelines: PipelineCache, daemon: DaemonProfile = .owner) {
        self.pipelines = pipelines
        self.daemon = daemon
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        resetPipeline = try pipelines.compute("sigil_embers_reset")
        emberPipeline = try pipelines.compute("sigil_embers")
        finalizePipeline = try pipelines.compute("sigil_embers_finalize")

        let hdrFormat = resources.texture(.hdrColor).pixelFormat
        let heatFormat = resources.texture(.heat).pixelFormat
        let depthFormat = resources.texture(.depth).pixelFormat
        filamentPipeline = try pipelines.render(label: "SigilFilaments",
                                                vertexFunction: "sigil_filament_vertex",
                                                fragmentFunction: "sigil_filament_fragment") { descriptor in
            SigilPass.configureAdditive(descriptor, hdrFormat: hdrFormat, heatFormat: heatFormat, depthFormat: depthFormat)
        }
        sheetPipeline = try pipelines.render(label: "SigilSheets",
                                             vertexFunction: "sigil_sheet_vertex",
                                             fragmentFunction: "sigil_sheet_fragment") { descriptor in
            SigilPass.configureAdditive(descriptor, hdrFormat: hdrFormat, heatFormat: heatFormat, depthFormat: depthFormat)
        }
        emberDrawPipeline = try pipelines.render(label: "SigilEmbers",
                                                 vertexFunction: "sigil_ember_vertex",
                                                 fragmentFunction: "sigil_ember_fragment") { descriptor in
            SigilPass.configureAdditive(descriptor, hdrFormat: hdrFormat, heatFormat: heatFormat, depthFormat: depthFormat)
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.label = "Sigil reversed-Z test, no write"
        depthDescriptor.depthCompareFunction = .greaterEqual
        depthDescriptor.isDepthWriteEnabled = false
        guard let state = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw SigilPassError.depthStateCreationFailed
        }
        depthState = state
        loggedNotBuilt = false
    }

    func encode(_ ctx: FrameContext) {
        guard let resetPipeline = resetPipeline, let emberPipeline = emberPipeline,
              let finalizePipeline = finalizePipeline, let filamentPipeline = filamentPipeline,
              let sheetPipeline = sheetPipeline, let emberDrawPipeline = emberDrawPipeline,
              let depthState = depthState else {
            if !loggedNotBuilt {
                log.error("SigilPass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        // Nothing to see and nothing alive before the eruption (also true after a seek
        // back before it: the ring history is back-filled with rings at rest).
        guard ctx.uniforms.sigilErupt > 0 else { return }

        let scene = ctx.scene
        uploadBuiltInFilamentsIfNeeded(scene)

        encodeEmberSimulation(ctx, reset: resetPipeline, embers: emberPipeline, finalize: finalizePipeline)
        encodeDraws(ctx, filaments: filamentPipeline, sheets: sheetPipeline, embers: emberDrawPipeline, depthState: depthState)
    }

    // MARK: - Filament geometry

    /// Uploads `SigilGeometry`'s segment list when the policy asks for it (once).
    private func uploadBuiltInFilamentsIfNeeded(_ scene: SceneResources) {
        guard !builtInFilamentsUploaded else { return }
        switch filamentSource {
        case .sceneThenBuiltIn:
            guard scene.sigilFilamentVertexCount == 0 else {
                builtInFilamentsUploaded = true
                return
            }
        case .builtIn:
            break
        }
        let radii = SigilDynamics.ringRadii.map { Float($0) }
        let vertices = SigilGeometry.build(daemon: daemon, center: SceneLayout.sigilCenter, radii: radii)
        let written = scene.writeSigilFilaments(vertices)
        builtInFilamentsUploaded = true
        log.info("Uploaded built-in sigil filaments: \(written) vertices")
    }

    // MARK: - Ember simulation

    private func encodeEmberSimulation(_ ctx: FrameContext, reset: MTLComputePipelineState,
                                       embers: MTLComputePipelineState, finalize: MTLComputePipelineState) {
        let scene = ctx.scene
        guard let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            log.error("Could not create the sigil ember compute encoder")
            return
        }
        encoder.label = "Sigil embers"

        // Bindings shared by the three dispatches (a serial encoder orders them).
        encoder.setBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setBuffer(scene.buffer(for: .sigilParams), offset: scene.offset(for: .sigilParams), index: BufferIndex.sigilParams.rawValue)
        encoder.setBuffer(scene.ringHistoryBuffer, offset: 0, index: BufferIndex.ringHistory.rawValue)
        encoder.setBuffer(scene.emberInstanceBuffer, offset: 0, index: BufferIndex.embers.rawValue)
        encoder.setBuffer(scene.emberCountBuffer, offset: SceneResources.emberCountOffset, index: BufferIndex.emberCount.rawValue)
        encoder.setBuffer(scene.emberCountBuffer, offset: SceneResources.emberDrawArgumentsOffset, index: BufferIndex.drawArgs.rawValue)

        encoder.setComputePipelineState(reset)
        encoder.dispatchThreadgroups(SigilPass.singleThread, threadsPerThreadgroup: SigilPass.singleThread)

        encoder.setComputePipelineState(embers)
        encoder.dispatchThreadgroups(SigilPass.emberThreadgroups, threadsPerThreadgroup: SigilPass.emberThreadgroup)

        encoder.setComputePipelineState(finalize)
        encoder.dispatchThreadgroups(SigilPass.singleThread, threadsPerThreadgroup: SigilPass.singleThread)
        encoder.endEncoding()
    }

    // MARK: - Draws

    private func encodeDraws(_ ctx: FrameContext, filaments: MTLRenderPipelineState, sheets: MTLRenderPipelineState,
                             embers: MTLRenderPipelineState, depthState: MTLDepthStencilState) {
        let resources = ctx.resources
        let scene = ctx.scene

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = resources.texture(.hdrColor)
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = resources.texture(.heat)
        pass.colorAttachments[1].loadAction = .load
        pass.colorAttachments[1].storeAction = .store
        pass.depthAttachment.texture = resources.texture(.depth)
        pass.depthAttachment.loadAction = .load
        pass.depthAttachment.storeAction = .store   // read-only here; keep it for DaemonPass

        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            log.error("Could not create the sigil render command encoder")
            return
        }
        encoder.label = "Sigil"
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(resources.renderSize.width),
                                        height: Double(resources.renderSize.height),
                                        znear: 0, zfar: 1))

        encoder.setVertexBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setVertexBuffer(scene.buffer(for: .sigilParams), offset: scene.offset(for: .sigilParams), index: BufferIndex.sigilParams.rawValue)
        encoder.setVertexBuffer(scene.ringHistoryBuffer, offset: 0, index: BufferIndex.ringHistory.rawValue)
        encoder.setVertexBuffer(scene.sigilFilamentBuffer, offset: 0, index: BufferIndex.sigilVertices.rawValue)
        encoder.setVertexBuffer(scene.emberInstanceBuffer, offset: 0, index: BufferIndex.embers.rawValue)
        encoder.setFragmentBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setFragmentBuffer(scene.buffer(for: .sigilParams), offset: scene.offset(for: .sigilParams), index: BufferIndex.sigilParams.rawValue)

        // a. Filament rune rings (segment list → 6 vertices per segment).
        let segmentCount = scene.sigilFilamentVertexCount / 2
        if segmentCount > 0 {
            encoder.setRenderPipelineState(filaments)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: segmentCount * SigilPass.filamentVerticesPerSegment)
        }

        // b. Fire sheets, one annulus per ring.
        encoder.setRenderPipelineState(sheets)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: SigilPass.sheetVertexCount, instanceCount: Int(RING_COUNT))

        // c. Embers through the indirect arguments written by the compute kernels.
        encoder.setRenderPipelineState(embers)
        encoder.drawPrimitives(type: .triangle,
                               indirectBuffer: scene.emberCountBuffer,
                               indirectBufferOffset: SceneResources.emberDrawArgumentsOffset)
        encoder.endEncoding()
    }

    // MARK: - Pipeline configuration

    /// HDRColor + Heat additive blending, depth attachment present (test only), no stencil.
    private static func configureAdditive(_ descriptor: MTLRenderPipelineDescriptor,
                                          hdrFormat: MTLPixelFormat, heatFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        for (slot, format) in [(0, hdrFormat), (1, heatFormat)] {
            let attachment = descriptor.colorAttachments[slot]
            attachment?.pixelFormat = format
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .one
            attachment?.sourceAlphaBlendFactor = .one
            attachment?.destinationAlphaBlendFactor = .one
        }
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.stencilAttachmentPixelFormat = .invalid
        descriptor.rasterSampleCount = 1
    }
}
