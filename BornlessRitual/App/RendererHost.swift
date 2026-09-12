//
//  RendererHost.swift
//  Bornless Ritual — main-actor bridge between the renderer and SwiftUI
//  (ARCHITECTURE §5 "Rendering uses the sim state at the latest integer tick",
//  §7 launch configuration, §8 debug panel stats "published to the debug panel at 4 Hz";
//  RENDER_CONTRACT §1 `Renderer` public API, §7 threading).
//
//  Role: owns the objects created once per process (settings, simulation, daemon
//  profile, ritual text, launch config), receives the `Renderer` from MetalView once
//  the MTKView exists, polls it on the main run loop (30 Hz) into value snapshots the
//  HUD / timeline / debug panel observe, and forwards UI actions (seek, jump, camera
//  preset, render path) to the renderer's main-thread-safe methods. The renderer runs
//  on the MTKView draw thread — the main thread with the default display link — so
//  every access here happens between frames on the same thread.
//

import Foundation
import Combine
import QuartzCore
import RitualCore

// MARK: - RitualSnapshot

/// Value copy of the simulation state the overlay UI needs, taken once per poll.
struct RitualSnapshot: Equatable, Sendable {
    /// Simulation tick rendered.
    var tick: Int = 0
    /// Highest tick reached with the current input log (timeline upper bound).
    var maxSimulatedTick: Int = 0
    /// Ritual seconds (`tick / 120`).
    var time: Double = 0
    /// Current stage.
    var stage: RitualStage = .oath
    /// Progress of the current stage in [0, 1].
    var stageProgress: Double = 0
    /// Tick at which the current stage began.
    var stageStartTick: Int = 0
    /// Whether the chant control is held (oath).
    var holding: Bool = false
    /// Oath chant progress in [0, 1].
    var chantProgress: Double = 0
    /// Camera yaw the simulation last saw, degrees in [0, 360).
    var cameraYaw: Double = 0
    /// Whether the camera faces the current quarter (±30°).
    var facingQuarter: Bool = false
    /// Trace checkpoints hit in order so far.
    var traceHits: Int = 0
    /// Failed trace attempts.
    var traceAttempts: Int = 0
    /// Quarters whose candle is lit.
    var litQuarters: Set<Quarter> = []
    /// Beats judged so far in the current rhythm round.
    var beatIndex: Int = 0
    /// Results of the judged beats in the current round.
    var beatResults: [BeatResult] = []
    /// Zero-based rhythm round.
    var rhythmRound: Int = 0
    /// Tick of each beat of the current round (six entries).
    var beatTicks: [Int] = []
    /// Whether the fiery sigil has erupted.
    var sigilErupted: Bool = false
    /// Spin energy in joules.
    var spinEnergy: Double = 0
    /// Manifestation charge in [0, 1].
    var manifestCharge: Double = 0
    /// Manifestation progress in [0, 1].
    var manifestT: Double = 0
    /// Whether every stage has completed.
    var isComplete: Bool = false
    /// Tick of completion per stage (timeline markers).
    var completedTicks: [RitualStage: Int] = [:]
    /// True while the renderer is inside its 16 warm-up frames.
    var isWarmingUp: Bool = false

    /// Empty snapshot (before the renderer exists).
    init() {}

    /// Snapshot of `state` at `tick`.
    init(tick: Int, maxSimulatedTick: Int, state: RitualState, isWarmingUp: Bool) {
        self.tick = tick
        self.maxSimulatedTick = maxSimulatedTick
        self.time = Double(tick) / Double(RitualSimulation.tickRate)
        self.stage = state.stage
        self.stageProgress = state.stageProgress
        self.stageStartTick = state.stageStartTick
        self.holding = state.holding
        self.chantProgress = state.chantProgress
        self.cameraYaw = state.cameraYaw
        self.facingQuarter = state.facingQuarter
        self.traceHits = state.traceHits
        self.traceAttempts = state.traceAttempts
        self.litQuarters = Set(Quarter.allCases.filter { state.candles[$0]?.lit ?? false })
        self.beatIndex = state.beatIndex
        self.beatResults = state.beatResults
        self.rhythmRound = state.rhythmRound
        self.beatTicks = (0..<RhythmSpec.beatsPerRound).map { state.beatTick($0) }
        self.sigilErupted = state.sigilErupted
        self.spinEnergy = state.spinEnergy
        self.manifestCharge = state.manifestCharge
        self.manifestT = state.manifestT
        self.isComplete = state.isComplete
        self.completedTicks = state.completedTick
        self.isWarmingUp = isWarmingUp
    }

