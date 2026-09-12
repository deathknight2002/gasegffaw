import Foundation

/// One row of Meeus Table 47.A: multipliers of D, M, M′, F and the coefficients of the
/// sine (longitude, 10⁻⁶ degree) and cosine (distance, 10⁻³ km) terms.
struct LunarLongitudeTerm {
    let d: Double, m: Double, mPrime: Double, f: Double
    let sigmaL: Double
    let sigmaR: Double

    init(_ d: Double, _ m: Double, _ mPrime: Double, _ f: Double, _ sigmaL: Double, _ sigmaR: Double) {
        self.d = d
        self.m = m
        self.mPrime = mPrime
        self.f = f
        self.sigmaL = sigmaL
        self.sigmaR = sigmaR
    }
}

/// One row of Meeus Table 47.B: multipliers of D, M, M′, F and the sine coefficient of the
/// latitude term (10⁻⁶ degree).
struct LunarLatitudeTerm {
    let d: Double, m: Double, mPrime: Double, f: Double
    let sigmaB: Double

    init(_ d: Double, _ m: Double, _ mPrime: Double, _ f: Double, _ sigmaB: Double) {
        self.d = d
        self.m = m
        self.mPrime = mPrime
        self.f = f
        self.sigmaB = sigmaB
    }
}

extension Ephemeris {
    /// Meeus Table 47.A — longitude (Σl) and distance (Σr) periodic terms, 60 rows.
    static let lunarLongitudeTerms: [LunarLongitudeTerm] = [
        LunarLongitudeTerm(0, 0, 1, 0, 6288774, -20905355),
        LunarLongitudeTerm(2, 0, -1, 0, 1274027, -3699111),
        LunarLongitudeTerm(2, 0, 0, 0, 658314, -2955968),
        LunarLongitudeTerm(0, 0, 2, 0, 213618, -569925),
        LunarLongitudeTerm(0, 1, 0, 0, -185116, 48888),
        LunarLongitudeTerm(0, 0, 0, 2, -114332, -3149),
        LunarLongitudeTerm(2, 0, -2, 0, 58793, 246158),
        LunarLongitudeTerm(2, -1, -1, 0, 57066, -152138),
        LunarLongitudeTerm(2, 0, 1, 0, 53322, -170733),
        LunarLongitudeTerm(2, -1, 0, 0, 45758, -204586),
        LunarLongitudeTerm(0, 1, -1, 0, -40923, -129620),
        LunarLongitudeTerm(1, 0, 0, 0, -34720, 108743),
        LunarLongitudeTerm(0, 1, 1, 0, -30383, 104755),
        LunarLongitudeTerm(2, 0, 0, -2, 15327, 10321),
        LunarLongitudeTerm(0, 0, 1, 2, -12528, 0),
        LunarLongitudeTerm(0, 0, 1, -2, 10980, 79661),
        LunarLongitudeTerm(4, 0, -1, 0, 10675, -34782),
        LunarLongitudeTerm(0, 0, 3, 0, 10034, -23210),
        LunarLongitudeTerm(4, 0, -2, 0, 8548, -21636),
        LunarLongitudeTerm(2, 1, -1, 0, -7888, 24208),
        LunarLongitudeTerm(2, 1, 0, 0, -6766, 30824),
        LunarLongitudeTerm(1, 0, -1, 0, -5163, -8379),
        LunarLongitudeTerm(1, 1, 0, 0, 4987, -16675),
        LunarLongitudeTerm(2, -1, 1, 0, 4036, -12831),
        LunarLongitudeTerm(2, 0, 2, 0, 3994, -10445),
        LunarLongitudeTerm(4, 0, 0, 0, 3861, -11650),
        LunarLongitudeTerm(2, 0, -3, 0, 3665, 14403),
        LunarLongitudeTerm(0, 1, -2, 0, -2689, -7003),
        LunarLongitudeTerm(2, 0, -1, 2, -2602, 0),
        LunarLongitudeTerm(2, -1, -2, 0, 2390, 10056),
        LunarLongitudeTerm(1, 0, 1, 0, -2348, 6322),
        LunarLongitudeTerm(2, -2, 0, 0, 2236, -9884),
        LunarLongitudeTerm(0, 1, 2, 0, -2120, 5751),
        LunarLongitudeTerm(0, 2, 0, 0, -2069, 0),
        LunarLongitudeTerm(2, -2, -1, 0, 2048, -4950),
        LunarLongitudeTerm(2, 0, 1, -2, -1773, 4130),
        LunarLongitudeTerm(2, 0, 0, 2, -1595, 0),
        LunarLongitudeTerm(4, -1, -1, 0, 1215, -3958),
        LunarLongitudeTerm(0, 0, 2, 2, -1110, 0),
        LunarLongitudeTerm(3, 0, -1, 0, -892, 3258),
        LunarLongitudeTerm(2, 1, 1, 0, -810, 2616),
        LunarLongitudeTerm(4, -1, -2, 0, 759, -1897),
        LunarLongitudeTerm(0, 2, -1, 0, -713, -2117),
        LunarLongitudeTerm(2, 2, -1, 0, -700, 2354),
        LunarLongitudeTerm(2, 1, -2, 0, 691, 0),
        LunarLongitudeTerm(2, -1, 0, -2, 596, 0),
        LunarLongitudeTerm(4, 0, 1, 0, 549, -1423),
        LunarLongitudeTerm(0, 0, 4, 0, 537, -1117),
        LunarLongitudeTerm(4, -1, 0, 0, 520, -1571),
        LunarLongitudeTerm(1, 0, -2, 0, -487, -1739),
        LunarLongitudeTerm(2, 1, 0, -2, -399, 0),
        LunarLongitudeTerm(0, 0, 2, -2, -381, -4421),
        LunarLongitudeTerm(1, 1, 1, 0, 351, 0),
        LunarLongitudeTerm(3, 0, -2, 0, -340, 0),
        LunarLongitudeTerm(4, 0, -3, 0, 330, 0),
        LunarLongitudeTerm(2, -1, 2, 0, 327, 0),
        LunarLongitudeTerm(0, 2, 1, 0, -323, 1165),
        LunarLongitudeTerm(1, 1, -1, 0, 299, 0),
        LunarLongitudeTerm(2, 0, 3, 0, 294, 0),
        LunarLongitudeTerm(2, 0, -1, -2, 0, 8752),
    ]

