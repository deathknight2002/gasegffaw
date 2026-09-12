import XCTest
@testable import RitualCore

/// The ritual state machine driven by the autopilot and by hand-made inputs.
final class RitualFlowTests: XCTestCase {
    private let tickRate = RitualSimulation.tickRate

    /// Steps `simulation` until `condition` holds or `limitTicks` elapse; returns whether it held.
    @discardableResult
    private func run(_ simulation: RitualSimulation, limitTicks: Int, events: inout [RitualEvent],
                     until condition: (RitualState) -> Bool) -> Bool {
        var remaining = limitTicks
        while !condition(simulation.state), remaining > 0 {
            simulation.step()
            events += simulation.lastStepEvents
            remaining -= 1
        }
        return condition(simulation.state)
    }

    private func traceInputs(for element: RitualElement, from tick: Int) -> [RitualInput] {
        var inputs: [RitualInput] = []
        for (offset, point) in SigilTemplates.checkpoints(for: element, count: 120).enumerated() {
            inputs.append(RitualInput(tick: tick + offset, kind: .tracePoint(point)))
        }
        inputs.append(RitualInput(tick: tick + 120, kind: .traceEnd))
        return inputs
    }

    // MARK: - Autopilot end to end

    func testAutopilotCompletesEveryStageInOrderWithExpectedEvents() {
        let simulation = RitualSimulation(seed: 1)
        let script = Autopilot.inputs(through: .manifestation, seed: 1)
        XCTAssertFalse(script.isEmpty)
        for input in script {
            simulation.apply(input)
        }
        var events: [RitualEvent] = []
        var stagesSeen: [RitualStage] = [simulation.state.stage]
        var remaining = tickRate * 200
        while !simulation.state.isComplete, remaining > 0 {
            simulation.step()
            events += simulation.lastStepEvents
            if simulation.state.stage != stagesSeen.last {
                stagesSeen.append(simulation.state.stage)
            }
            remaining -= 1
        }
        XCTAssertTrue(simulation.state.isComplete, "the autopilot must finish the ritual within 200 s")
        XCTAssertEqual(stagesSeen, RitualStage.allCases, "stages are visited 1…8 in order, none skipped")
        XCTAssertEqual(simulation.state.completedStages, Set(RitualStage.allCases))
        XCTAssertEqual(simulation.state.stage, .manifestation)

        let completions = events.compactMap { event -> RitualStage? in
            if case .stageCompleted(let stage) = event { return stage } else { return nil }
        }
        XCTAssertEqual(completions, RitualStage.allCases, "exactly one stageCompleted per stage, in order")
        let ticks = RitualStage.allCases.compactMap { simulation.state.completedTick[$0] }
        XCTAssertEqual(ticks.count, 8)
        XCTAssertEqual(ticks, ticks.sorted(), "completion ticks increase with stage order")

        let candles = events.compactMap { event -> Quarter? in
            if case .candleLit(let quarter) = event { return quarter } else { return nil }
        }
        XCTAssertEqual(candles, [.east, .south, .west, .north])
        let ignitions = Quarter.allCases.compactMap { simulation.state.candles[$0]?.ignitionTick }
        XCTAssertEqual(ignitions, ignitions.sorted())
        for quarter in Quarter.allCases {
            XCTAssertEqual(simulation.state.candles[quarter]?.lit, true)
            XCTAssertEqual(simulation.state.candles[quarter]?.intensity, 1)
        }

        XCTAssertEqual(events.filter { $0 == .sigilErupted }.count, 1)
        XCTAssertEqual(events.filter { $0 == .manifestationBegan }.count, 1)
        XCTAssertEqual(events.filter { $0 == .ritualComplete }.count, 1)
        let erupt = events.firstIndex(of: .sigilErupted)!
        let began = events.firstIndex(of: .manifestationBegan)!
        let complete = events.firstIndex(of: .ritualComplete)!
        XCTAssertLessThan(erupt, began)
        XCTAssertLessThan(began, complete)
        XCTAssertEqual(events.last, .ritualComplete)
        XCTAssertEqual(simulation.state.lastEvent, .ritualComplete)
        XCTAssertEqual(events.filter { if case .beatHit(.perfect) = $0 { return true } else { return false } }.count, 6,
                       "taps 0.02 s after each beat are all perfect")
        XCTAssertTrue(simulation.state.sigilErupted)
        XCTAssertEqual(simulation.state.sigilEruptTick, simulation.state.completedTick[.spirit])
        XCTAssertEqual(simulation.state.manifestStartTick, simulation.state.completedTick[.sigilSpin])
        XCTAssertEqual(simulation.state.manifestT, 1)
        XCTAssertEqual(simulation.state.manifestCharge, 1)
        XCTAssertEqual(simulation.state.ringKindle, 1)

        // Timing expectations of the script.
        XCTAssertEqual(simulation.state.completedTick[.oath], 360, "3.0 s of hold")
        let spinStart = simulation.state.completedTick[.spirit]!
        let spinDone = simulation.state.completedTick[.sigilSpin]!
        XCTAssertLessThanOrEqual(spinDone - spinStart, 15 * tickRate, "three flicks charge the manifestation within ~15 s")
        let thirdFlick = script.last { if case .flick = $0.kind { return true } else { return false } }!.tick
        XCTAssertGreaterThan(spinDone, thirdFlick, "all three flicks contribute before the charge is full")
        XCTAssertEqual(simulation.state.completedTick[.manifestation]! - spinDone, 8 * tickRate, "manifestT reaches 1 after 8 s")
        // Progress is 1 once the finale has played.
        XCTAssertEqual(simulation.state.stageProgress, 1)
    }

