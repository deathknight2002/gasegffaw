//
//  Froxel.metal
//  Bornless Ritual — volumetric smoke: froxel density, lighting, temporal blend and
//  front-to-back integration (RENDER_CONTRACT §2 row 7 "FroxelPass"; §4 SDF soft
//  shadows, §5 RT shadow rays; ShaderTypes.h `FroxelParams`, FROXEL_X/Y/Z,
//  TextureIndexFroxelLighting / FroxelHistory / FroxelScatter; Common.h froxel slice
//  mapping, curl / simplex noise, Henyey–Greenstein phase, blue noise).
//
//  Grid: 160×90×64 froxels over the camera frustum in texture-space uv (x right, y
//  down) with exponential slices between FroxelParams.nearZ (0.1 m) and farZ (12 m) in
//  planar view depth — `froxel_depth_from_slice` / `froxel_slice_from_depth` in
//  Common.h. Froxel (x, y, z) is centred at grid coordinate (x + ½, y + ½, z + ½); its
//  world position comes from the UN-jittered inverse view-projection (the volume must
//  not shimmer with the TAA jitter), which FrameUniforms does not carry, so FroxelPass
//  uploads a local `FroxelMatrices` block (layout mirrored in FroxelPass.swift) at
//  buffer index 20 — the first index above the ShaderTypes.h `BufferIndex` enum.
//
//  Kernels (one compute encoder, four serial dispatches; FroxelPass.swift):
//   1. froxel_density   (x, y, z) → FroxelLighting.a = density (rgb 0)
//        density = smokeDensity · (0.02 haze + incense plume + sigil smoke + daemon smoke)
//        · plume: buoyant column from FroxelParams.censerPosition, rise speed 0.4 m/s,
//          radius growing with height, density falling with height, advected by curl
//          noise of (x, y − 0.4·t, z) and drifted by the wind (windDirection · windSpeed
//          · age, age = height / rise speed);
//        · sigil smoke: FroxelParams.sigilSmoke (∝ sigilErupt) × a torus-shaped haze
//          around the sigil rings (SigilParams.center, radii 0.29–0.75 m), fbm-broken;
//        · daemon smoke: FroxelParams.daemonSmoke (= 4·manifest·(1 − manifest), written
//          by SceneUpdater) × a soft ellipsoid inside DaemonParams.bounds, fbm-broken.
//   2. froxel_lighting  FroxelLighting.a → FroxelScatter (rgb un-blended in-scatter,
//                       a density) — FroxelScatter is only a SCRATCH here; it is
//                       overwritten by kernel 4 before CompositePass reads it.
//        in-scatter = Σ_lights I_light · HG(cos θ, g = anisotropy) · V / (d² + r²) · density
//                     + ambient_radiance · ambientScatter · density
//        Visibility is estimated with ONE shadow ray per froxel per frame: a light is
//        chosen with probability ∝ the luminance of its unshadowed contribution and
//        traced (RT: RT.h `rtShadowRay` from the froxel centre jittered by blue noise
//        within the froxel toward a sampled point on the emitter; fallback: a 16-step
//        SDF cone march toward the same point). The estimator
//            S = Σ_i c_i − c_chosen · (1 − V_chosen) / P(chosen)
//        is unbiased for Σ_i c_i · V_i (the expectation of the subtracted term is the
//        occluded light) and has ZERO variance wherever nothing is occluded, so the
//        temporal blend only has to average the shadowed regions; it is clamped ≥ 0.
//   3. froxel_temporal  FroxelScatter (scratch) + FroxelHistory → FroxelLighting
//                       (rgb in-scatter, a = σ_t = density · extinctionScale)
//        The froxel centre is reprojected through FrameUniforms.prevViewProjection to
//        the previous grid, the history is fetched trilinearly and blended with weight
//        FroxelMatrices.temporal.x — FroxelPass resolves it to
//        min(historyBlend (0.92), n / (n + 1)) where n = frames since the history reset,
//        so warm-up frames form an exact running mean before the exponential window
//        takes over — or 0 when the previous position lies outside the previous
//        frustum / slice range, when historyValid is 0, or when the history is NaN.
//   4. froxel_integrate one thread per (x, y) column marching z front to back:
//        per slice T *= exp(−σ_t Δs), S += T · J · (1 − exp(−σ_t Δs)) / σ_t with
//        J = in-scatter and Δs the ray length through the slice (planar Δz times the
//        pixel ray's 1 / cos factor), writing FroxelScatter[k] = (S, T) at the CENTRE
//        of slice k — the convention Composite.metal samples with `froxel_coordinate`.
//
//  Robustness: an unwritten FroxelParams (all zeros — SceneUpdater is another job)
//  resolves to the documented defaults (0.1 m / 12 m, g 0.55, blend 0.92, censer
//  (0, 0.9, −2.3), wind (0.35, 0.05, −0.2) · 0.06 m/s, smoke terms from FrameUniforms).
//  Empty froxels (density ≤ 1e−5) skip the light loop.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"
#include "SDF.h"
#include "RT.h"
#include "LightShading.h"

