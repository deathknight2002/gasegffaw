# RitualCore — public API contract

Package: `Packages/RitualCore` (swift-tools-version 5.9, `import Foundation` only,
`platforms: [.iOS(.v17), .macOS(.v14)]`, target `RitualCore`, test target `RitualCoreTests`
with resources `Fixtures/`). Must build and pass `swift test` on Linux with Swift 6.2.
Language mode: Swift 5 (`swiftLanguageVersions: [.v5]`). All public types are `Sendable`
value types unless noted. Angles are **degrees** unless a name says radians. Longitudes are
normalised to [0, 360). Every public symbol has a Google-style doc comment.

## Vectors (`Math/RVec.swift`)
```swift
public struct RVec2: Hashable, Codable, Sendable { public var x, y: Double; +,-,*,/, dot, length, normalized, lerp }
public struct RVec3: Hashable, Codable, Sendable { public var x, y, z: Double; +,-,*,/, dot, cross, length, normalized, lerp }
public enum Angle { public static func normalize(_ degrees: Double) -> Double /* [0,360) */
                    public static func wrap180(_ degrees: Double) -> Double /* (-180,180] */
                    public static func deg2rad(_:) ; rad2deg(_:) }
```

## Determinism (`Simulation/Deterministic.swift`)
```swift
public struct SeededRNG: RandomNumberGenerator, Codable, Sendable {   // PCG32 (state, inc)
    public init(seed: UInt64, stream: UInt64 = 0)
    public mutating func next() -> UInt64        // two PCG32 outputs concatenated
    public mutating func nextU32() -> UInt32
    public mutating func nextUnit() -> Double    // [0,1)
    public mutating func nextRange(_ lo: Double, _ hi: Double) -> Double
}
public enum Hash {
    /// 32-bit mix, bit-identical to `hash_u32` in Shaders/Common.h:
    /// h = seed_lo ^ 0x9E3779B9; for v in [seed_hi, a, b, c]: h ^= v; h = (h ^ (h >> 16)) &* 0x7FEB352D; h = (h ^ (h >> 15)) &* 0x846CA68B; h ^= h >> 16
    /// Seed entropy: the first avalanche only sees seed_lo ^ seed_hi, so seeds with equal (lo XOR hi) — e.g. 1 and 1<<32 —
    /// produce identical streams for every (a, b, c); a seed carries 32 bits of entropy here (SeededRNG uses all 64).
    /// Prefer seeds < 2^32 (CaptureConfig defaults to 1) or with distinct low words when distinct hash streams matter.
    public static func u32(_ seed: UInt64, _ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32
    public static func unit(_ seed: UInt64, _ a: UInt32, _ b: UInt32, _ c: UInt32) -> Double   // u32 / 2^32
}
```

