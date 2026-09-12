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

    /// Apparent geocentric Moon referred to the true ecliptic and equinox of date.
    ///
    /// This is the shipped lunar engine: the textbook series of Meeus chapter 47
    /// (ELP-2000/82 truncated to the 60 + 60 terms of Tables 47.A/47.B with the E factor
    /// and the A1/A2/A3 additive terms — about 10″ in longitude, 4″ in latitude and 4 km in
    /// distance) plus nutation in longitude. The result is well inside the contract's
    /// 0.05° tolerance against the project's reference vectors. No other lunar theory is
    /// used; ``moonMeeus(jdUT:)`` names the same evaluation.
    ///
    /// - Parameter jdUT: Julian Day in Universal Time (converted to TT internally).
    /// - Returns: Longitude in [0, 360) and latitude in degrees, distance in kilometres.
    public static func moon(jdUT: Double) -> (longitude: Double, latitude: Double, distanceKm: Double) {
        let jdTT = JulianDay.terrestrialTime(fromUT: jdUT)
        let geometric = moonMeeusGeometric(jdTT: jdTT)
        let deltaPsi = nutation(jdTT: jdTT).longitude
        return (Angle.normalize(geometric.longitude + deltaPsi), geometric.latitude, geometric.distanceKm)
    }

    /// The Meeus chapter 47 Moon under its explicit name — an alias of ``moon(jdUT:)``,
    /// kept so callers that asked for the published reference series by name keep working
    /// (the two are one and the same evaluation).
    ///
    /// - Parameter jdUT: Julian Day in Universal Time (converted to TT internally).
    /// - Returns: Longitude in [0, 360) and latitude in degrees, distance in kilometres.
    public static func moonMeeus(jdUT: Double) -> (longitude: Double, latitude: Double, distanceKm: Double) {
        moon(jdUT: jdUT)
    }
}
