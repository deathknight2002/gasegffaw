import Foundation

/// Deterministic input scripts that play the ritual for captures and stage jumps
/// (ARCHITECTURE §7).
///
/// The script is generated closed-loop: a private simulation is driven stage by stage,
/// each stage's actions are scheduled relative to the tick at which that stage actually
/// began, and the resulting input list is fixed for a given seed and starting state.
/// Per stage the autopilot: holds the chant for 3.2 s; turns the camera to each quarter
/// at +0.2 s and then traces the template (180 samples, one per tick over 1.5 s, jittered
/// by ±0.01 from `Hash`) before lifting; taps 0.02 s after every beat; and flicks the
/// sigil three times (`(3.5, 0)` on ring 0 at +0.5 s, ring 1 at +1.5 s, ring 0 at +3.0 s).
/// With the contract friction and coupling coefficients those three flicks must charge
/// the manifestation within about 15 s, which fixes `SigilDynamics.flickImpulsePerSpeed`.
public enum Autopilot {
    /// Seconds the oath control is held.
    public static let holdSeconds = 3.2
    /// Delay after a quarter stage begins before the camera turns to it.
    public static let cameraTurnDelaySeconds = 0.2
    /// Duration of a traced template.
    public static let traceSeconds = 1.5
    /// Half-range of the per-sample trace jitter in normalised units.
    public static let traceJitter = 0.01
    /// Offset of every tap after its beat.
    public static let tapLateSeconds = 0.02
    /// Flick velocity in normalised sigil-plane units per second.
    public static let flickVelocity = RVec2(3.5, 0)
    /// Stage-relative flick times in seconds with the ring under the finger.
    public static let flickSchedule: [(seconds: Double, ring: Int)] = [(0.5, 0), (1.5, 1), (3.0, 0)]
    /// Upper bound on the ticks the generator will wait for one stage to complete.
    public static let maxTicksPerStage = 120 * 120

    /// Showcase offsets (ARCHITECTURE/CORE_API "Showcase definitions"): seconds after the
    /// stage's key moment at which the critic captures it.
    public static let oathShowcaseSeconds = 1.8
    /// Seconds after a quarter candle ignites at which that stage is captured.
    public static let candleShowcaseSeconds = 1.2
    /// Seconds after the sigil erupts at which the Spirit stage is captured.
    public static let spiritShowcaseSeconds = 1.0
    /// Seconds after the third autopilot flick at which the spin stage is captured.
    public static let spinShowcaseSeconds = 1.0
    /// Seconds after `manifestT` reaches 1 at which the manifestation is captured.
    public static let manifestationShowcaseSeconds = 2.0

    /// Deterministic input script that completes every stage before `stage` and then
    /// performs `stage`'s own showcase actions (the chant hold, the trace, the taps, the
    /// three flicks; nothing for the manifestation).
    ///
    /// - Parameters:
    ///   - stage: Target stage.
    ///   - seed: Simulation seed (drives the trace jitter).
    ///   - startTick: Tick at which the script begins on a fresh, idle simulation.
    public static func inputs(through stage: RitualStage, seed: UInt64, startTick: Int = 0) -> [RitualInput] {
        let simulation = RitualSimulation(seed: seed)
        simulation.step(ticks: max(0, startTick))
        return script(continuing: simulation, through: stage, includeShowcaseActions: true)
    }

    /// Tick at which the critic captures `stage` when the ritual is played by
    /// `inputs(through: stage, seed: seed)` from tick 0.
    ///
    /// Oath: 1.8 s into the chant. Air/Fire/Water/Earth: 1.2 s after that quarter's candle
    /// ignites. Spirit: 1.0 s after the sigil erupts. Sigil spin: 1.0 s after the third
    /// flick. Manifestation: 2.0 s after `manifestT` reaches 1.
    ///
    /// - Parameters:
    ///   - stage: Stage to capture.
    ///   - seed: Simulation seed.
    public static func showcaseTick(for stage: RitualStage, seed: UInt64) -> Int {
        let script = inputs(through: stage, seed: seed)
        let simulation = RitualSimulation(seed: seed)
        for input in script {
            simulation.apply(input)
        }
        let budget = maxTicksPerStage * RitualStage.allCases.count

        func tickWhen(_ condition: (RitualState) -> Int?) -> Int {
            var remaining = budget
            while remaining > 0 {
                if let found = condition(simulation.state) {
                    return found
                }
                simulation.step()
                remaining -= 1
            }
            return simulation.tick
        }

        switch stage {
        case .oath:
            let holdTick = script.first { $0.kind == .holdBegin }?.tick ?? 0
            return holdTick + RhythmSpec.ticks(forSeconds: oathShowcaseSeconds)
        case .air, .fire, .water, .earth:
            let quarter = stage.quarter ?? .east
            return tickWhen { $0.candles[quarter]?.ignitionTick } + RhythmSpec.ticks(forSeconds: candleShowcaseSeconds)
        case .spirit:
            return tickWhen { $0.sigilEruptTick } + RhythmSpec.ticks(forSeconds: spiritShowcaseSeconds)
        case .sigilSpin:
            let lastFlick = script.last { if case .flick = $0.kind { return true } else { return false } }
            return (lastFlick?.tick ?? tickWhen { $0.completedTick[.spirit] }) + RhythmSpec.ticks(forSeconds: spinShowcaseSeconds)
        case .manifestation:
            return tickWhen { $0.completedTick[.manifestation] } + RhythmSpec.ticks(forSeconds: manifestationShowcaseSeconds)
        }
    }