    func testAutopilotScriptIsDeterministicAndDependsOnSeedOnlyThroughJitter() {
        let a = Autopilot.inputs(through: .manifestation, seed: 9)
        let b = Autopilot.inputs(through: .manifestation, seed: 9)
        XCTAssertEqual(a, b)
        let c = Autopilot.inputs(through: .manifestation, seed: 10)
        XCTAssertEqual(a.map(\.tick), c.map(\.tick), "seeds only change the trace jitter, not the schedule")
        XCTAssertNotEqual(a, c)
        let shifted = Autopilot.inputs(through: .air, seed: 9, startTick: 500)
        XCTAssertEqual(shifted.first?.tick, 500)
        XCTAssertEqual(shifted.first?.kind, .holdBegin)
        XCTAssertEqual(shifted.map { $0.tick - 500 }, Autopilot.inputs(through: .air, seed: 9).map(\.tick))
        // The oath script holds for 3.2 s.
        XCTAssertEqual(a[1].kind, .holdEnd)
        XCTAssertEqual(a[1].tick, 384)
        // Camera turns 0.2 s after each quarter stage begins, then 180 samples, then a lift.
        let yaws = a.compactMap { input -> (Int, Double)? in
            if case .cameraYaw(let yaw) = input.kind { return (input.tick, yaw) } else { return nil }
        }
        XCTAssertEqual(yaws.map(\.1), [90, 0, 270, 180])
        XCTAssertEqual(yaws[0].0, 360 + 24)
        let points = a.filter { if case .tracePoint = $0.kind { return true } else { return false } }
        XCTAssertEqual(points.count, 4 * 180)
        XCTAssertEqual(a.filter { $0.kind == .traceEnd }.count, 4)
        XCTAssertEqual(a.filter { $0.kind == .tap }.count, 6)
        let flicks = a.filter { if case .flick = $0.kind { return true } else { return false } }
        XCTAssertEqual(flicks.count, 3)
        let spinStart = flicks[0].tick - 60
        XCTAssertEqual(flicks.map { $0.tick - spinStart }, [60, 180, 360])
        XCTAssertEqual(flicks.map(\.kind), [
            .flick(velocity: RVec2(3.5, 0), ring: 0), .flick(velocity: RVec2(3.5, 0), ring: 1), .flick(velocity: RVec2(3.5, 0), ring: 0),
        ])
        XCTAssertEqual(Autopilot.inputs(through: .manifestation, seed: 9), Autopilot.inputs(through: .sigilSpin, seed: 9),
                       "the manifestation has no actions of its own")
        XCTAssertEqual(Autopilot.inputs(through: .oath, seed: 9).count, 2)
    }

