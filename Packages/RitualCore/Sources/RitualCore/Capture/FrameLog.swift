import Foundation

// MARK: - FrameLogEntry

/// Timing record of one rendered frame, as written to `frametime.json` (ARCHITECTURE §7).
public struct FrameLogEntry: Codable, Sendable, Equatable {
    /// Zero-based frame index within the run.
    public var index: Int
    /// Wall-clock time in seconds since the run started.
    public var time: Double
    /// Simulation tick rendered by this frame.
    public var tick: Int
    /// CPU time spent on the frame in milliseconds (sim + encoding).
    public var cpuMs: Double
    /// GPU time of the frame in milliseconds.
    public var gpuMs: Double
    /// Frame-to-frame interval in milliseconds (what the fps and percentiles are computed from).
    public var frameMs: Double
    /// `ProcessInfo.thermalState` name at the time: `nominal`, `fair`, `serious` or `critical`.
    public var thermal: String

    /// Creates a frame record.
    ///
    /// - Parameters:
    ///   - index: Zero-based frame index.
    ///   - time: Seconds since the run started.
    ///   - tick: Simulation tick rendered.
    ///   - cpuMs: CPU milliseconds.
    ///   - gpuMs: GPU milliseconds.
    ///   - frameMs: Frame interval in milliseconds.
    ///   - thermal: Thermal state name.
    public init(index: Int, time: Double, tick: Int, cpuMs: Double, gpuMs: Double, frameMs: Double, thermal: String) {
        self.index = index
        self.time = time
        self.tick = tick
        self.cpuMs = cpuMs
        self.gpuMs = gpuMs
        self.frameMs = frameMs
        self.thermal = thermal
    }
}

// MARK: - FrameLog

/// Per-frame timing log of a capture run plus the metadata needed to compare runs
/// (`frametime.json`, ARCHITECTURE §7).
///
/// The JSON produced by `jsonData()` carries a derived `summary` object so that host tools can
/// read the headline numbers without recomputing them; the summary is ignored when decoding,
/// because it is always a function of `frames`.
public struct FrameLog: Codable, Sendable, Equatable {
    /// Device model identifier (e.g. `"iPhone16,1"`).
    public var device: String
    /// OS name and version (e.g. `"iOS 17.4"`).
    public var os: String
    /// Render path actually used (`"rt"` or `"fallback"`).
    public var renderPath: String
    /// Simulation/render seed of the run.
    public var seed: UInt64
    /// Ritual stage number 1…8 captured (or the starting stage of a perf run).
    public var stage: Int
    /// Camera preset raw value.
    public var camera: String
    /// Internal render scale used.
    public var renderScale: Double
    /// Whether MetalFX temporal upscaling was active.
    public var metalFX: Bool
    /// One record per rendered frame, in order.
    public var frames: [FrameLogEntry]

    /// Frame interval above which a frame counts as a spike (`spikesOver20ms`).
    public static let spikeThresholdMs = 20.0

    /// Creates a log with the given metadata.
    ///
    /// - Parameters:
    ///   - device: Device model identifier.
    ///   - os: OS name and version.
    ///   - renderPath: Render path actually used.
    ///   - seed: Run seed.
    ///   - stage: Stage number 1…8.
    ///   - camera: Camera preset raw value.
    ///   - renderScale: Internal render scale.
    ///   - metalFX: Whether MetalFX was active.
    ///   - frames: Frame records (defaults to empty).
    public init(
        device: String,
        os: String,
        renderPath: String,
        seed: UInt64,
        stage: Int,
        camera: String,
        renderScale: Double,
        metalFX: Bool,
        frames: [FrameLogEntry] = []
    ) {
        self.device = device
        self.os = os
        self.renderPath = renderPath
        self.seed = seed
        self.stage = stage
        self.camera = camera
        self.renderScale = renderScale
        self.metalFX = metalFX
        self.frames = frames
    }

    /// Creates a log whose metadata mirrors a capture configuration.
    ///
    /// - Parameters:
    ///   - config: The run configuration (stage, camera, seed and render scale are copied).
    ///   - resolvedRenderPath: The render path actually used (`"rt"` or `"fallback"`), since
    ///     `config.renderPath` may be `.auto`.
    ///   - device: Device model identifier.
    ///   - os: OS name and version.
    ///   - metalFX: Whether MetalFX was active.
    ///   - frames: Frame records (defaults to empty).
    public init(
        config: CaptureConfig,
        resolvedRenderPath: String,
        device: String,
        os: String,
        metalFX: Bool,
        frames: [FrameLogEntry] = []
    ) {
        self.init(
            device: device,
            os: os,
            renderPath: resolvedRenderPath,
            seed: config.seed,
            stage: config.stage.rawValue,
            camera: config.camera.rawValue,
            renderScale: config.renderScale,
            metalFX: metalFX,
            frames: frames
        )
    }

    // MARK: Summary

