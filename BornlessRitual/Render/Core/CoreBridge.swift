//
//  CoreBridge.swift
//  Bornless Ritual — RitualCore ↔ simd boundary (ARCHITECTURE §1: "The app converts
//  RVec3 → SIMD3<Float> at the boundary").
//
//  Role: conversions between RitualCore's Double-precision `RVec2`/`RVec3` (Linux-safe,
//  Foundation-only) and the renderer's `SIMD2<Float>`/`SIMD3<Float>`, plus camera-preset
//  and colour conveniences used by OrbitCamera, SceneUpdater and UniformBuilder.
//

import Foundation
import simd
import RitualCore

// MARK: - RVec → simd

extension RVec2 {
    /// Single-precision simd copy.
    var simd: SIMD2<Float> { SIMD2<Float>(Float(x), Float(y)) }
    /// Double-precision simd copy.
    var simdDouble: SIMD2<Double> { SIMD2<Double>(x, y) }
}

extension RVec3 {
    /// Single-precision simd copy.
    var simd: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
    /// Double-precision simd copy.
    var simdDouble: SIMD3<Double> { SIMD3<Double>(x, y, z) }
}

// MARK: - simd → RVec

extension SIMD2 where Scalar == Float {
    /// RitualCore vector (Double).
    var rvec: RVec2 { RVec2(Double(x), Double(y)) }
}

extension SIMD3 where Scalar == Float {
    /// RitualCore vector (Double).
    var rvec: RVec3 { RVec3(Double(x), Double(y), Double(z)) }
}

extension SIMD2 where Scalar == Double {
    /// RitualCore vector.
    var rvec: RVec2 { RVec2(x, y) }
}

extension SIMD3 where Scalar == Double {
    /// RitualCore vector.
    var rvec: RVec3 { RVec3(x, y, z) }
}

// MARK: - Presets and colours

extension CameraPreset {
    /// Preset eye position in metres.
    var positionSIMD: SIMD3<Float> { position.simd }
    /// Preset look-at target in metres.
    var targetSIMD: SIMD3<Float> { target.simd }
}

extension RitualElement {
    /// Linear-RGB flame tint as simd.
    var flameColorSIMD: SIMD3<Float> { flameColorLinearRGB.simd }
    /// Flame blackbody temperature as Float (0 = colour only).
    var flameTemperatureKelvin: Float { Float(flameTemperatureK) }
}

extension Quarter {
    /// Candle stand floor position as simd.
    var candlePositionSIMD: SIMD3<Float> { candlePosition.simd }
    /// Flame origin (y = 1.13 m) as simd.
    var flamePositionSIMD: SIMD3<Float> { flamePosition.simd }
    /// Yaw the camera must face, as Float degrees.
    var yawDegreesFloat: Float { Float(yawDegrees) }
}

extension DaemonProfile {
    /// Palette (core, mid, edge) as simd linear RGB for `DaemonParams`.
    var paletteSIMD: (core: SIMD3<Float>, mid: SIMD3<Float>, edge: SIMD3<Float>) {
        let palette = paletteLinearRGB
        return (palette.core.simd, palette.mid.simd, palette.edge.simd)
    }
}

// MARK: - Seed split (matches Hash.u32 / hash_u32)

extension UInt64 {
    /// Low 32 bits — `FrameUniforms.seedLo`.
    var seedLo: UInt32 { UInt32(truncatingIfNeeded: self) }
    /// High 32 bits — `FrameUniforms.seedHi`.
    var seedHi: UInt32 { UInt32(truncatingIfNeeded: self >> 32) }
}