using namespace metal;
using namespace metal::raytracing;

// MARK: - Local bindings (mirrored in FroxelPass.swift)

/// Buffer index of `FroxelMatrices` — the first free index above `BufferIndex` (0…19).
#define BufferIndexFroxelMatrices 20

/// Per-frame froxel matrices and temporal weights (FroxelPass.swift `FroxelMatrices`,
/// 144 bytes: two column-major float4x4 followed by one float4).
struct FroxelMatrices {
    float4x4 invUnjitteredViewProjection;   ///< NDC (un-jittered, reversed-Z) → world
    float4x4 unjitteredViewProjection;      ///< world → NDC (un-jittered)
    float4   temporal;                      ///< x effective history blend, y frames accumulated, z historyValid, w unused
};

// MARK: - Function-constant derived switches

/// True when the pipeline is specialised for the RT path (acceleration structure bound).
constant bool kFroxelUsesRT = (kRenderPath == RENDER_PATH_RT);
/// True when the pipeline is specialised for the SDF fallback (SDF scene bound).
constant bool kFroxelUsesSDF = !kFroxelUsesRT;

// MARK: - Constants

/// Grid dimensions as floats.
constant float3 kFroxelGridSize = float3(float(FROXEL_X), float(FROXEL_Y), float(FROXEL_Z));
/// Defaults for an unwritten FroxelParams (ShaderTypes.h field comments).
constant float kDefaultNearZ = 0.1f;
constant float kDefaultFarZ = 12.0f;
constant float kDefaultAnisotropy = 0.55f;
constant float kDefaultAmbientScatter = 0.02f;
constant float kDefaultHistoryBlend = 0.92f;
constant float kDefaultExtinctionScale = 1.0f;
constant float kDefaultWindSpeed = 0.06f;
constant float3 kDefaultWindDirection = float3(0.86039f, 0.12291f, -0.49165f);   // normalize(0.35, 0.05, −0.2)
constant float3 kDefaultCenserPosition = float3(0.0f, 0.9f, -2.3f);
constant float3 kDefaultSigilCenter = float3(0.0f, 1.55f, 0.0f);
constant float3 kDefaultDaemonCenter = float3(0.0f, 1.15f, -0.25f);
constant float3 kDefaultDaemonBoundsMin = float3(-1.1f, -1.2f, -1.1f);   // relative to the centre (SceneUpdater)
constant float3 kDefaultDaemonBoundsMax = float3(1.1f, 1.35f, 1.1f);

/// Density terms (per unit smokeDensity), RENDER_CONTRACT §2 row 7 (a).
constant float kHazeDensity = 0.02f;
constant float kPlumeDensity = 0.9f;            ///< peak incense density at the censer mouth
constant float kPlumeBaseRadius = 0.05f;        ///< column radius at the censer (m)
constant float kPlumeSpread = 0.14f;            ///< radius growth per metre of rise
constant float kPlumeFadeHeight = 1.4f;         ///< e-folding height of the density (m)
constant float kPlumeRiseSpeed = 0.4f;          ///< buoyant vertical speed (m/s)
constant float kPlumeMaxHeight = 3.2f;          ///< above this the plume is not evaluated
constant float kPlumeCullRadius = 1.3f;         ///< horizontal cull radius around the drifted axis
constant float kPlumeCurlAmplitude = 0.22f;     ///< curl displacement at 1 m of rise (m)
constant float kPlumeNoiseScale = 2.4f;         ///< curl-noise frequency (1/m)
constant float kPlumeNoiseEps = 0.05f;          ///< curl finite-difference step (m)
constant float kPlumeDetailScale = 5.0f;        ///< fbm detail frequency (1/m)
constant float kSigilSmokeDensity = 0.55f;
constant float kSigilTorusMajor = 0.52f;        ///< mid-way between ring 4 (0.29) and ring 0 (0.75)
constant float kSigilTorusFalloff = 0.30f;      ///< Gaussian radius around the torus circle (m)
constant float kSigilSmokeLift = 0.12f;         ///< the haze sits a little above the rings (m)
constant float kSigilCullRadius = 1.5f;
constant float kSigilRiseSpeed = 0.35f;
constant float kDaemonSmokeDensity = 1.2f;
constant float kDaemonRiseSpeed = 0.5f;
constant float kMinDensity = 1e-5f;

