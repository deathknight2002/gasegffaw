//
//  CaptureManifest.swift
//  Bornless Ritual — `manifest.json` schema and device identification for the capture
//  harness (ARCHITECTURE §7 "`<run>/manifest.json` (config, device, chart report, name,
//  sigil cells)"; docs/CRITIC.md "Fidelity: manifest.json (chart report, name, sigil
//  cells)"; §4 sigil cells "(6,4)→(4,2)→(1,6)→(6,2)→(6,4)").
//
//  Role: a Codable record written once per capture run beside `frametime.json`, plus
//  `DeviceInfo` (hardware model via `utsname`, OS version via `ProcessInfo`) shared with
//  `FrameLog`. Everything is plain Foundation so it parses on Linux.
//

import Foundation
import RitualCore

/// Contents of `manifest.json`.
struct CaptureManifest: Codable, Equatable {
    /// Schema version of this manifest.
    static let currentSchemaVersion = 1

    /// The daemon's name in both scripts.
    struct Name: Codable, Equatable {
        /// Hebrew letters in derivation order (right-to-left string), e.g. "דראנד".
        var hebrew: String
        /// Latin initials, e.g. "DRAND".
        var latin: String
    }

    /// Derived daemon attributes (ARCHITECTURE §4).
    struct Attributes: Codable, Equatable {
        var form: String
        var palette: String
        var element: String
        var motion: String
        var presence: String
    }

    /// Native and internal resolutions of the run.
    struct Resolution: Codable, Equatable {
        var outputWidth: Int
        var outputHeight: Int
        var renderWidth: Int
        var renderHeight: Int
    }

    var schemaVersion: Int = CaptureManifest.currentSchemaVersion
    /// ISO-8601 creation time.
    var createdAt: String
    /// "ok" or "failed".
    var status: String
    /// Error messages collected during the run (empty on success).
    var errors: [String]
    /// The parsed launch configuration.
    var config: CaptureConfig
    /// The launch arguments that reproduce `config`.
    var launchArguments: [String]
    /// Render path actually used ("rt" / "fallback").
    var resolvedRenderPath: String
    /// Why that path was chosen (device capability).
    var renderPathReason: String
    /// Whether the MetalFX temporal scaler was active.
    var metalFX: Bool
    /// Hardware model identifier (e.g. "iPhone16,1").
    var device: String
    /// OS name and version.
    var os: String
    /// Multi-line device capability report.
    var capabilities: String
    /// Resolutions.
    var resolution: Resolution
    /// `NatalChart.appendixAReport()` verbatim.
    var chartReport: String
    /// The daemon's name.
    var name: Name
    /// Sigil cells as [row, col] pairs in path order.
    var sigilCells: [[Int]]
    /// Sigil cells as "(6,4)→(4,2)→…".
    var sigilCellsText: String
    /// Reduced gematria values traced on the kamea.
    var sigilReducedValues: [Int]
    /// Derived attributes.
    var attributes: Attributes
    /// Tick the autopilot positioned the ritual at.
    var showcaseTick: Int
    /// Tick of the captured still / first clip frame, when one was captured.
    var capturedTick: Int?
    /// Files written into the run directory (relative paths).
    var files: [String]
    /// Frame-time summary of `frametime.json`.
    var frameSummary: FrameLog.Summary?

    /// Pretty-printed JSON with sorted keys.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Sigil cells of a profile as "(row,col)→…".
    static func sigilCellsText(for profile: DaemonProfile) -> String {
        profile.sigil.points.map { "(\($0.row),\($0.col))" }.joined(separator: "→")
    }

    /// Sigil cells of a profile as [row, col] pairs.
    static func sigilCells(for profile: DaemonProfile) -> [[Int]] {
        profile.sigil.points.map { [$0.row, $0.col] }
    }

    /// Attributes of a profile as raw strings.
    static func attributes(for profile: DaemonProfile) -> Attributes {
        Attributes(form: profile.form.rawValue,
                   palette: profile.palette.rawValue,
                   element: profile.element.rawValue,
                   motion: profile.motion.rawValue,
                   presence: profile.presence.rawValue)
    }
}

/// Device identification for `FrameLog` and `CaptureManifest`.
enum DeviceInfo {
    /// Hardware model identifier from `utsname.machine` (e.g. "iPhone16,1"; "x86_64" or
    /// "arm64" in the Simulator).
    static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        var identifier = ""
        for child in mirror.children {
            guard let value = child.value as? Int8, value != 0 else { continue }
            identifier.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    /// "iOS 17.4.1" style OS string.
    static var osVersionString: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// ISO-8601 timestamp of now (UTC, fractional seconds).
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