## Astrology (`Astrology/*.swift`)
```swift
public enum JulianDay {
    public static func fromCalendar(year: Int, month: Int, day: Int, hourUT: Double) -> Double  // Meeus 7.1, Gregorian
    public static func toCalendar(_ jd: Double) -> (year: Int, month: Int, day: Int, hourUT: Double)   // non-finite jd -> (0, 0, 0, jd) sentinel, never traps
    public static func centuriesSinceJ2000(_ jd: Double) -> Double
    /// seconds; JD(UT) -> JD(TT) = jd + deltaT/86400. Espenak–Meeus polynomials (2005 revision) before 2005; the observed IERS
    /// series (annual, interpolated) 2005–2025; beyond the table the Stephenson–Morrison–Hohenkerk 2016 curvature (32.5 s/cy²)
    /// anchored at the table end with zero slope, cross-faded (smoothstep) into the Morrison–Stephenson 2004 parabola by 2500,
    /// which applies unchanged from then on (and before −500). Within ≈ 4 s of contemporary predictions through 2100. NaN for non-finite jd.
    public static func deltaT(jd: Double) -> Double
}
public enum Ephemeris {
    // Sun: VSOP87D Earth (Meeus Appendix III tables: L0..L5, B0..B1, R0..R4 as printed), FK5 correction,
    // nutation in longitude, aberration −20.4898″/R. Result: apparent geocentric ecliptic-of-date.
    public static func sun(jdUT: Double) -> (longitude: Double, latitude: Double, distanceAU: Double)
    // Moon: Meeus ch. 47 (ELP-2000/82 truncated, 60+60 terms) + nutation. Apparent geocentric. This IS the shipped engine:
    // no code or tables derived from the Swiss Ephemeris sources (AGPL) may be used; accuracy ≈ 10″ is far inside the 0.1° tolerance.
    public static func moon(jdUT: Double) -> (longitude: Double, latitude: Double, distanceKm: Double)
    public static func nutation(jdTT: Double) -> (longitude: Double, obliquity: Double)   // IAU 1980, Meeus ch. 22 full 63-term table
    public static func meanObliquity(jdTT: Double) -> Double        // Laskar (Meeus 22.3)
    public static func trueObliquity(jdTT: Double) -> Double
    public static func greenwichMeanSiderealTime(jdUT: Double) -> Double       // degrees, Meeus 12.4
    public static func greenwichApparentSiderealTime(jdUT: Double) -> Double   // + Δψ cos ε
    public static func localApparentSiderealTime(jdUT: Double, longitudeEast: Double) -> Double  // RAMC, degrees
    public static func midheaven(ramc: Double, obliquity: Double) -> Double    // atan2(sin θ, cos θ cos ε), quadrant-correct
    public static func ascendant(ramc: Double, latitude: Double, obliquity: Double) -> Double
        // ASC = atan2(cos θ, −(sin θ cos ε + tan φ sin ε)); if result is not in the eastern half relative to MC, add 180
    public static func eclipticToEquatorial(longitude: Double, latitude: Double, obliquity: Double) -> (ra: Double, dec: Double)
    public static func altitude(ra: Double, dec: Double, lst: Double, latitude: Double) -> Double   // geometric, no refraction
    public static func sunAltitude(jdUT: Double, latitude: Double, longitudeEast: Double) -> Double
}
public enum SyzygyKind: String, Codable, Sendable { case newMoon, fullMoon }
public struct Syzygy: Codable, Sendable, Equatable { public let kind: SyzygyKind; public let jdUT: Double; public let longitude: Double }
public enum SyzygyFinder {
    /// Last New or Full Moon strictly before `jdUT`: coarse backward search (0.05 d) on Moon−Sun elongation, then bisection to < 1 s.
    /// New → Sun's longitude at that instant; Full → Moon's.
    public static func prenatal(before jdUT: Double) -> Syzygy
}
public struct BirthData: Codable, Sendable, Equatable {
    public var year: Int, month: Int, day: Int, hourUT: Double, latitude: Double, longitudeEast: Double
    public init(year:month:day:hourUT:latitude:longitudeEast:)
    public var jdUT: Double
    public var isFinite: Bool          // hourUT, latitude, longitudeEast all finite
    public var sanitized: BirthData    // non-finite fields replaced by 0 (0h UT, Greenwich equator)
    /// 16 Aug 2002 13:00 UT, Portland OR (45.5152, −122.6784)
    public static let owner: BirthData
}
public enum ZodiacSign: Int, CaseIterable, Codable, Sendable { case aries = 0, taurus, gemini, cancer, leo, virgo, libra, scorpio, sagittarius, capricorn, aquarius, pisces
    public var name: String; public var abbreviation: String /* "Leo" etc. (3 letters) */; public var ruler: Planet /* traditional */; public var element: ChartElement; public var exaltedPlanet: Planet? }
public enum ChartElement: String, Codable, Sendable { case fire, earth, air, water }
public enum Planet: String, CaseIterable, Codable, Sendable { case saturn, jupiter, mars, sun, venus, mercury, moon   // kamea order 3..9
    public var kameaOrder: Int; public var domiciles: [ZodiacSign]; public var exaltation: ZodiacSign?; public var name: String }
public enum Dignity: String, Codable, Sendable { case domicile, exaltation, detriment, fall, peregrine }
public struct ZodiacPosition: Codable, Sendable, Equatable {
    public let longitude: Double; public var sign: ZodiacSign; public var degreeInSign: Double   // exact: sign containing longitude
    public var degrees: Int; public var minutes: Int    // rounded to nearest minute, carrying (e.g. 23°30'); degrees is always 0…29
    public var roundedSign: ZodiacSign   // sign after the minute rounding: equals `sign` unless the minutes carry past 29°59' (then the next sign, Pisces -> Aries)
    /// "23°30' Leo (143.494°)" — the rounded decomposition (roundedSign), decimal to 3 places; 359.9999 prints "0°00' Aries (0.000°)", never 360.000
    public var formatted: String
    public init(longitude: Double)    // normalises to [0, 360); a non-finite longitude maps to 0° Aries
}
public enum Sect: String, Codable, Sendable { case day, night }
public struct NatalChart: Codable, Sendable, Equatable {
    public let birth: BirthData
    public let sun, moon, ascendant, midheaven: ZodiacPosition
    public let sunAltitude: Double          // degrees, geometric
    public let sect: Sect                   // night iff sunAltitude < 0
    public let prenatalSyzygy: Syzygy
    public let lotOfFortune, lotOfSpirit: ZodiacPosition   // night: F = ASC+Sun−Moon, S = ASC+Moon−Sun; day: swapped
    public let chartRuler: Planet           // ruler of the Ascendant sign
    public let rulerPosition: ZodiacPosition? // Sun/Moon positions known; other planets nil (not computed)
    public let rulerDignity: Dignity        // by sign of rulerPosition (peregrine if unknown)
    public let rulerRising: Bool            // ruler within 15° of the ASC on the same sign side (Sun: |Sun−ASC| ≤ 15°)
    public static func compute(birth: BirthData) -> NatalChart   // uses birth.sanitized (non-finite fields -> 0) and records it as `birth`; never traps
    /// Appendix A format, exactly these 9 lines, values as `formatted`, altitude "−2.87° → night chart":
    /// Sun 23°30' Leo (143.494°) / Moon ... / Ascendant ... / MC ... / Sun altitude −2.87° → night chart /
    /// Prenatal syzygy New Moon 2002-08-08 19:15 UT 16°04' Leo (136.063°) / Lot of Fortune ... / Lot of Spirit ... /
    /// Chart ruler Sun — in domicile, rising
    public func appendixAReport() -> String
}
```

