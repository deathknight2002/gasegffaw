//
//  ProceduralTextures.metal
//  Bornless Ritual — startup texture synthesis (RENDER_CONTRACT §2 row 1
//  "ProceduralTexturePass": seed → albedo/normal atlases (7 layers, 1024², mipmapped by
//  blit), blue noise 128², chalk mask 2048²; §6 kernel naming `proctex_*`).
//
//  Role: five compute kernels driven by Render/Scene/ProceduralTexturePass.swift:
//    proctex_material        one dispatch per MaterialTextureLayer: writes the albedo
//                            atlas layer (rgb = albedo multiplier, a = 1) and a scratch
//                            surface texture (r roughness multiplier, g height, b slope
//                            scale) — TextureGenParams selects the layer.
//    proctex_normals         height → tangent-space normal by central differences (wrapped),
//                            writes the normal atlas layer: xy = normal·0.5+0.5, z = roughness
//                            multiplier, w = height.
//    proctex_bluenoise_init  white noise from the hash (four channels).
//    proctex_bluenoise_swap  one deterministic simulated-annealing swap pass (see below).
//    proctex_chalk           chalk decal mask: double circle + hand-drawn strokes from a
//                            ChalkSegment buffer (name letters and quarter ticks).
//
//  Atlas convention (Materials.swift / GBuffer.metal): the atlases hold *multipliers*.
//  Every layer keeps its albedo multiplier plateau near 0.92 and its roughness multiplier
//  mean near 0.93; MaterialData carries the physical targets divided by those means.
//  All noise here is periodic on the tile (integer cells per tile, lattice hashed modulo
//  the period) so the atlases wrap seamlessly; everything derives from the seed through
//  `hash_u32`, so a given seed always produces the same textures.
//
//  Blue noise: an approximate void-and-cluster result obtained by iterative energy swaps
//  (Georgiev & Fajardo 2016, "Blue-noise dithered sampling"): starting from white noise,
//  each pass pairs every texel with a partner along one axis at a hash-chosen distance and
//  swaps their values (per channel) when the local energy
//  E = Σ_q exp(−|p−q|²/σ_i² − sqrt|v_p−v_q|/σ_s²) over a 7×7 toroidal window decreases.
//  Both texels of a pair compute the identical decision from the same source texture, so
//  the pass is race-free and bit-deterministic (ping-pong between two textures).
//
//  Locally defined structs (not in ShaderTypes.h, mirrored in Swift with identical
//  layout): `ChalkSegment` (24 bytes, HebrewStrokes.swift) and `ChalkGenParams`
//  (40 bytes, ProceduralTexturePass.swift). Binding numbers reuse enum values from
//  ShaderTypes.h only: the surface scratch sits at TextureIndexHeat, the blue-noise
//  ping-pong destination at TextureIndexHDRColor, the chalk segments at
//  BufferIndexSigilVertices (documented in the pass).
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;

// MARK: - Locally defined parameter structs (mirrored in Swift)

/// One chalk stroke in floor metres (x, z). Mirror of `ChalkSegment` in HebrewStrokes.swift.
struct ChalkSegment {
    float2 a;
    float2 b;
    float width;
    float grain;
};

/// Chalk mask generation parameters. Mirror of `ChalkGenParams` in ProceduralTexturePass.swift.
struct ChalkGenParams {
    float2 floorHalfExtents;   ///< (3, 3): world (x, z) = (uv − 0.5) · 2 · halfExtents
    float innerRadius;         ///< 1.45 m
    float outerRadius;         ///< 1.60 m
    float circleWidth;         ///< stroke width of the circles (m)
    float edgeSoftness;        ///< anti-aliasing / raggedness width (m)
    uint segmentCount;         ///< entries in the ChalkSegment buffer
    uint size;                 ///< 2048
    uint seedLo;
    uint seedHi;
};

// MARK: - Constants

/// Albedo multiplier plateau every layer is normalised to (Materials.swift).
constant float kAlbedoPlateau = 0.92f;
/// Roughness multiplier mean every layer is normalised to (Materials.swift).
constant float kRoughnessPlateau = 0.93f;

/// Blue-noise annealing constants (Georgiev & Fajardo 2016).
constant float kBlueSigmaImage = 2.1f;
constant float kBlueSigmaValue = 1.0f;
constant int kBlueWindowRadius = 3;

// MARK: - Periodic lattice noise

/// Hash of a lattice cell wrapped to `period` (tileable), keyed by the seed and a salt.
inline uint ptex_cell_hash(int2 cell, int period, uint seedLo, uint seedHi, uint salt) {
    int p = max(period, 1);
    int cx = ((cell.x % p) + p) % p;
    int cy = ((cell.y % p) + p) % p;
    return hash_u32(seedLo, seedHi, uint(cx), uint(cy), salt);
}

