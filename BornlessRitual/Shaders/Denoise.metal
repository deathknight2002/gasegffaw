//
//  Denoise.metal
//  Bornless Ritual — SVGF-style denoiser: temporal accumulation + à-trous wavelet
//  filtering of the noisy direct diffuse, direct specular and traced reflection signals
//  (RENDER_CONTRACT §2 row 5 "DenoisePass", §3 motion-vector convention
//  "motion = (prevUV − curUV) × R, current → previous"; ARCHITECTURE §6 warm-up).
//
//  Kernels
//    denoise_temporal  Reprojects each pixel into the previous frame — surface motion
//                      (G-buffer motion vector) for diffuse/specular, the virtual hit
//                      point (surface + view direction × hit distance) for reflection —
//                      fetches the history bilinearly with per-tap rejection (previous
//                      depth within 2 % of the depth expected for the current surface,
//                      previous normal · normal > 0.9), blends with
//                      alpha = max(1/(len+1), 0.05) for lighting and max(1/(len+1), 0.1)
//                      for reflection (1/(len+1) and no motion in warm-up) and updates
//                      the luminance moments. Writes in place.
//    denoise_atrous    One 5×5 B3-spline à-trous iteration (kDenoiseStep = 1, 2, 4) with
//                      edge-stopping weights on depth (σz = 1, measured against the
//                      surface's own depth gradient), normal (σn = 128) and luminance
//                      (σl = 4 × √variance); the variance is filtered alongside with
//                      squared weights (Schied et al. 2017). Iteration 1 replaces the
//                      temporal variance with a 5×5 spatial estimate where the history is
//                      shorter than 4 frames; later iterations prefilter it 3×3.
//
//  Data layout (this pass owns the alpha channels of the lighting textures and the
//  Moments texture; three signals are denoised, so the layout extends the contract's
//  "rg = moments, b = history length" note — recorded in the caveats):
//    DirectDiffuse / DirectSpecular / Reflection   rgb signal, a = μ2 = E[luminance²]
//    Moments                                       r = μ1 diffuse, g = μ1 specular,
//                                                  b = history length, a = μ1 reflection
//    scratch / History* during the ping-pong       a = filtered variance
//  À-trous ping-pong: Direct* → scratch → History* → Direct* (three iterations), so the
//  final result lands back in Direct*, which `swapHistory()` turns into next frame's
//  History*. The final iteration preserves the μ2 alpha of its output (read_write).
//
//  Texture slots: the à-trous INPUT is bound at the TextureIndexDirect* slots and its
//  OUTPUT at the TextureIndexHistory* slots whatever texture currently plays that role
//  (DenoisePass.swift rotates them). The previous frame's moments
//  (RenderResources.momentsHistory) have no TextureIndex and are bound at
//  DENOISE_TEXTURE_SLOT_MOMENTS_HISTORY (28, outside the enum; mirrored in Swift).
//
//  Function constants (pass-local; 0–2 are the shared ones declared in Common.h):
//    3 kDenoiseWarmup (bool)  temporal: warm-up accumulation (no motion, alpha 1/(k+1))
//    4 kDenoiseStep   (uint)  à-trous: 1, 2 or 4
//    5 kDenoiseFinal  (bool)  à-trous: last iteration (output is Direct*, keep its μ2)
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;

// MARK: - Function constants

/// Warm-up accumulation (ARCHITECTURE §6): the camera and simulation are frozen, so the
/// history is fetched without motion and blended with alpha = 1/(k+1).
constant bool kDenoiseWarmup [[function_constant(3)]] BR_FUNCTION_CONSTANT_LINT_INIT;
/// À-trous step size in pixels (1, 2, 4).
constant uint kDenoiseStep [[function_constant(4)]] BR_FUNCTION_CONSTANT_LINT_INIT;
/// True for the last à-trous iteration (its output is Direct*; the μ2 alpha is kept).
constant bool kDenoiseFinal [[function_constant(5)]] BR_FUNCTION_CONSTANT_LINT_INIT;
/// First iteration: the variance is derived from the moments, not read from the input alpha.
constant bool kDenoiseFirstIteration = (kDenoiseStep == 1u);

// MARK: - Constants

/// Texture slot of the previous frame's moments (no TextureIndex exists for it;
/// `DenoisePass.momentsHistoryTextureSlot` in Swift must match).
#define DENOISE_TEXTURE_SLOT_MOMENTS_HISTORY 28

