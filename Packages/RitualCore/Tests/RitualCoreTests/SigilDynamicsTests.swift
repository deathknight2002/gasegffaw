import XCTest
@testable import RitualCore

/// Ring dynamics: dissipation, counter-rotation, Coulomb stop, flick sign, angle wrap.
final class SigilDynamicsTests: XCTestCase {
    private let dt = RitualSimulation.dt

    func testContractRingsAndCoefficients() {
        let dynamics = SigilDynamics()
        XCTAssertEqual(dynamics.rings.count, 5)
        XCTAssertEqual(dynamics.rings.map(\.radius), [0.75, 0.62, 0.50, 0.39, 0.29])
        let masses = [0.30, 0.25, 0.20, 0.16, 0.12]
        for (ring, mass) in zip(dynamics.rings, masses) {
            XCTAssertEqual(ring.inertia, mass * ring.radius * ring.radius, accuracy: 1e-15)
            XCTAssertEqual(ring.omega, 0)
            XCTAssertEqual(ring.angle, 0)
        }
        XCTAssertEqual(dynamics.viscous, 0.03)
        XCTAssertEqual(dynamics.coulomb, 0.008)
        XCTAssertEqual(dynamics.coupling, 0.12)
        XCTAssertEqual(SigilDynamics.flickImpulsePerSpeed, 0.35)
        XCTAssertEqual(SigilDynamics.maxFlickSpeed, 4.0)
        // Viscous time constant of the outer ring: I₀ / viscous ≈ 5.6 s.
        XCTAssertEqual(dynamics.rings[0].inertia / dynamics.viscous, 5.625, accuracy: 1e-9)
        XCTAssertEqual(dynamics.kineticEnergy, 0)
        XCTAssertEqual(dynamics.sparkRate, 0)
        XCTAssertTrue(dynamics.isAtRest)
    }

    func testEnergyIsNonIncreasingWithoutInput() {
        for frictionScale in [0.0, 0.5, 1.0, 2.0, 3.0] {
            var dynamics = SigilDynamics()
            dynamics.rings[0].omega = 6
            dynamics.rings[1].omega = -3
            dynamics.rings[2].omega = 4.5
            dynamics.rings[3].omega = 0.2
            dynamics.rings[4].omega = -9
            var previous = dynamics.kineticEnergy
            XCTAssertGreaterThan(previous, 0)
            // The outer ring's viscous time constant is 5.6 s (11 s at half friction), so
            // the rings need tens of seconds to come to rest; watch a full minute.
            for tick in 0..<(120 * 60) {
                dynamics.step(dt: dt, frictionScale: frictionScale)
                let energy = dynamics.kineticEnergy
                XCTAssertLessThanOrEqual(energy, previous + 1e-12, "energy rose at tick \(tick), friction \(frictionScale)")
                previous = energy
            }
            if frictionScale > 0 {
                XCTAssertTrue(dynamics.isAtRest, "Coulomb friction must bring the rings to rest (scale \(frictionScale))")
            } else {
                // Coupling alone cannot damp the perfectly counter-rotating mode (adjacent sums
                // vanish), so that mode survives and everything else has been dissipated.
                XCTAssertGreaterThan(dynamics.kineticEnergy, 0)
                for index in 0..<4 {
                    XCTAssertEqual(dynamics.rings[index].omega + dynamics.rings[index + 1].omega, 0, accuracy: 1e-3,
                                   "rings \(index) and \(index + 1) settle into exact counter-rotation")
                }
            }
        }
    }