## Daemon (`Daemon/*.swift`)
```swift
public enum HebrewLetter: Int, CaseIterable, Codable, Sendable { case aleph = 0, beth, gimel, daleth, he, vav, zayin, chet, tet, yod, kaf, lamed, mem, nun, samekh, ayin, pe, tsade, qof, resh, shin, tav
    public var character: Character   // א ב ג ד ה ו ז ח ט י כ ל מ נ ס ע פ צ ק ר ש ת (non-final forms)
    public var name: String; public var latin: Character /* A B G D H V Z Ch->C? NO: use  A B G D H V Z Ch T Y K L M N S O P Tz Q R Sh Th -> for the Latin *initial* use: A B G D H V Z C T Y K L M N S O P X Q R S T; only the initial letter matters for the display name */
    public var value: Int              // 1..9, 10..90, 100..400
}
public enum HylegicalPlace: String, CaseIterable, Codable, Sendable { case sun, moon, ascendant, fortune, syzygy }   // order fixed
public struct NamePlacement: Codable, Sendable, Equatable { public let place: HylegicalPlace; public let longitude: Double; public let offsetFromAscendant: Double; public let letter: HebrewLetter }
public struct AgrippaName: Codable, Sendable, Equatable {
    public let placements: [NamePlacement]   // 5 entries in HylegicalPlace order
    public var letters: [HebrewLetter]
    public var hebrew: String                // right-to-left string of characters in derivation order, e.g. "דראנד"
    public var latin: String                 // initials in derivation order, e.g. "DRAND"
    /// letter index = floor(normalize(longitude − asc)) mod 22
    public static func derive(from chart: NatalChart) -> AgrippaName
}
public struct Kamea: Codable, Sendable, Equatable {
    public let planet: Planet; public let order: Int; public let cells: [[Int]]   // rows top→bottom, 1-based lookups below
    public func value(row: Int, col: Int) -> Int          // traps (precondition) outside 1…order
    public func value(atRow row: Int, col: Int) -> Int?   // nil outside 1…order
    // Decoding validates that `cells` is order×order and holds 1…order² exactly once (DecodingError.dataCorrupted otherwise)
    public func cell(of value: Int) -> (row: Int, col: Int)?
    public static func forPlanet(_ p: Planet) -> Kamea   // Agrippa II.22 squares: Saturn 3 (4 9 2 / 3 5 7 / 8 1 6), Jupiter 4, Mars 5, Sun 6 (exactly the Appendix A grid), Venus 7, Mercury 8, Moon 9
    public static let sun: Kamea
}
public struct SigilPoint: Codable, Sendable, Equatable { public let row: Int; public let col: Int; public let value: Int; public let normalized: RVec2 /* cell centre, x right, y down, in [0,1] */ }
public struct SigilPath: Codable, Sendable, Equatable {
    public let kamea: Kamea; public let points: [SigilPoint]; public let reducedValues: [Int]   // [4,20,1,5,4]
    public var isClosed: Bool           // first cell == last cell
    public var startMarkerRadius: Double  // 0.045 (normalised)
    public var endBarLength: Double       // 0.06, perpendicular to the last segment (drawn even when closed)
    /// reduce: while value > order² { value /= 10 }
    public static func trace(name: AgrippaName, kamea: Kamea) -> SigilPath
    public var polyline: [RVec2]
}
public enum DaemonForm: String, Codable, Sendable { case leonine, ... one per sign (aries: ram-horned, taurus: bull, gemini: twin-faced, cancer: carapaced, leo: leonine, virgo: veiled, libra: winged, scorpio: chitinous, sagittarius: centaur, capricorn: goat-horned, aquarius: many-eyed, pisces: finned) }
public enum DaemonPalette: String, Codable, Sendable { case goldWhiteFire /* Sun */, silverBlue /* Moon */, quicksilver, copperGreen, ironRed, tinViolet, leadBlack }
public enum DaemonElement: String, Codable, Sendable { case fire, earth, air, water }
public enum DaemonMotion: String, Codable, Sendable { case expansiveArcing /* Sagittarius */, ... one per Moon sign }
public enum DaemonPresence: String, Codable, Sendable { case dominantUnhurried /* domicile+rising */, exaltedRadiant, subdued, wary, restless }
public struct DaemonProfile: Codable, Sendable, Equatable {
    public let chart: NatalChart; public let name: AgrippaName; public let kamea: Kamea; public let sigil: SigilPath
    public let form: DaemonForm; public let palette: DaemonPalette; public let element: DaemonElement; public let motion: DaemonMotion; public let presence: DaemonPresence
    public var paletteLinearRGB: (core: RVec3, mid: RVec3, edge: RVec3)  // gold-white: (1.0,0.96,0.85), (1.0,0.62,0.18), (0.75,0.18,0.02)
    public static func derive(from chart: NatalChart) -> DaemonProfile
    public static let owner: DaemonProfile   // derive(from: .compute(birth: .owner))
}
```

