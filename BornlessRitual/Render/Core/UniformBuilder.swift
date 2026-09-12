//
//  UniformBuilder.swift
//  Bornless Ritual — fills `FrameUniforms` (ShaderTypes.h) each frame
//  (RENDER_CONTRACT §3 jitter / motion conventions, ARCHITECTURE §6 frameIndex + seed).
//
//  Role: pure function from (camera, settings, sim state, frame bookkeeping, sizes) to
//  the uniform struct. Also owns the Halton(2,3) 16-sample jitter table, which must
//  match `jitter_pixels()` in Common.h bit for bit (same float operations).
//
//  Jitter convention: `jitterPixels` is a texture-space offset (x right, y down) in
//  render-resolution pixels, in [−0.5, 0.5]². `FrameUniforms.jitter` is the NDC offset
//  added to the projection: `(2·px.x / R.x, −2·px.y / R.y)` (NDC y is up). Motion vectors
//  are computed from un-jittered matrices. For MetalFX, `jitterOffsetX/Y` should be the
//  pixel offset from the pixel centre in texture space (i.e. `jitterPixels`) — verify the
//  sign on device once (see caveats); both signs are exposed here.
//

import Foundation
import simd
import Metal
import RitualCore

/// Builds per-frame uniforms.
struct UniformBuilder {

    // MARK: Jitter

    /// Number of jitter samples in the sequence (ARCHITECTURE §6 warm-up length).
    static let jitterSampleCount: Int = Int(WARMUP_FRAMES)

    /// Halton(2,3) radical inverse, computed with the same float operations as `halton()` in Common.h.
    static func halton(_ index: UInt32, base: UInt32) -> Float {
        var f: Float = 1
        var r: Float = 0
        var i = index
        while i > 0 {
            f /= Float(base)
            r += f * Float(i % base)
            i /= base
        }
        return r
    }

    /// The 16 pixel-space jitter offsets (sample k uses Halton index k + 1), centred on 0.
    static let haltonJitterPixels: [SIMD2<Float>] = (0..<UInt32(jitterSampleCount)).map { k in
        SIMD2<Float>(halton(k + 1, base: 2) - 0.5, halton(k + 1, base: 3) - 0.5)
    }

    /// Texture-space pixel jitter for a frame index (`frameIndex % 16`).
    static func jitterPixels(frameIndex: UInt32) -> SIMD2<Float> {
        haltonJitterPixels[Int(frameIndex % UInt32(jitterSampleCount))]
    }

    /// Converts a texture-space pixel jitter to the NDC offset applied to the projection.
    static func jitterNDC(pixels: SIMD2<Float>, renderSize: MTLSize) -> SIMD2<Float> {
        let width = Float(max(renderSize.width, 1))
        let height = Float(max(renderSize.height, 1))
        return SIMD2<Float>(2 * pixels.x / width, -2 * pixels.y / height)
    }

    // MARK: Inputs

    /// Everything `build` needs; assembled by the Renderer each frame.
    struct Inputs {
        /// Camera for this frame (frozen during warm-up).
        var camera: OrbitCamera
        /// Settings snapshot.
        var settings: RenderSettings
        /// Simulation state at the latest integer tick.
        var state: RitualState
        /// Current simulation tick.
        var tick: Int
        /// ARCHITECTURE §6 frame index.
        var frameIndex: UInt32
        /// Simulation / render seed.
        var seed: UInt64
        /// Internal render size.
        var renderSize: MTLSize
        /// Native output size.
        var outputSize: MTLSize
        /// Active render path.
        var renderPath: RenderPath
        /// Whether temporal history may be used.
        var historyValid: Bool
        /// True during warm-up frames (camera frozen, deltaTime 0).
        var isWarmup: Bool
        /// Seconds since the previous rendered frame (0 during warm-up).
        var deltaTime: Float
        /// Number of lights written to `BufferIndexLights` this frame.
        var lightCount: Int
        /// Previous frame's uniforms (for prevViewProjection / prevCameraPosition); nil after a reset.
        var previous: FrameUniforms?
    }

