import Foundation

/// Closed-form ballistics of the sparks shed by the spinning sigil (ARCHITECTURE §6).
///
/// An ember is a millimetre-scale glowing particle in the Stokes regime: linear drag
/// `k = dragK` and gravity `g` give the terminal velocity `v_t = g/k` (downward, −Y) and
/// the trajectory `x(τ) = x0 + v_t·τ + (v0 − v_t)(1 − e^{−kτ})/k`. Because the position is
/// a pure function of the spawn state and the elapsed time, the renderer can evaluate any
/// ember at any tick without integrating, and rewinds are exact. The curl-noise
/// turbulence displacement mentioned in §6 is a render-side term and is not part of this
/// model.
public enum EmberModel {
    /// Linear drag coefficient in 1/s.
    public static let dragK = 6.0
    /// Ember lifetime in seconds.
    public static let lifetime = 2.5
    /// Blackbody temperature at spawn in kelvin.
    public static let tempStartK = 1900.0
    /// Blackbody temperature at the end of life in kelvin.
    public static let tempEndK = 800.0
    /// Standard gravity in m/s²; `gravity = standardGravity × gravityScale`.
    public static let standardGravity = 9.81
    /// Upward speed added to every spawned ember in m/s.
    public static let spawnUpwardSpeed = 0.25
    /// Half-range of the per-component velocity jitter in m/s.
    public static let spawnJitterSpeed = 0.15

    /// Terminal velocity `(0, −gravity/k, 0)` in m/s.
    ///
    /// - Parameter gravity: Gravitational acceleration in m/s² (zero gives zero).
    public static func terminalVelocity(gravity: Double) -> RVec3 {
        RVec3(0, -gravity / dragK, 0)
    }

    /// Ember position after `tau` seconds of flight.
    ///
    /// - Parameters:
    ///   - x0: Spawn position in metres.
    ///   - v0: Spawn velocity in m/s.
    ///   - tau: Seconds since spawn (`t − spawnTick/120`); values ≤ 0 return `x0`.
    ///   - gravity: Gravitational acceleration in m/s² (`9.81 × gravityScale`), acting along −Y.
    public static func position(x0: RVec3, v0: RVec3, tau: Double, gravity: Double) -> RVec3 {
        guard tau > 0 else { return x0 }
        let terminal = terminalVelocity(gravity: gravity)
        let decay = (1 - exp(-dragK * tau)) / dragK
        return x0 + terminal * tau + (v0 - terminal) * decay
    }

    /// Ember velocity after `tau` seconds: `v_t + (v0 − v_t)·e^{−kτ}`.
    ///
    /// - Parameters:
    ///   - v0: Spawn velocity in m/s.
    ///   - tau: Seconds since spawn; values ≤ 0 return `v0`.
    ///   - gravity: Gravitational acceleration in m/s².
    public static func velocity(v0: RVec3, tau: Double, gravity: Double) -> RVec3 {
        guard tau > 0 else { return v0 }
        let terminal = terminalVelocity(gravity: gravity)
        return terminal + (v0 - terminal) * exp(-dragK * tau)
    }

    /// Blackbody temperature in kelvin, cooling linearly from `tempStartK` to `tempEndK`
    /// over `lifetime`; clamped outside `[0, lifetime]`.
    public static func temperature(tau: Double) -> Double {
        let fraction = min(max(tau / lifetime, 0), 1)
        return tempStartK + (tempEndK - tempStartK) * fraction
    }

    /// Spawn state of ember `index` shed from `ring` at `tick`.
    ///
    /// The ember leaves the rim at phase `θ = ring.angle + 2π·Hash.unit(seed, tick, index, 1)`,
    /// at `sigilCenter + r·(cos θ, 0, sin θ)`, with the tangential velocity `ω·r·t̂` where
    /// `t̂ = (−sin θ, 0, cos θ)` carries the ring's rotation sign, plus a per-component
    /// jitter in `[−spawnJitterSpeed, +spawnJitterSpeed)` drawn from hash channels 2, 3, 4
    /// and `spawnUpwardSpeed` along +Y. The ring index is folded into the hash channel as
    /// `channel + 16·ringIndex`, so ring 0 uses the bare channel numbers and rings differ.
    ///
    /// - Parameters:
    ///   - ring: State of the shedding ring at `tick`.
    ///   - ringIndex: Index of the ring (0 = outermost).
    ///   - sigilCenter: Sigil centre in metres (ARCHITECTURE §2: `(0, 1.55, 0)`).
    ///   - seed: Simulation seed.
    ///   - tick: Spawn tick.
    ///   - index: Ember index within the tick.
    /// - Returns: The spawn position `x0` and velocity `v0`.
    public static func spawn(
        ring: RingState, ringIndex: Int, sigilCenter: RVec3, seed: UInt64, tick: Int, index: Int
    ) -> (x0: RVec3, v0: RVec3) {
        let tickKey = UInt32(truncatingIfNeeded: tick)
        let indexKey = UInt32(truncatingIfNeeded: index)
        let channelBase = UInt32(truncatingIfNeeded: max(ringIndex, 0)) &* 16
        func unit(_ channel: UInt32) -> Double {
            Hash.unit(seed, tickKey, indexKey, channelBase &+ channel)
        }

        let theta = ring.angle + 2.0 * Double.pi * unit(1)
        let radial = RVec3(cos(theta), 0, sin(theta))
        let tangent = RVec3(-sin(theta), 0, cos(theta)) * ring.rotationSign
        let jitter = RVec3(
            (unit(2) * 2 - 1) * spawnJitterSpeed,
            (unit(3) * 2 - 1) * spawnJitterSpeed,
            (unit(4) * 2 - 1) * spawnJitterSpeed
        )
        let x0 = sigilCenter + radial * ring.radius
        let v0 = tangent * (abs(ring.omega) * ring.radius) + jitter + RVec3(0, spawnUpwardSpeed, 0)
        return (x0, v0)
    }
}
