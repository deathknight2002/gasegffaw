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
        XCTAssertEqual(dynamics.viscous, 0.35)
        XCTAssertEqual(dynamics.coulomb, 0.02)
        XCTAssertEqual(dynamics.coupling, 0.15)
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
            for tick in 0..<(120 * 10) {
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
        for index in 0..<5 {
            let omega = omegas[index]
            var torque = -0.35 * 1.5 * omega
            if index > 0 { torque -= 0.15 * (omega + omegas[index - 1]) }
            if index < 4 { torque -= 0.15 * (omega + omegas[index + 1]) }
            let inertia = before.rings[index].inertia
            var expected = omega + torque / inertia * dt
            if expected != 0 {
                let sign: Double = expected > 0 ? 1 : -1
                let afterCoulomb = expected - sign * (0.02 * 1.5 / inertia) * dt
                expected = afterCoulomb * sign > 0 ? afterCoulomb : 0
            }
            XCTAssertEqual(dynamics.rings[index].omega, expected, accuracy: 1e-12, "ring \(index)")
            XCTAssertEqual(dynamics.rings[index].angle, SigilDynamics.wrapAngle(expected * dt), accuracy: 1e-12)
        }
        // The resting ring 3 is dragged by its neighbours' coupling, less the Coulomb decrement.
        let couplingKick = (-0.15 * (0 + 0.5) - 0.15 * (0 - 3.0)) / before.rings[3].inertia * dt
        XCTAssertEqual(dynamics.rings[3].omega, couplingKick - (0.02 * 1.5 / before.rings[3].inertia) * dt, accuracy: 1e-12)
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
