import XCTest
@testable import RitualCore

/// Pins for the shared foundation types: vectors, angles, PCG32, the CPU/GPU hash,
/// zodiac formatting, ritual enumerations and the Appendix A report.
final class FoundationTests: XCTestCase {

    // MARK: - RVec2 / RVec3

    func testRVec2Arithmetic() {
        let a = RVec2(1, 2)
        let b = RVec2(3, -4)
        XCTAssertEqual(a + b, RVec2(4, -2))
        XCTAssertEqual(a - b, RVec2(-2, 6))
        XCTAssertEqual(-a, RVec2(-1, -2))
        XCTAssertEqual(a * 2, RVec2(2, 4))
        XCTAssertEqual(2 * a, RVec2(2, 4))
        XCTAssertEqual(a * b, RVec2(3, -8))
        XCTAssertEqual(b / 2, RVec2(1.5, -2))
        XCTAssertEqual(a.dot(b), -5)
        XCTAssertEqual(b.length, 5)
        XCTAssertEqual(b.lengthSquared, 25)
        XCTAssertEqual(b.normalized, RVec2(0.6, -0.8))
        XCTAssertEqual(RVec2.zero.normalized, .zero, "zero vector must normalise to zero, not NaN")
        XCTAssertEqual(RVec2.lerp(a, b, 0.5), RVec2(2, -1))
        XCTAssertEqual(a.lerp(to: b, t: 0), a)
        XCTAssertEqual(a.lerp(to: b, t: 1), b)
        XCTAssertEqual(a.distance(to: RVec2(4, 6)), 5)

        var c = a
        c += b
        c *= 2
        c -= RVec2(1, 1)
        c /= 2
        XCTAssertEqual(c, RVec2(3.5, -2.5))
    }

    func testRVec3ArithmeticAndCross() {
        let a = RVec3(1, 2, 3)
        let b = RVec3(-2, 0.5, 4)
        XCTAssertEqual(a + b, RVec3(-1, 2.5, 7))
        XCTAssertEqual(a - b, RVec3(3, 1.5, -1))
        XCTAssertEqual(-a, RVec3(-1, -2, -3))
        XCTAssertEqual(a * 2, RVec3(2, 4, 6))
        XCTAssertEqual(0.5 * a, RVec3(0.5, 1, 1.5))
        XCTAssertEqual(a * b, RVec3(-2, 1, 12))
        XCTAssertEqual(a / 2, RVec3(0.5, 1, 1.5))
        XCTAssertEqual(a.dot(b), 11)
        XCTAssertEqual(RVec3(2, 3, 6).length, 7)
        XCTAssertEqual(RVec3(2, 3, 6).normalized, RVec3(2.0 / 7, 3.0 / 7, 6.0 / 7))
        XCTAssertEqual(RVec3.zero.normalized, .zero)
        XCTAssertEqual(RVec3.lerp(a, b, 0.5), RVec3(-0.5, 1.25, 3.5))

        // Right-handed basis: x × y = z, y × z = x, z × x = y.
        let x = RVec3(1, 0, 0), y = RVec3(0, 1, 0), z = RVec3(0, 0, 1)
        XCTAssertEqual(x.cross(y), z)
        XCTAssertEqual(y.cross(z), x)
        XCTAssertEqual(z.cross(x), y)
        XCTAssertEqual(y.cross(x), -z)
        XCTAssertEqual(a.cross(b), RVec3(6.5, -10, 4.5))
    }

    func testRVecCodableRoundTrip() throws {
        let v2 = RVec2(0.25, -1.5)
        let v3 = RVec3(1e-3, 2.5, -7)
        let decoded2 = try JSONDecoder().decode(RVec2.self, from: JSONEncoder().encode(v2))
        let decoded3 = try JSONDecoder().decode(RVec3.self, from: JSONEncoder().encode(v3))
        XCTAssertEqual(decoded2, v2)
        XCTAssertEqual(decoded3, v3)
        XCTAssertEqual(Set([v2, v2]).count, 1, "RVec2 must be Hashable")
        XCTAssertEqual(Set([v3, v3]).count, 1, "RVec3 must be Hashable")
    }

    // MARK: - Angle

    func testAngleNormalize() {
        XCTAssertEqual(Angle.normalize(0), 0)
        XCTAssertEqual(Angle.normalize(360), 0)
        XCTAssertEqual(Angle.normalize(720), 0)
        XCTAssertEqual(Angle.normalize(-360), 0)
        XCTAssertEqual(Angle.normalize(-1), 359)
        XCTAssertEqual(Angle.normalize(361), 1)
        XCTAssertEqual(Angle.normalize(-725), 355)
        XCTAssertEqual(Angle.normalize(359.5), 359.5)
        XCTAssertEqual(Angle.normalize(-0.0).sign, .plus, "negative zero must normalise to +0")
        // A negative value so tiny that r + 360 rounds to exactly 360 must fold back to 0.
        let result = Angle.normalize(-1e-20)
        XCTAssertGreaterThanOrEqual(result, 0)
        XCTAssertLessThan(result, 360)
        for degrees in stride(from: -1080.0, through: 1080.0, by: 37.25) {
            let n = Angle.normalize(degrees)
            XCTAssertGreaterThanOrEqual(n, 0)
            XCTAssertLessThan(n, 360)
            XCTAssertEqual((n - degrees).truncatingRemainder(dividingBy: 360), 0, accuracy: 1e-9)
        }
    }

