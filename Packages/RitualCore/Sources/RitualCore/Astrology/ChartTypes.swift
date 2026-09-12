import Foundation

// MARK: - Calendar helpers (internal)

/// Proleptic-Gregorian Julian Day conversions used by ``BirthData`` and ``Syzygy``.
///
/// Internal so that `JulianDay` (the public astrology API) can delegate to it and the two
/// stay consistent. Meeus, *Astronomical Algorithms*, chapter 7, Gregorian branch only.
enum JulianDayMath {
    /// Julian Day (UT) for a Gregorian calendar date and decimal hour (Meeus 7.1).
    ///
    /// - Parameters:
    ///   - year: Astronomical year (1 BC = 0).
    ///   - month: Month 1…12.
    ///   - day: Day of month.
    ///   - hourUT: Decimal hours since 0h UT.
    static func julianDay(year: Int, month: Int, day: Int, hourUT: Double) -> Double {
        var y = Double(year)
        var m = Double(month)
        if month <= 2 {
            y -= 1
            m += 12
        }
        let a = (y / 100.0).rounded(.down)
        let b = 2.0 - a + (a / 4.0).rounded(.down)
        let yearTerm = (365.25 * (y + 4716.0)).rounded(.down)
        let monthTerm = (30.6001 * (m + 1.0)).rounded(.down)
        return yearTerm + monthTerm + Double(day) + hourUT / 24.0 + b - 1524.5
    }

    /// Gregorian calendar date and decimal hour for a Julian Day (Meeus chapter 7).
    ///
    /// A non-finite Julian Day has no calendar date and yields the sentinel
    /// `(0, 0, 0, jd)` (month and day 0 never occur for finite input) instead of trapping.
    static func calendar(fromJulianDay jd: Double) -> (year: Int, month: Int, day: Int, hourUT: Double) {
        guard jd.isFinite else { return (0, 0, 0, jd) }
        let shifted = jd + 0.5
        let z = shifted.rounded(.down)
        let fraction = shifted - z
        let alpha = ((z - 1_867_216.25) / 36524.25).rounded(.down)
        let a = z + 1.0 + alpha - (alpha / 4.0).rounded(.down)
        let b = a + 1524.0
        let c = ((b - 122.1) / 365.25).rounded(.down)
        let d = (365.25 * c).rounded(.down)
        let e = ((b - d) / 30.6001).rounded(.down)
        let day = Int(b - d - (30.6001 * e).rounded(.down))
        let month = Int(e < 14.0 ? e - 1.0 : e - 13.0)
        let year = Int(month > 2 ? c - 4716.0 : c - 4715.0)
        return (year, month, day, fraction * 24.0)
    }

    /// Formats a Julian Day as `"YYYY-MM-DD HH:MM UT"`, rounding to the nearest minute
    /// (carrying into the next hour/day when the rounding crosses a boundary). A
    /// non-finite instant prints as `"????-??-?? ??:?? UT"`.
    static func formattedUT(julianDay jd: Double) -> String {
        guard jd.isFinite else { return "????-??-?? ??:?? UT" }
        let dayStart = (jd + 0.5).rounded(.down) - 0.5
        var minutes = Int(((jd - dayStart) * 1440.0).rounded())
        var dayJD = dayStart
        if minutes >= 1440 {
            minutes -= 1440
            dayJD += 1.0
        }
        let date = calendar(fromJulianDay: dayJD)
        return String(format: "%04d-%02d-%02d %02d:%02d UT", date.year, date.month, date.day, minutes / 60, minutes % 60)
    }
}

// MARK: - BirthData

/// Date, time and place of birth. Times are Universal Time; longitude is positive **east**.
public struct BirthData: Codable, Sendable, Equatable {
    /// Gregorian year.
    public var year: Int
    /// Month 1…12.
    public var month: Int
    /// Day of month.
    public var day: Int
    /// Decimal hours since 0h UT (13.5 = 13:30 UT).
    public var hourUT: Double
    /// Geographic latitude in degrees, north positive.
    public var latitude: Double
    /// Geographic longitude in degrees, east positive (Portland is −122.68).
    public var longitudeEast: Double

    /// Creates birth data.
    ///
    /// - Parameters:
    ///   - year: Gregorian year.
    ///   - month: Month 1…12.
    ///   - day: Day of month.
    ///   - hourUT: Decimal hours since 0h UT.
    ///   - latitude: Latitude in degrees, north positive.
    ///   - longitudeEast: Longitude in degrees, east positive.
    public init(year: Int, month: Int, day: Int, hourUT: Double, latitude: Double, longitudeEast: Double) {
        self.year = year
        self.month = month
        self.day = day
        self.hourUT = hourUT
        self.latitude = latitude
        self.longitudeEast = longitudeEast
    }

