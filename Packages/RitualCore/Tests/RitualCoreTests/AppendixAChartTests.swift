import XCTest
@testable import RitualCore

/// Pins the owner chart of Appendix A (`BirthData.owner`: 16 Aug 2002 13:00 UT, Portland OR)
/// and the behaviour of `NatalChart.compute` around it.
final class AppendixAChartTests: XCTestCase {
    /// Contract tolerance for every Appendix A number.
    private let contractTolerance = 0.05
    /// Regression tolerance against the Swiss Ephemeris values the appendix was cast from.
    private let regressionTolerance = 0.001

    private var chart: NatalChart!

    override func setUp() {
        super.setUp()
        chart = NatalChart.compute(birth: .owner)
    }

    // MARK: - Numbers

    func testOwnerPositionsWithinContractTolerance() {
        XCTAssertEqual(chart.sun.longitude, 143.494, accuracy: contractTolerance)
        XCTAssertEqual(chart.moon.longitude, 247.694, accuracy: contractTolerance)
        XCTAssertEqual(chart.ascendant.longitude, 140.211, accuracy: contractTolerance)
        XCTAssertEqual(chart.midheaven.longitude, 39.468, accuracy: contractTolerance)
        XCTAssertEqual(chart.sunAltitude, -2.87, accuracy: 0.1)
        XCTAssertEqual(chart.prenatalSyzygy.longitude, 136.063, accuracy: contractTolerance)
        XCTAssertEqual(chart.lotOfFortune.longitude, 36.010, accuracy: contractTolerance)
        XCTAssertEqual(chart.lotOfSpirit.longitude, 244.411, accuracy: contractTolerance)
    }

    func testOwnerPositionsPinnedAgainstReference() {
        // pyswisseph 2.10.03 / Moshier, the source of Fixtures/ephemeris_vectors.json.
        XCTAssertEqual(chart.sun.longitude, 143.4936873, accuracy: regressionTolerance)
        XCTAssertEqual(chart.moon.longitude, 247.6943068, accuracy: regressionTolerance)
        XCTAssertEqual(chart.ascendant.longitude, 140.2108505, accuracy: regressionTolerance)
        XCTAssertEqual(chart.midheaven.longitude, 39.4682560, accuracy: regressionTolerance)
        XCTAssertEqual(chart.sunAltitude, -2.8676832, accuracy: 0.002)
        XCTAssertEqual(chart.prenatalSyzygy.jdUT, 2_452_495.302212375, accuracy: 10.0 / 86_400.0)
        XCTAssertEqual(chart.prenatalSyzygy.longitude, 136.0627599, accuracy: regressionTolerance)
        XCTAssertEqual(chart.lotOfFortune.longitude, 36.010231, accuracy: regressionTolerance)
        XCTAssertEqual(chart.lotOfSpirit.longitude, 244.411470, accuracy: regressionTolerance)
    }

    func testOwnerSigns() {
        XCTAssertEqual(chart.sun.sign, .leo)
        XCTAssertEqual(chart.sun.degrees, 23)
        XCTAssertEqual(chart.sun.minutes, 30)
        XCTAssertEqual(chart.moon.sign, .sagittarius)
        XCTAssertEqual(chart.moon.degrees, 7)
        XCTAssertEqual(chart.moon.minutes, 42)
        XCTAssertEqual(chart.ascendant.sign, .leo)
        XCTAssertEqual(chart.ascendant.degrees, 20)
        XCTAssertEqual(chart.ascendant.minutes, 13)
        XCTAssertEqual(chart.midheaven.sign, .taurus)
        XCTAssertEqual(chart.midheaven.degrees, 9)
        XCTAssertEqual(chart.midheaven.minutes, 28)
        XCTAssertEqual(chart.prenatalSyzygy.position.sign, .leo)
        XCTAssertEqual(chart.lotOfFortune.sign, .taurus)
        XCTAssertEqual(chart.lotOfSpirit.sign, .sagittarius)
    }

