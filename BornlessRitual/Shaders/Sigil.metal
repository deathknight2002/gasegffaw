//
//  Sigil.metal
//  Bornless Ritual — the fiery sigil: ember filament rune rings, fire sheets and the
//  closed-form spark embers (RENDER_CONTRACT §2 row 10 "SigilPass"; ARCHITECTURE §3
//  "Sigil spin", §6 ember determinism; ShaderTypes.h `SigilParams`, `RingHistoryEntry`,
//  `SigilFilamentVertex`, `EmberInstance`, BufferIndexRingHistory / SigilVertices /
//  Embers / EmberCount / DrawArgs; Common.h hash, blackbody and curl noise).
//
//  Role:
//    • `sigil_embers_reset`    (1 thread)  zeroes the live-ember counter and writes the
//                                          indirect draw arguments (vertexCount 6, 0 instances).
//    • `sigil_embers`          (grid RING_HISTORY_TICKS × EMBERS_PER_TICK_MAX) — thread
//        (age, i): spawn tick s = currentTick − age (age < EMBER_LIFETIME_TICKS), ember i,
//        ring = i % RING_COUNT. The ember is live iff the sigil has erupted and
//        hash_unit(seed, s, i, 7) < sparkRate(s) / (EMBERS_PER_TICK_MAX · 120), where
//        sparkRate(s) = Σ_r |ω_r| r_r · 40 · emberScale is read from RingHistory[s]
//        (RENDER_CONTRACT row 10 / CORE_API `SigilDynamics.sparkRate`). Its spawn state
//        reproduces RitualCore `EmberModel.spawn` exactly (same hash keys and channels:
//        θ = angle + 2π·unit(1), tangent · |ω| r · sign(ω), jitter 0.15 m/s from channels
//        2/3/4, +0.25 m/s up; channel base 16·ring), and its position is the closed form
//        of `EmberModel.position` (drag k, gravity from SigilParams) plus a curl-noise
//        turbulence displacement capped at 4 cm (ARCHITECTURE §6). Life = τ / lifetime,
//        temperature 1900 → 800 K, colour = blackbody(T) · (T/1900)⁴, size 2.5 → 1 mm.
//        Live embers are appended with an atomic counter.
//    • `sigil_embers_finalize` (1 thread)  copies the clamped counter into instanceCount.
//    • `sigil_filament_vertex/fragment`: the filament buffer is a SEGMENT LIST (two
//        `SigilFilamentVertex` per straight segment; Render/Scene/SigilFilaments.swift and
//        Render/Passes/SigilGeometry.swift both emit it). Vertex id v → segment v / 6,
//        corner v % 6. Each end is rotated about `SigilParams.center` (axis +Y) by the
//        ring's `RingHistory[tick].angle`, projected, and the segment is expanded in
//        screen space into a quad of glow half-width kFilamentHaloScale · filamentWidth
//        (never thinner than kFilamentMinHalfWidthPx) with round caps. The fragment
//        applies the glow profile — white-hot `coreColor` on the centre line falling to
//        `edgeColor` at the rim — times erupt and an 8 Hz flicker with a per-segment phase.
//    • `sigil_sheet_vertex/fragment`: one faint annular "fire sheet" per ring (instance =
//        ring) between the next ring inward and this ring, radial-gradient emission with
//        animated fbm licks rotating with the ring, so the sigil reads as fire, not neon.
//    • `sigil_ember_vertex/fragment`: instanced camera-facing quads from `EmberInstance`
//        through the indirect draw; quads never shrink below kEmberMinPixelRadius pixels
//        and the brightness is compensated by the area ratio (floored) so distant sparks
//        stay visible without blooming out.
//  All draws are additive into HDRColor (color 0) and Heat (color 1); depth test
//  greater-equal against the G-buffer (reversed-Z), no depth write — owned by SigilPass.swift.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;

// MARK: - Local layouts