/// Unit gradient from a hash (uniform angle).
inline float2 ptex_gradient(uint h) {
    float angle = hash_unit(h) * kTwoPi;
    return float2(cos(angle), sin(angle));
}

/// Quintic fade.
inline float2 ptex_fade(float2 t) {
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

/// Periodic 2-D gradient (Perlin) noise in roughly [−1, 1]; `p` is in cell units and
/// the lattice repeats every `period` cells.
inline float ptex_gradient_noise(float2 p, int period, uint seedLo, uint seedHi, uint salt) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = ptex_fade(f);
    int2 c = int2(i);
    float n00 = dot(ptex_gradient(ptex_cell_hash(c + int2(0, 0), period, seedLo, seedHi, salt)), f - float2(0.0f, 0.0f));
    float n10 = dot(ptex_gradient(ptex_cell_hash(c + int2(1, 0), period, seedLo, seedHi, salt)), f - float2(1.0f, 0.0f));
    float n01 = dot(ptex_gradient(ptex_cell_hash(c + int2(0, 1), period, seedLo, seedHi, salt)), f - float2(0.0f, 1.0f));
    float n11 = dot(ptex_gradient(ptex_cell_hash(c + int2(1, 1), period, seedLo, seedHi, salt)), f - float2(1.0f, 1.0f));
    float x0 = mix(n00, n10, u.x);
    float x1 = mix(n01, n11, u.x);
    return mix(x0, x1, u.y) * 1.4142f;
}

/// Periodic 2-D value noise in [−1, 1].
inline float ptex_value_noise(float2 p, int period, uint seedLo, uint seedHi, uint salt) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = ptex_fade(f);
    int2 c = int2(i);
    float n00 = hash_unit(ptex_cell_hash(c + int2(0, 0), period, seedLo, seedHi, salt));
    float n10 = hash_unit(ptex_cell_hash(c + int2(1, 0), period, seedLo, seedHi, salt));
    float n01 = hash_unit(ptex_cell_hash(c + int2(0, 1), period, seedLo, seedHi, salt));
    float n11 = hash_unit(ptex_cell_hash(c + int2(1, 1), period, seedLo, seedHi, salt));
    float x0 = mix(n00, n10, u.x);
    float x1 = mix(n01, n11, u.x);
    return mix(x0, x1, u.y) * 2.0f - 1.0f;
}

