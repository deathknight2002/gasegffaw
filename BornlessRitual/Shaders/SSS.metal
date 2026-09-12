//
//  SSS.metal
//  Bornless Ritual — separable screen-space subsurface scattering + wax translucency
//  (RENDER_CONTRACT §2 row 6 "SSSPass"; ShaderTypes.h MATERIAL_FLAG_SSS / MATERIAL_FLAG_WAX,
//  `MaterialData.sssColor` / `sssRadiusMm`, `FlameData`).
//
//  Role: two kernels (`sss_horizontal`, `sss_vertical`) blur the denoised direct diffuse
//  irradiance (Lighting.metal stores irradiance / π WITHOUT albedo, so the blur mixes
//  light, not surface colour) on pixels whose material carries MATERIAL_FLAG_SSS (skin)
//  or MATERIAL_FLAG_WAX (candles), in the manner of Jimenez et al. 2015 "Separable
//  Subsurface Scattering": an 11-tap one-dimensional kernel applied horizontally, then
//  vertically. Every other pixel is copied through unchanged.
//
//  Kernel radius (pixels) = sssRadiusMm · 1e-3 · projectionScale / linearDepth, with
//  projectionScale = renderSize.y / (2 · tan(fovY / 2)) = projectionMatrix[1][1] ·
//  renderSize.y / 2 — the on-screen size of the material's scattering radius.
//
//  Profile: the Christensen–Burley normalised diffusion profile
//  R(r) = (e^{−r/d} + e^{−r/(3d)}) / (8π d r) with d = radius / 3 (so the taps span ±3d)
//  is approximated by three 2-D Gaussians. The coefficients were fitted offline by
//  least squares on the area-weighted profile (Tools scratch, d = 1):
//    σ = (0.08, 0.22, 1.56) · d, weights = (0.03, 0.16, 0.81);
//  the narrow term stands in for the 1/r core (sub-pixel at every practical radius),
//  the wide term carries the bulk of the energy. The separable pass uses the 1-D
//  marginal Σ wₖ g(x; σₖ) in each direction, which reproduces the 2-D sum of Gaussians
//  only approximately (a sum of products is not a product of sums) — the accepted
//  trade-off of separable SSS. Per-channel widths follow `sssColor`: channel c uses
//  d_c = d · sssColor_c / max(sssColor), so skin (0.9, 0.3, 0.2) scatters red widest
//  and blue narrowest; every channel's kernel is normalised to unit energy, so the
//  characteristic red bleed comes from the width difference alone (no tinting).
//
//  Tap layout: 11 taps at x_i = sign(i) · (|i| / 5)² · radius, i = −5…5 (quadratic spacing
//  concentrates samples near the centre where the profile peaks); each tap is weighted
//  by the profile times its trapezoidal footprint and rejected when it belongs to a
//  different material or lies more than kSSSDepthTolerance · radius (metres) away in
//  view depth, so light never bleeds across silhouettes or from the robe into a hand.
//
//  Wax translucency (thin-slab transmission approximation): a candle's wax is lit from
//  inside by its own flame. For each WAX pixel the vertical pass adds, for every lit
//  flame whose base lies above the pixel within kWaxFlameReach (0.08 m; the job brief's
//  figure supersedes RENDER_CONTRACT's 0.06 m),
//      flameColor · intensity · exp(−distance / kWaxFlameFalloff) · sssColor
//  scaled by kWaxFlameRadiance · flameIntensity slider. exp(−distance / 0.02) is the
//  Beer–Lambert transmission through a slab of wax with a 2 cm attenuation length; the
//  angular dependence is dropped (a translucent slab glows from every side). The term is
//  irradiance-like (Composite multiplies it by the albedo like the rest of SSSDiffuse).
//
//  Bindings (DenoisePass-style slot reuse, mirrored in SSSPass.swift): the INPUT of each
//  kernel is bound at TextureIndexDirectDiffuse and its OUTPUT at TextureIndexSSSDiffuse,
//  whatever texture plays that role — horizontal: DirectDiffuse → scratch; vertical:
//  scratch → SSSDiffuse. Output alpha = 1 for scattering pixels, 0 for copy-through
//  (the `.sss` debug view can show the mask). The flame buffer holds exactly
//  kSSSMaxFlames entries, zero-filled beyond the live flames (intensity 0 = skipped).
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;