    // MARK: - Script generation (internal)

    /// Generates the script from the current position of `simulation` without touching it.
    ///
    /// Each stage's actions are emitted once; if the stage has not completed
    /// `retryGraceTicks` after the last emitted action (a botched live rhythm round being
    /// continued, or a friction slider that makes three flicks insufficient) the actions
    /// are emitted again from the probe's new position, until `maxTicksPerStage` elapse.
    ///
    /// - Parameters:
    ///   - simulation: The simulation to continue from (cloned; never mutated).
    ///   - stage: Target stage.
    ///   - includeShowcaseActions: Whether to append the target stage's own actions.
    static func script(continuing simulation: RitualSimulation, through stage: RitualStage,
                       includeShowcaseActions: Bool) -> [RitualInput] {
        let probe = RitualSimulation(copying: simulation)
        var script: [RitualInput] = []

        while probe.state.stage.rawValue < stage.rawValue {
            let current = probe.state.stage
            var lastActionTick = emit(actions(for: current, on: probe), to: probe, script: &script)
            let grace = retryGraceTicks(for: current)
            var budget = maxTicksPerStage
            while probe.state.stage == current, budget > 0 {
                probe.step()
                budget -= 1
                if probe.state.stage == current, probe.tick > lastActionTick + grace {
                    lastActionTick = emit(actions(for: current, on: probe), to: probe, script: &script)
                }
            }
            guard probe.state.stage != current else { break }
        }

        if includeShowcaseActions, probe.state.stage == stage {
            _ = emit(actions(for: stage, on: probe), to: probe, script: &script)
        }
        return script
    }

    /// Applies `actions` to the probe and appends them to the script; returns the tick of
    /// the last action (or the probe's current tick when there are none).
    @discardableResult
    private static func emit(_ actions: [RitualInput], to probe: RitualSimulation, script: inout [RitualInput]) -> Int {
        for action in actions {
            probe.apply(action)
            script.append(action)
        }
        return actions.map(\.tick).max() ?? probe.tick
    }

    /// Ticks to wait after a stage's last action before re-emitting its actions.
    private static func retryGraceTicks(for stage: RitualStage) -> Int {
        switch stage {
        case .oath, .air, .fire, .water, .earth:
            return RhythmSpec.ticks(forSeconds: 0.1)
        case .spirit:
            return RhythmSpec.goodTicks + RhythmSpec.ticks(forSeconds: 0.2)
        case .sigilSpin:
            return RhythmSpec.ticks(forSeconds: 12.0)
        case .manifestation:
            return maxTicksPerStage
        }
    }

    /// The autopilot's actions for `stage`, scheduled from the probe's current position.
    private static func actions(for stage: RitualStage, on probe: RitualSimulation) -> [RitualInput] {
        let state = probe.state
        let now = probe.tick
        func at(_ seconds: Double) -> Int {
            max(state.stageStartTick + RhythmSpec.ticks(forSeconds: seconds), now)
        }

        switch stage {
        case .oath:
            let begin = at(0)
            return [
                RitualInput(tick: begin, kind: .holdBegin),
                RitualInput(tick: begin + RhythmSpec.ticks(forSeconds: holdSeconds), kind: .holdEnd),
            ]
        case .air, .fire, .water, .earth:
            guard let quarter = stage.quarter, let element = stage.element else { return [] }
            let turnTick = at(cameraTurnDelaySeconds)
            var inputs = [RitualInput(tick: turnTick, kind: .cameraYaw(quarter.yawDegrees))]
            let sampleCount = RhythmSpec.ticks(forSeconds: traceSeconds)
            let samples = SigilTemplates.checkpoints(for: element, count: sampleCount)
            for (offset, sample) in samples.enumerated() {
                let sampleTick = turnTick + 1 + offset
                let jittered = sample + traceJitterOffset(seed: probe.seed, tick: sampleTick, index: offset)
                inputs.append(RitualInput(tick: sampleTick, kind: .tracePoint(jittered)))
            }
            inputs.append(RitualInput(tick: turnTick + 1 + sampleCount, kind: .traceEnd))
            return inputs
        case .spirit:
            let late = RhythmSpec.ticks(forSeconds: tapLateSeconds)
            return (state.beatIndex..<RhythmSpec.beatsPerRound).compactMap { index in
                let tapTick = state.beatTick(index) + late
                return tapTick >= now ? RitualInput(tick: tapTick, kind: .tap) : nil
            }
        case .sigilSpin:
            return flickSchedule.map { entry in
                RitualInput(tick: at(entry.seconds), kind: .flick(velocity: flickVelocity, ring: entry.ring))
            }
        case .manifestation:
            return []
        }
    }

    /// Per-sample trace jitter in `[−traceJitter, +traceJitter)` from `Hash` channels 5 and 6.
    private static func traceJitterOffset(seed: UInt64, tick: Int, index: Int) -> RVec2 {
        let tickKey = UInt32(truncatingIfNeeded: tick)
        let indexKey = UInt32(truncatingIfNeeded: index)
        let x = (Hash.unit(seed, tickKey, indexKey, 5) * 2 - 1) * traceJitter
        let y = (Hash.unit(seed, tickKey, indexKey, 6) * 2 - 1) * traceJitter
        return RVec2(x, y)
    }
}
