//
//  Flame.metal
//  Bornless Ritual — candle flames as ray-marched procedural volumes on camera-facing
//  quads, plus the heat plume that drives the post-process shimmer
//  (RENDER_CONTRACT §2 row 9 "FlamePass"; ShaderTypes.h `FlameData`,
//  TextureIndexHDRColor / TextureIndexHeat; Common.h `blackbody_rgb`, `fbm3`, hashing).
//
//  Geometry: each `FlameData` instance is drawn as 12 vertices (FlamePass.swift,
//  `drawPrimitives(.triangle, vertexCount: 12, instanceCount: flameCount)`):
//    vertices 0–5  the FLAME quad, 1.6·width wide and 2.2·height tall, from 0.2·height
//                  below the wick top to 2.0·height above it;
//    vertices 6–11 the HEAT quad, 8·width wide and 3·height tall, from the wick top up.
//  Both are spherical billboards (camera right / up axes from the view matrix) centred
//  on the axis of the flame; the flame quad is only a proxy that covers the marched
//  volume from any direction. An unlit flame (intensity 0) collapses to a point.
//
//  Fragment (flame): the pixel's view ray is intersected with the flame's bounding
//  cylinder (radius 0.8·width, y ∈ [−0.2, 2.0]·height around the wick top) and the
//  density is ray-marched over 20 steps (jittered start, ARCHITECTURE §6 hash keyed by
//  (seed, frameIndex, pixel)) in flame-local space (origin at the wick top, world axes;
//  candles stand upright):
//    · teardrop profile: the radius rises as √ from the wick, peaks at 0.25·height and
//      tapers to zero at 1.85·height;
//    · wobble: the profile's axis is displaced by
//      0.35·width·h²·fbm(h·2.4 − (t·6 + 3·flicker)) — the noise coordinate is advected
//      upward with time so the sway travels up the flame — using two decorrelated fbm
//      fields (x / z) per flame;
//    · inner blue combustion zone: a thin shell just inside the profile edge below
//      0.45·height, blue (0.20, 0.42, 1.0), weighted so that it carries ≈ 1.5 % of the
//      flame's light (its emission coefficient is 0.06 of the body's; the zone's volume
//      is roughly a quarter of the body's);
//    · main body: blackbody_rgb(temperatureK, or 1800 K when 0) × elemental `color`
//      (SceneUpdater passes (1,1,1) for a plain candle), hotter/whiter in the core
//      (+500 K at the axis) and cooler toward the tip (−15 %);
//    · emission = kFlameEmission · density · intensity · flameIntensity (linear radiance
//      per metre; the core of a candle integrates to ≈ 25 — far above the bloom
//      threshold, as a flame should be); absorption σ_a = kFlameAbsorption · density.
//  The march accumulates E += T·emission·ds and T *= exp(−σ_a·ds); output rgb = E
//  (added to HDRColor with (.one, .one) blending), a = 1 − T (the pipeline masks alpha).
//
//  Fragment (heat): a rising plume 3× the flame height, Gaussian across the quad
//  (half-width growing from 1·width to 2.5·width), swaying with fbm; strength
//  ∝ intensity · flameIntensity, peaking at kHeatStrength — added into Heat (r16Float).
//  Both quads are depth-tested .greaterEqual against the G-buffer depth (no write) at
//  their billboard plane; the flame's own volume is never occluded by its wick because
//  the wick top sits below the quad centre.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;

// MARK: - Constants