## Ritual (`Ritual/*.swift`)
```swift
public enum RitualStage: Int, CaseIterable, Codable, Sendable { case oath = 1, air, fire, water, earth, spirit, sigilSpin, manifestation
    public var id: String /* "oath","air",...,"sigilSpin","manifestation" */; public var title: String; public var quarter: Quarter?; public var element: RitualElement?; public var next: RitualStage? }
public enum Quarter: String, CaseIterable, Codable, Sendable { case east, south, west, north
    public var yawDegrees: Double /* 90, 0, 270, 180 */; public var candlePosition: RVec3; public var element: RitualElement }
public enum RitualElement: String, CaseIterable, Codable, Sendable { case air, fire, water, earth, spirit
    public var flameColorLinearRGB: RVec3   // air (1.0,0.93,0.72) warm white; fire (1.0,0.28,0.05); water (0.15,0.45,1.0); earth (0.2,1.0,0.3); spirit (1.0,0.85,0.6)
    public var flameTemperatureK: Double    // 2400, 1500, 0 (colour-only), 0, 2000
}
public enum InputKind: Codable, Sendable, Equatable { case holdBegin, holdEnd, tracePoint(RVec2), traceEnd, tap, flick(velocity: RVec2, ring: Int?), cameraYaw(Double)
    public var isFinite: Bool }   // false for a NaN/±inf yaw, trace point or flick velocity; such inputs are refused by RitualSimulation.apply
// flick convention: `velocity` is in the ring's tangential frame — +x along the tangent at the touch point in the direction of increasing
// angle. The core has no touch position, so the gesture recogniser must rotate the screen-space swipe into this frame before emitting the
// input (a radial swipe then has x ≈ 0 and imparts ~no spin); the impulse magnitude is clamp(|v|, 0, 4)·0.35 and the sign is sign(v.x).
public struct RitualInput: Codable, Sendable, Equatable { public let tick: Int; public let kind: InputKind; public init(tick:kind:) }
public struct CandleState: Codable, Sendable, Equatable { public var lit: Bool; public var ignitionTick: Int?; public var intensity: Double /* 0..1 ramp over 0.6 s */ }
public struct RitualState: Codable, Sendable, Equatable {
    public var stage: RitualStage; public var stageStartTick: Int; public var stageProgress: Double /* 0..1 */
    public var completedStages: Set<RitualStage>
    public var holding: Bool; public var chantProgress: Double; public var ringKindle: Double
    public var cameraYaw: Double; public var facingQuarter: Bool; public var trace: [RVec2]; public var traceHits: Int; public var traceAttempts: Int
    public var candles: [Quarter: CandleState]
    public var beatIndex: Int; public var beatResults: [BeatResult]; public var rhythmRound: Int
    public var sigilErupted: Bool; public var sigilEruptTick: Int?
    public var sigil: SigilDynamics
    public var spinEnergy: Double; public var manifestCharge: Double
    public var manifestStartTick: Int?; public var manifestT: Double
    public var completedTick: [RitualStage: Int]   // stage -> tick of completion (haptics fire when this changes)
    public var lastEvent: RitualEvent?
    // Codable layout is value-determined (custom encode/decode): completedStages sorted by rawValue, candles as an object keyed by
    // Quarter.rawValue, completedTick as an object keyed by RitualStage.id (never hash-ordered flat arrays) — so equal states give
    // byte-identical JSON under JSONEncoder .sortedKeys in every process.
}
public enum BeatResult: String, Codable, Sendable { case perfect, good, miss }
public enum RitualEvent: Codable, Sendable, Equatable { case stageCompleted(RitualStage), candleLit(Quarter), beatHit(BeatResult), sigilErupted, manifestationBegan, ritualComplete }
public struct RingState: Codable, Sendable, Equatable { public var angle: Double /* rad */; public var omega: Double /* rad/s */; public let radius: Double; public let inertia: Double }
public struct SigilDynamics: Codable, Sendable, Equatable {
    public var rings: [RingState]   // 5 rings, radii 0.75,0.62,0.50,0.39,0.29; masses 0.30,0.25,0.20,0.16,0.12 kg (I = m r²)
    public var viscous: Double /* 0.03 N·m·s (τ ≈ 5.6 s on ring 0) */; public var coulomb: Double /* 0.008 N·m */; public var coupling: Double /* 0.12 N·m·s */; public static let flickImpulsePerSpeed = 0.35 /* N·m·s per (unit of |v|) */
    public static let maxFrictionScale = 10.0   // frictionScale is clamped to 0…10 in step (explicit viscous update is stable only below ≈ 73)
    public init(); public mutating func step(dt: Double, frictionScale: Double)  // semi-implicit Euler; Coulomb friction never reverses sign
    public mutating func applyFlick(velocity: RVec2, ring: Int?)  // impulse J = clamp(|v|,0,4)·flickImpulsePerSpeed on the ring, sign from the tangential direction; adjacent rings receive −0.5 J (counter-rotation)
    public var kineticEnergy: Double
    public var sparkRate: Double     // Σ |ω_i| r_i × 40 sparks/s per (rad/s·m)
}
public struct SimConfig: Codable, Sendable, Equatable { public var frictionScale /* clamped to 0…SigilDynamics.maxFrictionScale at step time */, gravityScale, emberScale: Double; public var autopilot: Bool; public init() }
public struct Keyframe: Codable, Sendable, Equatable { public let tick: Int; public let state: RitualState; public let rng: SeededRNG }
public final class RitualSimulation {   // not Sendable; owned by the render thread
    public static let tickRate = 120; public static let keyframeInterval = 240
    public init(seed: UInt64, config: SimConfig = SimConfig())
    public private(set) var tick: Int; public private(set) var state: RitualState; public var config: SimConfig
    public private(set) var inputLog: [RitualInput]; public private(set) var keyframes: [Keyframe]
    public func apply(_ input: RitualInput)   // must be for tick >= current tick; appended to inputLog; an input with !kind.isFinite is dropped (not logged)
    public func step()                       // advance one tick, consuming inputs whose tick == current tick, then keyframe if tick % 240 == 0
    public func step(ticks: Int)
    public func seek(toTick target: Int)      // restore nearest keyframe ≤ target (or tick 0) and replay inputLog; if target > max simulated, simulate forward; lastStepEvents is empty afterwards
    public private(set) var lastStepEvents: [RitualEvent]   // events of the most recent step(); empty after any seek
    public var maxSimulatedTick: Int
    public func jump(to stage: RitualStage)   // deterministic: uses Autopilot to complete prior stages, appending its inputs to the log from the current tick
}
public enum SigilTemplates { public static func path(for element: RitualElement) -> [RVec2]; public static func checkpoints(for element: RitualElement, count: Int = 24) -> [RVec2] }
public struct TraceScorer { public static let hitRadius = 0.09; public static func score(trace: [RVec2], checkpoints: [RVec2]) -> Int /* hits in order */ }
public enum RhythmSpec { public static let beatTimes: [Double] = [1.0, 1.8, 2.6, 3.4, 4.2, 5.0]; public static let names = ["Aoth","Abaoth","Basum","Isak","Sabaoth","Iao"]; perfectWindow 0.15; goodWindow 0.30; retryDelay 1.5 }
public enum EmberModel {
    public static let dragK = 6.0, lifetime = 2.5, tempStartK = 1900.0, tempEndK = 800.0
    /// Closed form (see ARCHITECTURE §6). gravity = 9.81 × gravityScale (m/s², downward −Y).
    public static func position(x0: RVec3, v0: RVec3, tau: Double, gravity: Double) -> RVec3
    public static func spawn(ring: RingState, ringIndex: Int, sigilCenter: RVec3, seed: UInt64, tick: Int, index: Int) -> (x0: RVec3, v0: RVec3)  // tangential v = ω r t̂ (+ 0.15 m/s jitter) + 0.25 m/s upward; t̂ from angle + hash phase
}
public enum Autopilot {
    /// Deterministic input script that completes every stage < `stage`, then positions the sim at the showcase for `stage`.
    public static func inputs(through stage: RitualStage, seed: UInt64, startTick: Int = 0) -> [RitualInput]
    public static func showcaseTick(for stage: RitualStage, seed: UInt64) -> Int   // tick at which the critic captures that stage
}
```
Showcase definitions: oath → 1.8 s into the chant (ring ≈ 60 % kindled); earth → 1.2 s after
the North candle ignites (all four lit, flames settled); sigilSpin → 1.0 s after the third
autopilot flick (rings at peak spin, sparks shedding); manifestation → manifestT = 1 + 2 s.