/// Relative depth tolerance for history acceptance (2 %).
constant float kDenoiseDepthTolerance = 0.02f;
/// Minimum normal agreement (cosine) for history acceptance.
constant float kDenoiseNormalTolerance = 0.9f;
/// Steady-state blend floors: lighting 0.05, reflection 0.1.
constant float kDenoiseMinAlphaLighting = 0.05f;
constant float kDenoiseMinAlphaReflection = 0.1f;
/// History length cap (frames); alpha has saturated at its floor long before this.
constant float kDenoiseMaxHistoryLength = 64.0f;
/// Pixels with a shorter history use a spatial variance estimate (SVGF: 4 frames).
constant float kDenoiseSpatialVarianceHistory = 4.0f;
/// Edge-stopping parameters (job brief: σz 1, σn 128, σl 4).
constant float kDenoiseSigmaZ = 1.0f;
constant float kDenoiseSigmaN = 128.0f;
constant float kDenoiseSigmaL = 4.0f;
/// Metres added to the depth-gradient term so fronto-parallel surfaces (zero gradient)
/// still tolerate a couple of millimetres of depth difference.
constant float kDenoiseDepthEpsilon = 2.0e-3f;
/// Added under the square root of the variance so converged pixels keep a finite φ.
constant float kDenoiseVarianceEpsilon = 1.0e-6f;
/// Below this accumulated bilinear weight the history is treated as rejected.
constant float kDenoiseMinTapWeight = 1.0e-4f;
/// 5-tap B3-spline (1/16, 1/4, 3/8, 1/4, 1/16).
constant float kDenoiseB3[5] = {0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f};
/// 3-tap binomial used to prefilter the variance (1/4, 1/2, 1/4).
constant float kDenoiseBinomial3[3] = {0.25f, 0.5f, 0.25f};

// MARK: - Moments packing

/// Moments texel: r = μ1 diffuse, g = μ1 specular, b = history length, a = μ1 reflection.
inline float4 pack_moments(float3 mean, float historyLength) {
    return float4(mean.x, mean.y, historyLength, mean.z);
}

/// (μ1 diffuse, μ1 specular, μ1 reflection) of a moments texel.
inline float3 unpack_moments_mean(float4 moments) {
    return float3(moments.x, moments.y, moments.w);
}

/// History length of a moments texel.
inline float unpack_moments_length(float4 moments) {
    return moments.z;
}

// MARK: - Reprojection helpers

/// Projects a world position with `viewProjection`: xy = texture-space uv (y down),
/// z = reversed-Z depth, w = clip w (≤ 0 means the point is behind the camera).
inline float4 project_with_w(float3 worldPosition, float4x4 viewProjection) {
    float4 clip = viewProjection * float4(worldPosition, 1.0f);
    float invW = 1.0f / max(clip.w, 1e-7f);
    float3 ndc = clip.xyz * invW;
    return float4(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f, ndc.z, clip.w);
}

/// Depth expected in the previous frame for a point of the current surface plane at
/// texture uv: depth(uv) = plane.x + plane.y · uv.x + plane.z · uv.y.
inline float expected_plane_depth(float3 plane, float2 uv) {
    return plane.x + plane.y * uv.x + plane.z * uv.y;
}

/// Fits the previous-frame reversed depth of the current surface plane (through
/// `position` with `normal`) as an affine function of texture uv. Exact for planar
/// reflectors: a projective map sends world planes to planes in NDC, on which depth is
/// affine in (x, y). Three points of the plane (the pixel and two tangential offsets of
/// 2 cm per metre of view distance) are projected with the previous view-projection and
/// the 2×2 system solved. Returns false when a point falls behind the previous camera or
/// the plane is edge-on (singular system).
inline bool fit_previous_depth_plane(float3 position, float3 normal, float viewDistance,
                                     float4x4 prevViewProjection, thread float3 &plane) {
    float3 tangent;
    float3 bitangent;
    orthonormal_basis(normal, tangent, bitangent);
    float span = 0.02f * max(viewDistance, 0.5f);
    float4 a = project_with_w(position, prevViewProjection);
    float4 b = project_with_w(position + tangent * span, prevViewProjection);
    float4 c = project_with_w(position + bitangent * span, prevViewProjection);
    if (a.w <= 0.0f || b.w <= 0.0f || c.w <= 0.0f) {
        return false;
    }
    float2 eb = b.xy - a.xy;
    float2 ec = c.xy - a.xy;
    float det = eb.x * ec.y - eb.y * ec.x;
    if (abs(det) < 1e-9f) {
        return false;
    }
    float db = b.z - a.z;
    float dc = c.z - a.z;
    float2 gradient = float2(db * ec.y - dc * eb.y, dc * eb.x - db * ec.x) / det;
    plane = float3(a.z - dot(gradient, a.xy), gradient.x, gradient.y);
    return true;
}

