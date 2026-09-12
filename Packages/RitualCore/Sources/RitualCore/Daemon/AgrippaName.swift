import Foundation

// MARK: - AgrippaName

/// The daemon's name spelled from the five hylegical places of a natal chart
/// (Agrippa, *Three Books of Occult Philosophy* III.26, "the name of the genius").
///
/// Each place is measured in degrees past the Ascendant; the whole degrees, taken
/// modulo 22, index the Hebrew alphabet. The places are always taken in the fixed
/// ``HylegicalPlace`` order: Sun, Moon, Ascendant, Lot of Fortune, prenatal syzygy —
/// so the Ascendant itself always contributes Aleph in third position.
public struct AgrippaName: Codable, Sendable, Equatable {
    /// One record per hylegical place, in ``HylegicalPlace/allCases`` order (5 entries).
    public let placements: [NamePlacement]

    /// Creates a name from explicit placements.
    ///
    /// Prefer ``derive(from:)``; this initialiser exists for fixtures and decoding.
    ///
    /// - Parameter placements: Placement records in derivation order.
    public init(placements: [NamePlacement]) {
        self.placements = placements
    }

    /// The letters in derivation order.
    public var letters: [HebrewLetter] {
        placements.map(\.letter)
    }

    /// The Hebrew spelling: characters concatenated in derivation order (e.g. `"דראנד"`).
    ///
    /// Hebrew is a right-to-left script, so the first-derived letter is the rightmost
    /// glyph when rendered; the stored string is simply the letters in logical order.
    public var hebrew: String {
        String(letters.map(\.character))
    }

    /// The Latin display name built from the letters' initials (e.g. `"DRAND"`).
    public var latin: String {
        String(letters.map(\.latin))
    }

    /// Gematria values of the letters in derivation order (e.g. `[4, 200, 1, 50, 4]`).
    public var values: [Int] {
        letters.map(\.value)
    }

    /// Number of Hebrew letters the derivation cycles through.
    public static let letterCount = HebrewLetter.allCases.count

    /// Letter for a place `offset` degrees past the Ascendant.
    ///
    /// The rule is `floor(normalize(offset)) mod 22`, so an offset of exactly 22.0° (or
    /// 0°, 44°, …) is Aleph, 21.999° is Tav and 355.85° wraps to Daleth.
    ///
    /// - Parameter offset: Degrees past the Ascendant (any value; normalised to [0, 360)).
    public static func letter(forOffset offset: Double) -> HebrewLetter {
        let wholeDegrees = Int(Angle.normalize(offset).rounded(.down))
        return HebrewLetter.allCases[wholeDegrees % letterCount]
    }

    /// Builds the placement record for one hylegical place.
    ///
    /// - Parameters:
    ///   - place: The place being spelled.
    ///   - longitude: Its ecliptic longitude in degrees.
    ///   - ascendant: The Ascendant longitude in degrees.
    public static func placement(for place: HylegicalPlace, longitude: Double, ascendant: Double) -> NamePlacement {
        let offset = Angle.normalize(longitude - ascendant)
        return NamePlacement(
            place: place,
            longitude: Angle.normalize(longitude),
            offsetFromAscendant: offset,
            letter: letter(forOffset: offset)
        )
    }

    /// Ecliptic longitude of a hylegical place in a chart.
    ///
    /// - Parameters:
    ///   - place: The hylegical place.
    ///   - chart: The natal chart.
    public static func longitude(of place: HylegicalPlace, in chart: NatalChart) -> Double {
        switch place {
        case .sun: return chart.sun.longitude
        case .moon: return chart.moon.longitude
        case .ascendant: return chart.ascendant.longitude
        case .fortune: return chart.lotOfFortune.longitude
        case .syzygy: return chart.prenatalSyzygy.longitude
        }
    }

    /// Derives the name from a chart: for each hylegical place in order, letter index
    /// `floor(normalize(longitude − ascendant)) mod 22`.
    ///
    /// - Parameter chart: The natal chart to spell from.
    public static func derive(from chart: NatalChart) -> AgrippaName {
        let ascendant = chart.ascendant.longitude
        let placements = HylegicalPlace.allCases.map { place in
            placement(for: place, longitude: longitude(of: place, in: chart), ascendant: ascendant)
        }
        return AgrippaName(placements: placements)
    }
}
