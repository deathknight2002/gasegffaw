import XCTest
@testable import RitualCore

/// End-to-end Appendix A pins on the **computed** owner chart: `NatalChart.compute(birth: .owner)`
/// flows through `AgrippaName`, `SigilPath` and `DaemonProfile.owner`.
///
/// The chart numbers are pinned in depth by `AppendixAChartTests` and the daemon derivation
/// on a hand-entered chart by `AppendixADaemonTests`; this class ties the two modules
/// together so that a regression in either the ephemeris or the derivation surfaces here.
final class AppendixATests: XCTestCase {
    /// Contract tolerance for every Appendix A number.
    private let tolerance = 0.05

    /// DRAND in Hebrew (logical order: Daleth, Resh, Aleph, Nun, Daleth).
    private static let expectedHebrew = "\u{05D3}\u{05E8}\u{05D0}\u{05E0}\u{05D3}"

    // MARK: - Chart

    func testOwnerChartPinsEveryAppendixANumber() {
        let chart = NatalChart.compute(birth: .owner)
        XCTAssertEqual(chart.sun.longitude, 143.494, accuracy: tolerance)
        XCTAssertEqual(chart.moon.longitude, 247.694, accuracy: tolerance)
        XCTAssertEqual(chart.ascendant.longitude, 140.211, accuracy: tolerance)
        XCTAssertEqual(chart.midheaven.longitude, 39.468, accuracy: tolerance)
        XCTAssertEqual(chart.sunAltitude, -2.87, accuracy: tolerance)
        XCTAssertEqual(chart.sect, .night)
        XCTAssertEqual(chart.prenatalSyzygy.kind, .newMoon)
        XCTAssertEqual(chart.prenatalSyzygy.formattedInstantUT, "2002-08-08 19:15 UT")
        XCTAssertEqual(chart.prenatalSyzygy.longitude, 136.063, accuracy: tolerance)
        XCTAssertEqual(chart.lotOfFortune.longitude, 36.010, accuracy: tolerance)
        XCTAssertEqual(chart.lotOfSpirit.longitude, 244.411, accuracy: tolerance)
        XCTAssertEqual(chart.chartRuler, .sun)
        XCTAssertEqual(chart.rulerDignity, .domicile)
        XCTAssertTrue(chart.rulerRising)
    }

    func testOwnerReportMatchesAppendixALineByLine() {
        // Nine lines; labels, sign names and degree/minute strings verbatim; the decimal
        // longitudes to 0.01° (the Meeus Moon prints 247.693° for the appendix's 247.694°).
        let report = NatalChart.compute(birth: .owner).appendixAReport()
        assertAppendixAReport(report)
        XCTAssertEqual(report.split(separator: "\n", omittingEmptySubsequences: false).count, 9)
    }

    // MARK: - Profile from the computed chart

    func testOwnerProfileIsDerivedFromTheComputedChart() {
        let profile = DaemonProfile.owner
        XCTAssertEqual(profile.chart, NatalChart.compute(birth: .owner))
        XCTAssertEqual(profile, DaemonProfile.derive(from: profile.chart))
        assertAppendixAReport(profile.chart.appendixAReport())
        XCTAssertEqual(profile.chart.appendixAReport(), NatalChart.compute(birth: .owner).appendixAReport())
    }

    func testOwnerNameIsDRAND() {
        let name = DaemonProfile.owner.name
        XCTAssertEqual(name.latin, "DRAND")
        XCTAssertEqual(name.hebrew, Self.expectedHebrew)
        XCTAssertEqual(name.letters, [.daleth, .resh, .aleph, .nun, .daleth])
        XCTAssertEqual(name.placements.count, 5)

        let expectedLetters: [HylegicalPlace: HebrewLetter] = [
            .sun: .daleth, .moon: .resh, .ascendant: .aleph, .fortune: .nun, .syzygy: .daleth,
        ]
        XCTAssertEqual(name.placements.map(\.place), HylegicalPlace.allCases)
        for placement in name.placements {
            XCTAssertEqual(placement.letter, expectedLetters[placement.place], "\(placement.place)")
            XCTAssertGreaterThanOrEqual(placement.offsetFromAscendant, 0)
            XCTAssertLessThan(placement.offsetFromAscendant, 360)
        }
        // The Ascendant is its own origin, so it always spells Aleph.
        XCTAssertEqual(name.placements[2].offsetFromAscendant, 0, accuracy: 1e-12)
    }

    func testOwnerSigilCellsFormAClosedLoopOnTheSunSquare() {
        let sigil = DaemonProfile.owner.sigil
        XCTAssertEqual(DaemonProfile.owner.kamea, Kamea.sun)
        XCTAssertEqual(sigil.kamea, Kamea.sun)
        XCTAssertEqual(sigil.reducedValues, [4, 20, 1, 5, 4])
        XCTAssertEqual(sigil.points.map { [$0.row, $0.col] }, [[6, 4], [4, 2], [1, 6], [6, 2], [6, 4]])
        XCTAssertTrue(sigil.isClosed)
        XCTAssertEqual(sigil.polyline.count, 5)
        XCTAssertEqual(sigil.startMarkerRadius, 0.045)
        XCTAssertEqual(sigil.endBarLength, 0.06)
    }

    func testOwnerAttributes() {
        let profile = DaemonProfile.owner
        XCTAssertEqual(profile.form, .leonine)
        XCTAssertEqual(profile.palette, .goldWhiteFire)
        XCTAssertEqual(profile.element, .fire)
        XCTAssertEqual(profile.motion, .expansiveArcing)
        XCTAssertEqual(profile.presence, .dominantUnhurried)
        XCTAssertEqual(profile.paletteLinearRGB.core, RVec3(1.0, 0.96, 0.85))
        XCTAssertEqual(profile.paletteLinearRGB.mid, RVec3(1.0, 0.62, 0.18))
        XCTAssertEqual(profile.paletteLinearRGB.edge, RVec3(0.75, 0.18, 0.02))
    }
}
