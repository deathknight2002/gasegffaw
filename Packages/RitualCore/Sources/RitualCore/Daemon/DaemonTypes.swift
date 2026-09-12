import Foundation

// MARK: - Hebrew letters

/// The 22 Hebrew letters in alphabetical order with their gematria values.
///
/// Used by the Agrippa name derivation: a hylegical place `n` degrees past the
/// Ascendant maps to letter `floor(n) mod 22`.
public enum HebrewLetter: Int, CaseIterable, Codable, Sendable {
    case aleph = 0, beth, gimel, daleth, he, vav, zayin, chet, tet, yod, kaf, lamed,
         mem, nun, samekh, ayin, pe, tsade, qof, resh, shin, tav

    /// Unicode Hebrew character (non-final form).
    public var character: Character {
        let glyphs: [Character] = [
            "\u{05D0}", "\u{05D1}", "\u{05D2}", "\u{05D3}", "\u{05D4}", "\u{05D5}", "\u{05D6}",
            "\u{05D7}", "\u{05D8}", "\u{05D9}", "\u{05DB}", "\u{05DC}", "\u{05DE}", "\u{05E0}",
            "\u{05E1}", "\u{05E2}", "\u{05E4}", "\u{05E6}", "\u{05E7}", "\u{05E8}", "\u{05E9}", "\u{05EA}",
        ]
        return glyphs[rawValue]
    }

    /// Transliterated name ("Aleph", "Beth", …).
    public var name: String {
        let names = [
            "Aleph", "Beth", "Gimel", "Daleth", "He", "Vav", "Zayin", "Chet", "Tet", "Yod", "Kaf",
            "Lamed", "Mem", "Nun", "Samekh", "Ayin", "Pe", "Tsade", "Qof", "Resh", "Shin", "Tav",
        ]
        return names[rawValue]
    }

    /// Latin initial used for the display name:
    /// A B G D H V Z C T Y K L M N S O P X Q R S T.
    public var latin: Character {
        let initials: [Character] = [
            "A", "B", "G", "D", "H", "V", "Z", "C", "T", "Y", "K",
            "L", "M", "N", "S", "O", "P", "X", "Q", "R", "S", "T",
        ]
        return initials[rawValue]
    }

    /// Gematria value: 1…9 (Aleph–Tet), 10…90 (Yod–Tsade), 100…400 (Qof–Tav).
    public var value: Int {
        switch rawValue {
        case 0..<9: return rawValue + 1
        case 9..<18: return (rawValue - 8) * 10
        default: return (rawValue - 17) * 100
        }
    }
}

// MARK: - Name derivation

/// The five hylegical places, in the fixed order used to spell the daemon's name.
public enum HylegicalPlace: String, CaseIterable, Codable, Sendable {
    case sun, moon, ascendant, fortune, syzygy

    /// Display title ("Sun", "Moon", "Ascendant", "Lot of Fortune", "Prenatal syzygy").
    public var title: String {
        switch self {
        case .sun: return "Sun"
        case .moon: return "Moon"
        case .ascendant: return "Ascendant"
        case .fortune: return "Lot of Fortune"
        case .syzygy: return "Prenatal syzygy"
        }
    }
}

/// One letter of the name and the place it was derived from.
public struct NamePlacement: Codable, Sendable, Equatable {
    /// The hylegical place.
    public let place: HylegicalPlace
    /// Ecliptic longitude of the place, degrees in [0, 360).
    public let longitude: Double
    /// `normalize(longitude − ascendant)`, degrees in [0, 360).
    public let offsetFromAscendant: Double
    /// Letter assigned: index `floor(offsetFromAscendant) mod 22`.
    public let letter: HebrewLetter

    /// Creates a placement record.
    ///
    /// - Parameters:
    ///   - place: The hylegical place.
    ///   - longitude: Its ecliptic longitude in degrees.
    ///   - offsetFromAscendant: Degrees past the Ascendant, in [0, 360).
    ///   - letter: The derived letter.
    public init(place: HylegicalPlace, longitude: Double, offsetFromAscendant: Double, letter: HebrewLetter) {
        self.place = place
        self.longitude = longitude
        self.offsetFromAscendant = offsetFromAscendant
        self.letter = letter
    }
}

// MARK: - Daemon attributes

