//
//  Post.metal
//  Bornless Ritual — bloom, heat shimmer, exposure, tonemap and output encoding
//  (RENDER_CONTRACT §2 row 13 "PostPass", §1 function constant 2 `kDebugView`;
//  ShaderTypes.h `PostParams`, TextureIndexUpscaled / TextureIndexBloom0 /
//  TextureIndexHeat / TextureIndexBlueNoise / TextureIndexOutput; Common.h
//  `linear_to_srgb`, `luminance`, `simplex_noise3`, `blue_noise_sample`).
//
//  Kernels (all at native resolution or on the bloom chain, 16×16 threadgroups):
//    post_bloom_prefilter   Upscaled (native) → bloom level 0 (native/2): exposure is
//                           applied first (2^EV × 0.6, the same factor the tonemap uses),
//                           then a soft-knee threshold (threshold 1.0, knee 0.5·threshold)
//                           per tap, then the 13-tap "five overlapping 2×2 boxes"
//                           downsample of Jimenez (2014) with a partial Karis average
//                           (weights 1/(1+luma) per box) to kill fireflies.
//    post_bloom_downsample  level k → level k+1, the same 13-tap filter, no threshold.
//    post_bloom_upsample    U[k] = D[k] + tent₉(U[k+1]): 3×3 tent (1 2 1 / 2 4 2 / 1 2 1)/16
//                           sampled at the coarser level's texel spacing, additive, so
//                           U[0] is the sum of all five blurred levels.
//    post_shimmer_tonemap   Heat (internal res, bilinear) → uv offset by the gradient of
//                           animated simplex noise × heat × shimmerStrength (pixels);
//                           colour = Upscaled(uv′) × exposure + tent₉(U[0]) × bloomIntensity;
//                           vignette; ACES fitted (Narkowicz 2015); blue-noise dither
//                           ±0.5/255 in the ENCODED domain; sRGB transfer in-shader
//                           → Output, which RenderResources allocates as bgra8Unorm (not
//                           _srgb: sRGB formats are not compute-writable on iOS). The
//                           shader writes logical RGBA; Metal swizzles to BGRA memory.
//
//  Debug views: when `kDebugView ≠ 0` CompositePass writes the visualisation into
//  HDRColor as display-ready values, so the tonemap kernel bypasses shimmer, exposure,
//  bloom, vignette and tonemapping and only sRGB-encodes saturate(colour). View 14
//  (`DebugView.heat`) cannot be produced by Composite (Heat is written later) and is
//  rendered here as a greyscale of the Heat texture.
//
//  Binding roles: the bloom chain is a set of per-level texture views owned by
//  PostPass.swift; each dispatch binds one or two source levels and one destination,
//  so the kernels use ROLE slots. Every role is a `TextureIndex` value (the enum is the
//  only source of binding numbers, RENDER_CONTRACT §1) and PostPass.swift mirrors the
//  same four aliases in `PostPass.Slot`:
//    POST_SLOT_COLOR   = TextureIndexUpscaled  — the native HDR colour (prefilter source, tonemap input)
//    POST_SLOT_FINE    = TextureIndexBloom0    — the finer bloom level read (downsample source,
//                                                 upsample additive input, tonemap: final bloom U[0])
//    POST_SLOT_COARSE  = TextureIndexHDRColor  — the coarser bloom level read by the upsample
//    POST_SLOT_TARGET  = TextureIndexOutput    — whatever the kernel writes (a chain level, or Output)
//  Per-level sizes come from the bound textures (`get_width`/`get_height`), so no
//  per-dispatch parameter buffer is needed.
//
//  Determinism (ARCHITECTURE §6): the shimmer noise is keyed by the frame seed and
//  `FrameUniforms.time` (tick / 120); the dither uses `FrameUniforms.frameIndex`
//  (`PostParams.frameIndex` is left 0 by SceneUpdater).
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;

// MARK: - Binding roles (mirrored by PostPass.Slot)

#define POST_SLOT_COLOR   TextureIndexUpscaled
#define POST_SLOT_FINE    TextureIndexBloom0
#define POST_SLOT_COARSE  TextureIndexHDRColor
#define POST_SLOT_TARGET  TextureIndexOutput

// MARK: - Function-constant derived switches

/// True when a debug visualisation bypasses the photographic pipeline.
constant bool kPostDebug = (kDebugView != 0u);