    /// Ritual seconds since the current stage began.
    var stageSeconds: Double {
        Double(max(tick - stageStartTick, 0)) / Double(RitualSimulation.tickRate)
    }

    /// 1-based stage number for "Stage n of 8".
    var stageNumber: Int { stage.rawValue }

    /// Total number of stages.
    var stageCount: Int { RitualStage.allCases.count }
}

// MARK: - RendererHost

/// Observable owner of the renderer reference and the polled UI snapshots.
@MainActor
final class RendererHost: ObservableObject {
    /// Poll rate of the UI snapshot in Hz.
    static let pollHz: Double = 30
    /// Stats refresh interval in seconds (ARCHITECTURE §8: 4 Hz).
    static let statsInterval: CFTimeInterval = 0.25

    /// The settings model (sliders / toggles).
    let settings: SettingsModel
    /// The one simulation of this process (owned by the render thread once it exists).
    let simulation: RitualSimulation
    /// The owner's daemon (Appendix A).
    let profile: DaemonProfile
    /// Ritual text lookup.
    let text: RitualTextProvider
    /// The launch configuration this process was started with.
    let launchConfig: CaptureConfig

    /// The renderer, once MetalView has created it.
    private(set) var renderer: Renderer?

    /// Optional factory for the capture harness (Capture/CaptureHarness.swift, another
    /// job): called once with the renderer; the returned observer is retained here and
    /// installed as `Renderer.frameObserver` (which is weak). `nil` = no capture.
    var captureObserverFactory: ((Renderer) -> RendererFrameObserver?)?
    private var captureObserver: RendererFrameObserver?

    /// Latest simulation snapshot (30 Hz while it changes).
    @Published private(set) var ritual = RitualSnapshot()
    /// Latest frame statistics (4 Hz).
    @Published private(set) var stats = FrameStats()
    /// Active render path.
    @Published private(set) var renderPath: RenderPath = .fallback
    /// Why the render path was chosen (device capability).
    @Published private(set) var renderPathReason: String = "renderer not started"
    /// Whether the MetalFX temporal scaler is active (else the TAA fallback).
    @Published private(set) var metalFXActive: Bool = false
    /// Multi-line device capability report.
    @Published private(set) var capabilityReport: String = ""
    /// Internal render resolution as text ("1170×2532 → 784×1696").
    @Published private(set) var resolutionText: String = ""
    /// Set when the renderer could not be created (no Metal device, no library, …).
    @Published private(set) var rendererError: String?
    /// Set when the scene updater could not be built (the renderer then shows black frames).
    @Published private(set) var sceneUpdaterError: String?

    private var pollTimer: Timer?
    private var lastStatsRefresh: CFTimeInterval = 0

    /// Creates the host over the process-wide objects.
    ///
    /// - Parameters:
    ///   - settings: Settings model already loaded with the launch configuration.
    ///   - simulation: The ritual simulation.
    ///   - profile: The daemon profile.
    ///   - text: Ritual text provider.
    ///   - launchConfig: Parsed launch arguments.
    init(settings: SettingsModel, simulation: RitualSimulation, profile: DaemonProfile,
         text: RitualTextProvider, launchConfig: CaptureConfig) {
        self.settings = settings
        self.simulation = simulation
        self.profile = profile
        self.text = text
        self.launchConfig = launchConfig
    }

    // MARK: Renderer lifecycle (called by MetalView.Coordinator)

