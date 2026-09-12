import Foundation

// MARK: - RingState

/// Rotational state of one sigil ring (ARCHITECTURE §3, "Sigil spin").
///
/// Rings are rigid hoops spinning about the sigil's vertical (+Y) axis. `angle` is the
/// phase of the ring's rune pattern and is kept in `[0, 2π)`; `omega` is signed so that
/// adjacent rings can counter-rotate.
public struct RingState: Codable, Sendable, Equatable {
    /// Rotation angle in radians, wrapped to `[0, 2π)`.
    public var angle: Double
    /// Angular velocity in rad/s (positive = increasing `angle`).
    public var omega: Double
    /// Ring radius in metres.
    public let radius: Double
    /// Moment of inertia `m·r²` in kg·m².
    public let inertia: Double

    /// Creates a ring.
    ///
    /// - Parameters:
    ///   - angle: Initial angle in radians (wrapped to `[0, 2π)`).
    ///   - omega: Initial angular velocity in rad/s.
    ///   - radius: Ring radius in metres.
    ///   - inertia: Moment of inertia in kg·m².
    public init(angle: Double = 0, omega: Double = 0, radius: Double, inertia: Double) {
        self.angle = SigilDynamics.wrapAngle(angle)
        self.omega = omega
        self.radius = radius
        self.inertia = inertia
    }

    /// Rotational kinetic energy `½·I·ω²` in joules.
    public var kineticEnergy: Double {
        0.5 * inertia * omega * omega
    }

    /// Sign of the rotation: `+1`, `−1`, or `0` when the ring is at rest.
    public var rotationSign: Double {
        if omega > 0 { return 1 }
        if omega < 0 { return -1 }
        return 0
    }
}

// MARK: - SigilDynamics

/// Rigid-body dynamics of the five nested sigil rings (ARCHITECTURE §3, CORE_API).
///
/// Each ring `i` feels a viscous torque `−viscous·ω_i`, a Coulomb torque
/// `−coulomb·sign(ω_i)`, and a coupling torque `−coupling·(ω_i + ω_j)` for every
/// neighbouring ring `j`, which drives adjacent rings to counter-rotate. The rings are
/// integrated with semi-implicit (symplectic) Euler at the simulation's fixed `dt`:
/// velocities first, then angles using the updated velocities. Coulomb friction can only
/// bring a ring to rest, never reverse it. All maths is plain `Double` arithmetic so a
/// run replays bit-identically.
public struct SigilDynamics: Codable, Sendable, Equatable {
    /// Ring radii in metres, outermost first (ARCHITECTURE §3).
    public static let ringRadii: [Double] = [0.75, 0.62, 0.50, 0.39, 0.29]
    /// Ring masses in kilograms, outermost first; `I = m·r²`.
    public static let ringMasses: [Double] = [0.30, 0.25, 0.20, 0.16, 0.12]
    /// Number of rings.
    public static let ringCount = 5
    /// Default viscous friction coefficient in N·m·s (CORE_API): ring 0 spins down with
    /// `τ = I₀ / viscous ≈ 5.6 s`, so its momentum is visibly conserved between flicks.
    public static let defaultViscous = 0.03
    /// Default Coulomb friction torque in N·m (CORE_API); brings the rings to an exact stop.
    public static let defaultCoulomb = 0.008
    /// Default coupling coefficient between adjacent rings in N·m·s (CORE_API).
    public static let defaultCoupling = 0.12
    /// Flick speeds are clamped to this magnitude before the impulse is computed.
    public static let maxFlickSpeed = 4.0
    /// Upper bound applied to `frictionScale` in ``step(dt:frictionScale:)``.
    ///
    /// The viscous and coupling torques are integrated explicitly, which is stable only
    /// while `(viscous·scale + 2·coupling)·dt / I_min < 2` (≈ scale 73 for the innermost
    /// ring at 120 Hz) and free of overshoot below half that. Clamping at 10 keeps every
    /// ring's decay monotone with a threefold margin while covering the 0–3 debug slider
    /// generously; scales above the clamp behave exactly like the clamp.
    public static let maxFrictionScale = 10.0
    /// Angular impulse per unit of (clamped) flick speed, in N·m·s (CORE_API).
    ///
    /// A full-speed autopilot flick (`|v| = 3.5`) delivers `J ≈ 1.2 N·m·s`, spinning ring 0
    /// up to ≈ 7 rad/s; with `E_ref = 20 J·s` the three autopilot flicks charge the
    /// manifestation a few seconds after the third one.
    public static let flickImpulsePerSpeed = 0.35
    /// Fraction of the flick impulse delivered to each adjacent ring (negative = counter-rotation).
    public static let adjacentImpulseFraction = -0.5
    /// Spark shedding rate per unit of rim speed: sparks/s per (rad/s·m).
    public static let sparksPerRimSpeed = 40.0

    /// Ring states, outermost first (`ringCount` entries).
    public var rings: [RingState]
    /// Viscous friction coefficient in N·m·s (scaled by the friction slider at step time).
    public var viscous: Double
    /// Coulomb friction torque in N·m (scaled by the friction slider at step time).
    public var coulomb: Double
    /// Coupling coefficient between adjacent rings in N·m·s.
    public var coupling: Double

    /// Creates the five rings at rest with the contract radii, masses and coefficients.
    public init() {
        rings = zip(Self.ringRadii, Self.ringMasses).map { radius, mass in
            RingState(angle: 0, omega: 0, radius: radius, inertia: mass * radius * radius)
        }
        viscous = Self.defaultViscous
        coulomb = Self.defaultCoulomb
        coupling = Self.defaultCoupling
    }

