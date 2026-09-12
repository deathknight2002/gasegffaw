//
//  Composite.metal
//  Bornless Ritual — deferred composite of the denoised lighting into HDRColor
//  (RENDER_CONTRACT §2 row 8 "CompositePass"; §1 function constant 2 `kDebugView`;
//  ShaderTypes.h TextureIndexHDRColor / TextureIndexHeat / TextureIndexFroxelScatter,
//  `FroxelParams`; Common.h `froxel_coordinate`, reversed-Z helpers, Fresnel).
//
//  Role: `composite_main` assembles, per pixel,
//      color = albedo · SSSDiffuse + DirectSpecular + Reflection · F · (1 − roughness)² + emissive
//  where
//    · SSSDiffuse is the denoised, subsurface-blurred Lambert irradiance / π (SSS.metal),
//      which ALREADY contains the unshadowed ambient term (Lighting.metal adds
//      `ambient_radiance × ambient` before the shadow-ray estimate), so no second
//      ambient term is added here — the job brief's "SSSDiffuse + ambient" would count
//      it twice against the actual Lighting.metal (recorded in the caveats);
//    · F is the roughness-aware Schlick Fresnel of Lagarde (2011):
//      F = f0 + (max(1 − roughness, f0) − f0)(1 − N·V)⁵ with f0 = specular_f0(albedo, metallic),
//      applied to the traced reflection which Reflection.metal leaves un-Fresnelled
//      ("reflection × F" is Composite's job); (1 − roughness)² fades glossy reflections
//      out on rough surfaces (the trace is only meaningful for glossy pixels);
//    · emissive comes straight from the G-buffer (chalk ring glow, later flame proxies).
//  Then the froxel volume is applied: the integrated in-scatter S and transmittance T
//  are trilinearly sampled at froxel_coordinate(uv, linearDepth) and
//  color = color · T + S. Background pixels (reversed-Z depth 0) write 0 — the flame,
//  sigil and daemon passes composite over HDRColor afterwards. Heat is cleared to 0 for
//  those passes to accumulate into.
//
//  Froxel conventions assumed of FroxelPass (Froxel.metal, another job): the volume
//  is laid out over the camera frustum in texture-space uv, slices follow Common.h's
//  exponential mapping over [FroxelParams.nearZ, farZ] in view-space (planar) depth,
//  and texel k holds the integral from the camera to the CENTRE of slice k, which is
//  what `froxel_coordinate` (z = slice / FROXEL_Z, trilinear) lines up with; if
//  FroxelPass integrates to slice boundaries the error is half a slice. A texel that is
//  exactly (0, 0, 0, 0) — an untouched or cleared volume — is treated as "no fog"
//  (T = 1, S = 0) so the scene stays visible while the volume is empty. nearZ / farZ
//  of an unwritten FroxelParams (zeros) fall back to 0.1 m / 12 m.
//
//  Debug views: `kDebugView` values mirror `DebugView` in App/SettingsModel.swift (the
//  truth for the numbering — the job brief's 1…8 list is superseded): 1 albedo,
//  2 normal, 3 roughness, 4 depth, 5 motion, 6 emissive, 7 direct diffuse (DenoisePass
//  skips itself for 7 and 8 so the raw estimate shows), 8 direct specular, 9 reflection,
//  10 denoised diffuse, 11 subsurface, 12 froxel in-scatter, 13 froxel transmittance,
//  15 diffuse variance (μ2 − μ1², Denoise.metal moments layout), 16 history length.
//  14 (heat) cannot be shown here — Heat is cleared by this kernel and written later —
//  and falls through to the lit image; PostPass owns it. Debug values are written into
//  HDRColor as-is, so PostPass should bypass exposure / tonemapping when kDebugView ≠ 0.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;

// MARK: - Function-constant derived switches

/// True when a debug visualisation replaces the lit image (compiled out otherwise).
constant bool kCompositeDebug = (kDebugView != 0u);

// MARK: - Constants

/// `DebugView` raw values (App/SettingsModel.swift).
constant uint kDebugViewAlbedo = 1u;
constant uint kDebugViewNormal = 2u;
constant uint kDebugViewRoughness = 3u;
constant uint kDebugViewDepth = 4u;
constant uint kDebugViewMotion = 5u;
constant uint kDebugViewEmissive = 6u;
constant uint kDebugViewDirectDiffuse = 7u;
constant uint kDebugViewDirectSpecular = 8u;
constant uint kDebugViewReflection = 9u;
constant uint kDebugViewDenoisedDiffuse = 10u;
constant uint kDebugViewSSS = 11u;
constant uint kDebugViewFroxelScatter = 12u;
constant uint kDebugViewFroxelTransmittance = 13u;
constant uint kDebugViewVariance = 15u;
constant uint kDebugViewHistoryLength = 16u;

