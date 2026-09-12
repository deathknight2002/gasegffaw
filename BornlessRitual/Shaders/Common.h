//
//  Common.h
//  Bornless Ritual — shared MSL helpers (RENDER_CONTRACT §6 "Common.h").
//
//  Role: function-constant declarations, the CPU-identical hash, low-discrepancy
//  sequences, noise (value / gradient / fbm / curl), blackbody colour, BRDF terms,
//  phase function, reversed-Z helpers, light sampling, froxel slice mapping and
//  small numeric utilities. Every .metal file includes this after ShaderTypes.h.
//
//  Determinism (ARCHITECTURE §6): `hash_u32` is bit-identical to Swift
//  `Hash.u32(seed, a, b, c)` in RitualCore/Simulation/Deterministic.swift. Do not
//  change either without changing the other and the RitualCore pins.
//

#ifndef Common_h
#define Common_h

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Function constants (indices are part of the render contract, §1)

// Tools/metal-lint compiles headers as plain C++, where an uninitialised const is an
// error; the real Metal compiler never defines METAL_LINT, so the declarations below
// stay exactly `constant T name [[function_constant(i)]];` for the app build.
#ifdef METAL_LINT
#define BR_FUNCTION_CONSTANT_LINT_INIT = {}
#else
#define BR_FUNCTION_CONSTANT_LINT_INIT
#endif

/// 0: RENDER_PATH_RT or RENDER_PATH_FALLBACK. Pipelines are built per path.
constant uint kRenderPath [[function_constant(0)]] BR_FUNCTION_CONSTANT_LINT_INIT;
/// 1: true when MetalFX temporal upscaling is active (TAA fallback otherwise).
constant bool kMetalFX [[function_constant(1)]] BR_FUNCTION_CONSTANT_LINT_INIT;
/// 2: debug visualisation selector (0 = off); see DebugView in App/SettingsModel.swift.
constant uint kDebugView [[function_constant(2)]] BR_FUNCTION_CONSTANT_LINT_INIT;

// MARK: - Numeric constants

constant float kPi = 3.14159265358979323846f;
constant float kTwoPi = 6.28318530717958647692f;
constant float kInvPi = 0.31830988618379067154f;
constant float kInvFourPi = 0.07957747154594766788f;
/// Linear-sRGB colour of the Planckian fit at 6500 K; `blackbody_rgb` divides by it
/// so that 6500 K maps to (1,1,1). Computed offline from the Krystek fit below.
constant float3 kBlackbodyWhite6500 = float3(1.043989f, 0.983291f, 1.035941f);

// MARK: - Hashing (bit-identical to RitualCore Hash.u32)

/// One avalanche round of the lowbias32-style mix used by `Hash.u32`.
inline uint hash_mix_round(uint h, uint v) {
    h ^= v;
    h = (h ^ (h >> 16)) * 0x7FEB352Du;
    h = (h ^ (h >> 15)) * 0x846CA68Bu;
    h ^= h >> 16;
    return h;
}

/// 32-bit mix of the 64-bit seed (split into lo/hi words) and three keys.
/// h = seedLo ^ 0x9E3779B9; for v in {seedHi, a, b, c}: round(h, v).
inline uint hash_u32(uint seedLo, uint seedHi, uint a, uint b, uint c) {
    uint h = seedLo ^ 0x9E3779B9u;
    h = hash_mix_round(h, seedHi);
    h = hash_mix_round(h, a);
    h = hash_mix_round(h, b);
    h = hash_mix_round(h, c);
    return h;
}

/// Maps a hash to [0, 1). Uses the top 24 bits so the float is exact and never
/// rounds up to 1.0 (Swift `Hash.unit` divides the full word by 2^32; the two agree
/// to float precision, which is all the GPU comparisons need).
inline float hash_unit(uint h) {
    return float(h >> 8) * (1.0f / 16777216.0f);
}