/// Periodic fbm of gradient noise, normalised to [−1, 1]. `uv` in [0,1)² tile space;
/// `frequency` is the (integer) number of cells per tile of the first octave.
inline float ptex_fbm(float2 uv, float frequency, uint octaves, float gain, uint seedLo, uint seedHi, uint salt) {
    float sum = 0.0f;
    float amplitude = 0.5f;
    float norm = 0.0f;
    float freq = max(frequency, 1.0f);
    for (uint o = 0u; o < octaves; ++o) {
        sum += amplitude * ptex_gradient_noise(uv * freq, int(freq + 0.5f), seedLo, seedHi, salt + o * 131u);
        norm += amplitude;
        freq *= 2.0f;
        amplitude *= gain;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

/// Anisotropic periodic fbm: the tile is stretched by `stretch` (cells per tile along u
/// and v independently) — brushed metal, wood-like streaks.
inline float ptex_fbm_stretched(float2 uv, float2 frequency, uint octaves, float gain, uint seedLo, uint seedHi, uint salt) {
    float sum = 0.0f;
    float amplitude = 0.5f;
    float norm = 0.0f;
    float2 freq = max(frequency, float2(1.0f));
    for (uint o = 0u; o < octaves; ++o) {
        // Different periods per axis: hash cells on a rectangular lattice by scaling the
        // v period into the x period range (cells wrap on both axes independently).
        float2 p = uv * freq;
        float2 i = floor(p);
        float2 f = p - i;
        float2 w = ptex_fade(f);
        int px = int(freq.x + 0.5f);
        int py = int(freq.y + 0.5f);
        int2 c = int2(i);
        int cx0 = ((c.x % px) + px) % px;
        int cx1 = (cx0 + 1) % px;
        int cy0 = ((c.y % py) + py) % py;
        int cy1 = (cy0 + 1) % py;
        uint s = salt + o * 131u;
        float n00 = dot(ptex_gradient(hash_u32(seedLo, seedHi, uint(cx0), uint(cy0), s)), f - float2(0.0f, 0.0f));
        float n10 = dot(ptex_gradient(hash_u32(seedLo, seedHi, uint(cx1), uint(cy0), s)), f - float2(1.0f, 0.0f));
        float n01 = dot(ptex_gradient(hash_u32(seedLo, seedHi, uint(cx0), uint(cy1), s)), f - float2(0.0f, 1.0f));
        float n11 = dot(ptex_gradient(hash_u32(seedLo, seedHi, uint(cx1), uint(cy1), s)), f - float2(1.0f, 1.0f));
        float n = mix(mix(n00, n10, w.x), mix(n01, n11, w.x), w.y) * 1.4142f;
        sum += amplitude * n;
        norm += amplitude;
        freq *= 2.0f;
        amplitude *= gain;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

// MARK: - Periodic Voronoi

/// Voronoi query result.
struct PtexVoronoi {
    float f1;           ///< distance to the nearest feature point (cell units)
    float edge;         ///< distance to the nearest cell border (cell units, IQ's second pass)
    uint id;            ///< hash of the owning cell
    float2 toCenter;    ///< vector from the query point to the owning feature point
};

/// Feature point of a wrapped cell, jittered inside it.
inline float2 ptex_voronoi_point(int2 cell, int period, float jitter, uint seedLo, uint seedHi, uint salt) {
    uint h = ptex_cell_hash(cell, period, seedLo, seedHi, salt);
    float2 r = float2(hash_unit(h), hash_unit(hash_mix_round(h, 0x51ED27u)));
    return float2(cell) + 0.5f + (r - 0.5f) * jitter;
}

/// Periodic Voronoi with border distance (Quilez, "Voronoi edges").
inline PtexVoronoi ptex_voronoi(float2 p, int period, float jitter, uint seedLo, uint seedHi, uint salt) {
    int2 base = int2(floor(p));
    float bestDistance = 1e9f;
    float2 bestOffset = float2(0.0f);
    int2 bestCell = base;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            int2 cell = base + int2(x, y);
            float2 point = ptex_voronoi_point(cell, period, jitter, seedLo, seedHi, salt);
            float2 offset = point - p;
            float d = dot(offset, offset);
            if (d < bestDistance) {
                bestDistance = d;
                bestOffset = offset;
                bestCell = cell;
            }
        }
    }
    float edge = 1e9f;
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            int2 cell = bestCell + int2(x, y);
            if (x == 0 && y == 0) {
                continue;
            }
            float2 point = ptex_voronoi_point(cell, period, jitter, seedLo, seedHi, salt);
            float2 offset = point - p;
            float2 delta = offset - bestOffset;
            float len2 = dot(delta, delta);
            if (len2 > 1e-8f) {
                float d = dot(0.5f * (bestOffset + offset), delta * rsqrt(len2));
                edge = min(edge, d);
            }
        }
    }
    PtexVoronoi result;
    result.f1 = sqrt(bestDistance);
    result.edge = max(edge, 0.0f);
    result.id = ptex_cell_hash(bestCell, period, seedLo, seedHi, salt);
    result.toCenter = bestOffset;
    return result;
}

// MARK: - Layer generators

/// Output of a layer generator for one texel.
struct ProcSurface {
    float3 albedo;      ///< albedo multiplier (plateau 0.92)
    float roughness;    ///< roughness multiplier (mean 0.93)
    float height;       ///< height in [0, 1]
    float slopeScale;   ///< height → normal slope scale for proctex_normals
};

/// Cheap per-id uniform in [0,1).
inline float ptex_id_unit(uint id, uint channel) {
    return hash_unit(hash_mix_round(id, 0xA511E9u + channel * 0x9E37u));
}

/// Floor: polished dark flagstones — irregular Voronoi cells with mortar gaps, per-stone
/// height and tint, subtle wear (lower, slightly lighter and rougher patches).
inline ProcSurface ptex_layer_floor(float2 uv, uint seedLo, uint seedHi) {
    const int cells = 6;
    PtexVoronoi v = ptex_voronoi(uv * float(cells), cells, 0.55f, seedLo, seedHi, 0x0F00u);
    float mortarWidth = 0.035f;
    float mortar = 1.0f - smoothstep(mortarWidth, mortarWidth + 0.03f, v.edge);
    float stoneTint = 0.84f + 0.16f * ptex_id_unit(v.id, 1u);
    float stoneHeight = 0.80f + 0.14f * ptex_id_unit(v.id, 2u);
    float surface = ptex_fbm(uv, 24.0f, 4u, 0.5f, seedLo, seedHi, 0x0F01u);
    float wear = smoothstep(0.15f, 0.55f, ptex_fbm(uv, 3.0f, 3u, 0.55f, seedLo, seedHi, 0x0F02u));
    float grain = ptex_value_noise(uv * 512.0f, 512, seedLo, seedHi, 0x0F03u);
    // Bevel toward the mortar so edges catch light.
    float bevel = smoothstep(mortarWidth + 0.03f, mortarWidth + 0.12f, v.edge);

    float height = stoneHeight * (0.85f + 0.15f * bevel) + 0.03f * surface - 0.05f * wear;
    height = mix(height, 0.35f + 0.05f * surface, mortar);

    float3 albedo = float3(kAlbedoPlateau * stoneTint) * (1.0f + 0.05f * surface + 0.06f * wear + 0.02f * grain);
    albedo *= float3(1.0f, 0.99f, 0.985f);
    albedo = mix(albedo, float3(0.52f, 0.50f, 0.47f), mortar);

    float roughness = 0.90f + 0.06f * surface + 0.10f * wear + 0.02f * grain;
    roughness = mix(roughness, 1.0f, mortar);

    ProcSurface out;
    out.albedo = saturate(albedo);
    out.roughness = saturate(roughness);
    out.height = saturate(height);
    out.slopeScale = 90.0f;
    return out;
}

