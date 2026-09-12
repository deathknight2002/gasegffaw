import Foundation

// MARK: - SimConfig

/// Live simulation settings from the debug panel (ARCHITECTURE §8).
///
/// The configuration is not part of a `Keyframe`; a replay uses whatever configuration
/// is current, so a run is reproducible as long as the configuration is held fixed.
public struct SimConfig: Codable, Sendable, Equatable {
    /// Multiplier on both sigil friction coefficients (slider 0–3, default 1). Values
    /// below 0 act as 0 and values above `SigilDynamics.maxFrictionScale` (10) as that
    /// maximum, which keeps the ring integration stable and monotonically dissipative.
    public var frictionScale: Double
    /// Multiplier on gravity for embers (slider 0–3, default 1).
    public var gravityScale: Double
    /// Multiplier on the ember spawn count (slider 0–3, default 1).
    public var emberScale: Double
    /// Whether the autopilot is driving the ritual.
    public var autopilot: Bool

    /// Default settings: all scales 1, autopilot off.
    public init() {
        frictionScale = 1
        gravityScale = 1
        emberScale = 1
        autopilot = false
    }

    /// Creates a configuration with explicit values.
    ///
    /// - Parameters:
    ///   - frictionScale: Multiplier on the sigil friction coefficients.
    ///   - gravityScale: Multiplier on ember gravity.
    ///   - emberScale: Multiplier on the ember spawn count.
    ///   - autopilot: Whether the autopilot drives the ritual.
    public init(frictionScale: Double, gravityScale: Double, emberScale: Double, autopilot: Bool) {
        self.frictionScale = frictionScale
        self.gravityScale = gravityScale
        self.emberScale = emberScale
        self.autopilot = autopilot
    }
}

// MARK: - Keyframe

/// Snapshot of the whole mutable simulation at a tick (ARCHITECTURE §5).
///
/// The state is the one *before* the inputs stamped with `tick` are consumed, so restoring
/// a keyframe and replaying the input log from `tick` reproduces the run exactly.
public struct Keyframe: Codable, Sendable, Equatable {
    /// Tick of the snapshot.
    public let tick: Int
    /// Ritual state at `tick`.
    public let state: RitualState
    /// Generator state at `tick`.
    public let rng: SeededRNG

    /// Creates a keyframe.
    ///
    /// - Parameters:
    ///   - tick: Tick of the snapshot.
    ///   - state: Ritual state at that tick.
    ///   - rng: Generator state at that tick.
    public init(tick: Int, state: RitualState, rng: SeededRNG) {
        self.tick = tick
        self.state = state
        self.rng = rng
    }
}

// MARK: - RitualSimulation

/// Fixed-step (120 Hz) ritual simulation with an input log and keyframes (ARCHITECTURE §5).
///
/// `step()` consumes the inputs stamped with the current tick in the order they were
/// applied, integrates one tick of stage logic, advances `tick`, and records a keyframe
/// every `keyframeInterval` ticks. Scrubbing restores the nearest keyframe at or before
/// the target and replays the log. The class is not `Sendable`: the render thread owns it.
public final class RitualSimulation {
    /// Simulation rate in ticks per second.
    public static let tickRate = 120
    /// Ticks between keyframes (2 s).
    public static let keyframeInterval = 240
    /// Seconds per tick.
    public static let dt = 1.0 / Double(tickRate)

    /// The seed every deterministic effect derives from.
    public let seed: UInt64
    /// Current tick; the state is the state *at* this tick, before its inputs are consumed.
    public private(set) var tick: Int
    /// Ritual state at `tick`.
    public private(set) var state: RitualState
    /// Live settings (not keyframed).
    public var config: SimConfig
    /// Every input applied, in application order.
    public private(set) var inputLog: [RitualInput]
    /// Keyframes in ascending tick order; the first is always tick 0.
    public private(set) var keyframes: [Keyframe]
    /// Highest tick reached with the current input log.
    public private(set) var maxSimulatedTick: Int
    /// Events raised by the most recent `step()`, in order. Empty after any `seek`, even
    /// one that lands on (or replays through) a tick that raised events, so a haptics or
    /// narration layer keyed on this never re-fires on a scrub landing.
    public private(set) var lastStepEvents: [RitualEvent]

    /// Generator state; snapshotted in keyframes so stochastic effects rewind exactly.
    private var rng: SeededRNG
    /// `inputLog` ordered by tick (stable), for consumption.
    private var orderedInputs: [RitualInput]
    /// Index into `orderedInputs` of the first input with `tick >= self.tick`.
    private var nextInputIndex: Int

    /// Creates a simulation at tick 0 with the initial ritual state and a tick-0 keyframe.
    ///
    /// - Parameters:
    ///   - seed: Seed for every deterministic effect.
    ///   - config: Initial live settings.
    public init(seed: UInt64, config: SimConfig = SimConfig()) {
        self.seed = seed
        self.config = config
        tick = 0
        state = RitualState()
        inputLog = []
        orderedInputs = []
        nextInputIndex = 0
        rng = SeededRNG(seed: seed)
        keyframes = []
        maxSimulatedTick = 0
        lastStepEvents = []
        keyframes = [Keyframe(tick: 0, state: state, rng: rng)]
    }

