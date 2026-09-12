//
//  TAA.metal
//  Bornless Ritual — temporal anti-aliasing + upsampling fallback for devices where
//  the MetalFX temporal scaler is unsupported or disabled from the debug panel
//  (RENDER_CONTRACT §2 row 12 "UpscalePass … fallback custom TAA-upsample", §3 motion
//  vectors & jitter; ShaderTypes.h TextureIndexHDRColor / TextureIndexDepth /
//  TextureIndexGBufferMotion / TextureIndexPrevHDR / TextureIndexUpscaled; Common.h
//  `is_background_depth`).
//
//  Role: `taa_resolve` runs one thread per NATIVE pixel (8×8 threadgroups) and writes
//  Upscaled from the internal-resolution HDRColor and the native-resolution history
//  PrevHDR (last frame's Upscaled, rotated in by `RenderResources.swapHistory()`):
//    1. jitter-aware Catmull-Rom reconstruction of the low-res colour at this pixel;
//    2. 3×3 neighbourhood mean/variance in YCoCg → clamp box mean ± γ·σ (γ = 1.25);
//    3. reprojection through the G-buffer motion vector (bilinear, with closest-depth
//       dilation over the 3×3 so silhouettes drag their background correctly);
//    4. Catmull-Rom (5-tap) fetch of the history at the reprojected native position,
//       clamped to the box, blended with alpha = max(0.1, 1 / historyLength);
//    5. the history length rides in Upscaled.a (capped at 32) so the 16 warm-up frames
//       after a seek accumulate as a running mean before settling on the 0.1 blend.
//  History is bypassed (alpha 1, length 1) when `historyValid == 0` or the reprojected
//  position leaves the frame. NaNs from upstream passes are zeroed before they can
//  poison the history.
//
//  Jitter convention (MathExtensions.perspectiveReversedZ(jitterNDC:) / UniformBuilder):
//  the projection satisfies ndc = unjitteredNDC + jitter, with
//  jitter = (2·px.x / R.x, −2·px.y / R.y) for a texture-space pixel offset px (x right,
//  y down). The rendered image is therefore the un-jittered image shifted by +px pixels
//  in texture space, so the un-jittered scene at render-pixel position s is found at
//  s + px in HDRColor. `px` is recovered from `FrameUniforms.jitter` below (never from
//  frameIndex) so the two sides cannot drift.
//
//  Motion convention (RENDER_CONTRACT §3, GBuffer.metal): motion = (prevUV − curUV) × R
//  in render-resolution pixels, pointing from the current pixel to where it was last
//  frame; prevUV = uv + motion / R.
//
//  Colour: linear HDR in, linear HDR out (PostPass applies exposure and tonemapping).
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;

// MARK: - Constants

/// Weight of the current frame once the history is long (contract: "blend 0.1").
constant float kTAABlendAlpha = 0.1f;
/// Variance-clamp width in standard deviations.
constant float kTAAVarianceGamma = 1.25f;
/// Cap on the history length carried in Upscaled.a (alpha floor is reached at 10).
constant float kTAAMaxHistoryLength = 32.0f;

/// Bilinear, edge-clamped sampler shared by the colour, motion and history fetches.
constexpr sampler kTAALinearClamp(filter::linear, mip_filter::none, address::clamp_to_edge);

// MARK: - Colour helpers

/// Replaces NaN components with 0 (an upstream NaN must never enter the history).
inline float3 taa_nan_to_zero(float3 c) {
    return select(c, float3(0.0f), isnan(c));
}

/// RGB → YCoCg (Malvar 2003): Y = luma-like, Co/Cg chroma; the clamp box is axis-aligned here.
inline float3 taa_rgb_to_ycocg(float3 c) {
    return float3( 0.25f * c.r + 0.5f * c.g + 0.25f * c.b,
                   0.5f * c.r              - 0.5f * c.b,
                  -0.25f * c.r + 0.5f * c.g - 0.25f * c.b);
}

/// YCoCg → RGB (exact inverse of `taa_rgb_to_ycocg`).
inline float3 taa_ycocg_to_rgb(float3 c) {
    float tmp = c.x - c.z;
    return float3(tmp + c.y, c.x + c.z, tmp - c.y);
}

// MARK: - Catmull-Rom

/// Catmull-Rom reconstruction of `tex` at `position` (pixel units of `tex`, pixel
/// centres at integer + 0.5) using the 9-bilinear-tap decomposition with the four
/// corner taps dropped and the weights renormalised (Jimenez 2016, "5-tap" variant).
/// Shared by the low-res colour upsample and the native history fetch.
inline float4 taa_sample_catmull_rom(texture2d<float, access::sample> tex, float2 position, float2 texSize) {
    float2 invSize = 1.0f / texSize;
    float2 texPos1 = floor(position - 0.5f) + 0.5f;
    float2 f = position - texPos1;

    float2 w0 = f * (-0.5f + f * (1.0f - 0.5f * f));
    float2 w1 = 1.0f + f * f * (-2.5f + 1.5f * f);
    float2 w2 = f * (0.5f + f * (2.0f - 1.5f * f));
    float2 w3 = f * f * (-0.5f + 0.5f * f);

    float2 w12 = w1 + w2;
    float2 offset12 = w2 / max(w12, float2(1e-5f));

    float2 texPos0 = (texPos1 - 1.0f) * invSize;
    float2 texPos3 = (texPos1 + 2.0f) * invSize;
    float2 texPos12 = (texPos1 + offset12) * invSize;

    float4 result = float4(0.0f);
    result += tex.sample(kTAALinearClamp, float2(texPos12.x, texPos0.y), level(0)) * (w12.x * w0.y);
    result += tex.sample(kTAALinearClamp, float2(texPos0.x, texPos12.y), level(0)) * (w0.x * w12.y);
    result += tex.sample(kTAALinearClamp, float2(texPos12.x, texPos12.y), level(0)) * (w12.x * w12.y);
    result += tex.sample(kTAALinearClamp, float2(texPos3.x, texPos12.y), level(0)) * (w3.x * w12.y);
    result += tex.sample(kTAALinearClamp, float2(texPos12.x, texPos3.y), level(0)) * (w12.x * w3.y);

    float weightSum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return result / max(weightSum, 1e-5f);
}

