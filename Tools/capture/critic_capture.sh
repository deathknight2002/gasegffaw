#!/usr/bin/env bash
# Tools/capture/critic_capture.sh — critic evidence run on a physical iPhone
# (docs/ARCHITECTURE.md §7 "Host side", docs/CRITIC.md "Evidence").
#
# usage: Tools/capture/critic_capture.sh <device-id> [run-label]
#
#   <device-id>   CoreDevice identifier (UDID) or the device name as printed by
#                 `xcrun devicectl list devices`. Simulator destinations are refused:
#                 Metal ray tracing does not run in the Simulator.
#   [run-label]   Name of the local output folder ./captures/<label>
#                 (default: critic-<YYYYmmdd-HHMMSS>).
#
# What it does (each launch is one app process that exits by itself, see
# BornlessRitual/Capture/CaptureHarness.swift):
#   1. 48 stills: stages 1 5 7 8 × cameras front threequarter profile overhead low
#      closeup × render paths rt fallback   (-capture stills)
#   2. 4 clips:  (stage 7, threequarter) and (stage 8, front) × rt fallback
#      (-capture clip -clipSeconds 5)
#   3. 2 perf runs: full autopilot ritual, one per render path
#      (-capture perf -perfSeconds 300)
#   4. pulls Documents/Captures/critic from the app container into
#      ./captures/<label>/critic and writes ./captures/<label>/host_log.txt
#
# Launch form (verify with `xcrun devicectl device process launch --help`):
#   xcrun devicectl device process launch --device <id> --terminate-existing --console \
#       com.bornless.ritual -- -stage 7 -camera low -renderPath rt -seed 1 -capture stills -runName critic
# devicectl is built on swift-argument-parser: everything after the bundle identifier
# is passed to the app as its argv, and the `--` terminator guarantees that the app's
# `-key value` pairs are never parsed as devicectl options. If your Xcode's devicectl
# rejects the terminator, set DEVICECTL_ARG_SEPARATOR="" (arguments then follow the
# bundle id directly). `--console` streams the app's stdout, so the harness's final
# `CAPTURE_DONE <dir>` / `CAPTURE_FAILED …` line is visible and the command returns
# when the app exits.
#
# Environment overrides:
#   BUNDLE_ID          app bundle identifier            (default com.bornless.ritual)
#   RUN_NAME           -runName / container folder      (default critic)
#   SEED               -seed                            (default 1)
#   RENDER_SCALE       -renderScale                     (default 0.67)
#   CLIP_SECONDS       -clipSeconds                     (default 5)
#   PERF_SECONDS       -perfSeconds                     (default 300)
#   STAGES / CAMERAS / PATHS   space-separated overrides of the loops
#   SKIP_STILLS=1 SKIP_CLIPS=1 SKIP_PERF=1   skip a phase
#   SKIP_PULL=1        do not copy the results back
#   STILL_TIMEOUT / CLIP_TIMEOUT / PERF_TIMEOUT   per-launch watchdog seconds
#                      (defaults 240, 900, PERF_SECONDS+300)
#   OUT_DIR            local output root                 (default ./captures)
#   DEVICECTL_ARG_SEPARATOR   "--" (default) or ""
#   DRY_RUN=1          print the commands without launching anything
#
# Exit status: 0 when every launch reported CAPTURE_DONE, 1 otherwise (the run
# continues past individual failures and lists them at the end).
set -u
set -o pipefail

usage() {
    sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 2
fi

DEVICE="$1"
LABEL="${2:-critic-$(date +%Y%m%d-%H%M%S)}"
BUNDLE_ID="${BUNDLE_ID:-com.bornless.ritual}"
RUN_NAME="${RUN_NAME:-critic}"
SEED="${SEED:-1}"
RENDER_SCALE="${RENDER_SCALE:-0.67}"
CLIP_SECONDS="${CLIP_SECONDS:-5}"
PERF_SECONDS="${PERF_SECONDS:-300}"
STAGES="${STAGES:-1 5 7 8}"
CAMERAS="${CAMERAS:-front threequarter profile overhead low closeup}"
PATHS="${PATHS:-rt fallback}"
STILL_TIMEOUT="${STILL_TIMEOUT:-240}"
CLIP_TIMEOUT="${CLIP_TIMEOUT:-900}"
PERF_TIMEOUT="${PERF_TIMEOUT:-$((PERF_SECONDS + 300))}"
OUT_DIR="${OUT_DIR:-./captures}"
DEVICECTL_ARG_SEPARATOR="${DEVICECTL_ARG_SEPARATOR---}"
DRY_RUN="${DRY_RUN:-0}"

DEST="$OUT_DIR/$LABEL"
HOST_LOG="$DEST/host_log.txt"
mkdir -p "$DEST"

log() {
    local line
    line="[$(date '+%H:%M:%S')] $*"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$HOST_LOG"
}

die() {
    log "error: $*"
    exit 2
}

# ---------------------------------------------------------------------------
# Host checks
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" != "1" ]; then
    [ "$(uname -s)" = "Darwin" ] || die "this script drives xcrun devicectl and must run on macOS"
    command -v xcrun >/dev/null 2>&1 || die "xcrun not found (install Xcode 15+)"
    xcrun devicectl --version >/dev/null 2>&1 || die "xcrun devicectl is unavailable (Xcode 15+ required)"
fi

# ---------------------------------------------------------------------------
# Destination checks: refuse simulators, require a CoreDevice match
# ---------------------------------------------------------------------------
refuse_simulator() {
    if xcrun simctl list devices 2>/dev/null | grep -Fq -- "$DEVICE"; then
        die "'$DEVICE' is a Simulator destination; Metal ray tracing does not run in the Simulator. Pass a physical device from 'xcrun devicectl list devices'."
    fi
    case "$DEVICE" in
        *[Ss]imulator*|booted) die "'$DEVICE' looks like a Simulator destination; a physical device is required" ;;
    esac
}

