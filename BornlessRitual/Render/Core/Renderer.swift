//
//  Renderer.swift
//  Bornless Ritual — the MTKViewDelegate frame loop (RENDER_CONTRACT §1 `Renderer`, §7
//  threading & timing; ARCHITECTURE §5 time/ticks, §6 determinism & warm-up, §7 capture
//  readback, §8 debug-panel stats).
//
//  Role: per frame — snapshot settings, advance ritual time and the 120 Hz simulation,
//  run the SceneUpdater hook, upload `FrameUniforms`, encode the frame graph, blit
//  Output → drawable, service readback requests, present, and collect CPU/GPU timing.
//  Also: warm-up scheduling after seek / stage jump / render-path change, render-path
//  and render-scale reconciliation (rebuilding passes and resizing textures), and the
//  contract's `seek(toTick:)`, `jump(to:)`, `setRenderPath`, `requestReadback`, `stats`.
//
//  Threading: `draw(in:)` runs on the MTKView draw thread (the main thread with the
//  default display-link driver). Every mutable member is touched only from that thread
//  except `stats` (lock) and the GPU completion handler (which only records timing,
//  copies the readback buffer and signals the in-flight semaphore). The renderer never
//  touches `SettingsModel`; it reads `RenderSettingsStore` (lock) once per frame.
//
//  Colour output: `TextureIndexOutput` is bgra8Unorm with the sRGB transfer applied in
//  the tonemap kernel (see RenderResources.swift); the MTKView is configured with
//  `colorPixelFormat = .bgra8Unorm` and `framebufferOnly = false` so Output can be
//  blitted into the drawable.
//

import Foundation
import Metal
import MetalKit
import QuartzCore
import CoreGraphics
import RitualCore
import os

// MARK: - Hooks

/// Scene update hook run at the start of every frame (RENDER_CONTRACT §2 row 0).
protocol SceneUpdating: AnyObject {
    /// Writes instances, lights, flames, ring history, params and the SDF scene for
    /// `tick`, and (RT path) refits / rebuilds acceleration structures on `commandBuffer`.
    func update(tick: Int, state: RitualState, camera: OrbitCamera, settings: RenderSettings,
                resources: SceneResources, commandBuffer: MTLCommandBuffer)

    /// Called after `seek` / `jump` so the updater can rebuild tick-indexed history
    /// (the ring-history ring buffer is zeroed by the Renderer before this call).
    func didSeek(toTick tick: Int, simulation: RitualSimulation, resources: SceneResources)
}

extension SceneUpdating {
    func didSeek(toTick tick: Int, simulation: RitualSimulation, resources: SceneResources) {}
}

/// Per-frame bookkeeping handed to observers (the capture harness).
struct FrameInfo: Sendable, Equatable {
    /// Monotonic frame counter (every `draw`, including warm-up frames).
    let serial: UInt64
    /// ARCHITECTURE §6 frame index.
    let frameIndex: UInt32
    /// Simulation tick rendered.
    let tick: Int
    /// True during warm-up.
    let isWarmup: Bool
    /// Remaining warm-up frames after this one (0 = this is the displayed/captured frame).
    let warmupRemaining: Int
    /// Active render path.
    let renderPath: RenderPath
    /// Internal render size.
    let renderWidth: Int
    let renderHeight: Int
    /// Native output size.
    let outputWidth: Int
    let outputHeight: Int
    /// Ritual seconds (`tick / 120`).
    let time: Double
}

/// Observer of the frame loop. The capture harness (`Capture/CaptureHarness.swift`)
/// adopts this to drive stills / clips / perf logs.
protocol RendererFrameObserver: AnyObject {
    /// Called on the draw thread before the frame is encoded.
    func renderer(_ renderer: Renderer, willEncodeFrame info: FrameInfo)
    /// Called from the GPU completion handler (arbitrary thread) with the frame's timing.
    func renderer(_ renderer: Renderer, didCompleteFrame info: FrameInfo, sample: FrameSample)
    /// Called on the draw thread after the 16th warm-up frame was encoded.
    func renderer(_ renderer: Renderer, didFinishWarmupAtTick tick: Int)
}