    /// Julian Day (UT) of the birth instant (Meeus 7.1, Gregorian calendar).
    public var jdUT: Double {
        JulianDayMath.julianDay(year: year, month: month, day: day, hourUT: hourUT)
    }

    /// Whether `hourUT`, `latitude` and `longitudeEast` are all finite.
    ///
    /// ``NatalChart/compute(birth:)`` requires finite input; check this first to reject
    /// data that would otherwise be silently replaced by ``sanitized``.
    public var isFinite: Bool {
        hourUT.isFinite && latitude.isFinite && longitudeEast.isFinite
    }

    /// A copy in which every non-finite floating-point field (`hourUT`, `latitude`,
    /// `longitudeEast`) is replaced by 0 — 0h UT at the Greenwich equator — so that every
    /// downstream computation stays defined and encodable.
    public var sanitized: BirthData {
        BirthData(
            year: year, month: month, day: day,
            hourUT: hourUT.isFinite ? hourUT : 0,
            latitude: latitude.isFinite ? latitude : 0,
            longitudeEast: longitudeEast.isFinite ? longitudeEast : 0
        )
    }

    /// 16 Aug 2002 13:00 UT, Portland OR (45.5152, −122.6784) — the chart of Appendix A.
    public static let owner = BirthData(
        year: 2002, month: 8, day: 16, hourUT: 13.0,
        latitude: 45.5152, longitudeEast: -122.6784
    )
}

// MARK: - Zodiac

/// The four classical elements as assigned to zodiac signs.
public enum ChartElement: String, Codable, Sendable, CaseIterable {
    case fire, earth, air, water
}

/// The twelve tropical signs, 30° each from 0° Aries.
public enum ZodiacSign: Int, CaseIterable, Codable, Sendable {
    case aries = 0, taurus, gemini, cancer, leo, virgo, libra, scorpio, sagittarius, capricorn, aquarius, pisces

    /// Full English name ("Sagittarius").
    public var name: String {
        switch self {
        case .aries: return "Aries"
        case .taurus: return "Taurus"
        case .gemini: return "Gemini"
        case .cancer: return "Cancer"
        case .leo: return "Leo"
        case .virgo: return "Virgo"
        case .libra: return "Libra"
        case .scorpio: return "Scorpio"
        case .sagittarius: return "Sagittarius"
        case .capricorn: return "Capricorn"
        case .aquarius: return "Aquarius"
        case .pisces: return "Pisces"
        }
    }

    /// Three-letter abbreviation ("Sag").
    public var abbreviation: String {
        String(name.prefix(3))
    }

    /// Traditional (Ptolemaic) domicile ruler.
    public var ruler: Planet {
        switch self {
        case .aries, .scorpio: return .mars
        case .taurus, .libra: return .venus
        case .gemini, .virgo: return .mercury
        case .cancer: return .moon
        case .leo: return .sun
        case .sagittarius, .pisces: return .jupiter
        case .capricorn, .aquarius: return .saturn
        }
    }

    /// Elemental triplicity.
    public var element: ChartElement {
        switch self {
        case .aries, .leo, .sagittarius: return .fire
        case .taurus, .virgo, .capricorn: return .earth
        case .gemini, .libra, .aquarius: return .air
        case .cancer, .scorpio, .pisces: return .water
        }
    }

    /// Planet exalted in this sign (traditional), or `nil` for the five signs without one.
    public var exaltedPlanet: Planet? {
        switch self {
        case .aries: return .sun
        case .taurus: return .moon
        case .cancer: return .jupiter
        case .virgo: return .mercury
        case .libra: return .saturn
        case .capricorn: return .mars
        case .pisces: return .venus
        case .gemini, .leo, .scorpio, .sagittarius, .aquarius: return nil
        }
    }

    /// The sign 180° away.
    public var opposite: ZodiacSign {
        ZodiacSign.allCases[(rawValue + 6) % 12]
    }

    /// Ecliptic longitude of the sign's first degree (0, 30, …, 330).
    public var startLongitude: Double {
        Double(rawValue) * 30.0
    }

    /// The sign containing an ecliptic longitude (any value; normalised to [0, 360)).
    /// A non-finite longitude maps to Aries, matching ``ZodiacPosition/init(longitude:)``.
    public static func containing(longitude: Double) -> ZodiacSign {
        guard longitude.isFinite else { return .aries }
        let normalized = Angle.normalize(longitude)
        let index = min(11, max(0, Int((normalized / 30.0).rounded(.down))))
        return ZodiacSign.allCases[index]
    }
}

