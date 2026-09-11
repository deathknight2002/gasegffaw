import Foundation

// MARK: - Stages

/// The eight ritual stages in fixed order (ARCHITECTURE §3). Raw values are 1…8 and
/// match the `-stage` launch argument.
public enum RitualStage: Int, CaseIterable, Codable, Sendable {
    case oath = 1, air, fire, water, earth, spirit, sigilSpin, manifestation

    /// Stable identifier ("oath", "air", …, "sigilSpin", "manifestation").
    public var id: String {
        switch self {
        case .oath: return "oath"
        case .air: return "air"
        case .fire: return "fire"
        case .water: return "water"
        case .earth: return "earth"
        case .spirit: return "spirit"
        case .sigilSpin: return "sigilSpin"
        case .manifestation: return "manifestation"
        }
    }

    /// Human-readable title for the HUD.
    public var title: String {
        switch self {
        case .oath: return "The Oath"
        case .air: return "Air — East"
        case .fire: return "Fire — South"
        case .water: return "Water — West"
        case .earth: return "Earth — North"
        case .spirit: return "Spirit"
        case .sigilSpin: return "The Sigil Spins"
        case .manifestation: return "Manifestation"
        }
    }

    /// The quarter the sorcerer must face during this stage (elemental stages only).
    public var quarter: Quarter? {
        switch self {
        case .air: return .east
        case .fire: return .south
        case .water: return .west
        case .earth: return .north
        case .oath, .spirit, .sigilSpin, .manifestation: return nil
        }
    }

    /// The element invoked by this stage, if any.
    public var element: RitualElement? {
        switch self {
        case .air: return .air
        case .fire: return .fire
        case .water: return .water
        case .earth: return .earth
        case .spirit: return .spirit
        case .oath, .sigilSpin, .manifestation: return nil
        }
    }

    /// The following stage, or `nil` after `manifestation`.
    public var next: RitualStage? {
        RitualStage(rawValue: rawValue + 1)
    }
}

// MARK: - Quarters

/// The four quarters of the circle, in ritual (ignition) order East, South, West, North.
public enum Quarter: String, CaseIterable, Codable, Sendable {
    case east, south, west, north

    /// Camera yaw (degrees, measured from +Z toward +X) that faces this quarter:
    /// East 90, South 0, West 270, North 180.
    public var yawDegrees: Double {
        switch self {
        case .east: return 90
        case .south: return 0
        case .west: return 270
        case .north: return 180
        }
    }

    /// Floor position of the quarter candle stand (radius 1.80 m; ARCHITECTURE §2).
    public var candlePosition: RVec3 {
        switch self {
        case .east: return RVec3(1.8, 0, 0)
        case .south: return RVec3(0, 0, 1.8)
        case .west: return RVec3(-1.8, 0, 0)
        case .north: return RVec3(0, 0, -1.8)
        }
    }

    /// Height of the candle flame origin above the floor (stand 0.90 m + wax 0.22 m + wick).
    public static let flameHeight = 1.13

    /// Position of the quarter candle's flame origin (`candlePosition` raised to `flameHeight`).
    public var flamePosition: RVec3 {
        var position = candlePosition
        position.y = Quarter.flameHeight
        return position
    }

    /// Element attributed to the quarter.
    public var element: RitualElement {
        switch self {
        case .east: return .air
        case .south: return .fire
        case .west: return .water
        case .north: return .earth
        }
    }

    /// The elemental stage worked at this quarter.
    public var stage: RitualStage {
        switch self {
        case .east: return .air
        case .south: return .fire
        case .west: return .water
        case .north: return .earth
        }
    }

    /// Half-width in degrees of the "facing" tolerance (`|wrap180(yaw − yawDegrees)| ≤ 30`).
    public static let facingToleranceDegrees = 30.0

    /// Whether a camera yaw (degrees) counts as facing this quarter.
    public func isFaced(byYaw yaw: Double) -> Bool {
        abs(Angle.wrap180(yaw - yawDegrees)) <= Quarter.facingToleranceDegrees
    }
}

// MARK: - Elements

/// The five ritual elements: the four quarter elements plus Spirit (the sigil).
public enum RitualElement: String, CaseIterable, Codable, Sendable {
    case air, fire, water, earth, spirit