// MARK: - Constants

/// `DebugView.heat` raw value (App/SettingsModel.swift).
constant uint kPostDebugViewHeat = 14u;
/// Base exposure multiplier applied on top of 2^EV.
constant float kPostExposureBase = 0.6f;
/// Bloom threshold used when `PostParams.bloomThreshold` has not been written (≤ 0).
constant float kPostDefaultBloomThreshold = 1.0f;
/// Soft-knee width as a fraction of the threshold.
constant float kPostBloomKneeRatio = 0.5f;
/// Dither amplitude: one 8-bit code in the encoded domain.
constant float kPostDitherAmplitude = 1.0f / 255.0f;
/// Vignette: radial distance (0 centre … 1 corner) where the darkening starts / saturates.
constant float kPostVignetteInner = 0.30f;
constant float kPostVignetteOuter = 1.05f;
/// Heat shimmer: noise cells across the frame height, upward drift (cells/s), pattern
/// evolution (z units/s), central-difference step, and the gain that normalises the
/// simplex gradient (|∇n| ≈ 2–3) to about ±1 before scaling by the pixel strength.
constant float kPostShimmerNoiseScale = 9.0f;
constant float kPostShimmerRiseRate = 1.6f;
constant float kPostShimmerWobbleRate = 0.7f;
constant float kPostShimmerGradientStep = 0.02f;
constant float kPostShimmerGradientGain = 0.35f;
/// Key mixed with the frame seed for the shimmer noise lattice.
constant uint kPostShimmerSeedKey = 0x5A1Cu;

/// Bilinear, edge-clamped sampler for every post fetch.
constexpr sampler kPostLinearClamp(filter::linear, mip_filter::none, address::clamp_to_edge);

// MARK: - Helpers

/// Replaces NaN components with 0 so an upstream NaN cannot become a black/white speck.
inline float3 post_nan_to_zero(float3 c) {
    return select(c, float3(0.0f), isnan(c));
}

/// Bilinear tap at `uv` offset by `offsetTexels` texels of the SOURCE texture; negative
/// values (never expected) are clamped so they cannot darken the bloom.
inline float3 post_tap(texture2d<float, access::sample> tex, float2 uv, float2 offsetTexels, float2 texel) {
    return max(tex.sample(kPostLinearClamp, uv + offsetTexels * texel, level(0)).rgb, 0.0f);
}

/// Soft-knee brightness threshold (Unity/Jimenez form): fully passes colour brighter
/// than `threshold + knee`, fades in quadratically from `threshold − knee`.
inline float3 post_bloom_threshold(float3 c, float threshold) {
    float knee = threshold * kPostBloomKneeRatio;
    float brightness = max(c.r, max(c.g, c.b));
    float soft = clamp(brightness - threshold + knee, 0.0f, 2.0f * knee);
    soft = soft * soft / max(4.0f * knee, 1e-4f);
    float contribution = max(soft, brightness - threshold) / max(brightness, 1e-4f);
    return c * contribution;
}

/// The 13 taps of the Jimenez downsample around `uv` (offsets in source texels):
///   a b c      (−2,−2) (0,−2) (2,−2)
///   d e f      (−2, 0) (0, 0) (2, 0)
///   g h i      (−2, 2) (0, 2) (2, 2)
///    j k       (−1,−1) (1,−1)
///    l m       (−1, 1) (1, 1)
struct PostDownsampleTaps {
    float3 a, b, c, d, e, f, g, h, i, j, k, l, m;
};

inline PostDownsampleTaps post_fetch_13(texture2d<float, access::sample> tex, float2 uv, float2 texel) {
    PostDownsampleTaps t;
    t.a = post_tap(tex, uv, float2(-2.0f, -2.0f), texel);
    t.b = post_tap(tex, uv, float2( 0.0f, -2.0f), texel);
    t.c = post_tap(tex, uv, float2( 2.0f, -2.0f), texel);
    t.d = post_tap(tex, uv, float2(-2.0f,  0.0f), texel);
    t.e = post_tap(tex, uv, float2( 0.0f,  0.0f), texel);
    t.f = post_tap(tex, uv, float2( 2.0f,  0.0f), texel);
    t.g = post_tap(tex, uv, float2(-2.0f,  2.0f), texel);
    t.h = post_tap(tex, uv, float2( 0.0f,  2.0f), texel);
    t.i = post_tap(tex, uv, float2( 2.0f,  2.0f), texel);
    t.j = post_tap(tex, uv, float2(-1.0f, -1.0f), texel);
    t.k = post_tap(tex, uv, float2( 1.0f, -1.0f), texel);
    t.l = post_tap(tex, uv, float2(-1.0f,  1.0f), texel);
    t.m = post_tap(tex, uv, float2( 1.0f,  1.0f), texel);
    return t;
}