/// Wall: rough quarried blocks in running bond with recessed mortar and fbm relief.
inline ProcSurface ptex_layer_wall(float2 uv, uint seedLo, uint seedHi) {
    const int rows = 6;
    const int columns = 3;
    float rowF = uv.y * float(rows);
    int row = int(floor(rowF));
    float shift = ((row & 1) != 0) ? 0.5f : 0.0f;
    float colF = uv.x * float(columns) + shift;
    int col = int(floor(colF));
    float2 local = float2(fract(colF), fract(rowF));
    // Distance to the block border in tile units.
    float edgeU = min(local.x, 1.0f - local.x) / float(columns);
    float edgeV = min(local.y, 1.0f - local.y) / float(rows);
    float edge = min(edgeU, edgeV);
    uint id = hash_u32(seedLo, seedHi, uint(((col % columns) + columns) % columns), uint(((row % rows) + rows) % rows), 0x0A11u);

    float mortarWidth = 0.012f;
    float mortar = 1.0f - smoothstep(mortarWidth, mortarWidth + 0.012f, edge);
    float relief = ptex_fbm(uv, 12.0f, 5u, 0.55f, seedLo, seedHi, 0x0A12u);
    float chips = ptex_fbm(uv, 48.0f, 3u, 0.5f, seedLo, seedHi, 0x0A13u);
    float blockTint = 0.86f + 0.14f * ptex_id_unit(id, 1u);
    float blockHeight = 0.70f + 0.20f * ptex_id_unit(id, 2u);
    float bevel = smoothstep(mortarWidth + 0.012f, mortarWidth + 0.06f, edge);

    float height = blockHeight * (0.8f + 0.2f * bevel) + 0.10f * relief + 0.04f * chips;
    height = mix(height, 0.30f + 0.06f * relief, mortar);

    float3 albedo = float3(kAlbedoPlateau * blockTint) * (1.0f + 0.08f * relief + 0.04f * chips);
    albedo *= float3(1.0f, 0.985f, 0.97f);
    albedo = mix(albedo, float3(0.58f, 0.56f, 0.53f), mortar);

    float roughness = 0.92f + 0.05f * relief + 0.03f * chips;
    roughness = mix(roughness, 1.0f, mortar);

    ProcSurface out;
    out.albedo = saturate(albedo);
    out.roughness = saturate(roughness);
    out.height = saturate(height);
    out.slopeScale = 60.0f;
    return out;
}

/// Cloth: plain weave — warp and weft threads alternating over/under, fibre noise.
inline ProcSurface ptex_layer_cloth(float2 uv, uint seedLo, uint seedHi) {
    const float threads = 48.0f;
    float2 t = uv * threads;
    int2 cell = int2(floor(t));
    bool warpOnTop = ((cell.x + cell.y) & 1) == 0;
    // Thread cross-section profiles (0 at the gap between threads, 1 at the crest).
    float warp = sqrt(max(sin(kPi * fract(t.x)), 0.0f));
    float weft = sqrt(max(sin(kPi * fract(t.y)), 0.0f));
    float top = warpOnTop ? warp : weft;
    float under = warpOnTop ? weft : warp;
    float weave = max(top, under * 0.75f);
    float fibre = ptex_fbm_stretched(uv, float2(64.0f, 512.0f), 3u, 0.5f, seedLo, seedHi, 0x0C10u) * (warpOnTop ? 1.0f : 0.0f)
                + ptex_fbm_stretched(uv, float2(512.0f, 64.0f), 3u, 0.5f, seedLo, seedHi, 0x0C11u) * (warpOnTop ? 0.0f : 1.0f);
    float fold = ptex_fbm(uv, 4.0f, 3u, 0.5f, seedLo, seedHi, 0x0C12u);

    float height = 0.35f + 0.45f * weave + 0.06f * fibre + 0.08f * fold;
    float3 albedo = float3(kAlbedoPlateau) * (0.92f + 0.10f * weave + 0.05f * fibre + 0.04f * fold);
    float roughness = 0.93f + 0.04f * fibre - 0.03f * (weave - 0.5f);

    ProcSurface out;
    out.albedo = saturate(albedo);
    out.roughness = saturate(roughness);
    out.height = saturate(height);
    out.slopeScale = 25.0f;
    return out;
}