/// Convenience: uniform [0,1) from (seed, a, b, c).
inline float hash_unit(uint seedLo, uint seedHi, uint a, uint b, uint c) {
    return hash_unit(hash_u32(seedLo, seedHi, a, b, c));
}

/// Two independent uniforms from one key by varying the channel key `c`.
inline float2 hash_unit2(uint seedLo, uint seedHi, uint a, uint b, uint c) {
    return float2(hash_unit(seedLo, seedHi, a, b, c),
                  hash_unit(seedLo, seedHi, a, b, c + 0x9E37u));
}

/// Three independent uniforms from one key by varying the channel key `c`.
inline float3 hash_unit3(uint seedLo, uint seedHi, uint a, uint b, uint c) {
    return float3(hash_unit(seedLo, seedHi, a, b, c),
                  hash_unit(seedLo, seedHi, a, b, c + 0x9E37u),
                  hash_unit(seedLo, seedHi, a, b, c + 0x3C6Eu));
}

/// Hash of the frame uniforms' seed with (frameIndex-or-tick, pixel/particle id, channel).
inline uint hash_frame(constant FrameUniforms &u, uint a, uint b, uint c) {
    return hash_u32(u.seedLo, u.seedHi, a, b, c);
}

// MARK: - Low-discrepancy sequences

/// Radical inverse of `index` in `base` (Halton). index 0 returns 0; callers that
/// want the sequence to start off-origin pass index + 1 (UniformBuilder does).
inline float halton(uint index, uint base) {
    float f = 1.0f;
    float r = 0.0f;
    uint i = index;
    while (i > 0u) {
        f /= float(base);
        r += f * float(i % base);
        i /= base;
    }
    return r;
}

/// Halton(2,3) 2-D point for `index`.
inline float2 halton23(uint index) {
    return float2(halton(index, 2u), halton(index, 3u));
}

/// The 16-sample jitter (pixels, centred on 0) used by UniformBuilder: sample k uses
/// Halton index k + 1 so the first sample is not the origin. Mirrors Swift exactly.
inline float2 jitter_pixels(uint frameIndex) {
    return halton23((frameIndex % 16u) + 1u) - 0.5f;
}

// MARK: - Noise

/// Lattice hash for noise: deterministic per (cell, seed). Negative cell coordinates
/// wrap through uint, which is fine for hashing.
inline uint lattice_hash(int3 cell, uint seed) {
    return hash_u32(seed, 0x5EEDu, uint(cell.x), uint(cell.y), uint(cell.z));
}

