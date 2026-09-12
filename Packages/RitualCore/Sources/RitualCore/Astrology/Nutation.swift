import Foundation

/// Solar, lunar and sidereal-time ephemeris routines used to cast a natal chart.
///
/// The implementation follows Meeus, *Astronomical Algorithms* (2nd ed.):
/// - Sun: VSOP87D Earth (Appendix III truncation), FK5 correction, nutation, aberration
///   (`SolarPosition.swift`).
/// - Moon: the chapter 47 series (ELP-2000/82 truncated to the 60 + 60 terms of Tables
///   47.A/47.B) plus nutation in longitude (`LunarPosition.swift`).
/// - Nutation: the full 63-term IAU 1980 series, Table 22.A; mean obliquity: Laskar 22.3
///   (this file).
/// - Sidereal time (chapter 12) and the horizon/ecliptic angles (`SiderealTime.swift`,
///   `Angles.swift`).
///
/// Contract time scales: every function taking `jdUT` converts to Terrestrial Time with
/// ``JulianDay/deltaT(jd:)`` before evaluating a dynamical theory; sidereal time itself is
/// a function of UT. All angles are degrees, longitudes normalised to [0, 360).
public enum Ephemeris {}

// MARK: - Nutation and obliquity

/// One row of the IAU 1980 nutation series (Meeus Table 22.A).
struct NutationTerm {
    /// Multipliers of the Delaunay arguments D, M, M′, F and Ω.
    let d: Double, m: Double, mPrime: Double, f: Double, omega: Double
    /// Sine coefficient for Δψ (0.0001″) and its rate per Julian century.
    let sin0: Double, sin1: Double
    /// Cosine coefficient for Δε (0.0001″) and its rate per Julian century.
    let cos0: Double, cos1: Double

    init(_ d: Double, _ m: Double, _ mPrime: Double, _ f: Double, _ omega: Double,
         _ sin0: Double, _ sin1: Double, _ cos0: Double, _ cos1: Double) {
        self.d = d
        self.m = m
        self.mPrime = mPrime
        self.f = f
        self.omega = omega
        self.sin0 = sin0
        self.sin1 = sin1
        self.cos0 = cos0
        self.cos1 = cos1
    }
}

