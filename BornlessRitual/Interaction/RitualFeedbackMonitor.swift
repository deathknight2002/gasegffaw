//
//  RitualFeedbackMonitor.swift
//  Bornless Ritual — simulation state → `RitualEvent` stream for haptics and narration
//  (CORE_API `RitualState.completedTick` "haptics fire when this changes";
//  `RitualEvent` "haptics/narration react to these"; ARCHITECTURE §5 "Rendering uses the
//  sim state at the latest integer tick", §10 the HUD/narration show the current stage's
//  lines in the selected edition).
//
//  Role: a main-thread `CADisplayLink` (60 Hz, `.common` run-loop mode) diffs the
//  simulation state against the previous frame and emits the events the simulation
//  raised in between. The state diff is used instead of `RitualSimulation.lastStepEvents`
//  because that only holds the events of the *last* tick of a frame, while a frame may
//  step up to `Renderer.maxTicksPerFrame` ticks. Relocations (seek / stage jump / capture
//  positioning, detected by `renderer.isWarmingUp`, a backwards tick or a jump larger
//  than `relocationTickThreshold`) resynchronise silently so a scrub never re-fires
//  haptics; narration then restarts for the stage the scrub landed in after a short
//  settle time.
//

import Foundation
import QuartzCore
import RitualCore

/// Per-frame state diff that drives `HapticsEngine` and `Narration`.
@MainActor
final class RitualFeedbackMonitor {
    /// Tick jump per frame above which the change is treated as a relocation, not play.
    static let relocationTickThreshold = 240
    /// Seconds a stage must stay current after a relocation before it is narrated.
    static let narrationSettleSeconds: CFTimeInterval = 0.5

    let renderer: Renderer
    let simulation: RitualSimulation
    let settings: SettingsModel
    let haptics: HapticsEngine
    let narration: Narration

    private var displayLink: CADisplayLink?
    private var proxy: DisplayLinkProxy?

    private var baselineState: RitualState?
    private var baselineTick: Int?
    private var narrationWasEnabled = false
    private var narratedEdition: RitualTextEdition?
    private var pendingStage: RitualStage?
    private var pendingSince: CFTimeInterval = 0

    /// Whether the display link is running.
    private(set) var isRunning = false

    /// Creates the monitor (call `start()` to begin polling).
    init(renderer: Renderer, simulation: RitualSimulation, settings: SettingsModel,
         haptics: HapticsEngine, narration: Narration) {
        self.renderer = renderer
        self.simulation = simulation
        self.settings = settings
        self.haptics = haptics
        self.narration = narration
    }

    deinit {
        // The display link retains only the weak proxy; invalidate it so it stops firing.
        displayLink?.invalidate()
    }

    // MARK: Lifecycle

    /// Starts polling once per display frame.
    func start() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy(monitor: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.displayLinkDidFire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minFrameRate: 30, maxFrameRate: 60, preferred: 60)
        link.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
        self.proxy = proxy
        displayLink = link
        isRunning = true
        baselineState = nil
        baselineTick = nil
    }

    /// Stops polling and silences narration.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
        isRunning = false
        narration.stop()
        narrationWasEnabled = false
        pendingStage = nil
    }

    // MARK: Polling

    /// One poll: diff the state, dispatch haptics, keep narration in step with the stage.
    func poll() {
        let now = CACurrentMediaTime()
        let tick = renderer.currentTick
        let state = simulation.state
        let narrationEnabled = settings.narrationEnabled
        let edition = settings.edition
        defer {
            baselineState = state
            baselineTick = tick
        }

        guard let previous = baselineState, let previousTick = baselineTick else {
            // First poll: establish the baseline; narrate the stage we start in.
            narrationWasEnabled = narrationEnabled
            narratedEdition = edition
            if narrationEnabled {
                narration.speak(stage: state.stage, edition: edition)
            }
            return
        }

        let tickDelta = tick - previousTick
        let relocated = renderer.isWarmingUp || tickDelta < 0 || tickDelta > RitualFeedbackMonitor.relocationTickThreshold

        if !relocated, settings.hapticsEnabled {
            for event in RitualFeedbackMonitor.events(from: previous, to: state) {
                haptics.handle(event)
            }
        }

        updateNarration(previousStage: previous.stage, stage: state.stage, relocated: relocated,
                        enabled: narrationEnabled, edition: edition, now: now)
    }

    private func updateNarration(previousStage: RitualStage, stage: RitualStage, relocated: Bool,
                                 enabled: Bool, edition: RitualTextEdition, now: CFTimeInterval) {
        if enabled != narrationWasEnabled {
            narrationWasEnabled = enabled
            pendingStage = nil
            if enabled {
                narratedEdition = edition
                narration.speak(stage: stage, edition: edition)
            } else {
                narration.stop()
            }
            return
        }
        guard enabled else { return }

        if edition != narratedEdition {
            narratedEdition = edition
            pendingStage = nil
            narration.speak(stage: stage, edition: edition)
            return
        }

        if stage != previousStage {
            if relocated {
                pendingStage = stage
                pendingSince = now
            } else {
                pendingStage = nil
                narration.speak(stage: stage, edition: edition)
            }
        }

        if let pending = pendingStage, now - pendingSince >= RitualFeedbackMonitor.narrationSettleSeconds {
            pendingStage = nil
            if pending == stage {
                narration.speak(stage: stage, edition: edition)
            }
        }
    }

    // MARK: State diff

    /// The events the simulation raised between two states, in the order it raises them
    /// (candle before its stage completion, beats before the eruption, manifestation
    /// begin before the spin stage's completion, completion before `ritualComplete`).
    static func events(from previous: RitualState, to current: RitualState) -> [RitualEvent] {
        var events: [RitualEvent] = []

        for quarter in Quarter.allCases {
            let wasLit = previous.candles[quarter]?.lit ?? false
            let isLit = current.candles[quarter]?.lit ?? false
            if !wasLit && isLit {
                events.append(.candleLit(quarter))
            }
        }

        if current.rhythmRound == previous.rhythmRound {
            if current.beatResults.count > previous.beatResults.count {
                for result in current.beatResults[previous.beatResults.count...] {
                    events.append(.beatHit(result))
                }
            }
        } else if current.stage == .spirit || previous.stage == .spirit {
            for result in current.beatResults {
                events.append(.beatHit(result))
            }
        }

        if !previous.sigilErupted && current.sigilErupted {
            events.append(.sigilErupted)
        }
        if previous.manifestStartTick == nil && current.manifestStartTick != nil {
            events.append(.manifestationBegan)
        }

        let completed = RitualStage.allCases
            .filter { previous.completedTick[$0] == nil && current.completedTick[$0] != nil }
            .sorted { (current.completedTick[$0] ?? 0, $0.rawValue) < (current.completedTick[$1] ?? 0, $1.rawValue) }
        for stage in completed {
            events.append(.stageCompleted(stage))
        }

        if !previous.isComplete && current.isComplete {
            events.append(.ritualComplete)
        }
        return events
    }
}

/// Weak display-link target so the link never retains the monitor.
@MainActor
private final class DisplayLinkProxy: NSObject {
    private weak var monitor: RitualFeedbackMonitor?

    init(monitor: RitualFeedbackMonitor) {
        self.monitor = monitor
        super.init()
    }

    @objc func displayLinkDidFire(_ link: CADisplayLink) {
        monitor?.poll()
    }
}