// MARK: - History fetch

/// Result of a bilinear history fetch with per-tap rejection (values are normalised
/// by the accepted weight; `weight` = 0 means every tap was rejected).
struct HistoryFetch {
    float weight;
    float4 colorA;
    float4 colorB;
    float4 moments;
};

/// Fetches the history at `prevUV` with 2×2 bilinear taps. A tap is accepted when the
/// previous depth is within 2 % (linearised) of the depth expected for the current
/// surface at that tap (`depthPlane`) and the previous normal agrees with `normal`.
inline HistoryFetch fetch_history(float2 prevUV, float3 depthPlane, float3 normal, constant FrameUniforms &u,
                                  depth2d<float, access::read> prevDepthTex,
                                  texture2d<float, access::read> prevNormalTex,
                                  texture2d<float, access::read> texA,
                                  texture2d<float, access::read> texB,
                                  texture2d<float, access::read> momentsTex) {
    HistoryFetch result;
    result.weight = 0.0f;
    result.colorA = float4(0.0f);
    result.colorB = float4(0.0f);
    result.moments = float4(0.0f);
    if (prevUV.x < 0.0f || prevUV.y < 0.0f || prevUV.x > 1.0f || prevUV.y > 1.0f) {
        return result;
    }

    float2 prevPixel = prevUV * u.renderSize - 0.5f;
    float2 base = floor(prevPixel);
    float2 f = prevPixel - base;
    float weights[4] = {(1.0f - f.x) * (1.0f - f.y), f.x * (1.0f - f.y), (1.0f - f.x) * f.y, f.x * f.y};
    int2 baseIndex = int2(base);
    int2 size = int2(u.renderSize);

    for (uint i = 0u; i < 4u; ++i) {
        int2 p = baseIndex + int2(int(i & 1u), int(i >> 1u));
        if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y) {
            continue;
        }
        uint2 pixel = uint2(p);
        float prevDepth = prevDepthTex.read(pixel);
        if (is_background_depth(prevDepth)) {
            continue;
        }
        float2 tapUV = (float2(p) + 0.5f) * u.invRenderSize;
        float expected = expected_plane_depth(depthPlane, tapUV);
        if (expected <= 0.0f) {
            continue;
        }
        float zPrev = linearize_depth(prevDepth, u.nearPlane, u.farPlane);
        float zExpected = linearize_depth(expected, u.nearPlane, u.farPlane);
        if (abs(zPrev - zExpected) > kDenoiseDepthTolerance * zExpected) {
            continue;
        }
        float3 prevNormal = safe_normalize(prevNormalTex.read(pixel).xyz);
        if (dot(normal, prevNormal) <= kDenoiseNormalTolerance) {
            continue;
        }
        float w = weights[i];
        result.weight += w;
        result.colorA += w * texA.read(pixel);
        result.colorB += w * texB.read(pixel);
        result.moments += w * momentsTex.read(pixel);
    }

    if (result.weight > kDenoiseMinTapWeight) {
        float inv = 1.0f / result.weight;
        result.colorA *= inv;
        result.colorB *= inv;
        result.moments *= inv;
    } else {
        result.weight = 0.0f;
    }
    return result;
}

// MARK: - Temporal kernel