    /// Meeus Table 47.B — latitude (Σb) periodic terms, 60 rows.
    static let lunarLatitudeTerms: [LunarLatitudeTerm] = [
        LunarLatitudeTerm(0, 0, 0, 1, 5128122),
        LunarLatitudeTerm(0, 0, 1, 1, 280602),
        LunarLatitudeTerm(0, 0, 1, -1, 277693),
        LunarLatitudeTerm(2, 0, 0, -1, 173237),
        LunarLatitudeTerm(2, 0, -1, 1, 55413),
        LunarLatitudeTerm(2, 0, -1, -1, 46271),
        LunarLatitudeTerm(2, 0, 0, 1, 32573),
        LunarLatitudeTerm(0, 0, 2, 1, 17198),
        LunarLatitudeTerm(2, 0, 1, -1, 9266),
        LunarLatitudeTerm(0, 0, 2, -1, 8822),
        LunarLatitudeTerm(2, -1, 0, -1, 8216),
        LunarLatitudeTerm(2, 0, -2, -1, 4324),
        LunarLatitudeTerm(2, 0, 1, 1, 4200),
        LunarLatitudeTerm(2, 1, 0, -1, -3359),
        LunarLatitudeTerm(2, -1, -1, 1, 2463),
        LunarLatitudeTerm(2, -1, 0, 1, 2211),
        LunarLatitudeTerm(2, -1, -1, -1, 2065),
        LunarLatitudeTerm(0, 1, -1, -1, -1870),
        LunarLatitudeTerm(4, 0, -1, -1, 1828),
        LunarLatitudeTerm(0, 1, 0, 1, -1794),
        LunarLatitudeTerm(0, 0, 0, 3, -1749),
        LunarLatitudeTerm(0, 1, -1, 1, -1565),
        LunarLatitudeTerm(1, 0, 0, 1, -1491),
        LunarLatitudeTerm(0, 1, 1, 1, -1475),
        LunarLatitudeTerm(0, 1, 1, -1, -1410),
        LunarLatitudeTerm(0, 1, 0, -1, -1344),
        LunarLatitudeTerm(1, 0, 0, -1, -1335),
        LunarLatitudeTerm(0, 0, 3, 1, 1107),
        LunarLatitudeTerm(4, 0, 0, -1, 1021),
        LunarLatitudeTerm(4, 0, -1, 1, 833),
        LunarLatitudeTerm(0, 0, 1, -3, 777),
        LunarLatitudeTerm(4, 0, -2, 1, 671),
        LunarLatitudeTerm(2, 0, 0, -3, 607),
        LunarLatitudeTerm(2, 0, 2, -1, 596),
        LunarLatitudeTerm(2, -1, 1, -1, 491),
        LunarLatitudeTerm(2, 0, -2, 1, -451),
        LunarLatitudeTerm(0, 0, 3, -1, 439),
        LunarLatitudeTerm(2, 0, 2, 1, 422),
        LunarLatitudeTerm(2, 0, -3, -1, 421),
        LunarLatitudeTerm(2, 1, -1, 1, -366),
        LunarLatitudeTerm(2, 1, 0, 1, -351),
        LunarLatitudeTerm(4, 0, 0, 1, 331),
        LunarLatitudeTerm(2, -1, 1, 1, 315),
        LunarLatitudeTerm(2, -2, 0, -1, 302),
        LunarLatitudeTerm(0, 0, 1, 3, -283),
        LunarLatitudeTerm(2, 1, 1, -1, -229),
        LunarLatitudeTerm(1, 1, 0, -1, 223),
        LunarLatitudeTerm(1, 1, 0, 1, 223),
        LunarLatitudeTerm(0, 1, -2, -1, -220),
        LunarLatitudeTerm(2, 1, -1, -1, -220),
        LunarLatitudeTerm(1, 0, 1, 1, -185),
        LunarLatitudeTerm(2, -1, -2, -1, 181),
        LunarLatitudeTerm(0, 1, 2, 1, -177),
        LunarLatitudeTerm(4, 0, -2, -1, 176),
        LunarLatitudeTerm(4, -1, -1, -1, 166),
        LunarLatitudeTerm(1, 0, 1, -1, -164),
        LunarLatitudeTerm(4, 0, 1, -1, 132),
        LunarLatitudeTerm(1, 0, -1, -1, -119),
        LunarLatitudeTerm(4, -1, 0, -1, 115),
        LunarLatitudeTerm(2, -2, 0, 1, 107),
    ]

    /// Geocentric Moon referred to the mean equinox of date from the Meeus chapter 47 series
    /// (Tables 47.A/47.B with the E factor and the A1/A2/A3 additive terms), before nutation.
    ///
    /// - Parameter jdTT: Julian Day in Terrestrial Time.
    /// - Returns: Longitude in [0, 360) and latitude in degrees, distance in kilometres.
    static func moonMeeusGeometric(jdTT: Double) -> (longitude: Double, latitude: Double, distanceKm: Double) {
        let t = JulianDay.centuriesSinceJ2000(jdTT)
        let t2 = t * t
        let t3 = t2 * t
        let t4 = t3 * t

        // Fundamental arguments (Meeus 47.1–47.5), degrees.
        let lPrime = Angle.normalize(218.3164477 + 481_267.88123421 * t - 0.0015786 * t2 + t3 / 538_841.0 - t4 / 65_194_000.0)
        let d = Angle.normalize(297.8501921 + 445_267.1114034 * t - 0.0018819 * t2 + t3 / 545_868.0 - t4 / 113_065_000.0)
        let m = Angle.normalize(357.5291092 + 35_999.0502909 * t - 0.0001536 * t2 + t3 / 24_490_000.0)
        let mPrime = Angle.normalize(134.9633964 + 477_198.8675055 * t + 0.0087414 * t2 + t3 / 69_699.0 - t4 / 14_712_000.0)
        let f = Angle.normalize(93.2720950 + 483_202.0175233 * t - 0.0036539 * t2 - t3 / 3_526_000.0 + t4 / 863_310_000.0)

        // Additive arguments (Meeus 47.6) and the eccentricity factor E.
        let a1 = Angle.normalize(119.75 + 131.849 * t)
        let a2 = Angle.normalize(53.09 + 479_264.290 * t)
        let a3 = Angle.normalize(313.45 + 481_266.484 * t)
        let e = 1.0 - 0.002516 * t - 0.0000074 * t2
        let e2 = e * e

        func eccentricityFactor(_ mMultiplier: Double) -> Double {
            switch abs(mMultiplier) {
            case 1: return e
            case 2: return e2
            default: return 1.0
            }
        }

        var sigmaL = 0.0
        var sigmaR = 0.0
        for term in lunarLongitudeTerms {
            let argument = Angle.deg2rad(term.d * d + term.m * m + term.mPrime * mPrime + term.f * f)
            let factor = eccentricityFactor(term.m)
            sigmaL += term.sigmaL * factor * sin(argument)
            sigmaR += term.sigmaR * factor * cos(argument)
        }
        var sigmaB = 0.0
        for term in lunarLatitudeTerms {
            let argument = Angle.deg2rad(term.d * d + term.m * m + term.mPrime * mPrime + term.f * f)
            sigmaB += term.sigmaB * eccentricityFactor(term.m) * sin(argument)
        }

        // Planetary perturbations and the flattening of the Earth (Meeus p. 338).
        sigmaL += 3958.0 * sin(Angle.deg2rad(a1))
            + 1962.0 * sin(Angle.deg2rad(lPrime - f))
            + 318.0 * sin(Angle.deg2rad(a2))
        sigmaB += -2235.0 * sin(Angle.deg2rad(lPrime))
            + 382.0 * sin(Angle.deg2rad(a3))
            + 175.0 * sin(Angle.deg2rad(a1 - f))
            + 175.0 * sin(Angle.deg2rad(a1 + f))
            + 127.0 * sin(Angle.deg2rad(lPrime - mPrime))
            - 115.0 * sin(Angle.deg2rad(lPrime + mPrime))

        let longitude = Angle.normalize(lPrime + sigmaL / 1_000_000.0)
        let latitude = sigmaB / 1_000_000.0
        let distance = 385_000.56 + sigmaR / 1000.0
        return (longitude, latitude, distance)
    }

