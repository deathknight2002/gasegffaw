import Foundation

/// Timing of the Spirit rhythm mini-game (ARCHITECTURE §3, "Rhythm").
///
/// Six barbarous names are chanted at 75 BPM; each is a beat the sorcerer must tap.
/// Beat times are stage-relative seconds; every value is an exact multiple of the
/// simulation tick (1/120 s), so beat judgement is done in integer ticks.
public enum RhythmSpec {
    /// Beat times in seconds relative to the start of a round.
    public static let beatTimes: [Double] = [1.0, 1.8, 2.6, 3.4, 4.2, 5.0]
    /// The barbarous name spoken on each beat.
    public static let names = ["Aoth", "Abaoth", "Basum", "Isak", "Sabaoth", "Iao"]
    /// Half-width in seconds of the "perfect" window around a beat.
    public static let perfectWindow = 0.15
    /// Half-width in seconds of the "good" window around a beat; beyond it a tap is a miss.
    public static let goodWindow = 0.30
    /// Seconds after the last beat of a failed round before the next round's clock starts.
    public static let retryDelay = 1.5
    /// Beats per round.
    public static let beatsPerRound = 6
    /// Hits (perfect or good) required out of `beatsPerRound` to succeed.
    public static let requiredHits = 5

    /// Duration in seconds from the start of one round to the start of the next
    /// (`beatTimes.last + retryDelay`).
    public static var roundPeriod: Double {
        (beatTimes.last ?? 0) + retryDelay
    }

    /// `perfectWindow` in ticks.
    public static var perfectTicks: Int {
        ticks(forSeconds: perfectWindow)
    }

    /// `goodWindow` in ticks.
    public static var goodTicks: Int {
        ticks(forSeconds: goodWindow)
    }

    /// Converts seconds to the nearest whole simulation tick.
    public static func ticks(forSeconds seconds: Double) -> Int {
        Int((seconds * Double(RitualSimulation.tickRate)).rounded())
    }

    /// Simulation tick of a beat.
    ///
    /// - Parameters:
    ///   - round: Zero-based round index (`RitualState.rhythmRound`).
    ///   - index: Beat index within the round (`0..<beatsPerRound`).
    ///   - stageStartTick: Tick at which the Spirit stage began.
    public static func beatTick(round: Int, index: Int, stageStartTick: Int) -> Int {
        let clamped = min(max(index, 0), beatTimes.count - 1)
        let offset = Double(round) * roundPeriod + beatTimes[clamped]
        return stageStartTick + ticks(forSeconds: offset)
    }

    /// Judges a tap by its signed offset from the beat in seconds.
    public static func judge(offsetSeconds: Double) -> BeatResult {
        let magnitude = abs(offsetSeconds)
        if magnitude <= perfectWindow { return .perfect }
        if magnitude <= goodWindow { return .good }
        return .miss
    }

    /// Judges a tap by its signed offset from the beat in ticks.
    public static func judge(offsetTicks: Int) -> BeatResult {
        let magnitude = abs(offsetTicks)
        if magnitude <= perfectTicks { return .perfect }
        if magnitude <= goodTicks { return .good }
        return .miss
    }
}