/// Wax: subtle mottling, faint vertical drip runs, slightly varying gloss.
inline ProcSurface ptex_layer_wax(float2 uv, uint seedLo, uint seedHi) {
    float mottle = ptex_fbm(uv, 3.0f, 4u, 0.5f, seedLo, seedHi, 0x0D10u);
    float fine = ptex_fbm(uv, 32.0f, 3u, 0.5f, seedLo, seedHi, 0x0D11u);
    // Drips: streaks stretched along v (the candle axis).
    float drips = ptex_fbm_stretched(uv, float2(24.0f, 2.0f), 3u, 0.5f, seedLo, seedHi, 0x0D12u);
    float dripMask = smoothstep(0.25f, 0.6f, drips) * smoothstep(0.35f, 0.75f, uv.y);

    float height = 0.5f + 0.06f * mottle + 0.02f * fine + 0.10f * dripMask;
    float3 albedo = float3(kAlbedoPlateau) * (1.0f + 0.04f * mottle + 0.015f * fine) * float3(1.0f, 1.0f - 0.01f * mottle, 1.0f - 0.03f * mottle);
    float roughness = 0.93f + 0.06f * mottle + 0.03f * fine - 0.08f * dripMask;

    ProcSurface out;
    out.albedo = saturate(albedo);
    out.roughness = saturate(roughness);
    out.height = saturate(height);
    out.slopeScale = 30.0f;
    return out;
}

/// Skin: pore-scale cellular dents, micro wrinkles, mild reddish colour variation.
inline ProcSurface ptex_layer_skin(float2 uv, uint seedLo, uint seedHi) {
    const int poreCells = 96;
    PtexVoronoi pores = ptex_voronoi(uv * float(poreCells), poreCells, 0.9f, seedLo, seedHi, 0x0E10u);
    float pore = 1.0f - smoothstep(0.08f, 0.30f, pores.f1);
    float poreDepth = 0.3f + 0.7f * ptex_id_unit(pores.id, 1u);
    float wrinkles = ptex_fbm_stretched(uv, float2(128.0f, 32.0f), 3u, 0.5f, seedLo, seedHi, 0x0E11u);
    float blotch = ptex_fbm(uv, 4.0f, 3u, 0.5f, seedLo, seedHi, 0x0E12u);
    float micro = ptex_fbm(uv, 64.0f, 3u, 0.5f, seedLo, seedHi, 0x0E13u);

    float height = 0.55f - 0.12f * pore * poreDepth + 0.04f * wrinkles + 0.03f * micro;
    float3 albedo = float3(kAlbedoPlateau) * (1.0f + 0.04f * blotch + 0.02f * micro)
                  * float3(1.0f, 1.0f - 0.05f * max(blotch, 0.0f) - 0.03f * pore, 1.0f - 0.07f * max(blotch, 0.0f) - 0.04f * pore);
    float roughness = 0.93f + 0.05f * pore + 0.03f * micro - 0.02f * blotch;

    ProcSurface out;
    out.albedo = saturate(albedo);
    out.roughness = saturate(roughness);
    out.height = saturate(height);
    out.slopeScale = 20.0f;
    return out;
}

/// Altar stone: rough-cut block face with chisel marks (directional streaks) and fbm relief.
inline ProcSurface ptex_layer_altar(float2 uv, uint seedLo, uint seedHi) {
    float relief = ptex_fbm(uv, 8.0f, 5u, 0.5f, seedLo, seedHi, 0x0B10u);
    float wobble = ptex_fbm(uv, 6.0f, 2u, 0.5f, seedLo, seedHi, 0x0B11u);
    // Chisel marks: ridged sine bands with a slight noise-driven skew, angled 20°.
    float2 dir = float2(cos(0.35f), sin(0.35f));
    float band = dot(uv, dir) * 28.0f + 0.35f * wobble;
    float chisel = abs(fract(band) * 2.0f - 1.0f);
    chisel = smoothstep(0.2f, 0.9f, chisel);
    float chiselMask = smoothstep(0.1f, 0.5f, ptex_fbm(uv, 3.0f, 2u, 0.5f, seedLo, seedHi, 0x0B12u));
    float grain = ptex_value_noise(uv * 512.0f, 512, seedLo, seedHi, 0x0B13u);

    float height = 0.55f + 0.18f * relief + 0.10f * chisel * chiselMask + 0.02f * grain;
    float3 albedo = float3(kAlbedoPlateau) * (1.0f + 0.07f * relief + 0.04f * chisel * chiselMask + 0.02f * grain)
                  * float3(1.0f, 0.99f, 0.975f);
    float roughness = 0.92f + 0.05f * relief + 0.03f * grain;

    ProcSurface out;
    out.albedo = saturate(albedo);
    out.roughness = saturate(roughness);
    out.height = saturate(height);
    out.slopeScale = 45.0f;
    return out;
}