extension Ephemeris {
    /// Meeus Table 22.A: the 63 terms of the 1980 IAU Theory of Nutation.
    /// Columns: D, M, M′, F, Ω, Δψ sine coefficient, its T-rate, Δε cosine coefficient, its T-rate.
    static let nutationTerms: [NutationTerm] = [
        NutationTerm( 0,  0,  0,  0,  1, -171996, -174.2,  92025,  8.9),
        NutationTerm(-2,  0,  0,  2,  2,  -13187,   -1.6,   5736, -3.1),
        NutationTerm( 0,  0,  0,  2,  2,   -2274,   -0.2,    977, -0.5),
        NutationTerm( 0,  0,  0,  0,  2,    2062,    0.2,   -895,  0.5),
        NutationTerm( 0,  1,  0,  0,  0,    1426,   -3.4,     54, -0.1),
        NutationTerm( 0,  0,  1,  0,  0,     712,    0.1,     -7,  0.0),
        NutationTerm(-2,  1,  0,  2,  2,    -517,    1.2,    224, -0.6),
        NutationTerm( 0,  0,  0,  2,  1,    -386,   -0.4,    200,  0.0),
        NutationTerm( 0,  0,  1,  2,  2,    -301,    0.0,    129, -0.1),
        NutationTerm(-2, -1,  0,  2,  2,     217,   -0.5,    -95,  0.3),
        NutationTerm(-2,  0,  1,  0,  0,    -158,    0.0,      0,  0.0),
        NutationTerm(-2,  0,  0,  2,  1,     129,    0.1,    -70,  0.0),
        NutationTerm( 0,  0, -1,  2,  2,     123,    0.0,    -53,  0.0),
        NutationTerm( 2,  0,  0,  0,  0,      63,    0.0,      0,  0.0),
        NutationTerm( 0,  0,  1,  0,  1,      63,    0.1,    -33,  0.0),
        NutationTerm( 2,  0, -1,  2,  2,     -59,    0.0,     26,  0.0),
        NutationTerm( 0,  0, -1,  0,  1,     -58,   -0.1,     32,  0.0),
        NutationTerm( 0,  0,  1,  2,  1,     -51,    0.0,     27,  0.0),
        NutationTerm(-2,  0,  2,  0,  0,      48,    0.0,      0,  0.0),
        NutationTerm( 0,  0, -2,  2,  1,      46,    0.0,    -24,  0.0),
        NutationTerm( 2,  0,  0,  2,  2,     -38,    0.0,     16,  0.0),
        NutationTerm( 0,  0,  2,  2,  2,     -31,    0.0,     13,  0.0),
        NutationTerm( 0,  0,  2,  0,  0,      29,    0.0,      0,  0.0),
        NutationTerm(-2,  0,  1,  2,  2,      29,    0.0,    -12,  0.0),
        NutationTerm( 0,  0,  0,  2,  0,      26,    0.0,      0,  0.0),
        NutationTerm(-2,  0,  0,  2,  0,     -22,    0.0,      0,  0.0),
        NutationTerm( 0,  0, -1,  2,  1,      21,    0.0,    -10,  0.0),
        NutationTerm( 0,  2,  0,  0,  0,      17,   -0.1,      0,  0.0),
        NutationTerm( 2,  0, -1,  0,  1,      16,    0.0,     -8,  0.0),
        NutationTerm(-2,  2,  0,  2,  2,     -16,    0.1,      7,  0.0),
        NutationTerm( 0,  1,  0,  0,  1,     -15,    0.0,      9,  0.0),
        NutationTerm(-2,  0,  1,  0,  1,     -13,    0.0,      7,  0.0),
        NutationTerm( 0, -1,  0,  0,  1,     -12,    0.0,      6,  0.0),
        NutationTerm( 0,  0,  2, -2,  0,      11,    0.0,      0,  0.0),
        NutationTerm( 2,  0, -1,  2,  1,     -10,    0.0,      5,  0.0),
        NutationTerm( 2,  0,  1,  2,  2,      -8,    0.0,      3,  0.0),
        NutationTerm( 0,  1,  0,  2,  2,       7,    0.0,     -3,  0.0),
        NutationTerm(-2,  1,  1,  0,  0,      -7,    0.0,      0,  0.0),
        NutationTerm( 0, -1,  0,  2,  2,      -7,    0.0,      3,  0.0),
        NutationTerm( 2,  0,  0,  2,  1,      -7,    0.0,      3,  0.0),
        NutationTerm( 2,  0,  1,  0,  0,       6,    0.0,      0,  0.0),
        NutationTerm(-2,  0,  2,  2,  2,       6,    0.0,     -3,  0.0),
        NutationTerm(-2,  0,  1,  2,  1,       6,    0.0,     -3,  0.0),
        NutationTerm( 2,  0, -2,  0,  1,      -6,    0.0,      3,  0.0),
        NutationTerm( 2,  0,  0,  0,  1,      -6,    0.0,      3,  0.0),
        NutationTerm( 0, -1,  1,  0,  0,       5,    0.0,      0,  0.0),
        NutationTerm(-2, -1,  0,  2,  1,      -5,    0.0,      3,  0.0),
        NutationTerm(-2,  0,  0,  0,  1,      -5,    0.0,      3,  0.0),
        NutationTerm( 0,  0,  2,  2,  1,      -5,    0.0,      3,  0.0),
        NutationTerm(-2,  0,  2,  0,  1,       4,    0.0,      0,  0.0),
        NutationTerm(-2,  1,  0,  2,  1,       4,    0.0,      0,  0.0),
        NutationTerm( 0,  0,  1, -2,  0,       4,    0.0,      0,  0.0),
        NutationTerm(-1,  0,  1,  0,  0,      -4,    0.0,      0,  0.0),
        NutationTerm(-2,  1,  0,  0,  0,      -4,    0.0,      0,  0.0),
        NutationTerm( 1,  0,  0,  0,  0,      -4,    0.0,      0,  0.0),
        NutationTerm( 0,  0,  1,  2,  0,       3,    0.0,      0,  0.0),
        NutationTerm( 0,  0, -2,  2,  2,      -3,    0.0,      0,  0.0),
        NutationTerm(-1, -1,  1,  0,  0,      -3,    0.0,      0,  0.0),
        NutationTerm( 0,  1,  1,  0,  0,      -3,    0.0,      0,  0.0),
        NutationTerm( 0, -1,  1,  2,  2,      -3,    0.0,      0,  0.0),
        NutationTerm( 2, -1, -1,  2,  2,      -3,    0.0,      0,  0.0),
        NutationTerm( 0,  0,  3,  2,  2,      -3,    0.0,      0,  0.0),
        NutationTerm( 2, -1,  0,  2,  2,      -3,    0.0,      0,  0.0),
    ]