    /// Apparent geocentric Moon from the textbook series of Meeus chapter 47 (ELP-2000/82
    /// truncated to the 60 + 60 terms of Tables 47.A/47.B, ~10″ in longitude, ~4″ in latitude,
    /// ~4 km in distance) plus nutation in longitude — referred to the true ecliptic and
    /// equinox of date.
    ///
    /// ``moon(jdUT:)`` is the chart engine's Moon; this variant is kept as the published
    /// reference series (and is pinned against Meeus's worked example 47.a in the tests).
    ///
    /// - Parameter jdUT: Julian Day in Universal Time (converted to TT internally).
    /// - Returns: Longitude in [0, 360) and latitude in degrees, distance in kilometres.
    public static func moonMeeus(jdUT: Double) -> (longitude: Double, latitude: Double, distanceKm: Double) {
        let jdTT = JulianDay.terrestrialTime(fromUT: jdUT)
        let geometric = moonMeeusGeometric(jdTT: jdTT)
        let deltaPsi = nutation(jdTT: jdTT).longitude
        return (Angle.normalize(geometric.longitude + deltaPsi), geometric.latitude, geometric.distanceKm)
    }

    /// Apparent geocentric Moon referred to the true ecliptic and equinox of date.
    ///
    /// Evaluates Moshier's semi-analytical lunar theory (ELP2000-85 truncated and refitted to
    /// JPL DE404 — the same series the Swiss Ephemeris "Moshier" mode uses, so the result
    /// agrees with the project's reference vectors to a few 0.01″), retards the position by
    /// the light-time (≈1.3 s, −0.7″ in longitude; the annual-aberration and light-time
    /// contributions of the Earth's own motion cancel for the Moon) and adds nutation in
    /// longitude. The plain Meeus chapter 47 series is available as ``moonMeeus(jdUT:)``;
    /// the two agree to ~15″.
    ///
    /// - Parameter jdUT: Julian Day in Universal Time (converted to TT internally).
    /// - Returns: Longitude in [0, 360) and latitude in degrees, distance in kilometres.
    public static func moon(jdUT: Double) -> (longitude: Double, latitude: Double, distanceKm: Double) {
        let jdTT = JulianDay.terrestrialTime(fromUT: jdUT)
        let geometric = MoshierLunarTheory.geometric(jdTT: jdTT)
        let lightTimeDays = geometric.distanceKm / speedOfLightKmPerSecond / JulianDay.secondsPerDay
        let retarded = MoshierLunarTheory.geometric(jdTT: jdTT - lightTimeDays)
        let deltaPsi = nutation(jdTT: jdTT).longitude
        return (Angle.normalize(retarded.longitude + deltaPsi), retarded.latitude, retarded.distanceKm)
    }

    /// Speed of light in km/s (IAU).
    static let speedOfLightKmPerSecond = 299_792.458
}

// MARK: - Moshier lunar theory

/// Steve Moshier's analytical lunar ephemeris: the ELP2000-85 series of Chapront-Touzé &
/// Chapront truncated to ≈ 300 terms, with mean elements and the largest planetary Poisson
/// terms refitted by least squares to JPL DE404 over −3000…+3000 (S. L. Moshier, 1991/1995).
/// The coefficient tables and the secular fit are Moshier's, as published in his freely
/// distributed `aa` ephemeris program and carried unchanged by the Swiss Ephemeris "Moshier"
/// mode; the evaluation code here is an independent implementation of that algorithm.
/// Coordinates are referred to the mean ecliptic and equinox of date. Accuracy versus DE404
/// is a few arc-seconds, and versus the Swiss Ephemeris Moshier mode a few 0.01″.
///
/// Internally every angle is kept in arc-seconds, as in the original.
enum MoshierLunarTheory {
    /// Arc-seconds to radians.
    static let arcsecondsToRadians = Double.pi / 648_000.0
    /// Arc-seconds in one turn.
    static let arcsecondsPerTurn = 1_296_000.0
    /// Constant part of the geocentric distance, kilometres.
    static let meanDistanceKm = 385_000.52899

    /// Reduces an angle in arc-seconds to [0, 1 296 000).
    static func modTurn(_ arcseconds: Double) -> Double {
        arcseconds - arcsecondsPerTurn * (arcseconds / arcsecondsPerTurn).rounded(.down)
    }

    /// Mean lunar and planetary arguments at a given epoch, all in arc-seconds.
    struct Arguments {
        /// Mean elongation of the Moon, D.
        var d: Double
        /// Mean anomaly of the Sun, l′.
        var m: Double
        /// Mean anomaly of the Moon, l.
        var mPrime: Double
        /// Mean argument of latitude, F.
        var f: Double
        /// Mean longitude of the Moon (mean ecliptic and equinox of date), L.
        var lPrime: Double
        /// Mean longitudes of Venus, Earth, Mars, Jupiter and Saturn.
        var venus: Double, earth: Double, mars: Double, jupiter: Double, saturn: Double
    }

    /// Mean elements (Laskar's expressions with the DE404-fitted secular corrections) and
    /// planetary mean longitudes (Laskar, Bretagnon).
    ///
    /// - Parameter t: Julian centuries of TT since J2000.0.
    static func arguments(t: Double) -> Arguments {
        let t2 = t * t
        // The large linear rates are split into an exact multiple of one turn (applied to the
        // fractional century only) plus a remainder, preserving precision far from J2000.
        let fracT = t.truncatingRemainder(dividingBy: 1.0)
        var m = modTurn(129_600_000.0 * fracT - 3418.961646 * t + 1_287_104.76154)
        m += ((((((((1.62e-20 * t - 1.0390e-17) * t - 3.83508e-15) * t + 4.237343e-13) * t + 8.8555011e-11) * t
            - 4.77258489e-8) * t - 1.1297037031e-5) * t + 1.4732069041e-4) * t - 0.552891801772) * t2
        var f = modTurn(1_739_232_000.0 * fracT + 295_263.0983 * t - 2.079419901760e-01 * t + 335_779.55755)
        var mPrime = modTurn(1_717_200_000.0 * fracT + 715_923.4728 * t - 2.035946368532e-01 * t + 485_868.28096)
        var d = modTurn(1_601_856_000.0 * fracT + 1_105_601.4603 * t + 3.962893294503e-01 * t + 1_072_260.73512)
        var lPrime = modTurn(1_731_456_000.0 * fracT + 1_108_372.83264 * t - 6.784914260953e-01 * t + 785_939.95571)
        f += ((z[2] * t + z[1]) * t + z[0]) * t2
        mPrime += ((z[5] * t + z[4]) * t + z[3]) * t2
        d += ((z[8] * t + z[7]) * t + z[6]) * t2
        lPrime += ((z[11] * t + z[10]) * t + z[9]) * t2

        var venus = modTurn(210_664_136.4335482 * t + 655_127.283046)
        venus += ((((((((-9.36e-023 * t - 1.95e-20) * t + 6.097e-18) * t + 4.43201e-15) * t + 2.509418e-13) * t
            - 3.0622898e-10) * t - 2.26602516e-9) * t - 1.4244812531e-5) * t + 0.005871373088) * t2
        var earth = modTurn(129_597_742.26669231 * t + 361_679.214649)
        earth += ((((((((-1.16e-22 * t + 2.976e-19) * t + 2.8460e-17) * t - 1.08402e-14) * t - 1.226182e-12) * t
            + 1.7228268e-10) * t + 1.515912254e-7) * t + 8.863982531e-6) * t - 2.0199859001e-2) * t2
        var mars = modTurn(68_905_077.59284 * t + 1_279_559.78866)
        mars += (-1.043e-5 * t + 9.38012e-3) * t2
        var jupiter = modTurn(10_925_660.428608 * t + 123_665.342120)
        jupiter += (1.543273e-5 * t - 3.06037836351e-1) * t2
        var saturn = modTurn(4_399_609.65932 * t + 180_278.89694)
        saturn += ((4.475946e-8 * t - 6.874806E-5) * t + 7.56161437443E-1) * t2

        return Arguments(d: d, m: m, mPrime: mPrime, f: f, lPrime: lPrime,
                         venus: venus, earth: earth, mars: mars, jupiter: jupiter, saturn: saturn)
    }