    func testAngleWrap180() {
        XCTAssertEqual(Angle.wrap180(0), 0)
        XCTAssertEqual(Angle.wrap180(180), 180, "180 stays 180 (range is (-180, 180])")
        XCTAssertEqual(Angle.wrap180(-180), 180, "-180 maps to +180")
        XCTAssertEqual(Angle.wrap180(540), 180)
        XCTAssertEqual(Angle.wrap180(181), -179)
        XCTAssertEqual(Angle.wrap180(-181), 179)
        XCTAssertEqual(Angle.wrap180(359), -1)
        XCTAssertEqual(Angle.wrap180(-359), 1)
        XCTAssertEqual(Angle.wrap180(90), 90)
        XCTAssertEqual(Angle.wrap180(270), -90)
        XCTAssertEqual(Angle.wrap180(-90), -90)
        for degrees in stride(from: -1080.0, through: 1080.0, by: 41.5) {
            let w = Angle.wrap180(degrees)
            XCTAssertGreaterThan(w, -180)
            XCTAssertLessThanOrEqual(w, 180)
        }
    }

    func testAngleRadianConversion() {
        XCTAssertEqual(Angle.deg2rad(180), Double.pi, accuracy: 1e-15)
        XCTAssertEqual(Angle.rad2deg(Double.pi / 2), 90, accuracy: 1e-12)
        XCTAssertEqual(Angle.rad2deg(Angle.deg2rad(33.3)), 33.3, accuracy: 1e-12)
    }

    // MARK: - PCG32

    /// Reference outputs from the minimal C `pcg32_srandom_r(42, 54)` demo. If these fail
    /// the generator is wrong; fix the generator, never the pins.
    func testPCG32ReferencePins() {
        var rng = SeededRNG(seed: 42, stream: 54)
        let expected: [UInt32] = [0xa15c_02b7, 0x7b47_f409, 0xba1d_3330, 0x83d2_f293, 0xbfa4_784b]
        let produced = (0..<5).map { _ in rng.nextU32() }
        XCTAssertEqual(produced, expected)
    }

    func testPCG32Next64ConcatenatesTwoDrawsHighFirst() {
        var rng = SeededRNG(seed: 42, stream: 54)
        XCTAssertEqual(rng.next(), 0xa15c_02b7_7b47_f409)
        XCTAssertEqual(rng.next(), 0xba1d_3330_83d2_f293)
    }

    func testPCG32DeterminismAndStreams() {
        var a = SeededRNG(seed: 7, stream: 3)
        var b = SeededRNG(seed: 7, stream: 3)
        var c = SeededRNG(seed: 7, stream: 4)
        let sa = (0..<16).map { _ in a.nextU32() }
        let sb = (0..<16).map { _ in b.nextU32() }
        let sc = (0..<16).map { _ in c.nextU32() }
        XCTAssertEqual(sa, sb, "same seed and stream must replay identically")
        XCTAssertNotEqual(sa, sc, "different streams must diverge")
        XCTAssertEqual(a, b, "generators are Equatable by state")
    }

    func testPCG32UnitAndRangeBounds() {
        var rng = SeededRNG(seed: 1234)
        for _ in 0..<2000 {
            let u = rng.nextUnit()
            XCTAssertGreaterThanOrEqual(u, 0)
            XCTAssertLessThan(u, 1)
            let r = rng.nextRange(-2.5, 4)
            XCTAssertGreaterThanOrEqual(r, -2.5)
            XCTAssertLessThan(r, 4)
        }
    }

