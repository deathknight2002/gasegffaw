import XCTest
@testable import RitualCore

/// The ember closed form against numeric integration, and the spawn geometry.
final class EmberModelTests: XCTestCase {
    /// RK4 integration of `a = −k·v − g·ŷ` with step `dt`.
    private func integrate(x0: RVec3, v0: RVec3, gravity: Double, until end: Double, dt: Double) -> RVec3 {
        let k = EmberModel.dragK
        func acceleration(_ v: RVec3) -> RVec3 {
            RVec3(-k * v.x, -k * v.y - gravity, -k * v.z)
        }
        var x = x0
        var v = v0
        var t = 0.0
        while t < end - 1e-12 {
            let h = min(dt, end - t)
            let k1v = acceleration(v)
            let k1x = v
            let k2v = acceleration(v + k1v * (h / 2))
            let k2x = v + k1v * (h / 2)
            let k3v = acceleration(v + k2v * (h / 2))
            let k3x = v + k2v * (h / 2)
            let k4v = acceleration(v + k3v * h)
            let k4x = v + k3v * h
            x = x + (k1x + k2x * 2 + k3x * 2 + k4x) * (h / 6)
            v = v + (k1v + k2v * 2 + k3v * 2 + k4v) * (h / 6)
            t += h
        }
        return x
    }

    func testClosedFormMatchesRK4WithinOneMillimetre() {
        let x0 = RVec3(0.3, 1.55, -0.2)
        let velocities = [RVec3(0, 0.25, 0), RVec3(2.5, 0.4, -1.0), RVec3(-4.0, 1.0, 3.0), RVec3(0.1, -0.5, 0.05)]
        let gravityScales = [0.0, 0.5, 1.0, 3.0]
        for v0 in velocities {
            for scale in gravityScales {
                let gravity = EmberModel.standardGravity * scale
                for tau in [0.05, 0.5, 1.0, 1.7, EmberModel.lifetime] {
                    let numeric = integrate(x0: x0, v0: v0, gravity: gravity, until: tau, dt: 1e-4)
                    let closed = EmberModel.position(x0: x0, v0: v0, tau: tau, gravity: gravity)
                    XCTAssertLessThan(closed.distance(to: numeric), 1e-3,
                                      "v0 \(v0) g×\(scale) τ=\(tau): closed \(closed) vs RK4 \(numeric)")
                }
            }
        }
    }

    func testTauZeroGivesSpawnPosition() {
        let x0 = RVec3(1, 2, 3)
        let v0 = RVec3(5, -5, 5)
        XCTAssertEqual(EmberModel.position(x0: x0, v0: v0, tau: 0, gravity: 9.81), x0)
        XCTAssertEqual(EmberModel.position(x0: x0, v0: v0, tau: -1, gravity: 9.81), x0)
        XCTAssertEqual(EmberModel.velocity(v0: v0, tau: 0, gravity: 9.81), v0)
    }

    func testZeroGravityHasNoTerminalVelocity() {
        XCTAssertEqual(EmberModel.terminalVelocity(gravity: 0), .zero)
        XCTAssertEqual(EmberModel.terminalVelocity(gravity: 9.81), RVec3(0, -9.81 / 6.0, 0))
        let v0 = RVec3(1, 2, -1)
        // Without gravity the ember asymptotically travels v0/k and its velocity decays to zero.
        let far = EmberModel.position(x0: .zero, v0: v0, tau: 10, gravity: 0)
        XCTAssertEqual(far.distance(to: v0 / EmberModel.dragK), 0, accuracy: 1e-9)
        XCTAssertLessThan(EmberModel.velocity(v0: v0, tau: 10, gravity: 0).length, 1e-9)
        // With gravity the velocity converges to the terminal velocity.
        let late = EmberModel.velocity(v0: v0, tau: 10, gravity: 9.81)
        XCTAssertEqual(late.distance(to: EmberModel.terminalVelocity(gravity: 9.81)), 0, accuracy: 1e-9)
    }

    func testTemperatureCoolsLinearly() {
        XCTAssertEqual(EmberModel.temperature(tau: 0), 1900)
        XCTAssertEqual(EmberModel.temperature(tau: EmberModel.lifetime), 800)
        XCTAssertEqual(EmberModel.temperature(tau: EmberModel.lifetime / 2), 1350, accuracy: 1e-12)
        XCTAssertEqual(EmberModel.temperature(tau: 99), 800)
        XCTAssertEqual(EmberModel.temperature(tau: -1), 1900)
        XCTAssertEqual(EmberModel.dragK, 6.0)
        XCTAssertEqual(EmberModel.lifetime, 2.5)
    }