    /// Sines and cosines of the multiples 1…n of the four Delaunay arguments, used to build
    /// every table argument by angle addition. Multiples that were never prepared read as
    /// zero (which silently drops the single row of `lrTerms` with an l multiplier of 5,
    /// exactly as the reference implementation does).
    struct MultipleAngles {
        private static let capacity = 8
        private var sines: [[Double]]
        private var cosines: [[Double]]

        /// Prepares the multiples for the angles `(value in arc-seconds, highest multiple)`.
        init(angles: [(arcseconds: Double, multiples: Int)]) {
            sines = Array(repeating: Array(repeating: 0.0, count: Self.capacity), count: angles.count)
            cosines = sines
            for (index, angle) in angles.enumerated() {
                let radians = angle.arcseconds * MoshierLunarTheory.arcsecondsToRadians
                let su = sin(radians)
                let cu = cos(radians)
                sines[index][0] = su
                cosines[index][0] = cu
                var sv = 2.0 * su * cu
                var cv = cu * cu - su * su
                sines[index][1] = sv
                cosines[index][1] = cv
                for multiple in 2 ..< min(angle.multiples, Self.capacity) {
                    let s = su * cv + cu * sv
                    cv = cu * cv - su * sv
                    sv = s
                    sines[index][multiple] = sv
                    cosines[index][multiple] = cv
                }
            }
        }

        /// Sine and cosine of `Σ multipliers[k] · angle[k]`.
        func combined(_ multipliers: ArraySlice<Int>) -> (sin: Double, cos: Double) {
            var sv = 0.0
            var cv = 0.0
            var first = true
            for (index, multiplier) in multipliers.enumerated() where multiplier != 0 {
                let k = abs(multiplier)
                // Multiples beyond the prepared range contribute sin = cos = 0.
                var su = k <= Self.capacity ? sines[index][k - 1] : 0.0
                let cu = k <= Self.capacity ? cosines[index][k - 1] : 0.0
                if multiplier < 0 {
                    su = -su
                }
                if first {
                    sv = su
                    cv = cu
                    first = false
                } else {
                    let s = su * cv + cu * sv
                    cv = cu * cv - su * sv
                    sv = s
                }
            }
            return (sv, cv)
        }
    }

    /// Accumulators for the longitude, latitude and radius series (mixed working units, as
    /// in the original stepwise evaluation).
    struct Accumulator {
        var longitude = 0.0
        var latitude = 0.0
        var radius = 0.0
    }

    /// Adds the rows of a table with the two-part (`hi·10000 + lo`) longitude/radius layout.
    static func addLargeLongitudeRadius(_ table: [Int], _ angles: MultipleAngles, into acc: inout Accumulator) {
        for row in stride(from: 0, to: table.count, by: 8) {
            let trig = angles.combined(table[row ..< row + 4])
            acc.longitude += Double(10_000 * table[row + 4] + table[row + 5]) * trig.sin
            let radiusLow = table[row + 7]
            if radiusLow != 0 {
                acc.radius += Double(10_000 * table[row + 6] + radiusLow) * trig.cos
            }
        }
    }

    /// Adds the rows of a table with single-part longitude and radius coefficients.
    static func addLongitudeRadius(_ table: [Int], _ angles: MultipleAngles, into acc: inout Accumulator) {
        for row in stride(from: 0, to: table.count, by: 6) {
            let trig = angles.combined(table[row ..< row + 4])
            acc.longitude += Double(table[row + 4]) * trig.sin
            acc.radius += Double(table[row + 5]) * trig.cos
        }
    }

    /// Adds the rows of a table with a two-part (`hi·10000 + lo`) latitude coefficient.
    static func addLargeLatitude(_ table: [Int], _ angles: MultipleAngles, into acc: inout Accumulator) {
        for row in stride(from: 0, to: table.count, by: 6) {
            let trig = angles.combined(table[row ..< row + 4])
            acc.latitude += Double(10_000 * table[row + 4] + table[row + 5]) * trig.sin
        }
    }

    /// Adds the rows of a table with a single-part latitude coefficient.
    static func addLatitude(_ table: [Int], _ angles: MultipleAngles, into acc: inout Accumulator) {
        for row in stride(from: 0, to: table.count, by: 5) {
            let trig = angles.combined(table[row ..< row + 4])
            acc.latitude += Double(table[row + 4]) * trig.sin
        }
    }