extension RendererFrameObserver {
    func renderer(_ renderer: Renderer, willEncodeFrame info: FrameInfo) {}
    func renderer(_ renderer: Renderer, didCompleteFrame info: FrameInfo, sample: FrameSample) {}
    func renderer(_ renderer: Renderer, didFinishWarmupAtTick tick: Int) {}
}

/// Errors raised while constructing the renderer.
enum RendererError: Error, CustomStringConvertible {
    /// Neither the view nor the system provided a Metal device.
    case noDevice
    /// `device.makeDefaultLibrary()` returned nil (no .metal sources in the target).
    case noDefaultLibrary
    /// `device.makeCommandQueue()` returned nil.
    case noCommandQueue
    /// A buffer allocation failed.
    case bufferCreationFailed(String)

    var description: String {
        switch self {
        case .noDevice: return "No Metal device is available"
        case .noDefaultLibrary: return "The default Metal library could not be loaded"
        case .noCommandQueue: return "The Metal command queue could not be created"
        case .bufferCreationFailed(let label): return "Could not create buffer '\(label)'"
        }
    }
}

// MARK: - Renderer

/// The frame loop.
final class Renderer: NSObject, MTKViewDelegate {

    // MARK: Public state

    /// The Metal device.
    let device: MTLDevice
    /// Command queue (one command buffer per frame).
    let commandQueue: MTLCommandQueue
    /// Default library with every `.metal` file.
    let library: MTLLibrary
    /// Device capability report.
    let capabilities: CapabilityProbe
    /// Pipeline cache shared by all passes.
    let pipelines: PipelineCache
    /// Textures.
    let resources: RenderResources
    /// Scene buffers.
    let scene: SceneResources
    /// The simulation (owned by the render thread; ARCHITECTURE §5).
    let simulation: RitualSimulation
    /// Settings snapshots.
    let settingsStore: RenderSettingsStore

    /// Scene update hook (Render/Scene/SceneUpdater.swift); set after construction.
    var sceneUpdater: SceneUpdating?
    /// Frame observer (capture harness).
    weak var frameObserver: RendererFrameObserver?

    /// Resolved render path the current pipelines were built for.
    private(set) var renderPath: RenderPath
    /// Why `renderPath` was chosen (debug panel).
    private(set) var renderPathReason: String
    /// Whether the MetalFX temporal scaler is active (else the TAA fallback).
    private(set) var metalFXActive: Bool
    /// The interactive camera (frozen copy used during warm-up).
    var camera: OrbitCamera
    /// Settings snapshot of the most recent frame.
    private(set) var settings: RenderSettings
    /// ARCHITECTURE §6 frame index of the most recent frame.
    private(set) var frameIndex: UInt32 = 0
    /// When set, ritual time advances by this fixed amount per frame instead of wall time
    /// (deterministic clip capture, e.g. 1/60).
    var fixedFrameDeltaTime: Double?
    /// Maximum simulation ticks advanced in one frame (0.4 s; bounds the spiral of death).
    var maxTicksPerFrame = 48

    /// Current simulation tick.
    var currentTick: Int { simulation.tick }
    /// Ritual seconds of the current tick.
    var currentTime: Double { Double(simulation.tick) / Double(RitualSimulation.tickRate) }
    /// True while warm-up frames are pending.
    var isWarmingUp: Bool { warmupRemaining > 0 }