/// Lighting.
constant uint kFroxelSDFShadowSteps = 16u;
constant float kFroxelSDFMinStep = 0.02f;
constant float kFroxelSDFMaxStep = 0.5f;

/// Trilinear, edge-clamped sampler for the froxel history volume.
constexpr sampler kFroxelHistorySampler(filter::linear, mip_filter::none, address::clamp_to_edge);

// MARK: - Resolved parameters

/// FroxelParams with defaults substituted when the block was never written.
struct FroxelSettings {
    float nearZ;
    float farZ;
    float densityScale;
    float anisotropy;
    float ambientScatter;
    float3 windDirection;
    float windSpeed;
    float3 censerPosition;
    float historyBlend;
    float extinctionScale;
    float sigilSmoke;
    float daemonSmoke;
};

/// Reads `params`, falling back to the documented defaults (and to FrameUniforms for
/// the smoke drivers) when `farZ` is 0 — the signature of an unwritten block.
inline FroxelSettings resolve_froxel_settings(constant FroxelParams &params, constant FrameUniforms &u) {
    FroxelSettings s;
    bool written = params.farZ > 0.0f;
    s.nearZ = (written && params.nearZ > 0.0f) ? params.nearZ : kDefaultNearZ;
    s.farZ = written ? max(params.farZ, s.nearZ * 2.0f) : max(kDefaultFarZ, s.nearZ * 2.0f);
    s.densityScale = written ? max(params.densityScale, 0.0f) : max(u.smokeDensity, 0.0f);
    s.anisotropy = written ? clamp(params.anisotropy, -0.95f, 0.95f) : kDefaultAnisotropy;
    s.ambientScatter = written ? max(params.ambientScatter, 0.0f) : kDefaultAmbientScatter;
    s.windDirection = written ? safe_normalize(params.windDirection, kDefaultWindDirection) : kDefaultWindDirection;
    s.windSpeed = written ? max(params.windSpeed, 0.0f) : kDefaultWindSpeed;
    s.censerPosition = written ? params.censerPosition : kDefaultCenserPosition;
    s.historyBlend = (written && params.historyBlend > 0.0f) ? saturate(params.historyBlend) : kDefaultHistoryBlend;
    s.extinctionScale = (written && params.extinctionScale > 0.0f) ? params.extinctionScale : kDefaultExtinctionScale;
    float manifest = saturate(u.manifestT);
    s.sigilSmoke = written ? saturate(params.sigilSmoke) : saturate(u.sigilErupt);
    s.daemonSmoke = written ? max(params.daemonSmoke, 0.0f) : 4.0f * manifest * (1.0f - manifest);
    return s;
}

// MARK: - Grid ↔ world

/// World position of a continuous grid coordinate (x, y in [0, FROXEL_X/Y], z in
/// [0, FROXEL_Z]): planar view depth from the exponential slice mapping, reversed-Z
/// depth through the CAMERA's near/far planes (MathExtensions.perspectiveReversedZ,
/// not the froxel range), then the un-jittered inverse view-projection.
inline float3 froxel_world_position(float3 gridCoord, FroxelSettings s, constant FroxelMatrices &m, constant FrameUniforms &u) {
    float2 uv = gridCoord.xy / kFroxelGridSize.xy;
    float viewDepth = froxel_depth_from_slice(gridCoord.z, s.nearZ, s.farZ);
    float depth = depth_from_linear(viewDepth, u.nearPlane, u.farPlane);
    return reconstruct_world_position(uv, depth, m.invUnjitteredViewProjection);
}

/// Centre of froxel `gid`.
inline float3 froxel_center(uint3 gid, FroxelSettings s, constant FroxelMatrices &m, constant FrameUniforms &u) {
    return froxel_world_position(float3(gid) + 0.5f, s, m, u);
}

