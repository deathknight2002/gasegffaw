//
//  SettingsModel.swift
//  Bornless Ritual — debug-panel settings (ARCHITECTURE §8 sliders/toggles, §7 launch
//  configuration; RENDER_CONTRACT §1 `SettingsModel: ObservableObject` with
//  `applyLaunchConfig(CaptureConfig)`).
//
//  Role: the SwiftUI-observable source of truth for every slider and toggle, plus the
//  lock-protected `RenderSettings` snapshot the renderer copies once per frame
//  (`RenderSettingsStore`). The model is `@MainActor`; the store is `nonisolated` and
//  `Sendable` so the renderer (which runs on the MTKView draw thread — the main thread
//  by default, but it must not depend on that) never touches the actor.
//

import Foundation
import Combine
import RitualCore

// MARK: - Enumerations

/// Debug visualisation selector (function constant 2, `kDebugView` in Common.h).
enum DebugView: UInt32, CaseIterable, Sendable, Identifiable {
    case none = 0
    case albedo
    case normal
    case roughness
    case depth
    case motion
    case emissive
    case directDiffuse
    case directSpecular
    case reflection
    case denoisedDiffuse
    case sss
    case froxelScatter
    case froxelTransmittance
    case heat
    case variance
    case historyLength

    var id: UInt32 { rawValue }

    /// Value written to the function constant.
    var shaderValue: UInt32 { rawValue }

    /// Picker label.
    var displayName: String {
        switch self {
        case .none: return "Off"
        case .albedo: return "Albedo"
        case .normal: return "Normals"
        case .roughness: return "Roughness"
        case .depth: return "Depth"
        case .motion: return "Motion vectors"
        case .emissive: return "Emissive"
        case .directDiffuse: return "Direct diffuse (noisy)"
        case .directSpecular: return "Direct specular (noisy)"
        case .reflection: return "Reflection"
        case .denoisedDiffuse: return "Denoised diffuse"
        case .sss: return "Subsurface"
        case .froxelScatter: return "Froxel in-scatter"
        case .froxelTransmittance: return "Froxel transmittance"
        case .heat: return "Heat"
        case .variance: return "Variance"
        case .historyLength: return "History length"
        }
    }
}

/// Which ritual text edition the HUD shows (keys of Resources/RitualText.json).
enum RitualTextEdition: String, CaseIterable, Sendable, Identifiable {
    /// Goodwin 1852 translation.
    case goodwin1852
    /// Liber Samekh (Crowley, 1929–30).
    case samekh1930

    var id: String { rawValue }

    /// Picker label.
    var displayName: String {
        switch self {
        case .goodwin1852: return "Goodwin (1852)"
        case .samekh1930: return "Liber Samekh (1930)"
        }
    }
}

// MARK: - RenderSettings snapshot

/// Immutable copy of the settings the renderer reads once per frame.
struct RenderSettings: Sendable, Equatable {
    // Sliders (ARCHITECTURE §8)
    /// Flame intensity multiplier, 0…3 (default 1).
    var flameIntensity: Float = 1
    /// Smoke density multiplier, 0…3 (default 1).
    var smokeDensity: Float = 1
    /// Ember count multiplier, 0…3 (default 1) → `FrameUniforms.emberScale`.
    var emberCount: Float = 1
    /// Sigil friction multiplier, 0…3 (default 1) → `SimConfig.frictionScale`.
    var sigilFriction: Float = 1
    /// Gravity multiplier, 0…3 (default 1) → `SimConfig.gravityScale`.
    var gravity: Float = 1
    /// Candle warmth 0…1 (default 0.5) → 1500…2400 K.
    var candleWarmth: Float = 0.5
    /// Ambient light 0…1 (default 0.15).
    var ambientLight: Float = 0.15
    /// Exposure in EV, −4…+4 (default 0).
    var exposureEV: Float = 0
    /// Ritual time scale, 0…4 (default 1).
    var timeScale: Float = 1
    /// Heat shimmer strength 0…1 (default 0.6) → `FrameUniforms.heatShimmer`.
    var heatShimmer: Float = 0.6
    /// Froxel far distance in metres, 6…12 (default 12; ARCHITECTURE §9 "froxel depth").
    var froxelFarZ: Float = 12
    /// Bloom intensity 0…0.3 (default 0.06).
    var bloomIntensity: Float = 0.06

    // Toggles
    var narrationEnabled: Bool = false
    var hapticsEnabled: Bool = true
    var autopilotEnabled: Bool = false
    var paused: Bool = false