// MARK: - Planet

/// The seven traditional planets in kamea order (Saturn 3 … Moon 9).
public enum Planet: String, CaseIterable, Codable, Sendable {
    case saturn, jupiter, mars, sun, venus, mercury, moon

    /// Order of the planet's magic square (Agrippa II.22): Saturn 3, Jupiter 4, Mars 5,
    /// Sun 6, Venus 7, Mercury 8, Moon 9.
    public var kameaOrder: Int {
        switch self {
        case .saturn: return 3
        case .jupiter: return 4
        case .mars: return 5
        case .sun: return 6
        case .venus: return 7
        case .mercury: return 8
        case .moon: return 9
        }
    }

    /// Signs the planet rules (traditional domiciles).
    public var domiciles: [ZodiacSign] {
        switch self {
        case .saturn: return [.capricorn, .aquarius]
        case .jupiter: return [.sagittarius, .pisces]
        case .mars: return [.aries, .scorpio]
        case .sun: return [.leo]
        case .venus: return [.taurus, .libra]
        case .mercury: return [.gemini, .virgo]
        case .moon: return [.cancer]
        }
    }

    /// Sign of exaltation.
    public var exaltation: ZodiacSign? {
        switch self {
        case .saturn: return .libra
        case .jupiter: return .cancer
        case .mars: return .capricorn
        case .sun: return .aries
        case .venus: return .pisces
        case .mercury: return .virgo
        case .moon: return .taurus
        }
    }

    /// Signs opposite the domiciles (detriment).
    public var detriments: [ZodiacSign] {
        domiciles.map(\.opposite)
    }

    /// Sign opposite the exaltation (fall).
    public var fall: ZodiacSign? {
        exaltation?.opposite
    }

    /// Capitalised English name ("Saturn").
    public var name: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// Essential dignity of the planet when placed in `sign`
    /// (domicile > exaltation > detriment > fall > peregrine).
    public func dignity(in sign: ZodiacSign) -> Dignity {
        if domiciles.contains(sign) { return .domicile }
        if exaltation == sign { return .exaltation }
        if detriments.contains(sign) { return .detriment }
        if fall == sign { return .fall }
        return .peregrine
    }
}

/// Essential dignity of a planet by sign.
public enum Dignity: String, Codable, Sendable, CaseIterable {
    case domicile, exaltation, detriment, fall, peregrine

    /// Wording used by the Appendix A report ("in domicile", "exalted", …).
    public var reportPhrase: String {
        switch self {
        case .domicile: return "in domicile"
        case .exaltation: return "exalted"
        case .detriment: return "in detriment"
        case .fall: return "in fall"
        case .peregrine: return "peregrine"
        }
    }
}

// MARK: - ZodiacPosition

/// An ecliptic longitude with its zodiacal decomposition and Appendix A formatting.
///
/// Two decompositions are exposed. `sign` and `degreeInSign` are exact: the sign is the
/// one containing `longitude`. `roundedSign`, `degrees` and `minutes` describe the
/// position after rounding to the nearest arc-minute, *carrying* across sign boundaries,
/// so they are always mutually consistent (`degrees` is 0…29) and `roundedSign` can be
/// the sign after `sign` when the longitude lies within half a minute below a boundary
/// (Pisces wraps to Aries). `formatted` prints the rounded decomposition.
public struct ZodiacPosition: Codable, Sendable, Equatable {
    /// Ecliptic longitude in degrees, normalised to [0, 360).
    public let longitude: Double

    /// Creates a position, normalising `longitude` into [0, 360).
    ///
    /// A non-finite longitude (NaN or ±∞) has no place on the ecliptic and is mapped to
    /// 0° Aries so that every derived property stays defined and encodable.
    public init(longitude: Double) {
        self.longitude = longitude.isFinite ? Angle.normalize(longitude) : 0.0
    }

    private enum CodingKeys: String, CodingKey {
        case longitude
    }

