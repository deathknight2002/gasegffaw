# Tools/capture — host-side capture scripts

Host scripts that drive the on-device capture harness
(`BornlessRitual/Capture/CaptureHarness.swift`, ARCHITECTURE §7) and turn its output into
the critic evidence listed in `docs/CRITIC.md`. Everything here runs on a macOS host with
Xcode 15+ (`xcrun devicectl`) and a paired, unlocked iPhone; `assemble.sh` also runs on Linux.

| Script | Purpose |
|---|---|
| `critic_capture.sh <device-id> [label]` | 48 stills + 4 clips + 2 perf runs on the device, then pulls `Documents/Captures/critic` into `./captures/<label>/critic` |
| `assemble.sh [captures-dir]` | encodes every `clip_*` frame sequence to `clip.mp4` with ffmpeg and summarises every `*frametime*.json` into `summary.md` |

## The on-device harness in one paragraph

The app is launched with UserDefaults-style arguments (`-stage 1..8 -camera <preset>
-renderPath rt|fallback|auto -seed <uint64> -capture stills|clip|perf|none -clipSeconds 5
-perfSeconds 300 -runName <name> -renderScale 0.67 -autopilot 1|0 -warmup 16 -narration 0|1`,
parsed by RitualCore `CaptureConfig.parse`). For a capture run the harness applies the
autopilot input script for the requested stage at tick 0, puts the camera on the preset,
seeks to `Autopilot.showcaseTick(for:seed:)` (which resets temporal history and renders the
16 warm-up frames with `frameIndex = tick·16 + k`), then:

* `stills` — writes the 16th warm-up frame as `still_s<stage>_<camera>_<path>.png` at native
  drawable resolution;
* `clip` — switches ritual time to a fixed 1/60 s per frame and writes
  `clip_s<stage>_<camera>_<path>/frame_%05d.png` for `clipSeconds × 60` frames (frame 0 is
  the warm-up frame, then live frames). At most 8 frames may be between readback and
  finished PNG; the render loop waits otherwise, so the sequence is deterministic no
  matter how slow the flash storage is;
* `perf` — runs the full ritual on autopilot for `perfSeconds` of wall time, logging every
  frame.

Every run writes `frametime.json` (RitualCore `FrameLog`: device, OS, path, seed, stage,
camera, scale, MetalFX, per-frame cpu/gpu/frame ms and thermal state, plus an embedded
`summary`) and `manifest.json` (config, launch arguments, resolved path and the reason,
device capability report, resolution, the Appendix A chart report, the daemon's name in
Hebrew and Latin, sigil cells `(6,4)→(4,2)→(1,6)→(6,2)→(6,4)`, attributes, showcase and
captured tick, files written, frame summary, status). Because every critic launch shares
the run name `critic`, the harness also writes per-capture copies
`<stem>.frametime.json` / `<stem>.manifest.json` (`stem` = `still_s7_low_rt`,
`clip_s8_front_fallback`, `perf_rt`, …) so nothing is overwritten. On completion the app
prints `CAPTURE_DONE <dir>` to stdout (or `CAPTURE_FAILED <dir> — <reason>`) and exits one
second later. Files live in the app's Documents container
(`Documents/Captures/<runName>/`), which is also visible in Finder thanks to
`UIFileSharingEnabled`.

## critic_capture.sh

```sh
xcrun devicectl list devices                       # find the identifier or name
Tools/capture/critic_capture.sh 00008130-0011223344556677 round3
Tools/capture/assemble.sh captures/round3/critic
```

The script

1. refuses anything that is a Simulator (`xcrun simctl list devices` match, or a
   "Simulator"/"booted" spelling) — Metal ray tracing does not run in the Simulator — and
   requires the device to appear in `xcrun devicectl list devices`;
2. loops stages `1 5 7 8` × cameras `front threequarter profile overhead low closeup` ×
   paths `rt fallback` with `-capture stills` (48 launches);
3. runs the two clips (stage 7 three-quarter, stage 8 front) × 2 paths with
   `-capture clip -clipSeconds 5`;
4. runs `-capture perf -perfSeconds 300` once per path;
5. pulls the run folder with
   `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
   --domain-identifier com.bornless.ritual --source Documents/Captures/critic
   --destination ./captures/<label>`.