/// Plain 13-tap downsample: four corner 2×2 boxes at weight 1/8 and the centre 2×2 box
/// at weight 1/2 (equivalent per-tap weights: e 1/8, corners 1/32, edges 1/16, inner 1/8).
inline float3 post_downsample_13(texture2d<float, access::sample> tex, float2 uv, float2 texel) {
    PostDownsampleTaps t = post_fetch_13(tex, uv, texel);
    float3 g0 = (t.a + t.b + t.d + t.e) * 0.25f;
    float3 g1 = (t.b + t.c + t.e + t.f) * 0.25f;
    float3 g2 = (t.d + t.e + t.g + t.h) * 0.25f;
    float3 g3 = (t.e + t.f + t.h + t.i) * 0.25f;
    float3 g4 = (t.j + t.k + t.l + t.m) * 0.25f;
    return (g0 + g1 + g2 + g3) * 0.125f + g4 * 0.5f;
}

/// Prefilter variant: exposure and soft threshold per tap, then the five boxes are
/// combined with a partial Karis average (box weight × 1/(1 + luma)).
inline float3 post_prefilter_13(texture2d<float, access::sample> tex, float2 uv, float2 texel,
                                float exposure, float threshold) {
    PostDownsampleTaps t = post_fetch_13(tex, uv, texel);
    t.a = post_bloom_threshold(post_nan_to_zero(t.a) * exposure, threshold);
    t.b = post_bloom_threshold(post_nan_to_zero(t.b) * exposure, threshold);
    t.c = post_bloom_threshold(post_nan_to_zero(t.c) * exposure, threshold);
    t.d = post_bloom_threshold(post_nan_to_zero(t.d) * exposure, threshold);
    t.e = post_bloom_threshold(post_nan_to_zero(t.e) * exposure, threshold);
    t.f = post_bloom_threshold(post_nan_to_zero(t.f) * exposure, threshold);
    t.g = post_bloom_threshold(post_nan_to_zero(t.g) * exposure, threshold);
    t.h = post_bloom_threshold(post_nan_to_zero(t.h) * exposure, threshold);
    t.i = post_bloom_threshold(post_nan_to_zero(t.i) * exposure, threshold);
    t.j = post_bloom_threshold(post_nan_to_zero(t.j) * exposure, threshold);
    t.k = post_bloom_threshold(post_nan_to_zero(t.k) * exposure, threshold);
    t.l = post_bloom_threshold(post_nan_to_zero(t.l) * exposure, threshold);
    t.m = post_bloom_threshold(post_nan_to_zero(t.m) * exposure, threshold);

    float3 g0 = (t.a + t.b + t.d + t.e) * 0.25f;
    float3 g1 = (t.b + t.c + t.e + t.f) * 0.25f;
    float3 g2 = (t.d + t.e + t.g + t.h) * 0.25f;
    float3 g3 = (t.e + t.f + t.h + t.i) * 0.25f;
    float3 g4 = (t.j + t.k + t.l + t.m) * 0.25f;

    float w0 = 0.125f / (1.0f + luminance(g0));
    float w1 = 0.125f / (1.0f + luminance(g1));
    float w2 = 0.125f / (1.0f + luminance(g2));
    float w3 = 0.125f / (1.0f + luminance(g3));
    float w4 = 0.5f / (1.0f + luminance(g4));
    float3 sum = g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4;
    return sum / max(w0 + w1 + w2 + w3 + w4, 1e-5f);
}