    /// Geometric geocentric Moon (mean ecliptic and equinox of date; no light-time, no
    /// nutation).
    ///
    /// - Parameter jdTT: Julian Day in Terrestrial Time.
    /// - Returns: Longitude in [0, 360) and latitude in degrees, distance in kilometres.
    static func geometric(jdTT: Double) -> (longitude: Double, latitude: Double, distanceKm: Double) {
        let t = JulianDay.centuriesSinceJ2000(jdTT)
        let a = arguments(t: t)
        let str = arcsecondsToRadians
        let angles = MultipleAngles(angles: [(a.d, 6), (a.m, 4), (a.mPrime, 4), (a.f, 4)])

        // Longitude polynomial coefficients: l in arc-seconds; l1…l4 in 10⁻⁵″ per T, T², …
        var l = 0.0, l1 = 0.0, l2 = 0.0
        var acc = Accumulator()

        // --- Terms in T² (10⁻⁵″, 10⁻⁵ km) and the planetary Poisson terms.
        addLongitudeRadius(lrt2Terms, angles, into: &acc)
        addLatitude(bt2Terms, angles, into: &acc)

        let venusEarth = 18.0 * a.venus - 16.0 * a.earth
        var g = str * (venusEarth - a.mPrime)                       // 18V − 16E − l
        var cg = cos(g), sg = sin(g)
        l = 6.367278 * cg + 12.747036 * sg
        l1 = 23123.70 * cg - 10570.02 * sg
        l2 = z[12] * cg + z[13] * sg
        acc.radius += 5.01 * cg + 2.72 * sg
        g = str * (10.0 * a.venus - 3.0 * a.earth - a.mPrime)        // 10V − 3E − l
        cg = cos(g); sg = sin(g)
        l += -0.253102 * cg + 0.503359 * sg
        l1 += 1258.46 * cg + 707.29 * sg
        l2 += z[14] * cg + z[15] * sg
        g = str * (8.0 * a.venus - 13.0 * a.earth)                   // 8V − 13E
        cg = cos(g); sg = sin(g)
        l += -0.187231 * cg - 0.127481 * sg
        l1 += -319.87 * cg - 18.34 * sg
        l2 += z[16] * cg + z[17] * sg
        let earthMarsJupiter = 4.0 * a.earth - 8.0 * a.mars + 3.0 * a.jupiter
        g = str * earthMarsJupiter                                    // 4E − 8M + 3J
        cg = cos(g); sg = sin(g)
        l += -0.866287 * cg + 0.248192 * sg
        l1 += 41.87 * cg + 1053.97 * sg
        l2 += z[18] * cg + z[19] * sg
        g = str * (earthMarsJupiter - a.mPrime)
        cg = cos(g); sg = sin(g)
        l += -0.165009 * cg + 0.044176 * sg
        l1 += 4.67 * cg + 201.55 * sg
        g = str * venusEarth                                          // 18V − 16E
        cg = cos(g); sg = sin(g)
        l += 0.330401 * cg + 0.661362 * sg
        l1 += 1202.67 * cg - 555.59 * sg
        l2 += z[20] * cg + z[21] * sg
        g = str * (venusEarth - 2.0 * a.mPrime)                      // 18V − 16E − 2l
        cg = cos(g); sg = sin(g)
        l += 0.352185 * cg + 0.705041 * sg
        l1 += 1283.59 * cg - 586.43 * sg
        g = str * (2.0 * a.jupiter - 5.0 * a.saturn)                 // 2J − 5S
        cg = cos(g); sg = sin(g)
        l += -0.034700 * cg + 0.160041 * sg
        l2 += z[22] * cg + z[23] * sg
        g = str * (a.lPrime - a.f)                                    // L − F
        cg = cos(g); sg = sin(g)
        l += 0.000116 * cg + 7.063040 * sg
        l1 += 298.8 * sg

        // --- Terms in T³ and the radius Poisson terms.
        let l3 = z[24] * sin(str * a.m)
        let l4 = 0.0
        acc.radius += -0.2655 * cos(str * (2.0 * a.d - a.m)) * t
        acc.radius += -0.1568 * cos(str * (a.m - a.mPrime)) * t
        acc.radius += 0.1309 * cos(str * (a.m + a.mPrime)) * t
        acc.radius += 0.5568 * cos(str * (2.0 * (a.d + a.m) - a.mPrime)) * t
        l2 += acc.longitude
        acc.radius += -0.1910 * cos(str * (2.0 * a.d - a.m - a.mPrime)) * t
        acc.latitude *= t
        acc.radius *= t

        // --- Terms in T (10⁻⁵″, 10⁻⁵ km).
        acc.longitude = 0.0
        addLatitude(btTerms, angles, into: &acc)
        addLargeLongitudeRadius(lrtTerms, angles, into: &acc)
        acc.latitude += -1127.0 * sin(str * (venusEarth - a.mPrime - a.f - 2_355_767.6))   // 18V − 16E − l − F
        acc.latitude += -1123.0 * sin(str * (venusEarth - a.mPrime + a.f - 235_353.6))     // 18V − 16E − l + F
        acc.latitude += 1303.0 * sin(str * (a.earth + a.d + 51_987.6))
        acc.latitude += 342.0 * sin(str * a.lPrime)
        g = str * (2.0 * a.venus - 3.0 * a.earth)
        cg = cos(g); sg = sin(g)
        l += -0.343550 * cg - 0.000276 * sg
        l1 += 105.90 * cg + 336.53 * sg
        g = str * (venusEarth - 2.0 * a.d)                            // 18V − 16E − 2D
        cg = cos(g); sg = sin(g)
        l += 0.074668 * cg + 0.149501 * sg
        l1 += 271.77 * cg - 124.20 * sg
        g = str * (venusEarth - 2.0 * a.d - a.mPrime)
        cg = cos(g); sg = sin(g)
        l += 0.073444 * cg + 0.147094 * sg
        l1 += 265.24 * cg - 121.16 * sg
        g = str * (venusEarth + 2.0 * a.d - a.mPrime)
        cg = cos(g); sg = sin(g)
        l += 0.072844 * cg + 0.145829 * sg
        l1 += 265.18 * cg - 121.29 * sg
        g = str * (venusEarth + 2.0 * (a.d - a.mPrime))
        cg = cos(g); sg = sin(g)
        l += 0.070201 * cg + 0.140542 * sg
        l1 += 255.36 * cg - 116.79 * sg
        g = str * (a.earth + a.d - a.f)
        cg = cos(g); sg = sin(g)
        l += 0.288209 * cg - 0.025901 * sg
        l1 += -63.51 * cg - 240.14 * sg
        g = str * (2.0 * a.earth - 3.0 * a.jupiter + 2.0 * a.d - a.mPrime)
        cg = cos(g); sg = sin(g)
        l += 0.077865 * cg + 0.438460 * sg
        l1 += 210.57 * cg + 124.84 * sg
        g = str * (a.earth - 2.0 * a.mars)
        cg = cos(g); sg = sin(g)
        l += -0.216579 * cg + 0.241702 * sg
        l1 += 197.67 * cg + 125.23 * sg
        g = str * (earthMarsJupiter + a.mPrime)
        cg = cos(g); sg = sin(g)
        l += -0.165009 * cg + 0.044176 * sg
        l1 += 4.67 * cg + 201.55 * sg
        g = str * (earthMarsJupiter + 2.0 * a.d - a.mPrime)
        cg = cos(g); sg = sin(g)
        l += -0.133533 * cg + 0.041116 * sg
        l1 += 6.95 * cg + 187.07 * sg
        g = str * (earthMarsJupiter - 2.0 * a.d + a.mPrime)
        cg = cos(g); sg = sin(g)
        l += -0.133430 * cg + 0.041079 * sg
        l1 += 6.28 * cg + 169.08 * sg
        g = str * (3.0 * a.venus - 4.0 * a.earth)
        cg = cos(g); sg = sin(g)
        l += -0.175074 * cg + 0.003035 * sg
        l1 += 49.17 * cg + 150.57 * sg
        g = str * (2.0 * (a.earth + a.d - a.mPrime) - 3.0 * a.jupiter + 213_534.0)
        l1 += 158.4 * sin(g)
        l1 += acc.longitude
        let poissonScale = 0.1 * t          // amplitude scale becomes 10⁻⁴″ / 10⁻⁴ km
        acc.latitude *= poissonScale
        acc.radius *= poissonScale

        // --- Terms in T⁰ (arc-seconds).
        l += 1.14307 * sin(str * (2.0 * (a.earth - a.jupiter + a.d) - a.mPrime + 648_431.172))
        l += 0.82155 * sin(str * (a.venus - a.earth + 648_035.568))
        l += 0.64371 * sin(str * (3.0 * (a.venus - a.earth) + 2.0 * a.d - a.mPrime + 647_933.184))
        l += 0.63880 * sin(str * (a.earth - a.jupiter + 4424.04))
        l += 0.49331 * sin(str * (a.lPrime + a.mPrime - a.f + 4.68))
        l += 0.4914 * sin(str * (a.lPrime - a.mPrime - a.f + 4.68))
        l += 0.36061 * sin(str * (a.lPrime + a.f + 2.52))
        l += 0.30154 * sin(str * (2.0 * a.venus - 2.0 * a.earth + 736.2))
        l += 0.28282 * sin(str * (2.0 * a.earth - 3.0 * a.jupiter + 2.0 * a.d - 2.0 * a.mPrime + 36_138.2))
        l += 0.24516 * sin(str * (2.0 * a.earth - 2.0 * a.jupiter + 2.0 * a.d - 2.0 * a.mPrime + 311.0))
        l += 0.21117 * sin(str * (a.earth - a.jupiter - 2.0 * a.d + a.mPrime + 6275.88))
        l += 0.19444 * sin(str * (2.0 * (a.earth - a.mars) - 846.36))
        l -= 0.18457 * sin(str * (2.0 * (a.earth - a.jupiter) + 1569.96))
        l += 0.18256 * sin(str * (2.0 * (a.earth - a.jupiter) - a.mPrime - 55.8))
        l += 0.16499 * sin(str * (a.earth - a.jupiter - 2.0 * a.d + 6490.08))
        l += 0.16427 * sin(str * (a.earth - 2.0 * a.jupiter - 212_378.4))
        l += 0.16088 * sin(str * (2.0 * (a.venus - a.earth - a.d) + a.mPrime + 1122.48))
        l -= 0.15350 * sin(str * (a.venus - a.earth - a.mPrime + 32.04))
        l += 0.14346 * sin(str * (a.earth - a.jupiter - a.mPrime + 4488.88))
        l += 0.13594 * sin(str * (2.0 * (a.venus - a.earth + a.d) - a.mPrime - 8.64))
        l += 0.13432 * sin(str * (2.0 * (a.venus - a.earth - a.d) + 1319.76))
        l -= 0.13122 * sin(str * (a.venus - a.earth - 2.0 * a.d + a.mPrime - 56.16))
        l -= 0.12722 * sin(str * (a.venus - a.earth + a.mPrime + 54.36))
        l += 0.12539 * sin(str * (3.0 * (a.venus - a.earth) - a.mPrime + 433.8))
        l += 0.10994 * sin(str * (a.earth - a.jupiter + a.mPrime + 4002.12))
        l += 0.10652 * sin(str * (20.0 * a.venus - 21.0 * a.earth - 2.0 * a.d + a.mPrime - 317_511.72))
        l += 0.10490 * sin(str * (26.0 * a.venus - 29.0 * a.earth - a.mPrime + 270_002.52))
        l += 0.10386 * sin(str * (3.0 * a.venus - 4.0 * a.earth + a.d - a.mPrime - 322_765.56))
        var b = 8.04508 * sin(str * (a.lPrime + 648_002.556))
        b += 1.51021 * sin(str * (a.earth + a.d + 996_048.252))
        b += 0.63037 * sin(str * (venusEarth - a.mPrime + a.f + 95_554.332))
        b += 0.63014 * sin(str * (venusEarth - a.mPrime - a.f + 95_553.792))
        b += 0.45587 * sin(str * (a.lPrime - a.mPrime + 2.9))
        b += -0.41573 * sin(str * (a.lPrime + a.mPrime + 2.5))
        b += 0.32623 * sin(str * (a.lPrime - 2.0 * a.f + 3.2))
        b += 0.29855 * sin(str * (a.lPrime - 2.0 * a.d + 2.5))

        // --- Main tables (10⁻⁴″, 10⁻⁴ km) and assembly.
        acc.longitude = 0.0
        addLargeLongitudeRadius(lrTerms, angles, into: &acc)
        addLargeLatitude(mbTerms, angles, into: &acc)
        l += (((l4 * t + l3) * t + l2) * t + l1) * t * 1.0e-5
        let longitudeArcseconds = modTurn(a.lPrime + l + 1.0e-4 * acc.longitude)
        let latitudeArcseconds = 1.0e-4 * acc.latitude + b
        let distanceKm = 1.0e-4 * acc.radius + meanDistanceKm
        return (Angle.normalize(longitudeArcseconds / 3600.0), latitudeArcseconds / 3600.0, distanceKm)
    }