## Capture (`Capture/*.swift`)
```swift
public enum CameraPreset: String, CaseIterable, Codable, Sendable { case front, threequarter, profile, overhead, low, closeup; public var position: RVec3; public var target: RVec3 }
public enum RenderPathChoice: String, Codable, Sendable { case rt, fallback, auto }
public enum CaptureMode: String, Codable, Sendable { case stills, clip, perf, none }
public struct CaptureConfig: Codable, Sendable, Equatable {
    public var stage: RitualStage /* default .oath */, camera: CameraPreset /* .threequarter */, renderPath: RenderPathChoice /* .auto */, seed: UInt64 /* 1 */, mode: CaptureMode /* .none */
    public var clipSeconds: Double /* 5 */, perfSeconds: Double /* 300 */, runName: String /* "run" */, renderScale: Double /* 0.67 */, autopilot: Bool /* true if mode != none */, warmupFrames: Int /* 16 */, narration: Bool /* false */
    public static func parse(arguments: [String]) -> CaptureConfig   // "-stage 7 -camera low ..." ; unknown keys ignored; invalid values → defaults
    public var isCaptureRun: Bool
    public func stillFileName(path: String) -> String   // "still_s7_low_rt.png"
    public func clipDirectoryName(path: String) -> String
}
public struct FrameLogEntry: Codable, Sendable, Equatable { public var index: Int; public var time: Double; public var tick: Int; public var cpuMs: Double; public var gpuMs: Double; public var frameMs: Double; public var thermal: String /* nominal/fair/serious/critical */ }
public struct FrameLog: Codable, Sendable, Equatable {
    public var device: String; public var os: String; public var renderPath: String; public var seed: UInt64; public var stage: Int; public var camera: String; public var renderScale: Double; public var metalFX: Bool
    public var frames: [FrameLogEntry]
    public struct Summary: Codable, Sendable, Equatable { public var averageFps, p50FrameMs, p99FrameMs, maxFrameMs: Double; public var spikesOver20ms: Int; public var framesTotal: Int; public var thermalStates: [String: Int] }
    public func summary() -> Summary
    public func jsonData() throws -> Data   // sorted keys, pretty
}
```