    /// The explicit viscous update is only stable while `(viscous·scale + 2·coupling)·dt / I`
    /// stays below 2 (≈ scale 73 for the innermost ring); `step` clamps the scale at
    /// `maxFrictionScale`, so any slider value keeps the rings dissipative and finite.
    func testFrictionScaleIsClampedSoExtremeFrictionStaysDissipative() {
        XCTAssertEqual(SigilDynamics.maxFrictionScale, 10)
        for scale in [SigilDynamics.maxFrictionScale, 60.0, 80.0, 100.0, 1e6, .infinity] {
            var dynamics = SigilDynamics()
            dynamics.rings[4].omega = 10
            dynamics.rings[0].omega = -6
            var previous = dynamics.kineticEnergy
            for tick in 0..<600 {
                dynamics.step(dt: dt, frictionScale: scale)
                let energy = dynamics.kineticEnergy
                XCTAssertTrue(energy.isFinite, "scale \(scale) tick \(tick)")
                XCTAssertLessThanOrEqual(energy, previous + 1e-12, "energy rose at tick \(tick), scale \(scale)")
                previous = energy
            }
            XCTAssertTrue(dynamics.isAtRest, "heavy friction stops the rings (scale \(scale))")
        }

        // Above the clamp every scale behaves exactly like the clamp.
        var clamped = SigilDynamics()
        clamped.rings[2].omega = 5
        var huge = clamped
        clamped.step(dt: dt, frictionScale: SigilDynamics.maxFrictionScale)
        huge.step(dt: dt, frictionScale: 1e9)
        XCTAssertEqual(clamped, huge)
        // Below it the scale is honoured (the slider range is untouched).
        var three = SigilDynamics()
        three.rings[2].omega = 5
        three.step(dt: dt, frictionScale: 3)
        XCTAssertNotEqual(three, clamped)
        XCTAssertGreaterThan(three.rings[2].omega, clamped.rings[2].omega)

        // And through the simulation's config.
        let config = SimConfig(frictionScale: 100, gravityScale: 1, emberScale: 1, autopilot: false)
        let simulation = RitualSimulation(seed: 1, config: config)
        simulation.jump(to: .sigilSpin)
        simulation.apply(RitualInput(tick: simulation.tick, kind: .flick(velocity: RVec2(4, 0), ring: 4)))
        simulation.step()
        var previous = simulation.state.spinEnergy
        XCTAssertGreaterThan(previous, 0)
        for _ in 0..<600 {
            simulation.step()
            XCTAssertLessThanOrEqual(simulation.state.spinEnergy, previous + 1e-12)
            XCTAssertTrue(simulation.state.spinEnergy.isFinite)
            previous = simulation.state.spinEnergy
        }
        XCTAssertTrue(simulation.state.sigil.isAtRest)
    }

    func testFlickImpulseMagnitudeAndSign() {
        var dynamics = SigilDynamics()
        dynamics.applyFlick(velocity: RVec2(3.5, 0), ring: 0)
        let impulse = 3.5 * SigilDynamics.flickImpulsePerSpeed
        XCTAssertEqual(dynamics.rings[0].omega, impulse / dynamics.rings[0].inertia, accuracy: 1e-12)
        XCTAssertEqual(dynamics.rings[1].omega, -0.5 * impulse / dynamics.rings[1].inertia, accuracy: 1e-12)
        XCTAssertEqual(dynamics.rings[2].omega, 0)
        XCTAssertGreaterThan(dynamics.rings[0].omega, 0, "rightward flick spins positive")
        XCTAssertLessThan(dynamics.rings[1].omega, 0, "the adjacent ring counter-rotates")

        var leftward = SigilDynamics()
        leftward.applyFlick(velocity: RVec2(-2, 0.5), ring: 2)
        XCTAssertLessThan(leftward.rings[2].omega, 0, "leftward flick spins negative")
        XCTAssertGreaterThan(leftward.rings[1].omega, 0)
        XCTAssertGreaterThan(leftward.rings[3].omega, 0)
        XCTAssertEqual(leftward.rings[0].omega, 0)
        XCTAssertEqual(leftward.rings[4].omega, 0)
        XCTAssertEqual(abs(leftward.rings[2].omega) * leftward.rings[2].inertia,
                       RVec2(-2, 0.5).length * SigilDynamics.flickImpulsePerSpeed, accuracy: 1e-12)
    }

    func testFlickSpeedIsClampedAndNilTargetsOuterRing() {
        var fast = SigilDynamics()
        fast.applyFlick(velocity: RVec2(40, 0), ring: nil)
        var limit = SigilDynamics()
        limit.applyFlick(velocity: RVec2(4, 0), ring: 0)
        XCTAssertEqual(fast.rings[0].omega, limit.rings[0].omega, accuracy: 1e-12, "|v| clamps to 4")
        XCTAssertEqual(fast.rings[1].omega, limit.rings[1].omega, accuracy: 1e-12)

        var still = SigilDynamics()
        still.applyFlick(velocity: .zero, ring: 3)
        XCTAssertTrue(still.isAtRest)

        var clamped = SigilDynamics()
        clamped.applyFlick(velocity: RVec2(1, 0), ring: 99)
        XCTAssertGreaterThan(clamped.rings[4].omega, 0, "out-of-range ring index clamps to the innermost ring")
        XCTAssertLessThan(clamped.rings[3].omega, 0)
    }

    func testAdjacentRingsCounterRotateAfterFlickAndUnderCoupling() {
        var dynamics = SigilDynamics()
        dynamics.applyFlick(velocity: RVec2(3.5, 0), ring: 0)
        for _ in 0..<60 {
            dynamics.step(dt: dt, frictionScale: 1)
            XCTAssertGreaterThan(dynamics.rings[0].omega, 0)
            XCTAssertLessThan(dynamics.rings[1].omega, 0)
        }
        // A ring driven only through the coupling spins opposite to its neighbour.
        var coupled = SigilDynamics()
        coupled.rings[2].omega = 5
        coupled.step(dt: dt, frictionScale: 1)
        XCTAssertLessThan(coupled.rings[1].omega, 0)
        XCTAssertLessThan(coupled.rings[3].omega, 0)
        XCTAssertEqual(coupled.rings[0].omega, 0, "non-adjacent rings feel nothing on the first step")
        XCTAssertEqual(coupled.rings[4].omega, 0)
    }

