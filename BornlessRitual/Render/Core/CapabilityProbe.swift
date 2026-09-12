//
//  CapabilityProbe.swift
//  Bornless Ritual — device capability detection (RENDER_CONTRACT §1: `renderPath`
//  "resolved from settings (.auto → .rt if device.supportsRaytracing &&
//  supportsFamily(.apple9) else .fallback)"; ARCHITECTURE §8 "active render path and
//  why (device capability)").
//
//  Role: probes the Metal device once at startup and resolves a `RenderPathChoice`
//  into the concrete `RenderPath`, producing a human-readable explanation for the
//  debug panel and the capture manifest.
//

import Foundation
import Metal
import MetalFX
import RitualCore

/// Immutable snapshot of what the GPU supports.
struct CapabilityProbe: Sendable {
    /// `MTLDevice.name`.
    let deviceName: String
    /// `MTLDevice.supportsRaytracing` (any RT support, hardware or emulated).
    let supportsRaytracing: Bool
    /// `MTLDevice.supportsFamily(.apple9)` — A17 Pro / M3 class with hardware RT units.
    let supportsApple9: Bool
    /// `MTLDevice.supportsFamily(.apple8)`.
    let supportsApple8: Bool
    /// `MTLDevice.supportsFamily(.apple7)`.
    let supportsApple7: Bool
    /// `MTLDevice.supportsFamily(.apple4)` — layered rendering, needed for 3-D history clears.
    let supportsApple4: Bool
    /// `MTLFXTemporalScalerDescriptor.supportsDevice(_:)`.
    let supportsMetalFXTemporal: Bool
    /// `MTLDevice.supportsFunctionPointers` (informational).
    let supportsFunctionPointers: Bool
    /// `MTLDevice.hasUnifiedMemory`.
    let hasUnifiedMemory: Bool
    /// `MTLDevice.recommendedMaxWorkingSetSize` in bytes (0 when unavailable).
    let recommendedMaxWorkingSetSize: UInt64

    /// Hardware ray tracing = RT support on an Apple9-class GPU (the contract's `.auto` rule).
    var hardwareRT: Bool { supportsRaytracing && supportsApple9 }

    /// The path `.auto` resolves to on this device.
    var recommendedPath: RenderPath { hardwareRT ? .rt : .fallback }

    /// Probes `device`.
    init(device: MTLDevice) {
        deviceName = device.name
        supportsRaytracing = device.supportsRaytracing
        supportsApple9 = device.supportsFamily(.apple9)
        supportsApple8 = device.supportsFamily(.apple8)
        supportsApple7 = device.supportsFamily(.apple7)
        supportsApple4 = device.supportsFamily(.apple4)
        supportsMetalFXTemporal = MTLFXTemporalScalerDescriptor.supportsDevice(device)
        supportsFunctionPointers = device.supportsFunctionPointers
        hasUnifiedMemory = device.hasUnifiedMemory
        recommendedMaxWorkingSetSize = device.recommendedMaxWorkingSetSize
    }

    /// Resolves the user's / capture's choice into the path that will actually run.
    ///
    /// `.rt` is honoured whenever the device reports ray-tracing support at all (it is
    /// the user's explicit request); `.auto` additionally requires the Apple9 family so
    /// that the RT path only runs where it can hold 60 fps (ARCHITECTURE §9).
    func resolve(_ choice: RenderPathChoice) -> RenderPath {
        switch choice {
        case .rt: return supportsRaytracing ? .rt : .fallback
        case .fallback: return .fallback
        case .auto: return recommendedPath
        }
    }

    /// Why `resolve(choice)` produced its answer, for the debug panel.
    func reason(for choice: RenderPathChoice) -> String {
        let resolved = resolve(choice)
        switch choice {
        case .rt:
            return supportsRaytracing
                ? "rt (requested; ray tracing supported\(supportsApple9 ? ", Apple9 hardware RT" : ", no Apple9 hardware RT — expect reduced performance"))"
                : "fallback (rt requested but device has no ray-tracing support)"
        case .fallback:
            return "fallback (requested)"
        case .auto:
            if resolved == .rt {
                return "rt (auto: supportsRaytracing && Apple9)"
            }
            if !supportsRaytracing {
                return "fallback (auto: device has no ray-tracing support)"
            }
            return "fallback (auto: ray tracing supported but GPU is not Apple9 class)"
        }
    }

    /// Whether the MetalFX temporal scaler can be used (else the TAA fallback in `TAA.metal`).
    func metalFXAvailable(requested: Bool) -> Bool {
        requested && supportsMetalFXTemporal
    }

    /// Multi-line human-readable report for the debug panel and `manifest.json`.
    var report: String {
        let workingSetMB = recommendedMaxWorkingSetSize / (1024 * 1024)
        let lines = [
            "Device: \(deviceName)",
            "Ray tracing: \(supportsRaytracing ? "yes" : "no") (Apple9: \(supportsApple9 ? "yes" : "no") → hardware RT: \(hardwareRT ? "yes" : "no"))",
            "GPU family: \(familyDescription)",
            "MetalFX temporal: \(supportsMetalFXTemporal ? "yes" : "no")",
            "Function pointers: \(supportsFunctionPointers ? "yes" : "no")",
            "Unified memory: \(hasUnifiedMemory ? "yes" : "no"), working set ≈ \(workingSetMB) MB",
            "Recommended path: \(recommendedPath.displayName)",
        ]
        return lines.joined(separator: "\n")
    }

    /// Highest supported Apple family, as text.
    var familyDescription: String {
        if supportsApple9 { return "Apple9" }
        if supportsApple8 { return "Apple8" }
        if supportsApple7 { return "Apple7" }
        if supportsApple4 { return "Apple4–6" }
        return "pre-Apple4"
    }
}