/// Quintic fade curve (Perlin's 6t^5 - 15t^4 + 10t^3).
inline float3 fade_quintic(float3 t) {
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

/// 3-D value noise in [-1, 1], smooth (quintic) trilinear interpolation of lattice values.
inline float value_noise3(float3 p, uint seed) {
    float3 i = floor(p);
    float3 f = p - i;
    float3 u = fade_quintic(f);
    int3 c = int3(i);
    float n000 = hash_unit(lattice_hash(c + int3(0, 0, 0), seed));
    float n100 = hash_unit(lattice_hash(c + int3(1, 0, 0), seed));
    float n010 = hash_unit(lattice_hash(c + int3(0, 1, 0), seed));
    float n110 = hash_unit(lattice_hash(c + int3(1, 1, 0), seed));
    float n001 = hash_unit(lattice_hash(c + int3(0, 0, 1), seed));
    float n101 = hash_unit(lattice_hash(c + int3(1, 0, 1), seed));
    float n011 = hash_unit(lattice_hash(c + int3(0, 1, 1), seed));
    float n111 = hash_unit(lattice_hash(c + int3(1, 1, 1), seed));
    float x00 = mix(n000, n100, u.x);
    float x10 = mix(n010, n110, u.x);
    float x01 = mix(n001, n101, u.x);
    float x11 = mix(n011, n111, u.x);
    float y0 = mix(x00, x10, u.y);
    float y1 = mix(x01, x11, u.y);
    return mix(y0, y1, u.z) * 2.0f - 1.0f;
}

/// Perlin's 12-direction gradient set selected by the low 4 bits of a hash.
inline float grad3_dot(uint hash, float3 p) {
    uint h = hash & 15u;
    float u = h < 8u ? p.x : p.y;
    float v = h < 4u ? p.y : ((h == 12u || h == 14u) ? p.x : p.z);
    return ((h & 1u) != 0u ? -u : u) + ((h & 2u) != 0u ? -v : v);
}

/// 3-D simplex (gradient) noise in roughly [-1, 1] (Gustavson's construction).
inline float simplex_noise3(float3 p, uint seed) {
    const float F3 = 1.0f / 3.0f;
    const float G3 = 1.0f / 6.0f;
    float s = (p.x + p.y + p.z) * F3;
    float3 i = floor(p + s);
    float t = (i.x + i.y + i.z) * G3;
    float3 x0 = p - (i - t);

    int3 i1;
    int3 i2;
    if (x0.x >= x0.y) {
        if (x0.y >= x0.z)      { i1 = int3(1, 0, 0); i2 = int3(1, 1, 0); }
        else if (x0.x >= x0.z) { i1 = int3(1, 0, 0); i2 = int3(1, 0, 1); }
        else                   { i1 = int3(0, 0, 1); i2 = int3(1, 0, 1); }
    } else {
        if (x0.y < x0.z)       { i1 = int3(0, 0, 1); i2 = int3(0, 1, 1); }
        else if (x0.x < x0.z)  { i1 = int3(0, 1, 0); i2 = int3(0, 1, 1); }
        else                   { i1 = int3(0, 1, 0); i2 = int3(1, 1, 0); }
    }

    float3 x1 = x0 - float3(i1) + G3;
    float3 x2 = x0 - float3(i2) + 2.0f * G3;
    float3 x3 = x0 - 1.0f + 3.0f * G3;
    int3 ci = int3(i);

    float n = 0.0f;
    float t0 = 0.6f - dot(x0, x0);
    if (t0 > 0.0f) { t0 *= t0; n += t0 * t0 * grad3_dot(lattice_hash(ci, seed), x0); }
    float t1 = 0.6f - dot(x1, x1);
    if (t1 > 0.0f) { t1 *= t1; n += t1 * t1 * grad3_dot(lattice_hash(ci + i1, seed), x1); }
    float t2 = 0.6f - dot(x2, x2);
    if (t2 > 0.0f) { t2 *= t2; n += t2 * t2 * grad3_dot(lattice_hash(ci + i2, seed), x2); }
    float t3 = 0.6f - dot(x3, x3);
    if (t3 > 0.0f) { t3 *= t3; n += t3 * t3 * grad3_dot(lattice_hash(ci + int3(1, 1, 1), seed), x3); }
    return 32.0f * n;
}

/// Fractal Brownian motion of simplex noise, normalised to [-1, 1].
inline float fbm3(float3 p, uint octaves, float lacunarity, float gain, uint seed) {
    float sum = 0.0f;
    float amplitude = 0.5f;
    float norm = 0.0f;
    float3 q = p;
    for (uint o = 0u; o < octaves; ++o) {
        sum += amplitude * simplex_noise3(q, seed + o * 131u);
        norm += amplitude;
        q *= lacunarity;
        amplitude *= gain;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

/// fbm with the usual lacunarity 2, gain 0.5.
inline float fbm3(float3 p, uint octaves, uint seed) {
    return fbm3(p, octaves, 2.0f, 0.5f, seed);
}

/// Vector potential for curl noise: three decorrelated simplex fields.
inline float3 noise_potential3(float3 p, uint seed) {
    return float3(simplex_noise3(p, seed),
                  simplex_noise3(p + float3(31.416f, -47.853f, 12.793f), seed + 977u),
                  simplex_noise3(p + float3(-233.7f, 118.5f, -69.2f), seed + 1789u));
}

/// Divergence-free curl noise: curl of `noise_potential3` by central finite
/// differences with step `eps` (metres in world space). Twelve noise evaluations.
inline float3 curl_noise3(float3 p, float eps, uint seed) {
    float3 dx = float3(eps, 0.0f, 0.0f);
    float3 dy = float3(0.0f, eps, 0.0f);
    float3 dz = float3(0.0f, 0.0f, eps);
    float3 px1 = noise_potential3(p + dx, seed);
    float3 px0 = noise_potential3(p - dx, seed);
    float3 py1 = noise_potential3(p + dy, seed);
    float3 py0 = noise_potential3(p - dy, seed);
    float3 pz1 = noise_potential3(p + dz, seed);
    float3 pz0 = noise_potential3(p - dz, seed);
    float inv2e = 1.0f / (2.0f * eps);
    float3 curl;
    curl.x = ((py1.z - py0.z) - (pz1.y - pz0.y)) * inv2e;
    curl.y = ((pz1.x - pz0.x) - (px1.z - px0.z)) * inv2e;
    curl.z = ((px1.y - px0.y) - (py1.x - py0.x)) * inv2e;
    return curl;
}

// MARK: - Colour

/// CIE 1931 chromaticity (x, y) of a Planckian radiator via Krystek's (1985)
/// CIE 1960 (u, v) rational fit, valid 1000–15000 K (extrapolated below 1000 K;
/// embers cool to 800 K where the fit is still monotone and deep red).
inline float2 planckian_xy(float temperatureK) {
    float T = clamp(temperatureK, 800.0f, 15000.0f);
    float T2 = T * T;
    float u = (0.860117757f + 1.54118254e-4f * T + 1.28641212e-7f * T2) /
              (1.0f + 8.42420235e-4f * T + 7.08145163e-7f * T2);
    float v = (0.317398726f + 4.22806245e-5f * T + 4.20481691e-8f * T2) /
              (1.0f - 2.89741816e-5f * T + 1.61456053e-7f * T2);
    float d = 2.0f * u - 8.0f * v + 4.0f;
    return float2(3.0f * u / d, 2.0f * v / d);
}

/// CIE XYZ (Y = 1) → linear sRGB (Rec.709 primaries, D65).
inline float3 xyz_to_linear_srgb(float3 xyz) {
    return float3( 3.2404542f * xyz.x - 1.5371385f * xyz.y - 0.4985314f * xyz.z,
                  -0.9692660f * xyz.x + 1.8760108f * xyz.y + 0.0415560f * xyz.z,
                   0.0556434f * xyz.x - 0.2040259f * xyz.y + 1.0572252f * xyz.z);
}

/// Linear-sRGB chromaticity of a blackbody at `temperatureK`, normalised so that
/// 6500 K is (1,1,1) and luminance (Y) is 1 before normalisation. Negative
/// out-of-gamut components are clamped to 0 (red end).
inline float3 blackbody_rgb(float temperatureK) {
    float2 xy = planckian_xy(temperatureK);
    float y = max(xy.y, 1e-4f);
    float3 xyz = float3(xy.x / y, 1.0f, (1.0f - xy.x - xy.y) / y);
    float3 rgb = max(xyz_to_linear_srgb(xyz), 0.0f);
    return rgb / kBlackbodyWhite6500;
}

/// Stefan–Boltzmann relative radiance (T / Tref)^4 for brightness ∝ T^4 (ARCHITECTURE §6).
inline float blackbody_relative_power(float temperatureK, float referenceK) {
    float r = temperatureK / max(referenceK, 1.0f);
    float r2 = r * r;
    return r2 * r2;
}

/// Rec.709 luminance of a linear colour.
inline float luminance(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

/// Linear → sRGB transfer (used by the tonemap kernel: Output is bgra8Unorm and
/// encoded manually because sRGB pixel formats are not compute-writable on iOS).
inline float3 linear_to_srgb(float3 c) {
    float3 lo = c * 12.92f;
    float3 hi = 1.055f * pow(max(c, 0.0f), float3(1.0f / 2.4f)) - 0.055f;
    return select(hi, lo, c <= 0.0031308f);
}

/// sRGB → linear transfer.
inline float3 srgb_to_linear(float3 c) {
    float3 lo = c / 12.92f;
    float3 hi = pow((c + 0.055f) / 1.055f, float3(2.4f));
    return select(hi, lo, c <= 0.04045f);
}

// MARK: - BRDF terms (all inputs normalised; cosines clamped by the caller)

/// GGX / Trowbridge–Reitz normal distribution, alpha = roughness².
inline float ggx_ndf(float NdotH, float alpha) {
    float a2 = alpha * alpha;
    float d = NdotH * NdotH * (a2 - 1.0f) + 1.0f;
    return a2 / max(kPi * d * d, 1e-7f);
}

/// Height-correlated Smith-GGX visibility V = G / (4 NdotL NdotV) (Heitz 2014).
inline float smith_ggx_visibility(float NdotL, float NdotV, float alpha) {
    float a2 = alpha * alpha;
    float gv = NdotL * sqrt(NdotV * NdotV * (1.0f - a2) + a2);
    float gl = NdotV * sqrt(NdotL * NdotL * (1.0f - a2) + a2);
    return 0.5f / max(gv + gl, 1e-6f);
}

/// Schlick Fresnel with scalar F0.
inline float fresnel_schlick(float VdotH, float f0) {
    float m = 1.0f - VdotH;
    float m2 = m * m;
    return f0 + (1.0f - f0) * m2 * m2 * m;
}

/// Schlick Fresnel with RGB F0.
inline float3 fresnel_schlick(float VdotH, float3 f0) {
    float m = 1.0f - VdotH;
    float m2 = m * m;
    return f0 + (1.0f - f0) * (m2 * m2 * m);
}

/// Lambert BRDF (albedo / π).
inline float3 lambert_brdf(float3 albedo) {
    return albedo * kInvPi;
}

/// Full GGX specular BRDF value (D·V·F) for the given cosines.
inline float3 ggx_specular(float NdotL, float NdotV, float NdotH, float VdotH, float roughness, float3 f0) {
    float alpha = max(roughness * roughness, 1e-3f);
    float d = ggx_ndf(NdotH, alpha);
    float v = smith_ggx_visibility(NdotL, NdotV, alpha);
    float3 f = fresnel_schlick(VdotH, f0);
    return d * v * f;
}

/// Dielectric/metal F0 from albedo and metallic (0.04 for dielectrics).
inline float3 specular_f0(float3 albedo, float metallic) {
    return mix(float3(0.04f), albedo, metallic);
}

// MARK: - Phase function

/// Henyey–Greenstein phase function; cosTheta = dot(viewDir, lightDir).
inline float henyey_greenstein(float cosTheta, float g) {
    float g2 = g * g;
    float denom = 1.0f + g2 - 2.0f * g * cosTheta;
    return kInvFourPi * (1.0f - g2) / max(denom * sqrt(denom), 1e-5f);
}

// MARK: - Reversed-Z helpers

/// View-space distance from a reversed-Z depth (1 = near, 0 = far) produced by
/// MathExtensions.perspectiveReversedZ: t = near·far / (d·(far − near) + near).
inline float linearize_depth(float depth, float nearPlane, float farPlane) {
    return nearPlane * farPlane / max(depth * (farPlane - nearPlane) + nearPlane, 1e-6f);
}

/// Reversed-Z depth for a view-space distance `t` (inverse of `linearize_depth`).
inline float depth_from_linear(float t, float nearPlane, float farPlane) {
    return (nearPlane * farPlane / max(t, 1e-6f) - nearPlane) / (farPlane - nearPlane);
}

/// World position from texture-space uv (y down), reversed-Z depth and the inverse
/// view-projection matrix.
inline float3 reconstruct_world_position(float2 uv, float depth, float4x4 invViewProjection) {
    float4 ndc = float4(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f, depth, 1.0f);
    float4 world = invViewProjection * ndc;
    return world.xyz / max(world.w, 1e-7f);
}

/// Texture-space uv (y down) of a world position under `viewProjection`; z = reversed depth.
inline float3 project_to_uv(float3 worldPosition, float4x4 viewProjection) {
    float4 clip = viewProjection * float4(worldPosition, 1.0f);
    float invW = 1.0f / max(clip.w, 1e-7f);
    float3 ndc = clip.xyz * invW;
    return float3(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f, ndc.z);
}

/// Depth is "background" (nothing rendered) when it equals the reversed-Z clear value 0.
inline bool is_background_depth(float depth) {
    return depth <= 0.0f;
}

// MARK: - Light sampling

/// Uniform direction on the unit sphere from two uniforms.
inline float3 sample_sphere_direction(float2 xi) {
    float z = 1.0f - 2.0f * xi.x;
    float r = sqrt(max(0.0f, 1.0f - z * z));
    float phi = kTwoPi * xi.y;
    return float3(r * cos(phi), r * sin(phi), z);
}

/// Uniform point on the surface of a sphere light.
inline float3 sample_sphere_light(float3 center, float radius, float2 xi) {
    return center + radius * sample_sphere_direction(xi);
}

/// Point on a horizontal ring light (major circle in the XZ plane around `center`,
/// tube radius `tubeRadius`): xi.x selects the angle on the ring, xi.y the angle
/// around the tube cross-section.
inline float3 sample_ring_light(float3 center, float majorRadius, float tubeRadius, float2 xi) {
    float theta = kTwoPi * xi.x;
    float3 radial = float3(cos(theta), 0.0f, sin(theta));
    float phi = kTwoPi * xi.y;
    float3 tube = tubeRadius * (cos(phi) * radial + sin(phi) * float3(0.0f, 1.0f, 0.0f));
    return center + majorRadius * radial + tube;
}

/// Uniform point on a disc of `radius` in the plane spanned by `tangent`, `bitangent`.
inline float3 sample_disc(float3 center, float3 tangent, float3 bitangent, float radius, float2 xi) {
    float r = radius * sqrt(xi.x);
    float phi = kTwoPi * xi.y;
    return center + r * (cos(phi) * tangent + sin(phi) * bitangent);
}

/// Cosine-weighted hemisphere direction around +Z from two uniforms.
inline float3 sample_cosine_hemisphere(float2 xi) {
    float r = sqrt(xi.x);
    float phi = kTwoPi * xi.y;
    float z = sqrt(max(0.0f, 1.0f - xi.x));
    return float3(r * cos(phi), r * sin(phi), z);
}

/// GGX-distributed half vector around +Z (alpha = roughness²).
inline float3 sample_ggx_half_vector(float2 xi, float alpha) {
    float phi = kTwoPi * xi.x;
    float cosTheta = sqrt((1.0f - xi.y) / max(1.0f + (alpha * alpha - 1.0f) * xi.y, 1e-6f));
    float sinTheta = sqrt(max(0.0f, 1.0f - cosTheta * cosTheta));
    return float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
}

/// Orthonormal basis (tangent, bitangent) around normal `n` (Duff et al. 2017).
inline void orthonormal_basis(float3 n, thread float3 &tangent, thread float3 &bitangent) {
    float s = n.z >= 0.0f ? 1.0f : -1.0f;
    float a = -1.0f / (s + n.z);
    float b = n.x * n.y * a;
    tangent = float3(1.0f + s * n.x * n.x * a, s * b, -s * n.x);
    bitangent = float3(b, s + n.y * n.y * a, -n.y);
}

/// Transforms a local (+Z up) direction into the basis around `n`.
inline float3 to_world_basis(float3 local, float3 n) {
    float3 t;
    float3 b;
    orthonormal_basis(n, t, b);
    return normalize(local.x * t + local.y * b + local.z * n);
}

// MARK: - Froxels (exponential slice distribution, FROXEL_Z slices)

/// Continuous slice coordinate in [0, FROXEL_Z] for a view distance `depth` (metres).
inline float froxel_slice_from_depth(float depth, float nearZ, float farZ) {
    float d = clamp(depth, nearZ, farZ);
    return float(FROXEL_Z) * log(d / nearZ) / log(farZ / nearZ);
}

/// View distance (metres) at continuous slice coordinate `slice` in [0, FROXEL_Z].
inline float froxel_depth_from_slice(float slice, float nearZ, float farZ) {
    return nearZ * pow(farZ / nearZ, slice / float(FROXEL_Z));
}

/// Integer slice index for a depth, clamped to [0, FROXEL_Z − 1].
inline uint froxel_slice_index(float depth, float nearZ, float farZ) {
    float s = floor(froxel_slice_from_depth(depth, nearZ, farZ));
    return uint(clamp(s, 0.0f, float(FROXEL_Z - 1)));
}

/// Froxel-grid normalised coordinate (x, y in [0,1], z = slice / FROXEL_Z) for a
/// texture-space uv and view distance, suitable for sampling the 3-D scatter texture.
inline float3 froxel_coordinate(float2 uv, float depth, float nearZ, float farZ) {
    return float3(uv, froxel_slice_from_depth(depth, nearZ, farZ) / float(FROXEL_Z));
}

// MARK: - Small utilities

/// Normalises `v`, returning `fallback` when the length is (numerically) zero.
inline float3 safe_normalize(float3 v, float3 fallback) {
    float len2 = dot(v, v);
    return len2 > 1e-12f ? v * rsqrt(len2) : fallback;
}

/// Normalises `v`, returning +Y for a zero vector.
inline float3 safe_normalize(float3 v) {
    return safe_normalize(v, float3(0.0f, 1.0f, 0.0f));
}

/// x².
inline float sqr(float x) {
    return x * x;
}

/// Smooth step remap helper: clamp((x − a) / (b − a)) with a quintic-free Hermite curve.
inline float remap01(float x, float a, float b) {
    return saturate((x - a) / max(b - a, 1e-6f));
}

/// Rotates `v` by the unit quaternion `q` (x, y, z, w) — matches simd_quatf.act.
inline float3 quat_rotate(float4 q, float3 v) {
    float3 t = 2.0f * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

/// Rotates `v` by the inverse of unit quaternion `q`.
inline float3 quat_rotate_inverse(float4 q, float3 v) {
    return quat_rotate(float4(-q.xyz, q.w), v);
}

/// True when the thread's pixel lies inside the internal render target.
inline bool pixel_in_render_bounds(uint2 gid, constant FrameUniforms &u) {
    return gid.x < uint(u.renderSize.x) && gid.y < uint(u.renderSize.y);
}

/// Pixel-centre uv for a thread id at the internal resolution.
inline float2 pixel_center_uv(uint2 gid, constant FrameUniforms &u) {
    return (float2(gid) + 0.5f) * u.invRenderSize;
}

/// Blue-noise lookup (texture is 128² and tiled); channel rotated per frame by the
/// golden-ratio sequence so temporal accumulation decorrelates.
inline float4 blue_noise_sample(texture2d<float, access::read> noise, uint2 gid, uint frameIndex) {
    uint2 coord = gid & 127u;
    float4 n = noise.read(coord);
    float shift = fract(float(frameIndex % 64u) * 0.61803398875f);
    return fract(n + shift);
}

#endif /* Common_h */
