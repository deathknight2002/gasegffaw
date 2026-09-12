import Foundation

extension Ephemeris {
    /// Ecliptic longitude of the midheaven for a given RAMC.
    ///
    /// MC = atan2(sin θ, cos θ cos ε), which is quadrant-correct for every θ.
    ///
    /// - Parameters:
    ///   - ramc: Right ascension of the midheaven (local apparent sidereal time), degrees.
    ///   - obliquity: True obliquity of the ecliptic, degrees.
    /// - Returns: MC longitude in [0, 360).
    public static func midheaven(ramc: Double, obliquity: Double) -> Double {
        let theta = Angle.deg2rad(ramc)
        let epsilon = Angle.deg2rad(obliquity)
        return Angle.normalize(Angle.rad2deg(atan2(sin(theta), cos(theta) * cos(epsilon))))
    }

    /// Ecliptic longitude of the ascendant.
    ///
    /// ASC = atan2(cos θ, −(sin θ cos ε + tan φ sin ε)). For latitudes inside the polar
    /// circles the closed form can return the descendant; the result is therefore forced
    /// into the eastern half-circle relative to the MC (0° < ASC − MC < 180°) by adding
    /// 180° when needed.
    ///
    /// - Parameters:
    ///   - ramc: Right ascension of the midheaven, degrees.
    ///   - latitude: Geographic latitude, degrees (north positive).
    ///   - obliquity: True obliquity of the ecliptic, degrees.
    /// - Returns: Ascendant longitude in [0, 360).
    public static func ascendant(ramc: Double, latitude: Double, obliquity: Double) -> Double {
        let theta = Angle.deg2rad(ramc)
        let phi = Angle.deg2rad(latitude)
        let epsilon = Angle.deg2rad(obliquity)
        let denominator = -(sin(theta) * cos(epsilon) + tan(phi) * sin(epsilon))
        var ascendant = Angle.normalize(Angle.rad2deg(atan2(cos(theta), denominator)))
        let mc = midheaven(ramc: ramc, obliquity: obliquity)
        if Angle.normalize(ascendant - mc) > 180.0 {
            ascendant = Angle.normalize(ascendant + 180.0)
        }
        return ascendant
    }

    /// Converts ecliptic to equatorial coordinates (Meeus 13.3 and 13.4).
    ///
    /// - Parameters:
    ///   - longitude: Ecliptic longitude λ, degrees.
    ///   - latitude: Ecliptic latitude β, degrees.
    ///   - obliquity: Obliquity of the ecliptic ε, degrees.
    /// - Returns: Right ascension in [0, 360) and declination in degrees.
    public static func eclipticToEquatorial(longitude: Double, latitude: Double, obliquity: Double) -> (ra: Double, dec: Double) {
        let lambda = Angle.deg2rad(longitude)
        let beta = Angle.deg2rad(latitude)
        let epsilon = Angle.deg2rad(obliquity)
        let ra = atan2(sin(lambda) * cos(epsilon) - tan(beta) * sin(epsilon), cos(lambda))
        let sinDec = sin(beta) * cos(epsilon) + cos(beta) * sin(epsilon) * sin(lambda)
        let dec = asin(max(-1.0, min(1.0, sinDec)))
        return (Angle.normalize(Angle.rad2deg(ra)), Angle.rad2deg(dec))
    }

    /// Geometric altitude above the horizon (no refraction, no parallax), Meeus 13.6.
    ///
    /// - Parameters:
    ///   - ra: Right ascension, degrees.
    ///   - dec: Declination, degrees.
    ///   - lst: Local (apparent) sidereal time, degrees.
    ///   - latitude: Geographic latitude, degrees.
    /// - Returns: Altitude in degrees, in [−90, 90].
    public static func altitude(ra: Double, dec: Double, lst: Double, latitude: Double) -> Double {
        let hourAngle = Angle.deg2rad(lst - ra)
        let phi = Angle.deg2rad(latitude)
        let delta = Angle.deg2rad(dec)
        let sinAltitude = sin(phi) * sin(delta) + cos(phi) * cos(delta) * cos(hourAngle)
        return Angle.rad2deg(asin(max(-1.0, min(1.0, sinAltitude))))
    }

    /// Geometric altitude of the apparent Sun for an observer.
    ///
    /// - Parameters:
    ///   - jdUT: Julian Day in Universal Time.
    ///   - latitude: Geographic latitude, degrees (north positive).
    ///   - longitudeEast: Geographic longitude, degrees (east positive).
    /// - Returns: Altitude in degrees; negative when the Sun is below the horizon.
    public static func sunAltitude(jdUT: Double, latitude: Double, longitudeEast: Double) -> Double {
        let position = sun(jdUT: jdUT)
        let epsilon = trueObliquity(jdTT: JulianDay.terrestrialTime(fromUT: jdUT))
        let equatorial = eclipticToEquatorial(longitude: position.longitude, latitude: position.latitude, obliquity: epsilon)
        let lst = localApparentSiderealTime(jdUT: jdUT, longitudeEast: longitudeEast)
        return altitude(ra: equatorial.ra, dec: equatorial.dec, lst: lst, latitude: latitude)
    }
}
