//
//  DaemonPass.swift
//  Bornless Ritual — the daemon ray-march pass (RENDER_CONTRACT §2 row 11 "DaemonPass:
//  render (full-screen bounded by boundsMin/Max, blend)", §1 `RenderPass`;
//  Shaders/Daemon.metal; ShaderTypes.h `DaemonParams`, BufferIndexDaemonParams,
//  TextureIndexHDRColor / Heat / Depth).
//
//  Role: draws one full-screen triangle with `daemon_vertex` / `daemon_fragment` into
//  HDRColor (color 0, premultiplied src-over: src ONE, dst ONE_MINUS_SRC_ALPHA — the
//  "src alpha" blend for the premultiplied radiance the march produces) and Heat
//  (color 1, additive). There is no depth attachment: the fragment reads the G-buffer
//  depth texture and clips the march itself, and never writes depth. The draw is skipped
//  while `manifestT` is 0 and otherwise scissored to the projected bounds box
//  (`DaemonParams.boundsMin/Max` from the current slot; full screen when the camera is
//  inside the box or a corner is behind the near plane; skipped when the box is fully
//  off screen), so fragments only run where the daemon can appear.
//

import Foundation
import Metal
import simd
import os

/// Ray-marches the leonine daemon over the composited image.
final class DaemonPass: RenderPass {

    // MARK: Configuration

    let name = "Daemon"

    /// Scissor padding (pixels) around the projected bounds.
    static let scissorPadding = 2

    // MARK: State

    private let pipelines: PipelineCache
    private var pipeline: MTLRenderPipelineState?
    private var loggedNotBuilt = false
    private let log = Logger(subsystem: "BornlessRitual", category: "DaemonPass")

    // MARK: Init

    /// Creates the pass; the pipeline is built in `build`.
    init(pipelines: PipelineCache) {
        self.pipelines = pipelines
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        let hdrFormat = resources.texture(.hdrColor).pixelFormat
        let heatFormat = resources.texture(.heat).pixelFormat
        pipeline = try pipelines.render(label: "Daemon", vertexFunction: "daemon_vertex", fragmentFunction: "daemon_fragment") { descriptor in
            let color = descriptor.colorAttachments[0]
            color?.pixelFormat = hdrFormat
            color?.isBlendingEnabled = true
            color?.rgbBlendOperation = .add
            color?.alphaBlendOperation = .add
            color?.sourceRGBBlendFactor = .one
            color?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color?.sourceAlphaBlendFactor = .one
            color?.destinationAlphaBlendFactor = .oneMinusSourceAlpha

            let heat = descriptor.colorAttachments[1]
            heat?.pixelFormat = heatFormat
            heat?.isBlendingEnabled = true
            heat?.rgbBlendOperation = .add
            heat?.alphaBlendOperation = .add
            heat?.sourceRGBBlendFactor = .one
            heat?.destinationRGBBlendFactor = .one
            heat?.sourceAlphaBlendFactor = .one
            heat?.destinationAlphaBlendFactor = .one

            descriptor.depthAttachmentPixelFormat = .invalid
            descriptor.stencilAttachmentPixelFormat = .invalid
            descriptor.rasterSampleCount = 1
        }
        loggedNotBuilt = false
    }