/// Depth debug view: white at the camera, black at this many metres.
constant float kDebugDepthRange = 12.0f;
/// Motion debug view: ±this many pixels map to [0, 1] around 0.5.
constant float kDebugMotionRange = 16.0f;
/// Variance debug view gain.
constant float kDebugVarianceGain = 4.0f;
/// History-length debug view: white at this many frames (Denoise.metal caps at 64).
constant float kDebugHistoryRange = 64.0f;
/// Fallback froxel range when FroxelParams has not been written (FroxelParams doc: 0.1 m / 12 m).
constant float kDefaultFroxelNearZ = 0.1f;
constant float kDefaultFroxelFarZ = 12.0f;

/// Trilinear, edge-clamped sampler for the 3-D scatter volume.
constexpr sampler kFroxelSampler(filter::linear, mip_filter::none, address::clamp_to_edge);

// MARK: - Helpers

/// Roughness-aware Schlick Fresnel (Lagarde 2011): rough surfaces lose grazing reflectance.
inline float3 fresnel_schlick_roughness(float NdotV, float3 f0, float roughness) {
    float3 fr = max(float3(1.0f - roughness), f0);
    float m = 1.0f - NdotV;
    float m2 = m * m;
    return f0 + (fr - f0) * (m2 * m2 * m);
}

/// Integrated in-scatter (rgb) and transmittance (a) in front of a surface at texture
/// uv and linear view depth (see the header for the conventions and the empty-volume rule).
inline float4 sample_froxel_scatter(texture3d<float, access::sample> froxels, float2 uv, float linearDepth,
                                    constant FroxelParams &params) {
    float nearZ = (params.nearZ > 0.0f) ? params.nearZ : kDefaultFroxelNearZ;
    float farZ = (params.farZ > nearZ) ? params.farZ : max(kDefaultFroxelFarZ, nearZ * 2.0f);
    float3 coordinate = froxel_coordinate(uv, linearDepth, nearZ, farZ);
    float4 s = froxels.sample(kFroxelSampler, coordinate);
    if (isnan(s.a) || (s.a <= 0.0f && dot(s.rgb, s.rgb) <= 0.0f)) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }
    return float4(max(s.rgb, 0.0f), saturate(s.a));
}

/// Debug visualisation for `kDebugView`; `litColor` is returned for views this kernel
/// cannot show (heat) and for unknown values.
inline float3 composite_debug_view(uint2 gid, float depth, float linearDepth, float4 fog, float3 litColor,
                                   constant FrameUniforms &u,
                                   texture2d<float, access::read> albedoTex,
                                   texture2d<float, access::read> normalTex,
                                   texture2d<float, access::read> emissiveTex,
                                   texture2d<float, access::read> motionTex,
                                   texture2d<float, access::read> diffuseTex,
                                   texture2d<float, access::read> specularTex,
                                   texture2d<float, access::read> reflectionTex,
                                   texture2d<float, access::read> sssTex,
                                   texture2d<float, access::read> momentsTex) {
    switch (kDebugView) {
        case kDebugViewAlbedo:
            return albedoTex.read(gid).rgb;
        case kDebugViewNormal:
            return safe_normalize(normalTex.read(gid).xyz) * 0.5f + 0.5f;
        case kDebugViewRoughness:
            return float3(normalTex.read(gid).w);
        case kDebugViewDepth:
            return float3(is_background_depth(depth) ? 0.0f : saturate(1.0f - linearDepth / kDebugDepthRange));
        case kDebugViewMotion: {
            float2 motion = motionTex.read(gid).xy;
            return float3(saturate(motion / kDebugMotionRange + 0.5f), 0.0f);
        }
        case kDebugViewEmissive:
            return max(emissiveTex.read(gid).rgb, 0.0f);
        case kDebugViewDirectDiffuse:
            return max(diffuseTex.read(gid).rgb, 0.0f);
        case kDebugViewDirectSpecular:
            return max(specularTex.read(gid).rgb, 0.0f);
        case kDebugViewReflection:
            return max(reflectionTex.read(gid).rgb, 0.0f);
        case kDebugViewDenoisedDiffuse:
            return max(diffuseTex.read(gid).rgb, 0.0f);
        case kDebugViewSSS:
            return max(sssTex.read(gid).rgb, 0.0f);
        case kDebugViewFroxelScatter:
            return fog.rgb;
        case kDebugViewFroxelTransmittance:
            return float3(fog.a);
        case kDebugViewVariance: {
            float4 diffuse = diffuseTex.read(gid);
            float4 moments = momentsTex.read(gid);
            float variance = max(diffuse.a - moments.r * moments.r, 0.0f);
            return float3(saturate(variance * kDebugVarianceGain));
        }
        case kDebugViewHistoryLength:
            return float3(saturate(momentsTex.read(gid).b / kDebugHistoryRange));
        default:
            return litColor;
    }
}

