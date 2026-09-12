import Foundation

extension NatalChart {
    /// Orb within which the chart ruler counts as rising (conjunct the Ascendant).
    public static let risingOrbDegrees = 15.0

    /// Casts the chart: apparent Sun and Moon, Ascendant and MC, Sun altitude and sect,
    /// prenatal syzygy, Lots of Fortune and Spirit, and the Ascendant ruler's condition.
    ///
    /// Lots follow the traditional day/night reversal: by night Fortune = ASC + Sun − Moon
    /// and Spirit = ASC + Moon − Sun; by day the two formulas swap. Only the Sun and Moon
    /// are computed, so a chart ruler other than the luminaries has no position, is
    /// reported as peregrine and never as rising.
    ///
    /// - Parameter birth: Date, time (UT) and place of birth.
    /// - Returns: The fully derived ``NatalChart``.
    public static func compute(birth: BirthData) -> NatalChart {
        let jdUT = birth.jdUT
        let jdTT = JulianDay.terrestrialTime(fromUT: jdUT)

        let sun = ZodiacPosition(longitude: Ephemeris.sun(jdUT: jdUT).longitude)
        let moon = ZodiacPosition(longitude: Ephemeris.moon(jdUT: jdUT).longitude)

        let obliquity = Ephemeris.trueObliquity(jdTT: jdTT)
        let ramc = Ephemeris.localApparentSiderealTime(jdUT: jdUT, longitudeEast: birth.longitudeEast)
        let midheaven = ZodiacPosition(longitude: Ephemeris.midheaven(ramc: ramc, obliquity: obliquity))
        let ascendant = ZodiacPosition(
            longitude: Ephemeris.ascendant(ramc: ramc, latitude: birth.latitude, obliquity: obliquity)
        )

        let sunAltitude = Ephemeris.sunAltitude(jdUT: jdUT, latitude: birth.latitude, longitudeEast: birth.longitudeEast)
        let sect: Sect = sunAltitude < 0 ? .night : .day

        let syzygy = SyzygyFinder.prenatal(before: jdUT)

        let sunMinusMoon = sun.longitude - moon.longitude
        let lotOfFortune: ZodiacPosition
        let lotOfSpirit: ZodiacPosition
        switch sect {
        case .night:
            lotOfFortune = ZodiacPosition(longitude: ascendant.longitude + sunMinusMoon)
            lotOfSpirit = ZodiacPosition(longitude: ascendant.longitude - sunMinusMoon)
        case .day:
            lotOfFortune = ZodiacPosition(longitude: ascendant.longitude - sunMinusMoon)
            lotOfSpirit = ZodiacPosition(longitude: ascendant.longitude + sunMinusMoon)
        }

        let chartRuler = ascendant.sign.ruler
        let rulerPosition = luminaryPosition(of: chartRuler, sun: sun, moon: moon)
        let rulerDignity = rulerPosition.map { chartRuler.dignity(in: $0.sign) } ?? .peregrine
        let rulerRising = rulerPosition.map { position in
            abs(Angle.wrap180(position.longitude - ascendant.longitude)) <= risingOrbDegrees
        } ?? false

        return NatalChart(
            birth: birth,
            sun: sun,
            moon: moon,
            ascendant: ascendant,
            midheaven: midheaven,
            sunAltitude: sunAltitude,
            sect: sect,
            prenatalSyzygy: syzygy,
            lotOfFortune: lotOfFortune,
            lotOfSpirit: lotOfSpirit,
            chartRuler: chartRuler,
            rulerPosition: rulerPosition,
            rulerDignity: rulerDignity,
            rulerRising: rulerRising
        )
    }

    /// The computed position of a planet when it is one of the luminaries, else `nil`.
    private static func luminaryPosition(of planet: Planet, sun: ZodiacPosition, moon: ZodiacPosition) -> ZodiacPosition? {
        switch planet {
        case .sun: return sun
        case .moon: return moon
        case .saturn, .jupiter, .mars, .venus, .mercury: return nil
        }
    }
}