kernel void denoise_temporal(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                             depth2d<float, access::read> depthTex [[texture(TextureIndexDepth)]],
                             depth2d<float, access::read> prevDepthTex [[texture(TextureIndexPrevDepth)]],
                             texture2d<float, access::read> normalTex [[texture(TextureIndexGBufferNormal)]],
                             texture2d<float, access::read> prevNormalTex [[texture(TextureIndexPrevNormal)]],
                             texture2d<float, access::read> motionTex [[texture(TextureIndexGBufferMotion)]],
                             texture2d<float, access::read_write> diffuseTex [[texture(TextureIndexDirectDiffuse)]],
                             texture2d<float, access::read_write> specularTex [[texture(TextureIndexDirectSpecular)]],
                             texture2d<float, access::read_write> reflectionTex [[texture(TextureIndexReflection)]],
                             texture2d<float, access::read> historyDiffuseTex [[texture(TextureIndexHistoryDiffuse)]],
                             texture2d<float, access::read> historySpecularTex [[texture(TextureIndexHistorySpecular)]],
                             texture2d<float, access::read> historyReflectionTex [[texture(TextureIndexHistoryReflection)]],
                             texture2d<float, access::read> historyMomentsTex [[texture(DENOISE_TEXTURE_SLOT_MOMENTS_HISTORY)]],
                             texture2d<float, access::write> momentsTex [[texture(TextureIndexMoments)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.renderSize.x) || gid.y >= uint(u.renderSize.y)) return;

    float depth = depthTex.read(gid);
    float4 noisyDiffuse = diffuseTex.read(gid);
    float4 noisySpecular = specularTex.read(gid);
    float4 noisyReflection = reflectionTex.read(gid);
    if (is_background_depth(depth)) {
        diffuseTex.write(float4(0.0f), gid);
        specularTex.write(float4(0.0f), gid);
        reflectionTex.write(float4(0.0f), gid);
        momentsTex.write(float4(0.0f), gid);
        return;
    }

    float2 uv = pixel_center_uv(gid, u);
    float3 position = reconstruct_world_position(uv, depth, u.invViewProjection);
    float4 normalTexel = normalTex.read(gid);
    float3 normal = safe_normalize(normalTexel.xyz);
    float roughness = clamp(normalTexel.w, 0.02f, 1.0f);
    float3 lum = float3(luminance(noisyDiffuse.rgb), luminance(noisySpecular.rgb), luminance(noisyReflection.rgb));
    float hitDistance = noisyReflection.a;

    HistoryFetch surface;
    surface.weight = 0.0f;
    surface.colorA = float4(0.0f);
    surface.colorB = float4(0.0f);
    surface.moments = float4(0.0f);
    HistoryFetch virtualHit = surface;

    if (u.historyValid != 0u) {
        // Surface reprojection (diffuse + specular): motion vectors point current → previous.
        float2 motion = kDenoiseWarmup ? float2(0.0f) : motionTex.read(gid).xy;
        float2 prevUV = uv + motion * u.invRenderSize;
        float4 projected = project_with_w(position, u.prevViewProjection);
        if (projected.w > 0.0f) {
            float3 plane = float3(projected.z, 0.0f, 0.0f);
            surface = fetch_history(prevUV, plane, normal, u, prevDepthTex, prevNormalTex,
                                    historyDiffuseTex, historySpecularTex, historyMomentsTex);
        }

        // Virtual-point reprojection (reflection): the reflected radiance behaves like an
        // image at hit distance behind the reflector, so the point is pushed along the view
        // ray by hitDistance × (1 − smoothstep(0, 0.5, roughness)) — rougher lobes are
        // wider and their mean reflection stays closer to the surface.
        if (hitDistance > 0.0f) {
            float3 toSurface = position - u.cameraPosition;
            float viewDistance = length(toSurface);
            float3 viewDir = toSurface / max(viewDistance, 1e-4f);
            float virtualWeight = 1.0f - smoothstep(0.0f, 0.5f, roughness);
            float3 virtualPoint = position + viewDir * (hitDistance * virtualWeight);
            float4 projectedVirtual = project_with_w(virtualPoint, u.prevViewProjection);
            float3 plane;
            bool planeValid = fit_previous_depth_plane(position, normal, viewDistance, u.prevViewProjection, plane);
            if (projectedVirtual.w > 0.0f && planeValid) {
                virtualHit = fetch_history(projectedVirtual.xy, plane, normal, u, prevDepthTex, prevNormalTex,
                                           historyReflectionTex, historyReflectionTex, historyMomentsTex);
            }
        }
    }

    // Blend. Lighting (diffuse + specular) shares the surface history length; the
    // reflection resets whenever the surface history is rejected.
    float historyLength = 0.0f;
    float3 mean = lum;
    float3 second = lum * lum;
    float3 diffuse = noisyDiffuse.rgb;
    float3 specular = noisySpecular.rgb;
    float3 reflection = noisyReflection.rgb;

    if (surface.weight > 0.0f) {
        historyLength = max(unpack_moments_length(surface.moments), 0.0f);
        float inverse = 1.0f / (historyLength + 1.0f);
        float alpha = kDenoiseWarmup ? inverse : max(inverse, kDenoiseMinAlphaLighting);
        float3 previousMean = unpack_moments_mean(surface.moments);
        diffuse = mix(surface.colorA.rgb, noisyDiffuse.rgb, alpha);
        specular = mix(surface.colorB.rgb, noisySpecular.rgb, alpha);
        mean.x = mix(previousMean.x, lum.x, alpha);
        mean.y = mix(previousMean.y, lum.y, alpha);
        second.x = mix(surface.colorA.a, lum.x * lum.x, alpha);
        second.y = mix(surface.colorB.a, lum.y * lum.y, alpha);

        if (virtualHit.weight > 0.0f) {
            float alphaReflection = kDenoiseWarmup ? inverse : max(inverse, kDenoiseMinAlphaReflection);
            reflection = mix(virtualHit.colorA.rgb, noisyReflection.rgb, alphaReflection);
            mean.z = mix(unpack_moments_mean(virtualHit.moments).z, lum.z, alphaReflection);
            second.z = mix(virtualHit.colorA.a, lum.z * lum.z, alphaReflection);
        }
    }
    float newLength = (surface.weight > 0.0f) ? min(historyLength + 1.0f, kDenoiseMaxHistoryLength) : 1.0f;

    diffuseTex.write(float4(diffuse, second.x), gid);
    specularTex.write(float4(specular, second.y), gid);
    reflectionTex.write(float4(reflection, second.z), gid);
    momentsTex.write(pack_moments(mean, newLength), gid);
}