/// Mirror of Metal's `MTLDrawPrimitivesIndirectArguments` (four uints, 16 bytes) living
/// at `SceneResources.emberDrawArgumentsOffset` inside the ember-count buffer. Declared
/// locally (with a distinct name) because ShaderTypes.h does not carry it; the layout is
/// identical to the framework struct the Swift side reads.
struct SigilIndirectDrawArgs {
    uint vertexCount;
    uint instanceCount;
    uint vertexStart;
    uint baseInstance;
};

// MARK: - Constants

/// Vertices per ember quad (two triangles).
constant uint kEmberQuadVertexCount = 6u;
/// Sparks per second per (rad/s · m) of rim speed (CORE_API `SigilDynamics.sparksPerRimSpeed`).
constant float kSparksPerRimSpeed = 40.0f;
/// `EmberModel.spawnJitterSpeed` (m/s, half range per component).
constant float kEmberSpawnJitterSpeed = 0.15f;
/// `EmberModel.spawnUpwardSpeed` (m/s).
constant float kEmberSpawnUpwardSpeed = 0.25f;
/// `EmberModel.tempStartK` / `tempEndK`.
constant float kEmberTempStartK = 1900.0f;
constant float kEmberTempEndK = 800.0f;
/// Ember diameter at spawn / at the end of life (metres).
constant float kEmberDiameterStart = 2.5e-3f;
constant float kEmberDiameterEnd = 1.0e-3f;
/// Turbulence: curl-noise frequency (1/m), finite-difference step (m), gain (m per unit
/// curl per second of age) and the displacement cap (ARCHITECTURE §6: ≤ 4 cm).
constant float kEmberCurlFrequency = 3.0f;
constant float kEmberCurlEps = 0.05f;
constant float kEmberCurlGain = 0.004f;
constant float kEmberCurlMaxDisplacement = 0.04f;
/// Vertical drift of the turbulence field with age (m/s), so an ember's wobble evolves.
constant float kEmberCurlDrift = 0.7f;
/// Salt for the turbulence noise lattice.
constant uint kEmberCurlSalt = 0xC0A1u;
/// Peak radiance of a freshly shed ember (linear, before exposure).
constant float kEmberRadiance = 5.0f;
/// Minimum on-screen radius of an ember quad (pixels) and the floor of the area-ratio
/// brightness compensation (so sub-pixel sparks stay visible).
constant float kEmberMinPixelRadius = 1.5f;
constant float kEmberMinCompensation = 0.25f;
/// Heat written per unit ember intensity.
constant float kEmberHeat = 0.20f;

/// Filament glow half-width as a multiple of `SigilParams.filamentWidth`.
constant float kFilamentHaloScale = 3.0f;
/// Minimum filament glow half-width on screen (pixels).
constant float kFilamentMinHalfWidthPx = 1.5f;
/// Radiance of the white-hot filament core (linear, before exposure).
constant float kFilamentRadiance = 12.0f;
/// Halo (edge colour) strength relative to the core.
constant float kFilamentHaloStrength = 0.28f;
/// Flicker frequency (Hz) and depth: intensity × (0.7 + 0.3·sin(2π·8·t + phase)).
constant float kFilamentFlickerHz = 8.0f;
/// Heat written per unit filament intensity.
constant float kFilamentHeat = 0.35f;
/// Extra brightness at full rim speed (|ω| = kFilamentSpinRef rad/s).
constant float kFilamentSpinBoost = 0.15f;
constant float kFilamentSpinRef = 8.0f;

/// Fire-sheet annulus segments (6 vertices each) and radiance (faint by design).
constant uint kSheetSegments = 48u;
constant float kSheetRadiance = 0.35f;
constant float kSheetHeat = 0.25f;
/// Innermost sheet inner radius (metres) so the fan never degenerates at the centre.
constant float kSheetCoreRadius = 0.02f;
/// Ring radii (ARCHITECTURE §3) used when RingHistory has not been written for a ring.
constant float kRingRadiusDefault[RING_COUNT] = { 0.75f, 0.62f, 0.50f, 0.39f, 0.29f };

// MARK: - Helpers

/// Row of `RingHistory` for `tick` (the ring buffer is indexed by tick % RING_HISTORY_TICKS).
inline uint ring_history_row(uint tick) {
    return (tick % uint(RING_HISTORY_TICKS)) * uint(RING_COUNT);
}

