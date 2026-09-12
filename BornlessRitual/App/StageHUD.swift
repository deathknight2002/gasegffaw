//
//  StageHUD.swift
//  Bornless Ritual — top overlay (ARCHITECTURE §3 mini-games and their prompts, §8
//  "stage and progress", §10 ritual text: "The HUD shows the current stage's lines in
//  the selected edition"; docs/SOURCES.md §4a beat names per edition).
//
//  Role: stage title, the current ritual line (cycling every 3.5 ritual seconds of the
//  stage), a progress bar tinted by the stage's element, and the mini-game prompt:
//  "Hold to chant" (oath, chant progress), "Turn to face the East and trace the sigil"
//  (quarter stages, with a facing arrow and the trace template glyph), rhythm beat
//  markers lighting the six names on the beat (spirit), "Flick to spin" (sigil spin,
//  charge bar) and "Behold" (manifestation). Non-interactive: hit testing is disabled
//  so gestures fall through to the Metal view.
//

import SwiftUI
import Foundation
import RitualCore

/// Stage title, ritual line, progress and mini-game prompt.
@MainActor
struct StageHUD: View {
    @EnvironmentObject private var host: RendererHost
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        let ritual = host.ritual
        VStack(alignment: .leading, spacing: 8) {
            header(ritual)
            ritualLine(ritual)
            HUDProgressBar(value: ritual.stageProgress, tint: HUDStyle.stageColor(ritual.stage))
            prompt(ritual)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .hudPanel()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: ritual.stage)
        .animation(.easeInOut(duration: 0.25), value: ritual.facingQuarter)
    }

    // MARK: Header

    private func header(_ ritual: RitualSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "STAGE \(ritual.stageNumber) OF \(ritual.stageCount)")
                    .font(HUDStyle.labelFont)
                    .foregroundStyle(HUDStyle.textSecondary)
                    .tracking(1.2)
                Text(verbatim: host.text.title(for: ritual.stage))
                    .font(HUDStyle.titleFont)
                    .foregroundStyle(HUDStyle.textPrimary)
            }
            Spacer(minLength: 8)
            if ritual.isWarmingUp {
                Text(verbatim: "…")
                    .font(HUDStyle.monoFont)
                    .foregroundStyle(HUDStyle.textSecondary)
                    .accessibilityLabel(Text("Warming up"))
            }
            Text(verbatim: HUDStyle.clock(ritual.time))
                .font(HUDStyle.monoFont)
                .monospacedDigit()
                .foregroundStyle(HUDStyle.textSecondary)
        }
    }

    // MARK: Ritual line

    @ViewBuilder
    private func ritualLine(_ ritual: RitualSnapshot) -> some View {
        if let line = host.currentLine {
            Text(verbatim: line.text)
                .font(HUDStyle.lineFont)
                .foregroundStyle(HUDStyle.textPrimary.opacity(0.9))
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .id(line.index)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.5), value: line.index)
        } else if !host.text.isLoaded {
            Text(verbatim: host.text.loadError ?? "Ritual text unavailable")
                .font(HUDStyle.monoFont)
                .foregroundStyle(HUDStyle.textSecondary)
        }
    }

    // MARK: Prompts

    @ViewBuilder
    private func prompt(_ ritual: RitualSnapshot) -> some View {
        switch ritual.stage {
        case .oath:
            oathPrompt(ritual)
        case .air, .fire, .water, .earth:
            quarterPrompt(ritual)
        case .spirit:
            spiritPrompt(ritual)
        case .sigilSpin:
            spinPrompt(ritual)
        case .manifestation:
            manifestationPrompt(ritual)
        }
    }

    private func oathPrompt(_ ritual: RitualSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ritual.holding ? "hand.tap.fill" : "hand.tap")
                .foregroundStyle(ritual.holding ? HUDStyle.gold : HUDStyle.textSecondary)
            Text(verbatim: "Hold to chant")
                .font(HUDStyle.promptFont)
                .foregroundStyle(HUDStyle.textPrimary)
            Spacer(minLength: 8)
            Text(verbatim: String(format: "%.0f %%", ritual.chantProgress * 100))
                .font(HUDStyle.monoFont)
                .monospacedDigit()
                .foregroundStyle(HUDStyle.textSecondary)
        }
    }

    @ViewBuilder
    private func quarterPrompt(_ ritual: RitualSnapshot) -> some View {
        if let quarter = ritual.stage.quarter, let element = ritual.stage.element {
            let tint = HUDStyle.elementColor(element)
            HStack(alignment: .center, spacing: 10) {
                FacingIndicator(quarter: quarter, cameraYaw: ritual.cameraYaw, facing: ritual.facingQuarter, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Turn to face the \(HUDStyle.quarterName(quarter)) and trace the sigil")
                        .font(HUDStyle.promptFont)
                        .foregroundStyle(HUDStyle.textPrimary)
                    Text(verbatim: ritual.facingQuarter
                         ? "Facing \(HUDStyle.quarterName(quarter)) — trace the \(element.rawValue.capitalized) sigil in one stroke"
                         : "Orbit the camera until it looks \(HUDStyle.quarterName(quarter))")
                        .font(.caption)
                        .foregroundStyle(ritual.facingQuarter ? tint : HUDStyle.textSecondary)
                    if ritual.traceAttempts > 0 {
                        Text(verbatim: "Attempts: \(ritual.traceAttempts) · \(ritual.traceHits)/\(SigilTemplates.defaultCheckpointCount) checkpoints")
                            .font(HUDStyle.monoFont)
                            .foregroundStyle(HUDStyle.textSecondary)
                    }
                }
                Spacer(minLength: 4)
                TraceTemplateGlyph(element: element, hits: ritual.traceHits, tint: tint)
                    .frame(width: 56, height: 56)
                    .opacity(ritual.facingQuarter ? 1 : 0.5)
            }
        }
    }

    private func spiritPrompt(_ ritual: RitualSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: "Tap on each name as it sounds")
                    .font(HUDStyle.promptFont)
                    .foregroundStyle(HUDStyle.textPrimary)
                Spacer(minLength: 8)
                if ritual.rhythmRound > 0 {
                    Text(verbatim: "Round \(ritual.rhythmRound + 1)")
                        .font(HUDStyle.monoFont)
                        .foregroundStyle(HUDStyle.textSecondary)
                }
            }
            RhythmMarkers(names: host.text.beatNames(edition: settings.edition),
                          beatTicks: ritual.beatTicks,
                          beatResults: ritual.beatResults,
                          tick: ritual.tick)
        }
    }

    private func spinPrompt(_ ritual: RitualSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(HUDStyle.gold)
            Text(verbatim: "Flick to spin")
                .font(HUDStyle.promptFont)
                .foregroundStyle(HUDStyle.textPrimary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: String(format: "charge %.0f %%", ritual.manifestCharge * 100))
                    .font(HUDStyle.monoFont)
                    .monospacedDigit()
                    .foregroundStyle(HUDStyle.textSecondary)
                Text(verbatim: String(format: "%.1f J", ritual.spinEnergy))
                    .font(HUDStyle.monoFont)
                    .monospacedDigit()
                    .foregroundStyle(HUDStyle.textSecondary)
            }
        }
    }

    private func manifestationPrompt(_ ritual: RitualSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ritual.isComplete ? "eye.fill" : "eye")
                .foregroundStyle(HUDStyle.gold)
            Text(verbatim: ritual.isComplete ? "Behold — \(host.profile.name.latin)" : "Behold")
                .font(HUDStyle.promptFont)
                .foregroundStyle(HUDStyle.textPrimary)
            Spacer(minLength: 8)
            Text(verbatim: ritual.isComplete ? "ritual complete" : String(format: "%.0f %%", ritual.manifestT * 100))
                .font(HUDStyle.monoFont)
                .monospacedDigit()
                .foregroundStyle(HUDStyle.textSecondary)
        }
    }
}