    func testMomentumIsVisiblyConservedForTwoSecondsAfterAFlick() {
        // A single 3.5-speed flick on the outer ring, then two seconds with no input.
        // Viscous friction alone (τ = I₀/viscous = 5.6 s) would leave ring 0 at
        // e^(−2/5.6) ≈ 70 % of its speed. The contract coupling (0.12 N·m·s) additionally
        // spreads the flick's counter-momentum into rings 1–4, which start from rest, so
        // with the contract coefficients ring 0 settles at ≈ 48 % of its initial speed
        // while the chain's total momentum Σ|I·ω| — which only friction can remove —
        // keeps ≈ 53 %. (The previous 0.35 viscous coefficient left ring 0 at ≈ 4 %.)
        var dynamics = SigilDynamics()
        dynamics.applyFlick(velocity: RVec2(3.5, 0), ring: 0)
        let initialOmega = dynamics.rings[0].omega
        let initialMomentum = dynamics.rings.reduce(0) { $0 + abs($1.inertia * $1.omega) }
        XCTAssertEqual(initialOmega, 3.5 * 0.35 / dynamics.rings[0].inertia, accuracy: 1e-12)
        for _ in 0..<(2 * RitualSimulation.tickRate) {
            dynamics.step(dt: dt, frictionScale: 1)
        }
        let retainedSpeed = dynamics.rings[0].omega / initialOmega
        XCTAssertGreaterThanOrEqual(retainedSpeed, 0.45, "ring 0 keeps at least 45 % of its speed after 2 s (contract coefficients give ≈ 48 %)")
        XCTAssertLessThan(retainedSpeed, 0.75, "friction and coupling do act on ring 0")
        let momentum = dynamics.rings.reduce(0) { $0 + abs($1.inertia * $1.omega) }
        XCTAssertGreaterThanOrEqual(momentum / initialMomentum, 0.5, "the chain keeps at least half of its momentum after 2 s")
        // The momentum has spread down the chain in alternating directions.
        for index in 1..<5 {
            XCTAssertNotEqual(dynamics.rings[index].omega, 0, "ring \(index) has been spun up")
        }
        for index in 0..<4 {
            XCTAssertLessThan(dynamics.rings[index].omega * dynamics.rings[index + 1].omega, 0, "rings \(index) and \(index + 1) counter-rotate")
        }
        // Even 5 s after the flick the outer ring is still turning at more than 1 rad/s.
        for _ in 0..<(3 * RitualSimulation.tickRate) {
            dynamics.step(dt: dt, frictionScale: 1)
        }
        XCTAssertGreaterThan(dynamics.rings[0].omega, 1.0)
    }

    func testCoulombFrictionStopsWithoutReversal() {
        var dynamics = SigilDynamics()
        dynamics.rings[4].omega = 0.02
        var previous = dynamics.rings[4].omega
        var stoppedAt: Int? = nil
        for tick in 0..<600 {
            dynamics.step(dt: dt, frictionScale: 1)
            let omega = dynamics.rings[4].omega
            XCTAssertGreaterThanOrEqual(omega, 0, "omega reversed at tick \(tick)")
            XCTAssertLessThanOrEqual(omega, previous)
            previous = omega
            if omega == 0, stoppedAt == nil {
                stoppedAt = tick
            }
        }
        XCTAssertNotNil(stoppedAt, "the ring must come to an exact stop")
        XCTAssertEqual(dynamics.rings[4].omega, 0)

        // Negative direction, larger speed: still stops at exactly zero, never overshoots.
        var reverse = SigilDynamics()
        reverse.rings[0].omega = -0.5
        for _ in 0..<(120 * 30) {
            reverse.step(dt: dt, frictionScale: 1)
            XCTAssertLessThanOrEqual(reverse.rings[0].omega, 0)
        }
        XCTAssertTrue(reverse.isAtRest)
    }