    /// Creates an independent copy of `other` (same tick, state, log, keyframes and generator).
    init(copying other: RitualSimulation) {
        seed = other.seed
        config = other.config
        tick = other.tick
        state = other.state
        inputLog = other.inputLog
        orderedInputs = other.orderedInputs
        nextInputIndex = other.nextInputIndex
        rng = other.rng
        keyframes = other.keyframes
        maxSimulatedTick = other.maxSimulatedTick
        lastStepEvents = other.lastStepEvents
    }

    /// Current ritual time in seconds (`tick / 120`).
    public var time: Double {
        Double(tick) * Self.dt
    }

    // MARK: Inputs

    /// Records an input for consumption at its tick.
    ///
    /// Inputs must be stamped with the current tick or later; an input stamped earlier is
    /// re-stamped to the current tick (it cannot change the past). Keyframes after the
    /// input's tick are discarded because the run beyond it has changed.
    ///
    /// An input carrying a non-finite value (NaN or ±∞ yaw, trace point or flick
    /// velocity — see ``InputKind/isFinite``) is rejected outright: it is neither logged
    /// nor applied, so the state, the keyframes and the input log always stay finite and
    /// JSON-encodable.
    ///
    /// - Parameter input: The input to log.
    public func apply(_ input: RitualInput) {
        guard input.kind.isFinite else { return }
        let stamped = input.tick >= tick ? input : RitualInput(tick: tick, kind: input.kind)
        inputLog.append(stamped)
        let position = Self.upperBound(of: stamped.tick, in: orderedInputs)
        orderedInputs.insert(stamped, at: position)
        keyframes.removeAll { $0.tick > stamped.tick }
        maxSimulatedTick = min(maxSimulatedTick, max(stamped.tick, tick))
    }

    // MARK: Stepping

    /// Advances one tick: consumes this tick's inputs, integrates, then keyframes if due.
    public func step() {
        var events: [RitualEvent] = []
        while nextInputIndex < orderedInputs.count, orderedInputs[nextInputIndex].tick == tick {
            events += state.consume(orderedInputs[nextInputIndex].kind, tick: tick)
            nextInputIndex += 1
        }
        events += state.integrate(tick: tick, config: config)
        if let last = events.last {
            state.lastEvent = last
        }
        lastStepEvents = events
        tick += 1
        maxSimulatedTick = max(maxSimulatedTick, tick)
        if tick % Self.keyframeInterval == 0, (keyframes.last?.tick ?? -1) < tick {
            keyframes.append(Keyframe(tick: tick, state: state, rng: rng))
        }
    }

    /// Advances `ticks` ticks (no-op for values ≤ 0).
    public func step(ticks: Int) {
        guard ticks > 0 else { return }
        for _ in 0..<ticks {
            step()
        }
    }

    // MARK: Seeking

    /// Moves the simulation to `target` (clamped at 0).
    ///
    /// Restores the nearest keyframe at or before `target` and replays the input log up
    /// to it; when the current position already lies between that keyframe and the target
    /// the simulation simply steps forward. Targets beyond `maxSimulatedTick` are simulated.
    /// `lastStepEvents` is empty afterwards on both paths.
    ///
    /// - Parameter target: Destination tick.
    public func seek(toTick target: Int) {
        let destination = max(0, target)
        guard let keyframe = keyframes.last(where: { $0.tick <= destination }) else { return }
        defer { lastStepEvents = [] }
        if tick <= destination, tick >= keyframe.tick {
            step(ticks: destination - tick)
            return
        }
        restore(keyframe)
        step(ticks: destination - keyframe.tick)
    }

    private func restore(_ keyframe: Keyframe) {
        tick = keyframe.tick
        state = keyframe.state
        rng = keyframe.rng
        nextInputIndex = Self.lowerBound(of: keyframe.tick, in: orderedInputs)
        lastStepEvents = []
    }

    // MARK: Stage jump

    /// Drives the ritual forward to the start of `stage` with the autopilot.
    ///
    /// The autopilot's inputs for every stage before `stage` are generated from the
    /// current state, appended to the log from the current tick, and the simulation
    /// steps until `stage` is active. Does nothing when the ritual is already at or past
    /// `stage`. The result is deterministic for a given seed and current state.
    ///
    /// - Parameter stage: Stage to jump to.
    public func jump(to stage: RitualStage) {
        guard state.stage.rawValue < stage.rawValue else { return }
        for input in Autopilot.script(continuing: self, through: stage, includeShowcaseActions: false) {
            apply(input)
        }
        var budget = Autopilot.maxTicksPerStage * RitualStage.allCases.count
        while state.stage.rawValue < stage.rawValue, budget > 0 {
            step()
            budget -= 1
        }
    }

    // MARK: Helpers

    /// First index whose tick is `>= value`.
    private static func lowerBound(of value: Int, in inputs: [RitualInput]) -> Int {
        var low = 0
        var high = inputs.count
        while low < high {
            let mid = (low + high) / 2
            if inputs[mid].tick < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// First index whose tick is `> value`.
    private static func upperBound(of value: Int, in inputs: [RitualInput]) -> Int {
        var low = 0
        var high = inputs.count
        while low < high {
            let mid = (low + high) / 2
            if inputs[mid].tick <= value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
