import XCTest
@testable import RitualCore

/// Appendix A pins for the daemon module, driven by a hand-built owner chart (the
/// astrology module's `NatalChart.compute` is covered separately by `AppendixATests`).
final class AppendixADaemonTests: XCTestCase {

    // MARK: - Fixtures

    /// The owner's chart with every Appendix A value entered by hand.
    static let ownerChart = NatalChart(
        birth: .owner,
        sun: ZodiacPosition(longitude: 143.494),
        moon: ZodiacPosition(longitude: 247.694),
        ascendant: ZodiacPosition(longitude: 140.211),
        midheaven: ZodiacPosition(longitude: 39.468),
        sunAltitude: -2.87,
        sect: .night,
        prenatalSyzygy: Syzygy(kind: .newMoon, jdUT: 2_452_495.302212375, longitude: 136.063),
        lotOfFortune: ZodiacPosition(longitude: 36.010),
        lotOfSpirit: ZodiacPosition(longitude: 244.411),
        chartRuler: .sun,
        rulerPosition: ZodiacPosition(longitude: 143.494),
        rulerDignity: .domicile,
        rulerRising: true
    )

    /// A copy of the owner chart with selected fields replaced.
    private static func variant(
        sun: Double? = nil, moon: Double? = nil, ascendant: Double? = nil, lotOfSpirit: Double? = nil,
        chartRuler: Planet? = nil, rulerDignity: Dignity? = nil, rulerRising: Bool? = nil
    ) -> NatalChart {
        let base = ownerChart
        return NatalChart(
            birth: base.birth,
            sun: sun.map(ZodiacPosition.init(longitude:)) ?? base.sun,
            moon: moon.map(ZodiacPosition.init(longitude:)) ?? base.moon,
            ascendant: ascendant.map(ZodiacPosition.init(longitude:)) ?? base.ascendant,
            midheaven: base.midheaven,
            sunAltitude: base.sunAltitude,
            sect: base.sect,
            prenatalSyzygy: base.prenatalSyzygy,
            lotOfFortune: base.lotOfFortune,
            lotOfSpirit: lotOfSpirit.map(ZodiacPosition.init(longitude:)) ?? base.lotOfSpirit,
            chartRuler: chartRuler ?? base.chartRuler,
            rulerPosition: base.rulerPosition,
            rulerDignity: rulerDignity ?? base.rulerDignity,
            rulerRising: rulerRising ?? base.rulerRising
        )
    }

    // MARK: - Name

    func testOwnerNameIsDRAND() {
        let name = AgrippaName.derive(from: Self.ownerChart)
        XCTAssertEqual(name.latin, "DRAND")
        XCTAssertEqual(name.hebrew, "דראנד")
        XCTAssertEqual(name.letters, [.daleth, .resh, .aleph, .nun, .daleth])
        XCTAssertEqual(name.values, [4, 200, 1, 50, 4])
        XCTAssertEqual(name.placements.count, 5)
        XCTAssertEqual(name.placements.map(\.place), [.sun, .moon, .ascendant, .fortune, .syzygy])
    }

    func testOwnerPlacementsCarryTheAppendixAOffsets() {
        let placements = AgrippaName.derive(from: Self.ownerChart).placements
        let expected: [(HylegicalPlace, Double, Double, HebrewLetter)] = [
            (.sun, 143.494, 3.283, .daleth),
            (.moon, 247.694, 107.483, .resh),
            (.ascendant, 140.211, 0.0, .aleph),
            (.fortune, 36.010, 255.799, .nun),
            (.syzygy, 136.063, 355.852, .daleth),
        ]
        for (placement, (place, longitude, offset, letter)) in zip(placements, expected) {
            XCTAssertEqual(placement.place, place)
            XCTAssertEqual(placement.longitude, longitude, accuracy: 1e-9)
            XCTAssertEqual(placement.offsetFromAscendant, offset, accuracy: 1e-9, "\(place) offset")
            XCTAssertEqual(placement.letter, letter, "\(place) letter")
            XCTAssertGreaterThanOrEqual(placement.offsetFromAscendant, 0)
            XCTAssertLessThan(placement.offsetFromAscendant, 360)
        }
    }

    // MARK: - Sigil

