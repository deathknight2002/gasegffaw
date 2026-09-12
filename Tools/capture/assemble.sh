#!/usr/bin/env bash
# Tools/capture/assemble.sh — turn pulled capture runs into critic evidence
# (docs/ARCHITECTURE.md §7 "`Tools/capture/assemble.sh` makes MP4s with ffmpeg",
# docs/CRITIC.md "Clips … 60 fps frame sequences → MP4").
#
# usage: Tools/capture/assemble.sh [captures-dir ...]
#
#   captures-dir   one or more run folders (e.g. ./captures/<label>/critic) or any
#                  parent of them; default: the newest folder under ./captures.
#
# For every directory named clip_* that contains frame_00000.png:
#   ffmpeg -framerate 60 -i frame_%05d.png -c:v libx264 -pix_fmt yuv420p -crf 14 clip.mp4
#   (odd native resolutions are padded by one pixel because yuv420p needs even sizes;
#   existing clip.mp4 files are rebuilt when FORCE=1, otherwise skipped).
# Then every *frametime*.json below the given directories is summarised with
# python3 into <captures-dir>/summary.md (one markdown table row per log:
# render path, stage, camera, scale, MetalFX, frames, average fps, p50 / p99 / max
# frame ms, spikes over 20 ms, thermal states) and printed.
#
# Environment: FFMPEG (binary, default ffmpeg), CRF (default 14), FORCE=1, SKIP_MP4=1.
set -u
set -o pipefail

