import Foundation

// MARK: - CaptureConfig

/// Configuration of one capture-harness run (ARCHITECTURE §7), parsed from launch arguments.
///
/// The harness is driven by UserDefaults-style launch arguments (`-key value`); the critic
/// scripts and developers both use it, so parsing is deliberately forgiving: keys may appear
/// in any order, `-key=value` is accepted, enum values are case-insensitive, unknown keys
/// are ignored and an invalid value falls back to that key's default instead of failing.
/// `parse(arguments:)` therefore never throws and always yields a usable configuration.
///
/// The same configuration is echoed into `manifest.json` and drives the deterministic
/// file naming used by `Tools/capture/critic_capture.sh`.
public struct CaptureConfig: Codable, Sendable, Equatable {
    /// Ritual stage to capture (`-stage 1…8`). Default `.oath`.
    public var stage: RitualStage
    /// Camera preset (`-camera`). Default `.threequarter`.
    public var camera: CameraPreset
    /// Render path request (`-renderPath`). Default `.auto` (resolved by device capability).
    public var renderPath: RenderPathChoice
    /// Simulation and render seed (`-seed`, decimal or `0x` hex). Default 1.
    public var seed: UInt64
    /// What the harness records (`-capture`). Default `.none` (interactive run).
    public var mode: CaptureMode
    /// Length of a `clip` capture in seconds (`-clipSeconds`). Default 5.
    public var clipSeconds: Double
    /// Length of a `perf` run in seconds (`-perfSeconds`). Default 300.
    public var perfSeconds: Double
    /// Name of the output folder under `Documents/Captures/` (`-runName`). Default `"run"`.
    public var runName: String
    /// Internal render scale relative to the native drawable (`-renderScale`). Default 0.67.
    public var renderScale: Double
    /// Whether the autopilot plays the ritual (`-autopilot 1|0`).
    /// Defaults to `true` whenever `mode != .none`, otherwise `false`.
    public var autopilot: Bool
    /// Number of warm-up frames rendered before the captured frame (`-warmup`). Default 16.
    public var warmupFrames: Int
    /// Whether spoken narration is enabled (`-narration 0|1`). Default `false`.
    public var narration: Bool

    // MARK: Defaults

    /// Default stage.
    public static let defaultStage: RitualStage = .oath
    /// Default camera preset.
    public static let defaultCamera: CameraPreset = .threequarter
    /// Default render path choice.
    public static let defaultRenderPath: RenderPathChoice = .auto
    /// Default seed.
    public static let defaultSeed: UInt64 = 1
    /// Default capture mode.
    public static let defaultMode: CaptureMode = .none
    /// Default clip length in seconds.
    public static let defaultClipSeconds = 5.0
    /// Default perf-run length in seconds.
    public static let defaultPerfSeconds = 300.0
    /// Default run name.
    public static let defaultRunName = "run"
    /// Default render scale.
    public static let defaultRenderScale = 0.67
    /// Default number of warm-up frames.
    public static let defaultWarmupFrames = 16
    /// Default narration setting.
    public static let defaultNarration = false

    /// Creates a configuration, using the documented default for every omitted value.
    ///
    /// - Parameters:
    ///   - stage: Stage to capture.
    ///   - camera: Camera preset.
    ///   - renderPath: Render path request.
    ///   - seed: Simulation/render seed.
    ///   - mode: Capture mode.
    ///   - clipSeconds: Clip length in seconds.
    ///   - perfSeconds: Perf-run length in seconds.
    ///   - runName: Output folder name.
    ///   - renderScale: Internal render scale.
    ///   - autopilot: Autopilot switch; `nil` resolves to `mode != .none`.
    ///   - warmupFrames: Warm-up frames before the captured frame.
    ///   - narration: Narration switch.
    public init(
        stage: RitualStage = CaptureConfig.defaultStage,
        camera: CameraPreset = CaptureConfig.defaultCamera,
        renderPath: RenderPathChoice = CaptureConfig.defaultRenderPath,
        seed: UInt64 = CaptureConfig.defaultSeed,
        mode: CaptureMode = CaptureConfig.defaultMode,
        clipSeconds: Double = CaptureConfig.defaultClipSeconds,
        perfSeconds: Double = CaptureConfig.defaultPerfSeconds,
        runName: String = CaptureConfig.defaultRunName,
        renderScale: Double = CaptureConfig.defaultRenderScale,
        autopilot: Bool? = nil,
        warmupFrames: Int = CaptureConfig.defaultWarmupFrames,
        narration: Bool = CaptureConfig.defaultNarration
    ) {
        self.stage = stage
        self.camera = camera
        self.renderPath = renderPath
        self.seed = seed
        self.mode = mode
        self.clipSeconds = clipSeconds
        self.perfSeconds = perfSeconds
        self.runName = runName
        self.renderScale = renderScale
        self.autopilot = autopilot ?? (mode != .none)
        self.warmupFrames = warmupFrames
        self.narration = narration
    }

