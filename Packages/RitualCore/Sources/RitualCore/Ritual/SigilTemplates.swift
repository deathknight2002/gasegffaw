import Foundation

/// The elemental trace paths the sorcerer draws at each quarter (ARCHITECTURE §3).
///
/// Paths are open polylines in normalised `[0, 1]²` coordinates (x right, y down) and are
/// confined to the box `[0.1, 0.9]²`. Air and Fire are upward triangles, Water and Earth
/// downward triangles; Air and Earth carry the alchemical horizontal bar, drawn after the
/// triangle closes (the finger stays down and slides from the closing corner to the bar's
/// left end). Bar heights are measured **upward from the base of the box** (y = 0.9):
/// Air's bar sits at 55 % (upper part of the upward triangle), Earth's at 45 % (lower
/// part of the downward triangle), matching the classical glyphs.
public enum SigilTemplates {
    /// Left/top edge of the drawing box in normalised units.
    public static let boxMin = 0.1
    /// Right/bottom edge of the drawing box in normalised units.
    public static let boxMax = 0.9
    /// Height of the Air bar as a fraction of the box height, measured up from the base.
    public static let airBarHeightFraction = 0.55
    /// Height of the Earth bar as a fraction of the box height, measured up from the base.
    public static let earthBarHeightFraction = 0.45
    /// Default checkpoint count used by the scorer.
    public static let defaultCheckpointCount = 24

    /// The polyline for an element, in drawing order.
    ///
    /// Triangles start at their first base corner (bottom-left for upward, top-left for
    /// downward) and run clockwise on screen, returning to the start; bars are appended
    /// left → right. Spirit is not traced and returns an empty path.
    public static func path(for element: RitualElement) -> [RVec2] {
        switch element {
        case .air:
            return upwardTriangle + bar(heightFraction: airBarHeightFraction, upward: true)
        case .fire:
            return upwardTriangle
        case .water:
            return downwardTriangle
        case .earth:
            return downwardTriangle + bar(heightFraction: earthBarHeightFraction, upward: false)
        case .spirit:
            return []
        }
    }

    /// The element's path resampled by arc length into `count` evenly spaced checkpoints.
    ///
    /// The first checkpoint is the path's first vertex and the last is its final vertex;
    /// the remaining points are spaced `length / (count − 1)` apart along the polyline.
    ///
    /// - Parameters:
    ///   - element: Element whose template is sampled.
    ///   - count: Number of checkpoints (default 24, the scorer's count).
    public static func checkpoints(for element: RitualElement, count: Int = defaultCheckpointCount) -> [RVec2] {
        if count == defaultCheckpointCount, let cached = defaultCheckpoints[element] {
            return cached
        }
        return resample(path(for: element), count: count)
    }

    /// Total arc length of a polyline.
    public static func length(of polyline: [RVec2]) -> Double {
        guard polyline.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<polyline.count {
            total += polyline[index - 1].distance(to: polyline[index])
        }
        return total
    }

    /// Resamples a polyline into `count` points evenly spaced by arc length, keeping both
    /// end vertices. A degenerate (empty or zero-length) polyline repeats its first vertex.
    ///
    /// - Parameters:
    ///   - polyline: Vertices in drawing order.
    ///   - count: Number of output points; values below 1 yield an empty array.
    public static func resample(_ polyline: [RVec2], count: Int) -> [RVec2] {
        guard count > 0, let first = polyline.first else { return [] }
        guard count > 1, polyline.count > 1 else { return Array(repeating: first, count: count) }

        var cumulative = [0.0]
        cumulative.reserveCapacity(polyline.count)
        for index in 1..<polyline.count {
            cumulative.append(cumulative[index - 1] + polyline[index - 1].distance(to: polyline[index]))
        }
        guard let total = cumulative.last, total > 0 else { return Array(repeating: first, count: count) }

        var result: [RVec2] = []
        result.reserveCapacity(count)
        var segment = 0
        let lastSegment = polyline.count - 2
        for sample in 0..<count {
            let target = total * Double(sample) / Double(count - 1)
            while segment < lastSegment && cumulative[segment + 1] < target {
                segment += 1
            }
            let segmentLength = cumulative[segment + 1] - cumulative[segment]
            let fraction = segmentLength > 0 ? min(max((target - cumulative[segment]) / segmentLength, 0), 1) : 0
            result.append(RVec2.lerp(polyline[segment], polyline[segment + 1], fraction))
        }
        return result
    }

    // MARK: - Geometry

    private static var centreX: Double { (boxMin + boxMax) / 2 }
    private static var halfWidth: Double { (boxMax - boxMin) / 2 }
    private static var boxHeight: Double { boxMax - boxMin }

    /// Bottom-left → apex → bottom-right → bottom-left (clockwise on a y-down screen).
    private static var upwardTriangle: [RVec2] {
        let bottomLeft = RVec2(boxMin, boxMax)
        let apex = RVec2(centreX, boxMin)
        let bottomRight = RVec2(boxMax, boxMax)
        return [bottomLeft, apex, bottomRight, bottomLeft]
    }

    /// Top-left → top-right → bottom apex → top-left (clockwise on a y-down screen).
    private static var downwardTriangle: [RVec2] {
        let topLeft = RVec2(boxMin, boxMin)
        let topRight = RVec2(boxMax, boxMin)
        let apex = RVec2(centreX, boxMax)
        return [topLeft, topRight, apex, topLeft]
    }

    /// The horizontal bar at `heightFraction` up from the base, spanning exactly the
    /// triangle's width at that height, drawn left → right.
    private static func bar(heightFraction: Double, upward: Bool) -> [RVec2] {
        let y = boxMax - heightFraction * boxHeight
        // Width of an upward triangle shrinks toward its apex at the top; a downward one toward the bottom.
        let widthFraction = upward ? (1 - heightFraction) : heightFraction
        let half = halfWidth * widthFraction
        return [RVec2(centreX - half, y), RVec2(centreX + half, y)]
    }

    /// Cache of the 24-point checkpoints per element (the scorer's hot path).
    private static let defaultCheckpoints: [RitualElement: [RVec2]] = {
        var table: [RitualElement: [RVec2]] = [:]
        for element in RitualElement.allCases {
            table[element] = resample(path(for: element), count: defaultCheckpointCount)
        }
        return table
    }()
}