/// Vertices per flame instance (flame quad + heat quad).
constant uint kFlameVerticesPerInstance = 12u;
/// Flame quad half-width / vertical extent in units of `width` / `height`.
constant float kFlameQuadHalfWidth = 0.8f;
constant float kFlameQuadBottom = -0.2f;
constant float kFlameQuadTop = 2.0f;
/// Heat quad half-width (units of width) and top (units of height).
constant float kHeatQuadHalfWidth = 4.0f;
constant float kHeatQuadTop = 3.0f;
/// Ray-march steps through the flame volume (16–24 per the contract).
constant uint kFlameMarchSteps = 20u;
/// Emission (linear radiance per metre at density 1, intensity 1) and absorption (1/m).
constant float kFlameEmission = 2500.0f;
constant float kFlameAbsorption = 40.0f;
/// Blue combustion zone: colour and emission coefficient relative to the body.
constant float3 kFlameBlueColor = float3(0.20f, 0.42f, 1.0f);
constant float kFlameBlueWeight = 0.06f;
/// Default flame temperature when FlameData.temperatureK is 0.
constant float kFlameDefaultTemperatureK = 1800.0f;
/// Core temperature boost (K) and tip cooling fraction.
constant float kFlameCoreBoostK = 500.0f;
constant float kFlameTipCooling = 0.15f;
/// Wobble amplitude in units of width (scaled by h²) and its temporal rate.
constant float kFlameWobbleAmplitude = 0.35f;
constant float kFlameWobbleRate = 6.0f;
constant float kFlameWobbleFlickerPhase = 3.0f;
constant float kFlameWobbleAdvection = 2.4f;
/// Heat plume: peak strength, half-width growth per flame height (units of width),
/// sway amplitude (units of width per flame height) and rise rate.
constant float kHeatStrength = 0.8f;
constant float kHeatSpread = 0.5f;
constant float kHeatSwayAmplitude = 0.4f;
constant float kHeatRiseRate = 2.0f;

// MARK: - Varyings

/// Vertex → fragment payload.
struct FlameVaryings {
    float4 position [[position]];
    float3 worldPosition;          ///< billboard point (the march starts from the view ray through it)
    float2 quadCoord;              ///< x ∈ [−1, 1] across, y ∈ [0, 1] up the quad
    uint flameIndex [[flat]];
    uint kind [[flat]];            ///< 0 flame, 1 heat plume
};

/// Fragment outputs: color(0) HDRColor (additive), color(1) Heat (additive, r16Float).
struct FlameOut {
    float4 color [[color(0)]];
    float4 heat [[color(1)]];
};

// MARK: - Helpers

/// Corner of the unit quad for vertices 0…5 (two CCW triangles): x ∈ {−1, 1}, y ∈ {0, 1}.
inline float2 flame_quad_corner(uint corner) {
    float x = (corner == 1u || corner == 4u || corner == 5u) ? 1.0f : -1.0f;
    float y = (corner == 2u || corner == 3u || corner == 5u) ? 1.0f : 0.0f;
    return float2(x, y);
}

/// Teardrop radius profile (units of the half-width) at normalised height `h`.
inline float flame_profile(float h) {
    float rise = saturate((h + 0.15f) / 0.4f);
    float taper = saturate((1.85f - h) / 1.6f);
    return sqrt(rise) * pow(taper, 1.3f);
}

/// Horizontal displacement (metres, xz) of the flame axis at normalised height `h`.
inline float2 flame_wobble(float h, float width, float flicker, float time, uint flameIndex, uint seed) {
    float phase = time * kFlameWobbleRate + flicker * kFlameWobbleFlickerPhase;
    float lane = float(flameIndex) * 2.13f + 0.7f;
    float nx = fbm3(float3(h * kFlameWobbleAdvection - phase, lane, 0.37f), 2u, seed);
    float nz = fbm3(float3(0.61f, h * kFlameWobbleAdvection - phase, lane + 3.1f), 2u, seed + 7u);
    return float2(nx, nz) * (kFlameWobbleAmplitude * width * h * h);
}

