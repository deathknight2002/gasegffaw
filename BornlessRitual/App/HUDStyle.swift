//
//  HUDStyle.swift
//  Bornless Ritual — shared look of the SwiftUI overlay (ARCHITECTURE §8 debug panel,
//  §10 HUD text): dark, minimal, legible over the 3D view, thin Material backgrounds.
//
//  Role: colours (element tints derived from RitualCore's linear flame colours),
//  fonts (serif for ritual text, rounded for labels, monospaced for numbers) and the
//  `hudPanel()` modifier every overlay card uses.
//

import SwiftUI
import Foundation
import RitualCore

/// Palette, typography and helpers shared by the overlay views.
enum HUDStyle {
    /// Warm gold used for the sigil, progress and highlights.
    static let gold = Color(red: 0.96, green: 0.78, blue: 0.40)
    /// Ember orange for "perfect" beats and hot accents.
    static let ember = Color(red: 1.0, green: 0.55, blue: 0.20)
    /// Muted red for misses and errors.
    static let miss = Color(red: 0.75, green: 0.25, blue: 0.22)
    /// Primary text over the 3D view.
    static let textPrimary = Color.white.opacity(0.92)
    /// Secondary / caption text.
    static let textSecondary = Color.white.opacity(0.62)
    /// Faint outline of panels.
    static let panelStroke = Color.white.opacity(0.10)
    /// Track colour of progress bars.
    static let track = Color.white.opacity(0.14)

    /// Stage title.
    static let titleFont = Font.system(.title3, design: .serif).weight(.semibold)
    /// Ritual line.
    static let lineFont = Font.system(.callout, design: .serif).italic()
    /// Small labels ("STAGE 2 OF 8").
    static let labelFont = Font.system(.caption2, design: .rounded).weight(.semibold)
    /// Prompts ("Hold to chant").
    static let promptFont = Font.system(.subheadline, design: .rounded).weight(.medium)
    /// Numeric readouts.
    static let monoFont = Font.system(.caption, design: .monospaced)
    /// Barbarous names on the beat markers.
    static let beatFont = Font.system(.caption, design: .serif).weight(.semibold)

    /// Converts a linear-RGB colour (RitualCore) to a display colour (sRGB transfer).
    static func color(linear: RVec3, opacity: Double = 1) -> Color {
        Color(red: sRGBTransfer(linear.x), green: sRGBTransfer(linear.y), blue: sRGBTransfer(linear.z), opacity: opacity)
    }

    /// Linear → sRGB electro-optical transfer (IEC 61966-2-1), clamped to [0, 1].
    static func sRGBTransfer(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        if clamped <= 0.0031308 {
            return 12.92 * clamped
        }
        return 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
    }

    /// Tint of an element's flame (gold for `nil`).
    static func elementColor(_ element: RitualElement?) -> Color {
        guard let element = element else { return gold }
        return color(linear: element.flameColorLinearRGB)
    }

    /// Tint for a stage: its element's flame colour, gold otherwise.
    static func stageColor(_ stage: RitualStage) -> Color {
        elementColor(stage.element)
    }

    /// Capitalised quarter name ("East").
    static func quarterName(_ quarter: Quarter) -> String {
        quarter.rawValue.capitalized
    }

    /// Splits a camelCase identifier into lower-case words ("goldWhiteFire" → "gold white fire").
    static func words(fromCamelCase identifier: String) -> String {
        var result = ""
        for character in identifier {
            if character.isUppercase, !result.isEmpty {
                result.append(" ")
            }
            result.append(contentsOf: String(character).lowercased())
        }
        return result
    }

    /// "m:ss.s" from ritual seconds.
    static func clock(_ seconds: Double) -> String {
        let clamped = max(seconds, 0)
        let minutes = Int(clamped / 60)
        let remainder = clamped - Double(minutes) * 60
        return String(format: "%d:%04.1f", minutes, remainder)
    }
}

// MARK: - Panel modifier

/// Thin dark material card with a faint outline.
struct HUDPanelModifier: ViewModifier {
    /// Inner padding.
    var padding: CGFloat = 12
    /// Corner radius.
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(HUDStyle.panelStroke, lineWidth: 1)
            )
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Wraps the view in the overlay card style.
    func hudPanel(padding: CGFloat = 12, cornerRadius: CGFloat = 14) -> some View {
        modifier(HUDPanelModifier(padding: padding, cornerRadius: cornerRadius))
    }
}

// MARK: - Progress bar

/// Thin capsule progress bar tinted by `tint`.
struct HUDProgressBar: View {
    /// Fraction in [0, 1].
    var value: Double
    /// Fill colour.
    var tint: Color = HUDStyle.gold
    /// Bar height in points.
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let fraction = CGFloat(min(max(value, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(HUDStyle.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * fraction, fraction > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.1), value: value)
    }
}
