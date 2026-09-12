import Foundation

// MARK: - Palette colours

extension DaemonPalette {
    /// Linear-RGB colour ramp of the palette: `core` is the hottest/brightest tone,
    /// `mid` the body colour and `edge` the cool fringe. Gold-white fire (Sun) is
    /// (1.0, 0.96, 0.85), (1.0, 0.62, 0.18), (0.75, 0.18, 0.02).
    public var linearRGB: (core: RVec3, mid: RVec3, edge: RVec3) {
        switch self {
        case .goldWhiteFire:
            return (RVec3(1.0, 0.96, 0.85), RVec3(1.0, 0.62, 0.18), RVec3(0.75, 0.18, 0.02))
        case .silverBlue:
            return (RVec3(0.94, 0.97, 1.0), RVec3(0.55, 0.70, 0.95), RVec3(0.10, 0.20, 0.55))
        case .quicksilver:
            return (RVec3(0.97, 0.98, 1.0), RVec3(0.66, 0.70, 0.78), RVec3(0.22, 0.25, 0.32))
        case .copperGreen:
            return (RVec3(1.0, 0.92, 0.76), RVec3(0.85, 0.45, 0.20), RVec3(0.05, 0.42, 0.30))
        case .ironRed:
            return (RVec3(1.0, 0.84, 0.70), RVec3(0.85, 0.14, 0.05), RVec3(0.28, 0.04, 0.02))
        case .tinViolet:
            return (RVec3(0.96, 0.92, 1.0), RVec3(0.55, 0.35, 0.85), RVec3(0.18, 0.07, 0.40))
        case .leadBlack:
            return (RVec3(0.62, 0.62, 0.66), RVec3(0.20, 0.20, 0.24), RVec3(0.02, 0.02, 0.03))
        }
    }
}

// MARK: - Presence

extension DaemonPresence {
    /// Presence from the chart ruler's essential dignity and whether it is rising:
    /// domicile → dominant, unhurried (rising or not); exaltation → exalted, radiant;
    /// detriment → subdued; fall → wary; peregrine → restless.
    ///
    /// - Parameters:
    ///   - dignity: Dignity of the chart ruler.
    ///   - rising: Whether the ruler is within 15° of the Ascendant.
    public static func from(dignity: Dignity, rising: Bool) -> DaemonPresence {
        switch dignity {
        case .domicile: return .dominantUnhurried
        case .exaltation: return .exaltedRadiant
        case .detriment: return .subdued
        case .fall: return .wary
        case .peregrine: return .restless
        }
    }
}

// MARK: - DaemonProfile

/// Everything the renderer needs to know about the daemon, derived deterministically
/// from a natal chart: name, kamea, sigil and the five appearance attributes.
///
/// Attribute sources: form ← Sun sign; palette ← chart ruler; element ← sign of the
/// Lot of Spirit; motion ← Moon sign; presence ← ruler dignity and rising. The sigil is
/// traced on the chart ruler's kamea (the Sun square for the owner).
public struct DaemonProfile: Codable, Sendable, Equatable {
    /// The chart the profile was derived from.
    public let chart: NatalChart
    /// The Agrippa name.
    public let name: AgrippaName
    /// The chart ruler's magic square.
    public let kamea: Kamea
    /// The name traced on ``kamea``.
    public let sigil: SigilPath
    /// Bodily form (Sun sign).
    public let form: DaemonForm
    /// Colour palette (chart ruler).
    public let palette: DaemonPalette
    /// Element (Lot of Spirit's sign).
    public let element: DaemonElement
    /// Movement style (Moon sign).
    public let motion: DaemonMotion
    /// Bearing (ruler dignity + rising).
    public let presence: DaemonPresence

    /// Memberwise initialiser; prefer ``derive(from:)``.
    ///
    /// - Parameters:
    ///   - chart: Source chart.
    ///   - name: Agrippa name.
    ///   - kamea: Square the sigil is traced on.
    ///   - sigil: Traced sigil.
    ///   - form: Bodily form.
    ///   - palette: Colour palette.
    ///   - element: Element.
    ///   - motion: Movement style.
    ///   - presence: Bearing.
    public init(
        chart: NatalChart,
        name: AgrippaName,
        kamea: Kamea,
        sigil: SigilPath,
        form: DaemonForm,
        palette: DaemonPalette,
        element: DaemonElement,
        motion: DaemonMotion,
        presence: DaemonPresence
    ) {
        self.chart = chart
        self.name = name
        self.kamea = kamea
        self.sigil = sigil
        self.form = form
        self.palette = palette
        self.element = element
        self.motion = motion
        self.presence = presence
    }

    /// Linear-RGB ramp of ``palette`` (see ``DaemonPalette/linearRGB``).
    public var paletteLinearRGB: (core: RVec3, mid: RVec3, edge: RVec3) {
        palette.linearRGB
    }

    /// Derives the full profile from a chart.
    ///
    /// - Parameter chart: The natal chart.
    public static func derive(from chart: NatalChart) -> DaemonProfile {
        let name = AgrippaName.derive(from: chart)
        let kamea = Kamea.forPlanet(chart.chartRuler)
        let sigil = SigilPath.trace(name: name, kamea: kamea)
        return DaemonProfile(
            chart: chart,
            name: name,
            kamea: kamea,
            sigil: sigil,
            form: DaemonForm.forSign(chart.sun.sign),
            palette: DaemonPalette.forPlanet(chart.chartRuler),
            element: DaemonElement(chartElement: chart.lotOfSpirit.sign.element),
            motion: DaemonMotion.forSign(chart.moon.sign),
            presence: DaemonPresence.from(dignity: chart.rulerDignity, rising: chart.rulerRising)
        )
    }

    /// The owner's daemon: `derive(from: NatalChart.compute(birth: .owner))` — DRAND on
    /// the Sun square, leonine, gold-white fire, fire, expansive arcing, dominant unhurried.
    public static let owner = DaemonProfile.derive(from: NatalChart.compute(birth: .owner))
}