/// Linear froxel index for hashing.
inline uint froxel_index(uint3 gid) {
    return (gid.z * uint(FROXEL_Y) + gid.y) * uint(FROXEL_X) + gid.x;
}

// MARK: - Density terms

/// Incense plume density at world position `p` (see the header).
inline float plume_density(float3 p, FroxelSettings s, float time, uint seed) {
    float rise = p.y - s.censerPosition.y;
    if (rise < -0.05f || rise > kPlumeMaxHeight) {
        return 0.0f;
    }
    float height = max(rise, 0.0f);
    float age = height / kPlumeRiseSpeed;
    // Wind drift of the column axis grows with the smoke's age.
    float2 axis = s.censerPosition.xz + s.windDirection.xz * (s.windSpeed * age);
    float2 radial = p.xz - axis;
    if (dot(radial, radial) > kPlumeCullRadius * kPlumeCullRadius) {
        return 0.0f;
    }
    // Curl-noise advection of a field that rises with the smoke: (x, y − 0.4·t, z).
    // The curl of simplex noise sampled at frequency f has magnitude ≈ 2f, so it is
    // normalised to unit order before the amplitude (metres) is applied.
    float3 advected = float3(p.x, p.y - kPlumeRiseSpeed * time, p.z);
    float3 curl = curl_noise3(advected * kPlumeNoiseScale, kPlumeNoiseEps * kPlumeNoiseScale, seed);
    float3 swirl = curl / (2.0f * kPlumeNoiseScale);
    float turbulence = kPlumeCurlAmplitude * saturate(height);
    float2 displaced = radial + swirl.xz * turbulence;
    float radius = kPlumeBaseRadius + kPlumeSpread * height + 0.5f * turbulence * abs(swirl.y);
    float column = exp(-dot(displaced, displaced) / max(radius * radius, 1e-5f));
    float vertical = exp(-height / kPlumeFadeHeight) * smoothstep(-0.05f, 0.06f, rise);
    float detail = 0.65f + 0.35f * fbm3(advected * kPlumeDetailScale, 2u, seed + 41u);
    return kPlumeDensity * column * vertical * detail;
}

/// Torus-shaped haze around the sigil rings.
inline float sigil_smoke_density(float3 p, float3 center, float amount, float time, uint seed) {
    if (amount <= 0.0f) {
        return 0.0f;
    }
    float3 rel = p - center;
    if (dot(rel, rel) > kSigilCullRadius * kSigilCullRadius) {
        return 0.0f;
    }
    float2 torus = float2(length(rel.xz) - kSigilTorusMajor, (rel.y - kSigilSmokeLift) * 0.8f);
    float shell = exp(-dot(torus, torus) / (kSigilTorusFalloff * kSigilTorusFalloff));
    float3 advected = float3(p.x, p.y - kSigilRiseSpeed * time, p.z);
    float detail = 0.6f + 0.4f * fbm3(advected * 3.0f, 2u, seed + 97u);
    return kSigilSmokeDensity * amount * shell * detail;
}

/// Condensation smoke inside the daemon bounds.
inline float daemon_smoke_density(float3 p, float3 boundsMin, float3 boundsMax, float amount, float time, uint seed) {
    if (amount <= 0.0f) {
        return 0.0f;
    }
    if (any(p < boundsMin) || any(p > boundsMax)) {
        return 0.0f;
    }
    float3 center = 0.5f * (boundsMin + boundsMax);
    float3 halfExtents = max(0.5f * (boundsMax - boundsMin), float3(1e-3f));
    float3 rel = (p - center) / halfExtents;
    float radial = length(rel);
    float falloff = 1.0f - smoothstep(0.55f, 1.0f, radial);
    float3 advected = float3(p.x, p.y - kDaemonRiseSpeed * time, p.z);
    float noise = fbm3(advected * 2.0f, 3u, seed + 211u);
    return kDaemonSmokeDensity * amount * falloff * saturate(0.55f + 0.6f * noise);
}

// MARK: - Shadowing