    // Render configuration
    /// auto / rt / fallback.
    var renderPathChoice: RenderPathChoice = .auto
    /// Internal render scale, 0.5…1.0 (default 0.67).
    var renderScale: Float = 0.67
    /// MetalFX temporal upscaling requested.
    var metalFXEnabled: Bool = true
    /// Debug visualisation.
    var debugView: DebugView = .none
    /// Ritual text edition.
    var edition: RitualTextEdition = .samekh1930
    /// Simulation / render seed (from the launch config; default 1).
    var seed: UInt64 = 1

    /// Candle colour temperature in kelvin: 1500 + 900 · candleWarmth.
    var candleWarmthKelvin: Float { 1500 + 900 * candleWarmth }

    /// The simulation configuration implied by the sliders.
    var simConfig: SimConfig {
        var config = SimConfig()
        config.frictionScale = Double(sigilFriction)
        config.gravityScale = Double(gravity)
        config.emberScale = Double(emberCount)
        config.autopilot = autopilotEnabled
        return config
    }

    /// The subset whose change requires rebuilding pipelines (function constants).
    var pipelineVariantKey: (RenderPathChoice, Bool, DebugView) {
        (renderPathChoice, metalFXEnabled, debugView)
    }
}

/// Lock-protected holder of the latest `RenderSettings` (written by the model on the
/// main actor, read by the renderer on the draw thread).
final class RenderSettingsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = RenderSettings()

    /// Creates a store holding the defaults.
    init() {}

    /// Replaces the stored snapshot.
    func update(_ settings: RenderSettings) {
        lock.lock()
        value = settings
        lock.unlock()
    }

    /// Copies the stored snapshot.
    func snapshot() -> RenderSettings {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Slider metadata

/// Range/default metadata for one slider, for the debug panel.
struct SliderSpec: Identifiable, Sendable {
    /// Stable identifier (also the label key).
    let id: String
    /// Label shown next to the slider.
    let title: String
    /// Allowed range.
    let range: ClosedRange<Double>
    /// Default value.
    let defaultValue: Double
    /// Slider step.
    let step: Double
    /// Unit suffix for the value readout.
    let unit: String
}

// MARK: - SettingsModel

/// Observable settings for the debug panel and the launch configuration.
@MainActor
final class SettingsModel: ObservableObject {

    // MARK: Sliders

    @Published var flameIntensity: Double = 1 { didSet { publish() } }
    @Published var smokeDensity: Double = 1 { didSet { publish() } }
    @Published var emberCount: Double = 1 { didSet { publish() } }
    @Published var sigilFriction: Double = 1 { didSet { publish() } }
    @Published var gravity: Double = 1 { didSet { publish() } }
    @Published var candleWarmth: Double = 0.5 { didSet { publish() } }
    @Published var ambientLight: Double = 0.15 { didSet { publish() } }
    @Published var exposureEV: Double = 0 { didSet { publish() } }
    @Published var timeScale: Double = 1 { didSet { publish() } }
    @Published var heatShimmer: Double = 0.6 { didSet { publish() } }
    @Published var froxelFarZ: Double = 12 { didSet { publish() } }
    @Published var bloomIntensity: Double = 0.06 { didSet { publish() } }

    // MARK: Toggles

    @Published var narrationEnabled: Bool = false { didSet { publish() } }
    @Published var hapticsEnabled: Bool = true { didSet { publish() } }
    @Published var autopilotEnabled: Bool = false { didSet { publish() } }
    @Published var paused: Bool = false { didSet { publish() } }

    // MARK: Render configuration

    @Published var renderPathChoice: RenderPathChoice = .auto { didSet { publish() } }
    @Published var renderScale: Double = 0.67 { didSet { publish() } }
    @Published var metalFXEnabled: Bool = true { didSet { publish() } }
    @Published var debugView: DebugView = .none { didSet { publish() } }
    @Published var edition: RitualTextEdition = .samekh1930 { didSet { publish() } }
    @Published var showDebugPanel: Bool = false

    // MARK: Launch configuration (not sliders)

    /// Simulation / render seed.
    @Published private(set) var seed: UInt64 = 1 { didSet { publish() } }
    /// Camera preset requested at launch (nil = default three-quarter view).
    @Published private(set) var launchCamera: CameraPreset = .threequarter
    /// Stage requested at launch.
    @Published private(set) var launchStage: RitualStage = .oath
    /// The capture configuration this run was launched with, if any.
    @Published private(set) var captureConfig: CaptureConfig?

    /// Thread-safe snapshot the renderer copies once per frame.
    nonisolated let renderSettingsStore = RenderSettingsStore()

    /// Creates the model with ARCHITECTURE §8 defaults and seeds the store.
    init() {
        publish()
    }

    // MARK: Snapshot

    /// The current settings as a value.
    var renderSettings: RenderSettings {
        var settings = RenderSettings()
        settings.flameIntensity = Float(flameIntensity)
        settings.smokeDensity = Float(smokeDensity)
        settings.emberCount = Float(emberCount)
        settings.sigilFriction = Float(sigilFriction)
        settings.gravity = Float(gravity)
        settings.candleWarmth = Float(candleWarmth)
        settings.ambientLight = Float(ambientLight)
        settings.exposureEV = Float(exposureEV)
        settings.timeScale = Float(timeScale)
        settings.heatShimmer = Float(heatShimmer)
        settings.froxelFarZ = Float(froxelFarZ)
        settings.bloomIntensity = Float(bloomIntensity)
        settings.narrationEnabled = narrationEnabled
        settings.hapticsEnabled = hapticsEnabled
        settings.autopilotEnabled = autopilotEnabled
        settings.paused = paused
        settings.renderPathChoice = renderPathChoice
        settings.renderScale = Float(ScalarMath.clamp(renderScale, 0.5, 1.0))
        settings.metalFXEnabled = metalFXEnabled
        settings.debugView = debugView
        settings.edition = edition
        settings.seed = seed
        return settings
    }

    /// Pushes the current values into the store (called from every `didSet`).
    private func publish() {
        renderSettingsStore.update(renderSettings)
    }

    // MARK: Launch configuration

    /// Applies a parsed `-key value` launch configuration (ARCHITECTURE §7).
    func applyLaunchConfig(_ config: CaptureConfig) {
        captureConfig = config
        seed = config.seed
        launchCamera = config.camera
        launchStage = config.stage
        renderPathChoice = config.renderPath
        renderScale = ScalarMath.clamp(config.renderScale, 0.5, 1.0)
        autopilotEnabled = config.autopilot
        narrationEnabled = config.narration
        paused = false
        publish()
    }

    /// Restores every slider and toggle to its default.
    func resetToDefaults() {
        flameIntensity = 1
        smokeDensity = 1
        emberCount = 1
        sigilFriction = 1
        gravity = 1
        candleWarmth = 0.5
        ambientLight = 0.15
        exposureEV = 0
        timeScale = 1
        heatShimmer = 0.6
        froxelFarZ = 12
        bloomIntensity = 0.06
        narrationEnabled = false
        hapticsEnabled = true
        autopilotEnabled = false
        paused = false
        debugView = .none
        edition = .samekh1930
    }

    // MARK: Slider metadata for the panel

    /// Slider specs in panel order, with key paths into the model.
    static let sliders: [(spec: SliderSpec, keyPath: ReferenceWritableKeyPath<SettingsModel, Double>)] = [
        (SliderSpec(id: "flameIntensity", title: "Flame intensity", range: 0...3, defaultValue: 1, step: 0.05, unit: "×"), \.flameIntensity),
        (SliderSpec(id: "smokeDensity", title: "Smoke density", range: 0...3, defaultValue: 1, step: 0.05, unit: "×"), \.smokeDensity),
        (SliderSpec(id: "emberCount", title: "Ember count", range: 0...3, defaultValue: 1, step: 0.05, unit: "×"), \.emberCount),
        (SliderSpec(id: "sigilFriction", title: "Sigil friction", range: 0...3, defaultValue: 1, step: 0.05, unit: "×"), \.sigilFriction),
        (SliderSpec(id: "gravity", title: "Gravity", range: 0...3, defaultValue: 1, step: 0.05, unit: "×"), \.gravity),
        (SliderSpec(id: "candleWarmth", title: "Candle warmth", range: 0...1, defaultValue: 0.5, step: 0.01, unit: ""), \.candleWarmth),
        (SliderSpec(id: "ambientLight", title: "Ambient light", range: 0...1, defaultValue: 0.15, step: 0.01, unit: ""), \.ambientLight),
        (SliderSpec(id: "exposureEV", title: "Exposure", range: -4...4, defaultValue: 0, step: 0.1, unit: " EV"), \.exposureEV),
        (SliderSpec(id: "timeScale", title: "Time scale", range: 0...4, defaultValue: 1, step: 0.05, unit: "×"), \.timeScale),
        (SliderSpec(id: "heatShimmer", title: "Heat shimmer", range: 0...1, defaultValue: 0.6, step: 0.01, unit: ""), \.heatShimmer),
        (SliderSpec(id: "froxelFarZ", title: "Froxel depth", range: 6...12, defaultValue: 12, step: 0.5, unit: " m"), \.froxelFarZ),
        (SliderSpec(id: "renderScale", title: "Render scale", range: 0.5...1.0, defaultValue: 0.67, step: 0.01, unit: ""), \.renderScale),
    ]

    /// Candle colour temperature readout for the panel ("1950 K").
    var candleWarmthKelvinText: String {
        String(format: "%.0f K", 1500 + 900 * candleWarmth)
    }
}