/// Density sample of the flame at local position `q` (wick top at the origin).
/// Returns the body density; `core` (0 at the edge, 1 on the axis) and `blue` (the
/// combustion-shell weight) are written through the references.
inline float flame_density(float3 q, float height, float width, float flicker, float time,
                           uint flameIndex, uint seed, thread float &core, thread float &blue) {
    core = 0.0f;
    blue = 0.0f;
    float h = q.y / max(height, 1e-4f);
    if (h < -0.2f || h > 1.9f) {
        return 0.0f;
    }
    float radius = 0.5f * width * flame_profile(h);
    if (radius <= 1e-5f) {
        return 0.0f;
    }
    float2 axisOffset = flame_wobble(h, width, flicker, time, flameIndex, seed);
    float radial = length(q.xz - axisOffset) / radius;
    float body = 1.0f - smoothstep(0.55f, 1.0f, radial);
    core = sqr(saturate(1.0f - radial));
    // Thin shell just inside the edge, only near the wick.
    float shell = smoothstep(0.55f, 0.85f, radial) * (1.0f - smoothstep(0.85f, 1.05f, radial));
    float low = smoothstep(-0.2f, -0.05f, h) * (1.0f - smoothstep(0.2f, 0.45f, h));
    blue = shell * low;
    // Vertical envelope: the lower-middle body is the brightest, the tip fades.
    float envelope = smoothstep(-0.2f, 0.05f, h) * (1.0f - smoothstep(0.9f, 1.85f, h));
    return body * envelope * (0.85f + 0.15f * flicker);
}

/// Intersects the ray (o, d) with the flame's bounding cylinder (axis +Y, radius r,
/// y ∈ [yMin, yMax]); returns false when it misses. tNear may be negative.
inline bool flame_bounds_intersect(float3 o, float3 d, float r, float yMin, float yMax,
                                   thread float &tNear, thread float &tFar) {
    float a = dot(d.xz, d.xz);
    float tEnter = -1e9f;
    float tExit = 1e9f;
    if (a > 1e-8f) {
        float b = dot(o.xz, d.xz);
        float c = dot(o.xz, o.xz) - r * r;
        float disc = b * b - a * c;
        if (disc < 0.0f) {
            return false;
        }
        float s = sqrt(disc);
        tEnter = (-b - s) / a;
        tExit = (-b + s) / a;
    } else if (dot(o.xz, o.xz) > r * r) {
        return false;
    }
    if (abs(d.y) > 1e-8f) {
        float t0 = (yMin - o.y) / d.y;
        float t1 = (yMax - o.y) / d.y;
        tEnter = max(tEnter, min(t0, t1));
        tExit = min(tExit, max(t0, t1));
    } else if (o.y < yMin || o.y > yMax) {
        return false;
    }
    tNear = tEnter;
    tFar = tExit;
    return tExit > tEnter;
}

// MARK: - Vertex

vertex FlameVaryings flame_vertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                                  device const FlameData *flames [[buffer(BufferIndexFlames)]]) {
    device const FlameData &flame = flames[iid];
    const uint verticesPerQuad = kFlameVerticesPerInstance / 2u;
    uint kind = min(vid / verticesPerQuad, 1u);
    float2 corner = flame_quad_corner(vid % verticesPerQuad);

    // Screen-aligned billboard axes (rows 0 and 1 of the view matrix).
    float3 right = float3(u.viewMatrix[0][0], u.viewMatrix[1][0], u.viewMatrix[2][0]);
    float3 up = float3(u.viewMatrix[0][1], u.viewMatrix[1][1], u.viewMatrix[2][1]);

    float height = max(flame.height, 0.0f);
    float width = max(flame.width, 0.0f);
    float bottom = (kind == 0u) ? kFlameQuadBottom * height : 0.0f;
    float top = (kind == 0u) ? kFlameQuadTop * height : kHeatQuadTop * height;
    float halfWidth = (kind == 0u) ? kFlameQuadHalfWidth * width : kHeatQuadHalfWidth * width;
    float halfHeight = 0.5f * (top - bottom);
    float3 center = flame.position + float3(0.0f, 0.5f * (top + bottom), 0.0f);

    // Unlit flames collapse to a point (no fragments).
    float lit = (flame.intensity > 0.0f && height > 0.0f && width > 0.0f) ? 1.0f : 0.0f;
    float3 world = center + (right * (corner.x * halfWidth) + up * ((corner.y * 2.0f - 1.0f) * halfHeight)) * lit;

    FlameVaryings out;
    out.position = u.viewProjection * float4(world, 1.0f);
    out.worldPosition = world;
    out.quadCoord = corner;
    out.flameIndex = iid;
    out.kind = kind;
    return out;
}

// MARK: - Fragment

