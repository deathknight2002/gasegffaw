//
//  SigilPicker.swift
//  Bornless Ritual — screen ↔ sigil-plane geometry for the flick gesture and ring picking
//  (ARCHITECTURE §3 "flick impulse applied to the ring under the finger (or ring 0 if
//  none)"; CORE_API / `SigilDynamics.applyFlick`: the flick velocity is expressed in the
//  ring's tangential frame, +x along the tangent at the touch point in the direction of
//  increasing ring angle; RENDER_CONTRACT §2 row 10 / Sigil.metal
//  `rotate_about_sigil_axis`: ring angle θ maps the rim point (cos θ, 0, sin θ) about the
//  sigil centre, so the increasing-angle tangent at rim offset d is cross(d, +Y)).
//
//  Role: pure value-type math over `OrbitCamera` (no UIKit) — builds the camera ray
//  through a view point, intersects the horizontal sigil plane at y = 1.55 m, picks the
//  nearest ring by radius and rotates a screen-space swipe velocity (points/s, y down)
//  into the ring's tangential frame in normalised units per second (points ÷ 300). Kept
//  free of UIKit so it parses on Linux and can be exercised with synthetic cameras.
//

import Foundation
import simd
import RitualCore

/// Ray casting and ring picking against the sigil plane for one camera and view size.
struct SigilPicker {
    /// Sigil centre (ARCHITECTURE §2: floats at (0, 1.55, 0), plane normal +Y).
    static let center = SIMD3<Float>(0, 1.55, 0)
    /// Ring radii, outer → inner (`SigilDynamics.ringRadii`: 0.75, 0.62, 0.50, 0.39, 0.29).
    static let ringRadii: [Float] = SigilDynamics.ringRadii.map { Float($0) }
    /// Radial margin beyond the outer ring that still counts as touching the sigil (metres).
    static let flickMargin: Float = 0.15
    /// Screen velocity divisor: points/s ÷ 300 = normalised sigil units/s.
    static let pointsPerUnit: Float = 300
    /// Rays whose direction has a smaller |y| component are treated as parallel to the plane.
    static let minimumPlaneCosine: Float = 1e-4
    /// World-space step used to project the tangent direction onto the screen (metres).
    static let tangentProbeLength: Float = 0.05

    /// Camera the view is rendered with.
    var camera: OrbitCamera
    /// View size in points.
    var viewSize: SIMD2<Float>

    /// Where a view point's ray meets the sigil plane.
    struct PlaneHit: Equatable {
        /// World position on the plane.
        var position: SIMD3<Float>
        /// Distance from the sigil centre within the plane (metres).
        var radial: Float
        /// Nearest ring by radius (0 = outer), or `nil` when the touch is outside the sigil.
        var ring: Int?

        /// True when the touch lies within the outer ring plus `flickMargin`.
        var onSigil: Bool { ring != nil }
    }

    /// Creates a picker for a camera and a view size in points.
    init(camera: OrbitCamera, viewSize: SIMD2<Float>) {
        self.camera = camera
        self.viewSize = viewSize
    }

    /// Aspect ratio (width / height); degenerate sizes are treated as 1 × 1.
    var aspect: Float {
        max(viewSize.x, 1) / max(viewSize.y, 1)
    }

    /// tan(fovY / 2), the half-height of the image plane at unit depth.
    private var tanHalfFov: Float {
        tan(camera.fovY * 0.5)
    }

    // MARK: Rays and projection

