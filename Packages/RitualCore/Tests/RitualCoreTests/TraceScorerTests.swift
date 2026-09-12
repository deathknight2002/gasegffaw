import XCTest
@testable import RitualCore

/// Template geometry, arc-length resampling and in-order checkpoint scoring.
final class TraceScorerTests: XCTestCase {
    private var rng = SeededRNG(seed: 2024, stream: 9)

    private func noisy(_ points: [RVec2], amplitude: Double) -> [RVec2] {
        points.map { $0 + RVec2(rng.nextRange(-amplitude, amplitude), rng.nextRange(-amplitude, amplitude)) }
    }

    func testTemplateShapes() {
        let air = SigilTemplates.path(for: .air)
        XCTAssertEqual(air.count, 6)
        XCTAssertEqual(air[0], RVec2(0.1, 0.9), "starts bottom-left")
        XCTAssertEqual(air[1], RVec2(0.5, 0.1), "apex at the top (y down)")
        XCTAssertEqual(air[2], RVec2(0.9, 0.9))
        XCTAssertEqual(air[3], RVec2(0.1, 0.9), "triangle closes")
        XCTAssertEqual(air[4].y, 0.46, accuracy: 1e-12, "bar at 55 % up from the base")
        XCTAssertEqual(air[5].y, 0.46, accuracy: 1e-12)
        XCTAssertLessThan(air[4].x, air[5].x, "bar drawn left to right")
        XCTAssertEqual(air[4].x, 0.32, accuracy: 1e-12, "bar spans the triangle's width at that height")
        XCTAssertEqual(air[5].x, 0.68, accuracy: 1e-12)

        let fire = SigilTemplates.path(for: .fire)
        XCTAssertEqual(fire, Array(air.prefix(4)), "Fire is the bare upward triangle")

        let water = SigilTemplates.path(for: .water)
        XCTAssertEqual(water, [RVec2(0.1, 0.1), RVec2(0.9, 0.1), RVec2(0.5, 0.9), RVec2(0.1, 0.1)])

        let earth = SigilTemplates.path(for: .earth)
        XCTAssertEqual(Array(earth.prefix(4)), water)
        XCTAssertEqual(earth.count, 6)
        XCTAssertEqual(earth[4].y, 0.54, accuracy: 1e-12, "bar at 45 % up from the base")
        XCTAssertEqual(earth[4].x, 0.32, accuracy: 1e-12)
        XCTAssertEqual(earth[5].x, 0.68, accuracy: 1e-12)
        XCTAssertTrue(SigilTemplates.path(for: .spirit).isEmpty)

        for element in [RitualElement.air, .fire, .water, .earth] {
            for point in SigilTemplates.path(for: element) {
                XCTAssertGreaterThanOrEqual(point.x, 0.1 - 1e-12)
                XCTAssertLessThanOrEqual(point.x, 0.9 + 1e-12)
                XCTAssertGreaterThanOrEqual(point.y, 0.1 - 1e-12)
                XCTAssertLessThanOrEqual(point.y, 0.9 + 1e-12)
            }
        }
    }

    func testCheckpointsAreEvenlySpacedByArcLength() {
        for element in [RitualElement.air, .fire, .water, .earth] {
            let path = SigilTemplates.path(for: element)
            let checkpoints = SigilTemplates.checkpoints(for: element)
            XCTAssertEqual(checkpoints.count, 24)
            XCTAssertEqual(checkpoints.first, path.first)
            XCTAssertEqual(checkpoints.last!.distance(to: path.last!), 0, accuracy: 1e-12)
            let spacing = SigilTemplates.length(of: path) / 23
            var exactGaps = 0
            for index in 1..<checkpoints.count {
                // Consecutive checkpoints are exactly one spacing apart along a straight run and
                // closer (as a chord) only where the pair straddles a vertex of the polyline.
                let gap = checkpoints[index - 1].distance(to: checkpoints[index])
                XCTAssertLessThanOrEqual(gap, spacing + 1e-12, "\(element) gap \(index)")
                if abs(gap - spacing) < 1e-9 {
                    exactGaps += 1
                }
            }
            XCTAssertGreaterThanOrEqual(exactGaps, 23 - (path.count - 2), "\(element): only corner-straddling gaps may be short")
            XCTAssertEqual(SigilTemplates.checkpoints(for: element, count: 24), checkpoints, "cache matches recomputation")
            let dense = SigilTemplates.checkpoints(for: element, count: 180)
            XCTAssertEqual(dense.count, 180)
            XCTAssertEqual(dense.first, path.first)
        }
        XCTAssertEqual(SigilTemplates.length(of: SigilTemplates.path(for: .fire)), 0.8 + 2 * (0.4 * 0.4 + 0.8 * 0.8).squareRoot(), accuracy: 1e-12)
    }