fragment FlameOut flame_fragment(FlameVaryings in [[stage_in]],
                                 float4 fragCoord [[position]],
                                 constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                                 device const FlameData *flames [[buffer(BufferIndexFlames)]]) {
    device const FlameData &flame = flames[in.flameIndex];
    FlameOut out;
    out.color = float4(0.0f);
    out.heat = float4(0.0f);

    float height = max(flame.height, 1e-4f);
    float width = max(flame.width, 1e-4f);
    float strength = max(flame.intensity, 0.0f) * max(u.flameIntensity, 0.0f);
    if (strength <= 0.0f) {
        return out;
    }
    uint seed = u.seedLo ^ (in.flameIndex * 0x9E3779B9u);

    if (in.kind == 1u) {
        // Heat plume: evaluated in the billboard's own coordinates (x across in metres,
        // h up in flame heights), so it is independent of the billboard's tilt.
        float across = in.quadCoord.x * (kHeatQuadHalfWidth * width);
        float h = in.quadCoord.y * kHeatQuadTop;                  // 0 … 3
        float plumeHalfWidth = width * (1.0f + kHeatSpread * h);
        float sway = fbm3(float3(h * 1.5f - u.time * kHeatRiseRate, float(in.flameIndex) * 1.7f, 0.29f), 2u, seed + 13u)
                   * (kHeatSwayAmplitude * width * h);
        float radial = (across - sway) / max(plumeHalfWidth, 1e-4f);
        float profile = exp(-radial * radial);
        float vertical = smoothstep(0.0f, 0.3f, h) * (1.0f - smoothstep(1.4f, 3.0f, h));
        float breath = 0.85f + 0.15f * fbm3(float3(0.0f, h * 2.0f - u.time * kHeatRiseRate, float(in.flameIndex)), 2u, seed + 29u);
        out.heat = float4(kHeatStrength * strength * profile * vertical * breath, 0.0f, 0.0f, 0.0f);
        return out;
    }

    // Flame: march the view ray through the bounding cylinder in flame-local space.
    float3 cameraLocal = u.cameraPosition - flame.position;
    float3 dir = safe_normalize(in.worldPosition - u.cameraPosition, float3(0.0f, 0.0f, -1.0f));
    float tNear = 0.0f;
    float tFar = 0.0f;
    float boundRadius = kFlameQuadHalfWidth * width;
    if (!flame_bounds_intersect(cameraLocal, dir, boundRadius, kFlameQuadBottom * height, kFlameQuadTop * height, tNear, tFar)) {
        return out;
    }
    tNear = max(tNear, 0.0f);
    if (tFar <= tNear) {
        return out;
    }

    uint2 pixel = uint2(fragCoord.xy);
    uint pixelIndex = pixel.y * uint(u.renderSize.x) + pixel.x;
    float jitter = hash_unit(hash_frame(u, u.frameIndex, pixelIndex, 5u));
    float step = (tFar - tNear) / float(kFlameMarchSteps);
    float t = tNear + jitter * step;

    float temperature = (flame.temperatureK > 0.0f) ? flame.temperatureK : kFlameDefaultTemperatureK;
    float3 tint = max(flame.color, 0.0f);
    float3 radiance = float3(0.0f);
    float transmittance = 1.0f;
    for (uint i = 0u; i < kFlameMarchSteps; ++i) {
        float3 q = cameraLocal + dir * t;
        float core = 0.0f;
        float blue = 0.0f;
        float density = flame_density(q, height, width, flame.flicker, u.time, in.flameIndex, seed, core, blue);
        if (density > 0.0f || blue > 0.0f) {
            float h = q.y / height;
            float tipCooling = 1.0f - kFlameTipCooling * smoothstep(1.0f, 1.85f, h);
            float3 bodyColor = blackbody_rgb(temperature * tipCooling + kFlameCoreBoostK * core) * tint;
            float3 emission = (bodyColor * density + kFlameBlueColor * (kFlameBlueWeight * blue)) * (kFlameEmission * strength);
            radiance += transmittance * emission * step;
            transmittance *= exp(-kFlameAbsorption * density * step);
        }
        t += step;
        if (transmittance < 1e-3f) {
            break;
        }
    }

    out.color = float4(max(radiance, 0.0f), 1.0f - transmittance);
    return out;
}
