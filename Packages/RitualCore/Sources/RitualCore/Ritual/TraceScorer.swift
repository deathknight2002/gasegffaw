import Foundation

/// Scores a finger trace against a template's checkpoints (ARCHITECTURE §3).
///
/// Checkpoints must be hit **in order**: a trace point "hits" the next unhit checkpoint
/// when it lies within `hitRadius` of it. A single point may hit several consecutive
/// checkpoints if they are all within reach. Points that miss the next checkpoint are
/// ignored, so wobble and back-tracking are not penalised; the stage succeeds when at
/// least `RitualRules.traceRequiredHits` of the 24 checkpoints are hit at finger lift.
public struct TraceScorer {
    /// Radius in normalised units within which a trace point hits a checkpoint.
    public static let hitRadius = 0.09

    /// Number of checkpoints hit in order by the whole trace.
    ///
    /// - Parameters:
    ///   - trace: Finger samples in normalised `[0, 1]²` coordinates, in time order.
    ///   - checkpoints: Template checkpoints in drawing order.
    public static func score(trace: [RVec2], checkpoints: [RVec2]) -> Int {
        var hits = 0
        for point in trace {
            hits = advance(hits: hits, point: point, checkpoints: checkpoints)
        }
        return hits
    }

    /// Progressive form of `score`: folds one new trace point into a running hit count.
    ///
    /// `score(trace:checkpoints:)` is exactly `trace.reduce(0) { advance(hits: $0, point: $1, …) }`,
    /// so the simulation can keep `traceHits` live as points arrive.
    ///
    /// - Parameters:
    ///   - hits: Checkpoints hit so far.
    ///   - point: The new trace sample.
    ///   - checkpoints: Template checkpoints in drawing order.
    public static func advance(hits: Int, point: RVec2, checkpoints: [RVec2]) -> Int {
        var updated = max(0, hits)
        while updated < checkpoints.count && point.distance(to: checkpoints[updated]) <= hitRadius {
            updated += 1
        }
        return updated
    }
}
