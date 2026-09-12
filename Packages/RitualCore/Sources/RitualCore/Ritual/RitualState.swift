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
    /// `E_ref` in J·s: `d(charge)/dt = spinEnergy / manifestChargeReference` (ARCHITECTURE §3:
    /// 20 J·s, about three good flicks).
    public static let manifestChargeReference = 20.0
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
    ///
    /// Inputs carrying a non-finite value (see ``InputKind/isFinite``) leave the state
    /// untouched: `RitualSimulation.apply` already refuses to log them, and the guard here
    /// keeps the documented invariants (`cameraYaw` in [0, 360), finite trace samples and
    /// ring velocities) even for inputs that reach the state by another route.
    mutating func consume(_ kind: InputKind, tick: Int) -> [RitualEvent] {
        guard kind.isFinite else { return [] }
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

    /// Judges a tap against the open beat, or ignores it.
    ///
    /// The open beat is always `beatIndex`: a beat is auto-missed at `+goodWindow` by
    /// `integrateRhythm`, and with beats 0.8 s apart and a ±0.30 s good window the next
    /// beat's window opens 0.2 s later still, so the windows never overlap. A tap outside
    /// the open beat's good window therefore belongs to no beat and must not consume one:
    /// it is ignored, the beat stays open for a timely tap (or the timeout miss), and a
    /// stray early or late tap cannot cascade every later on-beat tap into a miss.
    private mutating func judgeTap(tick: Int) -> [RitualEvent] {
        guard beatIndex < RhythmSpec.beatsPerRound else { return [] }
        let offsetTicks = tick - beatTick(beatIndex)
        guard abs(offsetTicks) <= RhythmSpec.goodTicks else { return [] }
        return recordBeat(RhythmSpec.judge(offsetTicks: offsetTicks), tick: tick)
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

// MARK: - Codable (deterministic layout)

extension RitualState {
    private enum CodingKeys: String, CodingKey {
        case stage, stageStartTick, stageProgress, completedStages
        case holding, chantProgress, ringKindle
        case cameraYaw, facingQuarter, trace, traceHits, traceAttempts
        case candles
        case beatIndex, beatResults, rhythmRound
        case sigilErupted, sigilEruptTick
        case sigil
        case spinEnergy, manifestCharge
        case manifestStartTick, manifestT
        case completedTick, lastEvent
    }

    /// Key of one entry in the `candles` (`Quarter.rawValue`) and `completedTick`
    /// (`RitualStage.id`) objects.
    private struct EntryKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    /// Decodes the layout written by ``encode(to:)``.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = try container.decode(RitualStage.self, forKey: .stage)
        stageStartTick = try container.decode(Int.self, forKey: .stageStartTick)
        stageProgress = try container.decode(Double.self, forKey: .stageProgress)
        completedStages = Set(try container.decode([RitualStage].self, forKey: .completedStages))
        holding = try container.decode(Bool.self, forKey: .holding)
        chantProgress = try container.decode(Double.self, forKey: .chantProgress)
        ringKindle = try container.decode(Double.self, forKey: .ringKindle)
        cameraYaw = try container.decode(Double.self, forKey: .cameraYaw)
        facingQuarter = try container.decode(Bool.self, forKey: .facingQuarter)
        trace = try container.decode([RVec2].self, forKey: .trace)
        traceHits = try container.decode(Int.self, forKey: .traceHits)
        traceAttempts = try container.decode(Int.self, forKey: .traceAttempts)
        let candleContainer = try container.nestedContainer(keyedBy: EntryKey.self, forKey: .candles)
        var decodedCandles: [Quarter: CandleState] = [:]
        for quarter in Quarter.allCases {
            let key = EntryKey(stringValue: quarter.rawValue)
            if let candle = try candleContainer.decodeIfPresent(CandleState.self, forKey: key) {
                decodedCandles[quarter] = candle
            }
        }
        candles = decodedCandles
        beatIndex = try container.decode(Int.self, forKey: .beatIndex)
        beatResults = try container.decode([BeatResult].self, forKey: .beatResults)
        rhythmRound = try container.decode(Int.self, forKey: .rhythmRound)
        sigilErupted = try container.decode(Bool.self, forKey: .sigilErupted)
        sigilEruptTick = try container.decodeIfPresent(Int.self, forKey: .sigilEruptTick)
        sigil = try container.decode(SigilDynamics.self, forKey: .sigil)
        spinEnergy = try container.decode(Double.self, forKey: .spinEnergy)
        manifestCharge = try container.decode(Double.self, forKey: .manifestCharge)
        manifestStartTick = try container.decodeIfPresent(Int.self, forKey: .manifestStartTick)
        manifestT = try container.decode(Double.self, forKey: .manifestT)
        let tickContainer = try container.nestedContainer(keyedBy: EntryKey.self, forKey: .completedTick)
        var decodedTicks: [RitualStage: Int] = [:]
        for completed in RitualStage.allCases {
            let key = EntryKey(stringValue: completed.id)
            if let tick = try tickContainer.decodeIfPresent(Int.self, forKey: key) {
                decodedTicks[completed] = tick
            }
        }
        completedTick = decodedTicks
        lastEvent = try container.decodeIfPresent(RitualEvent.self, forKey: .lastEvent)
    }

    /// Encodes the state in a layout whose bytes depend only on the value (ARCHITECTURE §6).
    ///
    /// The synthesized conformance emits `completedStages` in `Set` iteration order and
    /// the enum-keyed dictionaries as flat `[key, value, …]` arrays in `Dictionary` order,
    /// both of which are seeded per process and which no encoder option can sort. Here
    /// `completedStages` is written sorted by stage number, `candles` as an object keyed
    /// by `Quarter.rawValue` and `completedTick` as an object keyed by `RitualStage.id`,
    /// so with `JSONEncoder.OutputFormatting.sortedKeys` (which orders every keyed
    /// object) two encodings of equal states are byte-identical in every process.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stage, forKey: .stage)
        try container.encode(stageStartTick, forKey: .stageStartTick)
        try container.encode(stageProgress, forKey: .stageProgress)
        try container.encode(completedStages.sorted { $0.rawValue < $1.rawValue }, forKey: .completedStages)
        try container.encode(holding, forKey: .holding)
        try container.encode(chantProgress, forKey: .chantProgress)
        try container.encode(ringKindle, forKey: .ringKindle)
        try container.encode(cameraYaw, forKey: .cameraYaw)
        try container.encode(facingQuarter, forKey: .facingQuarter)
        try container.encode(trace, forKey: .trace)
        try container.encode(traceHits, forKey: .traceHits)
        try container.encode(traceAttempts, forKey: .traceAttempts)
        var candleContainer = container.nestedContainer(keyedBy: EntryKey.self, forKey: .candles)
        for quarter in Quarter.allCases {
            if let candle = candles[quarter] {
                try candleContainer.encode(candle, forKey: EntryKey(stringValue: quarter.rawValue))
            }
        }
        try container.encode(beatIndex, forKey: .beatIndex)
        try container.encode(beatResults, forKey: .beatResults)
        try container.encode(rhythmRound, forKey: .rhythmRound)
        try container.encode(sigilErupted, forKey: .sigilErupted)
        try container.encodeIfPresent(sigilEruptTick, forKey: .sigilEruptTick)
        try container.encode(sigil, forKey: .sigil)
        try container.encode(spinEnergy, forKey: .spinEnergy)
        try container.encode(manifestCharge, forKey: .manifestCharge)
        try container.encodeIfPresent(manifestStartTick, forKey: .manifestStartTick)
        try container.encode(manifestT, forKey: .manifestT)
        var tickContainer = container.nestedContainer(keyedBy: EntryKey.self, forKey: .completedTick)
        for completed in RitualStage.allCases {
            if let tick = completedTick[completed] {
                try tickContainer.encode(tick, forKey: EntryKey(stringValue: completed.id))
            }
        }
        try container.encodeIfPresent(lastEvent, forKey: .lastEvent)
    }
}
