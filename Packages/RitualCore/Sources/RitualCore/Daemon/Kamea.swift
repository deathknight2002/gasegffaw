import Foundation

// MARK: - Kamea

/// A planetary magic square (kamea) as printed in Agrippa, *Three Books of Occult
/// Philosophy* II.22: Saturn 3×3 through Moon 9×9.
///
/// `cells` are stored as rows from top to bottom, each row left to right; the public
/// lookups are **1-based** (`row: 1...order`, `col: 1...order`) to match the way the
/// sigil cells are quoted in Appendix A, e.g. the Sun square's `(6,4)` holds 4.
public struct Kamea: Codable, Sendable, Equatable {
    /// The planet the square belongs to.
    public let planet: Planet
    /// Side length `n`; every value `1…n²` appears exactly once.
    public let order: Int
    /// Rows top→bottom, each left→right, 0-based storage.
    public let cells: [[Int]]

    /// Creates a square from its rows. `cells` must be square; `order` is `cells.count`.
    ///
    /// - Parameters:
    ///   - planet: Planet of the square.
    ///   - cells: Rows top→bottom.
    init(planet: Planet, cells: [[Int]]) {
        precondition(cells.allSatisfy { $0.count == cells.count }, "kamea rows must form an n×n grid")
        self.planet = planet
        self.order = cells.count
        self.cells = cells
    }

    /// The constant every row, column and main diagonal sums to: `n(n² + 1) / 2`.
    public var magicSum: Int {
        order * (order * order + 1) / 2
    }

    /// Value at a 1-based cell.
    ///
    /// - Parameters:
    ///   - row: Row 1…order, counted from the top.
    ///   - col: Column 1…order, counted from the left.
    public func value(row: Int, col: Int) -> Int {
        precondition((1...order).contains(row) && (1...order).contains(col), "kamea cell out of range")
        return cells[row - 1][col - 1]
    }

    /// 1-based cell holding `value`, or `nil` if the value is outside `1…n²`.
    ///
    /// - Parameter value: The value to locate.
    public func cell(of value: Int) -> (row: Int, col: Int)? {
        for (rowIndex, row) in cells.enumerated() {
            if let colIndex = row.firstIndex(of: value) {
                return (rowIndex + 1, colIndex + 1)
            }
        }
        return nil
    }

    /// Centre of a 1-based cell in normalised square coordinates, x right and y down,
    /// in [0, 1]: `((col − 0.5) / n, (row − 0.5) / n)`.
    ///
    /// - Parameters:
    ///   - row: Row 1…order.
    ///   - col: Column 1…order.
    public func normalizedCenter(row: Int, col: Int) -> RVec2 {
        let n = Double(order)
        return RVec2((Double(col) - 0.5) / n, (Double(row) - 0.5) / n)
    }

    // MARK: The seven squares (Agrippa II.22)

    /// Saturn, 3×3, sum 15.
    public static let saturn = Kamea(planet: .saturn, cells: [
        [4, 9, 2],
        [3, 5, 7],
        [8, 1, 6],
    ])

    /// Jupiter, 4×4, sum 34.
    public static let jupiter = Kamea(planet: .jupiter, cells: [
        [4, 14, 15, 1],
        [9, 7, 6, 12],
        [5, 11, 10, 8],
        [16, 2, 3, 13],
    ])

    /// Mars, 5×5, sum 65.
    public static let mars = Kamea(planet: .mars, cells: [
        [11, 24, 7, 20, 3],
        [4, 12, 25, 8, 16],
        [17, 5, 13, 21, 9],
        [10, 18, 1, 14, 22],
        [23, 6, 19, 2, 15],
    ])

    /// Sun, 6×6, sum 111 — exactly the Appendix A grid used for the owner's sigil.
    public static let sun = Kamea(planet: .sun, cells: [
        [6, 32, 3, 34, 35, 1],
        [7, 11, 27, 28, 8, 30],
        [19, 14, 16, 15, 23, 24],
        [18, 20, 22, 21, 17, 13],
        [25, 29, 10, 9, 26, 12],
        [36, 5, 33, 4, 2, 31],
    ])

    /// Venus, 7×7, sum 175.
    public static let venus = Kamea(planet: .venus, cells: [
        [22, 47, 16, 41, 10, 35, 4],
        [5, 23, 48, 17, 42, 11, 29],
        [30, 6, 24, 49, 18, 36, 12],
        [13, 31, 7, 25, 43, 19, 37],
        [38, 14, 32, 1, 26, 44, 20],
        [21, 39, 8, 33, 2, 27, 45],
        [46, 15, 40, 9, 34, 3, 28],
    ])

    /// Mercury, 8×8, sum 260.
    public static let mercury = Kamea(planet: .mercury, cells: [
        [8, 58, 59, 5, 4, 62, 63, 1],
        [49, 15, 14, 52, 53, 11, 10, 56],
        [41, 23, 22, 44, 45, 19, 18, 48],
        [32, 34, 35, 29, 28, 38, 39, 25],
        [40, 26, 27, 37, 36, 30, 31, 33],
        [17, 47, 46, 20, 21, 43, 42, 24],
        [9, 55, 54, 12, 13, 51, 50, 16],
        [64, 2, 3, 61, 60, 6, 7, 57],
    ])

    /// Moon, 9×9, sum 369.
    public static let moon = Kamea(planet: .moon, cells: [
        [37, 78, 29, 70, 21, 62, 13, 54, 5],
        [6, 38, 79, 30, 71, 22, 63, 14, 46],
        [47, 7, 39, 80, 31, 72, 23, 55, 15],
        [16, 48, 8, 40, 81, 32, 64, 24, 56],
        [57, 17, 49, 9, 41, 73, 33, 65, 25],
        [26, 58, 18, 50, 1, 42, 74, 34, 66],
        [67, 27, 59, 10, 51, 2, 43, 75, 35],
        [36, 68, 19, 60, 11, 52, 3, 44, 76],
        [77, 28, 69, 20, 61, 12, 53, 4, 45],
    ])

    /// The Agrippa square of a planet (order `planet.kameaOrder`).
    ///
    /// - Parameter p: The planet.
    public static func forPlanet(_ p: Planet) -> Kamea {
        switch p {
        case .saturn: return saturn
        case .jupiter: return jupiter
        case .mars: return mars
        case .sun: return sun
        case .venus: return venus
        case .mercury: return mercury
        case .moon: return moon
        }
    }
}
