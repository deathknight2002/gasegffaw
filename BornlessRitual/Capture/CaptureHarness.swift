//
//  CaptureHarness.swift
//  Bornless Ritual — on-device capture harness (ARCHITECTURE §7: launch arguments →
//  autopilot to the showcase tick → 16 warm-up frames → stills / clip / perf, always
//  `frametime.json` + `manifest.json` under Documents/Captures/<runName>/; §6 warm-up
//  determinism "the 16th is displayed or captured"; RENDER_CONTRACT §2 row 14 Readback,
//  §7 "PNG encoding on a background queue with backpressure (clip mode uses a bounded
//  queue)"; CORE_API `CaptureConfig`, `FrameLog`, `Autopilot`).
//
//  Role: adopts `RendererFrameObserver` (Renderer.swift) and drives one run:
//    1. `start()` (main thread, before the first frame): applies the autopilot script
//       for the target stage to the simulation at tick 0, positions the camera on the
//       preset, and `renderer.seek(toTick: showcaseTick)` — which resets history and
//       schedules the 16 warm-up frames. Stills / clips request the readback of that
//       16th frame immediately (the Renderer services readbacks only on the frame that
//       ends a warm-up). If the drawable size changes while positioning (SwiftUI lays
//       the MTKView out after the first frames), the seek is issued again so the
//       captured frame always has a full 16-frame warm-up at the final size.
//    2. `didFinishWarmupAtTick`: switches to the mode's phase and starts frame logging.
//    3. stills: one PNG of the warm-up frame → finish.
//       clip:   `fixedFrameDeltaTime = 1/60` (deterministic time) and one readback per
//               live frame for clipSeconds × 60 frames; at most `inFlightLimit` (8)
//               frames may be between readback and finished PNG — the draw thread waits
//               on a semaphore otherwise (determinism over speed).
//       perf:   the full ritual on autopilot for perfSeconds of wall time.
//    4. `finishRun()`: drains the PNG queue, writes `frametime.json` and `manifest.json`
//       (plus per-capture copies `<stem>.frametime.json` / `<stem>.manifest.json`, since
//       every critic run shares the run name "critic"), prints `CAPTURE_DONE <dir>` and,
//       for capture runs, exits the process after 1 s. Failures print `CAPTURE_FAILED`.
//
//  Threading: `start` runs on the main thread; `willEncodeFrame` / `didFinishWarmup` on
//  the draw thread; `didCompleteFrame` on Metal's completion thread; readback images on
//  the Renderer's readback queue; PNG completions on the writer queue. All mutable state
//  is guarded by one lock; file writes happen on `workQueue`.
//

import Foundation
import QuartzCore
import CoreGraphics
import Metal
import RitualCore
import os

/// Drives stills / clip / perf captures on the renderer's frame loop.
final class CaptureHarness: RendererFrameObserver {

    /// Where the run is.
    enum Phase: Equatable {
        /// Created, not started.
        case idle
        /// Script applied, seek issued, warm-up frames rendering.
        case positioning
        /// Warm-up done; waiting for the still's readback.
        case capturingStill
        /// Warm-up done; requesting one readback per live frame.
        case capturingClip
        /// Warm-up done; logging frames until `perfSeconds` elapse.
        case runningPerf
        /// Writing `frametime.json` / `manifest.json`.
        case finishing
        /// Finished successfully.
        case done
        /// Finished with an error (artifacts still written).
        case failed
    }

    // MARK: Constants

    /// Frames allowed between readback request and finished PNG before the draw thread waits.
    static let inFlightLimit = 8
    /// Seconds without capture progress after which the run is failed.
    static let stallTimeoutSeconds: TimeInterval = 15
    /// Delay between printing `CAPTURE_DONE` and `exit(0)`.
    static let exitDelaySeconds: TimeInterval = 1
    /// Clip frame rate: fixed 1/60 s of ritual time per rendered frame.
    static let clipFrameRate: Double = 60
    /// Seconds to wait for queued PNG writes while finishing.
    static let drainTimeoutSeconds: TimeInterval = 60
    /// Contract file names (ARCHITECTURE §7).
    static let frametimeFileName = "frametime.json"
    static let manifestFileName = "manifest.json"

    // MARK: Immutable configuration

    /// The parsed launch configuration.
    let config: CaptureConfig
    /// The renderer whose frame loop is observed.
    let renderer: Renderer
    /// The owner's daemon (chart report, name, sigil for the manifest).
    let profile: DaemonProfile
    /// `Documents/Captures/<runName>`.
    let directory: URL
    /// Whether `finishRun` terminates the process (true for capture runs).
    let exitsProcessWhenDone: Bool