// MARK: - Kernel

kernel void taa_resolve(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                        texture2d<float, access::sample> colorTex [[texture(TextureIndexHDRColor)]],
                        depth2d<float, access::sample> depthTex [[texture(TextureIndexDepth)]],
                        texture2d<float, access::sample> motionTex [[texture(TextureIndexGBufferMotion)]],
                        texture2d<float, access::sample> historyTex [[texture(TextureIndexPrevHDR)]],
                        texture2d<float, access::write> upscaledTex [[texture(TextureIndexUpscaled)]],
                        uint2 gid [[thread_position_in_grid]]) {
    // Native-resolution pass: guard against the output size, not the render size.
    if (gid.x >= uint(u.outputSize.x) || gid.y >= uint(u.outputSize.y)) return;

    float2 outputSize = u.outputSize;
    float2 renderSize = u.renderSize;
    float2 uv = (float2(gid) + 0.5f) / outputSize;

    // Texture-space pixel jitter recovered from the NDC jitter (see header).
    float2 jitterPx = float2(u.jitter.x * renderSize.x * 0.5f, -u.jitter.y * renderSize.y * 0.5f);

    // Position of this output pixel's un-jittered scene point inside the jittered low-res image.
    float2 renderPos = uv * renderSize + jitterPx;
    float2 renderUV = renderPos * u.invRenderSize;

    // 1. Jitter-aware Catmull-Rom reconstruction of the current colour.
    float3 current = taa_nan_to_zero(max(taa_sample_catmull_rom(colorTex, renderPos, renderSize).rgb, 0.0f));

    // 2. Neighbourhood statistics (YCoCg) and 3. closest-depth motion dilation, one 3×3 loop.
    int2 maxPixel = int2(renderSize) - 1;
    int2 centerPixel = clamp(int2(floor(renderPos)), int2(0), maxPixel);
    float3 m1 = float3(0.0f);
    float3 m2 = float3(0.0f);
    float closestDepth = -1.0f;          // reversed-Z: larger = closer
    int2 closestPixel = centerPixel;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            int2 p = clamp(centerPixel + int2(dx, dy), int2(0), maxPixel);
            float3 c = taa_rgb_to_ycocg(taa_nan_to_zero(max(colorTex.read(uint2(p)).rgb, 0.0f)));
            m1 += c;
            m2 += c * c;
            float d = depthTex.read(uint2(p));
            if (d > closestDepth) {
                closestDepth = d;
                closestPixel = p;
            }
        }
    }
    float3 mean = m1 * (1.0f / 9.0f);
    float3 variance = max(m2 * (1.0f / 9.0f) - mean * mean, 0.0f);
    float3 sigma = sqrt(variance);
    float3 boxMin = mean - kTAAVarianceGamma * sigma;
    float3 boxMax = mean + kTAAVarianceGamma * sigma;

    // Motion (render pixels, current → previous): bilinear at the sample position when the
    // nearest pixel is itself the closest, otherwise snapped to the closest pixel's centre.
    bool centerIsClosest = all(closestPixel == centerPixel);
    float2 motionUV = centerIsClosest ? renderUV : (float2(closestPixel) + 0.5f) * u.invRenderSize;
    float2 motion = motionTex.sample(kTAALinearClamp, motionUV, level(0)).xy;
    float2 prevUV = uv + motion * u.invRenderSize;

    // 4. History fetch, clamp and blend.
    bool historyValid = (u.historyValid != 0u)
                     && all(prevUV >= float2(0.0f))
                     && all(prevUV <= float2(1.0f));
    float3 color = current;
    float historyLength = 1.0f;
    if (historyValid) {
        float4 history = taa_sample_catmull_rom(historyTex, prevUV * outputSize, outputSize);
        float3 historyRGB = taa_nan_to_zero(max(history.rgb, 0.0f));
        float3 historyYCoCg = clamp(taa_rgb_to_ycocg(historyRGB), boxMin, boxMax);
        historyRGB = max(taa_ycocg_to_rgb(historyYCoCg), 0.0f);

        // 5. Running-mean accumulation for young histories, 0.1 blend once settled.
        float previousLength = clamp(isnan(history.a) ? 0.0f : history.a, 0.0f, kTAAMaxHistoryLength);
        historyLength = min(previousLength + 1.0f, kTAAMaxHistoryLength);
        float alpha = max(kTAABlendAlpha, 1.0f / historyLength);
        color = mix(historyRGB, current, alpha);
    }

    upscaledTex.write(float4(color, historyLength), gid);
}