// MARK: - Constants

/// FlameData entries scanned by the wax term; SSSPass.swift binds exactly this many.
constant uint kSSSMaxFlames = 16u;
/// Taps per direction (i = −5 … 5).
constant int kSSSHalfTaps = 5;
/// Burley → 3-Gaussian fit (units of d, see header).
constant float kSSSProfileSigma[3] = {0.08f, 0.22f, 1.56f};
constant float kSSSProfileWeight[3] = {0.03f, 0.16f, 0.81f};
/// d = radius / 3: the taps reach three diffusion lengths.
constant float kSSSRadiusToDiffusion = 1.0f / 3.0f;
/// Below this on-screen radius (pixels) the blur is a no-op and the pixel is copied.
constant float kSSSMinRadiusPixels = 0.5f;
/// Upper bound on the on-screen radius (pixels) — extreme close-ups stay bounded in cost and leak.
constant float kSSSMaxRadiusPixels = 48.0f;
/// Per-channel width floor relative to the widest channel (avoids a zero-width kernel).
constant float kSSSMinChannelScale = 0.05f;
/// Taps farther than this many radii (metres) in view depth are faded out / rejected.
constant float kSSSDepthTolerance = 8.0f;
/// Wax translucency: flame reach above the pixel (m), attenuation length (m), radiance scale.
constant float kWaxFlameReach = 0.08f;
constant float kWaxFlameFalloff = 0.02f;
constant float kWaxFlameRadiance = 3.0f;
/// 1 / sqrt(2π) for the 1-D Gaussian normalisation.
constant float kInvSqrtTwoPi = 0.39894228040143267794f;

// MARK: - Material helpers

/// Material index encoded in the albedo alpha (GBuffer.metal: materialIndex / 255).
inline uint sss_material_index(float4 albedoTexel) {
    return uint(albedoTexel.a * 255.0f + 0.5f);
}

/// True for materials that take part in the screen-space scattering.
inline bool sss_scatters(uint flags) {
    return (flags & (MATERIAL_FLAG_SSS | MATERIAL_FLAG_WAX)) != 0u;
}

/// Per-channel diffusion length in pixels: d_c = d · sssColor_c / max(sssColor), floored.
inline float3 sss_channel_diffusion(float radiusPixels, float3 sssColor) {
    float3 tint = max(sssColor, 0.0f);
    float peak = max(max(tint.x, tint.y), tint.z);
    float3 scale = (peak > 1e-5f) ? max(tint / peak, kSSSMinChannelScale) : float3(1.0f);
    return scale * (radiusPixels * kSSSRadiusToDiffusion);
}

/// On-screen scattering radius in pixels for a material at linear view depth `linearDepth`.
inline float sss_radius_pixels(float sssRadiusMm, float linearDepth, constant FrameUniforms &u) {
    float projectionScale = 0.5f * u.renderSize.y * u.projectionMatrix[1][1];
    float radius = sssRadiusMm * 1e-3f * projectionScale / max(linearDepth, 1e-3f);
    return clamp(radius, 0.0f, kSSSMaxRadiusPixels);
}

// MARK: - Profile

/// 1-D marginal of the 3-Gaussian Burley fit, per channel, at pixel offset `x` for
/// per-channel diffusion lengths `d` (pixels).
inline float3 sss_profile_1d(float x, float3 d) {
    float3 sum = float3(0.0f);
    for (uint k = 0u; k < 3u; ++k) {
        float3 sigma = max(kSSSProfileSigma[k] * d, 1e-3f);
        float3 gauss = exp(-(x * x) / (2.0f * sigma * sigma)) * (kInvSqrtTwoPi / sigma);
        sum += kSSSProfileWeight[k] * gauss;
    }
    return sum;
}

/// Tap position (pixels) along the blur axis for tap index i ∈ [−5, 5].
inline float sss_tap_offset(int i, float radiusPixels) {
    float t = float(i) / float(kSSSHalfTaps);
    return (t < 0.0f ? -1.0f : 1.0f) * t * t * radiusPixels;
}