/// Rotates `p` about the vertical axis through `center` by `angle` (radians), in the
/// same sense as the ring phase (angle θ maps the rim point (cos θ, 0, sin θ)).
inline float3 rotate_about_sigil_axis(float3 p, float3 center, float angle) {
    float3 local = p - center;
    float c = cos(angle);
    float s = sin(angle);
    float3 rotated = float3(local.x * c - local.z * s, local.y, local.x * s + local.z * c);
    return center + rotated;
}

/// Pixels per metre at clip-space depth `w` for the current projection
/// (`projectionMatrix[1][1]` is 1 / tan(fovY / 2)).
inline float pixels_per_metre(constant FrameUniforms &u, float w) {
    return u.projectionMatrix[1][1] * u.renderSize.y * 0.5f / max(w, 1e-3f);
}

/// Camera right / up axes in world space (rows of the view rotation).
inline float3 camera_right(constant FrameUniforms &u) {
    return float3(u.viewMatrix[0][0], u.viewMatrix[1][0], u.viewMatrix[2][0]);
}
inline float3 camera_up(constant FrameUniforms &u) {
    return float3(u.viewMatrix[0][1], u.viewMatrix[1][1], u.viewMatrix[2][1]);
}

/// Spark shedding rate (sparks/s, ember-scaled) implied by the ring states at a history row.
inline float spark_rate_at_row(device const RingHistoryEntry *ringHistory, uint row, uint ringCount, float emberScale) {
    float rimSpeed = 0.0f;
    for (uint r = 0u; r < ringCount; ++r) {
        RingHistoryEntry entry = ringHistory[row + r];
        rimSpeed += abs(entry.omega) * entry.radius;
    }
    return rimSpeed * kSparksPerRimSpeed * emberScale;
}

/// Sign of ω as in `RingState.rotationSign` (+1, −1, or 0 at rest).
inline float rotation_sign(float omega) {
    return omega > 0.0f ? 1.0f : (omega < 0.0f ? -1.0f : 0.0f);
}

/// Bounded turbulence displacement for an ember spawned at `x0` after `tau` seconds:
/// a divergence-free curl-noise field sampled at the spawn point (drifting with age),
/// growing linearly from zero at spawn and capped at kEmberCurlMaxDisplacement.
inline float3 ember_turbulence(float3 x0, float tau, uint seedLo) {
    float3 q = x0 * kEmberCurlFrequency + float3(0.0f, tau * kEmberCurlDrift, 0.0f);
    float3 curl = curl_noise3(q, kEmberCurlEps, seedLo ^ kEmberCurlSalt);
    float3 displacement = curl * (kEmberCurlGain * tau);
    float len = length(displacement);
    if (len > kEmberCurlMaxDisplacement) {
        displacement *= kEmberCurlMaxDisplacement / len;
    }
    return displacement;
}

// MARK: - Ember compute

kernel void sigil_embers_reset(device atomic_uint *emberCount [[buffer(BufferIndexEmberCount)]],
                               device SigilIndirectDrawArgs *drawArgs [[buffer(BufferIndexDrawArgs)]],
                               uint gid [[thread_position_in_grid]]) {
    if (gid != 0u) return;
    atomic_store_explicit(emberCount, 0u, memory_order_relaxed);
    drawArgs->vertexCount = kEmberQuadVertexCount;
    drawArgs->instanceCount = 0u;
    drawArgs->vertexStart = 0u;
    drawArgs->baseInstance = 0u;
}

