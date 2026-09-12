//
//  BornlessRitualApp.swift
//  Bornless Ritual — application entry point (ARCHITECTURE §7 launch arguments parsed
//  by `CaptureConfig.parse`, §4 the owner's daemon `DaemonProfile.owner`, §5 one
//  `RitualSimulation` per process seeded from the launch config; RENDER_CONTRACT §1
//  `SettingsModel.applyLaunchConfig(CaptureConfig)`).
//
//  Role: parses `CommandLine.arguments` once, injects the configuration into
//  `SettingsModel`, creates the simulation and the daemon profile once, wraps them in
//  `RendererHost` and shows `ContentView`. The capture harness (Capture/, another job)
//  plugs in through `RendererHost.captureObserverFactory` — see the marked line.
//

import SwiftUI
import RitualCore

/// The app.
@main
@MainActor
struct BornlessRitualApp: App {
    @StateObject private var settings: SettingsModel
    @StateObject private var host: RendererHost

    /// Parses the launch configuration and builds the process-wide objects.
    init() {
        let config = CaptureConfig.parse(arguments: CommandLine.arguments)
        let settings = SettingsModel()
        settings.applyLaunchConfig(config)

        let simulation = RitualSimulation(seed: config.seed, config: settings.renderSettings.simConfig)
        let profile = DaemonProfile.owner
        let text = RitualTextProvider(bundle: Bundle.main)
        let host = RendererHost(settings: settings, simulation: simulation, profile: profile,
                                text: text, launchConfig: config)

        // Capture harness integration point (Capture/CaptureHarness.swift): assign a
        // factory returning a `RendererFrameObserver` for capture runs, e.g.
        //   host.captureObserverFactory = { renderer in
        //       config.isCaptureRun ? CaptureHarness(renderer: renderer, config: config, settings: settings) : nil
        //   }
        host.captureObserverFactory = nil

        _settings = StateObject(wrappedValue: settings)
        _host = StateObject(wrappedValue: host)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(host)
        }
    }
}