/// Trapezoidal footprint of tap i (half the distance to each neighbour; the outermost
/// taps take the full spacing to their inner neighbour).
inline float sss_tap_footprint(int i, float radiusPixels) {
    if (i == kSSSHalfTaps || i == -kSSSHalfTaps) {
        return abs(sss_tap_offset(kSSSHalfTaps, radiusPixels) - sss_tap_offset(kSSSHalfTaps - 1, radiusPixels));
    }
    return 0.5f * (sss_tap_offset(i + 1, radiusPixels) - sss_tap_offset(i - 1, radiusPixels));
}

// MARK: - Separable blur

/// One direction of the separable blur for a scattering pixel. Returns the normalised
/// weighted sum of the input irradiance along `axis` ((1,0) or (0,1)).
inline float3 sss_blur(uint2 gid, int2 axis, float radiusPixels, float3 diffusionPixels,
                       uint materialIndex, float zCenter, float depthTolerance,
                       constant FrameUniforms &u,
                       depth2d<float, access::read> depthTex,
                       texture2d<float, access::read> albedoTex,
                       texture2d<float, access::read> inputTex) {
    int2 size = int2(u.renderSize);
    float3 sumColor = float3(0.0f);
    float3 sumWeight = float3(0.0f);
    for (int i = -kSSSHalfTaps; i <= kSSSHalfTaps; ++i) {
        float x = sss_tap_offset(i, radiusPixels);
        float3 w = sss_profile_1d(x, diffusionPixels) * sss_tap_footprint(i, radiusPixels);
        int2 p = int2(gid) + axis * int(round(x));
        p = clamp(p, int2(0), size - 1);
        uint2 pixel = uint2(p);
        if (i != 0) {
            float depth = depthTex.read(pixel);
            if (is_background_depth(depth)) {
                continue;
            }
            if (sss_material_index(albedoTex.read(pixel)) != materialIndex) {
                continue;
            }
            float zTap = linearize_depth(depth, u.nearPlane, u.farPlane);
            w *= saturate(1.0f - abs(zTap - zCenter) / depthTolerance);
        }
        sumColor += w * inputTex.read(pixel).rgb;
        sumWeight += w;
    }
    return sumColor / max(sumWeight, float3(1e-5f));
}

// MARK: - Wax translucency

/// Flame-through-wax term (see header): thin-slab transmission from every lit flame
/// whose base sits above `position` within kWaxFlameReach.
inline float3 sss_wax_transmission(float3 position, float3 waxTint,
                                   device const FlameData *flames, constant FrameUniforms &u) {
    float3 total = float3(0.0f);
    for (uint i = 0u; i < kSSSMaxFlames; ++i) {
        FlameData flame = flames[i];
        if (flame.intensity <= 0.0f) {
            continue;
        }
        float3 delta = flame.position - position;
        if (delta.y <= 0.0f) {
            continue;
        }
        float dist = length(delta);
        if (dist > kWaxFlameReach) {
            continue;
        }
        float3 color = max(flame.color, 0.0f);
        if (flame.temperatureK > 0.0f) {
            color *= blackbody_rgb(flame.temperatureK);
        }
        total += color * (flame.intensity * exp(-dist / kWaxFlameFalloff));
    }
    return total * max(waxTint, 0.0f) * (kWaxFlameRadiance * max(u.flameIntensity, 0.0f));
}

// MARK: - Shared per-pixel setup

/// Everything both kernels need to know about the centre pixel.
struct SSSPixel {
    bool scatters;          ///< material has SSS or WAX and the on-screen radius is ≥ ½ px
    bool wax;               ///< material has MATERIAL_FLAG_WAX
    uint materialIndex;
    float depth;            ///< reversed-Z depth
    float zCenter;          ///< linear view depth (m)
    float radiusPixels;
    float3 diffusionPixels;
    float3 sssColor;
    float depthTolerance;   ///< metres
};