    /// Camera ray through a view point (points, origin top-left, y down).
    ///
    /// The direction matches `float4x4.perspectiveReversedZ`: NDC x scales by
    /// tan(fovY/2)·aspect along the camera's right axis, NDC y by tan(fovY/2) along up.
    func ray(through point: SIMD2<Float>) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let ndcX = 2 * (point.x / max(viewSize.x, 1)) - 1
        let ndcY = 1 - 2 * (point.y / max(viewSize.y, 1))
        let halfHeight = tanHalfFov
        let direction = camera.right * (ndcX * halfHeight * aspect)
            + camera.up * (ndcY * halfHeight)
            + camera.forward
        return (camera.position, direction.safeNormalized(fallback: camera.forward))
    }

    /// Projects a world point to view points (y down); `nil` at or behind the camera plane.
    func project(_ world: SIMD3<Float>) -> SIMD2<Float>? {
        let relative = world - camera.position
        let depth = simd_dot(relative, camera.forward)
        guard depth > 1e-4 else { return nil }
        let halfHeight = tanHalfFov
        let ndcX = simd_dot(relative, camera.right) / depth / (halfHeight * aspect)
        let ndcY = simd_dot(relative, camera.up) / depth / halfHeight
        return SIMD2<Float>((ndcX + 1) * 0.5 * viewSize.x, (1 - ndcY) * 0.5 * viewSize.y)
    }

    // MARK: Plane hits and rings

    /// Intersects the ray through `point` with the sigil plane; `nil` when the ray is
    /// parallel to the plane or the plane lies behind the camera.
    func planeHit(at point: SIMD2<Float>) -> PlaneHit? {
        let cameraRay = ray(through: point)
        let cosine = cameraRay.direction.y
        guard abs(cosine) > SigilPicker.minimumPlaneCosine else { return nil }
        let distance = (SigilPicker.center.y - cameraRay.origin.y) / cosine
        guard distance > 0 else { return nil }
        let position = cameraRay.origin + cameraRay.direction * distance
        let offset = SIMD2<Float>(position.x - SigilPicker.center.x, position.z - SigilPicker.center.z)
        let radial = simd_length(offset)
        return PlaneHit(position: position, radial: radial, ring: SigilPicker.nearestRing(radial: radial))
    }

    /// Nearest ring index for a radial distance, or `nil` outside the outer ring + margin.
    static func nearestRing(radial: Float) -> Int? {
        guard let outer = ringRadii.first, radial.isFinite, radial <= outer + flickMargin else { return nil }
        var best = 0
        var bestDelta = Float.greatestFiniteMagnitude
        for (index, radius) in ringRadii.enumerated() {
            let delta = abs(radial - radius)
            if delta < bestDelta {
                bestDelta = delta
                best = index
            }
        }
        return best
    }

    /// The ring under a view point (nearest ring radius on the sigil plane), or `nil`.
    func ringUnderTouch(_ point: SIMD2<Float>) -> Int? {
        planeHit(at: point)?.ring
    }

    /// Unit screen direction (points, y down) in which the ring under `hit` moves when its
    /// angle increases; screen-right when the direction cannot be projected.
    func screenTangent(at hit: PlaneHit) -> SIMD2<Float> {
        let fallback = SIMD2<Float>(1, 0)
        let offset = SIMD3<Float>(hit.position.x - SigilPicker.center.x, 0, hit.position.z - SigilPicker.center.z)
        guard simd_length(offset) > 1e-3 else { return fallback }
        // Rim point (cos θ, 0, sin θ) → d/dθ = (−sin θ, 0, cos θ) = cross(offset, +Y).
        let tangentWorld = simd_cross(offset, SIMD3<Float>(0, 1, 0)).safeNormalized(fallback: SIMD3<Float>(1, 0, 0))
        guard let start = project(hit.position),
              let end = project(hit.position + tangentWorld * SigilPicker.tangentProbeLength) else {
            return fallback
        }
        let delta = end - start
        let length = simd_length(delta)
        guard length > 1e-5 else { return fallback }
        return delta / length
    }

    /// Rotates a swipe velocity (points/s, y down) into the ring frame `applyFlick` expects:
    /// x = signed tangential component ÷ 300 (normalised units/s), y = 0, plus the ring
    /// under the touch. Off the sigil plane the swipe's screen-x component is used.
    func flickInput(swipe velocity: SIMD2<Float>, at point: SIMD2<Float>) -> (velocity: RVec2, ring: Int?) {
        guard let hit = planeHit(at: point) else {
            return (RVec2(Double(velocity.x / SigilPicker.pointsPerUnit), 0), nil)
        }
        let tangent = screenTangent(at: hit)
        let tangential = simd_dot(velocity, tangent) / SigilPicker.pointsPerUnit
        return (RVec2(Double(tangential), 0), hit.ring)
    }

    /// Metres of target motion per point of drag at the orbit target's depth (for panning).
    var metresPerPointAtTarget: Float {
        2 * camera.distance * tanHalfFov / max(viewSize.y, 1)
    }
}
