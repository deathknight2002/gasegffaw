//
//  Daemon.metal
//  Bornless Ritual — the leonine daemon: a bounded ray-marched signed-distance volume
//  (RENDER_CONTRACT §2 row 11 "DaemonPass: ray-march the daemon SDF … with emissive fire
//  shading and smoke absorption; depth-test vs G-buffer depth; writes Heat";
//  ARCHITECTURE §2 "Daemon: condenses at (0, 1.15, −0.25), final height ≈ 2.4 m, facing
//  +Z", §3 "Manifestation", §4 attributes; ShaderTypes.h `DaemonParams`; Common.h noise,
//  reversed-Z helpers; SDF.h `sdSphere` / `sdCapsule`).
//
//  Role: `daemon_vertex` emits a full-screen triangle (DaemonPass.swift scissors it to
//  the projected `boundsMin/Max`). `daemon_fragment` builds the pixel's camera ray,
//  clips it to the bounds box and to the G-buffer depth (the manual depth test: the
//  march never goes past the opaque scene), then marches the condensed distance field
//  accumulating emission with Beer–Lambert transmittance:
//    • body — smooth-min union of spheres and capsules in the daemon's local frame
//      (+Z toward the sorcerer): torso, chest, haunches, hind legs, forelimbs and paws,
//      neck, head, muzzle, ears and a swaying tail arc. The chest breathes
//      (scale 1 + 0.03·breath, `DaemonPresence` "dominant, unhurried"); the head, muzzle,
//      eyes and ears turn by `headYaw` about the neck; the mane is the head-sized sphere
//      displaced by fbm noise flowing upward, its sampling frame swept through wide arcs
//      (`DaemonMotion` "expansive arcing") and carved open in front of the face;
//    • condensation — the surface threshold is offset by
//      (1 − manifest)·1.5 + fbm(p·3 + t·0.4)·(1 − manifest)·2, so the form appears from
//      broken noise pockets deep inside and fills out to its skin as manifest → 1, with a
//      wider, hazier soft edge while condensing;
//    • shading — density = smoothstep over the soft edge; emission colour from the
//      SDF "heat": `paletteCore` on the skin and the eyes, `paletteMid` through the soft
//      edge, `paletteEdge` at the smoky boundary and in the condensation haze, modulated
//      by upward-flowing flame licks; transmittance falls with a dense body extinction
//      plus a lighter haze extinction (smoke absorption); rim embers sparkle in the
//      boundary band; the eyes are two small `paletteCore` emitters that light once the
//      form is mostly condensed.
//  Output: premultiplied colour + alpha (1 − transmittance) into HDRColor with src-over
//  blending, and alpha-proportional Heat (additive), both configured by DaemonPass.swift.
//  No depth write.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"
#include "SDF.h"

using namespace metal;

// MARK: - Constants

/// March budget and step bounds (metres).
constant uint kDaemonMaxSteps = 96u;
constant float kDaemonMinStep = 0.02f;
constant float kDaemonMaxStep = 0.30f;
/// Sphere-tracing safety factor outside the soft band (the noise offset is not Lipschitz-1).
constant float kDaemonSkipFactor = 0.6f;
/// Soft-edge width at full manifestation and the extra width while condensing (metres).
constant float kDaemonEdgeWidth = 0.05f;
constant float kDaemonCondenseEdgeWidth = 0.30f;
/// Condensation haze band beyond the edge (metres) and its peak density.
constant float kDaemonHazeWidth = 0.60f;
constant float kDaemonHazeDensity = 0.25f;
/// Extinction coefficients (1/m) inside the body and in the haze.
constant float kDaemonBodyExtinction = 30.0f;
constant float kDaemonHazeExtinction = 5.0f;
/// Emission scales (linear radiance per metre of density, before exposure).
constant float kDaemonRadiance = 2.5f;
constant float kDaemonHazeRadiance = 0.35f;
constant float kDaemonEyeRadiance = 14.0f;
constant float kDaemonRimEmberRadiance = 8.0f;
/// Stop marching once this little light can still get through.
constant float kDaemonTransmittanceCutoff = 0.02f;
/// Heat written per unit alpha.
constant float kDaemonHeat = 0.6f;
/// Smooth-union radii (metres) for body joints and the face.
constant float kDaemonJoinK = 0.10f;
constant float kDaemonFaceJoinK = 0.05f;
/// Mane sphere radius, noise amplitude and flow speed.
constant float kManeRadius = 0.42f;
constant float kManeNoiseAmplitude = 0.14f;
constant float kManeNoiseFrequency = 3.5f;
constant float kManeFlowSpeed = 0.9f;
constant float kManeArcAmplitude = 0.55f;
/// Only evaluate the mane noise this close to the mane sphere.
constant float kManeNoiseReach = 0.35f;
/// Noise lattice salts.
constant uint kManeSeed = 0x3A7Eu;
constant uint kCondenseSeed = 0xC0DEu;
constant uint kLickSeed = 0x11C5u;
constant uint kSparkSeed = 0x5A2Fu;

