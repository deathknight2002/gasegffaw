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

    /// Non-finite gesture payloads (NaN/±∞ yaw, trace point, flick velocity) are refused at
    /// the boundary: never logged, never applied, so state, keyframes and the input log
    /// keep their invariants and stay JSON-encodable.
    func testNonFiniteInputsAreDroppedAndTheStateStaysEncodable() throws {
        let simulation = RitualSimulation(seed: 1)
        simulation.apply(RitualInput(tick: 0, kind: .cameraYaw(90)))
        simulation.step()
        let logBefore = simulation.inputLog
        let badInputs: [InputKind] = [
            .cameraYaw(.nan), .cameraYaw(.infinity), .cameraYaw(-.infinity),
            .tracePoint(RVec2(.nan, 0.5)), .tracePoint(RVec2(0.5, -.infinity)),
            .flick(velocity: RVec2(.nan, 0), ring: 0), .flick(velocity: RVec2(1, .infinity), ring: nil),
        ]
        for kind in badInputs {
            XCTAssertFalse(kind.isFinite)
            simulation.apply(RitualInput(tick: simulation.tick, kind: kind))
        }
        XCTAssertEqual(simulation.inputLog, logBefore, "non-finite inputs are not logged")
        simulation.step(ticks: 240)
        XCTAssertEqual(simulation.state.cameraYaw, 90)
        XCTAssertTrue(simulation.state.trace.isEmpty)
        XCTAssertTrue(simulation.state.sigil.isAtRest)
        XCTAssertNoThrow(try JSONEncoder().encode(simulation.state))
        XCTAssertNoThrow(try JSONEncoder().encode(simulation.keyframes))
        XCTAssertNoThrow(try JSONEncoder().encode(simulation.inputLog))
        for kind in [InputKind.holdBegin, .holdEnd, .traceEnd, .tap, .cameraYaw(0), .tracePoint(.zero), .flick(velocity: .zero, ring: nil)] {
            XCTAssertTrue(kind.isFinite)
        }

        // In the stages that consume the payloads: a trace while facing East, a flick while spinning.
        let air = RitualSimulation(seed: 1)
        air.jump(to: .air)
        air.apply(RitualInput(tick: air.tick, kind: .cameraYaw(90)))
        air.apply(RitualInput(tick: air.tick, kind: .tracePoint(RVec2(.nan, 0.5))))
        air.apply(RitualInput(tick: air.tick, kind: .tracePoint(RVec2(0.5, .infinity))))
        air.step()
        XCTAssertTrue(air.state.facingQuarter)
        XCTAssertTrue(air.state.trace.isEmpty)
        XCTAssertNoThrow(try JSONEncoder().encode(air.state))

        let spin = RitualSimulation(seed: 1)
        spin.jump(to: .sigilSpin)
        let twin = RitualSimulation(seed: 1)
        twin.jump(to: .sigilSpin)
        spin.apply(RitualInput(tick: spin.tick, kind: .flick(velocity: RVec2(.infinity, 0), ring: 0)))
        spin.apply(RitualInput(tick: spin.tick, kind: .flick(velocity: RVec2(.nan, .nan), ring: 2)))
        spin.step(ticks: 10)
        twin.step(ticks: 10)
        XCTAssertEqual(spin.state, twin.state)
        XCTAssertEqual(spin.inputLog, twin.inputLog)
        XCTAssertNoThrow(try JSONEncoder().encode(spin.state))

        // `RitualState.consume` guards on its own as well (bypassing `apply`).
        var state = RitualState()
        XCTAssertTrue(state.consume(.cameraYaw(.nan), tick: 0).isEmpty)
        XCTAssertTrue(state.consume(.cameraYaw(.infinity), tick: 0).isEmpty)
        XCTAssertEqual(state, RitualState())
    }

    /// `RitualState` encodes with a value-determined layout: `completedStages` sorted by
    /// stage number, `candles` and `completedTick` as keyed objects (not hash-ordered
    /// flat arrays), so equal states produce identical bytes under `.sortedKeys` in every
    /// process (ARCHITECTURE §6).
    func testStateEncodingLayoutIsDeterministic() throws {
        let simulation = scriptedSimulation(seed: 12)
        simulation.step(ticks: 2000)
        let state = simulation.state
        XCTAssertGreaterThan(state.completedStages.count, 1)
        XCTAssertGreaterThan(state.completedTick.count, 1)

        let sorted = JSONEncoder()
        sorted.outputFormatting = [.sortedKeys]
        let first = try sorted.encode(state)
        let again = JSONEncoder()
        again.outputFormatting = [.sortedKeys]
        XCTAssertEqual(first, try again.encode(state))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let candles = try XCTUnwrap(object["candles"] as? [String: Any], "candles must be a keyed object")
        XCTAssertEqual(Set(candles.keys), Set(Quarter.allCases.map(\.rawValue)))
        let ticks = try XCTUnwrap(object["completedTick"] as? [String: Any], "completedTick must be a keyed object")
        XCTAssertEqual(Set(ticks.keys), Set(state.completedTick.keys.map(\.id)))
        for (stage, tick) in state.completedTick {
            XCTAssertEqual(ticks[stage.id] as? Int, tick)
        }
        let stages = try XCTUnwrap(object["completedStages"] as? [Int])
        XCTAssertEqual(stages, state.completedStages.map(\.rawValue).sorted())

        // The plain (unsorted) encoding carries the same layout and round-trips too; only
        // `.sortedKeys` fixes the byte order of keyed objects, which is why it is the
        // documented way to compare keyframes or manifests byte for byte.
        let plain = try JSONEncoder().encode(state)
        let plainObject = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNotNil(plainObject["candles"] as? [String: Any])
        XCTAssertNotNil(plainObject["completedTick"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(plainObject["completedStages"] as? [Int]), stages)

        XCTAssertEqual(try JSONDecoder().decode(RitualState.self, from: first), state)
        XCTAssertEqual(try JSONDecoder().decode(RitualState.self, from: plain), state)
        let keyframe = try XCTUnwrap(simulation.keyframes.last)
        XCTAssertEqual(try sorted.encode(keyframe), try again.encode(keyframe))
        XCTAssertEqual(try JSONDecoder().decode(Keyframe.self, from: try sorted.encode(keyframe)), keyframe)
    }

    /// `lastStepEvents` is empty after every `seek`, whether it steps forward from the
    /// current position or restores a keyframe and replays — even when the landing tick
    /// raised events — so a haptics layer keyed on it never re-fires on a scrub.
    func testSeekLeavesNoStepEvents() throws {
        let probe = scriptedSimulation(seed: 1)
        var landing: Int?
        while landing == nil, probe.tick < 5000 {
            probe.step()
            if probe.lastStepEvents.contains(.stageCompleted(.oath)) {
                landing = probe.tick
            }
        }
        let oathLanding = try XCTUnwrap(landing, "the autopilot completes the oath")
        XCTAssertGreaterThan(oathLanding, RitualSimulation.keyframeInterval)

        // Forward path: already between the keyframe and the target.
        let simulation = scriptedSimulation(seed: 1)
        simulation.step(ticks: oathLanding - 60)
        simulation.seek(toTick: oathLanding)
        XCTAssertEqual(simulation.state.completedTick[.oath], oathLanding - 1)
        XCTAssertTrue(simulation.lastStepEvents.isEmpty, "forward seek onto a completion tick")

        // Restore-and-replay path.
        simulation.step(ticks: 100)
        simulation.seek(toTick: oathLanding)
        XCTAssertEqual(simulation.tick, oathLanding)
        XCTAssertTrue(simulation.lastStepEvents.isEmpty, "restore-and-replay seek onto a completion tick")
        simulation.seek(toTick: oathLanding)
        XCTAssertTrue(simulation.lastStepEvents.isEmpty, "no-op seek")

        // A plain step still reports its events.
        simulation.seek(toTick: oathLanding - 1)
        simulation.step()
        XCTAssertEqual(simulation.lastStepEvents, [.stageCompleted(.oath)])
        XCTAssertEqual(simulation.state.lastEvent, .stageCompleted(.oath), "the state's own lastEvent is unaffected")
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
