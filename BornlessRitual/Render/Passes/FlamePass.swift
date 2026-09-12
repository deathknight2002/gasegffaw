//
//  FlamePass.swift
//  Bornless Ritual — candle flame render pass (RENDER_CONTRACT §2 row 9 "FlamePass",
//  §1 `RenderPass`; Shaders/Flame.metal `flame_vertex` / `flame_fragment`;
//  ShaderTypes.h `FlameData`, TextureIndexHDRColor / TextureIndexHeat / TextureIndexDepth).
//
//  Role: builds one render pipeline with two additive colour attachments — HDRColor
//  (rgb add with (.one, .one); the alpha channel is masked out so Composite's
//  foreground/background alpha survives) and Heat (r16Float, add) — plus a reversed-Z
//  depth-stencil state that tests `.greaterEqual` against the G-buffer depth without
//  writing it. Every frame it loads HDRColor / Heat / Depth, and issues a single
//  `drawPrimitives(.triangle, vertexCount: 12, instanceCount: flameCount)`: vertices
//  0–5 of each instance are the flame quad, 6–11 the heat-plume quad (Flame.metal).
//  Runs after CompositePass (which writes HDRColor and clears Heat) and before
//  SigilPass / DaemonPass, which add into the same targets.
//
//  The flame buffer is the scene's triple-buffered `.flames` slot written by
//  SceneUpdater (another job); `SceneResources.flameCount` is the live count, and a
//  frame without flames encodes nothing.
//

import Foundation
import Metal
import os

/// Errors raised while building the flame pass.
enum FlamePassError: Error, CustomStringConvertible {
    /// `MTLDevice.makeDepthStencilState` returned nil.
    case depthStateCreationFailed

    var description: String {
        switch self {
        case .depthStateCreationFailed: return "Could not create the flame depth-stencil state"
        }
    }
}

/// Camera-facing ray-marched flame quads → HDRColor (additive) and Heat.
final class FlamePass: RenderPass {

    // MARK: Configuration

    let name = "Flame"

    /// Vertices drawn per flame instance (`kFlameVerticesPerInstance` in Flame.metal).
    static let verticesPerFlame = 12

    // MARK: State

    private let pipelines: PipelineCache
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var loggedNotBuilt = false
    private let log = Logger(subsystem: "BornlessRitual", category: "FlamePass")

    // MARK: Init

    /// Creates the pass; the pipeline and depth state are built in `build`.
    init(pipelines: PipelineCache) {
        self.pipelines = pipelines
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        pipeline = try pipelines.render(label: "Flame", vertexFunction: "flame_vertex", fragmentFunction: "flame_fragment") { descriptor in
            // color(0): HDRColor, rgb additive, alpha untouched.
            let color = descriptor.colorAttachments[0]
            color?.pixelFormat = resources.texture(.hdrColor).pixelFormat
            color?.isBlendingEnabled = true
            color?.rgbBlendOperation = .add
            color?.alphaBlendOperation = .add
            color?.sourceRGBBlendFactor = .one
            color?.destinationRGBBlendFactor = .one
            color?.sourceAlphaBlendFactor = .zero
            color?.destinationAlphaBlendFactor = .one
            color?.writeMask = [.red, .green, .blue]

            // color(1): Heat, additive.
            let heat = descriptor.colorAttachments[1]
            heat?.pixelFormat = resources.texture(.heat).pixelFormat
            heat?.isBlendingEnabled = true
            heat?.rgbBlendOperation = .add
            heat?.alphaBlendOperation = .add
            heat?.sourceRGBBlendFactor = .one
            heat?.destinationRGBBlendFactor = .one
            heat?.sourceAlphaBlendFactor = .one
            heat?.destinationAlphaBlendFactor = .one
            heat?.writeMask = .all

            descriptor.depthAttachmentPixelFormat = resources.texture(.depth).pixelFormat
            descriptor.stencilAttachmentPixelFormat = .invalid
            descriptor.rasterSampleCount = 1
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.label = "Flame reversed-Z test only"
        depthDescriptor.depthCompareFunction = .greaterEqual
        depthDescriptor.isDepthWriteEnabled = false
        guard let state = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw FlamePassError.depthStateCreationFailed
        }
        depthState = state
        loggedNotBuilt = false
    }

    func encode(_ ctx: FrameContext) {
        guard let pipeline = pipeline, let depthState = depthState else {
            if !loggedNotBuilt {
                log.error("FlamePass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        let scene = ctx.scene
        let resources = ctx.resources
        let flameCount = scene.flameCount
        guard flameCount > 0 else { return }

        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]
        color?.texture = resources.texture(.hdrColor)
        color?.loadAction = .load
        color?.storeAction = .store
        let heat = pass.colorAttachments[1]
        heat?.texture = resources.texture(.heat)
        heat?.loadAction = .load
        heat?.storeAction = .store
        pass.depthAttachment.texture = resources.texture(.depth)
        pass.depthAttachment.loadAction = .load
        pass.depthAttachment.storeAction = .store   // no depth writes, but later passes still read it

        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            log.error("Could not create the flame render command encoder")
            return
        }
        encoder.label = "Flames (\(flameCount))"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(resources.renderSize.width),
                                        height: Double(resources.renderSize.height),
                                        znear: 0, zfar: 1))

        encoder.setVertexBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setVertexBuffer(scene.buffer(for: .flames), offset: scene.offset(for: .flames), index: BufferIndex.flames.rawValue)
        encoder.setFragmentBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setFragmentBuffer(scene.buffer(for: .flames), offset: scene.offset(for: .flames), index: BufferIndex.flames.rawValue)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: FlamePass.verticesPerFlame, instanceCount: flameCount)
        encoder.endEncoding()
    }
}
