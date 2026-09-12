//
//  TimelineView.swift
//  Bornless Ritual — timeline scrubber (ARCHITECTURE §5 "Rewind/scrub = restore nearest
//  keyframe ≤ target and replay the input log … Forward scrub beyond the max simulated
//  tick simulates forward", §8 "timeline scrubber", time scale 0–4; RENDER_CONTRACT §1
//  `Renderer.seek(toTick:)`).
//
//  Role: bottom overlay with play/pause, the ritual clock, a slider over simulation
//  ticks bound to the renderer's current tick / `maxSimulatedTick` (the range is frozen
//  while the finger is down so it does not slide under the thumb), stage-completion
//  markers on the track, a time-scale menu and stage skip buttons. The type is named
//  `RitualTimelineView` so it does not shadow SwiftUI's `TimelineView`.
//

import SwiftUI
import Foundation
import RitualCore

/// Scrubber, transport controls and time scale.
@MainActor
struct RitualTimelineView: View {
    @EnvironmentObject private var host: RendererHost
    @EnvironmentObject private var settings: SettingsModel

    /// Slider value in ticks (follows the renderer while not scrubbing).
    @State private var scrubTick: Double = 0
    /// True while the finger is on the slider.
    @State private var isScrubbing = false
    /// Slider upper bound captured when a scrub starts.
    @State private var frozenRangeMax: Double = 1
    /// Pause state before the scrub began (restored on release).
    @State private var pausedBeforeScrub = false
    /// Last tick sent to `seek` during the current scrub.
    @State private var lastSeekTick: Int = -1

    /// Ticks of forward headroom offered beyond the simulated range (5 s).
    static let forwardHeadroomTicks = 5 * RitualSimulation.tickRate
    /// Available time scales.
    static let timeScales: [Double] = [0.25, 0.5, 1, 2, 4]

    var body: some View {
        let ritual = host.ritual
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                playPauseButton
                Text(verbatim: HUDStyle.clock(ritual.time))
                    .font(HUDStyle.monoFont)
                    .monospacedDigit()
                    .foregroundStyle(HUDStyle.textPrimary)
                Text(verbatim: "tick \(isScrubbing ? Int(scrubTick) : ritual.tick)")
                    .font(HUDStyle.monoFont)
                    .monospacedDigit()
                    .foregroundStyle(HUDStyle.textSecondary)
                Spacer(minLength: 4)
                stageSkipButtons(ritual)
                timeScaleMenu
            }
            slider(ritual)
        }
        .hudPanel()
        .onAppear { scrubTick = Double(ritual.tick) }
        .onChange(of: ritual.tick) { _, newTick in
            if !isScrubbing {
                scrubTick = Double(newTick)
            }
        }
    }

    // MARK: Controls

    private var playPauseButton: some View {
        Button {
            host.togglePause()
        } label: {
            Image(systemName: settings.paused ? "play.fill" : "pause.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(HUDStyle.textPrimary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(settings.paused ? "Play" : "Pause"))
    }

    private func stageSkipButtons(_ ritual: RitualSnapshot) -> some View {
        HStack(spacing: 4) {
            Button {
                host.seek(toTick: ritual.stageStartTick)
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(HUDStyle.textSecondary)
            .accessibilityLabel(Text("Back to the start of the stage"))

            Button {
                if let next = ritual.stage.next {
                    host.jump(to: next)
                }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ritual.stage.next == nil ? HUDStyle.textSecondary.opacity(0.35) : HUDStyle.textSecondary)
            .disabled(ritual.stage.next == nil)
            .accessibilityLabel(Text("Jump to the next stage"))
        }
    }

    private var timeScaleMenu: some View {
        Menu {
            ForEach(RitualTimelineView.timeScales, id: \.self) { scale in
                Button {
                    settings.timeScale = scale
                } label: {
                    if abs(settings.timeScale - scale) < 1e-6 {
                        Label(RitualTimelineView.scaleLabel(scale), systemImage: "checkmark")
                    } else {
                        Text(verbatim: RitualTimelineView.scaleLabel(scale))
                    }
                }
            }
        } label: {
            Text(verbatim: RitualTimelineView.scaleLabel(settings.timeScale))
                .font(HUDStyle.monoFont)
                .monospacedDigit()
                .foregroundStyle(HUDStyle.textPrimary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .accessibilityLabel(Text("Time scale"))
    }

    /// "1×", "0.25×", "2×".
    static func scaleLabel(_ scale: Double) -> String {
        String(format: "%g×", scale)
    }

    // MARK: Slider

    private func slider(_ ritual: RitualSnapshot) -> some View {
        let liveMax = Double(max(ritual.maxSimulatedTick, ritual.tick) + RitualTimelineView.forwardHeadroomTicks)
        let rangeMax = isScrubbing ? frozenRangeMax : max(liveMax, 1)
        return ZStack {
            stageMarkers(ritual, rangeMax: rangeMax)
            Slider(value: $scrubTick, in: 0...rangeMax, onEditingChanged: { editing in
                scrubEditingChanged(editing, liveMax: liveMax)
            })
            .tint(HUDStyle.gold)
            .onChange(of: scrubTick) { _, newValue in
                if isScrubbing {
                    seekIfNeeded(Int(newValue.rounded()))
                }
            }
        }
        .frame(height: 30)
        .accessibilityLabel(Text("Timeline"))
    }

    /// Small ticks on the track where each stage completed.
    private func stageMarkers(_ ritual: RitualSnapshot, rangeMax: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ForEach(RitualStage.allCases, id: \.rawValue) { stage in
                if let tick = ritual.completedTicks[stage], rangeMax > 0 {
                    let fraction = min(max(Double(tick) / rangeMax, 0), 1)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(HUDStyle.stageColor(stage).opacity(0.8))
                        .frame(width: 2, height: 10)
                        .position(x: CGFloat(fraction) * width, y: proxy.size.height / 2 + 12)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func scrubEditingChanged(_ editing: Bool, liveMax: Double) {
        if editing {
            isScrubbing = true
            frozenRangeMax = max(liveMax, 1)
            pausedBeforeScrub = settings.paused
            settings.paused = true
            lastSeekTick = -1
        } else {
            seekIfNeeded(Int(scrubTick.rounded()), force: true)
            isScrubbing = false
            settings.paused = pausedBeforeScrub
        }
    }

    /// Seeks the renderer when the requested tick differs from the last one sent.
    private func seekIfNeeded(_ tick: Int, force: Bool = false) {
        guard force || tick != lastSeekTick else { return }
        lastSeekTick = tick
        host.seek(toTick: tick)
    }
}