// MARK: - Local geometry (metres, relative to DaemonParams.center; +Z faces the sorcerer)

/// Neck pivot the head assembly yaws about.
constant float3 kNeckPivot = float3(0.0f, 0.62f, 0.10f);
constant float3 kHeadCenter = float3(0.0f, 0.90f, 0.20f);
constant float kHeadRadius = 0.28f;
constant float3 kManeCenter = float3(0.0f, 0.90f, 0.05f);
constant float3 kFaceCarveCenter = float3(0.0f, 0.90f, 0.46f);
constant float kFaceCarveRadius = 0.30f;
constant float3 kMuzzleA = float3(0.0f, 0.80f, 0.32f);
constant float3 kMuzzleB = float3(0.0f, 0.78f, 0.52f);
constant float kMuzzleRadius = 0.14f;
constant float3 kEyeOffset = float3(0.11f, 0.95f, 0.45f);
constant float kEyeRadius = 0.035f;
constant float3 kEarOffset = float3(0.19f, 1.12f, 0.10f);
constant float kEarRadius = 0.07f;
constant float3 kNeckA = float3(0.0f, 0.40f, 0.02f);
constant float3 kNeckB = float3(0.0f, 0.78f, 0.15f);
constant float kNeckRadius = 0.24f;
constant float3 kTorsoA = float3(0.0f, -0.55f, -0.30f);
constant float3 kTorsoB = float3(0.0f, 0.40f, 0.02f);
constant float kTorsoRadius = 0.38f;
constant float3 kChestCenter = float3(0.0f, 0.22f, 0.16f);
constant float kChestRadius = 0.40f;
constant float3 kHaunchOffset = float3(0.36f, -0.72f, -0.38f);
constant float kHaunchRadius = 0.40f;
constant float3 kHindA = float3(0.36f, -0.85f, -0.30f);
constant float3 kHindB = float3(0.34f, -1.00f, 0.15f);
constant float kHindRadius = 0.14f;
constant float3 kForelimbA = float3(0.30f, 0.05f, 0.20f);
constant float3 kForelimbB = float3(0.32f, -1.00f, 0.38f);
constant float kForelimbRadius = 0.12f;
constant float3 kPawOffset = float3(0.32f, -1.00f, 0.48f);
constant float kPawRadius = 0.14f;
constant float3 kTailP0 = float3(0.30f, -0.80f, -0.62f);
constant float3 kTailP1 = float3(0.55f, -0.45f, -0.85f);
constant float3 kTailP2 = float3(0.45f, 0.05f, -0.95f);
constant float3 kTailP3 = float3(0.15f, 0.30f, -0.85f);
constant float kTailRadius = 0.06f;
constant float kTuftRadius = 0.10f;

// MARK: - Types

/// Distance sample of the (uncondensed) body.
struct DaemonSample {
    float d;      ///< signed distance to the body (m)
    float eye;    ///< signed distance to the nearer eye (m)
};

/// Rasteriser varyings (position only; uv is derived from the pixel position).
struct DaemonVaryings {
    float4 position [[position]];
};

/// HDRColor (premultiplied, src-over) and Heat (additive).
struct DaemonFragmentOut {
    float4 hdr  [[color(0)]];
    float  heat [[color(1)]];
};

// MARK: - Helpers

