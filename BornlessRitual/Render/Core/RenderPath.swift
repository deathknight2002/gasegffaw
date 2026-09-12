//
//  RenderPath.swift
//  Bornless Ritual — RENDER_CONTRACT §1 Swift-side contracts: `RenderPath`,
//  `FrameContext` and the `RenderPass` protocol every frame-graph pass implements.
//
//  Role: the immutable per-frame context handed to passes and the pass interface.
//  The Renderer assembles passes (Renderer+Passes.swift), builds them once per
//  (device, renderPath) and again on resize, then calls `encode` in frame-graph order.
//

import Foundation
import Metal

// MARK: - RenderPath

/// Which rendering path the pipelines were built for (function constant 0, `kRenderPath`).
enum RenderPath: Int, CaseIterable, Sendable {
    /// Hardware ray tracing (`RT.h`).
    case rt = 0
    /// Signed-distance-field fallback (`SDF.h`).
    case fallback = 1

    /// Value written to `FrameUniforms.renderPath` and function constant 0
    /// (`RENDER_PATH_RT` / `RENDER_PATH_FALLBACK` in ShaderTypes.h).
    var shaderValue: UInt32 { UInt32(rawValue) }

    /// Suffix used in capture file names (`still_s7_low_rt.png`).
    var fileSuffix: String {
        switch self {
        case .rt: return "rt"
        case .fallback: return "fallback"
        }
    }

    /// Human-readable name for the debug panel.
    var displayName: String {
        switch self {
        case .rt: return "Ray traced"
        case .fallback: return "SDF fallback"
        }
    }
}

// MARK: - FrameContext

/// Per-frame immutable context handed to every pass (RENDER_CONTRACT §1).
///
/// Additions beyond the contract's field list: `settings` (the per-frame settings
/// snapshot) so passes can read slider values that are not mirrored in `FrameUniforms`.
struct FrameContext {
    /// The frame's single command buffer; passes append encoders to it in order.
    let commandBuffer: MTLCommandBuffer
    /// CPU copy of the uniforms uploaded at `uniformBuffer` + `uniformOffset`.
    let uniforms: FrameUniforms
    /// Triple-buffered uniform ring; bind at `BufferIndexFrameUniforms` with `uniformOffset`.
    let uniformBuffer: MTLBuffer
    /// Byte offset of this frame's `FrameUniforms` inside `uniformBuffer`.
    let uniformOffset: Int
    /// Textures for the current (renderSize, outputSize).
    let resources: RenderResources
    /// Geometry, instance, light, parameter and acceleration-structure buffers.
    let scene: SceneResources
    /// Path the current pipelines were built for.
    let renderPath: RenderPath
    /// ARCHITECTURE §6 frame index (live: incrementing; warm-up: tick·16 + k).
    let frameIndex: UInt32
    /// True during the 16 warm-up frames after a seek / path change / capture request.
    let isWarmup: Bool
    /// False on the first frame after `RenderResources.resetHistory()`; passes must not reproject.
    let historyValid: Bool
    /// Settings snapshot taken at the start of the frame.
    let settings: RenderSettings

    /// Internal render size in pixels.
    var renderSize: MTLSize { resources.renderSize }
    /// Native output size in pixels.
    var outputSize: MTLSize { resources.outputSize }

    /// Threadgroup count for an 8×8 threadgroup grid covering the internal resolution.
    var threadgroupsRender8x8: MTLSize {
        MTLSize(width: (resources.renderSize.width + 7) / 8,
                height: (resources.renderSize.height + 7) / 8,
                depth: 1)
    }

    /// Threadgroup count for a 16×16 threadgroup grid covering the output resolution (post).
    var threadgroupsOutput16x16: MTLSize {
        MTLSize(width: (resources.outputSize.width + 15) / 16,
                height: (resources.outputSize.height + 15) / 16,
                depth: 1)
    }

    /// The standard 8×8 screen-pass threadgroup size.
    static let threadgroup8x8 = MTLSize(width: 8, height: 8, depth: 1)
    /// The 16×16 post-pass threadgroup size.
    static let threadgroup16x16 = MTLSize(width: 16, height: 16, depth: 1)
}

// MARK: - RenderPass

/// One node of the frame graph (RENDER_CONTRACT §2).
protocol RenderPass: AnyObject {
    /// Stable name used for encoder labels and the debug panel.
    var name: String { get }

    /// Called once per (device, renderPath) and again on resize; build pipelines here
    /// (function constants: `kRenderPath`, `kMetalFX`, `kDebugView`).
    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws

    /// Encodes the pass's work into `ctx.commandBuffer`.
    func encode(_ ctx: FrameContext)
}
