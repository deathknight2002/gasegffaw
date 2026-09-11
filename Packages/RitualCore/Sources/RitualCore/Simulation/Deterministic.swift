import Foundation

// MARK: - SeededRNG (PCG32)

/// Deterministic PCG32-XSH-RR generator (64-bit state, 64-bit stream increment).
///
/// Bit-identical to the reference `pcg32_random_r` / `pcg32_srandom_r` in the minimal
/// C implementation: seed 42, stream 54 yields `0xa15c02b7, 0x7b47f409, 0xba1d3330, …`.
/// The generator is a plain value (`Codable`, `Equatable`), so a simulation keyframe
/// can snapshot it and rewind exactly. Every random draw in the simulation must come
/// from an instance of this type or from ``Hash``; never from `SystemRandomNumberGenerator`.
public struct SeededRNG: RandomNumberGenerator, Codable, Sendable, Hashable {
    /// The PCG multiplier for the 64-bit LCG step.
    private static let multiplier: UInt64 = 6_364_136_223_846_793_005

    /// Current LCG state.
    public private(set) var state: UInt64
    /// Stream increment (always odd; derived from the `stream` passed at initialisation).
    public private(set) var inc: UInt64

    /// Creates a generator following the reference `pcg32_srandom_r` sequence:
    /// `state = 0; inc = (stream << 1) | 1; step; state += seed; step`.
    ///
    /// - Parameters:
    ///   - seed: The 64-bit seed (`initstate` in the reference).
    ///   - stream: Stream selector (`initseq`); different streams give independent sequences.
    public init(seed: UInt64, stream: UInt64 = 0) {
        state = 0
        inc = (stream << 1) | 1
        advance()
        state &+= seed
        advance()
    }

    /// Advances the LCG by one step and returns the state *before* the step.
    @discardableResult
    private mutating func advance() -> UInt64 {
        let oldState = state
        state = oldState &* Self.multiplier &+ inc
        return oldState
    }

    /// Next 32-bit output (XSH-RR permutation of the pre-step state).
    public mutating func nextU32() -> UInt32 {
        let oldState = advance()
        let xorshifted = UInt32(truncatingIfNeeded: ((oldState >> 18) ^ oldState) >> 27)
        let rotation = UInt32(truncatingIfNeeded: oldState >> 59)
        return (xorshifted >> rotation) | (xorshifted << ((0 &- rotation) & 31))
    }

    /// Next 64-bit value: two consecutive PCG32 outputs concatenated, the first draw in
    /// the high 32 bits and the second in the low 32 bits.
    public mutating func next() -> UInt64 {
        let high = UInt64(nextU32())
        let low = UInt64(nextU32())
        return (high << 32) | low
    }

    /// Uniform `Double` in `[0, 1)` built from one 32-bit draw (`u32 / 2^32`).
    public mutating func nextUnit() -> Double {
        Double(nextU32()) / 4_294_967_296.0
    }

    /// Uniform `Double` in `[lo, hi)` (or `[hi, lo)` when the bounds are reversed).
    ///
    /// - Parameters:
    ///   - lo: Lower bound (inclusive).
    ///   - hi: Upper bound (exclusive).
    public mutating func nextRange(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * nextUnit()
    }
}

// MARK: - Hash

/// Stateless 32-bit hashing shared by the CPU simulation and the GPU shaders.
///
/// `u32` is bit-identical to `hash_u32` in `Shaders/Common.h`, so an ember or a noise
/// sample keyed by `(seed, tick, id)` evaluates to the same value on both sides.
/// `RitualCoreTests/FoundationTests` pins the outputs; if the formula ever changes,
/// the shader and the pins must change in the same commit.
public enum Hash {
    /// Golden-ratio constant XORed into the low seed word before mixing.
    private static let seedSalt: UInt32 = 0x9E37_79B9
    /// First multiplier of the `lowbias32`-style avalanche.
    private static let mixA: UInt32 = 0x7FEB_352D
    /// Second multiplier of the `lowbias32`-style avalanche.
    private static let mixB: UInt32 = 0x846C_A68B

    /// 32-bit mix of a 64-bit seed and three 32-bit keys.
    ///
    /// Algorithm (contract): `h = seed_lo ^ 0x9E3779B9`; then for each `v` in
    /// `[seed_hi, a, b, c]`: `h ^= v; h = (h ^ (h >> 16)) * 0x7FEB352D;
    /// h = (h ^ (h >> 15)) * 0x846CA68B; h ^= h >> 16` (all wrapping 32-bit arithmetic).
    ///
    /// - Parameters:
    ///   - seed: Simulation/render seed; split into low and high 32-bit words.
    ///   - a: First key (typically a tick or frame index).
    ///   - b: Second key (typically a particle or pixel id).
    ///   - c: Third key (typically a per-use channel/salt).
    public static func u32(_ seed: UInt64, _ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        let seedLo = UInt32(truncatingIfNeeded: seed)
        let seedHi = UInt32(truncatingIfNeeded: seed >> 32)
        var hash = seedLo ^ seedSalt
        for value in [seedHi, a, b, c] {
            hash ^= value
            hash = (hash ^ (hash >> 16)) &* mixA
            hash = (hash ^ (hash >> 15)) &* mixB
            hash ^= hash >> 16
        }
        return hash
    }

    /// `u32(seed, a, b, c) / 2^32`, a uniform value in `[0, 1)`.
    public static func unit(_ seed: UInt64, _ a: UInt32, _ b: UInt32, _ c: UInt32) -> Double {
        Double(u32(seed, a, b, c)) / 4_294_967_296.0
    }
}