    /// Headline statistics derived from `frames`.
    public struct Summary: Codable, Sendable, Equatable {
        /// `framesTotal / Σ frameMs` in frames per second; 0 when the log is empty or has no elapsed time.
        public var averageFps: Double
        /// Median frame interval (nearest-rank percentile of the sorted `frameMs`).
        public var p50FrameMs: Double
        /// 99th-percentile frame interval (nearest-rank).
        public var p99FrameMs: Double
        /// Longest frame interval.
        public var maxFrameMs: Double
        /// Number of frames whose interval exceeds `FrameLog.spikeThresholdMs`.
        public var spikesOver20ms: Int
        /// Number of frames in the log.
        public var framesTotal: Int
        /// Histogram of `thermal` names to frame counts.
        public var thermalStates: [String: Int]

        /// Creates a summary.
        ///
        /// - Parameters:
        ///   - averageFps: Frames per second over the whole log.
        ///   - p50FrameMs: Median frame interval in milliseconds.
        ///   - p99FrameMs: 99th-percentile frame interval in milliseconds.
        ///   - maxFrameMs: Longest frame interval in milliseconds.
        ///   - spikesOver20ms: Count of frames over the spike threshold.
        ///   - framesTotal: Number of frames.
        ///   - thermalStates: Thermal-state histogram.
        public init(
            averageFps: Double,
            p50FrameMs: Double,
            p99FrameMs: Double,
            maxFrameMs: Double,
            spikesOver20ms: Int,
            framesTotal: Int,
            thermalStates: [String: Int]
        ) {
            self.averageFps = averageFps
            self.p50FrameMs = p50FrameMs
            self.p99FrameMs = p99FrameMs
            self.maxFrameMs = maxFrameMs
            self.spikesOver20ms = spikesOver20ms
            self.framesTotal = framesTotal
            self.thermalStates = thermalStates
        }
    }

    /// Computes the summary statistics of `frames`.
    ///
    /// Average fps is `frames.count / (Σ frameMs · 1e-3)`, guarded to 0 when the total time is
    /// not positive. Percentiles use the nearest-rank method on the sorted frame intervals, so
    /// they are always actual samples from the log. An empty log yields all-zero statistics.
    public func summary() -> Summary {
        let intervals = frames.map(\.frameMs).sorted()
        let totalSeconds = intervals.reduce(0, +) * 1e-3
        let averageFps = totalSeconds > 0 ? Double(intervals.count) / totalSeconds : 0
        var thermalStates: [String: Int] = [:]
        for frame in frames {
            thermalStates[frame.thermal, default: 0] += 1
        }
        return Summary(
            averageFps: averageFps,
            p50FrameMs: FrameLog.nearestRank(percentile: 50, inSorted: intervals),
            p99FrameMs: FrameLog.nearestRank(percentile: 99, inSorted: intervals),
            maxFrameMs: intervals.last ?? 0,
            spikesOver20ms: intervals.filter { $0 > FrameLog.spikeThresholdMs }.count,
            framesTotal: frames.count,
            thermalStates: thermalStates
        )
    }

    /// Nearest-rank percentile: the element at rank `⌈p/100 · n⌉` (1-based, clamped to `1…n`)
    /// of an ascending-sorted sample; 0 for an empty sample.
    ///
    /// - Parameters:
    ///   - percentile: Percentile in 0…100.
    ///   - sortedValues: Samples sorted ascending.
    public static func nearestRank(percentile: Double, inSorted sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let rank = Int((percentile / 100 * Double(sortedValues.count)).rounded(.up))
        let index = min(max(rank, 1), sortedValues.count) - 1
        return sortedValues[index]
    }

    // MARK: JSON

    /// Encodes the log as pretty-printed JSON with sorted keys and an embedded `summary` object.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case device, os, renderPath, seed, stage, camera, renderScale, metalFX, frames, summary
    }

    /// Decodes the metadata and frames; a `summary` key, if present, is ignored.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.decode(String.self, forKey: .device)
        os = try container.decode(String.self, forKey: .os)
        renderPath = try container.decode(String.self, forKey: .renderPath)
        seed = try container.decode(UInt64.self, forKey: .seed)
        stage = try container.decode(Int.self, forKey: .stage)
        camera = try container.decode(String.self, forKey: .camera)
        renderScale = try container.decode(Double.self, forKey: .renderScale)
        metalFX = try container.decode(Bool.self, forKey: .metalFX)
        frames = try container.decode([FrameLogEntry].self, forKey: .frames)
    }

    /// Encodes the metadata, the frames and the derived `summary`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(device, forKey: .device)
        try container.encode(os, forKey: .os)
        try container.encode(renderPath, forKey: .renderPath)
        try container.encode(seed, forKey: .seed)
        try container.encode(stage, forKey: .stage)
        try container.encode(camera, forKey: .camera)
        try container.encode(renderScale, forKey: .renderScale)
        try container.encode(metalFX, forKey: .metalFX)
        try container.encode(frames, forKey: .frames)
        try container.encode(summary(), forKey: .summary)
    }
}
