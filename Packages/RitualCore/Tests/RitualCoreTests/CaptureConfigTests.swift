import XCTest
@testable import RitualCore

/// Launch-argument parsing, capture file naming and `FrameLog` summary/JSON behaviour
/// (CORE_API "Capture", ARCHITECTURE §7).
final class CaptureConfigTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultsMatchContract() {
        let config = CaptureConfig()
        XCTAssertEqual(config.stage, .oath)
        XCTAssertEqual(config.camera, .threequarter)
        XCTAssertEqual(config.renderPath, .auto)
        XCTAssertEqual(config.seed, 1)
        XCTAssertEqual(config.mode, CaptureMode.none)
        XCTAssertEqual(config.clipSeconds, 5)
        XCTAssertEqual(config.perfSeconds, 300)
        XCTAssertEqual(config.runName, "run")
        XCTAssertEqual(config.renderScale, 0.67)
        XCTAssertFalse(config.autopilot, "autopilot defaults to false when mode is none")
        XCTAssertEqual(config.warmupFrames, 16)
        XCTAssertFalse(config.narration)
        XCTAssertFalse(config.isCaptureRun)
        XCTAssertEqual(config.documentsRelativeDirectory, "Captures/run")
        XCTAssertEqual(CaptureConfig.parse(arguments: []), config)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["/Applications/BornlessRitual.app/BornlessRitual"]), config)
    }

    func testMemberwiseInitDerivesAutopilotFromMode() {
        XCTAssertTrue(CaptureConfig(mode: .stills).autopilot)
        XCTAssertTrue(CaptureConfig(mode: .perf).autopilot)
        XCTAssertFalse(CaptureConfig(mode: .none).autopilot)
        XCTAssertFalse(CaptureConfig(mode: .clip, autopilot: false).autopilot)
        XCTAssertTrue(CaptureConfig(mode: .none, autopilot: true).autopilot)
    }

    // MARK: - Parsing

    func testParsesEveryKey() {
        let arguments = [
            "-stage", "7", "-camera", "low", "-renderPath", "rt", "-seed", "12345",
            "-capture", "stills", "-clipSeconds", "8", "-perfSeconds", "30.5",
            "-runName", "critic_r3", "-renderScale", "0.75", "-autopilot", "0",
            "-warmup", "24", "-narration", "1",
        ]
        let config = CaptureConfig.parse(arguments: arguments)
        XCTAssertEqual(config.stage, .sigilSpin)
        XCTAssertEqual(config.camera, .low)
        XCTAssertEqual(config.renderPath, .rt)
        XCTAssertEqual(config.seed, 12345)
        XCTAssertEqual(config.mode, .stills)
        XCTAssertEqual(config.clipSeconds, 8)
        XCTAssertEqual(config.perfSeconds, 30.5)
        XCTAssertEqual(config.runName, "critic_r3")
        XCTAssertEqual(config.renderScale, 0.75)
        XCTAssertFalse(config.autopilot, "explicit -autopilot 0 overrides the mode-derived default")
        XCTAssertEqual(config.warmupFrames, 24)
        XCTAssertTrue(config.narration)
        XCTAssertTrue(config.isCaptureRun)
    }

    func testParsingRoundTripsThroughLaunchArguments() {
        let samples: [CaptureConfig] = [
            CaptureConfig(),
            CaptureConfig(stage: .sigilSpin, camera: .low, renderPath: .rt, seed: 0xDEAD_BEEF, mode: .stills,
                          runName: "critic r3", renderScale: 0.6, warmupFrames: 32, narration: true),
            CaptureConfig(stage: .manifestation, camera: .closeup, renderPath: .fallback, seed: UInt64.max,
                          mode: .clip, clipSeconds: 12.5, autopilot: false),
            CaptureConfig(stage: .earth, camera: .overhead, mode: .perf, perfSeconds: 42),
            CaptureConfig(mode: .none, autopilot: true),
        ]
        for sample in samples {
            let parsed = CaptureConfig.parse(arguments: sample.launchArguments)
            XCTAssertEqual(parsed, sample, "round trip of \(sample.launchArguments)")
            XCTAssertEqual(parsed.launchArguments, sample.launchArguments)
        }
    }

    func testLaunchArgumentsUseContractKeys() {
        let arguments = CaptureConfig().launchArguments
        let keys = stride(from: 0, to: arguments.count, by: 2).map { arguments[$0] }
        XCTAssertEqual(keys, ["-stage", "-camera", "-renderPath", "-seed", "-capture", "-clipSeconds",
                              "-perfSeconds", "-runName", "-renderScale", "-autopilot", "-warmup", "-narration"])
        XCTAssertEqual(arguments.count, keys.count * 2)
    }

    func testHexAndDecimalSeeds() {
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed", "0xDEADBEEF"]).seed, 0xDEAD_BEEF)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed", "0XFF"]).seed, 255)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed", "0xdeadbeefcafebabe"]).seed, 0xDEAD_BEEF_CAFE_BABE)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed", "18446744073709551615"]).seed, UInt64.max)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed", "0"]).seed, 0)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed", "42"]).seed, 42)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed=0x10"]).seed, 16)
        // Invalid seeds fall back to the default of 1.
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed", "0xZZ"]).seed, 1)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed", "-5"]).seed, 1)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed", "18446744073709551616"]).seed, 1)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed", "1.5"]).seed, 1)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-seed", ""]).seed, 1)
    }

    func testKeyEqualsValueAndDoubleDashForms() {
        let config = CaptureConfig.parse(arguments: ["-stage=7", "--camera=profile", "--renderPath", "fallback", "-capture=clip"])
        XCTAssertEqual(config.stage, .sigilSpin)
        XCTAssertEqual(config.camera, .profile)
        XCTAssertEqual(config.renderPath, .fallback)
        XCTAssertEqual(config.mode, .clip)
        XCTAssertTrue(config.autopilot)
    }

    func testEnumValuesAndKeysAreCaseInsensitive() {
        let config = CaptureConfig.parse(arguments: ["-Camera", "LOW", "-renderpath", "RT", "-CAPTURE", "Clip", "-RunName", "Round3"])
        XCTAssertEqual(config.camera, .low)
        XCTAssertEqual(config.renderPath, .rt)
        XCTAssertEqual(config.mode, .clip)
        XCTAssertEqual(config.runName, "Round3", "run name keeps its case")
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-camera", "ThreeQuarter"]).camera, .threequarter)
    }

    func testStageAcceptsNumbersAndIdentifiers() {
        for stage in RitualStage.allCases {
            XCTAssertEqual(CaptureConfig.parse(arguments: ["-stage", String(stage.rawValue)]).stage, stage)
            XCTAssertEqual(CaptureConfig.parse(arguments: ["-stage", stage.id]).stage, stage)
            XCTAssertEqual(CaptureConfig.parse(arguments: ["-stage", stage.id.uppercased()]).stage, stage)
        }
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-stage", "0"]).stage, .oath)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-stage", "9"]).stage, .oath)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-stage", "-3"]).stage, .oath)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-stage", "3.0"]).stage, .oath)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-stage", "banishing"]).stage, .oath)
    }

    func testInvalidValuesFallBackToDefaults() {
        let config = CaptureConfig.parse(arguments: [
            "-stage", "9", "-camera", "sideways", "-renderPath", "metal", "-seed", "abc",
            "-capture", "video", "-clipSeconds", "-2", "-perfSeconds", "nan",
            "-runName", "", "-renderScale", "0", "-autopilot", "maybe", "-warmup", "1.5", "-narration", "2",
        ])
        XCTAssertEqual(config, CaptureConfig())
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-renderScale", "-1"]).renderScale, 0.67)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-renderScale", "inf"]).renderScale, 0.67)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-warmup", "0"]).warmupFrames, 16)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-warmup", "-3"]).warmupFrames, 16)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-clipSeconds", "0"]).clipSeconds, 0, "zero seconds is degenerate but valid")
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-runName", "../escape"]).runName, "run")
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-runName", "a/b"]).runName, "run")
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-runName", ".."]).runName, "run")
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-runName", "   "]).runName, "run")
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-runName", " round 3 "]).runName, "round 3", "surrounding whitespace is trimmed")
    }

    func testUnknownKeysAndStrayTokensAreIgnored() {
        let config = CaptureConfig.parse(arguments: [
            "/private/var/containers/Bundle/Application/BornlessRitual.app/BornlessRitual",
            "-NSDocumentRevisionsDebugMode", "YES", "junk", "-stage", "3", "-foo=bar",
            "-AppleLanguages", "(en)", "-camera", "profile", "--", "-", "trailing",
        ])
        XCTAssertEqual(config.stage, .fire)
        XCTAssertEqual(config.camera, .profile)
        XCTAssertEqual(config.mode, CaptureMode.none)
        XCTAssertEqual(config.seed, 1)
    }

    func testAutopilotDefaultFollowsModeRegardlessOfOrder() {
        XCTAssertTrue(CaptureConfig.parse(arguments: ["-capture", "perf"]).autopilot)
        XCTAssertTrue(CaptureConfig.parse(arguments: ["-capture", "clip"]).autopilot)
        XCTAssertTrue(CaptureConfig.parse(arguments: ["-capture", "stills"]).autopilot)
        XCTAssertFalse(CaptureConfig.parse(arguments: ["-capture", "none"]).autopilot)
        XCTAssertFalse(CaptureConfig.parse(arguments: ["-capture", "stills", "-autopilot", "0"]).autopilot)
        XCTAssertFalse(CaptureConfig.parse(arguments: ["-autopilot", "0", "-capture", "clip"]).autopilot,
                       "an explicit 0 given before the mode still wins")
        XCTAssertTrue(CaptureConfig.parse(arguments: ["-autopilot", "1"]).autopilot)
        XCTAssertTrue(CaptureConfig.parse(arguments: ["-autopilot", "bogus", "-capture", "perf"]).autopilot,
                      "an invalid autopilot value falls back to the mode-derived default")
        XCTAssertFalse(CaptureConfig.parse(arguments: ["-capture", "nonsense"]).autopilot,
                       "an invalid mode is none, so autopilot is off")
    }

    func testBooleanSpellings() {
        for text in ["1", "true", "TRUE", "yes", "on", "On"] {
            XCTAssertTrue(CaptureConfig.parse(arguments: ["-narration", text]).narration, text)
        }
        for text in ["0", "false", "False", "no", "off", "OFF"] {
            XCTAssertFalse(CaptureConfig.parse(arguments: ["-narration", text, "-capture", "perf"]).narration, text)
            XCTAssertFalse(CaptureConfig.parse(arguments: ["-autopilot", text, "-capture", "perf"]).autopilot, text)
        }
    }

    func testKeyWithoutValueDoesNotSwallowTheNextKey() {
        let config = CaptureConfig.parse(arguments: ["-autopilot", "-narration", "1", "-stage", "5", "-stage"])
        XCTAssertFalse(config.autopilot, "bare -autopilot has no value, so the default applies")
        XCTAssertTrue(config.narration)
        XCTAssertEqual(config.stage, .earth, "a trailing valueless -stage leaves the earlier value alone")
    }

    func testLastOccurrenceWins() {
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-stage", "2", "-stage", "4"]).stage, .water)
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-stage", "4", "-stage", "42"]).stage, .oath,
                       "the last occurrence is the one that is validated")
        XCTAssertEqual(CaptureConfig.parse(arguments: ["-camera", "low", "-camera=front"]).camera, .front)
    }

    func testPropertyNameAliases() {
        let config = CaptureConfig.parse(arguments: ["-mode", "stills", "-warmupFrames", "8"])
        XCTAssertEqual(config.mode, .stills)
        XCTAssertEqual(config.warmupFrames, 8)
    }

    func testIsCaptureRunForEveryMode() {
        for mode in CaptureMode.allCases {
            XCTAssertEqual(CaptureConfig(mode: mode).isCaptureRun, mode != .none, "\(mode)")
        }
    }

    // MARK: - File naming

    func testStillAndClipNames() {
        let config = CaptureConfig(stage: .sigilSpin, camera: .low, renderPath: .rt, runName: "critic_r3")
        XCTAssertEqual(config.stillFileName(path: "rt"), "still_s7_low_rt.png")
        XCTAssertEqual(config.clipDirectoryName(path: "rt"), "clip_s7_low_rt")
        XCTAssertEqual(config.stillFileName(path: "fallback"), "still_s7_low_fallback.png")
        XCTAssertEqual(config.documentsRelativeDirectory, "Captures/critic_r3")

        let defaults = CaptureConfig()
        XCTAssertEqual(defaults.stillFileName(path: "fallback"), "still_s1_threequarter_fallback.png")
        XCTAssertEqual(defaults.clipDirectoryName(path: "rt"), "clip_s1_threequarter_rt")

        let last = CaptureConfig(stage: .manifestation, camera: .closeup)
        XCTAssertEqual(last.stillFileName(path: "rt"), "still_s8_closeup_rt.png")
        XCTAssertEqual(last.clipDirectoryName(path: "fallback"), "clip_s8_closeup_fallback")
    }

    func testStillNamesAreUniquePerStageCameraAndPath() {
        var names = Set<String>()
        for stage in RitualStage.allCases {
            for camera in CameraPreset.allCases {
                for path in ["rt", "fallback"] {
                    names.insert(CaptureConfig(stage: stage, camera: camera).stillFileName(path: path))
                }
            }
        }
        XCTAssertEqual(names.count, RitualStage.allCases.count * CameraPreset.allCases.count * 2)
    }

    func testCaptureConfigCodableRoundTrip() throws {
        let config = CaptureConfig(stage: .spirit, camera: .front, renderPath: .rt, seed: 0xCAFE, mode: .clip,
                                   clipSeconds: 3, perfSeconds: 10, runName: "codable", renderScale: 0.8,
                                   autopilot: false, warmupFrames: 4, narration: true)
        let decoded = try JSONDecoder().decode(CaptureConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }

    // MARK: - FrameLog summary

    /// 100 frames with intervals 10.0, 10.1, … 19.9 ms, three of which are replaced by spikes.
    private func syntheticLog() -> FrameLog {
        var log = FrameLog(device: "iPhone16,1", os: "iOS 17.4", renderPath: "rt", seed: 7,
                           stage: 7, camera: "low", renderScale: 0.67, metalFX: true)
        let spikes: [Int: Double] = [10: 33.0, 50: 25.0, 90: 41.0]
        var time = 0.0
        for index in 0..<100 {
            let frameMs = spikes[index] ?? 10.0 + Double(index) * 0.1
            let thermal = index < 80 ? "nominal" : (index < 95 ? "fair" : "serious")
            log.frames.append(FrameLogEntry(index: index, time: time, tick: index * 2, cpuMs: 3.5,
                                            gpuMs: frameMs - 4, frameMs: frameMs, thermal: thermal))
            time += frameMs * 1e-3
        }
        return log
    }

    func testSummaryMathOnSyntheticLog() {
        let log = syntheticLog()
        let summary = log.summary()
        XCTAssertEqual(summary.framesTotal, 100)
        XCTAssertEqual(summary.spikesOver20ms, 3)
        XCTAssertEqual(summary.maxFrameMs, 41)
        // Σ = Σ(10 + 0.1 i) − (11 + 15 + 19) + (33 + 25 + 41) = 1495 − 45 + 99 = 1549 ms.
        let totalMs = log.frames.map(\.frameMs).reduce(0, +)
        XCTAssertEqual(totalMs, 1549, accuracy: 1e-9)
        XCTAssertEqual(summary.averageFps, 100 / 1.549, accuracy: 1e-9)
        XCTAssertEqual(summary.averageFps, Double(log.frames.count) / (totalMs * 1e-3), accuracy: 1e-9)
        // Nearest rank: p50 → rank 50 → sorted[49]; the sorted non-spike values skip 11.0, 15.0 and
        // 19.0, so sorted[48] = 14.9 and sorted[49] = 15.1. p99 → rank 99 → sorted[98] = 33 (second
        // largest), and the largest (41) is only reached by p100.
        XCTAssertEqual(summary.p50FrameMs, 15.1, accuracy: 1e-9)
        XCTAssertEqual(summary.p99FrameMs, 33)
        XCTAssertEqual(summary.thermalStates, ["nominal": 80, "fair": 15, "serious": 5])
    }

    func testSummaryIsGuardedAgainstZeroTime() {
        let empty = FrameLog(device: "d", os: "o", renderPath: "rt", seed: 1, stage: 1, camera: "front",
                             renderScale: 1, metalFX: false)
        let summary = empty.summary()
        XCTAssertEqual(summary, FrameLog.Summary(averageFps: 0, p50FrameMs: 0, p99FrameMs: 0, maxFrameMs: 0,
                                                 spikesOver20ms: 0, framesTotal: 0, thermalStates: [:]))
        var zeroTime = empty
        zeroTime.frames = (0..<3).map { FrameLogEntry(index: $0, time: 0, tick: 0, cpuMs: 0, gpuMs: 0, frameMs: 0, thermal: "nominal") }
        let zeroSummary = zeroTime.summary()
        XCTAssertEqual(zeroSummary.averageFps, 0, "no elapsed time must not divide by zero")
        XCTAssertFalse(zeroSummary.averageFps.isNaN)
        XCTAssertEqual(zeroSummary.framesTotal, 3)
        XCTAssertEqual(zeroSummary.thermalStates, ["nominal": 3])
        XCTAssertNoThrow(try zeroTime.jsonData(), "a zero-time log must still serialise (no NaN/inf)")
        XCTAssertNoThrow(try empty.jsonData())
    }

    func testNearestRankPercentileOnSmallSamples() {
        let sorted = [1.0, 3.0, 5.0]
        XCTAssertEqual(FrameLog.nearestRank(percentile: 50, inSorted: sorted), 3, "rank ⌈1.5⌉ = 2")
        XCTAssertEqual(FrameLog.nearestRank(percentile: 99, inSorted: sorted), 5)
        XCTAssertEqual(FrameLog.nearestRank(percentile: 100, inSorted: sorted), 5)
        XCTAssertEqual(FrameLog.nearestRank(percentile: 0, inSorted: sorted), 1, "rank clamps to 1")
        XCTAssertEqual(FrameLog.nearestRank(percentile: 1, inSorted: sorted), 1)
        XCTAssertEqual(FrameLog.nearestRank(percentile: 50, inSorted: [8.0]), 8)
        XCTAssertEqual(FrameLog.nearestRank(percentile: 50, inSorted: []), 0)
        let hundred = (1...100).map(Double.init)
        XCTAssertEqual(FrameLog.nearestRank(percentile: 50, inSorted: hundred), 50)
        XCTAssertEqual(FrameLog.nearestRank(percentile: 99, inSorted: hundred), 99)
        XCTAssertEqual(FrameLog.nearestRank(percentile: 1, inSorted: hundred), 1)
    }

    func testSpikeCountUsesStrictThreshold() {
        var log = FrameLog(device: "d", os: "o", renderPath: "rt", seed: 1, stage: 1, camera: "front", renderScale: 1, metalFX: false)
        for (index, frameMs) in [20.0, 20.0001, 19.9999, 60.0].enumerated() {
            log.frames.append(FrameLogEntry(index: index, time: 0, tick: 0, cpuMs: 0, gpuMs: 0, frameMs: frameMs, thermal: "fair"))
        }
        XCTAssertEqual(FrameLog.spikeThresholdMs, 20)
        XCTAssertEqual(log.summary().spikesOver20ms, 2, "exactly 20 ms is not a spike")
    }

    func testFrameLogInitFromConfigCopiesMetadata() {
        let config = CaptureConfig(stage: .earth, camera: .overhead, renderPath: .auto, seed: 99, mode: .perf, renderScale: 0.6)
        let log = FrameLog(config: config, resolvedRenderPath: "fallback", device: "iPad14,3", os: "iPadOS 17.5", metalFX: false)
        XCTAssertEqual(log.stage, 5)
        XCTAssertEqual(log.camera, "overhead")
        XCTAssertEqual(log.renderPath, "fallback")
        XCTAssertEqual(log.seed, 99)
        XCTAssertEqual(log.renderScale, 0.6)
        XCTAssertEqual(log.device, "iPad14,3")
        XCTAssertEqual(log.os, "iPadOS 17.5")
        XCTAssertFalse(log.metalFX)
        XCTAssertTrue(log.frames.isEmpty)
    }

    // MARK: - FrameLog JSON

    /// Top-level keys of a pretty-printed JSON object, in document order (lines indented by
    /// exactly `indent` spaces that start with a quoted key).
    private func keys(inPrettyJSON text: String, indent: Int) -> [String] {
        let prefix = String(repeating: " ", count: indent) + "\""
        return text.split(separator: "\n").compactMap { line -> String? in
            let string = String(line)
            guard string.hasPrefix(prefix), !string.hasPrefix(prefix + " ") else { return nil }
            let afterQuote = string.dropFirst(prefix.count)
            guard let closing = afterQuote.firstIndex(of: "\"") else { return nil }
            return String(afterQuote[..<closing])
        }
    }

    func testJSONHasSortedKeysAndSummaryObject() throws {
        let log = syntheticLog()
        let data = try log.jsonData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\n"), "output must be pretty-printed")

        let topLevelKeys = keys(inPrettyJSON: text, indent: 2)
        XCTAssertEqual(topLevelKeys, ["camera", "device", "frames", "metalFX", "os", "renderPath",
                                      "renderScale", "seed", "stage", "summary"])
        XCTAssertEqual(topLevelKeys, topLevelKeys.sorted())

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["device"] as? String, "iPhone16,1")
        XCTAssertEqual(object["os"] as? String, "iOS 17.4")
        XCTAssertEqual(object["renderPath"] as? String, "rt")
        XCTAssertEqual(object["seed"] as? UInt64, 7)
        XCTAssertEqual(object["stage"] as? Int, 7)
        XCTAssertEqual(object["camera"] as? String, "low")
        XCTAssertEqual(object["renderScale"] as? Double, 0.67)
        XCTAssertEqual(object["metalFX"] as? Bool, true)
        let frames = try XCTUnwrap(object["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 100)
        XCTAssertEqual(Set(frames[0].keys), ["index", "time", "tick", "cpuMs", "gpuMs", "frameMs", "thermal"])

        let summary = try XCTUnwrap(object["summary"] as? [String: Any])
        XCTAssertEqual(Set(summary.keys), ["averageFps", "p50FrameMs", "p99FrameMs", "maxFrameMs",
                                           "spikesOver20ms", "framesTotal", "thermalStates"])
        XCTAssertEqual(summary["framesTotal"] as? Int, 100)
        XCTAssertEqual(summary["spikesOver20ms"] as? Int, 3)
        XCTAssertEqual(summary["maxFrameMs"] as? Double, 41)
        XCTAssertEqual(summary["p99FrameMs"] as? Double, 33)
        XCTAssertEqual(try XCTUnwrap(summary["p50FrameMs"] as? Double), 15.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(summary["averageFps"] as? Double), 100 / 1.549, accuracy: 1e-9)
        XCTAssertEqual(summary["thermalStates"] as? [String: Int], ["nominal": 80, "fair": 15, "serious": 5])

        // Nested objects are sorted too: the summary's keys and each frame's keys.
        let summaryKeys = keys(inPrettyJSON: text, indent: 4).filter { !["cpuMs", "frameMs", "gpuMs", "index", "thermal", "tick", "time"].contains($0) }
        XCTAssertEqual(summaryKeys, ["averageFps", "framesTotal", "maxFrameMs", "p50FrameMs", "p99FrameMs", "spikesOver20ms", "thermalStates"])
        let frameKeyRuns = keys(inPrettyJSON: text, indent: 6)
        XCTAssertEqual(Array(frameKeyRuns.prefix(7)), ["cpuMs", "frameMs", "gpuMs", "index", "thermal", "tick", "time"])
    }

    func testJSONDecodingIgnoresSummaryAndRoundTrips() throws {
        let log = syntheticLog()
        let decoded = try JSONDecoder().decode(FrameLog.self, from: log.jsonData())
        XCTAssertEqual(decoded, log)
        XCTAssertEqual(decoded.summary(), log.summary())

        // A stale or malformed summary in the file is ignored; the frames are the truth.
        let tampered = """
        {
          "camera" : "front",
          "device" : "iPhone15,2",
          "frames" : [
            { "cpuMs" : 1, "frameMs" : 16.7, "gpuMs" : 9, "index" : 0, "thermal" : "nominal", "tick" : 0, "time" : 0 }
          ],
          "metalFX" : false,
          "os" : "iOS 17.0",
          "renderPath" : "fallback",
          "renderScale" : 0.67,
          "seed" : 18446744073709551615,
          "stage" : 3,
          "summary" : { "averageFps" : "not a number", "bogus" : true }
        }
        """
        let fromTampered = try JSONDecoder().decode(FrameLog.self, from: Data(tampered.utf8))
        XCTAssertEqual(fromTampered.seed, UInt64.max)
        XCTAssertEqual(fromTampered.stage, 3)
        XCTAssertEqual(fromTampered.frames.count, 1)
        XCTAssertEqual(fromTampered.summary().framesTotal, 1)
        XCTAssertEqual(fromTampered.summary().averageFps, 1 / 0.0167, accuracy: 1e-9)

        let withoutSummary = tampered.replacingOccurrences(
            of: ",\n  \"summary\" : { \"averageFps\" : \"not a number\", \"bogus\" : true }", with: "")
        XCTAssertFalse(withoutSummary.contains("summary"))
        let fromPlain = try JSONDecoder().decode(FrameLog.self, from: Data(withoutSummary.utf8))
        XCTAssertEqual(fromPlain, fromTampered)
    }

    func testJSONIsDeterministic() throws {
        let log = syntheticLog()
        XCTAssertEqual(try log.jsonData(), try log.jsonData())
        XCTAssertEqual(try log.jsonData(), try syntheticLog().jsonData())
    }
}
