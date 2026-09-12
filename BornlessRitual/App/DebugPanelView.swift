//
//  DebugPanelView.swift
//  Bornless Ritual — the debug panel (ARCHITECTURE §8, complete list: fps, frame time
//  CPU + GPU, 1 % low, thermal state, active render path and why, render scale, MetalFX
//  on/off, stage and progress, chart report (Appendix A, monospaced), daemon name
//  (Hebrew + Latin) and sigil preview, the sliders and toggles, stage jump, render
//  path picker; §4 "The debug panel prints NatalChart.appendixAReport() verbatim";
//  §10 edition toggle; §9 render scale / froxel depth for thermal headroom).
//
//  Role: a sheet over the 3D view (medium/large detents, thin material so the scene
//  keeps rendering behind it). Every control writes `SettingsModel` (the renderer reads
//  the snapshot each frame) or calls `RendererHost`, which forwards to the renderer's
//  main-thread methods.
//

import SwiftUI
import Foundation
import UIKit
import RitualCore

/// The gear-button panel.
@MainActor
struct DebugPanelView: View {
    @EnvironmentObject private var host: RendererHost
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.dismiss) private var dismiss

    /// Render scale range offered by the panel (ARCHITECTURE §9: ≥ 0.6 permitted).
    static let renderScaleRange: ClosedRange<Double> = 0.6...1.0
    /// Bloom intensity range (SettingsModel default 0.06).
    static let bloomRange: ClosedRange<Double> = 0...0.3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statsSection
                    renderSection
                    slidersSection
                    togglesSection
                    ritualSection
                    daemonSection
                    chartSection
                    launchSection
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { settings.resetToDefaults() }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    // MARK: Stats

    private var statsSection: some View {
        let stats = host.stats
        let ritual = host.ritual
        return DebugSection(title: "Performance") {
            VStack(alignment: .leading, spacing: 4) {
                statRow("fps", String(format: "%.1f", stats.fps))
                statRow("frame", String(format: "%.2f ms  (cpu %.2f · gpu %.2f)", stats.frameMs, stats.cpuMs, stats.gpuMs))
                statRow("1 % low", String(format: "%.1f fps  (p99 %.2f ms · max %.2f ms)", stats.p1Low, stats.p99FrameMs, stats.maxFrameMs))
                statRow("thermal", stats.thermal)
                statRow("stage", "\(ritual.stageNumber) \(ritual.stage.id) · " + String(format: "%.0f %%", ritual.stageProgress * 100))
                statRow("tick", "\(ritual.tick) / \(ritual.maxSimulatedTick)  \(HUDStyle.clock(ritual.time))\(ritual.isWarmingUp ? "  warm-up" : "")")
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: label)
                .font(HUDStyle.monoFont)
                .foregroundStyle(HUDStyle.textSecondary)
                .frame(width: 64, alignment: .leading)
            Text(verbatim: value)
                .font(HUDStyle.monoFont)
                .monospacedDigit()
                .foregroundStyle(HUDStyle.textPrimary)
        }
    }

    // MARK: Render

    private var renderSection: some View {
        DebugSection(title: "Render") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Render path", selection: $settings.renderPathChoice) {
                    ForEach(RenderPathChoice.allCases, id: \.self) { choice in
                        Text(verbatim: choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.renderPathChoice) { _, newValue in
                    host.setRenderPath(newValue)
                }
                Text(verbatim: "Active: \(host.renderPath.displayName) — \(host.renderPathReason)")
                    .font(HUDStyle.monoFont)
                    .foregroundStyle(HUDStyle.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let sceneError = host.sceneUpdaterError {
                    Text(verbatim: "Scene updater failed: \(sceneError)")
                        .font(HUDStyle.monoFont)
                        .foregroundStyle(HUDStyle.miss)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Device capabilities") {
                    Text(verbatim: host.capabilityReport)
                        .font(HUDStyle.monoFont)
                        .foregroundStyle(HUDStyle.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)

                Toggle(isOn: $settings.metalFXEnabled) {
                    HStack {
                        Text("MetalFX temporal")
                        Text(verbatim: host.metalFXActive ? "active" : (settings.metalFXEnabled ? "unavailable → TAA" : "off → TAA"))
                            .font(HUDStyle.monoFont)
                            .foregroundStyle(HUDStyle.textSecondary)
                    }
                }

                LabeledSlider(title: "Render scale",
                              value: $settings.renderScale,
                              range: DebugPanelView.renderScaleRange,
                              step: 0.01,
                              valueText: String(format: "%.2f  %@", settings.renderScale, host.resolutionText))

                Picker("Debug view", selection: $settings.debugView) {
                    ForEach(DebugView.allCases) { view in
                        Text(verbatim: view.displayName).tag(view)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: Sliders

    private var slidersSection: some View {
        DebugSection(title: "Sliders") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SettingsModel.sliders.indices, id: \.self) { index in
                    let entry = SettingsModel.sliders[index]
                    if entry.spec.id != "renderScale" {
                        LabeledSlider(title: entry.spec.title,
                                      value: binding(for: entry.keyPath),
                                      range: entry.spec.range,
                                      step: entry.spec.step,
                                      valueText: valueText(for: entry.spec))
                    }
                }
                LabeledSlider(title: "Bloom intensity",
                              value: $settings.bloomIntensity,
                              range: DebugPanelView.bloomRange,
                              step: 0.005,
                              valueText: String(format: "%.3f", settings.bloomIntensity))
            }
        }
    }

    private func binding(for keyPath: ReferenceWritableKeyPath<SettingsModel, Double>) -> Binding<Double> {
        let model = settings
        return Binding(get: { model[keyPath: keyPath] }, set: { model[keyPath: keyPath] = $0 })
    }

    private func valueText(for spec: SliderSpec) -> String {
        if spec.id == "candleWarmth" {
            return String(format: "%.2f  %@", settings.candleWarmth, settings.candleWarmthKelvinText)
        }
        let value = settings[keyPath: SettingsModel.sliders.first(where: { $0.spec.id == spec.id })?.keyPath ?? \.flameIntensity]
        return String(format: "%.2f%@", value, spec.unit)
    }

    // MARK: Toggles

    private var togglesSection: some View {
        DebugSection(title: "Toggles") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Narration", isOn: $settings.narrationEnabled)
                Toggle("Haptics", isOn: $settings.hapticsEnabled)
                Toggle("Autopilot", isOn: $settings.autopilotEnabled)
                Toggle("Pause", isOn: $settings.paused)
            }
        }
    }

    // MARK: Ritual

    private var ritualSection: some View {
        DebugSection(title: "Ritual") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Jump to stage")
                    .font(.subheadline)
                    .foregroundStyle(HUDStyle.textSecondary)
                ChipGrid {
                    ForEach(RitualStage.allCases, id: \.rawValue) { stage in
                        Button {
                            host.jump(to: stage)
                        } label: {
                            Text(verbatim: "\(stage.rawValue) \(stage.id)")
                        }
                        .buttonStyle(ChipButtonStyle(active: host.ritual.stage == stage, tint: HUDStyle.stageColor(stage)))
                    }
                }
                Text("Camera preset")
                    .font(.subheadline)
                    .foregroundStyle(HUDStyle.textSecondary)
                ChipGrid {
                    ForEach(CameraPreset.allCases, id: \.rawValue) { preset in
                        Button {
                            host.applyCameraPreset(preset)
                        } label: {
                            Text(verbatim: preset.rawValue)
                        }
                        .buttonStyle(ChipButtonStyle(active: false, tint: HUDStyle.gold))
                    }
                }
                Picker("Ritual text", selection: $settings.edition) {
                    ForEach(RitualTextEdition.allCases) { edition in
                        Text(verbatim: edition.displayName).tag(edition)
                    }
                }
                .pickerStyle(.segmented)
                if !host.text.isLoaded {
                    Text(verbatim: host.text.loadError ?? "RitualText.json missing")
                        .font(HUDStyle.monoFont)
                        .foregroundStyle(HUDStyle.miss)
                }
            }
        }
    }

    // MARK: Daemon

    private var daemonSection: some View {
        let profile = host.profile
        return DebugSection(title: "Daemon") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: profile.name.hebrew)
                            .font(.system(size: 44, weight: .regular, design: .serif))
                            .foregroundStyle(HUDStyle.gold)
                            .accessibilityLabel(Text("Hebrew name"))
                        Text(verbatim: profile.name.latin)
                            .font(.system(.title2, design: .serif).weight(.semibold))
                            .foregroundStyle(HUDStyle.textPrimary)
                            .tracking(3)
                        Text(verbatim: "values \(profile.name.values.map(String.init).joined(separator: " ")) → \(profile.sigil.reducedValues.map(String.init).joined(separator: " "))")
                            .font(HUDStyle.monoFont)
                            .foregroundStyle(HUDStyle.textSecondary)
                    }
                    Spacer(minLength: 8)
                    SigilPreview(sigil: profile.sigil)
                        .frame(width: 132, height: 132)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(profile.name.placements.enumerated()), id: \.offset) { item in
                        let placement = item.element
                        let place = placement.place.title.padding(toLength: 16, withPad: " ", startingAt: 0)
                        Text(verbatim: place + String(format: "%8.3f°  +%7.3f°  ", placement.longitude, placement.offsetFromAscendant) + String(placement.letter.character) + " " + placement.letter.name)
                            .font(HUDStyle.monoFont)
                            .foregroundStyle(HUDStyle.textSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    attributeRow("sigil", "\(profile.kamea.planet.name) kamea \(profile.kamea.order)×\(profile.kamea.order): \(SigilPreview.cellsDescription(profile.sigil))\(profile.sigil.isClosed ? " (closed)" : "")")
                    attributeRow("form", HUDStyle.words(fromCamelCase: profile.form.rawValue))
                    attributeRow("palette", HUDStyle.words(fromCamelCase: profile.palette.rawValue))
                    attributeRow("element", profile.element.rawValue)
                    attributeRow("motion", HUDStyle.words(fromCamelCase: profile.motion.rawValue))
                    attributeRow("presence", HUDStyle.words(fromCamelCase: profile.presence.rawValue))
                }
            }
        }
    }

    private func attributeRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: label)
                .font(HUDStyle.monoFont)
                .foregroundStyle(HUDStyle.textSecondary)
                .frame(width: 64, alignment: .leading)
            Text(verbatim: value)
                .font(HUDStyle.monoFont)
                .foregroundStyle(HUDStyle.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Chart

    private var chartSection: some View {
        DebugSection(title: "Natal chart (Appendix A)") {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: host.profile.chart.appendixAReport())
                    .font(HUDStyle.monoFont)
                    .foregroundStyle(HUDStyle.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = DebugPanelView.fullReport(host: host)
                } label: {
                    Label("Copy report", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .tint(HUDStyle.gold)
            }
        }
    }

    /// Chart report + name + sigil cells + device / render lines for the clipboard.
    static func fullReport(host: RendererHost) -> String {
        let profile = host.profile
        var lines: [String] = []
        lines.append(profile.chart.appendixAReport())
        lines.append("")
        lines.append("Name \(profile.name.latin) (\(profile.name.hebrew))")
        lines.append("Sigil \(SigilPreview.cellsDescription(profile.sigil)) on the \(profile.kamea.planet.name) kamea")
        lines.append("Form \(HUDStyle.words(fromCamelCase: profile.form.rawValue)); palette \(HUDStyle.words(fromCamelCase: profile.palette.rawValue)); element \(profile.element.rawValue); motion \(HUDStyle.words(fromCamelCase: profile.motion.rawValue)); presence \(HUDStyle.words(fromCamelCase: profile.presence.rawValue))")
        lines.append("")
        lines.append("Render path: \(host.renderPathReason)")
        lines.append("MetalFX: \(host.metalFXActive ? "active" : "inactive"); resolution \(host.resolutionText)")
        lines.append(host.capabilityReport)
        lines.append(String(format: "Stats: %.1f fps, cpu %.2f ms, gpu %.2f ms, 1%%low %.1f, thermal %@",
                            host.stats.fps, host.stats.cpuMs, host.stats.gpuMs, host.stats.p1Low, host.stats.thermal))
        lines.append("Seed \(host.launchConfig.seed); stage \(host.ritual.stage.id) tick \(host.ritual.tick)")
        return lines.joined(separator: "\n")
    }

    // MARK: Launch

    private var launchSection: some View {
        let config = host.launchConfig
        return DebugSection(title: "Launch configuration") {
            VStack(alignment: .leading, spacing: 3) {
                attributeRow("stage", "\(config.stage.rawValue) \(config.stage.id)")
                attributeRow("camera", config.camera.rawValue)
                attributeRow("path", config.renderPath.rawValue)
                attributeRow("seed", "\(config.seed)")
                attributeRow("capture", "\(config.mode.rawValue)\(config.isCaptureRun ? " (run \"\(config.runName)\")" : "")")
                attributeRow("autopilot", config.autopilot ? "on" : "off")
                attributeRow("warm-up", "\(config.warmupFrames) frames")
                attributeRow("edition", host.text.editionTitle(settings.edition))
            }
        }
    }
}

// MARK: - Building blocks

/// Titled card inside the panel.
struct DebugSection<Content: View>: View {
    /// Section title.
    let title: String
    /// Section content.
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title.uppercased())
                .font(HUDStyle.labelFont)
                .foregroundStyle(HUDStyle.textSecondary)
                .tracking(1.2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HUDStyle.panelStroke, lineWidth: 1)
        )
    }
}