## Tests required (`Tests/RitualCoreTests`)
- `EphemerisTests`: every vector in `Fixtures/ephemeris_vectors.json` (41 vectors, Swiss Ephemeris/Moshier) within: Sun 0.01°, Moon 0.05°, ASC 0.05°, MC 0.05°, altitude 0.1°, obliquity 0.001°, nutation 0.001°; prenatal syzygy longitude 0.05° and instant within 2 minutes.
- `AppendixATests`: owner chart pins every Appendix A number (0.05°); `appendixAReport()` is checked line by line: the 9-line layout, labels, sign names and the degree/minute strings must match Appendix A exactly, while the decimal longitudes in parentheses are parsed and compared with 0.01° tolerance (the Meeus Moon differs from Swiss/Moshier by a few arc-seconds); name DRAND / דראנד with the five placements' letters, sigil cells, closed loop, attributes.
- `NameDerivationTests`: synthetic charts hitting wrap-around (offset 355.85 → Daleth), exact-degree boundaries, all 22 letters reachable; value reduction 200→20, 50→5, 400→4, 300→3; kamea validity (every 1..n² once, magic sums) for all seven squares.
- `DeterminismTests`: same seed+inputs ⇒ identical state after 10,000 ticks; seek(toTick) after arbitrary stepping ⇒ identical to straight-through; Hash pins (e.g. Hash.u32(1,2,3,4) fixed value recorded in the test); PCG32 pins against the reference C implementation (seed 42, stream 54 → first outputs 0xa15c02b7, 0x7b47f409, 0xba1d3330, 0x83d2f293, 0xbfa4784b) — verify by implementing the reference exactly.
- `RitualFlowTests`: autopilot completes all stages in order; stage order 1..8 asserted; candles ignite in East, South, West, North order; rhythm scoring windows; trace scorer passes a resampled template with noise 0.03 and fails a random scribble; camera-facing gate blocks the trace when not facing; SigilDynamics energy is non-increasing without flicks, counter-rotation of adjacent rings after a flick, Coulomb friction stops rings without sign reversal; manifest charge reaches 1 only with spin.
- `EmberModelTests`: closed form matches numeric integration (RK4, dt 1e-4) within 1 mm over 2.5 s; τ = 0 gives x0; gravity scale 0 ⇒ v_t = 0.
- `CaptureConfigTests`: argument parsing round-trips; file naming; FrameLog summary math (p99 etc.).