/// Polynomial smooth minimum (Quilez); `k` is the blend radius.
inline float smooth_union(float a, float b, float k) {
    float h = saturate(0.5f + 0.5f * (b - a) / max(k, 1e-5f));
    return mix(b, a, h) - k * h * (1.0f - h);
}

/// Rotation about +Y by `angle` (radians).
inline float3 rotate_y(float3 p, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
}

/// Mirrors an x offset for the left/right pair and returns the nearer distance.
inline float sd_sphere_pair(float3 p, float3 offset, float radius) {
    float3 mirrored = float3(abs(p.x), p.y, p.z);
    return sdSphere(mirrored - offset, radius);
}

/// Capsule pair mirrored in x.
inline float sd_capsule_pair(float3 p, float3 a, float3 b, float radius) {
    float3 mirrored = float3(abs(p.x), p.y, p.z);
    return sdCapsule(mirrored, a, b, radius);
}

/// Point on the tail's cubic Bézier arc at `s`, with a slow lateral sway.
inline float3 tail_point(float s, float time) {
    float u = 1.0f - s;
    float3 p = u * u * u * kTailP0 + 3.0f * u * u * s * kTailP1 + 3.0f * u * s * s * kTailP2 + s * s * s * kTailP3;
    p.x += 0.10f * s * sin(time * 0.8f + s * 2.0f);
    return p;
}

/// Tail as a chain of capsules along the arc with a tuft at the tip.
inline float sd_tail(float3 p, float time) {
    float d = 1e6f;
    float3 previous = tail_point(0.0f, time);
    for (uint i = 1u; i <= 5u; ++i) {
        float3 next = tail_point(float(i) / 5.0f, time);
        d = min(d, sdCapsule(p, previous, next, kTailRadius));
        previous = next;
    }
    return min(d, sdSphere(p - previous, kTuftRadius));
}

/// Mane: the head-sized sphere displaced by fbm flowing upward through arcing sweeps,
/// carved open in front of the face. `q` is in the yawed head frame.
inline float sd_mane(float3 q, float time, uint seed) {
    float3 m = q - kManeCenter;
    float sphere = length(m) - kManeRadius;
    if (sphere < kManeNoiseReach) {
        float arc = kManeArcAmplitude * sin(time * 0.6f + m.y * 2.0f);
        float3 swept = rotate_y(m, arc);
        float3 coords = swept * kManeNoiseFrequency + float3(0.0f, -time * kManeFlowSpeed, 0.0f);
        float lift = 0.6f + 0.4f * saturate(m.y / kManeRadius + 0.5f);   // more flame on top
        sphere -= fbm3(coords, 3u, seed ^ kManeSeed) * kManeNoiseAmplitude * lift;
    }
    float face = sdSphere(q - kFaceCarveCenter, kFaceCarveRadius);
    return max(sphere, -face);
}

/// The uncondensed body in the local frame (breath already applied by the caller).
inline DaemonSample daemon_body(float3 p, constant DaemonParams &d, float time, uint seed) {
    // Head assembly yaws about the neck pivot.
    float3 q = kNeckPivot + rotate_y(p - kNeckPivot, -d.headYaw);

    float body = sdCapsule(p, kTorsoA, kTorsoB, kTorsoRadius);
    body = smooth_union(body, sdSphere(p - kChestCenter, kChestRadius), kDaemonJoinK);
    body = smooth_union(body, sd_sphere_pair(p, kHaunchOffset, kHaunchRadius), kDaemonJoinK);
    body = smooth_union(body, sd_capsule_pair(p, kHindA, kHindB, kHindRadius), kDaemonJoinK);
    body = smooth_union(body, sd_capsule_pair(p, kForelimbA, kForelimbB, kForelimbRadius), kDaemonJoinK);
    body = smooth_union(body, sd_sphere_pair(p, kPawOffset, kPawRadius), kDaemonJoinK);
    body = smooth_union(body, sdCapsule(p, kNeckA, kNeckB, kNeckRadius), kDaemonJoinK);
    body = smooth_union(body, sd_tail(p, time), kDaemonJoinK * 0.5f);

    float head = sdSphere(q - kHeadCenter, kHeadRadius);
    head = smooth_union(head, sdCapsule(q, kMuzzleA, kMuzzleB, kMuzzleRadius), kDaemonFaceJoinK);
    head = smooth_union(head, sd_sphere_pair(q, kEarOffset, kEarRadius), kDaemonFaceJoinK);
    head = smooth_union(head, sd_mane(q, time, seed), kDaemonJoinK);

    DaemonSample sample;
    sample.d = smooth_union(body, head, kDaemonJoinK);
    sample.eye = sd_sphere_pair(q, kEyeOffset, kEyeRadius);
    return sample;
}