    // MARK: Launch argument keys

    /// The launch-argument keys understood by `parse(arguments:)` (ARCHITECTURE §7).
    ///
    /// Raw values are the key names as written on the command line (without the dash);
    /// matching is case-insensitive. `capture` also answers to `mode`, and `warmup` to
    /// `warmupFrames`, so the struct's property names work as keys too.
    public enum ArgumentKey: String, CaseIterable, Sendable {
        case stage, camera, renderPath, seed, capture, clipSeconds, perfSeconds, runName,
             renderScale, autopilot, warmup, narration

        /// The key as it appears on the command line, e.g. `"-renderPath"`.
        public var flag: String {
            "-" + rawValue
        }

        /// Resolves a key name (any case, aliases allowed) to a known key.
        ///
        /// - Parameter argumentName: The key text without leading dashes.
        public init?(argumentName: String) {
            let lowered = argumentName.lowercased()
            switch lowered {
            case "mode":
                self = .capture
            case "warmupframes":
                self = .warmup
            default:
                guard let match = ArgumentKey.allCases.first(where: { $0.rawValue.lowercased() == lowered }) else {
                    return nil
                }
                self = match
            }
        }
    }

    // MARK: Parsing

    /// Parses UserDefaults-style launch arguments such as `-stage 7 -camera low -capture stills`.
    ///
    /// Accepted forms: `-key value`, `-key=value` and `--key value`, anywhere in the array
    /// (the executable path and any other stray tokens are skipped). Keys are matched
    /// case-insensitively; unknown keys are ignored together with their value. When a key is
    /// repeated the last occurrence wins. A key with a missing or invalid value keeps its
    /// default; a key immediately followed by another key (`-autopilot -stage 3`) counts as
    /// missing rather than swallowing the next key.
    ///
    /// Value rules:
    /// - `stage`: integer 1…8, or a stage id such as `sigilSpin` (case-insensitive).
    /// - `camera`, `renderPath`, `capture`: enum raw values, case-insensitive.
    /// - `seed`: unsigned 64-bit decimal, or hexadecimal with a `0x` prefix.
    /// - `clipSeconds`, `perfSeconds`: finite, non-negative doubles.
    /// - `renderScale`: finite, strictly positive double.
    /// - `warmup`: integer ≥ 1 (the last warm-up frame is the captured one).
    /// - `autopilot`, `narration`: `1|0`, also `true|false`, `yes|no`, `on|off`.
    /// - `runName`: a single non-empty path component (no `/`, `\` or `.`/`..`).
    ///
    /// `autopilot` is resolved after every other key so that its default (`mode != .none`)
    /// sees the parsed mode regardless of argument order.
    ///
    /// - Parameter arguments: Typically `CommandLine.arguments`.
    /// - Returns: The parsed configuration; never fails.
    public static func parse(arguments: [String]) -> CaptureConfig {
        let raw = rawArgumentValues(arguments)
        var config = CaptureConfig()
        if let text = raw[.stage], let stage = parseStage(text) {
            config.stage = stage
        }
        if let text = raw[.camera], let camera = parseCase(CameraPreset.self, text) {
            config.camera = camera
        }
        if let text = raw[.renderPath], let renderPath = parseCase(RenderPathChoice.self, text) {
            config.renderPath = renderPath
        }
        if let text = raw[.seed], let seed = parseSeed(text) {
            config.seed = seed
        }
        if let text = raw[.capture], let mode = parseCase(CaptureMode.self, text) {
            config.mode = mode
        }
        if let text = raw[.clipSeconds], let seconds = parseDouble(text, minimum: 0, exclusive: false) {
            config.clipSeconds = seconds
        }
        if let text = raw[.perfSeconds], let seconds = parseDouble(text, minimum: 0, exclusive: false) {
            config.perfSeconds = seconds
        }
        if let text = raw[.runName], let runName = parseRunName(text) {
            config.runName = runName
        }
        if let text = raw[.renderScale], let scale = parseDouble(text, minimum: 0, exclusive: true) {
            config.renderScale = scale
        }
        if let text = raw[.warmup], let frames = parseInt(text), frames >= 1 {
            config.warmupFrames = frames
        }
        if let text = raw[.narration], let narration = parseBool(text) {
            config.narration = narration
        }
        let explicitAutopilot = raw[.autopilot].flatMap(parseBool)
        config.autopilot = explicitAutopilot ?? (config.mode != .none)
        return config
    }