    func testSpawnGeometryFollowsRingAndHash() {
        let centre = RVec3(0, 1.55, 0)
        let ring = RingState(angle: 1.0, omega: 4.0, radius: 0.75, inertia: 0.16875)
        let spawn = EmberModel.spawn(ring: ring, ringIndex: 0, sigilCenter: centre, seed: 7, tick: 100, index: 3)
        let theta = ring.angle + 2 * Double.pi * Hash.unit(7, 100, 3, 1)
        let expectedX0 = centre + RVec3(cos(theta), 0, sin(theta)) * 0.75
        XCTAssertEqual(spawn.x0.distance(to: expectedX0), 0, accuracy: 1e-12)
        XCTAssertEqual((spawn.x0 - centre).length, 0.75, accuracy: 1e-12, "spawns on the rim")
        XCTAssertEqual(spawn.x0.y, 1.55, accuracy: 1e-12, "the sigil plane is horizontal")

        let jitter = RVec3(
            (Hash.unit(7, 100, 3, 2) * 2 - 1) * 0.15,
            (Hash.unit(7, 100, 3, 3) * 2 - 1) * 0.15,
            (Hash.unit(7, 100, 3, 4) * 2 - 1) * 0.15
        )
        let tangent = RVec3(-sin(theta), 0, cos(theta))
        let expectedV0 = tangent * (4.0 * 0.75) + jitter + RVec3(0, 0.25, 0)
        XCTAssertEqual(spawn.v0.distance(to: expectedV0), 0, accuracy: 1e-12)
        // Tangential part is perpendicular to the radial direction.
        let radial = (spawn.x0 - centre).normalized
        XCTAssertEqual((spawn.v0 - jitter - RVec3(0, 0.25, 0)).dot(radial), 0, accuracy: 1e-12)

        // Reversing the spin reverses the tangential velocity.
        let reversed = RingState(angle: 1.0, omega: -4.0, radius: 0.75, inertia: 0.16875)
        let back = EmberModel.spawn(ring: reversed, ringIndex: 0, sigilCenter: centre, seed: 7, tick: 100, index: 3)
        XCTAssertEqual(back.x0, spawn.x0)
        XCTAssertEqual((back.v0 - jitter - RVec3(0, 0.25, 0)).distance(to: -(spawn.v0 - jitter - RVec3(0, 0.25, 0))), 0, accuracy: 1e-12)

        // A resting ring sheds only jitter + lift.
        let still = RingState(angle: 0, omega: 0, radius: 0.5, inertia: 0.05)
        let calm = EmberModel.spawn(ring: still, ringIndex: 2, sigilCenter: centre, seed: 7, tick: 5, index: 0)
        XCTAssertLessThanOrEqual(abs(calm.v0.x), 0.15)
        XCTAssertLessThanOrEqual(abs(calm.v0.z), 0.15)
        XCTAssertGreaterThan(calm.v0.y, 0.25 - 0.15 - 1e-12)
    }

    func testSpawnIsDeterministicAndVariesWithKeys() {
        let centre = RVec3(0, 1.55, 0)
        let ring = RingState(angle: 0.3, omega: 2, radius: 0.62, inertia: 0.0961)
        let a = EmberModel.spawn(ring: ring, ringIndex: 1, sigilCenter: centre, seed: 42, tick: 10, index: 1)
        let b = EmberModel.spawn(ring: ring, ringIndex: 1, sigilCenter: centre, seed: 42, tick: 10, index: 1)
        XCTAssertEqual(a.x0, b.x0)
        XCTAssertEqual(a.v0, b.v0)
        let otherIndex = EmberModel.spawn(ring: ring, ringIndex: 1, sigilCenter: centre, seed: 42, tick: 10, index: 2)
        let otherTick = EmberModel.spawn(ring: ring, ringIndex: 1, sigilCenter: centre, seed: 42, tick: 11, index: 1)
        let otherRing = EmberModel.spawn(ring: ring, ringIndex: 0, sigilCenter: centre, seed: 42, tick: 10, index: 1)
        let otherSeed = EmberModel.spawn(ring: ring, ringIndex: 1, sigilCenter: centre, seed: 43, tick: 10, index: 1)
        XCTAssertNotEqual(a.x0, otherIndex.x0)
        XCTAssertNotEqual(a.x0, otherTick.x0)
        XCTAssertNotEqual(a.x0, otherRing.x0)
        XCTAssertNotEqual(a.x0, otherSeed.x0)
    }
}
