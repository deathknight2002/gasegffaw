import Foundation

// MARK: - SigilPoint

/// One vertex of a sigil: a kamea cell (1-based), the reduced value that selected it
/// and its centre in normalised square coordinates.
public struct SigilPoint: Codable, Sendable, Equatable {
    /// Row 1…order, counted from the top.
    public let row: Int
    /// Column 1…order, counted from the left.
    public let col: Int
    /// The (reduced) letter value found in this cell.
    public let value: Int
    /// Cell centre, x right and y down, in [0, 1]: `((col − 0.5) / n, (row − 0.5) / n)`.
    public let normalized: RVec2

    /// Creates a sigil vertex.
    ///
    /// - Parameters:
    ///   - row: 1-based row.
    ///   - col: 1-based column.
    ///   - value: Reduced value in the cell.
    ///   - normalized: Cell centre in [0, 1]².
    public init(row: Int, col: Int, value: Int, normalized: RVec2) {
        self.row = row
        self.col = col
        self.value = value
        self.normalized = normalized
    }

    /// Whether two points name the same cell (ignoring value).
    ///
    /// - Parameter other: The point to compare with.
    public func sameCell(as other: SigilPoint) -> Bool {
        row == other.row && col == other.col
    }
}

// MARK: - SigilPath

/// The sigil of a name traced on a kamea: each letter's gematria value is reduced
/// until it fits the square (`while value > n² { value /= 10 }`), located in the grid
/// and joined to the next by a straight segment. The first cell carries a small circle,
/// the last a short bar perpendicular to the final segment.
public struct SigilPath: Codable, Sendable, Equatable {
    /// Default radius of the start marker in normalised units.
    public static let defaultStartMarkerRadius = 0.045
    /// Default length of the end bar in normalised units.
    public static let defaultEndBarLength = 0.06

    /// The square the path was traced on.
    public let kamea: Kamea
    /// Vertices in name order; letters whose reduced value is absent from the square
    /// (impossible for orders ≥ 3) are skipped.
    public let points: [SigilPoint]
    /// Reduced value of every letter in name order, e.g. `[4, 20, 1, 5, 4]` for DRAND.
    public let reducedValues: [Int]
    /// Radius of the circle drawn on the first cell, normalised (0.045).
    public var startMarkerRadius: Double
    /// Length of the bar drawn across the last cell, perpendicular to the last segment
    /// and drawn even when the path is closed (0.06, normalised).
    public var endBarLength: Double

    /// Creates a path from explicit vertices.
    ///
    /// Prefer ``trace(name:kamea:)``; this initialiser exists for fixtures and decoding.
    ///
    /// - Parameters:
    ///   - kamea: The square.
    ///   - points: Vertices in order.
    ///   - reducedValues: Reduced values in order.
    ///   - startMarkerRadius: Start circle radius (normalised).
    ///   - endBarLength: End bar length (normalised).
    public init(
        kamea: Kamea,
        points: [SigilPoint],
        reducedValues: [Int],
        startMarkerRadius: Double = SigilPath.defaultStartMarkerRadius,
        endBarLength: Double = SigilPath.defaultEndBarLength
    ) {
        self.kamea = kamea
        self.points = points
        self.reducedValues = reducedValues
        self.startMarkerRadius = startMarkerRadius
        self.endBarLength = endBarLength
    }

    /// Whether the path returns to its first cell (at least two vertices, first cell ==
    /// last cell). DRAND on the Sun square is closed: (6,4) → … → (6,4).
    public var isClosed: Bool {
        guard points.count >= 2, let first = points.first, let last = points.last else { return false }
        return first.sameCell(as: last)
    }

    /// The vertices' normalised centres in order — the polyline to stroke.
    public var polyline: [RVec2] {
        points.map(\.normalized)
    }

    /// Centre of the start circle (the first vertex), or `nil` for an empty path.
    public var startMarkerCenter: RVec2? {
        points.first?.normalized
    }

    /// End points of the end bar: a segment of length ``endBarLength`` centred on the
    /// last vertex and perpendicular to the last non-degenerate segment. A path with no
    /// extent (one vertex, or all vertices in one cell) gets a horizontal bar. `nil` for
    /// an empty path.
    public var endBarSegment: (start: RVec2, end: RVec2)? {
        guard let last = points.last?.normalized else { return nil }
        let direction = lastSegmentDirection ?? RVec2(0, 1)
        let perpendicular = RVec2(-direction.y, direction.x) * (endBarLength / 2)
        return (last - perpendicular, last + perpendicular)
    }

    /// Unit direction of the last segment with non-zero length, searching backwards.
    private var lastSegmentDirection: RVec2? {
        let vertices = polyline
        guard let last = vertices.last else { return nil }
        for previous in vertices.dropLast().reversed() {
            let delta = last - previous
            if delta.lengthSquared > 0 {
                return delta.normalized
            }
        }
        return nil
    }

    /// Reduces a gematria value until it fits a square of the given order:
    /// `while value > order² { value /= 10 }` — so on the Sun square (36 cells)
    /// 200 → 20, 50 → 5, 400 → 40 → 4, 300 → 30 and 100 → 10; on Mars (25 cells)
    /// 300 → 30 → 3.
    ///
    /// - Parameters:
    ///   - value: Letter value (1…400).
    ///   - order: Side length of the square.
    public static func reduce(_ value: Int, order: Int) -> Int {
        let capacity = order * order
        var reduced = value
        while reduced > capacity {
            reduced /= 10
        }
        return reduced
    }

    /// Traces the sigil of `name` on `kamea`.
    ///
    /// - Parameters:
    ///   - name: The name whose letters are plotted.
    ///   - kamea: The square to plot on (normally the chart ruler's).
    public static func trace(name: AgrippaName, kamea: Kamea) -> SigilPath {
        let reducedValues = name.letters.map { reduce($0.value, order: kamea.order) }
        let points = reducedValues.compactMap { value -> SigilPoint? in
            guard let cell = kamea.cell(of: value) else { return nil }
            return SigilPoint(
                row: cell.row,
                col: cell.col,
                value: value,
                normalized: kamea.normalizedCenter(row: cell.row, col: cell.col)
            )
        }
        return SigilPath(kamea: kamea, points: points, reducedValues: reducedValues)
    }
}