require_core_device() {
    local listing
    listing="$(xcrun devicectl list devices 2>/dev/null)" || die "could not list devices with 'xcrun devicectl list devices'"
    if ! printf '%s\n' "$listing" | grep -Fq -- "$DEVICE"; then
        log "known devices:"
        printf '%s\n' "$listing" | tee -a "$HOST_LOG"
        die "device '$DEVICE' is not listed by 'xcrun devicectl list devices' (is it paired, unlocked and connected?)"
    fi
}

if [ "$DRY_RUN" != "1" ]; then
    refuse_simulator
    require_core_device
fi

# ---------------------------------------------------------------------------
# Launch helper: runs one capture launch, waits for the app to exit (or the
# watchdog), and checks the console for CAPTURE_DONE.
# ---------------------------------------------------------------------------
FAILURES=()
LAUNCHES=0

launch_and_wait() {
    local timeout="$1"
    local tag="$2"
    shift 2
    local launch_log="$DEST/launch_${tag}.log"
    local cmd=(xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --console "$BUNDLE_ID")
    if [ -n "$DEVICECTL_ARG_SEPARATOR" ]; then
        cmd+=("$DEVICECTL_ARG_SEPARATOR")
    fi
    cmd+=("$@" -seed "$SEED" -renderScale "$RENDER_SCALE" -runName "$RUN_NAME" -narration 0 -autopilot 1)
    LAUNCHES=$((LAUNCHES + 1))
    log "launch [$tag]: ${cmd[*]}"
    if [ "$DRY_RUN" = "1" ]; then
        return 0
    fi

    : > "$launch_log"
    "${cmd[@]}" >"$launch_log" 2>&1 &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$timeout" ]; then
            log "watchdog: [$tag] exceeded ${timeout}s; killing the console session (the app is terminated by the next --terminate-existing launch)"
            kill "$pid" 2>/dev/null || true
            sleep 2
            kill -9 "$pid" 2>/dev/null || true
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    wait "$pid" 2>/dev/null || true

    if grep -q "CAPTURE_DONE" "$launch_log"; then
        log "ok [$tag] ($(grep -o 'CAPTURE_DONE .*' "$launch_log" | tail -n 1))"
        return 0
    fi
    local reason
    reason="$(grep -o 'CAPTURE_FAILED .*' "$launch_log" | tail -n 1)"
    [ -n "$reason" ] || reason="no CAPTURE_DONE line (timeout, crash or launch failure; see $launch_log)"
    log "FAILED [$tag]: $reason"
    FAILURES+=("$tag: $reason")
    return 1
}

# ---------------------------------------------------------------------------
# 1. Stills
# ---------------------------------------------------------------------------
if [ "${SKIP_STILLS:-0}" != "1" ]; then
    for stage in $STAGES; do
        for camera in $CAMERAS; do
            for path in $PATHS; do
                launch_and_wait "$STILL_TIMEOUT" "still_s${stage}_${camera}_${path}" \
                    -stage "$stage" -camera "$camera" -renderPath "$path" -capture stills || true
            done
        done
    done
fi

# ---------------------------------------------------------------------------
# 2. Clips: sigil spin (stage 7, three-quarter) and manifestation (stage 8, front)
# ---------------------------------------------------------------------------
if [ "${SKIP_CLIPS:-0}" != "1" ]; then
    for path in $PATHS; do
        launch_and_wait "$CLIP_TIMEOUT" "clip_s7_threequarter_${path}" \
            -stage 7 -camera threequarter -renderPath "$path" -capture clip -clipSeconds "$CLIP_SECONDS" || true
        launch_and_wait "$CLIP_TIMEOUT" "clip_s8_front_${path}" \
            -stage 8 -camera front -renderPath "$path" -capture clip -clipSeconds "$CLIP_SECONDS" || true
    done
fi

# ---------------------------------------------------------------------------
# 3. Performance: full autopilot ritual per render path
# ---------------------------------------------------------------------------
if [ "${SKIP_PERF:-0}" != "1" ]; then
    for path in $PATHS; do
        launch_and_wait "$PERF_TIMEOUT" "perf_${path}" \
            -stage 1 -camera threequarter -renderPath "$path" -capture perf -perfSeconds "$PERF_SECONDS" || true
    done
fi

# ---------------------------------------------------------------------------
# 4. Pull the run folder from the app's data container
# ---------------------------------------------------------------------------
if [ "${SKIP_PULL:-0}" != "1" ]; then
    pull_cmd=(xcrun devicectl device copy from --device "$DEVICE" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source "Documents/Captures/$RUN_NAME" --destination "$DEST")
    log "pull: ${pull_cmd[*]}"
    if [ "$DRY_RUN" != "1" ]; then
        if "${pull_cmd[@]}" >>"$HOST_LOG" 2>&1; then
            log "pulled into $DEST/$RUN_NAME"
        else
            log "FAILED: copy from device (see $HOST_LOG). Files stay in the app's Documents/Captures/$RUN_NAME (also reachable through Finder file sharing)."
            FAILURES+=("pull: devicectl copy failed")
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "launches: $LAUNCHES, failures: ${#FAILURES[@]}"
if [ "${#FAILURES[@]}" -gt 0 ]; then
    for failure in "${FAILURES[@]}"; do
        log "  - $failure"
    done
    log "next: Tools/capture/assemble.sh $DEST/$RUN_NAME   (clips → MP4, frametime summary)"
    exit 1
fi
log "next: Tools/capture/assemble.sh $DEST/$RUN_NAME   (clips → MP4, frametime summary)"
exit 0