// MARK: - Facing indicator

/// Arrow pointing the way the camera must turn to face `quarter`.
///
/// Yaw grows from +Z toward +X (ARCHITECTURE §2); with +Y up and the camera's right
/// vector = forward × up, increasing yaw is a turn to the viewer's left, so a positive
/// yaw difference rotates the arrow counter-clockwise on screen.
struct FacingIndicator: View {
    /// Quarter to face.
    let quarter: Quarter
    /// Camera yaw in degrees.
    let cameraYaw: Double
    /// Whether the simulation's facing gate is open.
    let facing: Bool
    /// Tint when facing.
    var tint: Color = HUDStyle.gold

    /// Signed turn needed, degrees in (−180, 180]; positive = turn left.
    var turnDegrees: Double {
        RitualCore.Angle.wrap180(quarter.yawDegrees - cameraYaw)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(facing ? tint : HUDStyle.textSecondary.opacity(0.5), lineWidth: 1.5)
            Image(systemName: facing ? "checkmark" : "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(facing ? tint : HUDStyle.textPrimary)
                .rotationEffect(.degrees(facing ? 0 : -turnDegrees))
        }
        .frame(width: 36, height: 36)
        .animation(.easeInOut(duration: 0.15), value: turnDegrees)
        .accessibilityLabel(Text(facing ? "Facing \(HUDStyle.quarterName(quarter))" : "Turn \(Int(abs(turnDegrees))) degrees to face \(HUDStyle.quarterName(quarter))"))
    }
}