/// 16-step SDF cone march toward a light of `lightRadius` at distance `maxT` along
/// `dir` (the 48-step SDF.h `sdfSoftShadow` is too expensive per froxel). Same
/// penumbra estimate: visibility = min(h / coneRadius(t)).
inline float froxel_sdf_visibility(float3 origin, float3 dir, float maxT, float lightRadius, constant SDFScene &scene) {
    float visibility = 1.0f;
    float t = kFroxelSDFMinStep;
    for (uint i = 0u; i < kFroxelSDFShadowSteps; ++i) {
        if (t >= maxT) {
            break;
        }
        float h = sdSceneDistance(origin + dir * t, scene);
        if (h < 1e-4f) {
            return 0.0f;
        }
        float coneRadius = max(lightRadius * t / max(maxT, 1e-3f), 1e-4f);
        visibility = min(visibility, saturate(h / coneRadius));
        if (visibility < 1e-3f) {
            return 0.0f;
        }
        t += clamp(h, kFroxelSDFMinStep, kFroxelSDFMaxStep);
    }
    return saturate(visibility);
}

/// Point on the emitter's surface for two uniforms (sphere / daemon: uniform on the
/// sphere; ring: uniform angles on the torus).
inline float3 froxel_light_sample(LightData light, float2 xi) {
    if (light.type == LIGHT_TYPE_RING) {
        return sample_ring_light(light.position, max(light.ringRadius, 1e-3f), max(light.radius, 1e-3f), xi);
    }
    return sample_sphere_light(light.position, max(light.radius, 1e-3f), xi);
}

/// Unshadowed in-scatter contribution of `light` at `position` for the view direction
/// `viewDir` (camera → froxel): I · HG(cos θ) / (d² + r²) · density.
inline float3 froxel_light_contribution(LightData light, float3 position, float3 viewDir, float anisotropy, float density) {
    if (light.type == LIGHT_TYPE_AMBIENT) {
        return float3(0.0f);
    }
    float3 toLight = light.position - position;
    float d2 = dot(toLight, toLight);
    float3 lightDir = safe_normalize(toLight, -viewDir);
    float bound = light_bounding_radius(light);
    float phase = henyey_greenstein(dot(viewDir, lightDir), anisotropy);
    return light_color(light) * (phase * density / max(d2 + bound * bound, 1e-6f));
}

// MARK: - Kernel 1: density

kernel void froxel_density(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                           constant FroxelParams &params [[buffer(BufferIndexFroxelParams)]],
                           constant SigilParams &sigil [[buffer(BufferIndexSigilParams)]],
                           constant DaemonParams &daemon [[buffer(BufferIndexDaemonParams)]],
                           constant FroxelMatrices &matrices [[buffer(BufferIndexFroxelMatrices)]],
                           texture3d<float, access::write> outLighting [[texture(TextureIndexFroxelLighting)]],
                           uint3 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(FROXEL_X) || gid.y >= uint(FROXEL_Y) || gid.z >= uint(FROXEL_Z)) return;

    FroxelSettings s = resolve_froxel_settings(params, u);
    float3 p = froxel_center(gid, s, matrices, u);
    uint seed = u.seedLo ^ 0x0F0F0F0Fu;

    // Sigil centre / daemon bounds with fallbacks for unwritten parameter blocks.
    float3 sigilCenter = (sigil.center.y > 0.0f) ? sigil.center : kDefaultSigilCenter;
    bool daemonWritten = any(daemon.boundsMax > daemon.boundsMin);
    float3 daemonMin = daemonWritten ? daemon.boundsMin : (kDefaultDaemonCenter + kDefaultDaemonBoundsMin);
    float3 daemonMax = daemonWritten ? daemon.boundsMax : (kDefaultDaemonCenter + kDefaultDaemonBoundsMax);

    float density = kHazeDensity;
    density += plume_density(p, s, u.time, seed);
    density += sigil_smoke_density(p, sigilCenter, s.sigilSmoke, u.time, seed);
    density += daemon_smoke_density(p, daemonMin, daemonMax, s.daemonSmoke, u.time, seed);
    density *= s.densityScale;

    outLighting.write(float4(0.0f, 0.0f, 0.0f, max(density, 0.0f)), gid);
}

// MARK: - Kernel 2: lighting