/// Condensed distance at world position `p`: the breathing body plus the manifestation
/// threshold offset (1 − m)·1.5 + fbm(p·3 + t·0.4)·(1 − m)·2 (ARCHITECTURE §3).
inline float daemon_distance(float3 worldPosition, constant DaemonParams &d, float time, float manifest,
                             uint seed, thread float &eye) {
    float3 local = worldPosition - d.center;
    float breathScale = 1.0f + 0.03f * saturate(d.breath);
    DaemonSample body = daemon_body(local / breathScale, d, time, seed);
    eye = body.eye * breathScale;
    float dist = body.d * breathScale;
    if (manifest < 0.999f) {
        float inv = 1.0f - manifest;
        float cloud = fbm3(local * 3.0f + time * 0.4f, 3u, seed ^ kCondenseSeed);
        dist += inv * 1.5f + cloud * inv * 2.0f;
    }
    return dist;
}

/// Palette by the SDF "heat" band s ∈ [0, 1] (0 = on/inside the skin, 1 = outer edge).
inline float3 daemon_skin_color(constant DaemonParams &d, float s) {
    return s < 0.5f ? mix(d.paletteCore, d.paletteMid, s * 2.0f)
                    : mix(d.paletteMid, d.paletteEdge, (s - 0.5f) * 2.0f);
}

/// Ray / axis-aligned box slab test; returns (tEnter, tExit) with tEnter clamped to 0.
inline float2 ray_box(float3 origin, float3 direction, float3 boundsMin, float3 boundsMax) {
    float3 safeDir = select(direction, float3(1e-6f), abs(direction) < 1e-6f);
    float3 t0 = (boundsMin - origin) / safeDir;
    float3 t1 = (boundsMax - origin) / safeDir;
    float3 tNear = min(t0, t1);
    float3 tFar = max(t0, t1);
    float tEnter = max(max(tNear.x, tNear.y), max(tNear.z, 0.0f));
    float tExit = min(min(tFar.x, tFar.y), tFar.z);
    return float2(tEnter, tExit);
}

// MARK: - Vertex

vertex DaemonVaryings daemon_vertex(uint vid [[vertex_id]]) {
    DaemonVaryings out;
    float2 ndc = float2(vid == 1u ? 3.0f : -1.0f, vid == 2u ? 3.0f : -1.0f);
    out.position = float4(ndc, 0.5f, 1.0f);
    return out;
}

// MARK: - Fragment

