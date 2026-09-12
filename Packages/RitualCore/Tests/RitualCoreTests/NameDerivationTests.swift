import XCTest
@testable import RitualCore

/// Synthetic charts exercising the letter rule (`floor(normalize(lon − asc)) mod 22`),
/// wrap-around, exact-degree boundaries, reachability of all 22 letters, and the sigil
/// value reduction.
final class NameDerivationTests: XCTestCase {

    // MARK: - Helpers

    /// A chart with only the five hylegical longitudes set; everything else is filler.
    private static func chart(
        sun: Double, moon: Double, ascendant: Double, fortune: Double, syzygy: Double
    ) -> NatalChart {
        NatalChart(
            birth: .owner,
            sun: ZodiacPosition(longitude: sun),
            moon: ZodiacPosition(longitude: moon),
            ascendant: ZodiacPosition(longitude: ascendant),
            midheaven: ZodiacPosition(longitude: ascendant - 90),
            sunAltitude: 10,
            sect: .day,
            prenatalSyzygy: Syzygy(kind: .fullMoon, jdUT: 2_452_480.0, longitude: syzygy),
            lotOfFortune: ZodiacPosition(longitude: fortune),
            lotOfSpirit: ZodiacPosition(longitude: fortune + 40),
            chartRuler: ZodiacPosition(longitude: ascendant).sign.ruler,
            rulerPosition: nil,
            rulerDignity: .peregrine,
            rulerRising: false
        )
    }

    // MARK: - Letter rule

    func testLetterForOffsetFollowsFloorMod22() {
        XCTAssertEqual(AgrippaName.letter(forOffset: 0), .aleph)
        XCTAssertEqual(AgrippaName.letter(forOffset: 0.999), .aleph)
        XCTAssertEqual(AgrippaName.letter(forOffset: 1), .beth)
        XCTAssertEqual(AgrippaName.letter(forOffset: 3.283), .daleth)
        XCTAssertEqual(AgrippaName.letter(forOffset: 21), .tav)
        XCTAssertEqual(AgrippaName.letter(forOffset: 21.9999), .tav)
        XCTAssertEqual(AgrippaName.letter(forOffset: 107.483), .resh)
        XCTAssertEqual(AgrippaName.letter(forOffset: 255.799), .nun)
    }

    /// Offsets that land exactly on an integer belong to that integer's letter: 22.0 is
    /// Aleph (index 22 mod 22 = 0), 44.0 is Aleph, 23.0 is Beth, 1.0 is Beth.
    func testExactIntegerOffsetsAreBoundaryInclusive() {
        XCTAssertEqual(AgrippaName.letter(forOffset: 22.0), .aleph)
        XCTAssertEqual(AgrippaName.letter(forOffset: 44.0), .aleph)
        XCTAssertEqual(AgrippaName.letter(forOffset: 66.0), .aleph)
        XCTAssertEqual(AgrippaName.letter(forOffset: 352.0), .aleph)
        XCTAssertEqual(AgrippaName.letter(forOffset: 1.0), .beth)
        XCTAssertEqual(AgrippaName.letter(forOffset: 23.0), .beth)
        XCTAssertEqual(AgrippaName.letter(forOffset: 21.0), .tav)
        XCTAssertEqual(AgrippaName.letter(forOffset: 43.0), .tav)
        XCTAssertEqual(AgrippaName.letter(forOffset: 360.0), .aleph, "360 normalises to 0")
        // Just below an integer stays with the previous letter.
        XCTAssertEqual(AgrippaName.letter(forOffset: 22.0 - 1e-9), .tav)
        XCTAssertEqual(AgrippaName.letter(forOffset: 1.0 - 1e-9), .aleph)
    }

    /// Places behind the Ascendant wrap through 360: 355.85° past is Daleth (355 mod 22 = 3).
    func testWrapAroundOffsets() {
        XCTAssertEqual(AgrippaName.letter(forOffset: 355.85), .daleth)
        XCTAssertEqual(AgrippaName.letter(forOffset: -4.15), .daleth, "negative offsets normalise first")
        XCTAssertEqual(AgrippaName.letter(forOffset: 359.9999), .chet, "359 mod 22 = 7")
        XCTAssertEqual(AgrippaName.letter(forOffset: -0.5), .chet, "−0.5 → 359.5 → 359 → Chet")
        XCTAssertEqual(AgrippaName.letter(forOffset: 355.85 + 720), .daleth)
        XCTAssertEqual(AgrippaName.letter(forOffset: 355.85 - 720), .daleth)
    }