    /// Wraps an angle in radians into `[0, 2π)`.
    public static func wrapAngle(_ radians: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        var wrapped = radians.truncatingRemainder(dividingBy: twoPi)
        if wrapped < 0 {
            wrapped += twoPi
        }
        if wrapped >= twoPi {
            wrapped -= twoPi
        }
        return wrapped + 0.0
    }

    /// Advances every ring by `dt` seconds with semi-implicit Euler.
    ///
    /// The viscous and coupling torques are evaluated from the velocities at the start of
    /// the step (a Jacobi update, so the result does not depend on ring order), the
    /// velocities are updated, and the angles then advance with the *new* velocities.
    /// The Coulomb decrement `coulomb·dt/I` is then taken from the velocity that remains,
    /// against its own sign, and clamped at zero: a moving ring stops exactly at rest and
    /// is never pushed through zero, and a ring at rest that is nudged by its neighbours
    /// by less than the decrement stays at rest (Coulomb friction acts as static friction
    /// of the same magnitude, so the system settles to an exact all-zero state).
    ///
    /// - Parameters:
    ///   - dt: Time step in seconds (the simulation uses `1/120`).
    ///   - frictionScale: Multiplier applied to both `viscous` and `coulomb` (the
    ///     debug-panel friction slider), clamped to `0…maxFrictionScale`; the coupling
    ///     coefficient is not scaled.
    public mutating func step(dt: Double, frictionScale: Double) {
        guard dt > 0, !rings.isEmpty else { return }
        let scale = min(max(0, frictionScale), Self.maxFrictionScale)
        let viscousCoefficient = viscous * scale
        let coulombTorque = coulomb * scale
        let startOmegas = rings.map(\.omega)

        for index in rings.indices {
            let omega = startOmegas[index]
            let inertia = rings[index].inertia
            var torque = -viscousCoefficient * omega
            if index > 0 {
                torque -= coupling * (omega + startOmegas[index - 1])
            }
            if index + 1 < startOmegas.count {
                torque -= coupling * (omega + startOmegas[index + 1])
            }
            var updated = omega + (torque / inertia) * dt

            if updated != 0 {
                let sign: Double = updated > 0 ? 1 : -1
                let decrement = (coulombTorque / inertia) * dt
                let afterCoulomb = updated - sign * decrement
                updated = afterCoulomb * sign > 0 ? afterCoulomb : 0
            }

            rings[index].omega = updated
            rings[index].angle = Self.wrapAngle(rings[index].angle + updated * dt)
        }
    }

    /// Applies a flick gesture as an angular impulse.
    ///
    /// The impulse magnitude is `clamp(|velocity|, 0, maxFlickSpeed) · flickImpulsePerSpeed`.
    /// Its sign comes from the tangential direction of the gesture: the flick is read at
    /// the point of the ring nearest the viewer (screen-bottom, x right), where the ring's
    /// tangent is +x, so a rightward flick (`velocity.x ≥ 0`) spins the ring positive and
    /// a leftward flick spins it negative. The ring under the finger receives the full
    /// impulse; each adjacent ring receives `adjacentImpulseFraction` (−0.5) of it, so
    /// neighbours counter-rotate.
    ///
    /// Convention for callers (the app's gesture recogniser): `velocity` is expressed in
    /// the ring's local frame with +x along the tangent at the touch point in the
    /// direction of increasing angle. The input carries no touch position, so the core
    /// cannot project a screen-space swipe onto the ring itself; a recogniser must rotate
    /// the swipe velocity into this frame before emitting `InputKind.flick`, otherwise a
    /// radial swipe (x ≈ 0) would still deliver the full |v| impulse with a +x sign.
    ///
    /// - Parameters:
    ///   - velocity: Gesture velocity in the ring's tangential frame (see above), in
    ///     normalised sigil-plane units per second.
    ///   - ring: Index of the ring under the finger (0…4), or `nil` for the outer ring.
    ///     Out-of-range indices are clamped to the nearest ring.
    public mutating func applyFlick(velocity: RVec2, ring: Int?) {
        guard !rings.isEmpty else { return }
        let target = min(max(ring ?? 0, 0), rings.count - 1)
        let speed = min(max(velocity.length, 0), Self.maxFlickSpeed)
        guard speed > 0 else { return }
        let sign: Double = velocity.x < 0 ? -1 : 1
        let impulse = sign * speed * Self.flickImpulsePerSpeed

        rings[target].omega += impulse / rings[target].inertia
        for neighbour in [target - 1, target + 1] where rings.indices.contains(neighbour) {
            rings[neighbour].omega += Self.adjacentImpulseFraction * impulse / rings[neighbour].inertia
        }
    }

    /// Total rotational kinetic energy `Σ ½·I_i·ω_i²` in joules (the spin energy `E`).
    public var kineticEnergy: Double {
        rings.reduce(0) { $0 + $1.kineticEnergy }
    }

    /// Spark shedding rate in sparks/s: `Σ |ω_i|·r_i × sparksPerRimSpeed`.
    public var sparkRate: Double {
        rings.reduce(0) { $0 + abs($1.omega) * $1.radius } * Self.sparksPerRimSpeed
    }

    /// Whether every ring is at rest.
    public var isAtRest: Bool {
        rings.allSatisfy { $0.omega == 0 }
    }
}