    // MARK: Build

    /// Produces the uniforms for a frame.
    static func build(_ inputs: Inputs) -> FrameUniforms {
        let camera = inputs.camera
        let settings = inputs.settings
        let state = inputs.state

        let width = Float(max(inputs.renderSize.width, 1))
        let height = Float(max(inputs.renderSize.height, 1))
        let aspect = width / height

        let jitterPx = jitterPixels(frameIndex: inputs.frameIndex)
        let jitter = jitterNDC(pixels: jitterPx, renderSize: inputs.renderSize)

        let view = camera.viewMatrix()
        let projection = camera.projection(aspect: aspect, jitter: jitter)
        let unjitteredProjection = camera.projection(aspect: aspect)
        let viewProjection = projection * view
        let unjitteredViewProjection = unjitteredProjection * view

        var uniforms = FrameUniforms()
        uniforms.viewMatrix = view
        uniforms.projectionMatrix = projection
        uniforms.viewProjection = viewProjection
        uniforms.invViewProjection = viewProjection.inverse
        uniforms.unjitteredViewProjection = unjitteredViewProjection
        uniforms.prevViewProjection = inputs.previous?.unjitteredViewProjection ?? unjitteredViewProjection

        uniforms.cameraPosition = camera.position
        uniforms.prevCameraPosition = inputs.previous?.cameraPosition ?? camera.position
        uniforms.time = Float(inputs.tick) / Float(SIM_TICK_RATE)
        uniforms.deltaTime = inputs.isWarmup ? 0 : inputs.deltaTime
        uniforms.jitter = jitter
        uniforms.renderSize = SIMD2<Float>(width, height)
        uniforms.outputSize = SIMD2<Float>(Float(max(inputs.outputSize.width, 1)), Float(max(inputs.outputSize.height, 1)))
        uniforms.invRenderSize = SIMD2<Float>(1 / width, 1 / height)

        uniforms.frameIndex = inputs.frameIndex
        uniforms.tick = UInt32(clamping: max(inputs.tick, 0))
        uniforms.seedLo = inputs.seed.seedLo
        uniforms.seedHi = inputs.seed.seedHi
        uniforms.lightCount = UInt32(clamping: min(max(inputs.lightCount, 0), Int(MAX_LIGHTS)))
        uniforms.renderPath = inputs.renderPath.shaderValue
        uniforms.historyValid = inputs.historyValid ? 1 : 0
        uniforms.stage = UInt32(clamping: state.stage.rawValue)

        uniforms.exposureEV = settings.exposureEV
        uniforms.ambient = settings.ambientLight
        uniforms.flameIntensity = settings.flameIntensity
        uniforms.smokeDensity = settings.smokeDensity
        uniforms.candleWarmthK = settings.candleWarmthKelvin
        uniforms.emberScale = settings.emberCount
        uniforms.nearPlane = camera.near
        uniforms.farPlane = camera.far

        uniforms.ringKindle = Float(ScalarMath.clamp(state.ringKindle, 0, 1))
        uniforms.sigilErupt = sigilErupt(state: state, tick: inputs.tick)
        uniforms.manifestT = Float(ScalarMath.clamp(state.manifestT, 0, 1))
        uniforms.stageProgress = Float(ScalarMath.clamp(state.stageProgress, 0, 1))
        uniforms.heatShimmer = settings.heatShimmer
        uniforms.renderScale = settings.renderScale
        uniforms.padding0 = 0
        uniforms.padding1 = 0
        return uniforms
    }

    /// Sigil visibility/energy 0…1: ramps over one second after the eruption tick.
    static func sigilErupt(state: RitualState, tick: Int) -> Float {
        guard state.sigilErupted else { return 0 }
        guard let eruptTick = state.sigilEruptTick else { return 1 }
        let rampTicks = Double(SIM_TICK_RATE)   // 1.0 s
        let t = Double(tick - eruptTick) / rampTicks
        return Float(ScalarMath.clamp(t, 0, 1))
    }
}