fragment DaemonFragmentOut daemon_fragment(DaemonVaryings in [[stage_in]],
                                           constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                                           constant DaemonParams &d [[buffer(BufferIndexDaemonParams)]],
                                           depth2d<float, access::read> depthTex [[texture(TextureIndexDepth)]]) {
    DaemonFragmentOut out;
    out.hdr = float4(0.0f);
    out.heat = 0.0f;

    float manifest = saturate(d.manifest);
    if (manifest <= 0.0f) {
        discard_fragment();
        return out;
    }

    // Camera ray through the pixel centre (jittered projection, like the G-buffer).
    uint2 pixel = uint2(in.position.xy);
    float2 uv = in.position.xy * u.invRenderSize;
    float3 origin = u.cameraPosition;
    float3 farPoint = reconstruct_world_position(uv, 0.0f, u.invViewProjection);
    float3 direction = safe_normalize(farPoint - origin, float3(0.0f, 0.0f, -1.0f));

    // Bounds and the manual depth test against the opaque scene.
    float2 range = ray_box(origin, direction, d.boundsMin, d.boundsMax);
    float tEnter = range.x;
    float tExit = range.y;
    float sceneDepth = depthTex.read(pixel);
    if (!is_background_depth(sceneDepth)) {
        float3 scenePosition = reconstruct_world_position(uv, sceneDepth, u.invViewProjection);
        tExit = min(tExit, dot(scenePosition - origin, direction));
    }
    if (tEnter >= tExit) {
        discard_fragment();
        return out;
    }

    float time = d.time;
    uint seed = u.seedLo;
    float inv = 1.0f - manifest;
    float edgeWidth = kDaemonEdgeWidth + kDaemonCondenseEdgeWidth * inv;
    float hazeWidth = kDaemonHazeWidth * inv;
    float band = edgeWidth + hazeWidth;
    float breathGlow = 0.85f + 0.15f * saturate(d.breath);
    float emissive = max(d.emissiveScale, 0.0f);
    float eyeOpen = saturate((manifest - 0.6f) / 0.3f);

    // Deterministic per-pixel, per-frame start jitter breaks slice banding (integrated by TAA).
    float jitter = hash_unit(u.seedLo, u.seedHi, u.frameIndex, pixel.x, pixel.y);
    float t = tEnter + kDaemonMinStep * jitter;
    float3 radiance = float3(0.0f);
    float transmittance = 1.0f;

    for (uint step = 0u; step < kDaemonMaxSteps; ++step) {
        if (t >= tExit || transmittance < kDaemonTransmittanceCutoff) break;
        float3 p = origin + direction * t;
        float eye = 1e6f;
        float dist = daemon_distance(p, d, time, manifest, seed, eye);

        if (dist > band && eye > band) {
            // Outside the soft band: sphere-trace forward (bounded).
            t += clamp(dist * kDaemonSkipFactor, kDaemonMinStep, kDaemonMaxStep);
            continue;
        }

        float dt = min(kDaemonMinStep, tExit - t);
        float3 local = p - d.center;

        // Densities: dense body with a soft skin, plus the condensation haze.
        float body = 1.0f - smoothstep(0.0f, edgeWidth, dist);
        float haze = inv * kDaemonHazeDensity * (1.0f - smoothstep(0.0f, max(hazeWidth, 1e-3f), dist));
        float sigma = kDaemonBodyExtinction * body + kDaemonHazeExtinction * haze;

        // Emission: palette by heat band, upward-flowing flame licks, haze glow.
        float s = saturate(dist / edgeWidth);
        float lick = fbm3(local * 4.0f + float3(0.0f, -time * 1.5f, 0.0f), 2u, seed ^ kLickSeed);
        float flame = 0.75f + 0.5f * lick;
        float3 emission = daemon_skin_color(d, s) * (body * flame * kDaemonRadiance * emissive * breathGlow);
        emission += d.paletteEdge * (haze * kDaemonHazeRadiance * emissive);

        // Rim embers: bright specks drifting in the boundary band.
        float rim = smoothstep(0.0f, edgeWidth, dist) * (1.0f - smoothstep(edgeWidth, edgeWidth * 2.5f, dist));
        if (rim > 0.0f) {
            float grain = saturate(simplex_noise3(local * 40.0f + float3(0.0f, -time * 2.0f, 0.0f), seed ^ kSparkSeed));
            float spark = grain * grain;
            spark *= spark;
            spark *= spark;                                        // grain^8
            emission += mix(d.paletteEdge, d.paletteCore, 0.5f) * (rim * spark * kDaemonRimEmberRadiance * emissive);
        }

        // Eyes: small core-coloured emitters, lit once the form is mostly condensed.
        float eyeDensity = 1.0f - smoothstep(-0.01f, 0.02f, eye);
        if (eyeDensity > 0.0f) {
            emission += d.paletteCore * (eyeDensity * kDaemonEyeRadiance * eyeOpen);
            sigma += kDaemonBodyExtinction * eyeDensity;
        }

        radiance += transmittance * emission * dt;
        transmittance *= exp(-sigma * dt);
        t += dt;
    }

    float alpha = saturate(1.0f - transmittance);
    if (alpha <= 1e-4f) {
        discard_fragment();
        return out;
    }
    out.hdr = float4(max(radiance, 0.0f), alpha);
    out.heat = kDaemonHeat * alpha * (0.6f + 0.4f * manifest);
    return out;
}