Each launch waits for the app to exit (the harness calls `exit` after `CAPTURE_DONE`); a
watchdog (`STILL_TIMEOUT` 240 s, `CLIP_TIMEOUT` 900 s, `PERF_TIMEOUT` perfSeconds + 300 s)
kills a stuck console session and the next launch's `--terminate-existing` kills the app.
Failures are collected and listed at the end; the exit status is 1 if any launch failed.
`host_log.txt` and one `launch_<tag>.log` per launch (the app's console output) land in
`./captures/<label>/`.

### devicectl launch form

```
xcrun devicectl device process launch --device <id> --terminate-existing --console \
    com.bornless.ritual -- -stage 7 -camera low -renderPath rt -seed 1 -capture stills -runName critic
```

`devicectl` is built on swift-argument-parser: positional arguments after the bundle
identifier become the app's `argv`, and the `--` terminator guarantees that the app's
`-key value` pairs are never interpreted as devicectl options. Verify with
`xcrun devicectl device process launch --help` on your Xcode; if the terminator is
rejected, run with `DEVICECTL_ARG_SEPARATOR=""` (arguments then follow the bundle id
directly). `--console` streams the app's stdout — which is how the script sees
`CAPTURE_DONE` — and returns when the process exits. `-narration 0 -autopilot 1 -seed
$SEED -renderScale $RENDER_SCALE -runName $RUN_NAME` are appended to every launch.

Environment overrides: `BUNDLE_ID`, `RUN_NAME`, `SEED`, `RENDER_SCALE`, `CLIP_SECONDS`,
`PERF_SECONDS`, `STAGES`, `CAMERAS`, `PATHS`, `SKIP_STILLS`, `SKIP_CLIPS`, `SKIP_PERF`,
`SKIP_PULL`, `OUT_DIR`, `STILL_TIMEOUT`, `CLIP_TIMEOUT`, `PERF_TIMEOUT`,
`DEVICECTL_ARG_SEPARATOR`, `DRY_RUN=1` (prints every command without touching a device).

Total time on an iPhone 15 Pro is roughly 48 × ~8 s + 4 × ~40 s + 2 × 300 s ≈ 20 minutes,
dominated by the perf runs.

## assemble.sh

```sh
Tools/capture/assemble.sh captures/round3/critic      # or no argument: newest ./captures/*
FORCE=1 CRF=12 Tools/capture/assemble.sh captures/round3/critic
SKIP_MP4=1 Tools/capture/assemble.sh captures/round3/critic   # summary only
```

* Every directory named `clip_*` that contains `frame_00000.png` becomes `clip.mp4`
  (`ffmpeg -framerate 60 -i frame_%05d.png -c:v libx264 -pix_fmt yuv420p -crf 14`, with a
  one-pixel pad because iPhone native widths such as 1179 are odd and yuv420p needs even
  dimensions). Existing MP4s are skipped unless `FORCE=1`.
* Every `*frametime*.json` is summarised with python3 into `summary.md` in the given
  directory (average fps, p50 / p99 / max frame ms with nearest-rank percentiles — the same
  rule as `FrameLog.summary()` — spikes over 20 ms, mean GPU / CPU ms and thermal-state
  counts). The embedded `summary` object is preferred when present; the canonical
  `frametime.json` is left out of the table whenever a per-capture copy sits beside it.

## Output layout

```
captures/<label>/
  host_log.txt, launch_<tag>.log …
  critic/
    still_s1_front_rt.png … still_s8_closeup_fallback.png        (48)
    still_s1_front_rt.frametime.json / .manifest.json …          (per-capture copies)
    clip_s7_threequarter_rt/frame_00000.png … frame_00299.png, clip.mp4
    clip_s8_front_rt/ …, clip_s7_threequarter_fallback/ …, clip_s8_front_fallback/ …
    perf_rt.frametime.json, perf_rt.manifest.json, perf_fallback.…
    frametime.json, manifest.json                                (last run, contract names)
    summary.md                                                   (assemble.sh)
```

## Troubleshooting

* "device … is not listed": pair the phone with Xcode (Window ▸ Devices and Simulators),
  unlock it, trust the computer, enable Developer Mode (Settings ▸ Privacy & Security).
* No `CAPTURE_DONE` in `launch_<tag>.log`: open the log — a signing or install problem
  shows up as a devicectl error; an app-side failure prints `CAPTURE_FAILED <dir> — <why>`.
  The app must be installed first (`xcodebuild … -destination 'id=<udid>' install` or a
  Run from Xcode).
* RT stills identical to fallback ones: check `manifest.json` → `resolvedRenderPath` and
  `renderPathReason`; `-renderPath rt` falls back on devices without ray-tracing support.
* Frames written slowly during clips are expected: the render loop is throttled by the
  PNG queue (8 in flight) so that the frame sequence stays deterministic.