    func testOwnerSectSyzygyAndRuler() {
        XCTAssertEqual(chart.birth, .owner)
        XCTAssertEqual(chart.sect, .night)
        XCTAssertLessThan(chart.sunAltitude, 0)
        XCTAssertEqual(chart.prenatalSyzygy.kind, .newMoon)
        XCTAssertEqual(chart.prenatalSyzygy.formattedInstantUT, "2002-08-08 19:15 UT")
        XCTAssertLessThan(chart.prenatalSyzygy.jdUT, BirthData.owner.jdUT)
        XCTAssertEqual(chart.chartRuler, .sun)
        XCTAssertEqual(chart.rulerPosition, chart.sun)
        XCTAssertEqual(chart.rulerDignity, .domicile)
        XCTAssertTrue(chart.rulerRising)
        XCTAssertLessThanOrEqual(abs(Angle.wrap180(chart.sun.longitude - chart.ascendant.longitude)), NatalChart.risingOrbDegrees)
    }

    func testOwnerLotsFollowNightFormula() {
        // Night: Fortune = ASC + Sun − Moon, Spirit = ASC + Moon − Sun.
        let fortune = Angle.normalize(chart.ascendant.longitude + chart.sun.longitude - chart.moon.longitude)
        let spirit = Angle.normalize(chart.ascendant.longitude + chart.moon.longitude - chart.sun.longitude)
        XCTAssertEqual(chart.lotOfFortune.longitude, fortune, accuracy: 1e-9)
        XCTAssertEqual(chart.lotOfSpirit.longitude, spirit, accuracy: 1e-9)
    }

    // MARK: - Report

    func testAppendixAReportMatchesAppendixALineByLine() {
        // Labels, sign names and degree/minute strings verbatim; decimals to 0.01°
        // (see `AppendixAReportAssertions.swift`).
        let report = chart.appendixAReport()
        assertAppendixAReport(report)
        XCTAssertEqual(report.split(separator: "\n", omittingEmptySubsequences: false).count, 9)
        // The values the report prints are the chart's own, formatted to three decimals.
        XCTAssertTrue(report.hasPrefix("Sun \(chart.sun.formatted)\nMoon \(chart.moon.formatted)\n"))
        XCTAssertTrue(report.contains("\nLot of Fortune \(chart.lotOfFortune.formatted)\n"))
    }

    func testAppendixAReportAssertionRejectsWrongText() {
        // The line-by-line check must itself fail on a wrong sign name, a wrong minute
        // string or a longitude off by more than 0.01°: exercise the parser directly.
        let (text, value) = AppendixAReport.splitLongitude("Moon 7°42' Sagittarius (247.693°)")
        XCTAssertEqual(text, "Moon 7°42' Sagittarius")
        XCTAssertEqual(value, 247.693)
        XCTAssertNil(AppendixAReport.splitLongitude("Moon 7°42' Sagittarius (247.69°)").value, "three decimals required")
        XCTAssertNil(AppendixAReport.splitLongitude("Moon 7°42' Sagittarius").value)
        XCTAssertEqual(AppendixAReport.splitLongitude("Prenatal syzygy New Moon 2002-08-08 19:15 UT 16°04' Leo (136.063°)").text,
                       "Prenatal syzygy New Moon 2002-08-08 19:15 UT 16°04' Leo")
        XCTAssertEqual(AppendixAReport.parseAltitude("Sun altitude −2.87° → night chart"), -2.87)
        XCTAssertNil(AppendixAReport.parseAltitude("Sun altitude 2.87° → day chart"))
        XCTAssertTrue(AppendixAReport.altitudeRange.contains(-2.868))
        XCTAssertFalse(AppendixAReport.altitudeRange.contains(-2.85))
        XCTAssertEqual(AppendixAReport.longitudeLines.map(\.index), [0, 1, 2, 3, 5, 6, 7])
    }

