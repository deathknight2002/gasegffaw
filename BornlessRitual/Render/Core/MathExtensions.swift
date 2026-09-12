//
//  MathExtensions.swift
//  Bornless Ritual — simd helpers for the renderer (ARCHITECTURE §2 conventions,
//  RENDER_CONTRACT §1/§3: reversed-Z projection with finite far plane and NDC jitter).
//
//  Role: matrix constructors (translation / rotation / scale / look-at / perspective),
//  quaternion conveniences and angle utilities. Right-handed, metres, +Y up; view
//  space looks down −Z. Matrices are column-major (`columns.0` is the first column).
//

import Foundation
import simd

// MARK: - Angles

extension Float {
    /// Degrees → radians.
    var degreesToRadians: Float { self * (Float.pi / 180) }
    /// Radians → degrees.
    var radiansToDegrees: Float { self * (180 / Float.pi) }

    /// Wraps a value in degrees into `[0, 360)`.
    static func wrapDegrees0to360(_ degrees: Float) -> Float {
        var remainder = degrees.truncatingRemainder(dividingBy: 360)
        if remainder < 0 { remainder += 360 }
        if remainder >= 360 { remainder -= 360 }
        return remainder + 0
    }

    /// Wraps a value in degrees into `(-180, 180]`.
    static func wrapDegrees180(_ degrees: Float) -> Float {
        let wrapped = wrapDegrees0to360(degrees)
        return wrapped > 180 ? wrapped - 360 : wrapped
    }
}

// MARK: - float4x4 constructors

extension float4x4 {
    /// The identity matrix.
    static var identity: float4x4 { matrix_identity_float4x4 }

    /// Translation by `t`.
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    }

    /// Non-uniform scale.
    init(scale s: SIMD3<Float>) {
        self.init(columns: (SIMD4<Float>(s.x, 0, 0, 0),
                            SIMD4<Float>(0, s.y, 0, 0),
                            SIMD4<Float>(0, 0, s.z, 0),
                            SIMD4<Float>(0, 0, 0, 1)))
    }

    /// Uniform scale.
    init(uniformScale s: Float) {
        self.init(scale: SIMD3<Float>(repeating: s))
    }

    /// Rotation of `angleRadians` about a unit `axis` (right-handed).
    init(rotationAxis axis: SIMD3<Float>, angleRadians: Float) {
        let quaternion = simd_quatf(angle: angleRadians, axis: simd_normalize(axis))
        self = float4x4(quaternion)
    }

    /// Rotation about +X.
    init(rotationX radians: Float) {
        let c = cos(radians), s = sin(radians)
        self.init(columns: (SIMD4<Float>(1, 0, 0, 0),
                            SIMD4<Float>(0, c, s, 0),
                            SIMD4<Float>(0, -s, c, 0),
                            SIMD4<Float>(0, 0, 0, 1)))
    }

    /// Rotation about +Y (yaw).
    init(rotationY radians: Float) {
        let c = cos(radians), s = sin(radians)
        self.init(columns: (SIMD4<Float>(c, 0, -s, 0),
                            SIMD4<Float>(0, 1, 0, 0),
                            SIMD4<Float>(s, 0, c, 0),
                            SIMD4<Float>(0, 0, 0, 1)))
    }

    /// Rotation about +Z.
    init(rotationZ radians: Float) {
        let c = cos(radians), s = sin(radians)
        self.init(columns: (SIMD4<Float>(c, s, 0, 0),
                            SIMD4<Float>(-s, c, 0, 0),
                            SIMD4<Float>(0, 0, 1, 0),
                            SIMD4<Float>(0, 0, 0, 1)))
    }

    /// Model matrix = translation · rotation · scale.
    init(translation t: SIMD3<Float>, rotation q: simd_quatf, scale s: SIMD3<Float>) {
        self = float4x4(translation: t) * float4x4(q) * float4x4(scale: s)
    }

    /// Right-handed view matrix looking from `eye` toward `target` with `up` (world → view;
    /// view space looks down −Z).
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let forward = simd_normalize(target - eye)          // −Z axis of the camera
        var upVector = up
        if simd_length(simd_cross(forward, upVector)) < 1e-4 {
            // Looking straight up/down: pick a stable alternative up vector.
            upVector = SIMD3<Float>(0, 0, -1)
        }
        let right = simd_normalize(simd_cross(forward, upVector))
        let trueUp = simd_cross(right, forward)
        let rotation = float4x4(columns: (SIMD4<Float>(right.x, trueUp.x, -forward.x, 0),
                                          SIMD4<Float>(right.y, trueUp.y, -forward.y, 0),
                                          SIMD4<Float>(right.z, trueUp.z, -forward.z, 0),
                                          SIMD4<Float>(0, 0, 0, 1)))
        let translation = float4x4(translation: -eye)
        return rotation * translation
    }

    /// Reversed-Z perspective projection with a finite far plane: view-space distance
    /// `near` maps to NDC depth 1 and `far` to 0 (ARCHITECTURE §2: near 0.05 m, far 30 m).
    ///
    /// Inverse mapping used by the shaders (`linearize_depth` in Common.h):
    /// `t = near·far / (d·(far − near) + near)`.
    static func perspectiveReversedZ(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let yScale = 1 / tan(fovYRadians * 0.5)
        let xScale = yScale / max(aspect, 1e-6)
        let zScale = near / (far - near)
        let zOffset = near * far / (far - near)
        return float4x4(columns: (SIMD4<Float>(xScale, 0, 0, 0),
                                  SIMD4<Float>(0, yScale, 0, 0),
                                  SIMD4<Float>(0, 0, zScale, -1),
                                  SIMD4<Float>(0, 0, zOffset, 0)))
    }

    /// Reversed-Z perspective with a sub-pixel jitter expressed in NDC units
    /// (`jitterNDC = 2 · pixelOffset / renderSize`, y up). The result satisfies
    /// `ndc = unjittered_ndc + jitterNDC` for every view-space point.
    static func perspectiveReversedZ(fovYRadians: Float, aspect: Float, near: Float, far: Float,
                                     jitterNDC: SIMD2<Float>) -> float4x4 {
        var projection = perspectiveReversedZ(fovYRadians: fovYRadians, aspect: aspect, near: near, far: far)
        // clip.w = −z_view, so adding −jitter·z_view to clip.xy shifts NDC by +jitter.
        projection.columns.2.x = -jitterNDC.x
        projection.columns.2.y = -jitterNDC.y
        return projection
    }

    /// Upper-left 3×3 block.
    var upperLeft3x3: float3x3 {
        float3x3(columns: (SIMD3<Float>(columns.0.x, columns.0.y, columns.0.z),
                           SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z),
                           SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z)))
    }

    /// Inverse-transpose of the upper 3×3, embedded in a 4×4 (for `InstanceData.normalMatrix`).
    var normalMatrix: float4x4 {
        let inverseTranspose = upperLeft3x3.inverse.transpose
        return float4x4(columns: (SIMD4<Float>(inverseTranspose.columns.0, 0),
                                  SIMD4<Float>(inverseTranspose.columns.1, 0),
                                  SIMD4<Float>(inverseTranspose.columns.2, 0),
                                  SIMD4<Float>(0, 0, 0, 1)))
    }

    /// Translation component.
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    /// Transforms a point (w = 1) and divides by w.
    func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = self * SIMD4<Float>(p, 1)
        let w = abs(v.w) > 1e-7 ? v.w : 1
        return SIMD3<Float>(v.x, v.y, v.z) / w
    }

    /// Transforms a direction (w = 0).
    func transformDirection(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let v = self * SIMD4<Float>(d, 0)
        return SIMD3<Float>(v.x, v.y, v.z)
    }
}