    func testShowcaseTicksFollowTheirDefinitions() {
        let seed: UInt64 = 3
        let simulation = RitualSimulation(seed: seed)
        let script = Autopilot.inputs(through: .manifestation, seed: seed)
        for input in script {
            simulation.apply(input)
        }
        var events: [RitualEvent] = []
        XCTAssertTrue(run(simulation, limitTicks: tickRate * 200, events: &events) { $0.isComplete })
        let state = simulation.state

        XCTAssertEqual(Autopilot.showcaseTick(for: .oath, seed: seed), 216, "1.8 s into the chant")
        for quarter in Quarter.allCases {
            XCTAssertEqual(Autopilot.showcaseTick(for: quarter.stage, seed: seed), state.candles[quarter]!.ignitionTick! + 144,
                           "\(quarter): 1.2 s after ignition")
        }
        XCTAssertEqual(Autopilot.showcaseTick(for: .spirit, seed: seed), state.sigilEruptTick! + 120)
        let thirdFlick = script.last { if case .flick = $0.kind { return true } else { return false } }!.tick
        XCTAssertEqual(Autopilot.showcaseTick(for: .sigilSpin, seed: seed), thirdFlick + 120)
        XCTAssertEqual(Autopilot.showcaseTick(for: .manifestation, seed: seed), state.completedTick[.manifestation]! + 240)

        let ticks = RitualStage.allCases.map { Autopilot.showcaseTick(for: $0, seed: seed) }
        XCTAssertEqual(ticks, ticks.sorted())
        XCTAssertEqual(ticks, RitualStage.allCases.map { Autopilot.showcaseTick(for: $0, seed: seed) }, "deterministic")

        // The oath showcase really shows a ~60 % kindled ring.
        let oath = RitualSimulation(seed: seed)
        for input in Autopilot.inputs(through: .oath, seed: seed) {
            oath.apply(input)
        }
        oath.seek(toTick: Autopilot.showcaseTick(for: .oath, seed: seed))
        XCTAssertEqual(oath.state.stage, .oath)
        XCTAssertEqual(oath.state.ringKindle, 0.6, accuracy: 0.01)

        // The spin showcase has the rings spinning and sparks shedding.
        let spin = RitualSimulation(seed: seed)
        for input in Autopilot.inputs(through: .sigilSpin, seed: seed) {
            spin.apply(input)
        }
        spin.seek(toTick: Autopilot.showcaseTick(for: .sigilSpin, seed: seed))
        XCTAssertTrue(spin.state.sigilErupted)
        XCTAssertGreaterThan(spin.state.spinEnergy, 0)
        XCTAssertGreaterThan(spin.state.sigil.sparkRate, 0)
    }

    // MARK: - Oath