    func testWrapAroundThroughDerive() {
        // Ascendant at 140.211; syzygy at 136.063 is 355.852° past it → Daleth.
        let chart = Self.chart(sun: 143.494, moon: 247.694, ascendant: 140.211, fortune: 36.010, syzygy: 136.063)
        let name = AgrippaName.derive(from: chart)
        let syzygyPlacement = name.placements[4]
        XCTAssertEqual(syzygyPlacement.place, .syzygy)
        XCTAssertEqual(syzygyPlacement.offsetFromAscendant, 355.852, accuracy: 1e-9)
        XCTAssertEqual(syzygyPlacement.letter, .daleth)

        // Ascendant near the end of the zodiac; Sun just past 0° Aries.
        let wrapped = Self.chart(sun: 2.5, moon: 350.0, ascendant: 350.0, fortune: 349.9, syzygy: 12.0)
        let wrappedName = AgrippaName.derive(from: wrapped)
        XCTAssertEqual(wrappedName.placements[0].offsetFromAscendant, 12.5, accuracy: 1e-9)
        XCTAssertEqual(wrappedName.letters[0], .mem, "12.5° past → index 12 → Mem")
        XCTAssertEqual(wrappedName.letters[1], .aleph, "Moon conjunct the Ascendant → Aleph")
        XCTAssertEqual(wrappedName.letters[2], .aleph, "the Ascendant itself is always Aleph")
        XCTAssertEqual(wrappedName.placements[3].offsetFromAscendant, 359.9, accuracy: 1e-9)
        XCTAssertEqual(wrappedName.letters[3], .chet, "0.1° behind the Ascendant → 359 → Chet")
        XCTAssertEqual(wrappedName.placements[4].offsetFromAscendant, 22.0, accuracy: 1e-9)
        XCTAssertEqual(wrappedName.letters[4], .aleph, "exactly 22° past → Aleph")
        XCTAssertEqual(wrappedName.latin, "MAACA")
    }

    // MARK: - Reachability

    func testAllTwentyTwoLettersReachableWithinOneCycle() {
        let ascendant = 100.0
        var reached = Set<HebrewLetter>()
        for index in 0..<22 {
            let chart = Self.chart(
                sun: ascendant + Double(index) + 0.5, moon: ascendant, ascendant: ascendant,
                fortune: ascendant, syzygy: ascendant
            )
            let letter = AgrippaName.derive(from: chart).letters[0]
            XCTAssertEqual(letter.rawValue, index, "offset \(index).5 must give letter index \(index)")
            reached.insert(letter)
        }
        XCTAssertEqual(reached, Set(HebrewLetter.allCases), "every letter reachable from offsets 0…21")
    }

    func testAllTwentyTwoLettersReachableAcrossTheWholeCircle() {
        var reached = Set<HebrewLetter>()
        for degree in 0..<360 {
            let letter = AgrippaName.letter(forOffset: Double(degree) + 0.25)
            XCTAssertEqual(letter.rawValue, degree % 22, "degree \(degree)")
            reached.insert(letter)
        }
        XCTAssertEqual(reached.count, 22)
        // The 22-letter cycle restarts every 22° regardless of where the Ascendant is.
        for ascendant in stride(from: 0.0, to: 360.0, by: 17.5) {
            for index in 0..<22 {
                let sunLongitude = ascendant + Double(index) + 0.3 + 22.0 * 5
                XCTAssertEqual(
                    AgrippaName.placement(for: .sun, longitude: sunLongitude, ascendant: ascendant).letter.rawValue,
                    index, "asc \(ascendant), index \(index)"
                )
            }
        }
    }

    // MARK: - Placements and strings