    /// Longitude/radius T⁰ terms — D, l′, l, F, longitude (1″ and 0.0001″ parts), radius (1 km and 0.0001 km parts); 118 rows.
    static let lrTerms: [Int] = [
        0, 0, 1, 0, 22639, 5858, -20905, -3550,
        2, 0, -1, 0, 4586, 4383, -3699, -1109,
        2, 0, 0, 0, 2369, 9139, -2955, -9676,
        0, 0, 2, 0, 769, 257, -569, -9251,
        0, 1, 0, 0, -666, -4171, 48, 8883,
        0, 0, 0, 2, -411, -5957, -3, -1483,
        2, 0, -2, 0, 211, 6556, 246, 1585,
        2, -1, -1, 0, 205, 4358, -152, -1377,
        2, 0, 1, 0, 191, 9562, -170, -7331,
        2, -1, 0, 0, 164, 7285, -204, -5860,
        0, 1, -1, 0, -147, -3213, -129, -6201,
        1, 0, 0, 0, -124, -9881, 108, 7427,
        0, 1, 1, 0, -109, -3803, 104, 7552,
        2, 0, 0, -2, 55, 1771, 10, 3211,
        0, 0, 1, 2, -45, -996, 0, 0,
        0, 0, 1, -2, 39, 5333, 79, 6606,
        4, 0, -1, 0, 38, 4298, -34, -7825,
        0, 0, 3, 0, 36, 1238, -23, -2104,
        4, 0, -2, 0, 30, 7726, -21, -6363,
        2, 1, -1, 0, -28, -3971, 24, 2085,
        2, 1, 0, 0, -24, -3582, 30, 8238,
        1, 0, -1, 0, -18, -5847, -8, -3791,
        1, 1, 0, 0, 17, 9545, -16, -6747,
        2, -1, 1, 0, 14, 5303, -12, -8314,
        2, 0, 2, 0, 14, 3797, -10, -4448,
        4, 0, 0, 0, 13, 8991, -11, -6500,
        2, 0, -3, 0, 13, 1941, 14, 4027,
        0, 1, -2, 0, -9, -6791, -7, -27,
        2, 0, -1, 2, -9, -3659, 0, 7740,
        2, -1, -2, 0, 8, 6055, 10, 562,
        1, 0, 1, 0, -8, -4531, 6, 3220,
        2, -2, 0, 0, 8, 502, -9, -8845,
        0, 1, 2, 0, -7, -6302, 5, 7509,
        0, 2, 0, 0, -7, -4475, 1, 657,
        2, -2, -1, 0, 7, 3712, -4, -9501,
        2, 0, 1, -2, -6, -3832, 4, 1311,
        2, 0, 0, 2, -5, -7416, 0, 0,
        4, -1, -1, 0, 4, 3740, -3, -9580,
        0, 0, 2, 2, -3, -9976, 0, 0,
        3, 0, -1, 0, -3, -2097, 3, 2582,
        2, 1, 1, 0, -2, -9145, 2, 6164,
        4, -1, -2, 0, 2, 7319, -1, -8970,
        0, 2, -1, 0, -2, -5679, -2, -1171,
        2, 2, -1, 0, -2, -5212, 2, 3536,
        2, 1, -2, 0, 2, 4889, 0, 1437,
        2, -1, 0, -2, 2, 1461, 0, 6571,
        4, 0, 1, 0, 1, 9777, -1, -4226,
        0, 0, 4, 0, 1, 9337, -1, -1169,
        4, -1, 0, 0, 1, 8708, -1, -5714,
        1, 0, -2, 0, -1, -7530, -1, -7385,
        2, 1, 0, -2, -1, -4372, 0, -1357,
        0, 0, 2, -2, -1, -3726, -4, -4212,
        1, 1, 1, 0, 1, 2618, 0, -9333,
        3, 0, -2, 0, -1, -2241, 0, 8624,
        4, 0, -3, 0, 1, 1868, 0, -5142,
        2, -1, 2, 0, 1, 1770, 0, -8488,
        0, 2, 1, 0, -1, -1617, 1, 1655,
        1, 1, -1, 0, 1, 777, 0, 8512,
        2, 0, 3, 0, 1, 595, 0, -6697,
        2, 0, 1, 2, 0, -9902, 0, 0,
        2, 0, -4, 0, 0, 9483, 0, 7785,
        2, -2, 1, 0, 0, 7517, 0, -6575,
        0, 1, -3, 0, 0, -6694, 0, -4224,
        4, 1, -1, 0, 0, -6352, 0, 5788,
        1, 0, 2, 0, 0, -5840, 0, 3785,
        1, 0, 0, -2, 0, -5833, 0, -7956,
        6, 0, -2, 0, 0, 5716, 0, -4225,
        2, 0, -2, -2, 0, -5606, 0, 4726,
        1, -1, 0, 0, 0, -5569, 0, 4976,
        0, 1, 3, 0, 0, -5459, 0, 3551,
        2, 0, -2, 2, 0, -5357, 0, 7740,
        2, 0, -1, -2, 0, 1790, 8, 7516,
        3, 0, 0, 0, 0, 4042, -1, -4189,
        2, -1, -3, 0, 0, 4784, 0, 4950,
        2, -1, 3, 0, 0, 932, 0, -585,
        2, 0, 2, -2, 0, -4538, 0, 2840,
        2, -1, -1, 2, 0, -4262, 0, 373,
        0, 0, 0, 4, 0, 4203, 0, 0,
        0, 1, 0, 2, 0, 4134, 0, -1580,
        6, 0, -1, 0, 0, 3945, 0, -2866,
        2, -1, 0, 2, 0, -3821, 0, 0,
        2, -1, 1, -2, 0, -3745, 0, 2094,
        4, 1, -2, 0, 0, -3576, 0, 2370,
        1, 1, -2, 0, 0, 3497, 0, 3323,
        2, -3, 0, 0, 0, 3398, 0, -4107,
        0, 0, 3, 2, 0, -3286, 0, 0,
        4, -2, -1, 0, 0, -3087, 0, -2790,
        0, 1, -1, -2, 0, 3015, 0, 0,
        4, 0, -1, -2, 0, 3009, 0, -3218,
        2, -2, -2, 0, 0, 2942, 0, 3430,
        6, 0, -3, 0, 0, 2925, 0, -1832,
        2, 1, 2, 0, 0, -2902, 0, 2125,
        4, 1, 0, 0, 0, -2891, 0, 2445,
        4, -1, 1, 0, 0, 2825, 0, -2029,
        3, 1, -1, 0, 0, 2737, 0, -2126,
        0, 1, 1, 2, 0, 2634, 0, 0,
        1, 0, 0, 2, 0, 2543, 0, 0,
        3, 0, 0, -2, 0, -2530, 0, 2010,
        2, 2, -2, 0, 0, -2499, 0, -1089,
        2, -3, -1, 0, 0, 2469, 0, -1481,
        3, -1, -1, 0, 0, -2314, 0, 2556,
        4, 0, 2, 0, 0, 2185, 0, -1392,
        4, 0, -1, 2, 0, -2013, 0, 0,
        0, 2, -2, 0, 0, -1931, 0, 0,
        2, 2, 0, 0, 0, -1858, 0, 0,
        2, 1, -3, 0, 0, 1762, 0, 0,
        4, 0, -2, 2, 0, -1698, 0, 0,
        4, -2, -2, 0, 0, 1578, 0, -1083,
        4, -2, 0, 0, 0, 1522, 0, -1281,
        3, 1, 0, 0, 0, 1499, 0, -1077,
        1, -1, -1, 0, 0, -1364, 0, 1141,
        1, -3, 0, 0, 0, -1281, 0, 0,
        6, 0, 0, 0, 0, 1261, 0, -859,
        2, 0, 2, 2, 0, -1239, 0, 0,
        1, -1, 1, 0, 0, -1207, 0, 1100,
        0, 0, 5, 0, 0, 1110, 0, -589,
        0, 3, 0, 0, 0, -1013, 0, 213,
        4, -1, -3, 0, 0, 998, 0, 0,
    ]

