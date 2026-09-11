# Critic protocol (fixed before round one; never softened)

The critic is a separate agent. It never sees the builder's code notes, commit messages,
prior scores, or this repository's `docs/ROUNDS.md`. Its inputs are only the evidence
listed below and Appendix A of the build prompt (the ground truth for chart, name, sigil).

## Evidence

Captured on an iPhone 15 Pro with `Tools/capture/critic_capture.sh <device-id>`:

| Evidence | Count | Source |
|---|---|---|
| Stills: stages 1, 5, 7, 8 × angles front, three-quarter, profile, overhead, low, close-up | 24 per render path (48 total), native resolution PNG | `-capture stills` |
| Clips: sigil spin (stage 7, three-quarter) and manifestation (stage 8, front), 5 s each | 2 per render path (4 total), 60 fps frame sequences → MP4 via `Tools/capture/assemble.sh` | `-capture clip` |
| Performance: full autopilot ritual, 5 minutes | 1 log per render path (`frametime.json`) | `-capture perf -perfSeconds 300` |
| Fidelity: `manifest.json` (chart report, name, sigil cells) and the debug-panel chart text | 1 per run | any run |

Metal RT does not run in the Simulator: RT-path evidence is valid only from a device.

## Rubric (0–10 per axis, scored independently)

| Axis | What is judged | Evidence |
|---|---|---|
| Photorealism | lighting (candle area lights, soft shadows, bounce/ambient), materials (stone, wax SSS, skin SSS, cloth, floor gloss), smoke (volumetric, lit, self-shadowed) | all stills |
| Physics | fire behaviour (buoyant flicker, no popping), ember trajectories (gravity + drag, tangential shedding, cooling), spin momentum and friction (counter-rotation, decay without reversal) | clips + stage 7/8 stills |
| VFX design | sigil legibility (name letters, kamea path readable), ring motion, manifestation (condenses from fire and smoke; leonine, gold-white, fire, expansive, dominant) | stage 7/8 stills + clips |
| Interaction feel | tap latency (input → visible response ≤ 2 frames), gesture response (trace, flick, orbit, pinch, pan), haptic timing on stage completion | hands-on + clip timestamps |
| Performance | sustained 60 fps over 5 min, frame-time spikes (> 20 ms), thermal throttling (`thermalState` ≥ serious) | `frametime.json` both paths |
| Fidelity | stage order 1→8; chart values within 0.1° of the critic's own Swiss Ephemeris result; name and sigil match the critic's independent Appendix A derivation | manifest + debug panel + stills |

Scale: 0–3 broken; 4–7 functional but would not pass as a VFX still; 8 convincing;
9–10 indistinguishable from a high-end VFX plate. Every still is also scored; no frame
may score below 8 for the round to pass.

## Round rules

1. Any axis below 9 requires a ranked issue list. Each issue cites a specific still or clip
   timestamp, describes the visible failure, and states the fix the critic expects.
2. The builder answers every issue: **fixed** (with the change) or **rejected** (with reasoning).
3. No axis may regress between rounds. A regression fails the round outright.
4. Loop until every axis ≥ 9 and no frame < 8. Hard cap: six rounds. At the cap, ship the
   best-scoring round and list unresolved issues with an effort estimate each.

## Static rounds (this repository was built on Linux without Xcode or a device)

Until device evidence exists, rounds are run **statically**: independent critic agents read
only the shipped code, shader-lint output, and RitualCore test results, and score what can
be assessed from code. Static rounds use the same axes and the same rules, but their scores
are labelled `static` in `docs/ROUNDS.md` and are explicitly **not** VFX-plate scores: a
static critic cannot see a pixel. Static rounds exist to remove defects a device round
would find anyway (wrong physics, missing shadows, broken determinism, wrong chart values).
The first device round starts at round 1 of the six-round cap, not after the static rounds.

`docs/ROUNDS.md` records every round: evidence set, per-axis scores, ranked issues, and the
builder's answer to each.
