//
//  ContentView.swift
//  Bornless Ritual — root screen (ARCHITECTURE §1 "App/: SwiftUI app, views, debug
//  panel, timeline, settings model"; §8 "Debug panel (SwiftUI overlay, toggled by a gear
//  button)").
//
//  Role: ZStack of the full-screen Metal view, the top `StageHUD`, the bottom
//  `RitualTimelineView`, the gear button that presents `DebugPanelView` as a sheet, and
//  an error card when the renderer could not be created. Only the timeline, the gear
//  button and the sheet accept touches; everything else lets gestures reach the
//  Metal view.
//

import SwiftUI
import Foundation
import RitualCore

/// The one screen of the app.
@MainActor
struct ContentView: View {
    @EnvironmentObject private var host: RendererHost
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        ZStack {
            MetalView(host: host)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    StageHUD()
                    Spacer(minLength: 0)
                    gearButton
                }
                Spacer(minLength: 0)
                RitualTimelineView()
                    .frame(maxWidth: 640)
            }
            .padding(12)

            if let error = host.rendererError {
                rendererErrorCard(error)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $settings.showDebugPanel) {
            DebugPanelView()
                .environmentObject(host)
                .environmentObject(settings)
        }
    }

    private var gearButton: some View {
        Button {
            settings.showDebugPanel = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(HUDStyle.textPrimary)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(HUDStyle.panelStroke, lineWidth: 1))
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Debug panel"))
    }

    private func rendererErrorCard(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(HUDStyle.ember)
            Text("The renderer could not start")
                .font(HUDStyle.titleFont)
                .foregroundStyle(HUDStyle.textPrimary)
            Text(verbatim: message)
                .font(HUDStyle.monoFont)
                .foregroundStyle(HUDStyle.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 360)
        .hudPanel(padding: 20)
    }
}