    /// The launch arguments that reproduce this configuration through `parse(arguments:)`.
    ///
    /// Every key is emitted explicitly (including `-autopilot`), so the round trip is exact
    /// even when `autopilot` disagrees with its mode-derived default.
    public var launchArguments: [String] {
        [
            ArgumentKey.stage.flag, String(stage.rawValue),
            ArgumentKey.camera.flag, camera.rawValue,
            ArgumentKey.renderPath.flag, renderPath.rawValue,
            ArgumentKey.seed.flag, String(seed),
            ArgumentKey.capture.flag, mode.rawValue,
            ArgumentKey.clipSeconds.flag, String(clipSeconds),
            ArgumentKey.perfSeconds.flag, String(perfSeconds),
            ArgumentKey.runName.flag, runName,
            ArgumentKey.renderScale.flag, String(renderScale),
            ArgumentKey.autopilot.flag, autopilot ? "1" : "0",
            ArgumentKey.warmup.flag, String(warmupFrames),
            ArgumentKey.narration.flag, narration ? "1" : "0",
        ]
    }

    // MARK: Derived values

    /// `true` when the harness writes files, i.e. `mode != .none`.
    public var isCaptureRun: Bool {
        mode != .none
    }

    /// Folder for this run relative to the app's Documents container: `Captures/<runName>`.
    public var documentsRelativeDirectory: String {
        "Captures/\(runName)"
    }

    /// File name of the still for this stage and camera: `still_s<stage>_<camera>_<path>.png`.
    ///
    /// - Parameter path: The render path actually used (`"rt"` or `"fallback"`); passed in
    ///   because `.auto` is only resolved on the device.
    public func stillFileName(path: String) -> String {
        "still_s\(stage.rawValue)_\(camera.rawValue)_\(path).png"
    }

    /// Directory name of the clip frame sequence: `clip_s<stage>_<camera>_<path>`.
    ///
    /// - Parameter path: The render path actually used (`"rt"` or `"fallback"`).
    public func clipDirectoryName(path: String) -> String {
        "clip_s\(stage.rawValue)_\(camera.rawValue)_\(path)"
    }

    // MARK: - Tokenising

    /// Collects the raw text value of every recognised key; later occurrences override earlier ones.
    private static func rawArgumentValues(_ arguments: [String]) -> [ArgumentKey: String] {
        var values: [ArgumentKey: String] = [:]
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            guard let keyText = keyText(of: token) else { continue }
            var name = keyText
            var value: String?
            if let equals = keyText.firstIndex(of: "=") {
                name = String(keyText[..<equals])
                value = String(keyText[keyText.index(after: equals)...])
            } else if index < arguments.count, self.keyText(of: arguments[index]) == nil {
                value = arguments[index]
                index += 1
            }
            guard let key = ArgumentKey(argumentName: name), let value else { continue }
            values[key] = value
        }
        return values
    }

    /// The key text of a token shaped like `-name`, `--name` or `-name=value`, or `nil` when the
    /// token is not a key (values, negative numbers and stray words are not keys).
    private static func keyText(of token: String) -> String? {
        let dashes = token.prefix { $0 == "-" }.count
        guard dashes == 1 || dashes == 2 else { return nil }
        let body = token.dropFirst(dashes)
        guard let first = body.first, first.isLetter else { return nil }
        return String(body)
    }

    // MARK: - Value parsers

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A stage number 1…8 or a stage id (`oath`, `sigilSpin`, …), case-insensitive.
    private static func parseStage(_ text: String) -> RitualStage? {
        let value = trimmed(text)
        if let number = Int(value) {
            return RitualStage(rawValue: number)
        }
        let lowered = value.lowercased()
        return RitualStage.allCases.first { $0.id.lowercased() == lowered }
    }

    /// Case-insensitive match against the raw values of a string enum.
    private static func parseCase<Value>(_ type: Value.Type, _ text: String) -> Value?
    where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
        let lowered = trimmed(text).lowercased()
        return Value.allCases.first { $0.rawValue.lowercased() == lowered }
    }

    /// Unsigned 64-bit integer, decimal or `0x`-prefixed hexadecimal.
    private static func parseSeed(_ text: String) -> UInt64? {
        let value = trimmed(text)
        let lowered = value.lowercased()
        if lowered.hasPrefix("0x") {
            return UInt64(lowered.dropFirst(2), radix: 16)
        }
        return UInt64(value)
    }

    /// Finite double bounded below by `minimum` (inclusive unless `exclusive`).
    private static func parseDouble(_ text: String, minimum: Double, exclusive: Bool) -> Double? {
        guard let value = Double(trimmed(text)), value.isFinite else { return nil }
        if exclusive ? value <= minimum : value < minimum {
            return nil
        }
        return value
    }

    private static func parseInt(_ text: String) -> Int? {
        Int(trimmed(text))
    }

    /// `1|0`, `true|false`, `yes|no`, `on|off` (case-insensitive).
    private static func parseBool(_ text: String) -> Bool? {
        switch trimmed(text).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    /// A single, non-empty path component; anything that could escape `Captures/` is rejected.
    private static func parseRunName(_ text: String) -> String? {
        let value = trimmed(text)
        guard !value.isEmpty, value != ".", value != "..",
              value.unicodeScalars.allSatisfy({ $0 != "/" && $0 != "\\" && $0 != "\0" }) else {
            return nil
        }
        return value
    }
}