    func testComputedChartIsDeterministicAndCodable() throws {
        let again = NatalChart.compute(birth: .owner)
        XCTAssertEqual(again, chart)
        let decoded = try JSONDecoder().decode(NatalChart.self, from: JSONEncoder().encode(chart))
        XCTAssertEqual(decoded, chart)
        XCTAssertEqual(decoded.appendixAReport(), chart.appendixAReport())
    }

    // MARK: - Sect, lots and ruler on other charts

    func testDayChartSwapsTheLots() {
        // 20:00 UT on the same day is 13:00 PDT in Portland: the Sun is high.
        let noon = BirthData(year: 2002, month: 8, day: 16, hourUT: 20, latitude: 45.5152, longitudeEast: -122.6784)
        let day = NatalChart.compute(birth: noon)
        XCTAssertEqual(day.sect, .day)
        XCTAssertGreaterThan(day.sunAltitude, 40)
        let fortune = Angle.normalize(day.ascendant.longitude + day.moon.longitude - day.sun.longitude)
        let spirit = Angle.normalize(day.ascendant.longitude + day.sun.longitude - day.moon.longitude)
        XCTAssertEqual(day.lotOfFortune.longitude, fortune, accuracy: 1e-9)
        XCTAssertEqual(day.lotOfSpirit.longitude, spirit, accuracy: 1e-9)
        XCTAssertTrue(day.appendixAReport().contains("→ day chart"))
        // The same prenatal New Moon precedes both instants (bisection converges to < 1 s).
        XCTAssertEqual(day.prenatalSyzygy.kind, chart.prenatalSyzygy.kind)
        XCTAssertEqual(day.prenatalSyzygy.jdUT, chart.prenatalSyzygy.jdUT, accuracy: 1.0 / 86_400.0)
        XCTAssertEqual(day.prenatalSyzygy.longitude, chart.prenatalSyzygy.longitude, accuracy: 1e-5)
    }

    func testRulerHandlingAcrossADayOfAscendants() {
        // Over 24 hours the Ascendant sweeps every sign, so both luminary-ruled and
        // non-luminary-ruled charts are exercised.
        var luminaryRuled = 0
        var otherRuled = 0
        for hour in stride(from: 0.0, to: 24.0, by: 1.0) {
            let birth = BirthData(year: 2002, month: 8, day: 16, hourUT: hour, latitude: 45.5152, longitudeEast: -122.6784)
            let sample = NatalChart.compute(birth: birth)
            XCTAssertEqual(sample.chartRuler, sample.ascendant.sign.ruler)
            XCTAssertEqual(sample.sect, sample.sunAltitude < 0 ? .night : .day)
            switch sample.chartRuler {
            case .sun:
                luminaryRuled += 1
                XCTAssertEqual(sample.rulerPosition, sample.sun)
                XCTAssertEqual(sample.rulerDignity, Planet.sun.dignity(in: sample.sun.sign))
                XCTAssertEqual(sample.rulerRising, abs(Angle.wrap180(sample.sun.longitude - sample.ascendant.longitude)) <= 15)
            case .moon:
                luminaryRuled += 1
                XCTAssertEqual(sample.rulerPosition, sample.moon)
                XCTAssertEqual(sample.rulerDignity, Planet.moon.dignity(in: sample.moon.sign))
                XCTAssertEqual(sample.rulerRising, abs(Angle.wrap180(sample.moon.longitude - sample.ascendant.longitude)) <= 15)
            case .saturn, .jupiter, .mars, .venus, .mercury:
                otherRuled += 1
                XCTAssertNil(sample.rulerPosition)
                XCTAssertEqual(sample.rulerDignity, .peregrine)
                XCTAssertFalse(sample.rulerRising)
                XCTAssertTrue(sample.appendixAReport().hasSuffix("— peregrine"))
            }
        }
        XCTAssertGreaterThan(luminaryRuled, 0)
        XCTAssertGreaterThan(otherRuled, 0)
    }