kernel void froxel_lighting(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                            device const LightData *lights [[buffer(BufferIndexLights)]],
                            constant FroxelParams &params [[buffer(BufferIndexFroxelParams)]],
                            constant FroxelMatrices &matrices [[buffer(BufferIndexFroxelMatrices)]],
                            instance_acceleration_structure accel [[buffer(BufferIndexAccel), function_constant(kFroxelUsesRT)]],
                            constant SDFScene &sdf [[buffer(BufferIndexSDFScene), function_constant(kFroxelUsesSDF)]],
                            texture2d<float, access::read> blueNoise [[texture(TextureIndexBlueNoise)]],
                            texture3d<float, access::read> densityTex [[texture(TextureIndexFroxelLighting)]],
                            texture3d<float, access::write> outScatter [[texture(TextureIndexFroxelScatter)]],
                            uint3 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(FROXEL_X) || gid.y >= uint(FROXEL_Y) || gid.z >= uint(FROXEL_Z)) return;

    float density = max(densityTex.read(gid).a, 0.0f);
    if (density <= kMinDensity) {
        outScatter.write(float4(0.0f), gid);
        return;
    }

    FroxelSettings s = resolve_froxel_settings(params, u);
    float3 center = froxel_center(gid, s, matrices, u);
    float3 viewDir = safe_normalize(center - u.cameraPosition, float3(0.0f, 0.0f, -1.0f));

    // Unshadowed contribution of every light and the selection CDF over their luminance.
    uint lightCount = min(u.lightCount, uint(MAX_LIGHTS));
    float importance[MAX_LIGHTS];
    float3 total = float3(0.0f);
    float totalImportance = 0.0f;
    for (uint i = 0u; i < uint(MAX_LIGHTS); ++i) {
        float3 contribution = (i < lightCount)
            ? froxel_light_contribution(lights[i], center, viewDir, s.anisotropy, density)
            : float3(0.0f);
        float weight = luminance(contribution);
        importance[i] = weight;
        total += contribution;
        totalImportance += weight;
    }

    float3 inScatter = total;
    if (totalImportance > 0.0f) {
        uint froxelIndex = froxel_index(gid);
        float xiSelect = hash_unit(hash_frame(u, u.frameIndex, froxelIndex, 3u));
        float target = xiSelect * totalImportance;
        uint chosen = 0xFFFFFFFFu;
        float cumulative = 0.0f;
        for (uint i = 0u; i < lightCount; ++i) {
            if (importance[i] <= 0.0f) {
                continue;
            }
            cumulative += importance[i];
            chosen = i;                       // the last positive entry absorbs float round-off at the top
            if (target < cumulative) {
                break;
            }
        }

        if (chosen != 0xFFFFFFFFu) {
            LightData light = lights[chosen];
            float selectProbability = importance[chosen] / totalImportance;

            // Ray origin jittered uniformly inside the froxel (blue noise, decorrelated per slice).
            uint2 noiseCoord = gid.xy + uint2(gid.z * 13u, gid.z * 29u);
            float4 noise = blue_noise_sample(blueNoise, noiseCoord, u.frameIndex);
            float3 origin = froxel_world_position(float3(gid) + noise.xyz, s, matrices, u);
            float2 xi = float2(noise.w, hash_unit(hash_frame(u, u.frameIndex, froxelIndex, 4u)));
            float3 lightPoint = froxel_light_sample(light, xi);
            float3 toTarget = lightPoint - origin;
            float distance = length(toTarget);
            float visibility = 1.0f;
            if (distance > 1e-4f) {
                float3 dir = toTarget / distance;
                float maxT = max(distance - max(light.radius, 0.0f) - kRTOriginOffset, kRTOriginOffset);
                if (kFroxelUsesSDF) {
                    visibility = froxel_sdf_visibility(origin, dir, maxT, max(light.radius, 1e-3f), sdf);
                } else {
                    visibility = rtShadowRay(accel, origin, dir, maxT) ? 0.0f : 1.0f;
                }
            }
            // Control-variate estimator: subtract the one-sample estimate of the occluded light.
            float3 chosenContribution = froxel_light_contribution(light, center, viewDir, s.anisotropy, density);
            inScatter = total - chosenContribution * ((1.0f - visibility) / max(selectProbability, 1e-6f));
            inScatter = max(inScatter, 0.0f);
        }
    }

    inScatter += ambient_radiance(u, lights) * (s.ambientScatter * density);
    outScatter.write(float4(inScatter, density), gid);
}

// MARK: - Kernel 3: temporal blend