/// 3×3 tent filter (1 2 1 / 2 4 2 / 1 2 1) / 16 at one source-texel spacing.
inline float3 post_tent_9(texture2d<float, access::sample> tex, float2 uv, float2 texel) {
    float3 sum = float3(0.0f);
    sum += post_tap(tex, uv, float2(-1.0f, -1.0f), texel) * 1.0f;
    sum += post_tap(tex, uv, float2( 0.0f, -1.0f), texel) * 2.0f;
    sum += post_tap(tex, uv, float2( 1.0f, -1.0f), texel) * 1.0f;
    sum += post_tap(tex, uv, float2(-1.0f,  0.0f), texel) * 2.0f;
    sum += post_tap(tex, uv, float2( 0.0f,  0.0f), texel) * 4.0f;
    sum += post_tap(tex, uv, float2( 1.0f,  0.0f), texel) * 2.0f;
    sum += post_tap(tex, uv, float2(-1.0f,  1.0f), texel) * 1.0f;
    sum += post_tap(tex, uv, float2( 0.0f,  1.0f), texel) * 2.0f;
    sum += post_tap(tex, uv, float2( 1.0f,  1.0f), texel) * 1.0f;
    return sum * (1.0f / 16.0f);
}

/// Reciprocal size of a texture (its level-0 texel in uv units).
inline float2 post_texel_size(texture2d<float, access::sample> tex) {
    return 1.0f / float2(float(tex.get_width()), float(tex.get_height()));
}

/// Effective bloom threshold (falls back when PostParams has not been written).
inline float post_effective_threshold(constant PostParams &p) {
    return p.bloomThreshold > 0.0f ? p.bloomThreshold : kPostDefaultBloomThreshold;
}

/// Exposure multiplier: 2^EV × 0.6.
inline float post_exposure(constant FrameUniforms &u) {
    return exp2(u.exposureEV) * kPostExposureBase;
}

/// ∇ of animated simplex noise at `p` (x, y components) by central differences.
inline float2 post_shimmer_gradient(float3 p, uint seed) {
    float e = kPostShimmerGradientStep;
    float nx1 = simplex_noise3(p + float3(e, 0.0f, 0.0f), seed);
    float nx0 = simplex_noise3(p - float3(e, 0.0f, 0.0f), seed);
    float ny1 = simplex_noise3(p + float3(0.0f, e, 0.0f), seed);
    float ny0 = simplex_noise3(p - float3(0.0f, e, 0.0f), seed);
    return float2(nx1 - nx0, ny1 - ny0) / (2.0f * e);
}