    func testOathHoldAccumulatesAndReleaseDecays() {
        let simulation = RitualSimulation(seed: 1)
        simulation.apply(RitualInput(tick: 0, kind: .holdBegin))
        simulation.apply(RitualInput(tick: 120, kind: .holdEnd))
        simulation.step(ticks: 120)
        XCTAssertTrue(simulation.state.holding)
        XCTAssertEqual(simulation.state.chantProgress, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(simulation.state.ringKindle, simulation.state.chantProgress)
        XCTAssertEqual(simulation.state.stageProgress, simulation.state.chantProgress)
        simulation.step(ticks: 30)
        XCTAssertFalse(simulation.state.holding)
        XCTAssertEqual(simulation.state.chantProgress, 1.0 / 3.0 - 0.5 * 0.25, accuracy: 1e-9, "decays 0.5/s")
        simulation.step(ticks: 120)
        XCTAssertEqual(simulation.state.chantProgress, 0, "clamped at zero")
        XCTAssertEqual(simulation.state.stage, .oath)

        simulation.apply(RitualInput(tick: simulation.tick, kind: .holdBegin))
        var events: [RitualEvent] = []
        XCTAssertTrue(run(simulation, limitTicks: 400, events: &events) { $0.stage == .air })
        XCTAssertEqual(events, [.stageCompleted(.oath)])
        XCTAssertEqual(simulation.state.completedTick[.oath], 270 + 360)
        XCTAssertEqual(simulation.state.stageStartTick, 270 + 360)
        XCTAssertEqual(simulation.state.chantProgress, 1)
        XCTAssertEqual(simulation.state.ringKindle, 1)
        XCTAssertEqual(simulation.state.completedStages, [.oath])
        // Still holding and later releasing never dims the ring again.
        simulation.apply(RitualInput(tick: simulation.tick, kind: .holdEnd))
        simulation.step(ticks: 240)
        XCTAssertEqual(simulation.state.ringKindle, 1)
        XCTAssertEqual(simulation.state.chantProgress, 1)
    }

    // MARK: - Quarters

    func testTraceIsBlockedUnlessFacingTheQuarter() {
        let simulation = RitualSimulation(seed: 1)
        simulation.jump(to: .air)
        XCTAssertEqual(simulation.state.stage, .air)
        XCTAssertFalse(simulation.state.facingQuarter, "default yaw 0 faces South, not East")

        // Facing South: every trace point is dropped and the lift counts as a failed attempt.
        for input in traceInputs(for: .air, from: simulation.tick) {
            simulation.apply(input)
        }
        simulation.step(ticks: 121)
        XCTAssertEqual(simulation.state.stage, .air)
        XCTAssertEqual(simulation.state.candles[.east]?.lit, false)
        XCTAssertEqual(simulation.state.traceAttempts, 1)
        XCTAssertTrue(simulation.state.trace.isEmpty)
        XCTAssertEqual(simulation.state.traceHits, 0)

        // 31° off is still not facing; 29° off is.
        simulation.apply(RitualInput(tick: simulation.tick, kind: .cameraYaw(90 + 31)))
        simulation.step()
        XCTAssertFalse(simulation.state.facingQuarter)
        simulation.apply(RitualInput(tick: simulation.tick, kind: .cameraYaw(90 - 29)))
        simulation.step()
        XCTAssertTrue(simulation.state.facingQuarter)

        let start = simulation.tick
        for input in traceInputs(for: .air, from: start) {
            simulation.apply(input)
        }
        simulation.step(ticks: 60)
        XCTAssertEqual(simulation.state.trace.count, 60)
        XCTAssertGreaterThan(simulation.state.traceHits, 0)
        XCTAssertEqual(simulation.state.traceHits, TraceScorer.score(trace: simulation.state.trace, checkpoints: SigilTemplates.checkpoints(for: .air)))
        XCTAssertEqual(simulation.state.stageProgress, Double(simulation.state.traceHits) / 24)
        simulation.step(ticks: 61)
        XCTAssertEqual(simulation.state.stage, .fire)
        XCTAssertEqual(simulation.lastStepEvents, [.candleLit(.east), .stageCompleted(.air)])
        XCTAssertEqual(simulation.state.candles[.east]?.lit, true)
        XCTAssertEqual(simulation.state.candles[.east]?.ignitionTick, start + 120)
        XCTAssertEqual(simulation.state.completedTick[.air], start + 120)
        XCTAssertTrue(simulation.state.trace.isEmpty, "the trace is reset for the next quarter")
        XCTAssertFalse(simulation.state.facingQuarter, "East yaw does not face South")
        XCTAssertEqual(simulation.state.traceAttempts, 1)
    }

    func testWrongTemplateFailsAndResetsWithoutPenalty() {
        let simulation = RitualSimulation(seed: 1)
        simulation.jump(to: .fire)
        simulation.apply(RitualInput(tick: simulation.tick, kind: .cameraYaw(Quarter.south.yawDegrees)))
        for input in traceInputs(for: .water, from: simulation.tick + 1) {
            simulation.apply(input)
        }
        simulation.step(ticks: 122)
        XCTAssertEqual(simulation.state.stage, .fire)
        XCTAssertEqual(simulation.state.traceAttempts, 1)
        XCTAssertTrue(simulation.state.trace.isEmpty)
        XCTAssertEqual(simulation.state.stageProgress, 0)
        XCTAssertEqual(simulation.state.candles[.south]?.lit, false)
        for input in traceInputs(for: .fire, from: simulation.tick) {
            simulation.apply(input)
        }
        simulation.step(ticks: 121)
        XCTAssertEqual(simulation.state.stage, .water)
        XCTAssertEqual(simulation.state.candles[.south]?.lit, true)
    }

    func testCandleIntensityRampsOverSixTenthsOfASecond() {
        let simulation = RitualSimulation(seed: 1)
        simulation.jump(to: .water)
        simulation.apply(RitualInput(tick: simulation.tick, kind: .cameraYaw(270)))
        for input in traceInputs(for: .water, from: simulation.tick + 1) {
            simulation.apply(input)
        }
        var events: [RitualEvent] = []
        XCTAssertTrue(run(simulation, limitTicks: 200, events: &events) { $0.candles[.west]?.lit == true })
        let ignition = simulation.state.candles[.west]!.ignitionTick!
        XCTAssertEqual(simulation.state.candles[.west]?.intensity, 0, "ignition tick itself is dark")
        simulation.step(ticks: 36)
        XCTAssertEqual(simulation.state.candles[.west]!.intensity, 0.5, accuracy: 1e-12)
        simulation.step(ticks: 36)
        XCTAssertEqual(simulation.state.candles[.west]!.intensity, 1)
        simulation.step(ticks: 100)
        XCTAssertEqual(simulation.state.candles[.west]!.intensity, 1)
        XCTAssertEqual(simulation.state.candles[.west]!.ignitionTick, ignition)
        XCTAssertEqual(simulation.state.candles[.east]?.intensity, 1, "earlier candles are fully lit")
        XCTAssertEqual(simulation.state.candles[.north]?.intensity, 0)
    }

    // MARK: - Rhythm

    private func spiritSimulation() -> RitualSimulation {
        let simulation = RitualSimulation(seed: 1)
        simulation.jump(to: .spirit)
        XCTAssertEqual(simulation.state.stage, .spirit)
        return simulation
    }

    func testRhythmWindowsJudgePerfectGoodAndMiss() {
        let simulation = spiritSimulation()
        let start = simulation.state.stageStartTick
        XCTAssertEqual(simulation.state.beatTick(0), start + 120)
        XCTAssertEqual(simulation.state.beatTick(5), start + 600)
        let taps = [
            simulation.state.beatTick(0),        // exact → perfect
            simulation.state.beatTick(1) + 18,   // +0.15 s → perfect
            simulation.state.beatTick(2) + 19,   // just outside → good
            simulation.state.beatTick(3) - 36,   // −0.30 s → good
            simulation.state.beatTick(4) - 37,   // early beyond the window → miss
            simulation.state.beatTick(5) + 36,   // last moment → good
        ]
        for tap in taps {
            simulation.apply(RitualInput(tick: tap, kind: .tap))
        }
        var events: [RitualEvent] = []
        XCTAssertTrue(run(simulation, limitTicks: 800, events: &events) { $0.stage == .sigilSpin })
        let beats = events.compactMap { event -> BeatResult? in
            if case .beatHit(let result) = event { return result } else { return nil }
        }
        XCTAssertEqual(beats, [.perfect, .perfect, .good, .good, .miss, .good])
        XCTAssertEqual(events.suffix(3), [.beatHit(.good), .sigilErupted, .stageCompleted(.spirit)])
        XCTAssertEqual(simulation.state.sigilEruptTick, taps[5])
        XCTAssertEqual(simulation.state.rhythmRound, 0)
        XCTAssertTrue(simulation.state.sigilErupted)
    }

    func testRhythmProgressAndLateTapCountsAgainstNextBeat() {
        let simulation = spiritSimulation()
        let beat0 = simulation.state.beatTick(0)
        simulation.seek(toTick: beat0 + 36)
        XCTAssertEqual(simulation.state.beatIndex, 0, "the beat is still open at +0.30 s")
        simulation.step()
        XCTAssertEqual(simulation.state.beatIndex, 1, "no tap by +goodWindow → miss")
        XCTAssertEqual(simulation.state.beatResults, [.miss])
        XCTAssertEqual(simulation.lastStepEvents, [.beatHit(.miss)])
        XCTAssertEqual(simulation.state.stageProgress, 1.0 / 6.0, accuracy: 1e-12)
        // A tap now is judged against beat 1 (the nearest unjudged one) and is far too early.
        simulation.apply(RitualInput(tick: simulation.tick, kind: .tap))
        simulation.step()
        XCTAssertEqual(simulation.state.beatResults, [.miss, .miss])
        XCTAssertEqual(simulation.state.beatIndex, 2)
    }

    func testFailedRoundRepeatsAfterRetryDelay() {
        let simulation = spiritSimulation()
        let start = simulation.state.stageStartTick
        // Two early hits only: 4 misses → round fails.
        simulation.apply(RitualInput(tick: simulation.state.beatTick(0), kind: .tap))
        simulation.apply(RitualInput(tick: simulation.state.beatTick(1), kind: .tap))
        var events: [RitualEvent] = []
        XCTAssertTrue(run(simulation, limitTicks: 800, events: &events) { $0.rhythmRound == 1 })
        XCTAssertEqual(simulation.state.stage, .spirit)
        XCTAssertEqual(simulation.state.beatIndex, 0)
        XCTAssertTrue(simulation.state.beatResults.isEmpty)
        XCTAssertEqual(simulation.state.stageProgress, 0)
        XCTAssertEqual(simulation.tick - 1, start + 600 + 36, "round ends when the last beat is missed")
        XCTAssertEqual(events.filter { $0 == .sigilErupted }.count, 0)
        let secondRoundFirstBeat = simulation.state.beatTick(0)
        XCTAssertEqual(secondRoundFirstBeat, start + 600 + 180 + 120, "next round starts 1.5 s after the last beat")

        // Five hits in round two succeed.
        for index in 0..<5 {
            simulation.apply(RitualInput(tick: simulation.state.beatTick(index) + 5, kind: .tap))
        }
        events.removeAll()
        XCTAssertTrue(run(simulation, limitTicks: 1200, events: &events) { $0.stage == .sigilSpin })
        XCTAssertEqual(simulation.state.rhythmRound, 1)
        XCTAssertEqual(simulation.state.beatResults, [.perfect, .perfect, .perfect, .perfect, .perfect, .miss])
        XCTAssertEqual(simulation.state.sigilEruptTick, start + 780 + 600 + 36, "the missed sixth beat of round two resolves at +goodWindow")
        XCTAssertEqual(simulation.state.completedTick[.spirit], simulation.state.sigilEruptTick)
        XCTAssertEqual(simulation.state.stageStartTick, simulation.state.sigilEruptTick)
    }

    // MARK: - Sigil spin and manifestation

    func testManifestChargeNeedsSpin() {
        let simulation = RitualSimulation(seed: 1)
        simulation.jump(to: .sigilSpin)
        XCTAssertEqual(simulation.state.stage, .sigilSpin)
        XCTAssertTrue(simulation.state.sigilErupted)
        simulation.step(ticks: tickRate * 10)
        XCTAssertEqual(simulation.state.manifestCharge, 0, "no flick, no charge")
        XCTAssertEqual(simulation.state.spinEnergy, 0)
        XCTAssertEqual(simulation.state.stage, .sigilSpin)
        XCTAssertEqual(simulation.state.stageProgress, 0)

        simulation.apply(RitualInput(tick: simulation.tick, kind: .flick(velocity: RVec2(1, 0), ring: nil)))
        simulation.step()
        XCTAssertGreaterThan(simulation.state.spinEnergy, 0)
        XCTAssertGreaterThan(simulation.state.manifestCharge, 0)
        XCTAssertEqual(simulation.state.stageProgress, simulation.state.manifestCharge)
        let charge = simulation.state.manifestCharge
        simulation.step()
        XCTAssertEqual(simulation.state.manifestCharge - charge, simulation.state.spinEnergy / 1.2 / 120, accuracy: 1e-12,
                       "dq/dt = E / 1.2")
        XCTAssertLessThan(simulation.state.manifestCharge, 1)
        XCTAssertGreaterThan(simulation.state.sigil.rings[0].omega, 0)
        XCTAssertLessThan(simulation.state.sigil.rings[1].omega, 0)
        XCTAssertEqual(simulation.state.sigil.rings[4].omega, 0)

        // The autopilot's three flicks fill the charge within 15 s of the stage start.
        let start = simulation.state.stageStartTick
        for input in Autopilot.inputs(through: .sigilSpin, seed: 1).filter({ if case .flick = $0.kind { return true } else { return false } }) {
            simulation.apply(RitualInput(tick: simulation.tick + input.tick - Autopilot.inputs(through: .sigilSpin, seed: 1).first { if case .flick = $0.kind { return true } else { return false } }!.tick + 60, kind: input.kind))
        }
        var events: [RitualEvent] = []
        XCTAssertTrue(run(simulation, limitTicks: tickRate * 30, events: &events) { $0.stage == .manifestation })
        XCTAssertEqual(events.suffix(2), [.manifestationBegan, .stageCompleted(.sigilSpin)])
        XCTAssertEqual(simulation.state.manifestCharge, 1)
        XCTAssertEqual(simulation.state.manifestStartTick, simulation.tick - 1)
        XCTAssertLessThanOrEqual(simulation.tick - start, 15 * tickRate + 10 * tickRate, "charged within 15 s of the flicks (10 s idle first)")
    }

    func testManifestationSmoothstepAndRingsKeepSpinningDown() {
        let simulation = RitualSimulation(seed: 1)
        simulation.jump(to: .manifestation)
        XCTAssertEqual(simulation.state.stage, .manifestation)
        let start = simulation.state.manifestStartTick!
        XCTAssertEqual(start, simulation.state.stageStartTick)
        XCTAssertEqual(simulation.tick, start + 1)
        XCTAssertGreaterThan(simulation.state.spinEnergy, 0, "the rings are still spinning when the manifestation begins")

        var previousEnergy = simulation.state.spinEnergy
        var events: [RitualEvent] = []
        // The rings keep stepping (and spinning down) in stage 8.
        // The state at tick T is the result of integrating tick T − 1, hence the +1.
        simulation.seek(toTick: start + tickRate / 2 + 1)
        XCTAssertGreaterThan(simulation.state.spinEnergy, 0)
        XCTAssertLessThan(simulation.state.spinEnergy, previousEnergy)
        XCTAssertEqual(simulation.state.manifestT, RitualRules.smoothstep(0.5 / 8.0), accuracy: 1e-12)
        previousEnergy = simulation.state.spinEnergy
        simulation.seek(toTick: start + 2 * tickRate + 1)
        XCTAssertEqual(simulation.state.manifestT, RitualRules.smoothstep(2.0 / 8.0), accuracy: 1e-12)
        XCTAssertLessThan(simulation.state.spinEnergy, previousEnergy)
        previousEnergy = simulation.state.spinEnergy
        simulation.seek(toTick: start + 4 * tickRate + 1)
        XCTAssertEqual(simulation.state.manifestT, 0.5, accuracy: 1e-12)
        XCTAssertEqual(simulation.state.stageProgress, 0.5, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(simulation.state.spinEnergy, previousEnergy)
        XCTAssertFalse(simulation.state.isComplete)

        XCTAssertTrue(run(simulation, limitTicks: 8 * tickRate, events: &events) { $0.isComplete })
        XCTAssertEqual(simulation.state.manifestT, 1)
        XCTAssertEqual(simulation.state.completedTick[.manifestation], start + 8 * tickRate)
        XCTAssertEqual(events.suffix(2), [.stageCompleted(.manifestation), .ritualComplete])
        XCTAssertEqual(events.filter { $0 == .ritualComplete }.count, 1)
        events.removeAll()
        simulation.step(ticks: 600)
        XCTAssertTrue(simulation.lastStepEvents.isEmpty, "ritualComplete fires once")
        XCTAssertEqual(simulation.state.stage, .manifestation)
        XCTAssertEqual(simulation.state.manifestT, 1)
        XCTAssertEqual(simulation.state.stageProgress, 1)
        XCTAssertEqual(simulation.state.lastEvent, .ritualComplete)
    }

    // MARK: - Jump and misc

    func testJumpToStageIsDeterministicAndIdempotent() {
        let a = RitualSimulation(seed: 11)
        let b = RitualSimulation(seed: 11)
        a.jump(to: .spirit)
        b.jump(to: .spirit)
        XCTAssertEqual(a.state, b.state)
        XCTAssertEqual(a.tick, b.tick)
        XCTAssertEqual(a.inputLog, b.inputLog)
        XCTAssertEqual(a.state.stage, .spirit)
        XCTAssertEqual(a.state.completedStages, [.oath, .air, .fire, .water, .earth])
        XCTAssertEqual(a.tick, a.state.stageStartTick + 1, "positioned on the first tick of the stage")
        XCTAssertFalse(a.inputLog.contains { $0.kind == .tap }, "no showcase actions for the target stage itself")

        let before = a.state
        a.jump(to: .spirit)
        a.jump(to: .air)
        XCTAssertEqual(a.state, before, "jumping to the current or an earlier stage is a no-op")

        // Jumping from the middle of a stage continues from the live state.
        let mid = RitualSimulation(seed: 11)
        mid.apply(RitualInput(tick: 0, kind: .holdBegin))
        mid.step(ticks: 200)
        mid.apply(RitualInput(tick: 200, kind: .holdEnd))
        mid.step(ticks: 10)
        mid.jump(to: .fire)
        XCTAssertEqual(mid.state.stage, .fire)
        XCTAssertEqual(mid.state.completedStages, [.oath, .air])
        XCTAssertEqual(mid.state.candles[.east]?.lit, true)
        XCTAssertGreaterThan(mid.state.completedTick[.oath]!, 210)
        XCTAssertLessThan(mid.state.completedTick[.oath]!, 210 + 360, "the partial chant is reused")

        // Jumping all the way runs the full autopilot.
        let end = RitualSimulation(seed: 11)
        end.jump(to: .manifestation)
        XCTAssertEqual(end.state.stage, .manifestation)
        XCTAssertEqual(end.state.completedStages.count, 7)
        XCTAssertEqual(end.state.manifestCharge, 1)
    }

    func testInputsOutsideTheirStageAreIgnored() {
        let simulation = RitualSimulation(seed: 1)
        simulation.apply(RitualInput(tick: 0, kind: .tap))
        simulation.apply(RitualInput(tick: 0, kind: .flick(velocity: RVec2(4, 0), ring: 0)))
        simulation.apply(RitualInput(tick: 0, kind: .tracePoint(RVec2(0.5, 0.5))))
        simulation.apply(RitualInput(tick: 0, kind: .traceEnd))
        simulation.apply(RitualInput(tick: 0, kind: .cameraYaw(-270)))
        simulation.step()
        var expected = RitualState()
        expected.cameraYaw = 90
        XCTAssertEqual(simulation.state, expected, "only the yaw is recorded outside its stage")
        XCTAssertTrue(simulation.lastStepEvents.isEmpty)
        XCTAssertEqual(simulation.state.traceAttempts, 0)
        XCTAssertTrue(simulation.state.sigil.isAtRest)
    }

    func testInitialStateDefaults() {
        let state = RitualState()
        XCTAssertEqual(state.stage, .oath)
        XCTAssertEqual(state.stageStartTick, 0)
        XCTAssertEqual(state.stageProgress, 0)
        XCTAssertTrue(state.completedStages.isEmpty)
        XCTAssertFalse(state.holding)
        XCTAssertEqual(state.chantProgress, 0)
        XCTAssertEqual(state.ringKindle, 0)
        XCTAssertEqual(state.cameraYaw, 0)
        XCTAssertFalse(state.facingQuarter)
        XCTAssertTrue(state.trace.isEmpty)
        XCTAssertEqual(state.traceHits, 0)
        XCTAssertEqual(state.traceAttempts, 0)
        XCTAssertEqual(state.candles.count, 4)
        XCTAssertEqual(state.candles[.north], .unlit)
        XCTAssertEqual(state.beatIndex, 0)
        XCTAssertTrue(state.beatResults.isEmpty)
        XCTAssertEqual(state.rhythmRound, 0)
        XCTAssertFalse(state.sigilErupted)
        XCTAssertNil(state.sigilEruptTick)
        XCTAssertEqual(state.sigil, SigilDynamics())
        XCTAssertEqual(state.spinEnergy, 0)
        XCTAssertEqual(state.manifestCharge, 0)
        XCTAssertNil(state.manifestStartTick)
        XCTAssertEqual(state.manifestT, 0)
        XCTAssertTrue(state.completedTick.isEmpty)
        XCTAssertNil(state.lastEvent)
        XCTAssertFalse(state.isComplete)
        XCTAssertEqual(SimConfig(), SimConfig(frictionScale: 1, gravityScale: 1, emberScale: 1, autopilot: false))
        XCTAssertEqual(RitualSimulation.tickRate, 120)
        XCTAssertEqual(RitualSimulation.keyframeInterval, 240)
        XCTAssertEqual(RitualSimulation.dt, 1.0 / 120.0)
    }
}