    func testOwnerSigilOnTheSunSquare() {
        let name = AgrippaName.derive(from: Self.ownerChart)
        let sigil = SigilPath.trace(name: name, kamea: .sun)
        XCTAssertEqual(sigil.kamea, Kamea.sun)
        XCTAssertEqual(sigil.reducedValues, [4, 20, 1, 5, 4])
        XCTAssertEqual(sigil.points.map { [$0.row, $0.col] }, [[6, 4], [4, 2], [1, 6], [6, 2], [6, 4]])
        XCTAssertEqual(sigil.points.map(\.value), [4, 20, 1, 5, 4])
        XCTAssertTrue(sigil.isClosed, "DRAND returns to (6,4)")
        XCTAssertEqual(sigil.startMarkerRadius, 0.045)
        XCTAssertEqual(sigil.endBarLength, 0.06)
    }

    func testOwnerSigilPolylineUsesNormalisedCellCentres() {
        let sigil = SigilPath.trace(name: AgrippaName.derive(from: Self.ownerChart), kamea: .sun)
        let expected = [
            RVec2(3.5 / 6, 5.5 / 6),  // (6,4)
            RVec2(1.5 / 6, 3.5 / 6),  // (4,2)
            RVec2(5.5 / 6, 0.5 / 6),  // (1,6)
            RVec2(1.5 / 6, 5.5 / 6),  // (6,2)
            RVec2(3.5 / 6, 5.5 / 6),  // (6,4)
        ]
        XCTAssertEqual(sigil.polyline.count, 5)
        for (actual, wanted) in zip(sigil.polyline, expected) {
            XCTAssertEqual(actual.x, wanted.x, accuracy: 1e-12)
            XCTAssertEqual(actual.y, wanted.y, accuracy: 1e-12)
        }
        XCTAssertEqual(sigil.polyline, sigil.points.map(\.normalized))
        XCTAssertEqual(sigil.startMarkerCenter, expected[0])

        // The last segment (6,2)→(6,4) runs along +x, so the end bar is vertical, centred
        // on (6,4), 0.06 long — and it is present even though the path is closed.
        guard let bar = sigil.endBarSegment else {
            return XCTFail("closed path still carries an end bar")
        }
        XCTAssertEqual(bar.start.x, 3.5 / 6, accuracy: 1e-12)
        XCTAssertEqual(bar.end.x, 3.5 / 6, accuracy: 1e-12)
        XCTAssertEqual(abs(bar.end.y - bar.start.y), 0.06, accuracy: 1e-12)
        XCTAssertEqual((bar.start.y + bar.end.y) / 2, 5.5 / 6, accuracy: 1e-12)
    }

    func testSigilCodableRoundTrip() throws {
        let sigil = SigilPath.trace(name: AgrippaName.derive(from: Self.ownerChart), kamea: .sun)
        let decoded = try JSONDecoder().decode(SigilPath.self, from: JSONEncoder().encode(sigil))
        XCTAssertEqual(decoded, sigil)
        XCTAssertTrue(decoded.isClosed)
        XCTAssertEqual(decoded.polyline, sigil.polyline)
    }

    // MARK: - Profile

    func testOwnerProfileAttributes() {
        let profile = DaemonProfile.derive(from: Self.ownerChart)
        XCTAssertEqual(profile.chart, Self.ownerChart)
        XCTAssertEqual(profile.name.latin, "DRAND")
        XCTAssertEqual(profile.name.hebrew, "דראנד")
        XCTAssertEqual(profile.kamea, Kamea.sun, "the chart ruler is the Sun, so the sigil sits on the Sun square")
        XCTAssertEqual(profile.sigil, SigilPath.trace(name: profile.name, kamea: .sun))
        XCTAssertEqual(profile.sigil.points.map { [$0.row, $0.col] }, [[6, 4], [4, 2], [1, 6], [6, 2], [6, 4]])
        XCTAssertTrue(profile.sigil.isClosed)
        XCTAssertEqual(profile.form, .leonine)
        XCTAssertEqual(profile.palette, .goldWhiteFire)
        XCTAssertEqual(profile.element, .fire)
        XCTAssertEqual(profile.motion, .expansiveArcing)
        XCTAssertEqual(profile.presence, .dominantUnhurried)
    }

    func testOwnerPaletteLinearRGB() {
        let rgb = DaemonProfile.derive(from: Self.ownerChart).paletteLinearRGB
        XCTAssertEqual(rgb.core, RVec3(1.0, 0.96, 0.85))
        XCTAssertEqual(rgb.mid, RVec3(1.0, 0.62, 0.18))
        XCTAssertEqual(rgb.edge, RVec3(0.75, 0.18, 0.02))
        XCTAssertEqual(DaemonPalette.goldWhiteFire.linearRGB.core, rgb.core)
        for palette in DaemonPalette.allCases {
            let ramp = palette.linearRGB
            for channel in [ramp.core, ramp.mid, ramp.edge] {
                for component in [channel.x, channel.y, channel.z] {
                    XCTAssertGreaterThanOrEqual(component, 0, "\(palette)")
                    XCTAssertLessThanOrEqual(component, 1, "\(palette)")
                }
            }
        }
    }