/// Iron: brushed streaks along u, sparse pits, dark oxide blotches.
inline ProcSurface ptex_layer_iron(float2 uv, uint seedLo, uint seedHi) {
    float brush = ptex_fbm_stretched(uv, float2(2.0f, 256.0f), 4u, 0.6f, seedLo, seedHi, 0x0110u);
    float fineBrush = ptex_fbm_stretched(uv, float2(8.0f, 1024.0f), 2u, 0.5f, seedLo, seedHi, 0x0111u);
    PtexVoronoi pits = ptex_voronoi(uv * 40.0f, 40, 1.0f, seedLo, seedHi, 0x0112u);
    float pitSelect = step(0.82f, ptex_id_unit(pits.id, 3u));
    float pit = pitSelect * (1.0f - smoothstep(0.05f, 0.18f, pits.f1));
    float oxide = smoothstep(0.2f, 0.6f, ptex_fbm(uv, 5.0f, 3u, 0.5f, seedLo, seedHi, 0x0113u));

    float height = 0.5f + 0.05f * brush + 0.02f * fineBrush - 0.12f * pit;
    float3 albedo = float3(kAlbedoPlateau) * (1.0f + 0.06f * brush + 0.03f * fineBrush) * (1.0f - 0.35f * pit) * (1.0f - 0.15f * oxide)
                  * float3(1.0f + 0.04f * oxide, 1.0f, 1.0f - 0.03f * oxide);
    float roughness = 0.90f + 0.05f * brush + 0.12f * oxide + 0.10f * pit;

    ProcSurface out;
    out.albedo = saturate(albedo);
    out.roughness = saturate(roughness);
    out.height = saturate(height);
    out.slopeScale = 30.0f;
    return out;
}

/// Dispatches a texel to its layer generator.
inline ProcSurface ptex_layer(uint layer, float2 uv, uint seedLo, uint seedHi) {
    switch (layer) {
        case uint(MaterialTextureLayerFloorStone): return ptex_layer_floor(uv, seedLo, seedHi);
        case uint(MaterialTextureLayerWallStone): return ptex_layer_wall(uv, seedLo, seedHi);
        case uint(MaterialTextureLayerCloth): return ptex_layer_cloth(uv, seedLo, seedHi);
        case uint(MaterialTextureLayerWax): return ptex_layer_wax(uv, seedLo, seedHi);
        case uint(MaterialTextureLayerSkin): return ptex_layer_skin(uv, seedLo, seedHi);
        case uint(MaterialTextureLayerAltarStone): return ptex_layer_altar(uv, seedLo, seedHi);
        case uint(MaterialTextureLayerIron): return ptex_layer_iron(uv, seedLo, seedHi);
        default: {
            ProcSurface flat;
            flat.albedo = float3(kAlbedoPlateau);
            flat.roughness = kRoughnessPlateau;
            flat.height = 0.5f;
            flat.slopeScale = 0.0f;
            return flat;
        }
    }
}

// MARK: - Kernels: material atlases

/// One layer of the albedo atlas plus the scratch surface (roughness, height, slope scale).
kernel void proctex_material(constant TextureGenParams &params [[buffer(BufferIndexTextureGenParams)]],
                             texture2d_array<float, access::write> albedoAtlas [[texture(TextureIndexAlbedoAtlas)]],
                             texture2d<float, access::write> surfaceScratch [[texture(TextureIndexHeat)]],
                             uint2 gid [[thread_position_in_grid]]) {
    uint size = max(params.size, 1u);
    if (gid.x >= size || gid.y >= size) return;
    float2 uv = (float2(gid) + 0.5f) / float(size);
    // Per-layer seed decorrelation so layers never share lattice values.
    uint layerSeedLo = params.seedLo ^ (params.layer * 0x9E3779B9u);
    ProcSurface s = ptex_layer(params.layer, uv, layerSeedLo, params.seedHi);
    albedoAtlas.write(float4(s.albedo, 1.0f), gid, params.layer);
    surfaceScratch.write(float4(s.roughness, s.height, s.slopeScale, 0.0f), gid);
}