    /// Decodes and re-normalises the longitude.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(longitude: try container.decode(Double.self, forKey: .longitude))
    }

    /// Sign containing the exact longitude.
    public var sign: ZodiacSign {
        ZodiacSign.containing(longitude: longitude)
    }

    /// Degrees into `sign`, in [0, 30).
    public var degreeInSign: Double {
        longitude - sign.startLongitude
    }

    /// Sign of the position after rounding to the nearest arc-minute: equals `sign` unless
    /// the minutes carry past 29°59′, in which case it is the following sign.
    public var roundedSign: ZodiacSign {
        ZodiacSign.allCases[roundedTotalMinutes / Self.minutesPerSign]
    }

    /// Whole degrees into `roundedSign` (0…29) after rounding to the nearest arc-minute;
    /// a carry past 29°59′ advances `roundedSign` and reads 0°00′.
    public var degrees: Int {
        (roundedTotalMinutes % Self.minutesPerSign) / 60
    }

    /// Arc-minutes after rounding to the nearest minute (0…59).
    public var minutes: Int {
        roundedTotalMinutes % 60
    }

    /// Arc-minutes in one sign (30 × 60).
    private static let minutesPerSign = 1800
    /// Arc-minutes in the full circle (360 × 60).
    private static let minutesPerCircle = 21_600

    /// The longitude rounded to the nearest arc-minute, as whole minutes from 0° Aries in
    /// [0, 21600). The minutes within the exact sign are rounded first so the value carries
    /// into the next sign (and from Pisces round to Aries) exactly when they reach 30°00′.
    private var roundedTotalMinutes: Int {
        let minutesInSign = Int((degreeInSign * 60.0).rounded())
        return (sign.rawValue * Self.minutesPerSign + minutesInSign) % Self.minutesPerCircle
    }

    /// Appendix A form, e.g. `"23°30' Leo (143.494°)"`: the rounded decomposition and the
    /// decimal longitude to three places. A decimal that rounds up to `360.000` is printed
    /// as `0.000` so the report never leaves [0, 360).
    public var formatted: String {
        let minuteText = String(format: "%02d", minutes)
        var longitudeText = String(format: "%.3f", longitude)
        if longitudeText == "360.000" {
            longitudeText = "0.000"
        }
        return "\(degrees)°\(minuteText)' \(roundedSign.name) (\(longitudeText)°)"
    }
}

// MARK: - Sect and syzygy

/// Diurnal sect of a chart.
public enum Sect: String, Codable, Sendable {
    case day, night
}

/// Kind of lunation.
public enum SyzygyKind: String, Codable, Sendable {
    case newMoon, fullMoon

    /// Display name ("New Moon" / "Full Moon").
    public var name: String {
        switch self {
        case .newMoon: return "New Moon"
        case .fullMoon: return "Full Moon"
        }
    }
}

/// A New or Full Moon: instant and the longitude of the luminary that defines it
/// (Sun for a New Moon, Moon for a Full Moon).
public struct Syzygy: Codable, Sendable, Equatable {
    /// New or Full.
    public let kind: SyzygyKind
    /// Instant as a Julian Day (UT).
    public let jdUT: Double
    /// Ecliptic longitude of the syzygy point, degrees in [0, 360).
    public let longitude: Double

    /// Creates a syzygy record.
    ///
    /// - Parameters:
    ///   - kind: New or Full Moon.
    ///   - jdUT: Instant as a Julian Day (UT).
    ///   - longitude: Longitude of the syzygy point in degrees.
    public init(kind: SyzygyKind, jdUT: Double, longitude: Double) {
        self.kind = kind
        self.jdUT = jdUT
        self.longitude = longitude
    }

    /// The syzygy point as a ``ZodiacPosition``.
    public var position: ZodiacPosition {
        ZodiacPosition(longitude: longitude)
    }

    /// Instant formatted as `"2002-08-08 19:15 UT"` (rounded to the nearest minute).
    public var formattedInstantUT: String {
        JulianDayMath.formattedUT(julianDay: jdUT)
    }
}

// MARK: - NatalChart

/// The computed natal chart. `compute(birth:)` lives in the astrology module; this file
/// holds the value type, its memberwise initialiser and the Appendix A report.
public struct NatalChart: Codable, Sendable, Equatable {
    /// Birth data the chart was cast for.
    public let birth: BirthData
    /// Apparent geocentric Sun.
    public let sun: ZodiacPosition
    /// Apparent geocentric Moon.
    public let moon: ZodiacPosition
    /// Ascendant.
    public let ascendant: ZodiacPosition
    /// Midheaven (MC).
    public let midheaven: ZodiacPosition
    /// Geometric altitude of the Sun in degrees (no refraction).
    public let sunAltitude: Double
    /// Night iff `sunAltitude < 0`.
    public let sect: Sect
    /// Last New or Full Moon before birth.
    public let prenatalSyzygy: Syzygy
    /// Lot of Fortune (night: ASC + Sun − Moon; day: ASC + Moon − Sun).
    public let lotOfFortune: ZodiacPosition
    /// Lot of Spirit (night: ASC + Moon − Sun; day: ASC + Sun − Moon).
    public let lotOfSpirit: ZodiacPosition
    /// Ruler of the Ascendant sign.
    public let chartRuler: Planet
    /// Position of the chart ruler when known (Sun/Moon); `nil` for planets not computed.
    public let rulerPosition: ZodiacPosition?
    /// Dignity of the ruler by sign (`peregrine` when the position is unknown).
    public let rulerDignity: Dignity
    /// Whether the ruler is within 15° of the Ascendant.
    public let rulerRising: Bool