/// Slider with a title on the left and the live value on the right.
struct LabeledSlider: View {
    /// Label.
    let title: String
    /// Bound value.
    @Binding var value: Double
    /// Allowed range.
    let range: ClosedRange<Double>
    /// Step.
    let step: Double
    /// Live readout.
    let valueText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: title)
                    .font(.subheadline)
                    .foregroundStyle(HUDStyle.textPrimary)
                Spacer()
                Text(verbatim: valueText)
                    .font(HUDStyle.monoFont)
                    .monospacedDigit()
                    .foregroundStyle(HUDStyle.textSecondary)
            }
            Slider(value: $value, in: range, step: step)
                .tint(HUDStyle.gold)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(valueText))
    }
}

/// Wrapping row of chips (a simple flow layout).
struct ChipGrid<Content: View>: View {
    /// Chips.
    @ViewBuilder let content: () -> Content

    var body: some View {
        FlowLayout(spacing: 6) {
            content()
        }
    }
}

/// Minimal wrapping layout for chips.
struct FlowLayout: Layout {
    /// Gap between chips.
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let rows = arrange(subviews: subviews, width: width)
        return CGSize(width: width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified)))
        }
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, y + rowHeight)
    }
}

/// Capsule chip; `active` fills it with `tint`.
struct ChipButtonStyle: ButtonStyle {
    /// Whether the chip is the current selection.
    var active: Bool
    /// Fill / outline colour.
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption, design: .rounded).weight(.medium))
            .foregroundStyle(active ? Color.black.opacity(0.85) : HUDStyle.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(active ? tint : Color.white.opacity(configuration.isPressed ? 0.18 : 0.10)))
            .overlay(Capsule().stroke(active ? tint : HUDStyle.panelStroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