// MARK: - À-trous helpers

/// Linear (view-space) depth of pixel `p`; 0 for background.
inline float linear_depth_at(depth2d<float, access::read> depthTex, uint2 p, constant FrameUniforms &u) {
    float d = depthTex.read(p);
    return is_background_depth(d) ? 0.0f : linearize_depth(d, u.nearPlane, u.farPlane);
}

/// Screen-space gradient of the linear depth at `gid` (metres per pixel). Per axis the
/// smaller-magnitude one-sided difference is taken so depth discontinuities do not leak
/// into the surface slope (dFdx is unavailable in compute).
inline float2 depth_gradient(depth2d<float, access::read> depthTex, uint2 gid, int2 size, float zCenter,
                             constant FrameUniforms &u) {
    float2 gradient = float2(0.0f);
    for (uint axis = 0u; axis < 2u; ++axis) {
        int2 delta = (axis == 0u) ? int2(1, 0) : int2(0, 1);
        int2 p = int2(gid);
        int2 forwardPixel = p + delta;
        int2 backwardPixel = p - delta;
        float forward = 0.0f;
        float backward = 0.0f;
        if (forwardPixel.x < size.x && forwardPixel.y < size.y) {
            float z = linear_depth_at(depthTex, uint2(forwardPixel), u);
            forward = (z > 0.0f) ? (z - zCenter) : 0.0f;
        }
        if (backwardPixel.x >= 0 && backwardPixel.y >= 0) {
            float z = linear_depth_at(depthTex, uint2(backwardPixel), u);
            backward = (z > 0.0f) ? (zCenter - z) : 0.0f;
        }
        float g = (abs(forward) < abs(backward)) ? forward : backward;
        if (axis == 0u) {
            gradient.x = g;
        } else {
            gradient.y = g;
        }
    }
    return gradient;
}

/// Depth edge-stopping weight for a tap at `offset` pixels whose linear depth is `zTap`.
inline float depth_weight(float zTap, float zCenter, float2 depthGradient, int2 offset) {
    float slope = abs(dot(depthGradient, float2(offset)));
    return exp(-abs(zTap - zCenter) / (kDenoiseSigmaZ * slope + kDenoiseDepthEpsilon));
}

/// Normal edge-stopping weight.
inline float normal_weight(float3 nTap, float3 nCenter) {
    return pow(max(dot(nCenter, nTap), 0.0f), kDenoiseSigmaN);
}