    func testPlacementsAreInHylegicalOrderAndCarryLongitudes() {
        let chart = Self.chart(sun: 5.5, moon: 30.0, ascendant: 0.0, fortune: 100.0, syzygy: 300.0)
        let name = AgrippaName.derive(from: chart)
        XCTAssertEqual(name.placements.count, 5)
        XCTAssertEqual(name.placements.map(\.place), HylegicalPlace.allCases)
        XCTAssertEqual(name.placements.map(\.longitude), [5.5, 30.0, 0.0, 100.0, 300.0])
        XCTAssertEqual(name.placements.map(\.offsetFromAscendant), [5.5, 30.0, 0.0, 100.0, 300.0])
        XCTAssertEqual(name.letters, [.vav, .tet, .aleph, .mem, .samekh])
        XCTAssertEqual(name.latin, "VTAMS")
        XCTAssertEqual(name.hebrew, "וטאמס")
        XCTAssertEqual(name.values, [6, 9, 1, 40, 60])
        XCTAssertEqual(name.hebrew.count, 5)
    }

    func testDeriveReadsThePrenatalSyzygyLongitudeNotTheSun() {
        let chart = Self.chart(sun: 50, moon: 60, ascendant: 40, fortune: 70, syzygy: 40 + 19.5)
        let name = AgrippaName.derive(from: chart)
        XCTAssertEqual(name.letters[4], .resh, "19.5° past → index 19 → Resh")
        XCTAssertEqual(name.letters[0], .kaf, "Sun 10° past → index 10 → Kaf")
    }

    func testNameIsEquatableAndCodable() throws {
        let chart = Self.chart(sun: 143.494, moon: 247.694, ascendant: 140.211, fortune: 36.010, syzygy: 136.063)
        let name = AgrippaName.derive(from: chart)
        let decoded = try JSONDecoder().decode(AgrippaName.self, from: JSONEncoder().encode(name))
        XCTAssertEqual(decoded, name)
        XCTAssertEqual(decoded.latin, "DRAND")
        XCTAssertEqual(AgrippaName.derive(from: chart), name, "derivation is deterministic")
    }

    // MARK: - Value reduction

    func testReductionOnTheSunSquare() {
        XCTAssertEqual(SigilPath.reduce(200, order: 6), 20)
        XCTAssertEqual(SigilPath.reduce(50, order: 6), 5)
        XCTAssertEqual(SigilPath.reduce(400, order: 6), 4, "400 → 40 → 4: 40 still exceeds 36")
        XCTAssertEqual(SigilPath.reduce(300, order: 6), 30, "contract rule stops at 30 ≤ 36 (same shape as 100 → 10)")
        XCTAssertEqual(SigilPath.reduce(100, order: 6), 10)
        XCTAssertEqual(SigilPath.reduce(4, order: 6), 4)
        XCTAssertEqual(SigilPath.reduce(36, order: 6), 36, "n² itself fits")
        XCTAssertEqual(SigilPath.reduce(40, order: 6), 4)
        XCTAssertEqual(SigilPath.reduce(90, order: 6), 9)
    }

    func testReductionOnOtherOrders() {
        XCTAssertEqual(SigilPath.reduce(300, order: 5), 3, "300 → 30 → 3 on Mars (25 cells)")
        XCTAssertEqual(SigilPath.reduce(100, order: 3), 1, "100 → 10 → 1 on Saturn")
        XCTAssertEqual(SigilPath.reduce(10, order: 3), 1)
        XCTAssertEqual(SigilPath.reduce(9, order: 3), 9)
        XCTAssertEqual(SigilPath.reduce(20, order: 4), 2)
        XCTAssertEqual(SigilPath.reduce(16, order: 4), 16)
        XCTAssertEqual(SigilPath.reduce(300, order: 5), 3)
        XCTAssertEqual(SigilPath.reduce(400, order: 7), 40)
        XCTAssertEqual(SigilPath.reduce(90, order: 8), 9)
        XCTAssertEqual(SigilPath.reduce(400, order: 9), 40)
        XCTAssertEqual(SigilPath.reduce(81, order: 9), 81)
        XCTAssertEqual(SigilPath.reduce(90, order: 9), 9)
        // Every letter reduces into 1…n² for every planetary square.
        for planet in Planet.allCases {
            let order = planet.kameaOrder
            for letter in HebrewLetter.allCases {
                let reduced = SigilPath.reduce(letter.value, order: order)
                XCTAssertTrue((1...(order * order)).contains(reduced), "\(letter.name) on \(planet)")
            }
        }
    }