kernel void sigil_embers(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                         constant SigilParams &sigil [[buffer(BufferIndexSigilParams)]],
                         device const RingHistoryEntry *ringHistory [[buffer(BufferIndexRingHistory)]],
                         device EmberInstance *embers [[buffer(BufferIndexEmbers)]],
                         device atomic_uint *emberCount [[buffer(BufferIndexEmberCount)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint age = gid.x;                                   // ticks since spawn
    uint emberIndex = gid.y;
    if (age >= uint(EMBER_LIFETIME_TICKS) || emberIndex >= uint(EMBERS_PER_TICK_MAX)) return;
    if (sigil.erupt <= 0.0f || age > sigil.currentTick) return;

    uint spawnTick = sigil.currentTick - age;
    uint ringCount = clamp(sigil.ringCount, 1u, uint(RING_COUNT));
    uint row = ring_history_row(spawnTick);

    // Selection (RENDER_CONTRACT row 10): hash below the per-candidate rate at the spawn tick.
    float rate = spark_rate_at_row(ringHistory, row, ringCount, sigil.emberScale);
    float probability = rate / (float(EMBERS_PER_TICK_MAX) * float(SIM_TICK_RATE));
    float selector = hash_unit(u.seedLo, u.seedHi, spawnTick, emberIndex, 7u);
    if (selector >= probability) return;

    uint ringIndex = emberIndex % uint(RING_COUNT);
    RingHistoryEntry ring = ringHistory[row + ringIndex];
    if (ring.radius <= 0.0f) return;                    // unwritten history row

    // Spawn state — mirrors RitualCore EmberModel.spawn (hash channels 1…4, base 16·ring).
    uint channelBase = ringIndex * 16u;
    float phase = hash_unit(u.seedLo, u.seedHi, spawnTick, emberIndex, channelBase + 1u);
    float theta = ring.angle + kTwoPi * phase;
    float sinTheta = sin(theta);
    float cosTheta = cos(theta);
    float3 radial = float3(cosTheta, 0.0f, sinTheta);
    float3 tangent = float3(-sinTheta, 0.0f, cosTheta) * rotation_sign(ring.omega);
    float3 jitter = float3(hash_unit(u.seedLo, u.seedHi, spawnTick, emberIndex, channelBase + 2u) * 2.0f - 1.0f,
                           hash_unit(u.seedLo, u.seedHi, spawnTick, emberIndex, channelBase + 3u) * 2.0f - 1.0f,
                           hash_unit(u.seedLo, u.seedHi, spawnTick, emberIndex, channelBase + 4u) * 2.0f - 1.0f)
                    * kEmberSpawnJitterSpeed;
    float3 x0 = sigil.center + radial * ring.radius;
    float3 v0 = tangent * (abs(ring.omega) * ring.radius) + jitter + float3(0.0f, kEmberSpawnUpwardSpeed, 0.0f);

    // Closed-form linear-drag ballistics (EmberModel.position) + bounded turbulence.
    float tau = float(age) / float(SIM_TICK_RATE);
    float dragK = max(sigil.dragK, 1e-3f);
    float3 terminal = float3(0.0f, -sigil.gravity / dragK, 0.0f);
    float decay = (1.0f - exp(-dragK * tau)) / dragK;
    float3 position = x0 + terminal * tau + (v0 - terminal) * decay + ember_turbulence(x0, tau, u.seedLo);

    // Life, temperature, colour, size.
    float lifetime = max(sigil.lifetime, 1e-3f);
    float life = saturate(tau / lifetime);
    if (life >= 1.0f) return;
    float temperatureK = mix(kEmberTempStartK, kEmberTempEndK, life);
    float brightness = kEmberRadiance * blackbody_relative_power(temperatureK, kEmberTempStartK);

    EmberInstance ember;
    ember.position = position;
    ember.size = 0.5f * mix(kEmberDiameterStart, kEmberDiameterEnd, life);
    ember.color = blackbody_rgb(temperatureK) * brightness;
    ember.life = life;

    uint slot = atomic_fetch_add_explicit(emberCount, 1u, memory_order_relaxed);
    if (slot < uint(MAX_EMBERS)) {
        embers[slot] = ember;
    }
}

kernel void sigil_embers_finalize(device atomic_uint *emberCount [[buffer(BufferIndexEmberCount)]],
                                  device SigilIndirectDrawArgs *drawArgs [[buffer(BufferIndexDrawArgs)]],
                                  uint gid [[thread_position_in_grid]]) {
    if (gid != 0u) return;
    uint count = atomic_load_explicit(emberCount, memory_order_relaxed);
    drawArgs->vertexCount = kEmberQuadVertexCount;
    drawArgs->instanceCount = min(count, uint(MAX_EMBERS));
    drawArgs->vertexStart = 0u;
    drawArgs->baseInstance = 0u;
}

// MARK: - Shared fragment output

/// Additive outputs: HDRColor (color 0) and Heat (color 1).
struct SigilFragmentOut {
    float4 hdr  [[color(0)]];
    float  heat [[color(1)]];
};

// MARK: - Filaments

struct FilamentVaryings {
    float4 position [[position]];
    float3 color;              ///< linear radiance on the centre line (tint · glow · intensity · flicker)
    float2 profile;            ///< x: distance along the quad from a's cap tip (half-width units), y: side ∈ [−1, 1]
    float  quadLength;         ///< quad length in half-width units (segment + two round caps)
};

vertex FilamentVaryings sigil_filament_vertex(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                                              constant SigilParams &sigil [[buffer(BufferIndexSigilParams)]],
                                              device const SigilFilamentVertex *filaments [[buffer(BufferIndexSigilVertices)]],
                                              device const RingHistoryEntry *ringHistory [[buffer(BufferIndexRingHistory)]],
                                              uint vid [[vertex_id]]) {
    uint segment = vid / 6u;
    uint corner = vid % 6u;
    // Corner → (end, side): 0 (a,−) 1 (b,−) 2 (a,+) | 3 (a,+) 4 (b,−) 5 (b,+)
    bool isEndB = (corner == 1u || corner == 4u || corner == 5u);
    float side = (corner == 2u || corner == 3u || corner == 5u) ? 1.0f : -1.0f;

    SigilFilamentVertex va = filaments[segment * 2u];
    SigilFilamentVertex vb = filaments[segment * 2u + 1u];
    uint ringIndex = min(uint(max(va.ring, 0.0f)), uint(RING_COUNT - 1));
    uint row = ring_history_row(sigil.currentTick);
    RingHistoryEntry ring = ringHistory[row + ringIndex];

    float3 worldA = rotate_about_sigil_axis(va.position, sigil.center, ring.angle);
    float3 worldB = rotate_about_sigil_axis(vb.position, sigil.center, ring.angle);
    float4 clipA = u.viewProjection * float4(worldA, 1.0f);
    float4 clipB = u.viewProjection * float4(worldB, 1.0f);
    float wA = max(clipA.w, 1e-3f);
    float wB = max(clipB.w, 1e-3f);

    float2 halfSize = u.renderSize * 0.5f;
    float2 screenA = clipA.xy / wA * halfSize;
    float2 screenB = clipB.xy / wB * halfSize;
    float2 delta = screenB - screenA;
    float segmentPx = length(delta);
    float2 direction = segmentPx > 1e-4f ? delta / segmentPx : float2(1.0f, 0.0f);
    float2 normal = float2(-direction.y, direction.x);

    // Glow half-width in pixels at the segment's mean depth, never thinner than the floor;
    // brightness is compensated by the ratio so thin filaments do not brighten.
    float ppm = pixels_per_metre(u, 0.5f * (wA + wB));
    float physicalHalfPx = sigil.filamentWidth * kFilamentHaloScale * ppm;
    float halfWidthPx = max(physicalHalfPx, kFilamentMinHalfWidthPx);
    float compensation = clamp(physicalHalfPx / halfWidthPx, 0.2f, 1.0f);

    float2 screen = isEndB ? (screenB + direction * halfWidthPx) : (screenA - direction * halfWidthPx);
    screen += normal * (side * halfWidthPx);
    float w = isEndB ? wB : wA;
    float z = isEndB ? clipB.z : clipA.z;

    FilamentVaryings out;
    out.position = float4(screen / halfSize * w, z, w);
    out.profile = float2(isEndB ? (segmentPx / halfWidthPx + 2.0f) : 0.0f, side);
    out.quadLength = segmentPx / halfWidthPx + 2.0f;

    // Intensity: erupt × flicker (8 Hz, per-segment phase) × spin boost × pixel compensation.
    float flickerPhase = kTwoPi * hash_unit(u.seedLo, u.seedHi, segment, 0x51F1u, 3u);
    float flicker = 0.7f + 0.3f * sin(kTwoPi * kFilamentFlickerHz * u.time + flickerPhase);
    float spinBoost = 1.0f + kFilamentSpinBoost * saturate(abs(ring.omega) / kFilamentSpinRef);
    float intensity = kFilamentRadiance * saturate(sigil.erupt) * flicker * spinBoost * compensation
                    * max(u.flameIntensity, 0.0f);
    SigilFilamentVertex tintSource = isEndB ? vb : va;
    out.color = max(tintSource.color, 0.0f) * saturate(tintSource.glow) * intensity;
    return out;
}

fragment SigilFragmentOut sigil_filament_fragment(FilamentVaryings in [[stage_in]],
                                                  constant SigilParams &sigil [[buffer(BufferIndexSigilParams)]]) {
    // Distance from the capped centre line in half-width units (round caps at both ends).
    float along = in.profile.x;
    float capDistance = max(max(1.0f - along, along - (in.quadLength - 1.0f)), 0.0f);
    float r = length(float2(capDistance, in.profile.y));
    if (r >= 1.0f) {
        discard_fragment();
    }
    // Glow profile: white-hot core (physical filament radius = 1 / (2·halo scale) of the
    // quad) falling to the ember-orange edge colour at the rim.
    float coreWidth = 0.5f / kFilamentHaloScale + 0.06f;
    float core = exp(-sqr(r / coreWidth));
    float halo = exp(-sqr(r / 0.6f)) * (1.0f - core) * kFilamentHaloStrength;
    float3 radiance = (sigil.coreColor * core + sigil.edgeColor * halo) * in.color;
    float strength = core + halo;

    SigilFragmentOut out;
    out.hdr = float4(radiance, 1.0f);
    out.heat = kFilamentHeat * strength * saturate(luminance(in.color) / kFilamentRadiance);
    return out;
}

// MARK: - Fire sheets

struct SheetVaryings {
    float4 position [[position]];
    float3 worldPosition;
    float  innerRadius;
    float  outerRadius;
    float  ringAngle;
    float  ringIndex;
};

vertex SheetVaryings sigil_sheet_vertex(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                                        constant SigilParams &sigil [[buffer(BufferIndexSigilParams)]],
                                        device const RingHistoryEntry *ringHistory [[buffer(BufferIndexRingHistory)]],
                                        uint vid [[vertex_id]],
                                        uint iid [[instance_id]]) {
    uint ringIndex = min(iid, uint(RING_COUNT - 1));
    uint row = ring_history_row(sigil.currentTick);
    RingHistoryEntry ring = ringHistory[row + ringIndex];
    float outerRadius = ring.radius > 0.0f ? ring.radius : kRingRadiusDefault[ringIndex];
    float innerRadius = kSheetCoreRadius;
    if (ringIndex + 1u < uint(RING_COUNT)) {
        RingHistoryEntry inner = ringHistory[row + ringIndex + 1u];
        innerRadius = inner.radius > 0.0f ? inner.radius : kRingRadiusDefault[ringIndex + 1u];
    }
    innerRadius = min(innerRadius, outerRadius - 1e-3f);

    // Annulus strip: 6 vertices per segment → (angle step, inner/outer).
    uint segment = vid / 6u;
    uint corner = vid % 6u;
    bool nextAngle = (corner == 1u || corner == 4u || corner == 5u);
    bool outer = (corner == 2u || corner == 3u || corner == 5u);
    float angle = float(segment + (nextAngle ? 1u : 0u)) / float(kSheetSegments) * kTwoPi;
    float radius = outer ? outerRadius : innerRadius;
    float3 world = sigil.center + float3(cos(angle) * radius, 0.0f, sin(angle) * radius);

    SheetVaryings out;
    out.position = u.viewProjection * float4(world, 1.0f);
    out.worldPosition = world;
    out.innerRadius = innerRadius;
    out.outerRadius = outerRadius;
    out.ringAngle = ring.angle;
    out.ringIndex = float(ringIndex);
    return out;
}

fragment SigilFragmentOut sigil_sheet_fragment(SheetVaryings in [[stage_in]],
                                               constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                                               constant SigilParams &sigil [[buffer(BufferIndexSigilParams)]]) {
    float3 local = in.worldPosition - sigil.center;
    float radius = length(local.xz);
    float span = max(in.outerRadius - in.innerRadius, 1e-3f);
    float rNorm = saturate((radius - in.innerRadius) / span);

    // Noise coordinates rotate with the ring so the licks spin with the runes.
    float c = cos(-in.ringAngle);
    float s = sin(-in.ringAngle);
    float2 rotated = float2(local.x * c - local.z * s, local.x * s + local.z * c);
    uint noiseSeed = u.seedLo ^ (0x5EE7u + uint(in.ringIndex) * 131u);
    float licks = fbm3(float3(rotated * 5.0f, u.time * 1.3f), 3u, noiseSeed);
    float fire = saturate(0.55f + 0.45f * licks);

    float edge = rNorm * rNorm;                                     // brighter toward the outer ring
    float flicker = 0.85f + 0.15f * sin(kTwoPi * 6.0f * u.time + in.ringIndex * 1.7f);
    float intensity = kSheetRadiance * saturate(sigil.erupt) * (0.25f + 0.75f * edge) * fire * flicker
                    * max(u.flameIntensity, 0.0f);
    float3 color = mix(sigil.edgeColor, sigil.coreColor, edge * fire * 0.6f);

    SigilFragmentOut out;
    out.hdr = float4(color * intensity, 1.0f);
    out.heat = kSheetHeat * intensity / kSheetRadiance;
    return out;
}

// MARK: - Embers

struct EmberVaryings {
    float4 position [[position]];
    float2 local;              ///< quad coordinate in [−1, 1]²
    float3 color;              ///< radiance at the centre (compensated)
    float  life;
};

vertex EmberVaryings sigil_ember_vertex(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                                        device const EmberInstance *embers [[buffer(BufferIndexEmbers)]],
                                        uint vid [[vertex_id]],
                                        uint iid [[instance_id]]) {
    EmberInstance ember = embers[iid];
    uint corner = vid % 6u;
    // 0 (−,−) 1 (+,−) 2 (−,+) | 3 (−,+) 4 (+,−) 5 (+,+)
    float2 local = float2((corner == 1u || corner == 4u || corner == 5u) ? 1.0f : -1.0f,
                          (corner == 2u || corner == 3u || corner == 5u) ? 1.0f : -1.0f);

    float4 viewPosition = u.viewMatrix * float4(ember.position, 1.0f);
    float viewDepth = max(-viewPosition.z, 1e-3f);
    float ppm = pixels_per_metre(u, viewDepth);
    float physicalHalfPx = ember.size * ppm;
    float drawnHalfPx = max(physicalHalfPx, kEmberMinPixelRadius);
    float drawnHalf = drawnHalfPx / ppm;
    float compensation = clamp(sqr(physicalHalfPx / drawnHalfPx), kEmberMinCompensation, 1.0f);

    float3 world = ember.position + camera_right(u) * (local.x * drawnHalf) + camera_up(u) * (local.y * drawnHalf);

    EmberVaryings out;
    out.position = u.viewProjection * float4(world, 1.0f);
    out.local = local;
    out.color = ember.color * compensation * max(u.flameIntensity, 0.0f);
    out.life = ember.life;
    return out;
}

fragment SigilFragmentOut sigil_ember_fragment(EmberVaryings in [[stage_in]]) {
    float r2 = dot(in.local, in.local);
    if (r2 >= 1.0f) {
        discard_fragment();
    }
    // Soft circular falloff with a bright centre; fades out over the last 20 % of life.
    float falloff = sqr(saturate(1.0f - r2)) * (0.6f + 0.4f * exp(-r2 * 6.0f));
    float fade = 1.0f - smoothstep(0.8f, 1.0f, in.life);

    SigilFragmentOut out;
    out.hdr = float4(in.color * (falloff * fade), 1.0f);
    out.heat = kEmberHeat * falloff * fade * saturate(luminance(in.color) / kEmberRadiance);
    return out;
}