/// Per-signal variance of pixel `p` for this iteration: iteration 1 derives it from the
/// moments (μ2 in the input alphas, μ1 in the Moments texture); later iterations read
/// the filtered variance carried in the input alphas.
inline float3 tap_variance(uint2 p, float4 diffuse, float4 specular, float4 reflection,
                           texture2d<float, access::read> momentsTex) {
    float3 second = float3(diffuse.a, specular.a, reflection.a);
    if (kDenoiseFirstIteration) {
        float3 mean = unpack_moments_mean(momentsTex.read(p));
        return max(second - mean * mean, 0.0f);
    }
    return max(second, 0.0f);
}

/// 5×5 bilateral (depth + normal weighted) variance of the luminance of the three
/// signals, used where the temporal history is too short to trust (SVGF).
inline float3 spatial_variance(uint2 gid, int2 size, float zCenter, float3 nCenter, float2 depthGradient,
                               constant FrameUniforms &u,
                               depth2d<float, access::read> depthTex,
                               texture2d<float, access::read> normalTex,
                               texture2d<float, access::read> inDiffuse,
                               texture2d<float, access::read> inSpecular,
                               texture2d<float, access::read> inReflection) {
    float3 sumL = float3(0.0f);
    float3 sumL2 = float3(0.0f);
    float sumW = 0.0f;
    for (int j = -2; j <= 2; ++j) {
        for (int i = -2; i <= 2; ++i) {
            int2 offset = int2(i, j);
            int2 p = int2(gid) + offset;
            if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y) {
                continue;
            }
            uint2 pixel = uint2(p);
            float zTap = linear_depth_at(depthTex, pixel, u);
            if (zTap <= 0.0f) {
                continue;
            }
            float3 nTap = safe_normalize(normalTex.read(pixel).xyz);
            float w = depth_weight(zTap, zCenter, depthGradient, offset) * normal_weight(nTap, nCenter);
            float3 l = float3(luminance(inDiffuse.read(pixel).rgb),
                              luminance(inSpecular.read(pixel).rgb),
                              luminance(inReflection.read(pixel).rgb));
            sumL += w * l;
            sumL2 += w * l * l;
            sumW += w;
        }
    }
    if (sumW <= 1e-6f) {
        return float3(0.0f);
    }
    float3 mean = sumL / sumW;
    return max(sumL2 / sumW - mean * mean, 0.0f);
}

/// 3×3 binomial prefilter of the variance carried in the input alphas (iterations ≥ 2).
inline float3 prefiltered_variance(uint2 gid, int2 size,
                                   texture2d<float, access::read> inDiffuse,
                                   texture2d<float, access::read> inSpecular,
                                   texture2d<float, access::read> inReflection) {
    float3 sum = float3(0.0f);
    float sumW = 0.0f;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            int2 p = int2(gid) + int2(i, j);
            if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y) {
                continue;
            }
            uint2 pixel = uint2(p);
            float w = kDenoiseBinomial3[i + 1] * kDenoiseBinomial3[j + 1];
            sum += w * float3(inDiffuse.read(pixel).a, inSpecular.read(pixel).a, inReflection.read(pixel).a);
            sumW += w;
        }
    }
    return max(sum / max(sumW, 1e-6f), 0.0f);
}

// MARK: - À-trous kernel

