import XCTest
@testable import RitualCore

/// One reference vector from `Fixtures/ephemeris_vectors.json` (pyswisseph / Moshier).
struct EphemerisVector: Decodable {
    struct PrenatalSyzygy: Decodable {
        let kind: String
        let jd: Double
        let lon: Double
    }

    let date: String
    let utHours: Double
    let jdUT: Double
    let lat: Double
    let lon: Double
    let sunLon: Double
    let sunLat: Double
    let sunDistAU: Double
    let moonLon: Double
    let moonLat: Double
    let asc: Double
    let mc: Double
    let armc: Double
    let sunAltTrue: Double
    let trueObliquity: Double
    let meanObliquity: Double
    let nutationLon: Double
    let nutationObl: Double
    let prenatalSyzygy: PrenatalSyzygy?

    private enum CodingKeys: String, CodingKey {
        case date
        case utHours = "ut_hours"
        case jdUT = "jd_ut"
        case lat, lon
        case sunLon = "sun_lon"
        case sunLat = "sun_lat"
        case sunDistAU = "sun_dist_au"
        case moonLon = "moon_lon"
        case moonLat = "moon_lat"
        case asc, mc, armc
        case sunAltTrue = "sun_alt_true"
        case trueObliquity = "true_obliquity"
        case meanObliquity = "mean_obliquity"
        case nutationLon = "nutation_lon"
        case nutationObl = "nutation_obl"
        case prenatalSyzygy = "prenatal_syzygy"
    }
}

/// The fixture file: source description, headline tolerance and the vectors.
struct EphemerisFixture: Decodable {
    let source: String
    let toleranceDeg: Double
    let vectors: [EphemerisVector]

    private enum CodingKeys: String, CodingKey {
        case source
        case toleranceDeg = "tolerance_deg"
        case vectors
    }

    /// Loads `Fixtures/ephemeris_vectors.json` from the test bundle.
    static func load() throws -> EphemerisFixture {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "ephemeris_vectors", withExtension: "json", subdirectory: "Fixtures"),
            "Fixtures/ephemeris_vectors.json must be bundled with the test target"
        )
        return try JSONDecoder().decode(EphemerisFixture.self, from: Data(contentsOf: url))
    }
}

/// Smallest absolute difference between two angles in degrees, modulo 360.
func angularDifference(_ a: Double, _ b: Double) -> Double {
    abs(Angle.wrap180(a - b))
}

/// Contract tolerances (CORE_API.md, "Tests required"): every vector of the Swiss
/// Ephemeris fixture must be reproduced within these bounds.
enum EphemerisTolerance {
    static let sun = 0.01
    static let moon = 0.05
    static let ascendant = 0.05
    static let midheaven = 0.05
    static let altitude = 0.1
    static let obliquity = 0.001
    static let nutation = 0.001
    static let syzygyLongitude = 0.05
    static let syzygyInstantDays = 2.0 / 1440.0
}