    /// Nutation in longitude (Δψ) and in obliquity (Δε), IAU 1980 theory, Meeus ch. 22
    /// with the full 63-term Table 22.A.
    ///
    /// - Parameter jdTT: Julian Day in Terrestrial Time.
    /// - Returns: Δψ and Δε in degrees (Δψ ≈ ±0.005°, Δε ≈ ±0.0025°).
    public static func nutation(jdTT: Double) -> (longitude: Double, obliquity: Double) {
        let t = JulianDay.centuriesSinceJ2000(jdTT)
        let t2 = t * t
        let t3 = t2 * t
        // Delaunay arguments (Meeus 22.x), degrees.
        let d = 297.85036 + 445_267.111480 * t - 0.0019142 * t2 + t3 / 189_474.0
        let m = 357.52772 + 35_999.050340 * t - 0.0001603 * t2 - t3 / 300_000.0
        let mPrime = 134.96298 + 477_198.867398 * t + 0.0086972 * t2 + t3 / 56_250.0
        let f = 93.27191 + 483_202.017538 * t - 0.0036825 * t2 + t3 / 327_270.0
        let omega = 125.04452 - 1934.136261 * t + 0.0020708 * t2 + t3 / 450_000.0

        var deltaPsi = 0.0
        var deltaEpsilon = 0.0
        for term in nutationTerms {
            let argumentDegrees = term.d * d + term.m * m + term.mPrime * mPrime + term.f * f + term.omega * omega
            let argument = Angle.deg2rad(argumentDegrees)
            deltaPsi += (term.sin0 + term.sin1 * t) * sin(argument)
            deltaEpsilon += (term.cos0 + term.cos1 * t) * cos(argument)
        }
        // Coefficients are in units of 0.0001 arc-second.
        let arcsecondsToDegrees = 1.0 / 3600.0
        return (deltaPsi * 0.0001 * arcsecondsToDegrees, deltaEpsilon * 0.0001 * arcsecondsToDegrees)
    }

    /// Mean obliquity of the ecliptic ε₀, Laskar's polynomial (Meeus 22.3), degrees.
    ///
    /// Valid to ~0.01″ over ±1000 years from J2000.0 and to a few arc-seconds over
    /// ±10 000 years.
    ///
    /// - Parameter jdTT: Julian Day in Terrestrial Time.
    public static func meanObliquity(jdTT: Double) -> Double {
        let u = JulianDay.centuriesSinceJ2000(jdTT) / 100.0
        let coefficients: [Double] = [
            -4680.93, -1.55, 1999.25, -51.38, -249.67, -39.05, 7.12, 27.87, 5.79, 2.45,
        ]
        var arcseconds = 0.0
        var power = 1.0
        for coefficient in coefficients {
            power *= u
            arcseconds += coefficient * power
        }
        let base = 23.0 + 26.0 / 60.0 + 21.448 / 3600.0
        return base + arcseconds / 3600.0
    }

    /// True obliquity ε = ε₀ + Δε, degrees.
    ///
    /// - Parameter jdTT: Julian Day in Terrestrial Time.
    public static func trueObliquity(jdTT: Double) -> Double {
        meanObliquity(jdTT: jdTT) + nutation(jdTT: jdTT).obliquity
    }
}