kernel void froxel_temporal(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                            constant FroxelParams &params [[buffer(BufferIndexFroxelParams)]],
                            constant FroxelMatrices &matrices [[buffer(BufferIndexFroxelMatrices)]],
                            texture3d<float, access::read> currentTex [[texture(TextureIndexFroxelScatter)]],
                            texture3d<float, access::sample> historyTex [[texture(TextureIndexFroxelHistory)]],
                            texture3d<float, access::write> outLighting [[texture(TextureIndexFroxelLighting)]],
                            uint3 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(FROXEL_X) || gid.y >= uint(FROXEL_Y) || gid.z >= uint(FROXEL_Z)) return;

    FroxelSettings s = resolve_froxel_settings(params, u);
    float4 current = currentTex.read(gid);
    float4 value = float4(max(current.rgb, 0.0f), max(current.a, 0.0f) * s.extinctionScale);

    float blend = 0.0f;
    float4 history = float4(0.0f);
    if (u.historyValid != 0u && matrices.temporal.x > 0.0f) {
        float3 p = froxel_center(gid, s, matrices, u);
        float4 clip = u.prevViewProjection * float4(p, 1.0f);
        if (clip.w > 1e-5f) {
            float3 ndc = clip.xyz / clip.w;
            float2 prevUV = float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);
            float prevDepth = linearize_depth(ndc.z, u.nearPlane, u.farPlane);
            bool inside = all(prevUV >= float2(0.0f)) && all(prevUV <= float2(1.0f))
                       && ndc.z > 0.0f && ndc.z <= 1.0f
                       && prevDepth >= s.nearZ && prevDepth <= s.farZ;
            if (inside) {
                float prevSlice = froxel_slice_from_depth(prevDepth, s.nearZ, s.farZ) / kFroxelGridSize.z;
                history = historyTex.sample(kFroxelHistorySampler, float3(prevUV, prevSlice));
                bool finite = !any(isnan(history)) && !any(isinf(history));
                if (finite) {
                    blend = saturate(matrices.temporal.x);
                    history = max(history, 0.0f);
                }
            }
        }
    }

    float4 blended = mix(value, history, blend);
    outLighting.write(blended, gid);
}

// MARK: - Kernel 4: front-to-back integration

kernel void froxel_integrate(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                             constant FroxelParams &params [[buffer(BufferIndexFroxelParams)]],
                             texture3d<float, access::read> lightingTex [[texture(TextureIndexFroxelLighting)]],
                             texture3d<float, access::write> outScatter [[texture(TextureIndexFroxelScatter)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(FROXEL_X) || gid.y >= uint(FROXEL_Y)) return;

    FroxelSettings s = resolve_froxel_settings(params, u);

    // Ray length per unit of planar depth for this column: |(x·tanX, y·tanY, 1)|.
    float2 uv = (float2(gid) + 0.5f) / kFroxelGridSize.xy;
    float2 ndc = float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
    float tanX = 1.0f / max(u.projectionMatrix[0][0], 1e-4f);
    float tanY = 1.0f / max(u.projectionMatrix[1][1], 1e-4f);
    float rayScale = sqrt(1.0f + sqr(ndc.x * tanX) + sqr(ndc.y * tanY));

    float3 scattered = float3(0.0f);
    float transmittance = 1.0f;
    float front = froxel_depth_from_slice(0.0f, s.nearZ, s.farZ);
    for (uint k = 0u; k < uint(FROXEL_Z); ++k) {
        float4 texel = lightingTex.read(uint3(gid, k));
        float sigma = max(texel.a, 0.0f);
        float3 source = max(texel.rgb, 0.0f);
        float centerDepth = froxel_depth_from_slice(float(k) + 0.5f, s.nearZ, s.farZ);
        float back = froxel_depth_from_slice(float(k) + 1.0f, s.nearZ, s.farZ);

        // Front boundary → centre, then write the value Composite samples at this slice.
        float ds0 = max(centerDepth - front, 0.0f) * rayScale;
        float od0 = sigma * ds0;
        float tr0 = exp(-od0);
        float weight0 = (sigma > 1e-5f) ? (1.0f - tr0) / sigma : ds0;
        scattered += transmittance * source * weight0;
        transmittance *= tr0;
        outScatter.write(float4(scattered, transmittance), uint3(gid, k));

        // Centre → back boundary.
        float ds1 = max(back - centerDepth, 0.0f) * rayScale;
        float od1 = sigma * ds1;
        float tr1 = exp(-od1);
        float weight1 = (sigma > 1e-5f) ? (1.0f - tr1) / sigma : ds1;
        scattered += transmittance * source * weight1;
        transmittance *= tr1;
        front = back;
    }
}