usage() {
    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
    esac
done

FFMPEG="${FFMPEG:-ffmpeg}"
CRF="${CRF:-14}"
FORCE="${FORCE:-0}"
SKIP_MP4="${SKIP_MP4:-0}"

ROOTS=("$@")
if [ "${#ROOTS[@]}" -eq 0 ]; then
    newest="$(ls -1dt ./captures/*/ 2>/dev/null | head -n 1)"
    [ -n "$newest" ] || { echo "assemble: no captures directory given and ./captures is empty" >&2; usage; exit 2; }
    ROOTS=("${newest%/}")
fi
for root in "${ROOTS[@]}"; do
    [ -d "$root" ] || { echo "assemble: '$root' is not a directory" >&2; exit 2; }
done

# ---------------------------------------------------------------------------
# 1. Clips → MP4
# ---------------------------------------------------------------------------
clips_done=0
clips_failed=0
if [ "$SKIP_MP4" != "1" ]; then
    if ! command -v "$FFMPEG" >/dev/null 2>&1; then
        echo "assemble: '$FFMPEG' not found; install ffmpeg (brew install ffmpeg) or set SKIP_MP4=1" >&2
        exit 2
    fi
    while IFS= read -r frame0; do
        dir="$(dirname "$frame0")"
        out="$dir/clip.mp4"
        if [ -f "$out" ] && [ "$FORCE" != "1" ]; then
            echo "skip   $out (exists; FORCE=1 to rebuild)"
            continue
        fi
        count="$(find "$dir" -maxdepth 1 -name 'frame_*.png' | wc -l | tr -d ' ')"
        echo "encode $out ($count frames)"
        if "$FFMPEG" -y -loglevel error -framerate 60 -i "$dir/frame_%05d.png" \
            -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" \
            -c:v libx264 -pix_fmt yuv420p -crf "$CRF" -movflags +faststart "$out"; then
            clips_done=$((clips_done + 1))
        else
            echo "FAILED $out" >&2
            clips_failed=$((clips_failed + 1))
        fi
    done < <(find "${ROOTS[@]}" -type f -path '*clip_*' -name 'frame_00000.png' | sort)
fi

# ---------------------------------------------------------------------------
# 2. frametime.json → markdown summary
# ---------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { echo "assemble: python3 is required for the summary" >&2; exit 2; }

python3 - "${ROOTS[@]}" <<'PYEOF'
import json
import math
import os
import sys


def nearest_rank(values, percentile):
    """Nearest-rank percentile (matches RitualCore FrameLog.nearestRank)."""
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = int(math.ceil(percentile / 100.0 * len(ordered)))
    rank = min(max(rank, 1), len(ordered))
    return ordered[rank - 1]


def summarise(path):
    with open(path, "r", encoding="utf-8") as handle:
        log = json.load(handle)
    frames = log.get("frames") or []
    frame_ms = [float(f.get("frameMs", 0.0)) for f in frames]
    embedded = log.get("summary") or {}
    total = len(frames)
    if total:
        mean_ms = sum(frame_ms) / total
        computed = {
            "averageFps": (1000.0 / mean_ms) if mean_ms > 0 else 0.0,
            "p50FrameMs": nearest_rank(frame_ms, 50),
            "p99FrameMs": nearest_rank(frame_ms, 99),
            "maxFrameMs": max(frame_ms),
            "spikesOver20ms": sum(1 for v in frame_ms if v > 20.0),
            "framesTotal": total,
        }
    else:
        computed = {"averageFps": 0.0, "p50FrameMs": 0.0, "p99FrameMs": 0.0, "maxFrameMs": 0.0,
                    "spikesOver20ms": 0, "framesTotal": 0}
    thermal = {}
    for frame in frames:
        state = str(frame.get("thermal", "unknown"))
        thermal[state] = thermal.get(state, 0) + 1
    summary = dict(computed)
    for key in ("averageFps", "p50FrameMs", "p99FrameMs", "maxFrameMs", "spikesOver20ms", "framesTotal"):
        if key in embedded:
            summary[key] = embedded[key]
    if isinstance(embedded.get("thermalStates"), dict) and embedded["thermalStates"]:
        thermal = embedded["thermalStates"]
    gpu = [float(f.get("gpuMs", 0.0)) for f in frames]
    cpu = [float(f.get("cpuMs", 0.0)) for f in frames]
    summary["meanGpuMs"] = (sum(gpu) / total) if total else 0.0
    summary["meanCpuMs"] = (sum(cpu) / total) if total else 0.0
    summary["thermal"] = ", ".join("%s %d" % (k, v) for k, v in sorted(thermal.items())) or "-"
    summary["renderPath"] = str(log.get("renderPath", "?"))
    summary["stage"] = log.get("stage", "?")
    summary["camera"] = str(log.get("camera", "?"))
    summary["renderScale"] = log.get("renderScale", "?")
    summary["metalFX"] = "yes" if log.get("metalFX") else "no"
    summary["device"] = str(log.get("device", "?"))
    summary["os"] = str(log.get("os", "?"))
    return summary


def find_logs(roots):
    seen = set()
    for root in roots:
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in sorted(filenames):
                if name.endswith(".json") and "frametime" in name:
                    full = os.path.join(dirpath, name)
                    real = os.path.realpath(full)
                    if real in seen:
                        continue
                    seen.add(real)
                    yield full


roots = sys.argv[1:]
rows = []
devices = set()
for log_path in find_logs(roots):
    try:
        summary = summarise(log_path)
    except (OSError, ValueError) as error:
        print("summary: could not read %s: %s" % (log_path, error), file=sys.stderr)
        continue
    rel = os.path.relpath(log_path, roots[0]) if len(roots) == 1 else log_path
    # The canonical frametime.json duplicates the last per-capture copy; keep it out of
    # the table when a per-capture copy exists in the same folder.
    if os.path.basename(log_path) == "frametime.json":
        siblings = [n for n in os.listdir(os.path.dirname(log_path)) if n.endswith(".frametime.json")]
        if siblings:
            continue
    devices.add("%s / %s" % (summary["device"], summary["os"]))
    rows.append((rel, summary))

lines = []
lines.append("# Frame-time summary")
lines.append("")
lines.append("Device(s): %s" % (", ".join(sorted(devices)) if devices else "none"))
lines.append("")
lines.append("| log | path | stage | camera | scale | MetalFX | frames | avg fps | p50 ms | p99 ms | max ms | spikes >20 ms | mean GPU ms | mean CPU ms | thermal |")
lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for rel, s in rows:
    lines.append("| %s | %s | %s | %s | %s | %s | %d | %.1f | %.2f | %.2f | %.2f | %d | %.2f | %.2f | %s |" % (
        rel, s["renderPath"], s["stage"], s["camera"], s["renderScale"], s["metalFX"], int(s["framesTotal"]),
        float(s["averageFps"]), float(s["p50FrameMs"]), float(s["p99FrameMs"]), float(s["maxFrameMs"]),
        int(s["spikesOver20ms"]), s["meanGpuMs"], s["meanCpuMs"], s["thermal"]))
if not rows:
    lines.append("| (no frametime logs found) | | | | | | | | | | | | | | |")
lines.append("")
lines.append("Budget (ARCHITECTURE §9): sustained 60 fps over 5 min, spikes > 20 ms flagged, thermalState ≥ serious is throttling.")
text = "\n".join(lines) + "\n"
print(text)
target_dir = roots[0] if len(roots) == 1 else os.getcwd()
out = os.path.join(target_dir, "summary.md")
with open(out, "w", encoding="utf-8") as handle:
    handle.write(text)
print("wrote %s (%d logs)" % (out, len(rows)))
PYEOF
status=$?

echo "clips encoded: $clips_done, failed: $clips_failed"
if [ "$status" -ne 0 ] || [ "$clips_failed" -ne 0 ]; then
    exit 1
fi
exit 0