    func encode(_ ctx: FrameContext) {
        guard let pipeline = pipeline else {
            if !loggedNotBuilt {
                log.error("DaemonPass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        guard ctx.uniforms.manifestT > 0 else { return }

        let resources = ctx.resources
        let scene = ctx.scene
        let params = DaemonPass.readDaemonParams(scene)
        guard params.manifest > 0 else { return }
        guard let scissor = DaemonPass.scissorRect(boundsMin: params.boundsMin, boundsMax: params.boundsMax,
                                                   viewProjection: ctx.uniforms.viewProjection,
                                                   cameraPosition: ctx.uniforms.cameraPosition,
                                                   renderSize: resources.renderSize) else {
            return   // bounds fully off screen
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = resources.texture(.hdrColor)
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = resources.texture(.heat)
        pass.colorAttachments[1].loadAction = .load
        pass.colorAttachments[1].storeAction = .store

        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            log.error("Could not create the daemon render command encoder")
            return
        }
        encoder.label = "Daemon"
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(resources.renderSize.width),
                                        height: Double(resources.renderSize.height),
                                        znear: 0, zfar: 1))
        encoder.setScissorRect(scissor)
        encoder.setFragmentBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setFragmentBuffer(scene.buffer(for: .daemonParams), offset: scene.offset(for: .daemonParams), index: BufferIndex.daemonParams.rawValue)
        encoder.setFragmentTexture(resources.texture(.depth), index: TextureIndex.depth.rawValue)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: - Bounds

    /// CPU-side copy of the current slot's `DaemonParams` (shared memory written by SceneUpdater this frame).
    private static func readDaemonParams(_ scene: SceneResources) -> DaemonParams {
        let base = scene.buffer(for: .daemonParams).contents().advanced(by: scene.offset(for: .daemonParams))
        return base.load(as: DaemonParams.self)
    }

    /// Scissor rectangle covering the projection of the bounds box, padded and clamped to
    /// the render target. Returns the full target when the camera is inside the box or any
    /// corner projects behind the near plane (conservative), and `nil` when the box is
    /// entirely off screen.
    static func scissorRect(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, viewProjection: float4x4,
                            cameraPosition: SIMD3<Float>, renderSize: MTLSize,
                            padding: Int = DaemonPass.scissorPadding) -> MTLScissorRect? {
        let width = max(renderSize.width, 1)
        let height = max(renderSize.height, 1)
        let fullRect = MTLScissorRect(x: 0, y: 0, width: width, height: height)

        let lower = simd_min(boundsMin, boundsMax)
        let upper = simd_max(boundsMin, boundsMax)
        let inside = cameraPosition.x >= lower.x && cameraPosition.x <= upper.x
            && cameraPosition.y >= lower.y && cameraPosition.y <= upper.y
            && cameraPosition.z >= lower.z && cameraPosition.z <= upper.z
        if inside {
            return fullRect
        }

        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        let widthF = Float(width)
        let heightF = Float(height)
        for cornerIndex in 0..<8 {
            let corner = SIMD3<Float>(cornerIndex & 1 == 0 ? lower.x : upper.x,
                                      cornerIndex & 2 == 0 ? lower.y : upper.y,
                                      cornerIndex & 4 == 0 ? lower.z : upper.z)
            let clip = viewProjection * SIMD4<Float>(corner.x, corner.y, corner.z, 1)
            if !(clip.w > 1e-4) {
                return fullRect   // behind (or on) the near plane: be conservative
            }
            let ndcX = clip.x / clip.w
            let ndcY = clip.y / clip.w
            let pixelX = (ndcX * 0.5 + 0.5) * widthF
            let pixelY = (0.5 - ndcY * 0.5) * heightF
            if !pixelX.isFinite || !pixelY.isFinite {
                return fullRect
            }
            minX = min(minX, pixelX)
            maxX = max(maxX, pixelX)
            minY = min(minY, pixelY)
            maxY = max(maxY, pixelY)
        }

        let clampedMinX = ScalarMath.clamp(minX.rounded(.down) - Float(padding), 0, widthF)
        let clampedMaxX = ScalarMath.clamp(maxX.rounded(.up) + Float(padding), 0, widthF)
        let clampedMinY = ScalarMath.clamp(minY.rounded(.down) - Float(padding), 0, heightF)
        let clampedMaxY = ScalarMath.clamp(maxY.rounded(.up) + Float(padding), 0, heightF)
        let x0 = Int(clampedMinX)
        let x1 = Int(clampedMaxX)
        let y0 = Int(clampedMinY)
        let y1 = Int(clampedMaxY)
        guard x1 > x0, y1 > y0 else {
            return nil
        }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