    func testMoonRuledChartUsesMoonDignity() throws {
        // Find an instant on the owner's birthday with a Cancer Ascendant (Moon-ruled),
        // scanning the cheap angle computation before casting the full chart.
        var found: BirthData?
        for minute in stride(from: 0.0, to: 1440.0, by: 5.0) {
            let birth = BirthData(year: 2002, month: 8, day: 16, hourUT: minute / 60.0, latitude: 45.5152, longitudeEast: -122.6784)
            let jdTT = JulianDay.terrestrialTime(fromUT: birth.jdUT)
            let ramc = Ephemeris.localApparentSiderealTime(jdUT: birth.jdUT, longitudeEast: birth.longitudeEast)
            let ascendant = Ephemeris.ascendant(ramc: ramc, latitude: birth.latitude, obliquity: Ephemeris.trueObliquity(jdTT: jdTT))
            if ZodiacSign.containing(longitude: ascendant) == .cancer {
                found = birth
                break
            }
        }
        let sample = NatalChart.compute(birth: try XCTUnwrap(found, "Cancer must rise at some point during the day"))
        XCTAssertEqual(sample.ascendant.sign, .cancer)
        XCTAssertEqual(sample.chartRuler, .moon)
        XCTAssertEqual(sample.rulerPosition, sample.moon)
        XCTAssertEqual(sample.moon.sign, .sagittarius)
        XCTAssertEqual(sample.rulerDignity, .peregrine, "the Moon in Sagittarius has no dignity")
        XCTAssertFalse(sample.rulerRising, "the Moon is far from a Cancer Ascendant")
    }

    // MARK: - Every fixture vector through the chart

    func testChartsForAllFixtureVectorsMatchReference() throws {
        let fixture = try EphemerisFixture.load()
        for vector in fixture.vectors {
            let parts = vector.date.split(separator: "-").compactMap { Int($0) }
            let birth = BirthData(year: parts[0], month: parts[1], day: parts[2], hourUT: vector.utHours, latitude: vector.lat, longitudeEast: vector.lon)
            let sample = NatalChart.compute(birth: birth)
            XCTAssertEqual(sample.birth.jdUT, vector.jdUT, accuracy: 1e-8)
            XCTAssertLessThanOrEqual(angularDifference(sample.sun.longitude, vector.sunLon), EphemerisTolerance.sun, vector.date)
            XCTAssertLessThanOrEqual(angularDifference(sample.moon.longitude, vector.moonLon), EphemerisTolerance.moon, vector.date)
            XCTAssertLessThanOrEqual(angularDifference(sample.ascendant.longitude, vector.asc), EphemerisTolerance.ascendant, vector.date)
            XCTAssertLessThanOrEqual(angularDifference(sample.midheaven.longitude, vector.mc), EphemerisTolerance.midheaven, vector.date)
            XCTAssertEqual(sample.sunAltitude, vector.sunAltTrue, accuracy: EphemerisTolerance.altitude, vector.date)
            XCTAssertEqual(sample.sect, vector.sunAltTrue < 0 ? .night : .day, vector.date)
            if let syzygy = vector.prenatalSyzygy {
                XCTAssertEqual(sample.prenatalSyzygy.kind, syzygy.kind == "new" ? .newMoon : .fullMoon, vector.date)
                XCTAssertEqual(sample.prenatalSyzygy.jdUT, syzygy.jd, accuracy: EphemerisTolerance.syzygyInstantDays, vector.date)
                XCTAssertLessThanOrEqual(angularDifference(sample.prenatalSyzygy.longitude, syzygy.lon), EphemerisTolerance.syzygyLongitude, vector.date)
            }
            XCTAssertEqual(sample.appendixAReport().split(separator: "\n", omittingEmptySubsequences: false).count, 9, vector.date)
        }
    }
}
