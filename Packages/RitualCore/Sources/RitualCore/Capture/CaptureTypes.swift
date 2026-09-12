import Foundation

// MARK: - Camera presets

/// Fixed camera positions used by the critic captures and the debug panel (ARCHITECTURE §2).
/// Raw values match the `-camera` launch argument.
public enum CameraPreset: String, CaseIterable, Codable, Sendable {
    case front, threequarter, profile, overhead, low, closeup

    /// Camera position in metres (right-handed, +Y up, East = +X, South = +Z).
    public var position: RVec3 {
        switch self {
        case .front: return RVec3(0, 1.5, 4.6)
        case .threequarter: return RVec3(3.3, 1.9, 3.3)
        case .profile: return RVec3(4.6, 1.4, 0)
        case .overhead: return RVec3(0, 3.85, 0.05)
        case .low: return RVec3(0, 0.32, 3.6)
        case .closeup: return RVec3(0.9, 1.65, 1.35)
        }
    }

    /// Look-at target in metres.
    public var target: RVec3 {
        switch self {
        case .front: return RVec3(0, 1.2, 0)
        case .threequarter: return RVec3(0, 1.2, 0)
        case .profile: return RVec3(0, 1.2, 0)
        case .overhead: return RVec3(0, 0, 0)
        case .low: return RVec3(0, 1.3, 0)
        case .closeup: return RVec3(0, 1.45, -0.1)
        }
    }

    /// Vertical field of view in degrees shared by every preset.
    public static let verticalFOVDegrees = 50.0
    /// Near clip plane distance in metres.
    public static let nearPlane = 0.05
    /// Far clip plane distance in metres.
    public static let farPlane = 30.0
}

// MARK: - Capture configuration enums

/// Which render path the app should use. Raw values match the `-renderPath` launch argument.
public enum RenderPathChoice: String, Codable, Sendable, CaseIterable {
    /// Hardware ray tracing.
    case rt
    /// SDF/raster fallback path.
    case fallback
    /// Pick by device capability.
    case auto
}

/// What the capture harness should record. Raw values match the `-capture` launch argument.
public enum CaptureMode: String, Codable, Sendable, CaseIterable {
    /// One PNG at the stage's showcase tick.
    case stills
    /// A frame sequence running live from the showcase tick.
    case clip
    /// Full ritual on autopilot with per-frame timing only.
    case perf
    /// Interactive run; no files written.
    case none
}