// MARK: - Quaternion helpers

extension simd_quatf {
    /// The identity rotation.
    static var identity: simd_quatf { simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }

    /// Components as (x, y, z, w), the layout of `SDFPrimitive.rotation` and `quat_rotate` in Common.h.
    var xyzw: SIMD4<Float> {
        SIMD4<Float>(imag.x, imag.y, imag.z, real)
    }

    /// Builds a quaternion from (x, y, z, w) components.
    init(xyzw v: SIMD4<Float>) {
        self.init(ix: v.x, iy: v.y, iz: v.z, r: v.w)
    }

    /// Yaw about +Y (radians).
    static func yaw(_ radians: Float) -> simd_quatf {
        simd_quatf(angle: radians, axis: SIMD3<Float>(0, 1, 0))
    }

    /// Shortest rotation taking unit vector `from` onto unit vector `to`.
    static func rotation(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        simd_quatf(from: simd_normalize(from), to: simd_normalize(to))
    }

    /// Rotates `v` by this quaternion.
    func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
        act(v)
    }
}

// MARK: - Vector helpers

extension SIMD3 where Scalar == Float {
    /// Unit vector, or `fallback` when the length is numerically zero.
    func safeNormalized(fallback: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(self)
        return lengthSquared > 1e-12 ? self / lengthSquared.squareRoot() : fallback
    }

    /// Yaw (degrees, `[0, 360)`) of a direction measured from +Z toward +X — the camera yaw
    /// convention of ARCHITECTURE §2 (`atan2(x, z)`): +X → 90, +Z → 0, −Z → 180, −X → 270.
    var yawDegreesFromPlusZ: Float {
        Float.wrapDegrees0to360(atan2(x, z).radiansToDegrees)
    }
}

extension SIMD2 where Scalar == Float {
    /// Component-wise conversion to a size.
    var cgSize: CGSize { CGSize(width: CGFloat(x), height: CGFloat(y)) }
}

/// Scalar helpers named to avoid clashing with the simd overlay's free functions.
enum ScalarMath {
    /// Linear interpolation `a + (b − a)·t` (unclamped).
    static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    /// Hermite smoothstep of `x` between `edge0` and `edge1`.
    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / max(edge1 - edge0, 1e-6), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Clamps `x` to `[lo, hi]`.
    static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        min(max(x, lo), hi)
    }

    /// Clamps `x` to `[lo, hi]`.
    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }
}