    /// Linear-RGB tint of the element's flame.
    public var flameColorLinearRGB: RVec3 {
        switch self {
        case .air: return RVec3(1.0, 0.93, 0.72)
        case .fire: return RVec3(1.0, 0.28, 0.05)
        case .water: return RVec3(0.15, 0.45, 1.0)
        case .earth: return RVec3(0.2, 1.0, 0.3)
        case .spirit: return RVec3(1.0, 0.85, 0.6)
        }
    }

    /// Blackbody temperature of the flame in kelvin; 0 means colour-only (no blackbody term).
    public var flameTemperatureK: Double {
        switch self {
        case .air: return 2400
        case .fire: return 1500
        case .water: return 0
        case .earth: return 0
        case .spirit: return 2000
        }
    }

    /// The quarter this element belongs to (`nil` for Spirit).
    public var quarter: Quarter? {
        switch self {
        case .air: return .east
        case .fire: return .south
        case .water: return .west
        case .earth: return .north
        case .spirit: return nil
        }
    }
}

// MARK: - Inputs

/// A single user (or autopilot) input, applied at a simulation tick.
public enum InputKind: Codable, Sendable, Equatable {
    /// Finger down on the chant control.
    case holdBegin
    /// Finger lifted from the chant control.
    case holdEnd
    /// A sample of the sigil trace in normalised [0, 1]² coordinates.
    case tracePoint(RVec2)
    /// The trace finger lifted; the trace is scored.
    case traceEnd
    /// Rhythm tap.
    case tap
    /// Flick on the spinning sigil; `ring` is the ring under the finger (0…4) or `nil`.
    case flick(velocity: RVec2, ring: Int?)
    /// Camera yaw set to the given degrees.
    case cameraYaw(Double)
}

/// An input stamped with the tick it applies to. The simulation consumes inputs in log order.
public struct RitualInput: Codable, Sendable, Equatable {
    /// Simulation tick (120 Hz) at which the input applies.
    public let tick: Int
    /// The input.
    public let kind: InputKind

    /// Creates an input record.
    ///
    /// - Parameters:
    ///   - tick: Simulation tick at which the input applies.
    ///   - kind: The input.
    public init(tick: Int, kind: InputKind) {
        self.tick = tick
        self.kind = kind
    }
}

// MARK: - Events and rhythm

/// Timing quality of a rhythm tap.
public enum BeatResult: String, Codable, Sendable, CaseIterable {
    /// Within ±0.15 s of the beat.
    case perfect
    /// Within ±0.30 s of the beat.
    case good
    /// Outside the good window (or no tap).
    case miss

    /// Whether the result counts toward the "≥ 5 good of 6" success rule.
    public var isHit: Bool {
        self != .miss
    }
}

/// Discrete events raised by the simulation (haptics/narration react to these).
public enum RitualEvent: Codable, Sendable, Equatable {
    /// A stage was completed.
    case stageCompleted(RitualStage)
    /// A quarter candle ignited.
    case candleLit(Quarter)
    /// A rhythm beat was judged.
    case beatHit(BeatResult)
    /// The fiery sigil erupted above the circle.
    case sigilErupted
    /// Manifestation charge reached 1.
    case manifestationBegan
    /// The daemon finished condensing.
    case ritualComplete
}

// MARK: - Candles

/// State of one quarter candle.
public struct CandleState: Codable, Sendable, Equatable {
    /// Whether the candle has been lit.
    public var lit: Bool
    /// Tick at which it ignited, or `nil` while unlit.
    public var ignitionTick: Int?
    /// Flame intensity 0…1, ramping over `rampSeconds` after ignition.
    public var intensity: Double

    /// Duration of the ignition ramp in seconds.
    public static let rampSeconds = 0.6

    /// An unlit candle.
    public static let unlit = CandleState(lit: false, ignitionTick: nil, intensity: 0)

    /// Creates a candle state.
    ///
    /// - Parameters:
    ///   - lit: Whether the candle is lit.
    ///   - ignitionTick: Tick of ignition, if lit.
    ///   - intensity: Flame intensity 0…1.
    public init(lit: Bool = false, ignitionTick: Int? = nil, intensity: Double = 0) {
        self.lit = lit
        self.ignitionTick = ignitionTick
        self.intensity = intensity
    }
}