/// Classifies the centre pixel; `scatters` is false for background and non-SSS materials.
inline SSSPixel sss_classify(uint2 gid, constant FrameUniforms &u, device const MaterialData *materials,
                             depth2d<float, access::read> depthTex, texture2d<float, access::read> albedoTex) {
    SSSPixel px;
    px.scatters = false;
    px.wax = false;
    px.materialIndex = 0u;
    px.depth = depthTex.read(gid);
    px.zCenter = 0.0f;
    px.radiusPixels = 0.0f;
    px.diffusionPixels = float3(0.0f);
    px.sssColor = float3(0.0f);
    px.depthTolerance = 1.0f;
    if (is_background_depth(px.depth)) {
        return px;
    }
    px.materialIndex = sss_material_index(albedoTex.read(gid));
    device const MaterialData &material = materials[px.materialIndex];
    if (!sss_scatters(material.flags)) {
        return px;
    }
    px.wax = (material.flags & MATERIAL_FLAG_WAX) != 0u;
    px.zCenter = linearize_depth(px.depth, u.nearPlane, u.farPlane);
    px.radiusPixels = sss_radius_pixels(max(material.sssRadiusMm, 0.0f), px.zCenter, u);
    px.sssColor = material.sssColor;
    px.diffusionPixels = sss_channel_diffusion(px.radiusPixels, material.sssColor);
    px.depthTolerance = max(kSSSDepthTolerance * material.sssRadiusMm * 1e-3f, 1e-3f);
    px.scatters = px.radiusPixels >= kSSSMinRadiusPixels;
    return px;
}

// MARK: - Kernels

/// Horizontal pass: DirectDiffuse (denoised irradiance) → scratch.
kernel void sss_horizontal(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                           device const MaterialData *materials [[buffer(BufferIndexMaterials)]],
                           depth2d<float, access::read> depthTex [[texture(TextureIndexDepth)]],
                           texture2d<float, access::read> albedoTex [[texture(TextureIndexGBufferAlbedo)]],
                           texture2d<float, access::read> inputTex [[texture(TextureIndexDirectDiffuse)]],
                           texture2d<float, access::write> outputTex [[texture(TextureIndexSSSDiffuse)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.renderSize.x) || gid.y >= uint(u.renderSize.y)) return;

    SSSPixel px = sss_classify(gid, u, materials, depthTex, albedoTex);
    float3 irradiance = inputTex.read(gid).rgb;
    if (px.scatters) {
        irradiance = sss_blur(gid, int2(1, 0), px.radiusPixels, px.diffusionPixels, px.materialIndex,
                              px.zCenter, px.depthTolerance, u, depthTex, albedoTex, inputTex);
    }
    outputTex.write(float4(irradiance, px.scatters ? 1.0f : 0.0f), gid);
}

/// Vertical pass: scratch → SSSDiffuse, plus the wax translucency term.
kernel void sss_vertical(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                         device const MaterialData *materials [[buffer(BufferIndexMaterials)]],
                         device const FlameData *flames [[buffer(BufferIndexFlames)]],
                         depth2d<float, access::read> depthTex [[texture(TextureIndexDepth)]],
                         texture2d<float, access::read> albedoTex [[texture(TextureIndexGBufferAlbedo)]],
                         texture2d<float, access::read> inputTex [[texture(TextureIndexDirectDiffuse)]],
                         texture2d<float, access::write> outputTex [[texture(TextureIndexSSSDiffuse)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.renderSize.x) || gid.y >= uint(u.renderSize.y)) return;

    SSSPixel px = sss_classify(gid, u, materials, depthTex, albedoTex);
    float3 irradiance = inputTex.read(gid).rgb;
    if (px.scatters) {
        irradiance = sss_blur(gid, int2(0, 1), px.radiusPixels, px.diffusionPixels, px.materialIndex,
                              px.zCenter, px.depthTolerance, u, depthTex, albedoTex, inputTex);
    }
    if (px.wax) {
        float2 uv = pixel_center_uv(gid, u);
        float3 position = reconstruct_world_position(uv, px.depth, u.invViewProjection);
        irradiance += sss_wax_transmission(position, px.sssColor, flames, u);
    }
    outputTex.write(float4(max(irradiance, 0.0f), px.scatters ? 1.0f : 0.0f), gid);
}
