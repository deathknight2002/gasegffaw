import XCTest
@testable import RitualCore

/// Replay, seek and keyframe guarantees of `RitualSimulation` (ARCHITECTURE §5, §6).
final class DeterminismTests: XCTestCase {
    private func scriptedSimulation(seed: UInt64, config: SimConfig = SimConfig()) -> RitualSimulation {
        let simulation = RitualSimulation(seed: seed, config: config)
        for input in Autopilot.inputs(through: .manifestation, seed: seed) {
            simulation.apply(input)
        }
        return simulation
    }

    func testIdenticalRunsProduceIdenticalStateAfterTenThousandTicks() {
        let a = scriptedSimulation(seed: 5)
        let b = scriptedSimulation(seed: 5)
        a.step(ticks: 10_000)
        b.step(ticks: 10_000)
        XCTAssertEqual(a.tick, 10_000)
        XCTAssertEqual(a.state, b.state)
        XCTAssertEqual(a.keyframes, b.keyframes)
        XCTAssertEqual(a.inputLog, b.inputLog)
        XCTAssertTrue(a.state.isComplete, "the whole ritual fits in 10,000 ticks")
        XCTAssertEqual(a.maxSimulatedTick, 10_000)

        let other = scriptedSimulation(seed: 6)
        other.step(ticks: 10_000)
        XCTAssertEqual(other.state.stage, a.state.stage, "the schedule does not depend on the seed")
        XCTAssertNotEqual(other.inputLog, a.inputLog, "trace jitter does")
    }

    func testSeekMatchesStraightThroughRun() {
        let scrubbed = scriptedSimulation(seed: 7)
        scrubbed.step(ticks: 5000)
        XCTAssertEqual(scrubbed.maxSimulatedTick, 5000)

        for target in [1234, 0, 2400, 4999, 5000, 1, 239, 240, 241, 3599] {
            scrubbed.seek(toTick: target)
            let fresh = scriptedSimulation(seed: 7)
            fresh.step(ticks: target)
            XCTAssertEqual(scrubbed.tick, target)
            XCTAssertEqual(scrubbed.state, fresh.state, "seek(\(target))")
        }
        XCTAssertEqual(scrubbed.maxSimulatedTick, 5000, "scrubbing backwards keeps the furthest tick")

        // Forward beyond the furthest simulated tick simulates on.
        scrubbed.seek(toTick: 7000)
        let fresh = scriptedSimulation(seed: 7)
        fresh.step(ticks: 7000)
        XCTAssertEqual(scrubbed.tick, 7000)
        XCTAssertEqual(scrubbed.state, fresh.state)
        XCTAssertEqual(scrubbed.maxSimulatedTick, 7000)
        XCTAssertEqual(scrubbed.keyframes.map(\.tick), fresh.keyframes.map(\.tick))
        XCTAssertEqual(scrubbed.keyframes, fresh.keyframes)

        // Negative targets clamp to zero.
        scrubbed.seek(toTick: -5)
        XCTAssertEqual(scrubbed.tick, 0)
        XCTAssertEqual(scrubbed.state, RitualState())
    }

    func testSeekAfterArbitraryScrubbingStillMatches() {
        let scrubbed = scriptedSimulation(seed: 8)
        var rng = SeededRNG(seed: 99)
        var furthest = 0
        for _ in 0..<40 {
            let target = Int(rng.nextU32() % 6000)
            scrubbed.seek(toTick: target)
            furthest = max(furthest, target)
            XCTAssertEqual(scrubbed.tick, target)
            XCTAssertEqual(scrubbed.maxSimulatedTick, furthest)
        }
        scrubbed.seek(toTick: 4321)
        let fresh = scriptedSimulation(seed: 8)
        fresh.step(ticks: 4321)
        XCTAssertEqual(scrubbed.state, fresh.state)
    }

    func testKeyframeCadenceEvery240TicksIncludingZero() {
        let simulation = scriptedSimulation(seed: 2)
        XCTAssertEqual(simulation.keyframes.map(\.tick), [0])
        XCTAssertEqual(simulation.keyframes[0].state, RitualState())
        simulation.step(ticks: 5000)
        XCTAssertEqual(simulation.keyframes.map(\.tick), Array(stride(from: 0, through: 4800, by: 240)))
        for keyframe in simulation.keyframes {
            let fresh = scriptedSimulation(seed: 2)
            fresh.step(ticks: keyframe.tick)
            XCTAssertEqual(keyframe.state, fresh.state, "keyframe \(keyframe.tick) holds the state before that tick's inputs")
        }
        // Scrubbing back and forth adds no duplicates.
        simulation.seek(toTick: 100)
        simulation.seek(toTick: 5000)
        XCTAssertEqual(simulation.keyframes.map(\.tick), Array(stride(from: 0, through: 4800, by: 240)))
        simulation.step(ticks: 40)
        XCTAssertEqual(simulation.keyframes.last?.tick, 5040)
    }