/// Height → tangent-space normal (central differences on the wrapped scratch), plus the
/// roughness multiplier and height, into one layer of the normal atlas.
/// Encoding matches `decode_atlas_normal` in GBuffer.metal: xy = n.xy · 0.5 + 0.5.
kernel void proctex_normals(constant TextureGenParams &params [[buffer(BufferIndexTextureGenParams)]],
                            texture2d<float, access::read> surfaceScratch [[texture(TextureIndexHeat)]],
                            texture2d_array<float, access::write> normalAtlas [[texture(TextureIndexNormalAtlas)]],
                            uint2 gid [[thread_position_in_grid]]) {
    uint size = max(params.size, 1u);
    if (gid.x >= size || gid.y >= size) return;
    float4 center = surfaceScratch.read(gid);
    uint xl = (gid.x + size - 1u) % size;
    uint xr = (gid.x + 1u) % size;
    uint yu = (gid.y + size - 1u) % size;
    uint yd = (gid.y + 1u) % size;
    float hl = surfaceScratch.read(uint2(xl, gid.y)).y;
    float hr = surfaceScratch.read(uint2(xr, gid.y)).y;
    float hu = surfaceScratch.read(uint2(gid.x, yu)).y;
    float hd = surfaceScratch.read(uint2(gid.x, yd)).y;
    // Slopes per texel; +u is +x, +v is +y (texture row), matching the mesh uv/tangent convention.
    float slope = center.z;
    float dhdu = (hr - hl) * 0.5f * slope;
    float dhdv = (hd - hu) * 0.5f * slope;
    float3 n = safe_normalize(float3(-dhdu, -dhdv, 1.0f), float3(0.0f, 0.0f, 1.0f));
    normalAtlas.write(float4(n.xy * 0.5f + 0.5f, saturate(center.x), saturate(center.y)), gid, params.layer);
}

// MARK: - Kernels: blue noise