    /// Frame statistics (fps, cpuMs, gpuMs, p1Low, thermal), refreshed at 4 Hz.
    var stats: FrameStats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return publishedStats
    }

    // MARK: Private state

    private weak var view: MTKView?
    private var passes: [RenderPass] = []
    private var builtVariant: PipelineVariant?
    private var passesNeedRebuild = true

    private let inflightSemaphore = DispatchSemaphore(value: SceneResources.inflightSlots)
    private let uniformBuffer: MTLBuffer
    private let uniformStride: Int
    private var uniformSlot = 0
    private var previousUniforms: FrameUniforms?

    private var ritualTime: Double = 0
    private var lastFrameTimestamp: CFTimeInterval?
    private var lastWallDeltaTime: Double = 0
    private var lastYawFed: Float?

    private var warmupRemaining = 0
    private var warmupBaseTick = 0
    private var frozenCamera: OrbitCamera?

    private let timing = FrameTimingWindow()
    private let statsLock = NSLock()
    private var publishedStats = FrameStats()
    private var lastStatsPublish: CFTimeInterval = 0
    private var frameSerial: UInt64 = 0

    private var readbackRequests: [(CGImage) -> Void] = []
    private var readbackBuffers: [MTLBuffer?] = Array(repeating: nil, count: SceneResources.inflightSlots)
    private var readbackBytesPerRow = 0
    private let readbackQueue = DispatchQueue(label: "BornlessRitual.readback", qos: .userInitiated)

    private var nativeSize: MTLSize
    private var appliedRenderScale: Float
    private var loggedDrawableMismatch = false
    private let log = Logger(subsystem: "BornlessRitual", category: "Renderer")

    // MARK: Init

    /// Creates the renderer, configures `view`, allocates resources and resolves the
    /// render path from the settings' `renderPathChoice`.
    ///
    /// - Parameters:
    ///   - view: The MTKView to drive (delegate is set here).
    ///   - settings: The settings model; only its `renderSettingsStore` is retained.
    ///   - simulation: The ritual simulation (render-thread owned).
    ///   - capture: Optional frame observer (the capture harness adopts `RendererFrameObserver`).
    /// - Throws: `RendererError` / `RenderResourceError` when Metal objects cannot be created.
    @MainActor
    init(view: MTKView, settings: SettingsModel, simulation: RitualSimulation, capture: RendererFrameObserver?) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            throw RendererError.noDevice
        }
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        guard let library = device.makeDefaultLibrary() else { throw RendererError.noDefaultLibrary }

        let probe = CapabilityProbe(device: device)
        let store = settings.renderSettingsStore
        let initialSettings = store.snapshot()

        let drawableSize = view.drawableSize
        let native = RenderResources.clampedSize(MTLSize(width: Int(drawableSize.width.rounded()),
                                                         height: Int(drawableSize.height.rounded()), depth: 1))
        let renderSize = Renderer.renderSize(native: native, scale: initialSettings.renderScale)
        let resources = try RenderResources(device: device, renderSize: renderSize, outputSize: native)
        let scene = try SceneResources(device: device)

        let stride = (MemoryLayout<FrameUniforms>.stride + 255) / 256 * 256
        guard let uniforms = device.makeBuffer(length: stride * SceneResources.inflightSlots, options: .storageModeShared) else {
            throw RendererError.bufferCreationFailed("FrameUniforms ring")
        }
        uniforms.label = "FrameUniforms ring"

        self.device = device
        self.commandQueue = queue
        self.library = library
        self.capabilities = probe
        self.pipelines = PipelineCache(device: device, library: library)
        self.simulation = simulation
        self.settingsStore = store
        self.settings = initialSettings
        self.renderPath = probe.resolve(initialSettings.renderPathChoice)
        self.renderPathReason = probe.reason(for: initialSettings.renderPathChoice)
        self.metalFXActive = probe.metalFXAvailable(requested: initialSettings.metalFXEnabled)
        self.appliedRenderScale = initialSettings.renderScale
        self.nativeSize = native
        self.resources = resources
        self.scene = scene
        self.uniformStride = stride
        self.uniformBuffer = uniforms
        self.camera = OrbitCamera.preset(.threequarter)
        super.init()

        self.frameObserver = capture
        self.view = view

        view.device = device
        view.colorPixelFormat = RenderResources.outputPixelFormat
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self

        commandQueue.label = "BornlessRitual.frames"
        log.info("Renderer ready: \(self.capabilities.report, privacy: .public)")
        log.info("Render path: \(self.renderPathReason, privacy: .public)")
    }

    // MARK: - Contract API

    /// Switches the render path (rebuilds passes on the next frame, resets history and
    /// schedules a warm-up). Safe to call from the main thread between frames.
    func setRenderPath(_ choice: RenderPathChoice) {
        let resolved = capabilities.resolve(choice)
        renderPathReason = capabilities.reason(for: choice)
        if resolved != renderPath || builtVariant == nil {
            renderPath = resolved
            passesNeedRebuild = true
            resources.resetHistory()
            scheduleWarmup()
            log.info("Render path → \(self.renderPathReason, privacy: .public)")
        }
    }

    /// Seeks the simulation (keyframe restore + input replay, or forward simulation),
    /// resets temporal history and schedules 16 warm-up frames.
    func seek(toTick tick: Int) {
        simulation.seek(toTick: max(tick, 0))
        didRelocateSimulation()
    }

    /// Jumps to `stage` deterministically via the simulation's autopilot, then warms up.
    func jump(to stage: RitualStage) {
        simulation.jump(to: stage)
        didRelocateSimulation()
    }

    /// Requests a native-resolution readback of the next presented frame (or the 16th
    /// warm-up frame when a warm-up is pending). The completion runs on a background queue.
    func requestReadback(_ completion: @escaping (CGImage) -> Void) {
        readbackRequests.append(completion)
    }

    /// Resets history and schedules 16 warm-up frames (ARCHITECTURE §6) without moving the simulation.
    func scheduleWarmup() {
        warmupRemaining = Int(WARMUP_FRAMES)
        warmupBaseTick = simulation.tick
        frozenCamera = camera
        previousUniforms = nil
        resources.resetHistory()
        timing.reset()
    }

    /// Positions the camera on a preset (also refreezes it if a warm-up is pending).
    func applyCameraPreset(_ preset: CameraPreset) {
        camera = OrbitCamera.preset(preset)
        if warmupRemaining > 0 {
            frozenCamera = camera
        }
    }

    // MARK: - MTKViewDelegate

    /// Native drawable size changed: resize textures, rebuild passes, reset history.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let native = RenderResources.clampedSize(MTLSize(width: Int(size.width.rounded()), height: Int(size.height.rounded()), depth: 1))
        nativeSize = native
        applySizes(renderScale: settings.renderScale)
    }

    /// One frame (RENDER_CONTRACT §7 / ARCHITECTURE §5–§6).
    func draw(in view: MTKView) {
        let frameStart = CACurrentMediaTime()
        let settings = settingsStore.snapshot()
        self.settings = settings
        timing.pollThermal(now: frameStart)

        reconcileConfiguration(settings)
        advanceSimulation(settings: settings, now: frameStart)

        _ = inflightSemaphore.wait(timeout: .distantFuture)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inflightSemaphore.signal()
            return
        }
        commandBuffer.label = "Frame \(frameSerial)"

        // Frame bookkeeping (ARCHITECTURE §6).
        let isWarmup = warmupRemaining > 0
        let frameCamera: OrbitCamera
        if isWarmup {
            let k = Int(WARMUP_FRAMES) - warmupRemaining
            frameIndex = UInt32(truncatingIfNeeded: warmupBaseTick * Int(WARMUP_FRAMES) + k)
            frameCamera = frozenCamera ?? camera
        } else {
            frameIndex &+= 1
            frameCamera = camera
        }
        let info = FrameInfo(serial: frameSerial, frameIndex: frameIndex, tick: simulation.tick,
                             isWarmup: isWarmup, warmupRemaining: max(warmupRemaining - 1, 0),
                             renderPath: renderPath,
                             renderWidth: resources.renderSize.width, renderHeight: resources.renderSize.height,
                             outputWidth: resources.outputSize.width, outputHeight: resources.outputSize.height,
                             time: currentTime)
        frameObserver?.renderer(self, willEncodeFrame: info)

        // History clear after a reset (deterministic warm-up start).
        resources.encodeHistoryClearIfNeeded(commandBuffer)
        let historyValid = resources.historyValid

        // Scene update (row 0).
        scene.advanceSlot()
        sceneUpdater?.update(tick: simulation.tick, state: simulation.state, camera: frameCamera,
                             settings: settings, resources: scene, commandBuffer: commandBuffer)

        // Uniforms.
        let uniforms = UniformBuilder.build(UniformBuilder.Inputs(
            camera: frameCamera, settings: settings, state: simulation.state, tick: simulation.tick,
            frameIndex: frameIndex, seed: settings.seed,
            renderSize: resources.renderSize, outputSize: resources.outputSize,
            renderPath: renderPath, historyValid: historyValid, isWarmup: isWarmup,
            deltaTime: Float(lastWallDeltaTime), lightCount: scene.lightCount,
            previous: historyValid ? previousUniforms : nil))
        uniformSlot = (uniformSlot + 1) % SceneResources.inflightSlots
        let uniformOffset = uniformSlot * uniformStride
        withUnsafeBytes(of: uniforms) { raw in
            if let source = raw.baseAddress {
                uniformBuffer.contents().advanced(by: uniformOffset).copyMemory(from: source, byteCount: MemoryLayout<FrameUniforms>.size)
            }
        }
        previousUniforms = uniforms

        // Passes.
        let context = FrameContext(commandBuffer: commandBuffer, uniforms: uniforms,
                                   uniformBuffer: uniformBuffer, uniformOffset: uniformOffset,
                                   resources: resources, scene: scene, renderPath: renderPath,
                                   frameIndex: frameIndex, isWarmup: isWarmup, historyValid: historyValid,
                                   settings: settings)
        for pass in passes {
            pass.encode(context)
        }

        // Output → drawable, readback.
        let drawable = view.currentDrawable
        encodeFinalBlits(commandBuffer: commandBuffer, drawable: drawable)
        let servicesReadback = !readbackRequests.isEmpty && warmupRemaining <= 1
        var readbackBuffer: MTLBuffer?
        var completions: [(CGImage) -> Void] = []
        if servicesReadback, let buffer = encodeReadback(commandBuffer: commandBuffer) {
            readbackBuffer = buffer
            completions = readbackRequests
            readbackRequests.removeAll()
        }

        // Completion: timing, readback copy, semaphore.
        let cpuSeconds = CACurrentMediaTime() - frameStart
        let frameSeconds = lastWallDeltaTime
        let outputWidth = resources.outputSize.width
        let outputHeight = resources.outputSize.height
        let bytesPerRow = readbackBytesPerRow
        commandBuffer.addCompletedHandler { [weak self] completed in
            guard let self = self else { return }
            let gpuSeconds = max(completed.gpuEndTime - completed.gpuStartTime, 0)
            let sample = FrameSample(frameSeconds: frameSeconds, cpuSeconds: cpuSeconds, gpuSeconds: gpuSeconds)
            self.timing.record(sample)
            var imageBytes: Data?
            if let buffer = readbackBuffer {
                // Copied before the semaphore is signalled so the slot's buffer is never reused early.
                imageBytes = Data(bytes: buffer.contents(), count: min(bytesPerRow * outputHeight, buffer.length))
            }
            self.inflightSemaphore.signal()
            self.frameObserver?.renderer(self, didCompleteFrame: info, sample: sample)
            if let bytes = imageBytes, !completions.isEmpty {
                self.readbackQueue.async {
                    if let image = Renderer.makeImage(bytes: bytes, width: outputWidth, height: outputHeight, bytesPerRow: bytesPerRow) {
                        for completion in completions {
                            completion(image)
                        }
                    }
                }
            }
        }
        if let drawable = drawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()

        // Post-frame bookkeeping.
        resources.swapHistory()
        if isWarmup {
            warmupRemaining -= 1
            if warmupRemaining == 0 {
                frozenCamera = nil
                frameObserver?.renderer(self, didFinishWarmupAtTick: simulation.tick)
            }
        }
        publishStatsIfDue(now: frameStart)
        frameSerial &+= 1
    }

    // MARK: - Private: configuration

    /// Applies render-scale, render-path, MetalFX and debug-view changes.
    private func reconcileConfiguration(_ settings: RenderSettings) {
        if settings.renderScale != appliedRenderScale {
            applySizes(renderScale: settings.renderScale)
        }
        let resolvedPath = capabilities.resolve(settings.renderPathChoice)
        if resolvedPath != renderPath {
            setRenderPath(settings.renderPathChoice)
        }
        let metalFX = capabilities.metalFXAvailable(requested: settings.metalFXEnabled)
        let variant = PipelineVariant(renderPath: renderPath, metalFX: metalFX, debugView: settings.debugView)
        if passesNeedRebuild || builtVariant != variant {
            metalFXActive = metalFX
            rebuildPasses(variant: variant)
        }
    }

    /// Recomputes the internal size from the native size and `renderScale`, resizes the
    /// textures and schedules a pass rebuild (RENDER_CONTRACT §1: build again on resize).
    private func applySizes(renderScale: Float) {
        appliedRenderScale = renderScale
        let renderSize = Renderer.renderSize(native: nativeSize, scale: renderScale)
        let changed = !RenderResources.sizesEqual(renderSize, resources.renderSize) || !RenderResources.sizesEqual(nativeSize, resources.outputSize)
        guard changed else { return }
        resources.resize(renderSize: renderSize, outputSize: nativeSize)
        readbackBuffers = Array(repeating: nil, count: SceneResources.inflightSlots)
        readbackBytesPerRow = 0
        passesNeedRebuild = true
        resources.resetHistory()
        previousUniforms = nil
        loggedDrawableMismatch = false
    }

    /// Rebuilds every pass for `variant`; passes that fail to build are dropped and logged.
    private func rebuildPasses(variant: PipelineVariant) {
        pipelines.variant = variant
        var built: [RenderPass] = []
        for pass in assemblePasses() {
            do {
                try pass.build(device: device, library: library, resources: resources, renderPath: renderPath)
                built.append(pass)
            } catch {
                log.error("Pass '\(pass.name, privacy: .public)' failed to build: \(String(describing: error), privacy: .public)")
            }
        }
        passes = built
        builtVariant = variant
        passesNeedRebuild = false
    }

    /// `round(native × scale)`, at least 1×1.
    private static func renderSize(native: MTLSize, scale: Float) -> MTLSize {
        let s = Double(ScalarMath.clamp(scale, 0.25, 1))
        return MTLSize(width: max(Int((Double(native.width) * s).rounded()), 1),
                       height: max(Int((Double(native.height) * s).rounded()), 1),
                       depth: 1)
    }

    // MARK: - Private: time and simulation (ARCHITECTURE §5)

    /// Advances ritual time by `wallDt × timeScale` (or the fixed delta) and steps the
    /// simulation to `floor(T·120)`. Frozen during warm-up.
    private func advanceSimulation(settings: RenderSettings, now: CFTimeInterval) {
        let wallDelta: Double
        if let fixed = fixedFrameDeltaTime {
            wallDelta = fixed
        } else if let last = lastFrameTimestamp {
            wallDelta = min(max(now - last, 0), 0.1)
        } else {
            wallDelta = 0
        }
        lastFrameTimestamp = now
        lastWallDeltaTime = wallDelta   // stats use the true wall delta; uniforms zero it during warm-up
        guard warmupRemaining == 0 else { return }

        let config = settings.simConfig
        if simulation.config != config {
            simulation.config = config
        }
        if !settings.autopilotEnabled {
            feedCameraYaw()
        }
        if !settings.paused {
            ritualTime += wallDelta * Double(settings.timeScale)
        }
        let targetTick = Int((ritualTime * Double(RitualSimulation.tickRate)).rounded(.down))
        let ticks = targetTick - simulation.tick
        if ticks > 0 {
            simulation.step(ticks: min(ticks, maxTicksPerFrame))
            if ticks > maxTicksPerFrame {
                // Drop the backlog so time does not run away after a stall.
                ritualTime = Double(simulation.tick) / Double(RitualSimulation.tickRate)
            }
        }
    }

    /// Feeds the camera's forward yaw to the simulation's facing gate when it changes.
    private func feedCameraYaw() {
        let yaw = camera.forwardYawDegrees
        if let last = lastYawFed, abs(Float.wrapDegrees180(yaw - last)) < 0.05 {
            return
        }
        simulation.apply(RitualInput(tick: simulation.tick, kind: .cameraYaw(Double(yaw))))
        lastYawFed = yaw
    }

    /// Common tail of `seek` / `jump`: resync time, clear tick-indexed history, warm up.
    private func didRelocateSimulation() {
        ritualTime = Double(simulation.tick) / Double(RitualSimulation.tickRate)
        lastYawFed = nil
        scene.clearRingHistory()
        sceneUpdater?.didSeek(toTick: simulation.tick, simulation: simulation, resources: scene)
        scheduleWarmup()
    }

    // MARK: - Private: output and readback

    /// Blits `TextureIndexOutput` into the drawable (sizes and formats must match).
    private func encodeFinalBlits(commandBuffer: MTLCommandBuffer, drawable: CAMetalDrawable?) {
        guard let drawable = drawable else { return }
        let output = resources.texture(.output)
        let target = drawable.texture
        guard target.width == output.width, target.height == output.height, target.pixelFormat == output.pixelFormat else {
            if !loggedDrawableMismatch {
                log.warning("Drawable \(target.width)×\(target.height) \(String(describing: target.pixelFormat), privacy: .public) does not match Output \(output.width)×\(output.height); skipping present blit until resize")
                loggedDrawableMismatch = true
            }
            return
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "Output → drawable"
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: output.width, height: output.height, depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    /// Copies Output into this slot's shared readback buffer; returns that buffer.
    /// One buffer per in-flight slot: a slot is not reused until its completion handler
    /// (which copies the bytes out) has signalled the semaphore.
    private func encodeReadback(commandBuffer: MTLCommandBuffer) -> MTLBuffer? {
        let output = resources.texture(.output)
        let bytesPerRow = (output.width * 4 + 255) / 256 * 256
        let length = bytesPerRow * output.height
        let slot = uniformSlot
        if readbackBuffers[slot] == nil || readbackBuffers[slot]?.length != length || readbackBytesPerRow != bytesPerRow {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                log.error("Could not allocate the readback buffer (\(length) bytes)")
                return nil
            }
            buffer.label = "Readback \(slot)"
            readbackBuffers[slot] = buffer
            readbackBytesPerRow = bytesPerRow
        }
        guard let buffer = readbackBuffers[slot], let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.label = "Output → readback"
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: output.width, height: output.height, depth: 1),
                  to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: length)
        blit.endEncoding()
        return buffer
    }

    /// Wraps bgra8 (sRGB-encoded) bytes as a CGImage: 32-bit little-endian pixels with the
    /// alpha byte skipped (`noneSkipFirst | byteOrder32Little` reads B, G, R, X in memory order).
    static func makeImage(bytes: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0, bytes.count >= bytesPerRow * height else { return nil }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Private: stats

    /// Refreshes `stats` at 4 Hz.
    private func publishStatsIfDue(now: CFTimeInterval) {
        guard now - lastStatsPublish >= 0.25 else { return }
        lastStatsPublish = now
        let snapshot = timing.snapshot()
        statsLock.lock()
        publishedStats = snapshot
        statsLock.unlock()
    }
}
