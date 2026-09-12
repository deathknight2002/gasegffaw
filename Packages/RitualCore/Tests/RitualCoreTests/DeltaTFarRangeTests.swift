import XCTest
@testable import RitualCore

/// One pyswisseph 2.10.03 / Moshier reference vector in the far half (2060–2100) of the
/// supported 1900–2100 range, generated with the same routine as
/// `Fixtures/ephemeris_vectors.json` (`Tools/truth/gen_vectors.py`) and embedded verbatim.
struct FarRangeVector {
    let year: Int, month: Int, day: Int
    let utHours: Double, jdUT: Double
    let site: String, latitude: Double, longitudeEast: Double
    let sunLon: Double, moonLon: Double, asc: Double, mc: Double
    let deltaT: Double
    let syzygyKind: String, syzygyJD: Double, syzygyLon: Double

    var date: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

enum FarRangeFixture {
    static let vectors: [FarRangeVector] = [
        FarRangeVector(year: 2062, month: 6, day: 3, utHours: 11.3852, jdUT: 2474343.974383333,
                       site: "portland", latitude: 45.5152, longitudeEast: -122.6784,
                       sunLon: 73.19557991761843, moonLon: 19.342453052049006, asc: 52.50206662509221, mc: 298.20666796675465,
                       deltaT: 78.42823569224353, syzygyKind: "full", syzygyJD: 2474332.7941106344, syzygyLon: 242.46671358183596),
        FarRangeVector(year: 2063, month: 1, day: 22, utHours: 9.7034, jdUT: 2474576.9043083335,
                       site: "reykjavik", latitude: 64.1466, longitudeEast: -21.9426,
                       sunLon: 302.38718517704075, moonLon: 223.17371596725658, asc: 271.8698983836114, mc: 247.2194133997066,
                       deltaT: 78.6383450407091, syzygyKind: "full", syzygyJD: 2474569.3001790484, syzygyLon: 114.64696877538624),
        FarRangeVector(year: 2069, month: 2, day: 20, utHours: 10.0596, jdUT: 2476797.91915,
                       site: "sydney", latitude: -33.8688, longitudeEast: 151.2093,
                       sunLon: 332.35005158381335, moonLon: 315.71021722229165, asc: 184.6693770946394, mc: 92.7901867902989,
                       deltaT: 80.70651553180141, syzygyKind: "full", syzygyJD: 2476783.729048063, syzygyLon: 138.00482575044035),
        FarRangeVector(year: 2071, month: 5, day: 17, utHours: 13.1556, jdUT: 2477614.04815,
                       site: "equator", latitude: 0.0, longitudeEast: 0.0,
                       sunLon: 56.76659259551971, moonLon: 275.0617854706494, asc: 161.2320916499219, mc: 74.03477088883206,
                       deltaT: 81.49660025409706, syzygyKind: "full", syzygyJD: 2477610.6423341157, syzygyLon: 233.4821264628389),
        FarRangeVector(year: 2074, month: 6, day: 9, utHours: 6.1922, jdUT: 2478732.7580083334,
                       site: "equator", latitude: 0.0, longitudeEast: 0.0,
                       sunLon: 78.82253118969135, moonLon: 256.8876778578199, asc: 81.62214632202343, mc: 350.07793960946316,
                       deltaT: 82.60665634527435, syzygyKind: "new", syzygyJD: 2478718.4478506315, syzygyLon: 65.10544269400638),
        FarRangeVector(year: 2077, month: 7, day: 22, utHours: 1.4701, jdUT: 2479871.5612541665,
                       site: "portland", latitude: 45.5152, longitudeEast: -122.6784,
                       sunLon: 119.92939705700816, moonLon: 143.25702520246972, asc: 264.3187041637064, mc: 201.45611981370695,
                       deltaT: 83.76942828012231, syzygyKind: "new", syzygyJD: 2479869.5290176235, syzygyLon: 117.98885815229514),
        FarRangeVector(year: 2083, month: 9, day: 10, utHours: 9.7489, jdUT: 2482112.906204167,
                       site: "sydney", latitude: -33.8688, longitudeEast: 151.2093,
                       sunLon: 167.9192160921152, moonLon: 147.83996168377016, asc: 14.401923616013647, mc: 285.7471592664757,
                       deltaT: 86.15736181708195, syzygyKind: "full", syzygyJD: 2482098.9589885334, syzygyLon: 334.41759324018153),
        FarRangeVector(year: 2084, month: 11, day: 16, utHours: 20.2487, jdUT: 2482546.3436958333,
                       site: "portland", latitude: 45.5152, longitudeEast: -122.6784,
                       sunLon: 235.42763390165126, moonLon: 105.18902767151047, asc: 305.039014725255, mc: 240.08483952443896,
                       deltaT: 86.63472615736146, syzygyKind: "full", syzygyJD: 2482541.9244568106, syzygyLon: 50.97989682399239),
        FarRangeVector(year: 2089, month: 5, day: 10, utHours: 3.4856, jdUT: 2484181.645233333,
                       site: "equator", latitude: 0.0, longitudeEast: 0.0,
                       sunLon: 50.2432033994323, moonLon: 46.6570648281595, asc: 11.926847397308855, mc: 280.08402531471063,
                       deltaT: 88.48242502059558, syzygyKind: "full", syzygyJD: 2484166.391586922, syzygyLon: 215.43902919294695),
        FarRangeVector(year: 2092, month: 1, day: 13, utHours: 13.2878, jdUT: 2485160.053658333,
                       site: "equator", latitude: 0.0, longitudeEast: 0.0,
                       sunLon: 293.33686343078585, moonLon: 349.30412711112734, asc: 44.82463046880018, mc: 309.92311733894127,
                       deltaT: 89.62383328345378, syzygyKind: "new", syzygyJD: 2485155.568120175, syzygyLon: 288.76423636242527),
        FarRangeVector(year: 2096, month: 11, day: 26, utHours: 2.5089, jdUT: 2486938.6045375,
                       site: "portland", latitude: 45.5152, longitudeEast: -122.6784,
                       sunLon: 244.8585272189045, moonLon: 12.171086456066272, asc: 96.42345902330601, mc: 339.45728892252475,
                       deltaT: 91.76934494618804, syzygyKind: "new", syzygyJD: 2486927.525780103, syzygyLon: 233.67547823075256),
        FarRangeVector(year: 2096, month: 6, day: 26, utHours: 20.2606, jdUT: 2486786.3441916667,
                       site: "tokyo", latitude: 35.6762, longitudeEast: 139.6503,
                       sunLon: 96.2722882986345, moonLon: 178.12460040488796, asc: 105.55295039108873, mc: 359.51414238385775,
                       deltaT: 91.58204770036842, syzygyKind: "new", syzygyJD: 2486779.88429738, syzygyLon: 90.10684399889976),
    ]
}

/// Regression coverage for the far end of the supported range, where the ΔT model used
/// to diverge from contemporary predictions by 60–110 s and consumed most of the contract's
/// 2-minute syzygy budget (the shipped fixture's latest vector is 2050-07-18).
final class DeltaTFarRangeTests: XCTestCase {
    /// ΔT tolerance against Swiss, seconds; the model tracks it to ≈ 4 s through 2100.
    private let deltaTToleranceSeconds = 10.0
    /// Syzygy instant tolerance, seconds: the lunar series alone can shift a lunation by
    /// ≈ 20 s (10″ at 12.19°/day), so 45 s leaves room for that plus the ΔT budget above
    /// while staying far inside the contract's 120 s.
    private let syzygyInstantToleranceSeconds = 45.0