    /// Installs the renderer, applies the launch camera / stage and starts polling.
    func rendererDidStart(_ renderer: Renderer) {
        self.renderer = renderer
        rendererError = nil
        capabilityReport = renderer.capabilities.report

        renderer.applyCameraPreset(settings.launchCamera)
        if let factory = captureObserverFactory, let observer = factory(renderer) {
            captureObserver = observer
            renderer.frameObserver = observer
        }
        // Interactive `-stage N` runs start at that stage; capture runs are positioned by
        // the capture harness (autopilot to the showcase tick, ARCHITECTURE §7).
        if !launchConfig.isCaptureRun, settings.launchStage.rawValue > RitualStage.oath.rawValue {
            renderer.jump(to: settings.launchStage)
        }
        refreshRenderInfo(renderer)
        poll()
        startPolling()
    }

    /// Records a scene-updater construction failure for the debug panel.
    func sceneUpdaterFailed(_ error: Error) {
        sceneUpdaterError = String(describing: error)
    }

    /// Records a renderer construction failure for the error overlay.
    func rendererFailed(_ error: Error) {
        rendererError = String(describing: error)
        renderer = nil
        stopPolling()
    }

    /// Drops the renderer reference (view dismantled).
    func rendererDidStop() {
        stopPolling()
        renderer?.frameObserver = nil
        captureObserver = nil
        renderer = nil
    }

    // MARK: UI actions (main thread, between frames)

    /// Scrubs the simulation to `tick` (keyframe restore + replay, or forward simulation).
    func seek(toTick tick: Int) {
        guard let renderer = renderer else { return }
        renderer.seek(toTick: max(tick, 0))
        poll()
    }

    /// Jumps to `stage` deterministically via the autopilot.
    func jump(to stage: RitualStage) {
        guard let renderer = renderer else { return }
        renderer.jump(to: stage)
        poll()
    }

    /// Moves the camera to a preset.
    func applyCameraPreset(_ preset: CameraPreset) {
        renderer?.applyCameraPreset(preset)
    }

    /// Applies a render-path choice immediately (the renderer also reconciles the
    /// settings snapshot every frame; calling here refreshes the reason string at once).
    func setRenderPath(_ choice: RenderPathChoice) {
        guard let renderer = renderer else { return }
        renderer.setRenderPath(choice)
        refreshRenderInfo(renderer)
    }

    /// Toggles `SettingsModel.paused`.
    func togglePause() {
        settings.paused.toggle()
    }

    /// Ritual line for the current stage in the selected edition, cycling with stage time.
    var currentLine: (index: Int, text: String)? {
        text.currentLine(for: ritual.stage, edition: settings.edition, stageSeconds: ritual.stageSeconds)
    }

    // MARK: Polling

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0 / RendererHost.pollHz, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Copies the renderer's state into the published snapshots (only when changed).
    func poll() {
        guard let renderer = renderer else { return }
        let snapshot = RitualSnapshot(tick: renderer.currentTick,
                                      maxSimulatedTick: renderer.simulation.maxSimulatedTick,
                                      state: renderer.simulation.state,
                                      isWarmingUp: renderer.isWarmingUp)
        if snapshot != ritual {
            ritual = snapshot
        }
        let now = CACurrentMediaTime()
        if now - lastStatsRefresh >= RendererHost.statsInterval {
            lastStatsRefresh = now
            let latest = renderer.stats
            if latest != stats {
                stats = latest
            }
            refreshRenderInfo(renderer)
        }
    }

    private func refreshRenderInfo(_ renderer: Renderer) {
        if renderer.renderPath != renderPath { renderPath = renderer.renderPath }
        if renderer.renderPathReason != renderPathReason { renderPathReason = renderer.renderPathReason }
        if renderer.metalFXActive != metalFXActive { metalFXActive = renderer.metalFXActive }
        let output = renderer.resources.outputSize
        let internalSize = renderer.resources.renderSize
        let resolution = "\(output.width)×\(output.height) → \(internalSize.width)×\(internalSize.height)"
        if resolution != resolutionText { resolutionText = resolution }
    }
}