/// Bodily form of the daemon, one per Sun sign.
public enum DaemonForm: String, Codable, Sendable, CaseIterable {
    /// Aries.
    case ramHorned
    /// Taurus.
    case bull
    /// Gemini.
    case twinFaced
    /// Cancer.
    case carapaced
    /// Leo.
    case leonine
    /// Virgo.
    case veiled
    /// Libra.
    case winged
    /// Scorpio.
    case chitinous
    /// Sagittarius.
    case centaur
    /// Capricorn.
    case goatHorned
    /// Aquarius.
    case manyEyed
    /// Pisces.
    case finned

    /// The form associated with a zodiac sign.
    public static func forSign(_ sign: ZodiacSign) -> DaemonForm {
        switch sign {
        case .aries: return .ramHorned
        case .taurus: return .bull
        case .gemini: return .twinFaced
        case .cancer: return .carapaced
        case .leo: return .leonine
        case .virgo: return .veiled
        case .libra: return .winged
        case .scorpio: return .chitinous
        case .sagittarius: return .centaur
        case .capricorn: return .goatHorned
        case .aquarius: return .manyEyed
        case .pisces: return .finned
        }
    }
}

/// Colour palette of the daemon, one per traditional planet (the chart ruler).
public enum DaemonPalette: String, Codable, Sendable, CaseIterable {
    /// Sun.
    case goldWhiteFire
    /// Moon.
    case silverBlue
    /// Mercury.
    case quicksilver
    /// Venus.
    case copperGreen
    /// Mars.
    case ironRed
    /// Jupiter.
    case tinViolet
    /// Saturn.
    case leadBlack

    /// The palette associated with a planet.
    public static func forPlanet(_ planet: Planet) -> DaemonPalette {
        switch planet {
        case .sun: return .goldWhiteFire
        case .moon: return .silverBlue
        case .mercury: return .quicksilver
        case .venus: return .copperGreen
        case .mars: return .ironRed
        case .jupiter: return .tinViolet
        case .saturn: return .leadBlack
        }
    }
}

/// Element of the daemon (triplicity of the sign holding the Lot of Spirit).
public enum DaemonElement: String, Codable, Sendable, CaseIterable {
    case fire, earth, air, water

    /// The daemon element matching a chart element.
    public init(chartElement: ChartElement) {
        switch chartElement {
        case .fire: self = .fire
        case .earth: self = .earth
        case .air: self = .air
        case .water: self = .water
        }
    }
}

/// Movement style of the daemon, one per Moon sign.
public enum DaemonMotion: String, Codable, Sendable, CaseIterable {
    /// Aries.
    case abruptThrusting
    /// Taurus.
    case groundedSlow
    /// Gemini.
    case flickeringDual
    /// Cancer.
    case tidalSway
    /// Leo.
    case radiantPacing
    /// Virgo.
    case preciseMinute
    /// Libra.
    case balancedGlide
    /// Scorpio.
    case coiledStrike
    /// Sagittarius.
    case expansiveArcing
    /// Capricorn.
    case measuredClimb
    /// Aquarius.
    case erraticDrift
    /// Pisces.
    case flowingDissolve

    /// The motion associated with a zodiac sign.
    public static func forSign(_ sign: ZodiacSign) -> DaemonMotion {
        switch sign {
        case .aries: return .abruptThrusting
        case .taurus: return .groundedSlow
        case .gemini: return .flickeringDual
        case .cancer: return .tidalSway
        case .leo: return .radiantPacing
        case .virgo: return .preciseMinute
        case .libra: return .balancedGlide
        case .scorpio: return .coiledStrike
        case .sagittarius: return .expansiveArcing
        case .capricorn: return .measuredClimb
        case .aquarius: return .erraticDrift
        case .pisces: return .flowingDissolve
        }
    }
}

/// Bearing of the daemon, from the chart ruler's dignity and whether it is rising.
public enum DaemonPresence: String, Codable, Sendable, CaseIterable {
    /// Ruler in domicile, rising or not (the owner's Sun is both).
    case dominantUnhurried
    /// Ruler exalted.
    case exaltedRadiant
    /// Ruler in detriment.
    case subdued
    /// Ruler in fall.
    case wary
    /// Ruler peregrine.
    case restless
}