// MARK: - Rhythm markers

/// Six barbarous names; each lights as its beat approaches and keeps its judged colour.
struct RhythmMarkers: View {
    /// The six names in display orthography.
    let names: [String]
    /// Tick of each beat in the current round.
    let beatTicks: [Int]
    /// Results of the beats already judged.
    let beatResults: [BeatResult]
    /// Current simulation tick.
    let tick: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { item in
                marker(index: item.offset, name: item.element)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func marker(index: Int, name: String) -> some View {
        let state = RhythmMarkers.markerState(index: index, beatTicks: beatTicks, beatResults: beatResults, tick: tick)
        return Text(verbatim: name)
            .font(HUDStyle.beatFont)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(state.textColor)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(state.fillColor)
            )
            .overlay(
                Capsule().stroke(state.strokeColor, lineWidth: 1)
            )
            .scaleEffect(1 + 0.18 * state.glow)
            .shadow(color: HUDStyle.gold.opacity(0.7 * state.glow), radius: 6 * state.glow)
            .animation(.easeOut(duration: 0.08), value: state.glow)
    }

    /// Visual state of one marker.
    struct MarkerState: Equatable {
        /// Closeness of the beat in [0, 1] (1 = on the beat), 0 once judged.
        var glow: Double
        var textColor: Color
        var fillColor: Color
        var strokeColor: Color
    }

    /// Computes the state of marker `index` at `tick`.
    static func markerState(index: Int, beatTicks: [Int], beatResults: [BeatResult], tick: Int) -> MarkerState {
        if index < beatResults.count {
            switch beatResults[index] {
            case .perfect:
                return MarkerState(glow: 0, textColor: Color.black.opacity(0.85), fillColor: HUDStyle.gold, strokeColor: HUDStyle.gold)
            case .good:
                return MarkerState(glow: 0, textColor: Color.black.opacity(0.8), fillColor: HUDStyle.ember.opacity(0.8), strokeColor: HUDStyle.ember)
            case .miss:
                return MarkerState(glow: 0, textColor: HUDStyle.textSecondary, fillColor: HUDStyle.miss.opacity(0.35), strokeColor: HUDStyle.miss.opacity(0.6))
            }
        }
        guard index < beatTicks.count else {
            return MarkerState(glow: 0, textColor: HUDStyle.textSecondary, fillColor: Color.clear, strokeColor: HUDStyle.panelStroke)
        }
        let distance = Double(abs(beatTicks[index] - tick))
        let window = Double(max(RhythmSpec.goodTicks, 1))
        let glow = max(0, 1 - distance / window)
        let upcoming = beatTicks[index] > tick
        return MarkerState(glow: glow,
                           textColor: glow > 0 ? HUDStyle.textPrimary : (upcoming ? HUDStyle.textSecondary : HUDStyle.textSecondary.opacity(0.6)),
                           fillColor: HUDStyle.gold.opacity(0.55 * glow),
                           strokeColor: glow > 0 ? HUDStyle.gold.opacity(0.4 + 0.6 * glow) : HUDStyle.panelStroke)
    }
}