    func testResampleEdgeCases() {
        XCTAssertEqual(SigilTemplates.resample([], count: 5), [])
        XCTAssertEqual(SigilTemplates.resample([RVec2(1, 1)], count: 3), [RVec2(1, 1), RVec2(1, 1), RVec2(1, 1)])
        XCTAssertEqual(SigilTemplates.resample([RVec2(0, 0), RVec2(1, 0)], count: 0), [])
        XCTAssertEqual(SigilTemplates.resample([RVec2(0, 0), RVec2(1, 0)], count: 1), [RVec2(0, 0)])
        XCTAssertEqual(SigilTemplates.resample([RVec2(0, 0), RVec2(1, 0)], count: 3), [RVec2(0, 0), RVec2(0.5, 0), RVec2(1, 0)])
        XCTAssertEqual(SigilTemplates.resample([RVec2(0, 0), RVec2(0, 0)], count: 2), [RVec2(0, 0), RVec2(0, 0)])
        // Two segments of different length: the midpoint sample lands on the longer one.
        let bent = SigilTemplates.resample([RVec2(0, 0), RVec2(1, 0), RVec2(1, 3)], count: 5)
        XCTAssertEqual(bent[1], RVec2(1, 0))
        XCTAssertEqual(bent[2], RVec2(1, 1))
        XCTAssertEqual(bent[4], RVec2(1, 3))
        XCTAssertTrue(SigilTemplates.checkpoints(for: .spirit).isEmpty)
    }

    func testResampledTemplateWithNoiseScoresFullAndScribbleFails() {
        for element in [RitualElement.air, .fire, .water, .earth] {
            let checkpoints = SigilTemplates.checkpoints(for: element)
            let exact = SigilTemplates.checkpoints(for: element, count: 120)
            XCTAssertEqual(TraceScorer.score(trace: exact, checkpoints: checkpoints), 24)
            for _ in 0..<5 {
                let trace = noisy(exact, amplitude: 0.03)
                XCTAssertGreaterThanOrEqual(TraceScorer.score(trace: trace, checkpoints: checkpoints), 18, "\(element) noisy trace")
            }
            let scribble = (0..<200).map { _ in RVec2(rng.nextRange(0.35, 0.65), rng.nextRange(0.35, 0.65)) }
            XCTAssertLessThan(TraceScorer.score(trace: scribble, checkpoints: checkpoints), 18, "\(element) scribble")
            let reversed = TraceScorer.score(trace: exact.reversed(), checkpoints: checkpoints)
            XCTAssertLessThan(reversed, 18, "\(element) drawn backwards must not pass")
        }
    }

