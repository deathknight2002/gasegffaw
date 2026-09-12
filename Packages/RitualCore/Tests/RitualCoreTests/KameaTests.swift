import XCTest
@testable import RitualCore

/// Validity of the seven Agrippa squares and the 1-based lookups built on them.
final class KameaTests: XCTestCase {

    // MARK: - Magic-square validity

    /// Every square must contain each of 1…n² exactly once and have all rows, columns and
    /// both main diagonals summing to n(n² + 1) / 2.
    func testAllSevenSquaresAreMagic() {
        let expectedSums: [Planet: Int] = [
            .saturn: 15, .jupiter: 34, .mars: 65, .sun: 111, .venus: 175, .mercury: 260, .moon: 369,
        ]
        for planet in Planet.allCases {
            let kamea = Kamea.forPlanet(planet)
            let n = kamea.order
            XCTAssertEqual(n, planet.kameaOrder, "\(planet) order")
            XCTAssertEqual(kamea.planet, planet)
            XCTAssertEqual(kamea.cells.count, n, "\(planet) row count")
            for row in kamea.cells {
                XCTAssertEqual(row.count, n, "\(planet) row length")
            }
            let magic = expectedSums[planet]
            XCTAssertEqual(kamea.magicSum, magic, "\(planet) magic sum")

            let sortedValues = kamea.cells.flatMap { $0 }.sorted()
            XCTAssertEqual(sortedValues, Array(1...(n * n)), "\(planet) must contain 1…n² exactly once")

            for (index, row) in kamea.cells.enumerated() {
                XCTAssertEqual(row.reduce(0, +), magic, "\(planet) row \(index + 1)")
            }
            for col in 0..<n {
                let columnSum = kamea.cells.map { $0[col] }.reduce(0, +)
                XCTAssertEqual(columnSum, magic, "\(planet) column \(col + 1)")
            }
            let mainDiagonal = (0..<n).map { kamea.cells[$0][$0] }.reduce(0, +)
            let antiDiagonal = (0..<n).map { kamea.cells[$0][n - 1 - $0] }.reduce(0, +)
            XCTAssertEqual(mainDiagonal, magic, "\(planet) main diagonal")
            XCTAssertEqual(antiDiagonal, magic, "\(planet) anti-diagonal")
        }
    }

    func testStaticSquaresMatchForPlanet() {
        XCTAssertEqual(Kamea.forPlanet(.saturn), Kamea.saturn)
        XCTAssertEqual(Kamea.forPlanet(.jupiter), Kamea.jupiter)
        XCTAssertEqual(Kamea.forPlanet(.mars), Kamea.mars)
        XCTAssertEqual(Kamea.forPlanet(.sun), Kamea.sun)
        XCTAssertEqual(Kamea.forPlanet(.venus), Kamea.venus)
        XCTAssertEqual(Kamea.forPlanet(.mercury), Kamea.mercury)
        XCTAssertEqual(Kamea.forPlanet(.moon), Kamea.moon)
        XCTAssertEqual(Planet.allCases.map { Kamea.forPlanet($0).order }, [3, 4, 5, 6, 7, 8, 9])
    }

    // MARK: - Literal grids

    /// The Sun square is the Appendix A grid, verbatim.
    func testSunSquareIsTheAppendixAGrid() {
        let expected = [
            [6, 32, 3, 34, 35, 1],
            [7, 11, 27, 28, 8, 30],
            [19, 14, 16, 15, 23, 24],
            [18, 20, 22, 21, 17, 13],
            [25, 29, 10, 9, 26, 12],
            [36, 5, 33, 4, 2, 31],
        ]
        XCTAssertEqual(Kamea.sun.cells, expected)
        XCTAssertEqual(Kamea.sun.order, 6)
        XCTAssertEqual(Kamea.sun.planet, .sun)
        XCTAssertEqual(Kamea.sun.magicSum, 111)
    }

    func testSaturnSquareIsTheContractGrid() {
        XCTAssertEqual(Kamea.saturn.cells, [[4, 9, 2], [3, 5, 7], [8, 1, 6]])
    }

    // MARK: - Lookups

    func testValueLookupIsOneBasedRowMajor() {
        XCTAssertEqual(Kamea.sun.value(row: 1, col: 1), 6)
        XCTAssertEqual(Kamea.sun.value(row: 1, col: 6), 1)
        XCTAssertEqual(Kamea.sun.value(row: 6, col: 1), 36)
        XCTAssertEqual(Kamea.sun.value(row: 6, col: 4), 4)
        XCTAssertEqual(Kamea.sun.value(row: 4, col: 2), 20)
        XCTAssertEqual(Kamea.sun.value(row: 6, col: 2), 5)
        XCTAssertEqual(Kamea.saturn.value(row: 2, col: 2), 5)
        XCTAssertEqual(Kamea.moon.value(row: 9, col: 9), 45)
    }

    func testCellOfValueInvertsValueLookupForEverySquare() {
        for planet in Planet.allCases {
            let kamea = Kamea.forPlanet(planet)
            for value in 1...(kamea.order * kamea.order) {
                guard let cell = kamea.cell(of: value) else {
                    XCTFail("\(planet): value \(value) not found")
                    continue
                }
                XCTAssertTrue((1...kamea.order).contains(cell.row))
                XCTAssertTrue((1...kamea.order).contains(cell.col))
                XCTAssertEqual(kamea.value(row: cell.row, col: cell.col), value, "\(planet) value \(value)")
            }
            XCTAssertNil(kamea.cell(of: 0), "\(planet): 0 is not in the square")
            XCTAssertNil(kamea.cell(of: kamea.order * kamea.order + 1))
            XCTAssertNil(kamea.cell(of: -3))
        }
    }

    func testAppendixACellsOnTheSunSquare() {
        XCTAssertTrue(Kamea.sun.cell(of: 4).map { $0 == (6, 4) } ?? false)
        XCTAssertTrue(Kamea.sun.cell(of: 20).map { $0 == (4, 2) } ?? false)
        XCTAssertTrue(Kamea.sun.cell(of: 1).map { $0 == (1, 6) } ?? false)
        XCTAssertTrue(Kamea.sun.cell(of: 5).map { $0 == (6, 2) } ?? false)
    }

    func testNormalizedCellCentres() {
        let sun = Kamea.sun
        XCTAssertEqual(sun.normalizedCenter(row: 1, col: 1), RVec2(0.5 / 6, 0.5 / 6))
        XCTAssertEqual(sun.normalizedCenter(row: 6, col: 6), RVec2(5.5 / 6, 5.5 / 6))
        XCTAssertEqual(sun.normalizedCenter(row: 6, col: 4), RVec2(3.5 / 6, 5.5 / 6))
        XCTAssertEqual(Kamea.saturn.normalizedCenter(row: 2, col: 2), RVec2(0.5, 0.5))
        for planet in Planet.allCases {
            let kamea = Kamea.forPlanet(planet)
            for row in 1...kamea.order {
                for col in 1...kamea.order {
                    let centre = kamea.normalizedCenter(row: row, col: col)
                    XCTAssertGreaterThan(centre.x, 0)
                    XCTAssertLessThan(centre.x, 1)
                    XCTAssertGreaterThan(centre.y, 0)
                    XCTAssertLessThan(centre.y, 1)
                }
            }
        }
    }

    // MARK: - Codable

    func testKameaCodableRoundTrip() throws {
        for planet in Planet.allCases {
            let original = Kamea.forPlanet(planet)
            let decoded = try JSONDecoder().decode(Kamea.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded, original)
        }
    }
}