    func testEveryLetterTracesToACellOnEverySquare() {
        for planet in Planet.allCases {
            let kamea = Kamea.forPlanet(planet)
            let placements = HebrewLetter.allCases.map { letter in
                NamePlacement(place: .sun, longitude: 0, offsetFromAscendant: 0, letter: letter)
            }
            let path = SigilPath.trace(name: AgrippaName(placements: placements), kamea: kamea)
            XCTAssertEqual(path.points.count, 22, "\(planet): all 22 letters plotted")
            XCTAssertEqual(path.reducedValues, HebrewLetter.allCases.map { SigilPath.reduce($0.value, order: kamea.order) })
            for point in path.points {
                XCTAssertEqual(kamea.value(row: point.row, col: point.col), point.value)
                XCTAssertEqual(point.normalized, kamea.normalizedCenter(row: point.row, col: point.col))
            }
        }
    }

    func testTraceMetadataForOpenAndDegeneratePaths() {
        // "AB" on Saturn: 1 at (3,2), 2 at (1,3) — open path.
        let open = AgrippaName(placements: [
            NamePlacement(place: .sun, longitude: 0, offsetFromAscendant: 0, letter: .aleph),
            NamePlacement(place: .moon, longitude: 1, offsetFromAscendant: 1, letter: .beth),
        ])
        let path = SigilPath.trace(name: open, kamea: .saturn)
        XCTAssertFalse(path.isClosed)
        XCTAssertEqual(path.points.map { [$0.row, $0.col] }, [[3, 2], [1, 3]])
        XCTAssertEqual(path.polyline, [RVec2(1.5 / 3, 2.5 / 3), RVec2(2.5 / 3, 0.5 / 3)])
        XCTAssertEqual(path.startMarkerCenter, RVec2(1.5 / 3, 2.5 / 3))
        XCTAssertEqual(path.startMarkerRadius, 0.045)
        XCTAssertEqual(path.endBarLength, 0.06)
        let bar = try? XCTUnwrap(path.endBarSegment)
        if let bar {
            let barVector = bar.end - bar.start
            let segment = RVec2(2.5 / 3, 0.5 / 3) - RVec2(1.5 / 3, 2.5 / 3)
            XCTAssertEqual(barVector.length, 0.06, accuracy: 1e-12)
            XCTAssertEqual(barVector.dot(segment), 0, accuracy: 1e-12, "bar is perpendicular to the last segment")
            XCTAssertEqual(RVec2.lerp(bar.start, bar.end, 0.5), RVec2(2.5 / 3, 0.5 / 3), "bar is centred on the last vertex")
        }

        // A single letter: one point, not closed, bar defaults to horizontal.
        let single = AgrippaName(placements: [open.placements[0]])
        let singlePath = SigilPath.trace(name: single, kamea: .saturn)
        XCTAssertEqual(singlePath.points.count, 1)
        XCTAssertFalse(singlePath.isClosed, "a lone vertex is not a loop")
        if let singleBar = singlePath.endBarSegment {
            XCTAssertEqual(singleBar.start.y, 2.5 / 3, accuracy: 1e-12, "no extent → horizontal bar")
            XCTAssertEqual(singleBar.end.y, 2.5 / 3, accuracy: 1e-12)
            XCTAssertEqual(min(singleBar.start.x, singleBar.end.x), 0.5 - 0.03, accuracy: 1e-12)
            XCTAssertEqual(max(singleBar.start.x, singleBar.end.x), 0.5 + 0.03, accuracy: 1e-12)
        } else {
            XCTFail("a one-vertex path still has an end bar")
        }

        // Empty name: no points, no markers.
        let emptyPath = SigilPath.trace(name: AgrippaName(placements: []), kamea: .sun)
        XCTAssertTrue(emptyPath.points.isEmpty)
        XCTAssertFalse(emptyPath.isClosed)
        XCTAssertNil(emptyPath.startMarkerCenter)
        XCTAssertNil(emptyPath.endBarSegment)
    }
}