/// White-noise start: four independent uniforms per texel from the hash.
kernel void proctex_bluenoise_init(constant TextureGenParams &params [[buffer(BufferIndexTextureGenParams)]],
                                   texture2d<float, access::write> noise [[texture(TextureIndexBlueNoise)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    uint size = max(params.size, 1u);
    if (gid.x >= size || gid.y >= size) return;
    float4 v = float4(hash_unit(params.seedLo, params.seedHi, gid.x, gid.y, 0xB10Eu),
                      hash_unit(params.seedLo, params.seedHi, gid.x, gid.y, 0xB10Fu),
                      hash_unit(params.seedLo, params.seedHi, gid.x, gid.y, 0xB110u),
                      hash_unit(params.seedLo, params.seedHi, gid.x, gid.y, 0xB111u));
    noise.write(v, gid);
}

/// Local energy of value `value` at `p` against the 7×7 toroidal neighbourhood in `src`,
/// excluding `p` itself and `exclude` (the swap partner, whose mutual term is symmetric).
inline float4 bluenoise_energy(texture2d<float, access::read> src, uint2 p, float4 value, uint2 exclude, uint size) {
    float4 energy = float4(0.0f);
    float invSigmaImage2 = 1.0f / (kBlueSigmaImage * kBlueSigmaImage);
    float invSigmaValue2 = 1.0f / (kBlueSigmaValue * kBlueSigmaValue);
    for (int dy = -kBlueWindowRadius; dy <= kBlueWindowRadius; ++dy) {
        for (int dx = -kBlueWindowRadius; dx <= kBlueWindowRadius; ++dx) {
            if (dx == 0 && dy == 0) {
                continue;
            }
            uint qx = uint((int(p.x) + dx + int(size)) % int(size));
            uint qy = uint((int(p.y) + dy + int(size)) % int(size));
            if (qx == exclude.x && qy == exclude.y) {
                continue;
            }
            float4 neighbour = src.read(uint2(qx, qy));
            float spatial = exp(-float(dx * dx + dy * dy) * invSigmaImage2);
            float4 valueTerm = exp(-sqrt(abs(value - neighbour)) * invSigmaValue2);
            energy += spatial * valueTerm;
        }
    }
    return energy;
}

/// One deterministic swap pass: `params.layer` is the iteration index. Pairs are formed
/// along one axis at distance d (1–3, occasionally 4–7) with a per-iteration phase so
/// every texel has exactly one partner; both partners compute the same decision.
kernel void proctex_bluenoise_swap(constant TextureGenParams &params [[buffer(BufferIndexTextureGenParams)]],
                                   texture2d<float, access::read> src [[texture(TextureIndexBlueNoise)]],
                                   texture2d<float, access::write> dst [[texture(TextureIndexHDRColor)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    uint size = max(params.size, 1u);
    if (gid.x >= size || gid.y >= size) return;

    uint h = hash_u32(params.seedLo, params.seedHi, params.layer, 0xB1DEu, 0x5A17u);
    uint axis = h & 1u;
    uint distance = 1u + ((h >> 1) % 3u);
    if (((h >> 8) % 4u) == 0u) {
        distance = 4u + ((h >> 10) % 4u);
    }
    uint pairSpan = 2u * distance;
    uint phase = (h >> 16) % pairSpan;
    uint along = (axis == 0u) ? gid.x : gid.y;
    uint r = (along + phase) % pairSpan;
    bool forward = r < distance;
    uint partnerAlong = forward ? (along + distance) % size : (along + size - distance) % size;
    uint2 partner = (axis == 0u) ? uint2(partnerAlong, gid.y) : uint2(gid.x, partnerAlong);

    float4 mine = src.read(gid);
    float4 theirs = src.read(partner);
    float4 before = bluenoise_energy(src, gid, mine, partner, size) + bluenoise_energy(src, partner, theirs, gid, size);
    float4 after = bluenoise_energy(src, gid, theirs, partner, size) + bluenoise_energy(src, partner, mine, gid, size);
    // Swap the channels whose energy strictly decreases (ties keep the current value,
    // so both partners agree). The comparison is symmetric: the partner thread computes
    // the same two sums with the operands exchanged, and IEEE addition is commutative.
    float4 result = select(mine, theirs, after < before);
    dst.write(result, gid);
}

// MARK: - Kernel: chalk mask

/// Chalk coverage of a stroke of half-width `halfWidth` at distance `d`, with a ragged,
/// grainy edge (chalk on flagstone) driven by `grain`.
inline float chalk_stroke(float d, float halfWidth, float softness, float grain) {
    float ragged = halfWidth + softness * (0.6f * grain);
    return 1.0f - smoothstep(ragged - softness, ragged + softness, d);
}

/// Distance from `p` to segment [a, b].
inline float chalk_segment_distance(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float2 ap = p - a;
    float t = clamp(dot(ap, ab) / max(dot(ab, ab), 1e-8f), 0.0f, 1.0f);
    return length(ap - ab * t);
}

/// Chalk mask: 0 = bare floor, 1 = solid chalk. Texel → world (x, z) via the floor half
/// extents, matching GBuffer.metal's `uv = (x, z) / 6 + 0.5`.
kernel void proctex_chalk(constant ChalkGenParams &params [[buffer(BufferIndexTextureGenParams)]],
                          device const ChalkSegment *segments [[buffer(BufferIndexSigilVertices)]],
                          texture2d<float, access::write> mask [[texture(TextureIndexChalkMask)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint size = max(params.size, 1u);
    if (gid.x >= size || gid.y >= size) return;
    float2 uv = (float2(gid) + 0.5f) / float(size);
    float2 world = (uv - 0.5f) * 2.0f * params.floorHalfExtents;
    float radius = length(world);
    float angle = atan2(world.y, world.x);

    // Fine chalk grain (streaky, dusty) and a low-frequency pressure variation.
    float grain = value_noise3(float3(world * 420.0f, 0.37f), params.seedLo ^ 0xC4A1u);
    float pressure = 0.72f + 0.28f * (0.5f + 0.5f * value_noise3(float3(world * 9.0f, 1.7f), params.seedLo ^ 0xC4A2u));
    float streak = 0.5f + 0.5f * value_noise3(float3(world.x * 260.0f, world.y * 260.0f, 5.1f), params.seedLo ^ 0xC4A3u);

    float coverage = 0.0f;
    float halfCircle = params.circleWidth * 0.5f;
    float softness = max(params.edgeSoftness, 1e-4f);

    // Hand-drawn double circle: the radius wobbles slowly with angle.
    float wobbleInner = 0.004f * sin(angle * 5.0f + 1.3f) + 0.003f * sin(angle * 11.0f - 0.4f);
    float wobbleOuter = 0.004f * sin(angle * 7.0f + 2.9f) + 0.003f * sin(angle * 13.0f + 1.1f);
    float dInner = abs(radius - (params.innerRadius + wobbleInner));
    float dOuter = abs(radius - (params.outerRadius + wobbleOuter));
    coverage = max(coverage, chalk_stroke(dInner, halfCircle, softness, grain));
    coverage = max(coverage, chalk_stroke(dOuter, halfCircle, softness, grain));

    // Name letters and quarter ticks live between the circles; skip the loop elsewhere.
    if (radius > params.innerRadius - 0.25f && radius < params.outerRadius + 0.25f) {
        for (uint i = 0u; i < params.segmentCount; ++i) {
            ChalkSegment segment = segments[i];
            float d = chalk_segment_distance(world, segment.a, segment.b);
            if (d > segment.width + 4.0f * softness) {
                continue;
            }
            float strokeGrain = value_noise3(float3(world * 380.0f, segment.grain), params.seedLo ^ 0xC4A4u);
            coverage = max(coverage, chalk_stroke(d, segment.width * 0.5f, softness, strokeGrain));
        }
    }

    // Chalk never covers fully: powder density varies with pressure and grain streaks.
    float density = pressure * (0.70f + 0.30f * streak) * (0.85f + 0.15f * grain);
    float value = saturate(coverage * density);
    // Faint dust halo just outside the strokes.
    float dust = 0.06f * coverage * (0.5f + 0.5f * grain);
    mask.write(float4(saturate(value + dust), 0.0f, 0.0f, 1.0f), gid);
}