    /// Memberwise initialiser.
    ///
    /// - Parameters:
    ///   - birth: Birth data.
    ///   - sun: Sun position.
    ///   - moon: Moon position.
    ///   - ascendant: Ascendant.
    ///   - midheaven: Midheaven.
    ///   - sunAltitude: Geometric Sun altitude in degrees.
    ///   - sect: Day or night.
    ///   - prenatalSyzygy: Last lunation before birth.
    ///   - lotOfFortune: Lot of Fortune.
    ///   - lotOfSpirit: Lot of Spirit.
    ///   - chartRuler: Ruler of the Ascendant sign.
    ///   - rulerPosition: Ruler position if known.
    ///   - rulerDignity: Ruler dignity.
    ///   - rulerRising: Whether the ruler is rising.
    public init(
        birth: BirthData,
        sun: ZodiacPosition,
        moon: ZodiacPosition,
        ascendant: ZodiacPosition,
        midheaven: ZodiacPosition,
        sunAltitude: Double,
        sect: Sect,
        prenatalSyzygy: Syzygy,
        lotOfFortune: ZodiacPosition,
        lotOfSpirit: ZodiacPosition,
        chartRuler: Planet,
        rulerPosition: ZodiacPosition?,
        rulerDignity: Dignity,
        rulerRising: Bool
    ) {
        self.birth = birth
        self.sun = sun
        self.moon = moon
        self.ascendant = ascendant
        self.midheaven = midheaven
        self.sunAltitude = sunAltitude
        self.sect = sect
        self.prenatalSyzygy = prenatalSyzygy
        self.lotOfFortune = lotOfFortune
        self.lotOfSpirit = lotOfSpirit
        self.chartRuler = chartRuler
        self.rulerPosition = rulerPosition
        self.rulerDignity = rulerDignity
        self.rulerRising = rulerRising
    }

    /// The nine-line Appendix A report, lines joined by `"\n"` with no trailing newline:
    ///
    /// ```
    /// Sun 23°30' Leo (143.494°)
    /// Moon 7°42' Sagittarius (247.694°)
    /// Ascendant 20°13' Leo (140.211°)
    /// MC 9°28' Taurus (39.468°)
    /// Sun altitude −2.87° → night chart
    /// Prenatal syzygy New Moon 2002-08-08 19:15 UT 16°04' Leo (136.063°)
    /// Lot of Fortune 6°01' Taurus (36.010°)
    /// Lot of Spirit 4°25' Sagittarius (244.411°)
    /// Chart ruler Sun — in domicile, rising
    /// ```
    ///
    /// Negative altitudes use U+2212 MINUS SIGN; the ruler line uses an em dash and appends
    /// `", rising"` only when `rulerRising` is true.
    public func appendixAReport() -> String {
        let risingSuffix = rulerRising ? ", rising" : ""
        let lines = [
            "Sun \(sun.formatted)",
            "Moon \(moon.formatted)",
            "Ascendant \(ascendant.formatted)",
            "MC \(midheaven.formatted)",
            "Sun altitude \(Self.formatAltitude(sunAltitude)) → \(sect.rawValue) chart",
            "Prenatal syzygy \(prenatalSyzygy.kind.name) \(prenatalSyzygy.formattedInstantUT) \(prenatalSyzygy.position.formatted)",
            "Lot of Fortune \(lotOfFortune.formatted)",
            "Lot of Spirit \(lotOfSpirit.formatted)",
            "Chart ruler \(chartRuler.name) — \(rulerDignity.reportPhrase)\(risingSuffix)",
        ]
        return lines.joined(separator: "\n")
    }

    /// Formats an altitude with two decimals and a typographic minus (U+2212) for negatives.
    private static func formatAltitude(_ altitude: Double) -> String {
        let magnitude = String(format: "%.2f", abs(altitude))
        let sign = (altitude < 0 && magnitude != "0.00") ? "\u{2212}" : ""
        return "\(sign)\(magnitude)°"
    }
}