    func testPCG32CodableRoundTripPreservesSequence() throws {
        var original = SeededRNG(seed: 99, stream: 5)
        _ = original.nextU32()
        _ = original.nextU32()
        var restored = try JSONDecoder().decode(SeededRNG.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        let fromOriginal = (0..<8).map { _ in original.nextU32() }
        let fromRestored = (0..<8).map { _ in restored.nextU32() }
        XCTAssertEqual(fromOriginal, fromRestored)
    }

    // MARK: - Hash

    /// Pins for `Hash.u32`. These values were produced by this implementation of the
    /// contract formula and cross-checked with an independent Python transcription.
    /// `Shaders/Common.h::hash_u32` MUST produce exactly these for the same inputs.
    func testHashU32Pins() {
        XCTAssertEqual(Hash.u32(1, 2, 3, 4), 0x8f0b_a4b8)
        XCTAssertEqual(Hash.u32(0, 0, 0, 0), 0x41f3_9e5e)
        XCTAssertEqual(Hash.u32(UInt64.max, 7, 8, 9), 0x57ea_7fbb)
    }

    /// The contract formula folds `seed_hi` into `seed_lo ^ salt` with a plain XOR before
    /// any mixing, so a seed and its word-swapped twin (`1` and `1 << 32`) collide by
    /// construction. The high word still has to participate, which is what this checks.
    func testHashSeedWordsBothMatter() {
        XCTAssertNotEqual(Hash.u32(0x0000_0001_0000_0000, 1, 1, 1), Hash.u32(0, 1, 1, 1),
                          "the high 32 bits of the seed must feed the hash")
        XCTAssertNotEqual(Hash.u32(1, 1, 1, 1), Hash.u32(0, 1, 1, 1))
        XCTAssertEqual(Hash.u32(0x0000_0000_0000_0001, 1, 1, 1), Hash.u32(0x0000_0001_0000_0000, 1, 1, 1),
                       "documented property of the contract formula: lo/hi seed words are XOR-symmetric")
        XCTAssertNotEqual(Hash.u32(5, 1, 2, 3), Hash.u32(5, 1, 2, 4))
        XCTAssertNotEqual(Hash.u32(5, 1, 2, 3), Hash.u32(5, 1, 3, 3))
        XCTAssertNotEqual(Hash.u32(5, 1, 2, 3), Hash.u32(5, 2, 2, 3))
    }

    /// Documented property (CORE_API, ARCHITECTURE §6): only `seed_lo ^ seed_hi` enters the
    /// first avalanche, so seeds with equal XOR of their words produce identical streams
    /// for every key — a seed carries 32 bits of entropy into `Hash`.
    func testHashSeedEntropyIsTheXorOfTheSeedWords() {
        let keys: [(UInt32, UInt32, UInt32)] = [(1, 2, 3), (0, 0, 0), (0xdead, 0xbeef, 7), (UInt32.max, 5, 9)]
        for (a, b, c) in keys {
            XCTAssertEqual(Hash.u32(0x0000_0001_0000_0001, a, b, c), Hash.u32(0, a, b, c))
            XCTAssertEqual(Hash.u32(1 << 32, a, b, c), Hash.u32(1, a, b, c))
            XCTAssertEqual(Hash.u32(0xffff_ffff_0000_0000, a, b, c), Hash.u32(0x0000_0000_ffff_ffff, a, b, c))
            XCTAssertEqual(Hash.u32(0x1234_5678_9abc_def0, a, b, c), Hash.u32(UInt64(0x1234_5678 ^ 0x9abc_def0), a, b, c))
            XCTAssertNotEqual(Hash.u32(0x0000_0001_0000_0000, a, b, c), Hash.u32(0x0000_0002_0000_0000, a, b, c),
                              "distinct XORs still give distinct streams")
        }
    }

    func testHashUnitIsU32Over2Pow32() {
        let u = Hash.unit(1, 2, 3, 4)
        XCTAssertEqual(u, Double(0x8f0b_a4b8) / 4_294_967_296.0)
        for k in 0..<500 {
            let value = Hash.unit(42, UInt32(k), 9, 7)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
        }
    }

    // MARK: - Zodiac

    func testZodiacPositionFormatting() {
        XCTAssertEqual(ZodiacPosition(longitude: 143.494).formatted, "23°30' Leo (143.494°)")
        XCTAssertEqual(ZodiacPosition(longitude: 36.010).formatted, "6°01' Taurus (36.010°)")
        XCTAssertEqual(ZodiacPosition(longitude: 0).formatted, "0°00' Aries (0.000°)")
        XCTAssertEqual(ZodiacPosition(longitude: 247.694).formatted, "7°42' Sagittarius (247.694°)")
        XCTAssertEqual(ZodiacPosition(longitude: -30).formatted, "0°00' Pisces (330.000°)")
        XCTAssertEqual(ZodiacPosition(longitude: 400).formatted, "10°00' Taurus (40.000°)")
    }

    /// Minute rounding carries across the sign boundary: 29°59.994′ Aries rounds to 30°00′,
    /// which is 0°00′ Taurus. The exact `sign` stays Aries; the rounded decomposition
    /// (`roundedSign`, `degrees`, `minutes`) and `formatted` advance together, and the
    /// decimal never prints 360.000.
    func testZodiacPositionMinuteCarryAdvancesTheSign() {
        let position = ZodiacPosition(longitude: 29.9999)
        XCTAssertEqual(position.sign, .aries)
        XCTAssertEqual(position.roundedSign, .taurus)
        XCTAssertEqual(position.degrees, 0)
        XCTAssertEqual(position.minutes, 0)
        XCTAssertEqual(position.formatted, "0°00' Taurus (30.000°)")

        XCTAssertEqual(ZodiacPosition(longitude: 149.995).formatted, "0°00' Virgo (149.995°)")
        XCTAssertEqual(ZodiacPosition(longitude: 149.9999).formatted, "0°00' Virgo (150.000°)")
        XCTAssertEqual(ZodiacPosition(longitude: 89.99999).formatted, "0°00' Cancer (90.000°)")
        let wrap = ZodiacPosition(longitude: 359.9999)
        XCTAssertEqual(wrap.sign, .pisces)
        XCTAssertEqual(wrap.roundedSign, .aries)
        XCTAssertEqual(wrap.degrees, 0)
        XCTAssertEqual(wrap.minutes, 0)
        XCTAssertEqual(wrap.formatted, "0°00' Aries (0.000°)")

        let halfMinute = ZodiacPosition(longitude: 120 + 12.0 + 59.5 / 60.0)  // 12°59.5' Leo
        XCTAssertEqual(halfMinute.degrees, 13)
        XCTAssertEqual(halfMinute.minutes, 0)
        XCTAssertEqual(halfMinute.roundedSign, .leo)
        // Just under half a minute below the boundary does not carry.
        XCTAssertEqual(ZodiacPosition(longitude: 29.0 + 59.4 / 60.0).formatted, "29°59' Aries (29.990°)")
        for sign in ZodiacSign.allCases {
            let inside = ZodiacPosition(longitude: sign.startLongitude + 15.5)
            XCTAssertEqual(inside.roundedSign, inside.sign)
            XCTAssertEqual(inside.degrees, 15)
            XCTAssertEqual(inside.minutes, 30)
        }
    }

    /// Non-finite input must never reach an `Int(Double)` conversion: positions map to
    /// 0° Aries, the calendar and ΔT return sentinels, and `NatalChart.compute` sanitises
    /// the birth data (documented as 0 for each non-finite field) so the chart stays
    /// defined and encodable.
    func testNonFiniteAstrologyInputsDoNotTrap() throws {
        for value in [Double.nan, .infinity, -.infinity] {
            let position = ZodiacPosition(longitude: value)
            XCTAssertEqual(position.longitude, 0)
            XCTAssertEqual(position.sign, .aries)
            XCTAssertEqual(position.roundedSign, .aries)
            XCTAssertEqual(position.formatted, "0°00' Aries (0.000°)")
            XCTAssertEqual(ZodiacSign.containing(longitude: value), .aries)
            XCTAssertTrue(JulianDay.deltaT(jd: value).isNaN)
            let calendar = JulianDay.toCalendar(value)
            XCTAssertEqual(calendar.year, 0)
            XCTAssertEqual(calendar.month, 0)
            XCTAssertEqual(calendar.day, 0)
            XCTAssertEqual(Syzygy(kind: .newMoon, jdUT: value, longitude: 10).formattedInstantUT, "????-??-?? ??:?? UT")
        }
        XCTAssertTrue(BirthData.owner.isFinite)
        XCTAssertEqual(BirthData.owner.sanitized, BirthData.owner)

        var nanHour = BirthData.owner
        nanHour.hourUT = .nan
        XCTAssertFalse(nanHour.isFinite)
        var zeroHour = BirthData.owner
        zeroHour.hourUT = 0
        XCTAssertEqual(nanHour.sanitized, zeroHour)
        XCTAssertEqual(NatalChart.compute(birth: nanHour), NatalChart.compute(birth: zeroHour))

        var infiniteLatitude = BirthData.owner
        infiniteLatitude.latitude = .infinity
        var zeroLatitude = BirthData.owner
        zeroLatitude.latitude = 0
        let chart = NatalChart.compute(birth: infiniteLatitude)
        XCTAssertEqual(chart, NatalChart.compute(birth: zeroLatitude))
        XCTAssertEqual(chart.birth, zeroLatitude, "the chart records the sanitised birth data")
        XCTAssertNoThrow(try JSONEncoder().encode(chart))
        XCTAssertFalse(chart.appendixAReport().contains("nan"))

        var nanLongitude = BirthData.owner
        nanLongitude.longitudeEast = -.infinity
        XCTAssertNoThrow(try JSONEncoder().encode(NatalChart.compute(birth: nanLongitude)))
    }

    func testZodiacPositionDecomposition() {
        let position = ZodiacPosition(longitude: 244.411)
        XCTAssertEqual(position.sign, .sagittarius)
        XCTAssertEqual(position.degreeInSign, 4.411, accuracy: 1e-9)
        XCTAssertEqual(position.degrees, 4)
        XCTAssertEqual(position.minutes, 25)
        XCTAssertEqual(ZodiacPosition(longitude: 359.9999).sign, .pisces)
        XCTAssertEqual(ZodiacPosition(longitude: 360).sign, .aries)
        for sign in ZodiacSign.allCases {
            XCTAssertEqual(ZodiacPosition(longitude: sign.startLongitude).sign, sign)
            XCTAssertEqual(ZodiacPosition(longitude: sign.startLongitude + 29.999).sign, sign)
        }
    }

    func testZodiacPositionCodableNormalises() throws {
        let data = Data(#"{"longitude":-90}"#.utf8)
        let decoded = try JSONDecoder().decode(ZodiacPosition.self, from: data)
        XCTAssertEqual(decoded.longitude, 270)
        let reencoded = try JSONDecoder().decode(ZodiacPosition.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(reencoded, decoded)
    }

    func testZodiacSignTables() {
        XCTAssertEqual(ZodiacSign.allCases.count, 12)
        XCTAssertEqual(ZodiacSign.leo.name, "Leo")
        XCTAssertEqual(ZodiacSign.sagittarius.abbreviation, "Sag")
        XCTAssertEqual(ZodiacSign.leo.ruler, .sun)
        XCTAssertEqual(ZodiacSign.cancer.ruler, .moon)
        XCTAssertEqual(ZodiacSign.aquarius.ruler, .saturn)
        XCTAssertEqual(ZodiacSign.leo.element, .fire)
        XCTAssertEqual(ZodiacSign.taurus.exaltedPlanet, .moon)
        XCTAssertNil(ZodiacSign.leo.exaltedPlanet)
        XCTAssertEqual(ZodiacSign.aries.opposite, .libra)
        XCTAssertEqual(ZodiacSign.pisces.opposite, .virgo)
        // Every planet rules exactly the signs that name it as ruler.
        for planet in Planet.allCases {
            let ruled = ZodiacSign.allCases.filter { $0.ruler == planet }
            XCTAssertEqual(ruled, planet.domiciles, "\(planet) domiciles")
            if let exaltation = planet.exaltation {
                XCTAssertEqual(exaltation.exaltedPlanet, planet)
            }
        }
        XCTAssertEqual(Planet.allCases.map(\.kameaOrder), [3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(Planet.sun.name, "Sun")
        XCTAssertEqual(Planet.sun.dignity(in: .leo), .domicile)
        XCTAssertEqual(Planet.sun.dignity(in: .aries), .exaltation)
        XCTAssertEqual(Planet.sun.dignity(in: .aquarius), .detriment)
        XCTAssertEqual(Planet.sun.dignity(in: .libra), .fall)
        XCTAssertEqual(Planet.sun.dignity(in: .gemini), .peregrine)
    }

    func testBirthDataOwnerJulianDay() {
        let owner = BirthData.owner
        XCTAssertEqual(owner.year, 2002)
        XCTAssertEqual(owner.month, 8)
        XCTAssertEqual(owner.day, 16)
        XCTAssertEqual(owner.hourUT, 13.0)
        XCTAssertEqual(owner.latitude, 45.5152)
        XCTAssertEqual(owner.longitudeEast, -122.6784)
        XCTAssertEqual(owner.jdUT, 2_452_503.0416666665, accuracy: 1e-8)
        XCTAssertEqual(BirthData(year: 2000, month: 1, day: 1, hourUT: 12, latitude: 0, longitudeEast: 0).jdUT, 2_451_545.0)
        XCTAssertEqual(BirthData(year: 1987, month: 1, day: 27, hourUT: 0, latitude: 0, longitudeEast: 0).jdUT, 2_446_822.5, "Meeus example 7.a")
    }

    func testSyzygyInstantFormattingRoundsToMinute() {
        XCTAssertEqual(Syzygy(kind: .newMoon, jdUT: 2_452_495.302212375, longitude: 136.063).formattedInstantUT, "2002-08-08 19:15 UT")
        // 23:59:40 UT on 2002-08-08 rounds forward into the next day.
        let lateEvening = 2_452_494.5 + (23.0 + 59.0 / 60.0 + 40.0 / 3600.0) / 24.0
        XCTAssertEqual(Syzygy(kind: .fullMoon, jdUT: lateEvening, longitude: 0).formattedInstantUT, "2002-08-09 00:00 UT")
        XCTAssertEqual(SyzygyKind.newMoon.name, "New Moon")
        XCTAssertEqual(SyzygyKind.fullMoon.name, "Full Moon")
    }

    // MARK: - Appendix A report

    func testAppendixAReportMatchesExpectedText() {
        let chart = NatalChart(
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
        let expected = """
        Sun 23°30' Leo (143.494°)
        Moon 7°42' Sagittarius (247.694°)
        Ascendant 20°13' Leo (140.211°)
        MC 9°28' Taurus (39.468°)
        Sun altitude −2.87° → night chart
        Prenatal syzygy New Moon 2002-08-08 19:15 UT 16°04' Leo (136.063°)
        Lot of Fortune 6°01' Taurus (36.010°)
        Lot of Spirit 4°25' Sagittarius (244.411°)
        Chart ruler Sun — in domicile, rising
        """
        let report = chart.appendixAReport()
        XCTAssertEqual(report, expected)
        XCTAssertEqual(report.split(separator: "\n", omittingEmptySubsequences: false).count, 9)
        XCTAssertFalse(report.hasSuffix("\n"))
        XCTAssertTrue(report.contains("\u{2212}2.87°"), "negative altitude uses U+2212 MINUS SIGN")
        XCTAssertTrue(report.contains(" \u{2014} "), "ruler line uses an em dash")
    }

    func testAppendixAReportDayChartAndDignityWording() {
        let base = NatalChart(
            birth: .owner,
            sun: ZodiacPosition(longitude: 10),
            moon: ZodiacPosition(longitude: 20),
            ascendant: ZodiacPosition(longitude: 30),
            midheaven: ZodiacPosition(longitude: 300),
            sunAltitude: 34.9728,
            sect: .day,
            prenatalSyzygy: Syzygy(kind: .fullMoon, jdUT: 2_449_158.5780942924, longitude: 88.762),
            lotOfFortune: ZodiacPosition(longitude: 40),
            lotOfSpirit: ZodiacPosition(longitude: 50),
            chartRuler: .venus,
            rulerPosition: nil,
            rulerDignity: .peregrine,
            rulerRising: false
        )
        let lines = base.appendixAReport().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 9)
        XCTAssertEqual(lines[4], "Sun altitude 34.97° → day chart")
        XCTAssertEqual(lines[5], "Prenatal syzygy Full Moon 1993-06-20 01:52 UT 28°46' Gemini (88.762°)")
        XCTAssertEqual(lines[8], "Chart ruler Venus — peregrine")

        func rulerLine(_ dignity: Dignity, rising: Bool) -> String {
            let chart = NatalChart(
                birth: base.birth, sun: base.sun, moon: base.moon, ascendant: base.ascendant,
                midheaven: base.midheaven, sunAltitude: base.sunAltitude, sect: base.sect,
                prenatalSyzygy: base.prenatalSyzygy, lotOfFortune: base.lotOfFortune,
                lotOfSpirit: base.lotOfSpirit, chartRuler: .moon, rulerPosition: base.moon,
                rulerDignity: dignity, rulerRising: rising
            )
            return chart.appendixAReport().split(separator: "\n").map(String.init)[8]
        }
        XCTAssertEqual(rulerLine(.exaltation, rising: true), "Chart ruler Moon — exalted, rising")
        XCTAssertEqual(rulerLine(.detriment, rising: false), "Chart ruler Moon — in detriment")
        XCTAssertEqual(rulerLine(.fall, rising: false), "Chart ruler Moon — in fall")
    }

    func testNatalChartCodableRoundTrip() throws {
        let chart = NatalChart(
            birth: .owner,
            sun: ZodiacPosition(longitude: 143.494), moon: ZodiacPosition(longitude: 247.694),
            ascendant: ZodiacPosition(longitude: 140.211), midheaven: ZodiacPosition(longitude: 39.468),
            sunAltitude: -2.87, sect: .night,
            prenatalSyzygy: Syzygy(kind: .newMoon, jdUT: 2_452_495.302212375, longitude: 136.063),
            lotOfFortune: ZodiacPosition(longitude: 36.010), lotOfSpirit: ZodiacPosition(longitude: 244.411),
            chartRuler: .sun, rulerPosition: ZodiacPosition(longitude: 143.494),
            rulerDignity: .domicile, rulerRising: true
        )
        let decoded = try JSONDecoder().decode(NatalChart.self, from: JSONEncoder().encode(chart))
        XCTAssertEqual(decoded, chart)
        XCTAssertEqual(decoded.appendixAReport(), chart.appendixAReport())
    }

    // MARK: - Daemon types

    func testHebrewLetterTables() {
        XCTAssertEqual(HebrewLetter.allCases.count, 22)
        XCTAssertEqual(HebrewLetter.allCases.map(\.value),
                       [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 200, 300, 400])
        XCTAssertEqual(String(HebrewLetter.allCases.map(\.latin)), "ABGDHVZCTYKLMNSOPXQRST")
        XCTAssertEqual(String(HebrewLetter.allCases.map(\.character)), "אבגדהוזחטיכלמנסעפצקרשת")
        XCTAssertEqual(HebrewLetter.daleth.name, "Daleth")
        XCTAssertEqual(HebrewLetter.tav.name, "Tav")
        // DRAND = Daleth Resh Aleph Nun Daleth.
        let drand: [HebrewLetter] = [.daleth, .resh, .aleph, .nun, .daleth]
        XCTAssertEqual(String(drand.map(\.latin)), "DRAND")
        XCTAssertEqual(String(drand.map(\.character)), "דראנד")
        XCTAssertEqual(Set(HebrewLetter.allCases.map(\.character)).count, 22, "all glyphs distinct")
    }

    func testDaemonAttributeMappings() {
        XCTAssertEqual(HylegicalPlace.allCases, [.sun, .moon, .ascendant, .fortune, .syzygy])
        XCTAssertEqual(DaemonForm.allCases.count, 12)
        XCTAssertEqual(DaemonMotion.allCases.count, 12)
        XCTAssertEqual(DaemonPalette.allCases.count, 7)
        XCTAssertEqual(DaemonForm.forSign(.leo), .leonine)
        XCTAssertEqual(DaemonForm.forSign(.aries), .ramHorned)
        XCTAssertEqual(DaemonMotion.forSign(.sagittarius), .expansiveArcing)
        XCTAssertEqual(DaemonMotion.forSign(.aries), .abruptThrusting)
        XCTAssertEqual(DaemonMotion.forSign(.pisces), .flowingDissolve)
        XCTAssertEqual(DaemonPalette.forPlanet(.sun), .goldWhiteFire)
        XCTAssertEqual(DaemonPalette.forPlanet(.moon), .silverBlue)
        XCTAssertEqual(DaemonPalette.forPlanet(.saturn), .leadBlack)
        XCTAssertEqual(DaemonElement(chartElement: .fire), .fire)
        XCTAssertEqual(Set(ZodiacSign.allCases.map(DaemonForm.forSign)).count, 12, "form mapping is a bijection")
        XCTAssertEqual(Set(ZodiacSign.allCases.map(DaemonMotion.forSign)).count, 12, "motion mapping is a bijection")
        XCTAssertEqual(Set(Planet.allCases.map(DaemonPalette.forPlanet)).count, 7, "palette mapping is a bijection")
    }

    // MARK: - Ritual types

    func testRitualStageOrderAndNext() {
        XCTAssertEqual(RitualStage.allCases.map(\.rawValue), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(RitualStage.allCases, [.oath, .air, .fire, .water, .earth, .spirit, .sigilSpin, .manifestation])
        XCTAssertEqual(RitualStage.allCases.map(\.id),
                       ["oath", "air", "fire", "water", "earth", "spirit", "sigilSpin", "manifestation"])
        XCTAssertEqual(RitualStage.oath.next, .air)
        XCTAssertEqual(RitualStage.earth.next, .spirit)
        XCTAssertEqual(RitualStage.sigilSpin.next, .manifestation)
        XCTAssertNil(RitualStage.manifestation.next)
        var walked: [RitualStage] = []
        var stage: RitualStage? = .oath
        while let current = stage {
            walked.append(current)
            stage = current.next
        }
        XCTAssertEqual(walked, RitualStage.allCases)

        XCTAssertEqual(RitualStage.air.quarter, .east)
        XCTAssertEqual(RitualStage.fire.quarter, .south)
        XCTAssertEqual(RitualStage.water.quarter, .west)
        XCTAssertEqual(RitualStage.earth.quarter, .north)
        XCTAssertNil(RitualStage.oath.quarter)
        XCTAssertNil(RitualStage.spirit.quarter)
        XCTAssertEqual(RitualStage.spirit.element, .spirit)
        XCTAssertNil(RitualStage.manifestation.element)
        XCTAssertEqual(RitualStage(rawValue: 7), .sigilSpin)
    }

    func testQuarterYawPositionsAndElements() {
        XCTAssertEqual(Quarter.allCases, [.east, .south, .west, .north])
        XCTAssertEqual(Quarter.east.yawDegrees, 90)
        XCTAssertEqual(Quarter.south.yawDegrees, 0)
        XCTAssertEqual(Quarter.west.yawDegrees, 270)
        XCTAssertEqual(Quarter.north.yawDegrees, 180)
        XCTAssertEqual(Quarter.east.candlePosition, RVec3(1.8, 0, 0))
        XCTAssertEqual(Quarter.south.candlePosition, RVec3(0, 0, 1.8))
        XCTAssertEqual(Quarter.west.candlePosition, RVec3(-1.8, 0, 0))
        XCTAssertEqual(Quarter.north.candlePosition, RVec3(0, 0, -1.8))
        XCTAssertEqual(Quarter.north.flamePosition, RVec3(0, 1.13, -1.8))
        XCTAssertEqual(Quarter.allCases.map(\.element), [.air, .fire, .water, .earth])
        XCTAssertEqual(Quarter.allCases.map(\.stage), [.air, .fire, .water, .earth])
        for quarter in Quarter.allCases {
            XCTAssertEqual(quarter.candlePosition.length, 1.8, accuracy: 1e-12)
            XCTAssertEqual(quarter.element.quarter, quarter)
            XCTAssertEqual(quarter.stage.quarter, quarter)
            XCTAssertTrue(quarter.isFaced(byYaw: quarter.yawDegrees + 29.9))
            XCTAssertTrue(quarter.isFaced(byYaw: quarter.yawDegrees - 30 + 720))
            XCTAssertFalse(quarter.isFaced(byYaw: quarter.yawDegrees + 30.1))
            XCTAssertFalse(quarter.isFaced(byYaw: quarter.yawDegrees + 180))
        }
        XCTAssertTrue(Quarter.south.isFaced(byYaw: -20), "wrap-around: −20° faces South (yaw 0)")
        XCTAssertTrue(Quarter.west.isFaced(byYaw: -90), "−90° ≡ 270° faces West")
    }

    func testRitualElementFlames() {
        XCTAssertEqual(RitualElement.allCases, [.air, .fire, .water, .earth, .spirit])
        XCTAssertEqual(RitualElement.air.flameColorLinearRGB, RVec3(1.0, 0.93, 0.72))
        XCTAssertEqual(RitualElement.fire.flameColorLinearRGB, RVec3(1.0, 0.28, 0.05))
        XCTAssertEqual(RitualElement.water.flameColorLinearRGB, RVec3(0.15, 0.45, 1.0))
        XCTAssertEqual(RitualElement.earth.flameColorLinearRGB, RVec3(0.2, 1.0, 0.3))
        XCTAssertEqual(RitualElement.spirit.flameColorLinearRGB, RVec3(1.0, 0.85, 0.6))
        XCTAssertEqual(RitualElement.allCases.map(\.flameTemperatureK), [2400, 1500, 0, 0, 2000])
        XCTAssertNil(RitualElement.spirit.quarter)
    }

    func testInputAndEventCodableRoundTrip() throws {
        let inputs = [
            RitualInput(tick: 0, kind: .holdBegin),
            RitualInput(tick: 360, kind: .holdEnd),
            RitualInput(tick: 400, kind: .tracePoint(RVec2(0.5, 0.25))),
            RitualInput(tick: 401, kind: .traceEnd),
            RitualInput(tick: 500, kind: .tap),
            RitualInput(tick: 600, kind: .flick(velocity: RVec2(3, -1), ring: 2)),
            RitualInput(tick: 601, kind: .flick(velocity: RVec2(1, 1), ring: nil)),
            RitualInput(tick: 700, kind: .cameraYaw(90)),
        ]
        let decoded = try JSONDecoder().decode([RitualInput].self, from: JSONEncoder().encode(inputs))
        XCTAssertEqual(decoded, inputs)

        let events: [RitualEvent] = [
            .stageCompleted(.oath), .candleLit(.east), .beatHit(.perfect),
            .sigilErupted, .manifestationBegan, .ritualComplete,
        ]
        let decodedEvents = try JSONDecoder().decode([RitualEvent].self, from: JSONEncoder().encode(events))
        XCTAssertEqual(decodedEvents, events)

        XCTAssertEqual(BeatResult.allCases, [.perfect, .good, .miss])
        XCTAssertTrue(BeatResult.good.isHit)
        XCTAssertFalse(BeatResult.miss.isHit)
    }

    func testCandleStateDefaults() throws {
        XCTAssertEqual(CandleState.unlit, CandleState())
        XCTAssertFalse(CandleState.unlit.lit)
        XCTAssertNil(CandleState.unlit.ignitionTick)
        XCTAssertEqual(CandleState.unlit.intensity, 0)
        XCTAssertEqual(CandleState.rampSeconds, 0.6)
        let lit = CandleState(lit: true, ignitionTick: 1200, intensity: 0.5)
        let candles: [Quarter: CandleState] = [.east: lit, .south: .unlit]
        let decoded = try JSONDecoder().decode([Quarter: CandleState].self, from: JSONEncoder().encode(candles))
        XCTAssertEqual(decoded, candles)
    }

    // MARK: - Capture types

    func testCameraPresets() {
        XCTAssertEqual(CameraPreset.allCases, [.front, .threequarter, .profile, .overhead, .low, .closeup])
        XCTAssertEqual(CameraPreset.front.position, RVec3(0, 1.5, 4.6))
        XCTAssertEqual(CameraPreset.front.target, RVec3(0, 1.2, 0))
        XCTAssertEqual(CameraPreset.threequarter.position, RVec3(3.3, 1.9, 3.3))
        XCTAssertEqual(CameraPreset.threequarter.target, RVec3(0, 1.2, 0))
        XCTAssertEqual(CameraPreset.profile.position, RVec3(4.6, 1.4, 0))
        XCTAssertEqual(CameraPreset.profile.target, RVec3(0, 1.2, 0))
        XCTAssertEqual(CameraPreset.overhead.position, RVec3(0, 3.85, 0.05))
        XCTAssertEqual(CameraPreset.overhead.target, RVec3(0, 0, 0))
        XCTAssertEqual(CameraPreset.low.position, RVec3(0, 0.32, 3.6))
        XCTAssertEqual(CameraPreset.low.target, RVec3(0, 1.3, 0))
        XCTAssertEqual(CameraPreset.closeup.position, RVec3(0.9, 1.65, 1.35))
        XCTAssertEqual(CameraPreset.closeup.target, RVec3(0, 1.45, -0.1))
        XCTAssertEqual(CameraPreset(rawValue: "threequarter"), .threequarter)
        XCTAssertEqual(RenderPathChoice(rawValue: "fallback"), .fallback)
        XCTAssertEqual(CaptureMode(rawValue: "none"), CaptureMode.none)
        XCTAssertEqual(CaptureMode(rawValue: "stills"), .stills)
    }

    // MARK: - Resources

    /// The ephemeris fixture must be reachable through `Bundle.module` for `EphemerisTests`.
    func testFixtureBundleContainsEphemerisVectors() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "ephemeris_vectors", withExtension: "json", subdirectory: "Fixtures"),
            "Fixtures/ephemeris_vectors.json must be copied into the test bundle"
        )
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let vectors = try XCTUnwrap(json["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 41)
    }
}