final class EphemerisTests: XCTestCase {
    private var fixture: EphemerisFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try EphemerisFixture.load()
    }

    // MARK: - Fixture sanity

    func testFixtureHasAllVectors() {
        XCTAssertEqual(fixture.vectors.count, 41)
        XCTAssertTrue(fixture.source.contains("swisseph"))
        for vector in fixture.vectors {
            let parts = vector.date.split(separator: "-").compactMap { Int($0) }
            XCTAssertEqual(parts.count, 3, vector.date)
            let jd = JulianDay.fromCalendar(year: parts[0], month: parts[1], day: parts[2], hourUT: vector.utHours)
            XCTAssertEqual(jd, vector.jdUT, accuracy: 1e-8, "Julian Day of \(vector.date) \(vector.utHours)h")
        }
    }

    // MARK: - Julian Day and ΔT

    func testJulianDayCalendarRoundTrip() {
        XCTAssertEqual(JulianDay.fromCalendar(year: 2000, month: 1, day: 1, hourUT: 12), 2_451_545.0)
        XCTAssertEqual(JulianDay.fromCalendar(year: 1987, month: 1, day: 27, hourUT: 0), 2_446_822.5, "Meeus 7.a")
        XCTAssertEqual(JulianDay.fromCalendar(year: 1988, month: 6, day: 19, hourUT: 12), 2_447_332.0, "Meeus 7.b")
        let owner = JulianDay.fromCalendar(year: 2002, month: 8, day: 16, hourUT: 13)
        XCTAssertEqual(owner, BirthData.owner.jdUT)
        let back = JulianDay.toCalendar(owner)
        XCTAssertEqual(back.year, 2002)
        XCTAssertEqual(back.month, 8)
        XCTAssertEqual(back.day, 16)
        XCTAssertEqual(back.hourUT, 13, accuracy: 1e-6)
        let meeus = JulianDay.toCalendar(2_436_116.31)
        XCTAssertEqual(meeus.year, 1957)
        XCTAssertEqual(meeus.month, 10)
        XCTAssertEqual(meeus.day, 4)
        XCTAssertEqual(meeus.hourUT, 0.81 * 24, accuracy: 1e-6, "Meeus 7.c")
        XCTAssertEqual(JulianDay.centuriesSinceJ2000(2_451_545.0), 0)
        XCTAssertEqual(JulianDay.centuriesSinceJ2000(2_451_545.0 + 36_525.0), 1)
        XCTAssertEqual(JulianDay.millenniaSinceJ2000(2_451_545.0 + 365_250.0), 1)
    }

    func testDeltaTMatchesObservedValues() {
        // Observed ΔT (IERS): 1955 ≈ 31.1 s, 1975 ≈ 45.5 s, 2002 ≈ 64.3 s, 2021 ≈ 69.4 s.
        XCTAssertEqual(JulianDay.deltaT(jd: JulianDay.fromCalendar(year: 1955, month: 7, day: 1, hourUT: 0)), 31.1, accuracy: 1.0)
        XCTAssertEqual(JulianDay.deltaT(jd: JulianDay.fromCalendar(year: 1975, month: 7, day: 1, hourUT: 0)), 45.5, accuracy: 1.0)
        XCTAssertEqual(JulianDay.deltaT(jd: BirthData.owner.jdUT), 64.4, accuracy: 1.0)
        // Beyond 2005 the polynomial extrapolates (72.6 s for 2021 against 69.4 s observed).
        XCTAssertEqual(JulianDay.deltaT(jd: JulianDay.fromCalendar(year: 2021, month: 10, day: 5, hourUT: 0)), 69.4, accuracy: 5.0)
        // Segment boundaries are continuous to within a few seconds, and the far past/future
        // fall back to the parabolic long-term fit.
        for year in [1600, 1700, 1800, 1860, 1900, 1920, 1941, 1961, 1986, 2005, 2050, 2150] {
            let before = JulianDay.deltaT(decimalYear: Double(year) - 0.001)
            let after = JulianDay.deltaT(decimalYear: Double(year) + 0.001)
            XCTAssertEqual(before, after, accuracy: 5.0, "ΔT continuity at \(year)")
        }
        XCTAssertEqual(JulianDay.deltaT(decimalYear: -1000), 25_427.68, accuracy: 0.01, "long-term parabola, u = −28.2")
        XCTAssertEqual(JulianDay.deltaT(decimalYear: 2500), 1459.68, accuracy: 0.01, "long-term parabola, u = 6.8")
        let tt = JulianDay.terrestrialTime(fromUT: BirthData.owner.jdUT)
        XCTAssertEqual((tt - BirthData.owner.jdUT) * 86_400, JulianDay.deltaT(jd: BirthData.owner.jdUT), accuracy: 1e-3)
    }

    // MARK: - Obliquity and nutation

    func testMeanAndTrueObliquityWithinTolerance() {
        for vector in fixture.vectors {
            let jdTT = JulianDay.terrestrialTime(fromUT: vector.jdUT)
            XCTAssertEqual(Ephemeris.meanObliquity(jdTT: jdTT), vector.meanObliquity, accuracy: EphemerisTolerance.obliquity, "mean obliquity \(vector.date)")
            XCTAssertEqual(Ephemeris.trueObliquity(jdTT: jdTT), vector.trueObliquity, accuracy: EphemerisTolerance.obliquity, "true obliquity \(vector.date)")
        }
        // Meeus example 22.a: 1987 April 10, 0h TT → ε₀ = 23°26'27.407".
        let meeus = Ephemeris.meanObliquity(jdTT: 2_446_895.5)
        XCTAssertEqual(meeus, 23.0 + 26.0 / 60.0 + 27.407 / 3600.0, accuracy: 0.001 / 3600.0)
    }

    func testNutationWithinTolerance() {
        for vector in fixture.vectors {
            let jdTT = JulianDay.terrestrialTime(fromUT: vector.jdUT)
            let nutation = Ephemeris.nutation(jdTT: jdTT)
            XCTAssertEqual(nutation.longitude, vector.nutationLon, accuracy: EphemerisTolerance.nutation, "Δψ \(vector.date)")
            XCTAssertEqual(nutation.obliquity, vector.nutationObl, accuracy: EphemerisTolerance.nutation, "Δε \(vector.date)")
            // The Swiss Ephemeris series agrees with IAU 1980 to well under 0.1″.
            XCTAssertEqual(nutation.longitude, vector.nutationLon, accuracy: 0.1 / 3600.0, "Δψ fine \(vector.date)")
            XCTAssertEqual(nutation.obliquity, vector.nutationObl, accuracy: 0.1 / 3600.0, "Δε fine \(vector.date)")
        }
        // Meeus example 22.a: Δψ = −3.788", Δε = +9.443".
        let meeus = Ephemeris.nutation(jdTT: 2_446_895.5)
        XCTAssertEqual(meeus.longitude * 3600, -3.788, accuracy: 0.01)
        XCTAssertEqual(meeus.obliquity * 3600, 9.443, accuracy: 0.01)
        XCTAssertEqual(Ephemeris.nutationTerms.count, 63)
    }

    // MARK: - Sun

    func testSunWithinTolerance() {
        for vector in fixture.vectors {
            let sun = Ephemeris.sun(jdUT: vector.jdUT)
            XCTAssertLessThanOrEqual(angularDifference(sun.longitude, vector.sunLon), EphemerisTolerance.sun, "Sun longitude \(vector.date)")
            XCTAssertEqual(sun.latitude, vector.sunLat, accuracy: 0.001, "Sun latitude \(vector.date)")
            XCTAssertEqual(sun.distanceAU, vector.sunDistAU, accuracy: 1e-5, "Sun distance \(vector.date)")
            XCTAssertGreaterThanOrEqual(sun.longitude, 0)
            XCTAssertLessThan(sun.longitude, 360)
        }
        // Meeus example 25.b: 1992 October 13, 0h TT → apparent λ = 199°54'21.56", R = 0.99760775.
        let jdTT = 2_448_908.5
        let jdUT = jdTT - JulianDay.deltaT(jd: jdTT) / 86_400.0
        let sun = Ephemeris.sun(jdUT: jdUT)
        XCTAssertEqual(sun.longitude, 199.0 + 54.0 / 60.0 + 21.56 / 3600.0, accuracy: 1.0 / 3600.0)
        XCTAssertEqual(sun.distanceAU, 0.99760775, accuracy: 1e-6)
    }

    // MARK: - Moon

    func testMoonWithinTolerance() {
        for vector in fixture.vectors {
            let moon = Ephemeris.moon(jdUT: vector.jdUT)
            XCTAssertLessThanOrEqual(angularDifference(moon.longitude, vector.moonLon), EphemerisTolerance.moon, "Moon longitude \(vector.date)")
            XCTAssertEqual(moon.latitude, vector.moonLat, accuracy: EphemerisTolerance.moon, "Moon latitude \(vector.date)")
            XCTAssertGreaterThan(moon.distanceKm, 356_000)
            XCTAssertLessThan(moon.distanceKm, 407_000)
            // The engine reproduces the reference series itself (a few 0.01″ given the same
            // ΔT); the only remaining difference is ΔT, which the Espenak–Meeus polynomials
            // track to well under a second before 2010, so hold those vectors to 1″.
            if vector.jdUT < 2_455_200 {
                XCTAssertLessThanOrEqual(angularDifference(moon.longitude, vector.moonLon), 1.0 / 3600.0, "Moon longitude fine \(vector.date)")
            }
            XCTAssertEqual(moon.latitude, vector.moonLat, accuracy: 0.001, "Moon latitude fine \(vector.date)")
        }
    }

    func testMoonMeeusSeriesMatchesWorkedExample() {
        // Meeus example 47.a: 1992 April 12, 0h TT → λ = 133.162655°, β = −3.229126°, Δ = 368409.7 km
        // (geometric); with Δψ = +0.004610° the apparent longitude is 133.167265°.
        let jdTT = 2_448_724.5
        let geometric = Ephemeris.moonMeeusGeometric(jdTT: jdTT)
        XCTAssertEqual(geometric.longitude, 133.162655, accuracy: 0.000002)
        XCTAssertEqual(geometric.latitude, -3.229126, accuracy: 0.000002)
        XCTAssertEqual(geometric.distanceKm, 368_409.7, accuracy: 0.1)
        let jdUT = jdTT - JulianDay.deltaT(jd: jdTT) / 86_400.0
        let apparent = Ephemeris.moonMeeus(jdUT: jdUT)
        XCTAssertEqual(apparent.longitude, 133.167265, accuracy: 0.00005)
        XCTAssertEqual(apparent.latitude, -3.229126, accuracy: 0.00005)
        XCTAssertEqual(Ephemeris.lunarLongitudeTerms.count, 60)
        XCTAssertEqual(Ephemeris.lunarLatitudeTerms.count, 60)
        // The Meeus series and the engine agree to the ~10″ truncation level of Table 47.A.
        for vector in fixture.vectors {
            let meeus = Ephemeris.moonMeeus(jdUT: vector.jdUT)
            let engine = Ephemeris.moon(jdUT: vector.jdUT)
            XCTAssertLessThanOrEqual(angularDifference(meeus.longitude, engine.longitude), 20.0 / 3600.0, "Meeus vs engine longitude \(vector.date)")
            XCTAssertEqual(meeus.latitude, engine.latitude, accuracy: 6.0 / 3600.0, "Meeus vs engine latitude \(vector.date)")
            XCTAssertEqual(meeus.distanceKm, engine.distanceKm, accuracy: 60.0, "Meeus vs engine distance \(vector.date)")
        }
    }

    func testMoonLightTimeAndNutationAssembly() {
        // Apparent = geometric position retarded by the light-time (≈ −0.7″) plus Δψ.
        for vector in fixture.vectors {
            let jdTT = JulianDay.terrestrialTime(fromUT: vector.jdUT)
            let geometric = MoshierLunarTheory.geometric(jdTT: jdTT)
            let apparent = Ephemeris.moon(jdUT: vector.jdUT)
            let deltaPsi = Ephemeris.nutation(jdTT: jdTT).longitude
            let retardation = Angle.wrap180(apparent.longitude - deltaPsi - geometric.longitude) * 3600.0
            XCTAssertLessThan(retardation, -0.55, "retardation \(vector.date)")
            XCTAssertGreaterThan(retardation, -0.85, "retardation \(vector.date)")
            XCTAssertEqual(apparent.distanceKm, geometric.distanceKm, accuracy: 0.2)
        }
        // Mean elements at J2000.0: L = 785939.95571″ (218°18′59.96″), D ≈ 297.850°, F ≈ 93.272°.
        let arguments = MoshierLunarTheory.arguments(t: 0)
        XCTAssertEqual(arguments.lPrime, 785_939.95571, accuracy: 1e-6)
        XCTAssertEqual(arguments.d / 3600.0, 297.8502, accuracy: 1e-3)
        XCTAssertEqual(arguments.f / 3600.0, 93.2721, accuracy: 1e-3)
        XCTAssertEqual(arguments.mPrime / 3600.0, 134.9634, accuracy: 1e-3)
        XCTAssertEqual(arguments.m / 3600.0, 357.5291, accuracy: 1e-3)
        XCTAssertEqual(MoshierLunarTheory.lrTerms.count, 118 * 8)
        XCTAssertEqual(MoshierLunarTheory.mbTerms.count, 77 * 6)
        XCTAssertEqual(MoshierLunarTheory.z.count, 25)
    }

    // MARK: - Sidereal time and angles

    func testSiderealTimeMatchesARMC() {
        for vector in fixture.vectors {
            let ramc = Ephemeris.localApparentSiderealTime(jdUT: vector.jdUT, longitudeEast: vector.lon)
            XCTAssertLessThanOrEqual(angularDifference(ramc, vector.armc), 0.002, "RAMC \(vector.date)")
        }
        // Meeus example 12.a: 1987 April 10, 0h UT → GMST 13h10m46.3668s, GAST 13h10m46.1351s.
        let jd = 2_446_895.5
        XCTAssertEqual(Ephemeris.greenwichMeanSiderealTime(jdUT: jd), (13.0 + 10.0 / 60.0 + 46.3668 / 3600.0) * 15.0, accuracy: 0.0001)
        XCTAssertEqual(Ephemeris.greenwichApparentSiderealTime(jdUT: jd), (13.0 + 10.0 / 60.0 + 46.1351 / 3600.0) * 15.0, accuracy: 0.0002)
        // Meeus example 12.b: 1987 April 10, 19h21m UT → GMST 8h34m57.0896s.
        XCTAssertEqual(Ephemeris.greenwichMeanSiderealTime(jdUT: 2_446_896.30625), (8.0 + 34.0 / 60.0 + 57.0896 / 3600.0) * 15.0, accuracy: 0.0001)
    }

    func testAscendantAndMidheavenWithinTolerance() {
        for vector in fixture.vectors {
            let jdTT = JulianDay.terrestrialTime(fromUT: vector.jdUT)
            let obliquity = Ephemeris.trueObliquity(jdTT: jdTT)
            let ramc = Ephemeris.localApparentSiderealTime(jdUT: vector.jdUT, longitudeEast: vector.lon)
            let mc = Ephemeris.midheaven(ramc: ramc, obliquity: obliquity)
            let asc = Ephemeris.ascendant(ramc: ramc, latitude: vector.lat, obliquity: obliquity)
            XCTAssertLessThanOrEqual(angularDifference(mc, vector.mc), EphemerisTolerance.midheaven, "MC \(vector.date)")
            XCTAssertLessThanOrEqual(angularDifference(asc, vector.asc), EphemerisTolerance.ascendant, "ASC \(vector.date)")
            // With the fixture's own ARMC the angles are pure geometry and agree far better.
            XCTAssertLessThanOrEqual(angularDifference(Ephemeris.midheaven(ramc: vector.armc, obliquity: vector.trueObliquity), vector.mc), 1e-6, "MC geometry \(vector.date)")
            XCTAssertLessThanOrEqual(angularDifference(Ephemeris.ascendant(ramc: vector.armc, latitude: vector.lat, obliquity: vector.trueObliquity), vector.asc), 1e-6, "ASC geometry \(vector.date)")
            let offset = Angle.normalize(asc - mc)
            XCTAssertGreaterThan(offset, 0, "ASC must be east of the MC \(vector.date)")
            XCTAssertLessThan(offset, 180, "ASC must be east of the MC \(vector.date)")
        }
    }

    func testMidheavenAndAscendantQuadrants() {
        let epsilon = 23.44
        XCTAssertEqual(Ephemeris.midheaven(ramc: 0, obliquity: epsilon), 0, accuracy: 1e-9)
        XCTAssertEqual(Ephemeris.midheaven(ramc: 90, obliquity: epsilon), 90, accuracy: 1e-9)
        XCTAssertEqual(Ephemeris.midheaven(ramc: 180, obliquity: epsilon), 180, accuracy: 1e-9)
        XCTAssertEqual(Ephemeris.midheaven(ramc: 270, obliquity: epsilon), 270, accuracy: 1e-9)
        // RAMC 45°: the MC leads the RAMC in the first quadrant.
        let mc45 = Ephemeris.midheaven(ramc: 45, obliquity: epsilon)
        XCTAssertGreaterThan(mc45, 45)
        XCTAssertLessThan(mc45, 50)
        // At the equator with RAMC 0 the ascendant is 90° (0° Cancer rises when 0° Aries culminates).
        XCTAssertEqual(Ephemeris.ascendant(ramc: 0, latitude: 0, obliquity: epsilon), 90, accuracy: 1e-9)
        XCTAssertEqual(Ephemeris.ascendant(ramc: 180, latitude: 0, obliquity: epsilon), 270, accuracy: 1e-9)
        // The ascendant is always 0…180° ahead of the MC, at every latitude short of the polar circle.
        for latitude in stride(from: -66.0, through: 66.0, by: 11.0) {
            for ramc in stride(from: 0.0, to: 360.0, by: 7.5) {
                let mc = Ephemeris.midheaven(ramc: ramc, obliquity: epsilon)
                let asc = Ephemeris.ascendant(ramc: ramc, latitude: latitude, obliquity: epsilon)
                let offset = Angle.normalize(asc - mc)
                XCTAssertGreaterThan(offset, 0, "lat \(latitude) ramc \(ramc)")
                XCTAssertLessThan(offset, 180, "lat \(latitude) ramc \(ramc)")
            }
        }
        // Inside the polar circle the closed form can land in the west; the contract flips it east.
        for ramc in stride(from: 0.0, to: 360.0, by: 5.0) {
            let mc = Ephemeris.midheaven(ramc: ramc, obliquity: epsilon)
            let asc = Ephemeris.ascendant(ramc: ramc, latitude: 75, obliquity: epsilon)
            let offset = Angle.normalize(asc - mc)
            XCTAssertGreaterThan(offset, 0, "polar ramc \(ramc)")
            XCTAssertLessThanOrEqual(offset, 180, "polar ramc \(ramc)")
        }
    }

    func testEclipticToEquatorialMeeusExample() {
        // Meeus example 13.a (Pollux): λ = 113.215630°, β = 6.684170°, ε = 23.4392911° → α = 116.328942°, δ = 28.026183°.
        let equatorial = Ephemeris.eclipticToEquatorial(longitude: 113.215630, latitude: 6.684170, obliquity: 23.4392911)
        XCTAssertEqual(equatorial.ra, 116.328942, accuracy: 1e-5)
        XCTAssertEqual(equatorial.dec, 28.026183, accuracy: 1e-5)
        XCTAssertEqual(Ephemeris.eclipticToEquatorial(longitude: 0, latitude: 0, obliquity: 23.44).ra, 0, accuracy: 1e-12)
        XCTAssertEqual(Ephemeris.eclipticToEquatorial(longitude: 90, latitude: 0, obliquity: 23.44).dec, 23.44, accuracy: 1e-9)
    }

    func testAltitudeGeometry() {
        // Meeus example 13.b (Venus from USNO): H = 64.352133°, φ = 38.921389°, δ = −6.719892° → h = 15.1249°.
        let altitude = Ephemeris.altitude(ra: 0, dec: -6.719892, lst: 64.352133, latitude: 38.921389)
        XCTAssertEqual(altitude, 15.1249, accuracy: 1e-4)
        // A body on the meridian at the observer's own declination is at the zenith.
        XCTAssertEqual(Ephemeris.altitude(ra: 100, dec: 40, lst: 100, latitude: 40), 90, accuracy: 1e-5)
        // At lower culmination its altitude is φ + δ − 90 = −10°.
        XCTAssertEqual(Ephemeris.altitude(ra: 100, dec: 40, lst: 280, latitude: 40), -10, accuracy: 1e-9)
        XCTAssertEqual(Ephemeris.altitude(ra: 0, dec: 0, lst: 90, latitude: 0), 0, accuracy: 1e-9)
    }

    func testSunAltitudeWithinTolerance() {
        for vector in fixture.vectors {
            let altitude = Ephemeris.sunAltitude(jdUT: vector.jdUT, latitude: vector.lat, longitudeEast: vector.lon)
            XCTAssertEqual(altitude, vector.sunAltTrue, accuracy: EphemerisTolerance.altitude, "Sun altitude \(vector.date)")
        }
    }

    // MARK: - Prenatal syzygy

    func testPrenatalSyzygyWithinTolerance() {
        var checked = 0
        for vector in fixture.vectors {
            guard let expected = vector.prenatalSyzygy else { continue }
            checked += 1
            let syzygy = SyzygyFinder.prenatal(before: vector.jdUT)
            let expectedKind: SyzygyKind = expected.kind == "new" ? .newMoon : .fullMoon
            XCTAssertEqual(syzygy.kind, expectedKind, "syzygy kind \(vector.date)")
            XCTAssertEqual(syzygy.jdUT, expected.jd, accuracy: EphemerisTolerance.syzygyInstantDays, "syzygy instant \(vector.date)")
            XCTAssertLessThanOrEqual(angularDifference(syzygy.longitude, expected.lon), EphemerisTolerance.syzygyLongitude, "syzygy longitude \(vector.date)")
            XCTAssertLessThan(syzygy.jdUT, vector.jdUT, "syzygy must precede the birth \(vector.date)")
            XCTAssertGreaterThan(vector.jdUT - syzygy.jdUT, 0)
            XCTAssertLessThan(vector.jdUT - syzygy.jdUT, 15.5, "at most half a lunation back")
        }
        XCTAssertEqual(checked, 11, "the fixture carries eleven syzygy vectors")
    }

    func testPrenatalSyzygyIsAtTheElongationAndStrictlyBefore() {
        // Walk a year in 7-day steps: every result is a true syzygy, strictly in the past,
        // and the New/Full alternation is consistent with the elongation.
        let start = JulianDay.fromCalendar(year: 2010, month: 1, day: 1, hourUT: 0)
        for step in 0 ..< 52 {
            let jd = start + Double(step) * 7.0
            let syzygy = SyzygyFinder.prenatal(before: jd)
            XCTAssertLessThan(syzygy.jdUT, jd)
            let elongation = Angle.normalize(Ephemeris.moon(jdUT: syzygy.jdUT).longitude - Ephemeris.sun(jdUT: syzygy.jdUT).longitude)
            switch syzygy.kind {
            case .newMoon:
                XCTAssertLessThan(min(elongation, 360 - elongation), 0.001, "new moon elongation")
                XCTAssertEqual(syzygy.longitude, Ephemeris.sun(jdUT: syzygy.jdUT).longitude, accuracy: 1e-9)
            case .fullMoon:
                XCTAssertEqual(elongation, 180, accuracy: 0.001, "full moon elongation")
                XCTAssertEqual(syzygy.longitude, Ephemeris.moon(jdUT: syzygy.jdUT).longitude, accuracy: 1e-9)
            }
        }
        // Asking for the syzygy just after one that was found returns that same syzygy.
        let owner = SyzygyFinder.prenatal(before: BirthData.owner.jdUT)
        let again = SyzygyFinder.prenatal(before: owner.jdUT + 0.01)
        XCTAssertEqual(again.kind, owner.kind)
        XCTAssertEqual(again.jdUT, owner.jdUT, accuracy: 2.0 / 86_400.0)
    }
}