kernel void denoise_atrous(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                           depth2d<float, access::read> depthTex [[texture(TextureIndexDepth)]],
                           texture2d<float, access::read> normalTex [[texture(TextureIndexGBufferNormal)]],
                           texture2d<float, access::read> momentsTex [[texture(TextureIndexMoments)]],
                           texture2d<float, access::read> inDiffuse [[texture(TextureIndexDirectDiffuse)]],
                           texture2d<float, access::read> inSpecular [[texture(TextureIndexDirectSpecular)]],
                           texture2d<float, access::read> inReflection [[texture(TextureIndexReflection)]],
                           texture2d<float, access::read_write> outDiffuse [[texture(TextureIndexHistoryDiffuse)]],
                           texture2d<float, access::read_write> outSpecular [[texture(TextureIndexHistorySpecular)]],
                           texture2d<float, access::read_write> outReflection [[texture(TextureIndexHistoryReflection)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.renderSize.x) || gid.y >= uint(u.renderSize.y)) return;

    float depth = depthTex.read(gid);
    if (is_background_depth(depth)) {
        outDiffuse.write(float4(0.0f), gid);
        outSpecular.write(float4(0.0f), gid);
        outReflection.write(float4(0.0f), gid);
        return;
    }

    int2 size = int2(u.renderSize);
    float zCenter = linearize_depth(depth, u.nearPlane, u.farPlane);
    float3 nCenter = safe_normalize(normalTex.read(gid).xyz);
    float2 depthGradient = depth_gradient(depthTex, gid, size, zCenter, u);

    float4 centerDiffuse = inDiffuse.read(gid);
    float4 centerSpecular = inSpecular.read(gid);
    float4 centerReflection = inReflection.read(gid);
    float3 lumCenter = float3(luminance(centerDiffuse.rgb), luminance(centerSpecular.rgb), luminance(centerReflection.rgb));

    // Variance driving the luminance edge-stopping weight.
    float3 varianceCenter;
    if (kDenoiseFirstIteration) {
        varianceCenter = tap_variance(gid, centerDiffuse, centerSpecular, centerReflection, momentsTex);
        float historyLength = unpack_moments_length(momentsTex.read(gid));
        if (historyLength < kDenoiseSpatialVarianceHistory) {
            float3 spatial = spatial_variance(gid, size, zCenter, nCenter, depthGradient, u,
                                              depthTex, normalTex, inDiffuse, inSpecular, inReflection);
            varianceCenter = max(varianceCenter, spatial);
        }
    } else {
        varianceCenter = prefiltered_variance(gid, size, inDiffuse, inSpecular, inReflection);
    }
    float3 phiL = kDenoiseSigmaL * sqrt(varianceCenter + kDenoiseVarianceEpsilon);

    int step = int(kDenoiseStep);
    float3 sumDiffuse = float3(0.0f);
    float3 sumSpecular = float3(0.0f);
    float3 sumReflection = float3(0.0f);
    float3 sumVariance = float3(0.0f);
    float3 sumWeight = float3(0.0f);

    for (int j = -2; j <= 2; ++j) {
        for (int i = -2; i <= 2; ++i) {
            int2 offset = int2(i, j) * step;
            int2 p = int2(gid) + offset;
            if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y) {
                continue;
            }
            uint2 pixel = uint2(p);
            float h = kDenoiseB3[i + 2] * kDenoiseB3[j + 2];

            float4 tapDiffuse;
            float4 tapSpecular;
            float4 tapReflection;
            float3 w;
            if (i == 0 && j == 0) {
                tapDiffuse = centerDiffuse;
                tapSpecular = centerSpecular;
                tapReflection = centerReflection;
                w = float3(1.0f);
            } else {
                float zTap = linear_depth_at(depthTex, pixel, u);
                if (zTap <= 0.0f) {
                    continue;
                }
                float3 nTap = safe_normalize(normalTex.read(pixel).xyz);
                float wGeometry = depth_weight(zTap, zCenter, depthGradient, offset) * normal_weight(nTap, nCenter);
                tapDiffuse = inDiffuse.read(pixel);
                tapSpecular = inSpecular.read(pixel);
                tapReflection = inReflection.read(pixel);
                float3 lumTap = float3(luminance(tapDiffuse.rgb), luminance(tapSpecular.rgb), luminance(tapReflection.rgb));
                float3 wLuminance = exp(-abs(lumTap - lumCenter) / phiL);
                w = wGeometry * wLuminance;
            }

            float3 tapVar = tap_variance(pixel, tapDiffuse, tapSpecular, tapReflection, momentsTex);
            float3 hw = h * w;
            sumDiffuse += hw.x * tapDiffuse.rgb;
            sumSpecular += hw.y * tapSpecular.rgb;
            sumReflection += hw.z * tapReflection.rgb;
            sumVariance += hw * hw * tapVar;
            sumWeight += hw;
        }
    }

    float3 invWeight = 1.0f / max(sumWeight, 1e-6f);
    float3 filteredVariance = sumVariance * invWeight * invWeight;

    // The last iteration writes back into Direct*, whose alpha still holds the μ2 written
    // by the temporal pass; keep it so next frame's history carries complete moments.
    float3 alpha;
    if (kDenoiseFinal) {
        alpha = float3(outDiffuse.read(gid).a, outSpecular.read(gid).a, outReflection.read(gid).a);
    } else {
        alpha = filteredVariance;
    }

    outDiffuse.write(float4(sumDiffuse * invWeight.x, alpha.x), gid);
    outSpecular.write(float4(sumSpecular * invWeight.y, alpha.y), gid);
    outReflection.write(float4(sumReflection * invWeight.z, alpha.z), gid);
}
