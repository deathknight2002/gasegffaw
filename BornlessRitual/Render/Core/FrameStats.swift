//
//  FrameStats.swift
//  Bornless Ritual — frame timing statistics (ARCHITECTURE §8 debug panel: fps (1 s
//  average), frame time ms (CPU + GPU), 1 % low, thermal state; RENDER_CONTRACT §7:
//  GPU time from gpuStartTime/gpuEndTime, thermal polled each second).
//
//  Role: `FrameStats` is the value published to the debug panel and the capture
//  manifest; `FrameTimingWindow` accumulates per-frame samples over a 120-frame window
//  and derives the averages. Thread-safe: the GPU completion handler records samples
//  from a Metal callback thread while the main thread reads snapshots.
//

import Foundation

/// Snapshot of frame timing for the debug panel.
struct FrameStats: Sendable, Equatable {
    /// Frames per second over the window (mean frame time).
    var fps: Double = 0
    /// Mean CPU encode time per frame in milliseconds.
    var cpuMs: Double = 0
    /// Mean GPU time per frame in milliseconds (`gpuEndTime − gpuStartTime`).
    var gpuMs: Double = 0
    /// Mean wall frame time in milliseconds.
    var frameMs: Double = 0
    /// "1 % low": fps equivalent of the slowest 1 % of frames in the window (1000 / p99 ms).
    var p1Low: Double = 0
    /// 99th-percentile frame time in milliseconds.
    var p99FrameMs: Double = 0
    /// Worst frame time in the window, milliseconds.
    var maxFrameMs: Double = 0
    /// `ProcessInfo.thermalState` as "nominal" / "fair" / "serious" / "critical".
    var thermal: String = "nominal"
    /// Frames accumulated so far (≤ window length).
    var sampleCount: Int = 0

    /// One-line summary for the HUD.
    var summaryLine: String {
        String(format: "%.1f fps  cpu %.2f ms  gpu %.2f ms  1%%low %.1f  %@", fps, cpuMs, gpuMs, p1Low, thermal)
    }
}

/// Maps `ProcessInfo.ThermalState` to the strings used by `FrameLogEntry.thermal`.
extension ProcessInfo.ThermalState {
    /// "nominal", "fair", "serious" or "critical".
    var ritualName: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }
}

/// One frame's measurements.
struct FrameSample: Sendable, Equatable {
    /// Wall time between consecutive presented frames, seconds.
    var frameSeconds: Double
    /// CPU time spent in `draw(in:)` up to commit, seconds.
    var cpuSeconds: Double
    /// GPU execution time, seconds (0 until the completion handler fills it in).
    var gpuSeconds: Double
}

/// Ring buffer of the last `windowLength` frames with derived statistics.
final class FrameTimingWindow: @unchecked Sendable {
    /// Window length (ARCHITECTURE §8: 120 frames ≈ 2 s at 60 fps).
    let windowLength: Int

    private let lock = NSLock()
    private var samples: [FrameSample]
    private var nextIndex = 0
    private var filled = 0
    private var thermalName = ProcessInfo.processInfo.thermalState.ritualName
    private var lastThermalPoll: TimeInterval = 0

    /// Creates an empty window.
    init(windowLength: Int = 120) {
        self.windowLength = max(windowLength, 1)
        self.samples = Array(repeating: FrameSample(frameSeconds: 0, cpuSeconds: 0, gpuSeconds: 0), count: self.windowLength)
    }

    /// Records one frame. Safe to call from any thread.
    func record(_ sample: FrameSample) {
        lock.lock()
        samples[nextIndex] = sample
        nextIndex = (nextIndex + 1) % windowLength
        filled = min(filled + 1, windowLength)
        lock.unlock()
    }

    /// Re-reads `ProcessInfo.thermalState` at most once per second.
    func pollThermal(now: TimeInterval) {
        lock.lock()
        if now - lastThermalPoll >= 1.0 {
            lastThermalPoll = now
            thermalName = ProcessInfo.processInfo.thermalState.ritualName
        }
        lock.unlock()
    }

    /// Current thermal string.
    var thermal: String {
        lock.lock()
        defer { lock.unlock() }
        return thermalName
    }

    /// Clears all samples (after a seek or path change so the window reflects steady state).
    func reset() {
        lock.lock()
        nextIndex = 0
        filled = 0
        lock.unlock()
    }

    /// Computes the statistics over the recorded samples.
    func snapshot() -> FrameStats {
        lock.lock()
        let count = filled
        let window = Array(samples.prefix(count))
        let thermal = thermalName
        lock.unlock()

        var stats = FrameStats()
        stats.thermal = thermal
        stats.sampleCount = count
        guard count > 0 else { return stats }

        var frameSum = 0.0
        var cpuSum = 0.0
        var gpuSum = 0.0
        var frameTimes: [Double] = []
        frameTimes.reserveCapacity(count)
        for sample in window {
            frameSum += sample.frameSeconds
            cpuSum += sample.cpuSeconds
            gpuSum += sample.gpuSeconds
            frameTimes.append(sample.frameSeconds)
        }
        let meanFrame = frameSum / Double(count)
        stats.frameMs = meanFrame * 1000
        stats.cpuMs = cpuSum / Double(count) * 1000
        stats.gpuMs = gpuSum / Double(count) * 1000
        stats.fps = meanFrame > 0 ? 1.0 / meanFrame : 0

        frameTimes.sort()
        let p99Index = min(count - 1, Int((Double(count - 1) * 0.99).rounded()))
        let p99 = frameTimes[p99Index]
        stats.p99FrameMs = p99 * 1000
        stats.maxFrameMs = (frameTimes.last ?? 0) * 1000
        stats.p1Low = p99 > 0 ? 1.0 / p99 : 0
        return stats
    }
}