    /// Latitude T⁰ terms — D, l′, l, F, latitude (1″ and 0.0001″ parts); 77 rows.
    static let mbTerms: [Int] = [
        0, 0, 0, 1, 18461, 2387,
        0, 0, 1, 1, 1010, 1671,
        0, 0, 1, -1, 999, 6936,
        2, 0, 0, -1, 623, 6524,
        2, 0, -1, 1, 199, 4837,
        2, 0, -1, -1, 166, 5741,
        2, 0, 0, 1, 117, 2607,
        0, 0, 2, 1, 61, 9120,
        2, 0, 1, -1, 33, 3572,
        0, 0, 2, -1, 31, 7597,
        2, -1, 0, -1, 29, 5766,
        2, 0, -2, -1, 15, 5663,
        2, 0, 1, 1, 15, 1216,
        2, 1, 0, -1, -12, -941,
        2, -1, -1, 1, 8, 8681,
        2, -1, 0, 1, 7, 9586,
        2, -1, -1, -1, 7, 4346,
        0, 1, -1, -1, -6, -7314,
        4, 0, -1, -1, 6, 5796,
        0, 1, 0, 1, -6, -4601,
        0, 0, 0, 3, -6, -2965,
        0, 1, -1, 1, -5, -6324,
        1, 0, 0, 1, -5, -3684,
        0, 1, 1, 1, -5, -3113,
        0, 1, 1, -1, -5, -759,
        0, 1, 0, -1, -4, -8396,
        1, 0, 0, -1, -4, -8057,
        0, 0, 3, 1, 3, 9841,
        4, 0, 0, -1, 3, 6745,
        4, 0, -1, 1, 2, 9985,
        0, 0, 1, -3, 2, 7986,
        4, 0, -2, 1, 2, 4139,
        2, 0, 0, -3, 2, 1863,
        2, 0, 2, -1, 2, 1462,
        2, -1, 1, -1, 1, 7660,
        2, 0, -2, 1, -1, -6244,
        0, 0, 3, -1, 1, 5813,
        2, 0, 2, 1, 1, 5198,
        2, 0, -3, -1, 1, 5156,
        2, 1, -1, 1, -1, -3178,
        2, 1, 0, 1, -1, -2643,
        4, 0, 0, 1, 1, 1919,
        2, -1, 1, 1, 1, 1346,
        2, -2, 0, -1, 1, 859,
        0, 0, 1, 3, -1, -194,
        2, 1, 1, -1, 0, -8227,
        1, 1, 0, -1, 0, 8042,
        1, 1, 0, 1, 0, 8026,
        0, 1, -2, -1, 0, -7932,
        2, 1, -1, -1, 0, -7910,
        1, 0, 1, 1, 0, -6674,
        2, -1, -2, -1, 0, 6502,
        0, 1, 2, 1, 0, -6388,
        4, 0, -2, -1, 0, 6337,
        4, -1, -1, -1, 0, 5958,
        1, 0, 1, -1, 0, -5889,
        4, 0, 1, -1, 0, 4734,
        1, 0, -1, -1, 0, -4299,
        4, -1, 0, -1, 0, 4149,
        2, -2, 0, 1, 0, 3835,
        3, 0, 0, -1, 0, -3518,
        4, -1, -1, 1, 0, 3388,
        2, 0, -1, -3, 0, 3291,
        2, -2, -1, 1, 0, 3147,
        0, 1, 2, -1, 0, -3129,
        3, 0, -1, -1, 0, -3052,
        0, 1, -2, 1, 0, -3013,
        2, 0, 1, -3, 0, -2912,
        2, -2, -1, -1, 0, 2686,
        0, 0, 4, 1, 0, 2633,
        2, 0, -3, 1, 0, 2541,
        2, 0, -1, 3, 0, -2448,
        2, 1, 1, 1, 0, -2370,
        4, -1, -2, 1, 0, 2138,
        4, 0, 1, 1, 0, 2126,
        3, 0, -1, 1, 0, -2059,
        4, 1, -1, -1, 0, -1719,
    ]