    func testProfileIsDeterministicEquatableAndCodable() throws {
        let first = DaemonProfile.derive(from: Self.ownerChart)
        let second = DaemonProfile.derive(from: Self.ownerChart)
        XCTAssertEqual(first, second)
        let decoded = try JSONDecoder().decode(DaemonProfile.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(decoded, first)
        XCTAssertEqual(decoded.name.latin, "DRAND")
        XCTAssertEqual(decoded.chart.appendixAReport(), Self.ownerChart.appendixAReport())
    }

    // MARK: - Attribute sources

    func testFormFollowsTheSunSign() {
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(sun: 15)).form, .ramHorned)
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(sun: 275)).form, .goatHorned)
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(sun: 359.9)).form, .finned)
    }

    func testMotionFollowsTheMoonSign() {
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(moon: 100)).motion, .tidalSway)
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(moon: 200)).motion, .balancedGlide)
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(moon: 340)).motion, .flowingDissolve)
    }

    func testElementFollowsTheLotOfSpiritSign() {
        // Sun stays in Leo (fire) — the element must come from the Lot of Spirit.
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(lotOfSpirit: 45)).element, .earth, "Taurus")
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(lotOfSpirit: 75)).element, .air, "Gemini")
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(lotOfSpirit: 225)).element, .water, "Scorpio")
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(lotOfSpirit: 244.411)).element, .fire, "Sagittarius")
    }

    func testPaletteAndKameaFollowTheChartRuler() {
        let lunar = DaemonProfile.derive(from: Self.variant(chartRuler: .moon))
        XCTAssertEqual(lunar.palette, .silverBlue)
        XCTAssertEqual(lunar.kamea, Kamea.moon)
        XCTAssertEqual(lunar.sigil.kamea.order, 9)
        XCTAssertEqual(lunar.sigil.reducedValues, [4, 20, 1, 50, 4], "on the 9×9 square 50 fits without reduction")
        let saturnine = DaemonProfile.derive(from: Self.variant(chartRuler: .saturn))
        XCTAssertEqual(saturnine.palette, .leadBlack)
        XCTAssertEqual(saturnine.kamea, Kamea.saturn)
        XCTAssertEqual(saturnine.sigil.reducedValues, [4, 2, 1, 5, 4], "200 → 20 → 2 on the 3×3 square")
        for planet in Planet.allCases {
            let profile = DaemonProfile.derive(from: Self.variant(chartRuler: planet))
            XCTAssertEqual(profile.palette, DaemonPalette.forPlanet(planet))
            XCTAssertEqual(profile.kamea, Kamea.forPlanet(planet))
        }
    }

    func testPresenceFollowsRulerDignityAndRising() {
        XCTAssertEqual(DaemonPresence.from(dignity: .domicile, rising: true), .dominantUnhurried)
        XCTAssertEqual(DaemonPresence.from(dignity: .domicile, rising: false), .dominantUnhurried)
        XCTAssertEqual(DaemonPresence.from(dignity: .exaltation, rising: true), .exaltedRadiant)
        XCTAssertEqual(DaemonPresence.from(dignity: .exaltation, rising: false), .exaltedRadiant)
        XCTAssertEqual(DaemonPresence.from(dignity: .detriment, rising: false), .subdued)
        XCTAssertEqual(DaemonPresence.from(dignity: .detriment, rising: true), .subdued)
        XCTAssertEqual(DaemonPresence.from(dignity: .fall, rising: false), .wary)
        XCTAssertEqual(DaemonPresence.from(dignity: .peregrine, rising: false), .restless)
        XCTAssertEqual(DaemonPresence.from(dignity: .peregrine, rising: true), .restless)

        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(rulerDignity: .domicile, rulerRising: false)).presence, .dominantUnhurried)
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(rulerDignity: .exaltation)).presence, .exaltedRadiant)
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(rulerDignity: .detriment)).presence, .subdued)
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(rulerDignity: .fall)).presence, .wary)
        XCTAssertEqual(DaemonProfile.derive(from: Self.variant(rulerDignity: .peregrine, rulerRising: false)).presence, .restless)
    }
}
