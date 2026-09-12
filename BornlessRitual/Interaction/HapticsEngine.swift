//
//  HapticsEngine.swift
//  Bornless Ritual — CoreHaptics feedback for ritual events (ARCHITECTURE §1 "CoreHaptics
//  allowed for non-render-path work", §8 haptics toggle; CORE_API `RitualEvent`
//  "haptics/narration react to these"; docs/CRITIC.md "haptic timing on stage completion").
//
//  Role: wraps one `CHHapticEngine` (created lazily, restarted by its reset / stopped
//  handlers) and maps every `RitualEvent` to a `CHHapticPattern`:
//    stageCompleted     sharp transient (1.0) + 0.35 s continuous tail decaying to 0
//    candleLit          soft whoosh: 0.25 s continuous, intensity rising 0.15 → 0.7
//    beatHit(perfect)   tiny sharp tick   (intensity 0.6, sharpness 0.9)
//    beatHit(good)      tiny medium tick  (0.45, 0.5)
//    beatHit(miss)      dull thud         (0.25, 0.1)
//    sigilErupted       double transient + 0.6 s continuous decaying rumble
//    manifestationBegan 1.2 s swell (0.1 → 1.0 → 0.3)
//    ritualComplete     transient + 0.8 s continuous fade + closing transient
//  `handle(_:)` respects `RenderSettings.hapticsEnabled` through the lock-protected
//  `RenderSettingsStore`, so it never touches the main-actor `SettingsModel`.
//
//  Threading: call `prepare`, `handle`, `stop` from the main thread (the gesture layer
//  and the feedback monitor do); CoreHaptics' reset / stopped callbacks arrive on
//  arbitrary threads and are hopped back to the main queue before touching state.
//

import Foundation
import CoreHaptics
import RitualCore
import os

/// Haptic feedback for `RitualEvent`s.
final class HapticsEngine {
    /// Settings snapshot source (`hapticsEnabled`).
    let settingsStore: RenderSettingsStore
    /// `CHHapticEngine.capabilitiesForHardware().supportsHaptics`.
    let supportsHaptics: Bool

    private var engine: CHHapticEngine?
    private var isRunning = false
    private var loggedStartFailure = false
    private let log = Logger(subsystem: "BornlessRitual", category: "Haptics")

    /// Creates the engine wrapper; nothing is allocated until `prepare()` or the first event.
    init(settingsStore: RenderSettingsStore) {
        self.settingsStore = settingsStore
        self.supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    /// Convenience over the model's store.
    @MainActor
    convenience init(settings: SettingsModel) {
        self.init(settingsStore: settings.renderSettingsStore)
    }

    /// Whether the haptics toggle is on.
    var isEnabled: Bool {
        settingsStore.snapshot().hapticsEnabled
    }

    /// Whether the engine exists and is started.
    var isReady: Bool {
        engine != nil && isRunning
    }

    // MARK: Engine lifecycle

    /// Creates and starts the engine (no-op when the device has no haptics).
    func prepare() {
        guard supportsHaptics, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            engine.resetHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.engineDidReset()
                }
            }
            engine.stoppedHandler = { [weak self] reason in
                DispatchQueue.main.async {
                    self?.engineDidStop(reason)
                }
            }
            self.engine = engine
            startEngine()
        } catch {
            log.error("CHHapticEngine could not be created: \(String(describing: error), privacy: .public)")
            engine = nil
        }
    }

    /// Stops the engine (it restarts lazily on the next event).
    func stop() {
        engine?.stop(completionHandler: nil)
        isRunning = false
    }

    private func startEngine() {
        guard let engine = engine, !isRunning else { return }
        do {
            try engine.start()
            isRunning = true
            loggedStartFailure = false
        } catch {
            if !loggedStartFailure {
                loggedStartFailure = true
                log.error("CHHapticEngine failed to start: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func engineDidReset() {
        isRunning = false
        startEngine()
    }

    private func engineDidStop(_ reason: CHHapticEngine.StoppedReason) {
        isRunning = false
        if reason == .engineDestroyed {
            engine = nil
        }
    }

    // MARK: Events

    /// Plays the pattern for `event` when haptics are supported and enabled.
    func handle(_ event: RitualEvent) {
        guard supportsHaptics, isEnabled else { return }
        if engine == nil {
            prepare()
        }
        guard let engine = engine else { return }
        if !isRunning {
            startEngine()
        }
        guard isRunning else { return }
        do {
            let pattern = try HapticsEngine.pattern(for: event)
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            log.error("Haptic pattern failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Patterns

    /// The pattern for an event (pure; throws only when CoreHaptics rejects the parameters).
    static func pattern(for event: RitualEvent) throws -> CHHapticPattern {
        switch event {
        case .stageCompleted:
            return try CHHapticPattern(
                events: [transient(intensity: 1.0, sharpness: 0.7, at: 0),
                         continuous(intensity: 0.8, sharpness: 0.3, at: 0.03, duration: 0.35)],
                parameterCurves: [intensityCurve([(0, 1.0), (0.38, 0.0)], at: 0)])
        case .candleLit:
            return try CHHapticPattern(
                events: [continuous(intensity: 0.7, sharpness: 0.2, at: 0, duration: 0.25)],
                parameterCurves: [intensityCurve([(0, 0.2), (0.25, 1.0)], at: 0)])
        case .beatHit(let result):
            switch result {
            case .perfect:
                return try CHHapticPattern(events: [transient(intensity: 0.6, sharpness: 0.9, at: 0)], parameters: [])
            case .good:
                return try CHHapticPattern(events: [transient(intensity: 0.45, sharpness: 0.5, at: 0)], parameters: [])
            case .miss:
                return try CHHapticPattern(events: [transient(intensity: 0.25, sharpness: 0.1, at: 0)], parameters: [])
            }
        case .sigilErupted:
            return try CHHapticPattern(
                events: [transient(intensity: 1.0, sharpness: 0.8, at: 0),
                         transient(intensity: 0.9, sharpness: 0.6, at: 0.12),
                         continuous(intensity: 0.7, sharpness: 0.4, at: 0.15, duration: 0.6)],
                parameterCurves: [intensityCurve([(0, 1.0), (0.15, 1.0), (0.75, 0.0)], at: 0)])
        case .manifestationBegan:
            return try CHHapticPattern(
                events: [continuous(intensity: 1.0, sharpness: 0.25, at: 0, duration: 1.2)],
                parameterCurves: [intensityCurve([(0, 0.1), (0.7, 1.0), (1.2, 0.3)], at: 0)])
        case .ritualComplete:
            return try CHHapticPattern(
                events: [transient(intensity: 1.0, sharpness: 0.5, at: 0),
                         continuous(intensity: 0.9, sharpness: 0.3, at: 0.05, duration: 0.8),
                         transient(intensity: 0.7, sharpness: 0.9, at: 0.5)],
                parameterCurves: [intensityCurve([(0, 1.0), (0.85, 0.0)], at: 0)])
        }
    }

    private static func transient(intensity: Float, sharpness: Float, at time: TimeInterval) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient,
                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)],
                      relativeTime: time)
    }

    private static func continuous(intensity: Float, sharpness: Float, at time: TimeInterval, duration: TimeInterval) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticContinuous,
                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)],
                      relativeTime: time,
                      duration: duration)
    }

    private static func intensityCurve(_ points: [(TimeInterval, Float)], at time: TimeInterval) -> CHHapticParameterCurve {
        let controlPoints = points.map { CHHapticParameterCurve.ControlPoint(relativeTime: $0.0, value: $0.1) }
        return CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: controlPoints, relativeTime: time)
    }
}