    func testNewInputAfterRewindInvalidatesLaterKeyframes() {
        let simulation = RitualSimulation(seed: 4)
        simulation.step(ticks: 1500)
        XCTAssertEqual(simulation.keyframes.count, 7)
        simulation.seek(toTick: 500)
        simulation.apply(RitualInput(tick: 500, kind: .holdBegin))
        XCTAssertEqual(simulation.keyframes.map(\.tick), [0, 240, 480], "keyframes after the new input are stale")
        XCTAssertEqual(simulation.maxSimulatedTick, 500)
        simulation.step(ticks: 1000)
        XCTAssertEqual(simulation.keyframes.map(\.tick), [0, 240, 480, 720, 960, 1200, 1440])

        let fresh = RitualSimulation(seed: 4)
        fresh.apply(RitualInput(tick: 500, kind: .holdBegin))
        fresh.step(ticks: 1500)
        XCTAssertEqual(simulation.state, fresh.state)
        XCTAssertEqual(simulation.keyframes, fresh.keyframes)
        XCTAssertEqual(simulation.state.stage, .air)
        simulation.seek(toTick: 700)
        fresh.seek(toTick: 700)
        XCTAssertEqual(simulation.state, fresh.state)
    }

    func testInputsStampedInThePastAreRestampedToNow() {
        let simulation = RitualSimulation(seed: 4)
        simulation.step(ticks: 100)
        simulation.apply(RitualInput(tick: 10, kind: .holdBegin))
        XCTAssertEqual(simulation.inputLog, [RitualInput(tick: 100, kind: .holdBegin)])
        simulation.step()
        XCTAssertTrue(simulation.state.holding)
        // Inputs for the same tick are consumed in application order.
        simulation.apply(RitualInput(tick: 101, kind: .holdEnd))
        simulation.apply(RitualInput(tick: 101, kind: .holdBegin))
        simulation.step()
        XCTAssertTrue(simulation.state.holding)
        // Future inputs wait for their tick.
        simulation.apply(RitualInput(tick: 300, kind: .holdEnd))
        simulation.step(ticks: 198)
        XCTAssertTrue(simulation.state.holding)
        simulation.step()
        XCTAssertFalse(simulation.state.holding)
    }

    func testConfigChangesTheRunButNotTheLog() {
        let slick = scriptedSimulation(seed: 3, config: SimConfig(frictionScale: 0.2, gravityScale: 1, emberScale: 1, autopilot: true))
        let rough = scriptedSimulation(seed: 3)
        slick.step(ticks: 4000)
        rough.step(ticks: 4000)
        XCTAssertEqual(slick.inputLog, rough.inputLog)
        XCTAssertNotEqual(slick.state.sigil, rough.state.sigil, "friction scale changes the spin")
        XCTAssertEqual(slick.state.completedStages.intersection([.oath, .air, .fire, .water, .earth, .spirit]).count, 6)
    }

    func testStateAndKeyframeCodableRoundTrip() throws {
        let simulation = scriptedSimulation(seed: 12)
        simulation.step(ticks: 2000)
        let state = simulation.state
        XCTAssertFalse(state.completedTick.isEmpty)
        XCTAssertFalse(state.completedStages.isEmpty)
        let decoded = try JSONDecoder().decode(RitualState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        let keyframe = simulation.keyframes.last!
        let decodedKeyframe = try JSONDecoder().decode(Keyframe.self, from: JSONEncoder().encode(keyframe))
        XCTAssertEqual(decodedKeyframe, keyframe)
        let config = SimConfig(frictionScale: 2, gravityScale: 0.5, emberScale: 3, autopilot: true)
        XCTAssertEqual(try JSONDecoder().decode(SimConfig.self, from: JSONEncoder().encode(config)), config)
    }

    func testStepZeroOrNegativeTicksIsANoOp() {
        let simulation = RitualSimulation(seed: 1)
        simulation.step(ticks: 0)
        simulation.step(ticks: -3)
        XCTAssertEqual(simulation.tick, 0)
        XCTAssertEqual(simulation.time, 0)
        simulation.step(ticks: 60)
        XCTAssertEqual(simulation.time, 0.5, accuracy: 1e-12)
    }

    // MARK: - Hash and PCG pins (mirrors FoundationTests; the sim depends on both)

    func testHashAndPCGPins() {
        XCTAssertEqual(Hash.u32(1, 2, 3, 4), 0x8f0b_a4b8)
        var rng = SeededRNG(seed: 42, stream: 54)
        XCTAssertEqual((0..<5).map { _ in rng.nextU32() }, [0xa15c_02b7, 0x7b47_f409, 0xba1d_3330, 0x83d2_f293, 0xbfa4_784b])
    }
}