/// ACES filmic curve, Narkowicz (2015) fit; input is exposed linear colour.
inline float3 post_aces_narkowicz(float3 x) {
    const float a = 2.51f;
    const float b = 0.03f;
    const float c = 2.43f;
    const float d = 0.59f;
    const float e = 0.14f;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// MARK: - Bloom kernels

kernel void post_bloom_prefilter(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                                 constant PostParams &p [[buffer(BufferIndexPostParams)]],
                                 texture2d<float, access::sample> colorTex [[texture(POST_SLOT_COLOR)]],
                                 texture2d<float, access::write> dstTex [[texture(POST_SLOT_TARGET)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    uint2 dstSize = uint2(dstTex.get_width(), dstTex.get_height());
    if (gid.x >= dstSize.x || gid.y >= dstSize.y) return;

    float2 uv = (float2(gid) + 0.5f) / float2(float(dstSize.x), float(dstSize.y));
    float2 texel = post_texel_size(colorTex);
    float3 bloom = post_prefilter_13(colorTex, uv, texel, post_exposure(u), post_effective_threshold(p));
    dstTex.write(float4(bloom, 1.0f), gid);
}

kernel void post_bloom_downsample(texture2d<float, access::sample> srcTex [[texture(POST_SLOT_FINE)]],
                                  texture2d<float, access::write> dstTex [[texture(POST_SLOT_TARGET)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    uint2 dstSize = uint2(dstTex.get_width(), dstTex.get_height());
    if (gid.x >= dstSize.x || gid.y >= dstSize.y) return;

    float2 uv = (float2(gid) + 0.5f) / float2(float(dstSize.x), float(dstSize.y));
    float2 texel = post_texel_size(srcTex);
    float3 bloom = post_downsample_13(srcTex, uv, texel);
    dstTex.write(float4(bloom, 1.0f), gid);
}

kernel void post_bloom_upsample(texture2d<float, access::sample> fineTex [[texture(POST_SLOT_FINE)]],
                                texture2d<float, access::sample> coarseTex [[texture(POST_SLOT_COARSE)]],
                                texture2d<float, access::write> dstTex [[texture(POST_SLOT_TARGET)]],
                                uint2 gid [[thread_position_in_grid]]) {
    uint2 dstSize = uint2(dstTex.get_width(), dstTex.get_height());
    if (gid.x >= dstSize.x || gid.y >= dstSize.y) return;

    float2 uv = (float2(gid) + 0.5f) / float2(float(dstSize.x), float(dstSize.y));
    // fineTex has the destination's size: read the matching texel directly.
    float3 same = max(fineTex.read(gid).rgb, 0.0f);
    float3 blurred = post_tent_9(coarseTex, uv, post_texel_size(coarseTex));
    dstTex.write(float4(same + blurred, 1.0f), gid);
}

// MARK: - Shimmer + tonemap kernel

kernel void post_shimmer_tonemap(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                                 constant PostParams &p [[buffer(BufferIndexPostParams)]],
                                 texture2d<float, access::sample> colorTex [[texture(POST_SLOT_COLOR)]],
                                 texture2d<float, access::sample> bloomTex [[texture(POST_SLOT_FINE)]],
                                 texture2d<float, access::sample> heatTex [[texture(TextureIndexHeat)]],
                                 texture2d<float, access::read> noiseTex [[texture(TextureIndexBlueNoise)]],
                                 texture2d<float, access::write> outputTex [[texture(POST_SLOT_TARGET)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.outputSize.x) || gid.y >= uint(u.outputSize.y)) return;

    float2 outputSize = u.outputSize;
    float2 uv = (float2(gid) + 0.5f) / outputSize;

    if (kPostDebug) {
        float3 value;
        if (kDebugView == kPostDebugViewHeat) {
            value = float3(saturate(heatTex.sample(kPostLinearClamp, uv, level(0)).r));
        } else {
            value = saturate(post_nan_to_zero(colorTex.sample(kPostLinearClamp, uv, level(0)).rgb));
        }
        outputTex.write(float4(linear_to_srgb(value), 1.0f), gid);
        return;
    }

    // Heat shimmer: displace the sample position along the gradient of a rising noise field.
    float heat = saturate(heatTex.sample(kPostLinearClamp, uv, level(0)).r);
    float shimmerPixels = heat * max(p.shimmerStrength, 0.0f);
    float2 sampleUV = uv;
    if (shimmerPixels > 1e-3f) {
        float aspect = outputSize.x / max(outputSize.y, 1.0f);
        float3 noisePosition = float3(uv.x * aspect * kPostShimmerNoiseScale,
                                      uv.y * kPostShimmerNoiseScale + u.time * kPostShimmerRiseRate,
                                      u.time * kPostShimmerWobbleRate);
        uint noiseSeed = hash_u32(u.seedLo, u.seedHi, kPostShimmerSeedKey, 0u, 0u);
        float2 gradient = post_shimmer_gradient(noisePosition, noiseSeed);
        float2 offsetPixels = clamp(gradient * kPostShimmerGradientGain, -1.0f, 1.0f) * shimmerPixels;
        sampleUV = clamp(uv + offsetPixels / outputSize, 0.0f, 1.0f);
    }

    // Exposure and bloom (bloom is prefiltered in the exposed domain).
    float exposure = post_exposure(u);
    float3 color = post_nan_to_zero(max(colorTex.sample(kPostLinearClamp, sampleUV, level(0)).rgb, 0.0f)) * exposure;
    if (p.bloomIntensity > 0.0f) {
        float3 bloom = post_tent_9(bloomTex, sampleUV, post_texel_size(bloomTex));
        color += post_nan_to_zero(bloom) * p.bloomIntensity;
    }

    // Vignette (light falloff, before the curve).
    float radial = length(uv * 2.0f - 1.0f) * 0.70710678f;   // 0 centre … 1 corners
    float vignette = 1.0f - saturate(p.vignette) * smoothstep(kPostVignetteInner, kPostVignetteOuter, radial);
    color *= vignette;

    // Tonemap, encode, dither.
    float3 encoded = linear_to_srgb(post_aces_narkowicz(color));
    float dither = blue_noise_sample(noiseTex, gid, u.frameIndex).r - 0.5f;
    encoded = saturate(encoded + dither * kPostDitherAmplitude);
    outputTex.write(float4(encoded, 1.0f), gid);
}