    func testScoringIsProgressiveAndInOrder() {
        let checkpoints = [RVec2(0, 0), RVec2(0.5, 0), RVec2(1, 0)]
        XCTAssertEqual(TraceScorer.score(trace: [], checkpoints: checkpoints), 0)
        XCTAssertEqual(TraceScorer.score(trace: [RVec2(0.5, 0)], checkpoints: checkpoints), 0, "second checkpoint cannot be hit before the first")
        XCTAssertEqual(TraceScorer.score(trace: [RVec2(0.05, 0.05)], checkpoints: checkpoints), 1)
        XCTAssertEqual(TraceScorer.score(trace: [RVec2(0, 0.09)], checkpoints: checkpoints), 1, "hit radius is inclusive")
        XCTAssertEqual(TraceScorer.score(trace: [RVec2(0, 0.0901)], checkpoints: checkpoints), 0)
        XCTAssertEqual(TraceScorer.score(trace: [RVec2(0, 0), RVec2(1, 0)], checkpoints: checkpoints), 1, "skipping the middle stalls the count")
        XCTAssertEqual(TraceScorer.score(trace: [RVec2(0, 0), RVec2(0.5, 0), RVec2(1, 0)], checkpoints: checkpoints), 3)
        XCTAssertEqual(TraceScorer.score(trace: [RVec2(0, 0), RVec2(0.5, 0), RVec2(0, 0), RVec2(1, 0)], checkpoints: checkpoints), 3, "back-tracking is not penalised")
        // One point can hit several consecutive close checkpoints.
        let tight = [RVec2(0, 0), RVec2(0.05, 0), RVec2(0.1, 0)]
        XCTAssertEqual(TraceScorer.score(trace: [RVec2(0.05, 0)], checkpoints: tight), 3)
        XCTAssertEqual(TraceScorer.score(trace: [RVec2(0.5, 0.5)], checkpoints: []), 0)
        // The progressive form folds identically.
        let trace = [RVec2(0.02, 0), RVec2(0.3, 0), RVec2(0.52, 0.01), RVec2(0.98, 0)]
        var hits = 0
        for point in trace {
            hits = TraceScorer.advance(hits: hits, point: point, checkpoints: checkpoints)
        }
        XCTAssertEqual(hits, TraceScorer.score(trace: trace, checkpoints: checkpoints))
        XCTAssertEqual(TraceScorer.advance(hits: -5, point: RVec2(0, 0), checkpoints: checkpoints), 1)
        XCTAssertEqual(TraceScorer.hitRadius, 0.09)
    }

    func testRhythmSpecConstants() {
        XCTAssertEqual(RhythmSpec.beatTimes, [1.0, 1.8, 2.6, 3.4, 4.2, 5.0])
        XCTAssertEqual(RhythmSpec.names, ["Aoth", "Abaoth", "Basum", "Isak", "Sabaoth", "Iao"])
        XCTAssertEqual(RhythmSpec.perfectWindow, 0.15)
        XCTAssertEqual(RhythmSpec.goodWindow, 0.30)
        XCTAssertEqual(RhythmSpec.retryDelay, 1.5)
        XCTAssertEqual(RhythmSpec.roundPeriod, 6.5)
        XCTAssertEqual(RhythmSpec.perfectTicks, 18)
        XCTAssertEqual(RhythmSpec.goodTicks, 36)
        XCTAssertEqual(RhythmSpec.beatTick(round: 0, index: 0, stageStartTick: 1000), 1120)
        XCTAssertEqual(RhythmSpec.beatTick(round: 0, index: 5, stageStartTick: 1000), 1600)
        XCTAssertEqual(RhythmSpec.beatTick(round: 1, index: 0, stageStartTick: 1000), 1120 + 780)
        XCTAssertEqual(RhythmSpec.judge(offsetSeconds: 0.15), .perfect)
        XCTAssertEqual(RhythmSpec.judge(offsetSeconds: -0.151), .good)
        XCTAssertEqual(RhythmSpec.judge(offsetSeconds: 0.30), .good)
        XCTAssertEqual(RhythmSpec.judge(offsetSeconds: 0.31), .miss)
        XCTAssertEqual(RhythmSpec.judge(offsetTicks: -18), .perfect)
        XCTAssertEqual(RhythmSpec.judge(offsetTicks: 19), .good)
        XCTAssertEqual(RhythmSpec.judge(offsetTicks: 36), .good)
        XCTAssertEqual(RhythmSpec.judge(offsetTicks: 37), .miss)
    }
}
