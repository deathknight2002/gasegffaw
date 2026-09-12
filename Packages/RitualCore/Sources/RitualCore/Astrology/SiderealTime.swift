import Foundation

extension Ephemeris {
    /// Greenwich mean sidereal time in degrees (Meeus 12.4), for any instant of UT.
    ///
    /// θ₀ = 280.46061837 + 360.98564736629 (JD − 2451545) + 0.000387933 T² − T³/38710000,
    /// with T in Julian centuries of UT.
    ///
    /// - Parameter jdUT: Julian Day in Universal Time.
    /// - Returns: GMST in degrees, normalised to [0, 360).
    public static func greenwichMeanSiderealTime(jdUT: Double) -> Double {
        let daysSinceJ2000 = jdUT - JulianDay.j2000
        let t = JulianDay.centuriesSinceJ2000(jdUT)
        let t2 = t * t
        let theta = 280.46061837
            + 360.98564736629 * daysSinceJ2000
            + 0.000387933 * t2
            - t2 * t / 38_710_000.0
        return Angle.normalize(theta)
    }

    /// Greenwich apparent sidereal time in degrees: GMST plus the equation of the
    /// equinoxes Δψ cos ε (nutation evaluated in Terrestrial Time).
    ///
    /// - Parameter jdUT: Julian Day in Universal Time.
    public static func greenwichApparentSiderealTime(jdUT: Double) -> Double {
        let jdTT = JulianDay.terrestrialTime(fromUT: jdUT)
        let deltaPsi = nutation(jdTT: jdTT).longitude
        let epsilon = trueObliquity(jdTT: jdTT)
        let equationOfEquinoxes = deltaPsi * cos(Angle.deg2rad(epsilon))
        return Angle.normalize(greenwichMeanSiderealTime(jdUT: jdUT) + equationOfEquinoxes)
    }

    /// Local apparent sidereal time — the right ascension of the midheaven (RAMC) — in
    /// degrees.
    ///
    /// - Parameters:
    ///   - jdUT: Julian Day in Universal Time.
    ///   - longitudeEast: Geographic longitude in degrees, east positive.
    /// - Returns: LAST = GAST + longitude, normalised to [0, 360).
    public static func localApparentSiderealTime(jdUT: Double, longitudeEast: Double) -> Double {
        Angle.normalize(greenwichApparentSiderealTime(jdUT: jdUT) + longitudeEast)
    }
}