    func testOneStepMatchesTorqueFormula() {
        var dynamics = SigilDynamics()
        let omegas = [2.0, -1.0, 0.5, 0.0, -3.0]
        for (index, omega) in omegas.enumerated() {
            dynamics.rings[index].omega = omega
        }
        let before = dynamics
        dynamics.step(dt: dt, frictionScale: 1.5)
        // Contract coefficients written out so the formula is checked against the numbers.
        let viscous = 0.03
        let coulomb = 0.008
        let coupling = 0.12
        for index in 0..<5 {
            let omega = omegas[index]
            var torque = -viscous * 1.5 * omega
            if index > 0 { torque -= coupling * (omega + omegas[index - 1]) }
            if index < 4 { torque -= coupling * (omega + omegas[index + 1]) }
            let inertia = before.rings[index].inertia
            var expected = omega + torque / inertia * dt
            if expected != 0 {
                let sign: Double = expected > 0 ? 1 : -1
                let afterCoulomb = expected - sign * (coulomb * 1.5 / inertia) * dt
                expected = afterCoulomb * sign > 0 ? afterCoulomb : 0
            }
            XCTAssertEqual(dynamics.rings[index].omega, expected, accuracy: 1e-12, "ring \(index)")
            XCTAssertEqual(dynamics.rings[index].angle, SigilDynamics.wrapAngle(expected * dt), accuracy: 1e-12)
        }
        // The resting ring 3 is dragged by its neighbours' coupling, less the Coulomb decrement.
        let couplingKick = (-coupling * (0 + 0.5) - coupling * (0 - 3.0)) / before.rings[3].inertia * dt
        XCTAssertEqual(dynamics.rings[3].omega, couplingKick - (coulomb * 1.5 / before.rings[3].inertia) * dt, accuracy: 1e-12)
        XCTAssertGreaterThan(dynamics.rings[3].omega, 0)
    }

    func testRestingRingIgnoresNudgesBelowStaticFriction() {
        var dynamics = SigilDynamics()
        dynamics.rings[1].omega = 1e-4  // a residual far below one Coulomb decrement
        dynamics.step(dt: dt, frictionScale: 1)
        XCTAssertTrue(dynamics.isAtRest, "a nudge smaller than coulomb·dt/I cannot start a neighbour")
        // Repeated tiny kicks between rings therefore die out to an exact zero, not a denormal.
        var chain = SigilDynamics()
        chain.rings[0].omega = -0.5
        var settledAt: Int? = nil
        for tick in 0..<(120 * 20) {
            chain.step(dt: dt, frictionScale: 1)
            if chain.isAtRest {
                settledAt = tick
                break
            }
        }
        XCTAssertNotNil(settledAt)
        XCTAssertLessThan(settledAt ?? Int.max, 120 * 5, "settles within a few seconds")
        XCTAssertEqual(chain.kineticEnergy, 0)
    }

    func testAngleWrapsIntoZeroTwoPi() {
        var dynamics = SigilDynamics()
        dynamics.rings[0].omega = 50
        dynamics.rings[1].omega = -50
        for _ in 0..<(120 * 3) {
            dynamics.step(dt: dt, frictionScale: 0)
            for ring in dynamics.rings {
                XCTAssertGreaterThanOrEqual(ring.angle, 0)
                XCTAssertLessThan(ring.angle, 2 * Double.pi)
            }
        }
        XCTAssertEqual(SigilDynamics.wrapAngle(-0.5), 2 * Double.pi - 0.5, accuracy: 1e-12)
        XCTAssertEqual(SigilDynamics.wrapAngle(2 * Double.pi), 0)
        XCTAssertEqual(SigilDynamics.wrapAngle(7), 7 - 2 * Double.pi, accuracy: 1e-12)
        XCTAssertEqual(RingState(angle: -1, radius: 1, inertia: 1).angle, 2 * Double.pi - 1, accuracy: 1e-12)
    }

    func testEnergyAndSparkRate() {
        var dynamics = SigilDynamics()
        dynamics.rings[0].omega = 2
        dynamics.rings[3].omega = -1
        let expectedEnergy = 0.5 * dynamics.rings[0].inertia * 4 + 0.5 * dynamics.rings[3].inertia * 1
        XCTAssertEqual(dynamics.kineticEnergy, expectedEnergy, accuracy: 1e-15)
        XCTAssertEqual(dynamics.sparkRate, (2 * 0.75 + 1 * 0.39) * 40, accuracy: 1e-12)
        XCTAssertEqual(dynamics.rings[0].rotationSign, 1)
        XCTAssertEqual(dynamics.rings[3].rotationSign, -1)
        XCTAssertEqual(dynamics.rings[1].rotationSign, 0)
    }

    func testStepIsDeterministicAndCodable() throws {
        var a = SigilDynamics()
        var b = SigilDynamics()
        a.applyFlick(velocity: RVec2(3, 1), ring: 1)
        b.applyFlick(velocity: RVec2(3, 1), ring: 1)
        for _ in 0..<500 {
            a.step(dt: dt, frictionScale: 1)
            b.step(dt: dt, frictionScale: 1)
        }
        XCTAssertEqual(a, b)
        let decoded = try JSONDecoder().decode(SigilDynamics.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded, a)
    }
}
