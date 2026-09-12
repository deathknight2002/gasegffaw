//
//  OrbitCamera.swift
//  Bornless Ritual — orbit camera (RENDER_CONTRACT §1 `OrbitCamera`; ARCHITECTURE §2
//  presets, FOV 50°, near 0.05 m, far 30 m, reversed-Z; yaw convention "measured from
//  +Z toward +X", i.e. `forwardYawDegrees = atan2(forward.x, forward.z)` normalised to
//  [0, 360): looking toward +X reports 90 (East), +Z → 0 (South), −Z → 180 (North),
//  −X → 270 (West)).
//
//  Role: value type holding the orbit parameters, producing view / projection matrices
//  and the yaw the simulation's "facing a quarter" gate consumes.
//
//  Parameterisation: `yaw` and `pitch` are radians. `yaw` IS the forward yaw (so the
//  reported degrees are simply `yaw` wrapped); `pitch` is the camera's elevation above
//  the target (positive = camera above the target, looking down).
//    forward  = (sin yaw · cos pitch, −sin pitch, cos yaw · cos pitch)
//    position = target − forward · distance
//

import Foundation
import simd
import RitualCore

/// Orbit camera around a target point.
struct OrbitCamera: Equatable {
    /// Orbit centre (metres). Default (0, 1, 0) per ARCHITECTURE §2.
    var target: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    /// Forward yaw in radians (see header for the convention).
    var yaw: Float = Float.pi
    /// Elevation of the camera above the target in radians (positive = looking down).
    var pitch: Float = 0.1
    /// Distance from the target in metres.
    var distance: Float = 4.6
    /// Vertical field of view in radians (50°).
    var fovY: Float = Float(50.0).degreesToRadians
    /// Near plane in metres.
    var near: Float = Float(CameraPreset.nearPlane)
    /// Far plane in metres (finite; reversed-Z maps it to depth 0).
    var far: Float = Float(CameraPreset.farPlane)

    /// Limits keeping the camera inside the chamber and off the floor.
    static let minDistance: Float = 0.25
    static let maxDistance: Float = 8.0
    static let minPitch: Float = Float(-25.0).degreesToRadians
    static let maxPitch: Float = Float(89.0).degreesToRadians
    static let minHeight: Float = 0.12
    static let upVector = SIMD3<Float>(0, 1, 0)

    /// Creates a camera from explicit orbit parameters.
    init(target: SIMD3<Float> = SIMD3<Float>(0, 1, 0), yaw: Float = Float.pi, pitch: Float = 0.1, distance: Float = 4.6) {
        self.target = target
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
    }

    /// Creates a camera looking from `position` at `target` (derives yaw / pitch / distance).
    init(position: SIMD3<Float>, target: SIMD3<Float>) {
        self.target = target
        let offset = target - position
        let length = simd_length(offset)
        self.distance = max(length, OrbitCamera.minDistance)
        let forward = length > 1e-6 ? offset / length : SIMD3<Float>(0, 0, -1)
        self.yaw = atan2(forward.x, forward.z)
        self.pitch = asin(min(max(-forward.y, -1), 1))
    }

    // MARK: Derived

    /// Unit forward vector (from the camera toward the target).
    var forward: SIMD3<Float> {
        let cosPitch = cos(pitch)
        return SIMD3<Float>(sin(yaw) * cosPitch, -sin(pitch), cos(yaw) * cosPitch)
    }

    /// Unit right vector (perpendicular to forward, horizontal).
    var right: SIMD3<Float> {
        simd_cross(forward, OrbitCamera.upVector).safeNormalized(fallback: SIMD3<Float>(1, 0, 0))
    }

    /// Unit up vector of the camera frame.
    var up: SIMD3<Float> {
        simd_cross(right, forward).safeNormalized(fallback: OrbitCamera.upVector)
    }

    /// Eye position in metres.
    var position: SIMD3<Float> {
        target - forward * distance
    }

    /// Camera yaw in degrees, [0, 360): `atan2(forward.x, forward.z)`.
    var forwardYawDegrees: Float {
        forward.yawDegreesFromPlusZ
    }

    /// Yaw in degrees (get: same as `forwardYawDegrees`; set: replaces `yaw`).
    var yawDegrees: Float {
        get { forwardYawDegrees }
        set { yaw = newValue.degreesToRadians }
    }

    /// Pitch in degrees.
    var pitchDegrees: Float {
        get { pitch.radiansToDegrees }
        set { pitch = newValue.degreesToRadians }
    }

    // MARK: Matrices

    /// World → view matrix (right-handed, view looks down −Z).
    func viewMatrix() -> float4x4 {
        float4x4.lookAt(eye: position, target: target, up: OrbitCamera.upVector)
    }

    /// Reversed-Z projection (near → 1, far → 0) with a jitter in NDC units.
    ///
    /// - Parameters:
    ///   - aspect: width / height of the render target.
    ///   - jitter: sub-pixel offset in NDC (`2 · px / renderSize`, y up); pass `.zero` for
    ///     the un-jittered matrix used by motion vectors.
    func projection(aspect: Float, jitter: SIMD2<Float>) -> float4x4 {
        float4x4.perspectiveReversedZ(fovYRadians: fovY, aspect: aspect, near: near, far: far, jitterNDC: jitter)
    }

    /// Un-jittered reversed-Z projection.
    func projection(aspect: Float) -> float4x4 {
        projection(aspect: aspect, jitter: SIMD2<Float>(0, 0))
    }

    // MARK: Presets

    /// The camera for a critic/debug preset (ARCHITECTURE §2 positions and targets).
    static func preset(_ preset: CameraPreset) -> OrbitCamera {
        OrbitCamera(position: preset.positionSIMD, target: preset.targetSIMD)
    }

    // MARK: Interaction

    /// Orbits by `dx` (yaw, radians; positive turns the view toward +X when facing +Z)
    /// and `dy` (pitch, radians; positive raises the camera). Pitch is clamped.
    mutating func orbit(dx: Float, dy: Float) {
        yaw += dx
        pitch = ScalarMath.clamp(pitch + dy, OrbitCamera.minPitch, OrbitCamera.maxPitch)
        enforceHeight()
    }

    /// Pans the target along the camera's right / up axes by `dx` / `dy` metres.
    mutating func pan(dx: Float, dy: Float) {
        target += right * dx + up * dy
        target.y = max(target.y, 0.05)
        enforceHeight()
    }

    /// Zooms by dividing the distance by `scale` (pinch scale > 1 moves closer). Clamped.
    mutating func zoom(scale: Float) {
        guard scale > 1e-4 else { return }
        distance = ScalarMath.clamp(distance / scale, OrbitCamera.minDistance, OrbitCamera.maxDistance)
        enforceHeight()
    }

    /// Sets the forward yaw in degrees (used by the capture harness and the quarter gate tests).
    mutating func setYawDegrees(_ degrees: Float) {
        yaw = degrees.degreesToRadians
    }

    /// Raises the pitch just enough to keep the eye above `minHeight` (the floor is y = 0).
    private mutating func enforceHeight() {
        var iterations = 0
        while position.y < OrbitCamera.minHeight && pitch < OrbitCamera.maxPitch && iterations < 64 {
            pitch += Float(0.5).degreesToRadians
            iterations += 1
        }
    }
}