    /// Longitude/radius terms multiplied by T — D, l′, l, F, longitude (0.1″ and 0.00001″ parts), radius (0.1 km and 0.00001 km parts); 38 rows.
    static let lrtTerms: [Int] = [
        0, 1, 0, 0, 16, 7680, -1, -2302,
        2, -1, -1, 0, -5, -1642, 3, 8245,
        2, -1, 0, 0, -4, -1383, 5, 1395,
        0, 1, -1, 0, 3, 7115, 3, 2654,
        0, 1, 1, 0, 2, 7560, -2, -6396,
        2, 1, -1, 0, 0, 7118, 0, -6068,
        2, 1, 0, 0, 0, 6128, 0, -7754,
        1, 1, 0, 0, 0, -4516, 0, 4194,
        2, -2, 0, 0, 0, -4048, 0, 4970,
        0, 2, 0, 0, 0, 3747, 0, -540,
        2, -2, -1, 0, 0, -3707, 0, 2490,
        2, -1, 1, 0, 0, -3649, 0, 3222,
        0, 1, -2, 0, 0, 2438, 0, 1760,
        2, -1, -2, 0, 0, -2165, 0, -2530,
        0, 1, 2, 0, 0, 1923, 0, -1450,
        0, 2, -1, 0, 0, 1292, 0, 1070,
        2, 2, -1, 0, 0, 1271, 0, -6070,
        4, -1, -1, 0, 0, -1098, 0, 990,
        2, 0, 0, 0, 0, 1073, 0, -1360,
        2, 0, -1, 0, 0, 839, 0, -630,
        2, 1, 1, 0, 0, 734, 0, -660,
        4, -1, -2, 0, 0, -688, 0, 480,
        2, 1, -2, 0, 0, -630, 0, 0,
        0, 2, 1, 0, 0, 587, 0, -590,
        2, -1, 0, -2, 0, -540, 0, -170,
        4, -1, 0, 0, 0, -468, 0, 390,
        2, -2, 1, 0, 0, -378, 0, 330,
        2, 1, 0, -2, 0, 364, 0, 0,
        1, 1, 1, 0, 0, -317, 0, 240,
        2, -1, 2, 0, 0, -295, 0, 210,
        1, 1, -1, 0, 0, -270, 0, -210,
        2, -3, 0, 0, 0, -256, 0, 310,
        2, -3, -1, 0, 0, -187, 0, 110,
        0, 1, -3, 0, 0, 169, 0, 110,
        4, 1, -1, 0, 0, 158, 0, -150,
        4, -2, -1, 0, 0, -155, 0, 140,
        0, 0, 1, 0, 0, 155, 0, -250,
        2, -2, -2, 0, 0, -148, 0, -170,
    ]

    /// Latitude terms multiplied by T — D, l′, l, F, latitude (0.00001″); 16 rows.
    static let btTerms: [Int] = [
        2, -1, 0, -1, -7430,
        2, 1, 0, -1, 3043,
        2, -1, -1, 1, -2229,
        2, -1, 0, 1, -1999,
        2, -1, -1, -1, -1869,
        0, 1, -1, -1, 1696,
        0, 1, 0, 1, 1623,
        0, 1, -1, 1, 1418,
        0, 1, 1, 1, 1339,
        0, 1, 1, -1, 1278,
        0, 1, 0, -1, 1217,
        2, -2, 0, -1, -547,
        2, -1, 1, -1, -443,
        2, 1, -1, 1, 331,
        2, 1, 0, 1, 317,
        2, 0, 0, -1, 295,
    ]

    /// Longitude/radius terms multiplied by T² — D, l′, l, F, longitude (0.00001″), radius (0.00001 km); 25 rows.
    static let lrt2Terms: [Int] = [
        0, 1, 0, 0, 487, -36,
        2, -1, -1, 0, -150, 111,
        2, -1, 0, 0, -120, 149,
        0, 1, -1, 0, 108, 95,
        0, 1, 1, 0, 80, -77,
        2, 1, -1, 0, 21, -18,
        2, 1, 0, 0, 20, -23,
        1, 1, 0, 0, -13, 12,
        2, -2, 0, 0, -12, 14,
        2, -1, 1, 0, -11, 9,
        2, -2, -1, 0, -11, 7,
        0, 2, 0, 0, 11, 0,
        2, -1, -2, 0, -6, -7,
        0, 1, -2, 0, 7, 5,
        0, 1, 2, 0, 6, -4,
        2, 2, -1, 0, 5, -3,
        0, 2, -1, 0, 5, 3,
        4, -1, -1, 0, -3, 3,
        2, 0, 0, 0, 3, -4,
        4, -1, -2, 0, -2, 0,
        2, 1, -2, 0, -2, 0,
        2, -1, 0, -2, -2, 0,
        2, 1, 1, 0, 2, -2,
        2, 0, -1, 0, 2, 0,
        0, 2, 1, 0, 2, 0,
    ]

    /// Latitude terms multiplied by T² — D, l′, l, F, latitude (0.00001″); 12 rows.
    static let bt2Terms: [Int] = [
        2, -1, 0, -1, -22,
        2, 1, 0, -1, 9,
        2, -1, 0, 1, -6,
        2, -1, -1, 1, -6,
        2, -1, -1, -1, -5,
        0, 1, 0, 1, 5,
        0, 1, -1, -1, 5,
        0, 1, 1, 1, 4,
        0, 1, 1, -1, 4,
        0, 1, 0, -1, 4,
        0, 1, -1, 1, 4,
        2, -2, 0, -1, -2,
    ]

    /// Secular corrections from the least-squares fit to DE404 (−3000…+3000): the first twelve replace
    /// the T², T³, T⁴ coefficients of F, l, D and L (arc-seconds); the rest are longitude Poisson-term
    /// coefficients in 10⁻⁵ arc-second.
    static let z: [Double] = [
        -1.312045233711e+01, -1.138215912580e-03, -9.646018347184e-06,
        3.146734198839e+01, 4.768357585780e-02, -3.421689790404e-04,
        -6.847070905410e+00, -5.834100476561e-03, -2.905334122698e-04,
        -5.663161722088e+00, 5.722859298199e-03, -8.466472828815e-05,
        -8.429817796435e+01, -2.072552484689e+02, 7.876842214863e+00,
        1.836463749022e+00, -1.557471855361e+01, -2.006969124724e+01,
        2.152670284757e+01, -6.179946916139e+00, -9.070028191196e-01,
        -1.270848233038e+01, -2.145589319058e+00, 1.381936399935e+01,
        -1.999840061168e+00,
    ]
}