// MARK: - Kernel

kernel void composite_main(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                           constant FroxelParams &froxelParams [[buffer(BufferIndexFroxelParams)]],
                           texture2d<float, access::read> albedoTex [[texture(TextureIndexGBufferAlbedo)]],
                           texture2d<float, access::read> normalTex [[texture(TextureIndexGBufferNormal)]],
                           texture2d<float, access::read> emissiveTex [[texture(TextureIndexGBufferEmissive)]],
                           texture2d<float, access::read> motionTex [[texture(TextureIndexGBufferMotion)]],
                           depth2d<float, access::read> depthTex [[texture(TextureIndexDepth)]],
                           texture2d<float, access::read> diffuseTex [[texture(TextureIndexDirectDiffuse)]],
                           texture2d<float, access::read> specularTex [[texture(TextureIndexDirectSpecular)]],
                           texture2d<float, access::read> reflectionTex [[texture(TextureIndexReflection)]],
                           texture2d<float, access::read> sssTex [[texture(TextureIndexSSSDiffuse)]],
                           texture2d<float, access::read> momentsTex [[texture(TextureIndexMoments)]],
                           texture3d<float, access::sample> froxelTex [[texture(TextureIndexFroxelScatter)]],
                           texture2d<float, access::write> hdrTex [[texture(TextureIndexHDRColor)]],
                           texture2d<float, access::write> heatTex [[texture(TextureIndexHeat)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.renderSize.x) || gid.y >= uint(u.renderSize.y)) return;

    // Heat starts at zero every frame; FlamePass / SigilPass / DaemonPass add to it.
    heatTex.write(float4(0.0f), gid);

    float depth = depthTex.read(gid);
    bool background = is_background_depth(depth);
    float2 uv = pixel_center_uv(gid, u);
    // Background keeps the far end of the froxel range so the debug views stay defined.
    float linearDepth = background ? u.farPlane : linearize_depth(depth, u.nearPlane, u.farPlane);
    float4 fog = sample_froxel_scatter(froxelTex, uv, linearDepth, froxelParams);

    float3 color = float3(0.0f);
    if (!background) {
        float4 albedoTexel = albedoTex.read(gid);
        float4 normalTexel = normalTex.read(gid);
        float4 emissiveTexel = emissiveTex.read(gid);
        float3 albedo = saturate(albedoTexel.rgb);
        float3 normal = safe_normalize(normalTexel.xyz);
        float roughness = clamp(normalTexel.w, 0.02f, 1.0f);
        float metallic = saturate(emissiveTexel.a);

        float3 position = reconstruct_world_position(uv, depth, u.invViewProjection);
        float3 view = safe_normalize(u.cameraPosition - position, normal);
        float NdotV = saturate(dot(normal, view));
        float3 f0 = specular_f0(albedo, metallic);
        float3 fresnel = fresnel_schlick_roughness(NdotV, f0, roughness);
        float glossFade = sqr(1.0f - roughness);

        float3 diffuseIrradiance = max(sssTex.read(gid).rgb, 0.0f);   // includes the ambient term (Lighting.metal)
        float3 specular = max(specularTex.read(gid).rgb, 0.0f);
        float3 reflection = max(reflectionTex.read(gid).rgb, 0.0f);
        float3 emissive = max(emissiveTexel.rgb, 0.0f);

        color = albedo * diffuseIrradiance + specular + reflection * fresnel * glossFade + emissive;
        color = color * fog.a + fog.rgb;
    }

    if (kCompositeDebug) {
        color = composite_debug_view(gid, depth, linearDepth, fog, color, u,
                                     albedoTex, normalTex, emissiveTex, motionTex,
                                     diffuseTex, specularTex, reflectionTex, sssTex, momentsTex);
    }

    hdrTex.write(float4(max(color, 0.0f), background ? 0.0f : 1.0f), gid);
}