    // MARK: State (guarded by `lock`)

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var showcaseRequested = false
    private var showcaseTick = 0
    private var capturedTick: Int?
    private var expectedOutputWidth = 0
    private var expectedOutputHeight = 0
    private var frames: [FrameLogEntry] = []
    private var runStart: CFTimeInterval = 0
    private var lastProgress: CFTimeInterval = 0
    private var clipTotal = 0
    private var clipRequested = 0
    private var clipFinished = 0
    private var writtenFiles: [String] = []
    private var errors: [String] = []
    private var resolvedPath: RenderPath = .fallback
    private var renderPathReason = ""
    private var metalFXActive = false
    private var resolution = CaptureManifest.Resolution(outputWidth: 0, outputHeight: 0, renderWidth: 0, renderHeight: 0)

    private let pngQueue = PNGWriteQueue(maxPending: CaptureHarness.inFlightLimit)
    private let slots = DispatchSemaphore(value: CaptureHarness.inFlightLimit)
    private let workQueue = DispatchQueue(label: "BornlessRitual.capture", qos: .userInitiated)
    private let log = Logger(subsystem: "BornlessRitual", category: "Capture")

    // MARK: Init

    /// Creates a harness (call `start()` before the first frame is drawn).
    ///
    /// - Parameters:
    ///   - renderer: The renderer to observe (retained; the renderer holds observers weakly).
    ///   - config: Launch configuration.
    ///   - profile: Daemon profile for the manifest (the owner's by default).
    ///   - exitsProcessWhenDone: Whether to `exit` after writing the artifacts; defaults
    ///     to `config.isCaptureRun`.
    init(renderer: Renderer, config: CaptureConfig, profile: DaemonProfile = DaemonProfile.owner,
         exitsProcessWhenDone: Bool? = nil) {
        self.renderer = renderer
        self.config = config
        self.profile = profile
        self.exitsProcessWhenDone = exitsProcessWhenDone ?? config.isCaptureRun
        self.directory = CaptureHarness.runDirectory(for: config)
    }

    /// Creates a harness and applies the capture settings to the model
    /// (the integration point suggested in App/BornlessRitualApp.swift).
    @MainActor
    convenience init(renderer: Renderer, config: CaptureConfig, settings: SettingsModel,
                     profile: DaemonProfile = DaemonProfile.owner) {
        CaptureHarness.applyCaptureSettings(config, to: settings)
        self.init(renderer: renderer, config: config, profile: profile)
    }

    /// A `RendererHost.captureObserverFactory` for capture runs (`nil` for interactive runs).
    ///
    /// Usage in `BornlessRitualApp.init`:
    /// `host.captureObserverFactory = CaptureHarness.observerFactory(config: config, settings: settings)`.
    /// The settings are applied now (on the main actor); the returned closure only
    /// creates and starts the harness.
    @MainActor
    static func observerFactory(config: CaptureConfig, settings: SettingsModel,
                                profile: DaemonProfile = DaemonProfile.owner) -> ((Renderer) -> RendererFrameObserver?)? {
        guard config.isCaptureRun else { return nil }
        applyCaptureSettings(config, to: settings)
        return { renderer in
            let harness = CaptureHarness(renderer: renderer, config: config, profile: profile)
            harness.start()
            return harness
        }
    }

    /// Applies the launch configuration and the capture-run overrides: narration as
    /// configured (off by default), haptics off, time scale 1, not paused, no debug view.
    @MainActor
    static func applyCaptureSettings(_ config: CaptureConfig, to settings: SettingsModel) {
        settings.applyLaunchConfig(config)
        settings.hapticsEnabled = false
        settings.narrationEnabled = config.narration
        settings.autopilotEnabled = config.autopilot
        settings.timeScale = 1
        settings.paused = false
        settings.debugView = .none
    }