    func testFixtureShape() {
        XCTAssertEqual(FarRangeFixture.vectors.count, 12)
        for v in FarRangeFixture.vectors {
            XCTAssertTrue((2060...2100).contains(v.year), v.date)
            XCTAssertEqual(JulianDay.fromCalendar(year: v.year, month: v.month, day: v.day, hourUT: v.utHours), v.jdUT, accuracy: 1e-8, v.date)
        }
    }

    func testDeltaTStaysWithinAFewSecondsOfSwissThrough2100() {
        var worst = 0.0
        for v in FarRangeFixture.vectors {
            let deltaT = JulianDay.deltaT(jd: v.jdUT)
            worst = max(worst, abs(deltaT - v.deltaT))
            XCTAssertEqual(deltaT, v.deltaT, accuracy: deltaTToleranceSeconds, "ΔT \(v.date): RitualCore \(deltaT) vs Swiss \(v.deltaT)")
        }
        XCTAssertLessThan(worst, deltaTToleranceSeconds)
    }

    func testSunMoonAndAnglesWithinContractTolerances() {
        var worstMoon = 0.0
        for v in FarRangeFixture.vectors {
            let sun = Ephemeris.sun(jdUT: v.jdUT).longitude
            let moon = Ephemeris.moon(jdUT: v.jdUT).longitude
            XCTAssertLessThanOrEqual(angularDifference(sun, v.sunLon), EphemerisTolerance.sun, "Sun \(v.date)")
            XCTAssertLessThanOrEqual(angularDifference(moon, v.moonLon), EphemerisTolerance.moon, "Moon \(v.date)")
            worstMoon = max(worstMoon, angularDifference(moon, v.moonLon))
            let jdTT = JulianDay.terrestrialTime(fromUT: v.jdUT)
            let obliquity = Ephemeris.trueObliquity(jdTT: jdTT)
            let ramc = Ephemeris.localApparentSiderealTime(jdUT: v.jdUT, longitudeEast: v.longitudeEast)
            XCTAssertLessThanOrEqual(angularDifference(Ephemeris.midheaven(ramc: ramc, obliquity: obliquity), v.mc), EphemerisTolerance.midheaven, "MC \(v.date)")
            XCTAssertLessThanOrEqual(angularDifference(Ephemeris.ascendant(ramc: ramc, latitude: v.latitude, obliquity: obliquity), v.asc), EphemerisTolerance.ascendant, "ASC \(v.date)")
        }
        // With ΔT within a few seconds of Swiss the Moon error is the series' own (≈ 10″),
        // not the 47–74″ the old extrapolation produced at 2091–2100.
        XCTAssertLessThanOrEqual(worstMoon, EphemerisTolerance.moonFine, "worst Moon error \(worstMoon * 3600)″")
    }

    func testPrenatalSyzygyWithinContractTolerancesWithMargin() {
        var worstInstant = 0.0
        for v in FarRangeFixture.vectors {
            let syzygy = SyzygyFinder.prenatal(before: v.jdUT)
            XCTAssertEqual(syzygy.kind == .fullMoon ? "full" : "new", v.syzygyKind, v.date)
            XCTAssertLessThanOrEqual(angularDifference(syzygy.longitude, v.syzygyLon), EphemerisTolerance.syzygyLongitude, "syzygy longitude \(v.date)")
            let instantError = abs(syzygy.jdUT - v.syzygyJD) * 86_400
            worstInstant = max(worstInstant, instantError)
            XCTAssertLessThanOrEqual(instantError, syzygyInstantToleranceSeconds, "syzygy instant \(v.date) off by \(instantError) s")
            XCTAssertLessThan(syzygy.jdUT, v.jdUT, v.date)
        }
        XCTAssertLessThan(worstInstant, syzygyInstantToleranceSeconds)
    }
}
