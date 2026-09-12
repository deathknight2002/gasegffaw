import Foundation

// MARK: - Rules

/// Tunable thresholds of the ritual mini-games (ARCHITECTURE §3).
public enum RitualRules {
    /// Seconds of continuous hold that complete the oath chant.
    public static let chantDuration = 3.0
    /// Chant progress lost per second while the hold is released.
    public static let chantDecayPerSecond = 0.5
    /// Checkpoints per trace template.
    public static let traceCheckpointCount = SigilTemplates.defaultCheckpointCount
    /// Checkpoints that must be hit, in order, for a trace to light the candle.
    public static let traceRequiredHits = 18
    /// `E_ref` in J·s: `d(charge)/dt = spinEnergy / manifestChargeReference`.
    public static let manifestChargeReference = 1.2
    /// Seconds over which `manifestT` rises 0 → 1 (smoothstep).
    public static let manifestationDuration = 8.0

    /// Hermite smoothstep `x²(3 − 2x)` on `x` clamped to `[0, 1]`.
    public static func smoothstep(_ x: Double) -> Double {
        let clamped = min(max(x, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

// MARK: - RitualState

/// The complete mutable state of the ritual at one simulation tick (ARCHITECTURE §3, §5).
///
/// Everything the renderer and HUD need is here; a `Keyframe` snapshots it verbatim, so
/// the struct must stay a plain value with no hidden identity. Stage transitions are
/// performed by the internal `consume`/`integrate` methods driven by `RitualSimulation`.
public struct RitualState: Codable, Sendable, Equatable {
    /// Current stage.
    public var stage: RitualStage
    /// Tick at which `stage` began (the tick whose step completed the previous stage).
    public var stageStartTick: Int
    /// Progress of the current stage in `[0, 1]` (see `refreshProgress`).
    public var stageProgress: Double
    /// Stages completed so far.
    public var completedStages: Set<RitualStage>

    /// Whether the chant control is held (oath).
    public var holding: Bool
    /// Oath chant progress in `[0, 1]`.
    public var chantProgress: Double
    /// Kindle intensity of the chalk ring; equals `chantProgress` and stays 1 after the oath.
    public var ringKindle: Double

    /// Camera yaw in degrees, normalised to `[0, 360)`.
    public var cameraYaw: Double
    /// Whether the camera faces the current stage's quarter within ±30°.
    public var facingQuarter: Bool
    /// Accepted trace samples of the current attempt.
    public var trace: [RVec2]
    /// Checkpoints hit in order by `trace` so far.
    public var traceHits: Int
    /// Failed trace attempts (cumulative over the ritual).
    public var traceAttempts: Int

    /// State of the four quarter candles.
    public var candles: [Quarter: CandleState]

    /// Beats judged so far in the current rhythm round.
    public var beatIndex: Int
    /// Results of the judged beats in the current round.
    public var beatResults: [BeatResult]
    /// Zero-based rhythm round; increments after a failed round.
    public var rhythmRound: Int

    /// Whether the fiery sigil has erupted (Spirit complete).
    public var sigilErupted: Bool
    /// Tick of the sigil eruption.
    public var sigilEruptTick: Int?

    /// Ring dynamics of the sigil.
    public var sigil: SigilDynamics

    /// Spin energy `E = Σ ½Iω²` in joules (updated every tick from `sigil`).
    public var spinEnergy: Double
    /// Manifestation charge in `[0, 1]`.
    public var manifestCharge: Double

    /// Tick at which the manifestation began (charge reached 1).
    public var manifestStartTick: Int?
    /// Manifestation progress in `[0, 1]` (smoothstep over 8 s).
    public var manifestT: Double

    /// Tick at which each stage completed (haptics fire when this changes).
    public var completedTick: [RitualStage: Int]
    /// The most recent event raised by the simulation.
    public var lastEvent: RitualEvent?

    /// The initial state: oath stage, nothing held, all candles unlit, rings at rest.
    public init() {
        stage = .oath
        stageStartTick = 0
        stageProgress = 0
        completedStages = []
        holding = false
        chantProgress = 0
        ringKindle = 0
        cameraYaw = 0
        facingQuarter = false
        trace = []
        traceHits = 0
        traceAttempts = 0
        candles = Dictionary(uniqueKeysWithValues: Quarter.allCases.map { ($0, CandleState.unlit) })
        beatIndex = 0
        beatResults = []
        rhythmRound = 0
        sigilErupted = false
        sigilEruptTick = nil
        sigil = SigilDynamics()
        spinEnergy = 0
        manifestCharge = 0
        manifestStartTick = nil
        manifestT = 0
        completedTick = [:]
        lastEvent = nil
    }

    /// Whether every stage, including the manifestation, has completed.
    public var isComplete: Bool {
        completedStages.count == RitualStage.allCases.count
    }

    /// Tick of the beat `index` of the current rhythm round.
    public func beatTick(_ index: Int) -> Int {
        RhythmSpec.beatTick(round: rhythmRound, index: index, stageStartTick: stageStartTick)
    }
}

// MARK: - Stage machine (internal)

extension RitualState {
    /// Applies one input at `tick`. Returns the events it raised, in order.
    mutating func consume(_ kind: InputKind, tick: Int) -> [RitualEvent] {
        switch kind {
        case .holdBegin:
            holding = true
            return []
        case .holdEnd:
            holding = false
            return []
        case .cameraYaw(let yaw):
            cameraYaw = Angle.normalize(yaw)
            refreshFacing()
            return []
        case .tracePoint(let point):
            acceptTracePoint(point)
            return []
        case .traceEnd:
            return finishTrace(tick: tick)
        case .tap:
            guard stage == .spirit else { return [] }
            return judgeTap(tick: tick)
        case .flick(let velocity, let ring):
            guard stage == .sigilSpin || stage == .manifestation else { return [] }
            sigil.applyFlick(velocity: velocity, ring: ring)
            return []
        }
    }

    /// Advances the stage logic by one tick (after the tick's inputs were consumed).
    /// Returns the events raised, in order.
    mutating func integrate(tick: Int, config: SimConfig) -> [RitualEvent] {
        var events: [RitualEvent] = []
        refreshFacing()
        switch stage {
        case .oath:
            events += integrateOath(tick: tick)
        case .air, .fire, .water, .earth:
            break
        case .spirit:
            events += integrateRhythm(tick: tick)
        case .sigilSpin:
            events += integrateSpin(tick: tick, config: config)
        case .manifestation:
            events += integrateManifestation(tick: tick, config: config)
        }
        updateCandles(tick: tick)
        refreshProgress()
        return events
    }

    // MARK: Oath

    private mutating func integrateOath(tick: Int) -> [RitualEvent] {
        let dt = RitualSimulation.dt
        if holding {
            chantProgress += dt / RitualRules.chantDuration
        } else {
            chantProgress = max(0, chantProgress - RitualRules.chantDecayPerSecond * dt)
        }
        if chantProgress >= 1 {
            chantProgress = 1
            ringKindle = 1
            return [completeStage(at: tick)]
        }
        ringKindle = chantProgress
        return []
    }

    // MARK: Quarters

    private mutating func refreshFacing() {
        if let quarter = stage.quarter {
            facingQuarter = quarter.isFaced(byYaw: cameraYaw)
        } else {
            facingQuarter = false
        }
    }

    private mutating func acceptTracePoint(_ point: RVec2) {
        guard let element = stage.element, stage.quarter != nil, facingQuarter else { return }
        trace.append(point)
        traceHits = TraceScorer.advance(hits: traceHits, point: point, checkpoints: SigilTemplates.checkpoints(for: element))
    }

    private mutating func finishTrace(tick: Int) -> [RitualEvent] {
        guard let quarter = stage.quarter, let element = stage.element else { return [] }
        let score = TraceScorer.score(trace: trace, checkpoints: SigilTemplates.checkpoints(for: element))
        guard score >= RitualRules.traceRequiredHits else {
            traceAttempts += 1
            trace.removeAll()
            traceHits = 0
            return []
        }
        candles[quarter] = CandleState(lit: true, ignitionTick: tick, intensity: 0)
        return [.candleLit(quarter), completeStage(at: tick)]
    }

    private mutating func updateCandles(tick: Int) {
        let rampTicks = CandleState.rampSeconds * Double(RitualSimulation.tickRate)
        for quarter in Quarter.allCases {
            guard var candle = candles[quarter], candle.lit, let ignition = candle.ignitionTick else { continue }
            candle.intensity = min(1, max(0, Double(tick - ignition) / rampTicks))
            candles[quarter] = candle
        }
    }

    // MARK: Rhythm

    private mutating func judgeTap(tick: Int) -> [RitualEvent] {
        guard beatIndex < RhythmSpec.beatsPerRound else { return [] }
        // The nearest unjudged beat. Earlier beats are auto-missed at +goodWindow before the
        // next beat comes within reach, so in practice this is always `beatIndex`; skipped
        // beats (if any) are recorded as misses to keep the results in order.
        var nearest = beatIndex
        var nearestDistance = abs(beatTick(beatIndex) - tick)
        for index in (beatIndex + 1)..<RhythmSpec.beatsPerRound {
            let distance = abs(beatTick(index) - tick)
            if distance < nearestDistance {
                nearest = index
                nearestDistance = distance
            }
        }
        var events: [RitualEvent] = []
        while beatIndex < nearest && stage == .spirit {
            events += recordBeat(.miss, tick: tick)
        }
        guard stage == .spirit, beatIndex < RhythmSpec.beatsPerRound else { return events }
        let result = RhythmSpec.judge(offsetTicks: tick - beatTick(beatIndex))
        events += recordBeat(result, tick: tick)
        return events
    }

    private mutating func integrateRhythm(tick: Int) -> [RitualEvent] {
        var events: [RitualEvent] = []
        while stage == .spirit, beatIndex < RhythmSpec.beatsPerRound, tick >= beatTick(beatIndex) + RhythmSpec.goodTicks {
            events += recordBeat(.miss, tick: tick)
        }
        return events
    }

    private mutating func recordBeat(_ result: BeatResult, tick: Int) -> [RitualEvent] {
        beatResults.append(result)
        beatIndex += 1
        var events: [RitualEvent] = [.beatHit(result)]
        guard beatIndex >= RhythmSpec.beatsPerRound else { return events }
        let hits = beatResults.filter(\.isHit).count
        if hits >= RhythmSpec.requiredHits {
            sigilErupted = true
            sigilEruptTick = tick
            events.append(.sigilErupted)
            events.append(completeStage(at: tick))
        } else {
            rhythmRound += 1
            beatIndex = 0
            beatResults.removeAll()
        }
        return events
    }

    // MARK: Sigil spin and manifestation

    private mutating func stepSigil(config: SimConfig) {
        sigil.step(dt: RitualSimulation.dt, frictionScale: config.frictionScale)
        spinEnergy = sigil.kineticEnergy
    }

    private mutating func integrateSpin(tick: Int, config: SimConfig) -> [RitualEvent] {
        stepSigil(config: config)
        manifestCharge = min(1, manifestCharge + spinEnergy / RitualRules.manifestChargeReference * RitualSimulation.dt)
        guard manifestCharge >= 1 else { return [] }
        manifestCharge = 1
        manifestStartTick = tick
        return [.manifestationBegan, completeStage(at: tick)]
    }

    private mutating func integrateManifestation(tick: Int, config: SimConfig) -> [RitualEvent] {
        stepSigil(config: config)
        guard let start = manifestStartTick else { return [] }
        let elapsed = Double(tick - start) * RitualSimulation.dt
        manifestT = RitualRules.smoothstep(elapsed / RitualRules.manifestationDuration)
        guard manifestT >= 1, !completedStages.contains(.manifestation) else { return [] }
        manifestT = 1
        return [completeStage(at: tick), .ritualComplete]
    }

    // MARK: Transitions

    /// Marks the current stage complete at `tick`, advances to the next stage (if any) and
    /// returns the `.stageCompleted` event.
    private mutating func completeStage(at tick: Int) -> RitualEvent {
        let finished = stage
        completedStages.insert(finished)
        completedTick[finished] = tick
        if let next = finished.next {
            stage = next
            stageStartTick = tick
            trace.removeAll()
            traceHits = 0
            refreshFacing()
        }
        return .stageCompleted(finished)
    }

    /// Recomputes `stageProgress` from the current stage's own measure.
    mutating func refreshProgress() {
        switch stage {
        case .oath:
            stageProgress = min(max(chantProgress, 0), 1)
        case .air, .fire, .water, .earth:
            stageProgress = min(max(Double(traceHits) / Double(RitualRules.traceCheckpointCount), 0), 1)
        case .spirit:
            stageProgress = min(max(Double(beatIndex) / Double(RhythmSpec.beatsPerRound), 0), 1)
        case .sigilSpin:
            stageProgress = min(max(manifestCharge, 0), 1)
        case .manifestation:
            stageProgress = min(max(manifestT, 0), 1)
        }
    }
}