    /// `Documents/Captures/<runName>` (falls back to the temporary directory).
    static func runDirectory(for config: CaptureConfig) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent(config.documentsRelativeDirectory, isDirectory: true)
    }

    // MARK: Public state

    /// Current phase.
    var currentPhase: Phase {
        lock.lock()
        defer { lock.unlock() }
        return phase
    }

    /// Tick the autopilot positioned the ritual at.
    var positionedTick: Int {
        lock.lock()
        defer { lock.unlock() }
        return showcaseTick
    }

    /// Stem shared by the per-capture artifact copies (`still_s7_low_rt`, `clip_…`, `perf_rt`).
    func artifactStem(path: String) -> String {
        switch config.mode {
        case .stills:
            let name = config.stillFileName(path: path)
            return name.hasSuffix(".png") ? String(name.dropLast(4)) : name
        case .clip:
            return config.clipDirectoryName(path: path)
        case .perf:
            return "perf_\(path)"
        case .none:
            return "run"
        }
    }

    // MARK: Start

    /// Applies the autopilot script, positions the camera and issues the seek that
    /// schedules the warm-up. Call on the main thread before the first frame.
    func start() {
        lock.lock()
        guard phase == .idle else {
            lock.unlock()
            return
        }
        guard config.isCaptureRun else {
            phase = .done
            lock.unlock()
            return
        }
        phase = .positioning
        lock.unlock()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            recordError("Could not create \(directory.path): \(error)")
        }
        if config.warmupFrames != Int(WARMUP_FRAMES) {
            log.warning("-warmup \(self.config.warmupFrames) requested; the renderer always uses WARMUP_FRAMES = \(Int(WARMUP_FRAMES))")
        }

        let simulation = renderer.simulation
        simulation.seek(toTick: 0)
        let target: RitualStage = config.mode == .perf ? .manifestation : config.stage
        if config.autopilot {
            for input in Autopilot.inputs(through: target, seed: simulation.seed) {
                simulation.apply(input)
            }
        }
        let tick: Int
        switch config.mode {
        case .stills, .clip:
            tick = config.autopilot ? Autopilot.showcaseTick(for: config.stage, seed: simulation.seed) : 0
        case .perf, .none:
            tick = 0
        }
        lock.lock()
        showcaseTick = tick
        clipTotal = config.mode == .clip ? max(Int((config.clipSeconds * CaptureHarness.clipFrameRate).rounded()), 1) : 0
        lock.unlock()

        log.info("Capture \(self.config.mode.rawValue, privacy: .public): stage \(self.config.stage.rawValue) camera \(self.config.camera.rawValue, privacy: .public) seed \(self.config.seed) → tick \(tick); run dir \(self.directory.path, privacy: .public)")
        beginPositioning()
    }

    /// Positions the camera and seeks to the showcase tick (schedules the warm-up).
    /// Runs again when the drawable size changes during positioning.
    private func beginPositioning() {
        lock.lock()
        guard phase == .positioning else {
            lock.unlock()
            return
        }
        let tick = showcaseTick
        let outputSize = renderer.resources.outputSize
        expectedOutputWidth = outputSize.width
        expectedOutputHeight = outputSize.height
        let needsShowcaseRequest = (config.mode == .stills || config.mode == .clip) && !showcaseRequested
        showcaseRequested = true
        if needsShowcaseRequest, config.mode == .clip {
            clipRequested = 1
        }
        lock.unlock()

        renderer.camera = OrbitCamera.preset(config.camera)
        renderer.fixedFrameDeltaTime = config.mode == .clip ? 1.0 / CaptureHarness.clipFrameRate : nil
        renderer.seek(toTick: tick)

        if needsShowcaseRequest {
            if config.mode == .clip {
                slots.wait()
            }
            renderer.requestReadback { [weak self] image in
                self?.handleShowcaseImage(image, tick: tick)
            }
        }
    }

    // MARK: RendererFrameObserver

    /// Draw thread: watches the drawable size while positioning; requests one readback
    /// per live frame while capturing a clip (waiting on the in-flight bound).
    func renderer(_ renderer: Renderer, willEncodeFrame info: FrameInfo) {
        lock.lock()
        switch phase {
        case .positioning:
            if info.outputWidth != expectedOutputWidth || info.outputHeight != expectedOutputHeight {
                lock.unlock()
                log.warning("Drawable size changed to \(info.outputWidth)×\(info.outputHeight) during positioning; restarting the warm-up")
                DispatchQueue.main.async { [weak self] in
                    self?.beginPositioning()
                }
                return
            }
        case .capturingClip:
            if !info.isWarmup, clipRequested < clipTotal {
                let index = clipRequested
                clipRequested += 1
                lock.unlock()
                requestClipFrame(index: index, tick: info.tick)
                return
            }
        default:
            break
        }
        lock.unlock()
    }

    /// Completion thread: logs every frame after the warm-up; ends perf runs and detects stalls.
    func renderer(_ renderer: Renderer, didCompleteFrame info: FrameInfo, sample: FrameSample) {
        lock.lock()
        let current = phase
        guard current == .capturingStill || current == .capturingClip || current == .runningPerf else {
            lock.unlock()
            return
        }
        frames.append(FrameLogEntry(index: frames.count,
                                    time: info.time,
                                    tick: info.tick,
                                    cpuMs: sample.cpuSeconds * 1000,
                                    gpuMs: sample.gpuSeconds * 1000,
                                    frameMs: sample.frameSeconds * 1000,
                                    thermal: ProcessInfo.processInfo.thermalState.ritualName))
        let now = CACurrentMediaTime()
        let elapsed = now - runStart
        let sinceProgress = now - lastProgress
        lock.unlock()

        switch current {
        case .runningPerf:
            if elapsed >= config.perfSeconds {
                complete()
            }
        case .capturingStill, .capturingClip:
            if sinceProgress > CaptureHarness.stallTimeoutSeconds {
                fail("No capture progress for \(Int(CaptureHarness.stallTimeoutSeconds)) s (readback never delivered)")
            }
        default:
            break
        }
    }

    /// Draw thread: the 16th warm-up frame was encoded — enter the mode's phase.
    func renderer(_ renderer: Renderer, didFinishWarmupAtTick tick: Int) {
        lock.lock()
        guard phase == .positioning else {
            lock.unlock()
            return
        }
        resolvedPath = renderer.renderPath
        renderPathReason = renderer.renderPathReason
        metalFXActive = renderer.metalFXActive
        resolution = CaptureManifest.Resolution(outputWidth: renderer.resources.outputSize.width,
                                                outputHeight: renderer.resources.outputSize.height,
                                                renderWidth: renderer.resources.renderSize.width,
                                                renderHeight: renderer.resources.renderSize.height)
        let now = CACurrentMediaTime()
        runStart = now
        lastProgress = now
        frames.removeAll()
        switch config.mode {
        case .stills: phase = .capturingStill
        case .clip: phase = .capturingClip
        case .perf: phase = .runningPerf
        case .none: phase = .done
        }
        let mode = config.mode
        lock.unlock()
        log.info("Warm-up finished at tick \(tick); \(mode.rawValue, privacy: .public) capture begins")
    }

    // MARK: Readback handling

    /// Draw thread: reserves an in-flight slot (blocking when 8 frames are pending) and
    /// requests this frame's readback.
    private func requestClipFrame(index: Int, tick: Int) {
        let deadline = DispatchTime.now() + CaptureHarness.stallTimeoutSeconds
        if slots.wait(timeout: deadline) == .timedOut {
            fail("PNG pipeline stalled: no frame finished within \(Int(CaptureHarness.stallTimeoutSeconds)) s")
            return
        }
        renderer.requestReadback { [weak self] image in
            self?.writeClipFrame(image, index: index, tick: tick)
        }
    }

    /// Readback queue: the 16th warm-up frame (still, or clip frame 0).
    private func handleShowcaseImage(_ image: CGImage, tick: Int) {
        lock.lock()
        capturedTick = tick
        let current = phase
        let path = resolvedPath.fileSuffix
        lock.unlock()

        switch config.mode {
        case .stills:
            guard current == .capturingStill || current == .positioning else { return }
            let name = config.stillFileName(path: path)
            do {
                try PNGWriter.write(image, to: directory.appendingPathComponent(name))
                lock.lock()
                writtenFiles.append(name)
                lastProgress = CACurrentMediaTime()
                lock.unlock()
                log.info("Wrote \(name, privacy: .public)")
            } catch {
                recordError("Still \(name) failed: \(error)")
            }
            complete()
        case .clip:
            writeClipFrame(image, index: 0, tick: tick)
        case .perf, .none:
            break
        }
    }

    /// Readback queue: enqueue one clip frame (blocks while 8 PNG writes are outstanding).
    private func writeClipFrame(_ image: CGImage, index: Int, tick: Int) {
        lock.lock()
        if index == 0 {
            capturedTick = tick
        }
        let clipDirectory = directory.appendingPathComponent(config.clipDirectoryName(path: resolvedPath.fileSuffix), isDirectory: true)
        lock.unlock()
        let url = clipDirectory.appendingPathComponent(String(format: "frame_%05d.png", index))
        pngQueue.enqueue(image, to: url) { [weak self] error in
            self?.clipFrameDidWrite(index: index, error: error)
        }
    }

    /// Writer queue: releases the in-flight slot; finishes the run after the last frame.
    private func clipFrameDidWrite(index: Int, error: Error?) {
        lock.lock()
        clipFinished += 1
        lastProgress = CACurrentMediaTime()
        if let error = error {
            errors.append("Clip frame \(index) failed: \(error)")
        }
        let finished = clipFinished
        let total = clipTotal
        lock.unlock()
        slots.signal()
        if finished >= total {
            complete()
        }
    }

    // MARK: Completion

    private func recordError(_ message: String) {
        lock.lock()
        errors.append(message)
        lock.unlock()
        log.error("\(message, privacy: .public)")
    }

    /// Marks the run finished and writes the artifacts (idempotent).
    private func complete() {
        lock.lock()
        guard phase != .finishing, phase != .done, phase != .failed else {
            lock.unlock()
            return
        }
        phase = .finishing
        lock.unlock()
        finishRun(failed: false)
    }

    /// Marks the run failed and writes the artifacts (idempotent).
    private func fail(_ message: String) {
        lock.lock()
        guard phase != .finishing, phase != .done, phase != .failed else {
            lock.unlock()
            return
        }
        phase = .failed
        errors.append(message)
        lock.unlock()
        log.error("Capture failed: \(message, privacy: .public)")
        finishRun(failed: true)
    }

    /// Work queue: drain PNGs, write `frametime.json` + `manifest.json`, print, exit.
    private func finishRun(failed: Bool) {
        workQueue.async { [self] in
            let drained = pngQueue.drain(timeout: DispatchTime.now() + CaptureHarness.drainTimeoutSeconds)
            if !drained {
                recordError("PNG writes did not finish within \(Int(CaptureHarness.drainTimeoutSeconds)) s")
            }
            for failure in pngQueue.failedWrites {
                recordError("PNG write failed for \(failure.url.lastPathComponent): \(failure.error)")
            }

            lock.lock()
            let path = resolvedPath.fileSuffix
            let reason = renderPathReason
            let metalFX = metalFXActive
            let frameEntries = frames
            let tick = showcaseTick
            let captured = capturedTick
            var files = writtenFiles
            if config.mode == .clip {
                files.append("\(config.clipDirectoryName(path: path))/frame_%05d.png (\(clipFinished) frames)")
            }
            let sizes = resolution
            lock.unlock()

            let frameLog = FrameLog(config: config, resolvedRenderPath: path,
                                    device: DeviceInfo.modelIdentifier, os: DeviceInfo.osVersionString,
                                    metalFX: metalFX, frames: frameEntries)
            let stem = artifactStem(path: path)
            var writtenNow: [String] = []
            do {
                let data = try frameLog.jsonData()
                writtenNow += write(data, names: [CaptureHarness.frametimeFileName, "\(stem).frametime.json"])
            } catch {
                recordError("frametime.json encoding failed: \(error)")
            }

            lock.lock()
            let collectedErrors = errors
            lock.unlock()
            let manifest = CaptureManifest(
                createdAt: DeviceInfo.timestamp(),
                status: (failed || !collectedErrors.isEmpty) ? "failed" : "ok",
                errors: collectedErrors,
                config: config,
                launchArguments: config.launchArguments,
                resolvedRenderPath: path,
                renderPathReason: reason,
                metalFX: metalFX,
                device: DeviceInfo.modelIdentifier,
                os: DeviceInfo.osVersionString,
                capabilities: renderer.capabilities.report,
                resolution: sizes,
                chartReport: profile.chart.appendixAReport(),
                name: CaptureManifest.Name(hebrew: profile.name.hebrew, latin: profile.name.latin),
                sigilCells: CaptureManifest.sigilCells(for: profile),
                sigilCellsText: CaptureManifest.sigilCellsText(for: profile),
                sigilReducedValues: profile.sigil.reducedValues,
                attributes: CaptureManifest.attributes(for: profile),
                showcaseTick: tick,
                capturedTick: captured,
                files: files + writtenNow,
                frameSummary: frameLog.summary())
            do {
                let data = try manifest.jsonData()
                _ = write(data, names: [CaptureHarness.manifestFileName, "\(stem).manifest.json"])
            } catch {
                recordError("manifest.json encoding failed: \(error)")
            }

            lock.lock()
            let succeeded = !failed && errors.isEmpty
            phase = succeeded ? .done : .failed
            let summary = errors.joined(separator: "; ")
            lock.unlock()

            let line = succeeded
                ? "CAPTURE_DONE \(directory.path)"
                : "CAPTURE_FAILED \(directory.path) — \(summary)"
            print(line)
            fflush(stdout)
            log.info("\(line, privacy: .public)")

            if exitsProcessWhenDone {
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + CaptureHarness.exitDelaySeconds) {
                    exit(succeeded ? 0 : 1)
                }
            }
        }
    }

    /// Writes `data` under every name in `names`; returns the names written.
    private func write(_ data: Data, names: [String]) -> [String] {
        var written: [String] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            do {
                try data.write(to: url, options: [.atomic])
                written.append(name)
            } catch {
                recordError("Could not write \(name): \(error)")
            }
        }
        return written
    }
}
