//
//  GBuffer.metal
//  Bornless Ritual — G-buffer rasterisation (RENDER_CONTRACT §2 row 2 "GBufferPass",
//  §3 motion vectors & jitter; ShaderTypes.h `Vertex`, `InstanceData`, `MaterialData`,
//  TextureIndexGBuffer* formats).
//
//  Role: `gbuffer_vertex` transforms every instance by its model matrix, projects it
//  with the jittered view-projection and carries the un-jittered current and previous
//  clip positions for motion vectors. `gbuffer_fragment` samples the procedural
//  albedo/normal atlases (triplanar for stone materials using world position and
//  normal, uv for cloth/wax/skin/iron), perturbs the normal (TBN or whiteout triplanar
//  blend), applies the chalk decal on MATERIAL_FLAG_CHALK surfaces (the kindled ring
//  emits ember glow ∝ ringKindle × mask) and writes the four render targets:
//    color(0) TextureIndexGBufferAlbedo   rgba8Unorm  linear albedo, a = materialIndex / 255
//    color(1) TextureIndexGBufferNormal   rgba16Float world normal xyz, w roughness
//    color(2) TextureIndexGBufferMotion   rg16Float   motion in render pixels (current → previous)
//    color(3) TextureIndexGBufferEmissive rgba16Float emissive radiance rgb, a metallic
//  Depth is reversed-Z (clear 0, compare greater), owned by GBufferPass.swift.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;

// MARK: - Constants

/// Linear albedo of chalk (RENDER_CONTRACT job spec) and its roughness.
constant float3 kChalkAlbedo = float3(0.85f, 0.85f, 0.80f);
constant float kChalkRoughness = 0.7f;
/// Ember colour temperature of the kindled ring (embers are born at 1900 K, ARCHITECTURE §6).
constant float kRingEmberTemperatureK = 1900.0f;
/// Peak emissive radiance of the chalk ring at ringKindle = 1 (linear, before exposure).
constant float kRingEmberRadiance = 3.0f;
/// Chamber floor half extent in metres (interior 6 m × 6 m centred at the origin, ARCHITECTURE §2).
/// The chalk mask is assumed to cover the whole floor: uv = (x, z) / 6 + 0.5.
constant float kChamberHalfExtent = 3.0f;
/// Radial band (metres from the origin) that kindles: the double circle at 1.45 m / 1.60 m
/// and the name letters between the circles.
constant float kRingBandInner = 1.38f;
constant float kRingBandOuter = 1.67f;
constant float kRingBandFeather = 0.04f;
/// Triplanar blend sharpness (weights = |n|^k, normalised).
constant float kTriplanarSharpness = 4.0f;
/// `MaterialData.textureLayer` value meaning "no atlas" (ShaderTypes.h).
constant uint kNoTextureLayer = 0xFFFFFFFFu;

/// Trilinear, repeating sampler for the material atlases.
constexpr sampler kAtlasSampler(filter::linear, mip_filter::linear, address::repeat);
/// Bilinear, clamp-to-zero sampler for the single-level chalk mask.
constexpr sampler kChalkSampler(filter::linear, mip_filter::none, address::clamp_to_zero);

// MARK: - Stage interfaces

/// Vertex fetch layout; matches `Vertex` in ShaderTypes.h and the descriptor built by GBufferPass.swift.
struct GBufferVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float4 tangent  [[attribute(2)]];   // xyz + handedness in w
    float2 uv       [[attribute(3)]];
};

/// Rasteriser varyings.
struct GBufferVaryings {
    float4 position [[position]];       // jittered clip position
    float3 worldPosition;
    float3 worldNormal;
    float4 worldTangent;                // xyz world tangent, w handedness
    float2 uv;
    float4 currentClip;                 // un-jittered view-projection × world position
    float4 previousClip;                // previous un-jittered view-projection × prevModel × position
    uint materialIndex [[flat]];
};

/// Multiple render target outputs (attachment order fixed by GBufferPass.swift).
struct GBufferOut {
    float4 albedo        [[color(0)]];
    float4 normalRough   [[color(1)]];
    float2 motion        [[color(2)]];
    float4 emissiveMetal [[color(3)]];
};

/// Result of the atlas lookups for one fragment.
struct AtlasSurface {
    float3 albedo;      ///< atlas albedo (1 when the material has no atlas)
    float3 normal;      ///< perturbed world normal
    float roughness;    ///< atlas roughness factor (1 when the material has no atlas)
};

// MARK: - Helpers

/// True for the materials that are textured with world-space triplanar projection.
inline bool layer_is_stone(uint layer) {
    return layer == uint(MaterialTextureLayerFloorStone)
        || layer == uint(MaterialTextureLayerWallStone)
        || layer == uint(MaterialTextureLayerAltarStone);
}

/// Decodes a normal-atlas texel (xy in [0,1] → tangent-space normal, +Z up) and scales
/// its tilt by `strength`.
inline float3 decode_atlas_normal(float4 texel, float strength) {
    float2 xy = (texel.xy * 2.0f - 1.0f) * strength;
    float z = sqrt(max(1.0f - dot(xy, xy), 0.0f));
    return safe_normalize(float3(xy, z), float3(0.0f, 0.0f, 1.0f));
}

/// Texture-space uv (y down) of a clip-space position; falls back to `fallback` when
/// the position is behind the camera (w ≤ 0).
inline float2 clip_to_uv(float4 clip, float2 fallback) {
    if (clip.w <= 1e-6f) {
        return fallback;
    }
    float2 ndc = clip.xy / clip.w;
    return float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);
}

/// World-space triplanar sampling of the atlases with a whiteout normal blend
/// (Golus 2017): each axis projection contributes a tangent-space normal swizzled into
/// world orientation; uv flips per axis sign keep the projections unmirrored.
inline AtlasSurface sample_triplanar(texture2d_array<float> albedoAtlas,
                                     texture2d_array<float> normalAtlas,
                                     uint layer, float3 worldPosition, float3 normal,
                                     float uvScale, float normalStrength) {
    float3 blend = pow(abs(normal), float3(kTriplanarSharpness));
    blend /= max(blend.x + blend.y + blend.z, 1e-5f);
    float3 axisSign = select(float3(-1.0f), float3(1.0f), normal >= 0.0f);

    float2 uvX = worldPosition.zy * uvScale;
    float2 uvY = worldPosition.xz * uvScale;
    float2 uvZ = worldPosition.xy * uvScale;
    uvX.x *= axisSign.x;
    uvY.x *= axisSign.y;
    uvZ.x *= -axisSign.z;

    float4 albedoX = albedoAtlas.sample(kAtlasSampler, uvX, layer);
    float4 albedoY = albedoAtlas.sample(kAtlasSampler, uvY, layer);
    float4 albedoZ = albedoAtlas.sample(kAtlasSampler, uvZ, layer);
    float4 normalX = normalAtlas.sample(kAtlasSampler, uvX, layer);
    float4 normalY = normalAtlas.sample(kAtlasSampler, uvY, layer);
    float4 normalZ = normalAtlas.sample(kAtlasSampler, uvZ, layer);

    float3 tnX = decode_atlas_normal(normalX, normalStrength);
    float3 tnY = decode_atlas_normal(normalY, normalStrength);
    float3 tnZ = decode_atlas_normal(normalZ, normalStrength);
    // Undo the uv flips on the tangent-space x component.
    tnX.x *= axisSign.x;
    tnY.x *= axisSign.y;
    tnZ.x *= -axisSign.z;
    // Whiteout blend: add the world normal's in-plane components, keep its sign on the axis.
    tnX = float3(tnX.xy + normal.zy, abs(tnX.z) * normal.x);
    tnY = float3(tnY.xy + normal.xz, abs(tnY.z) * normal.y);
    tnZ = float3(tnZ.xy + normal.xy, abs(tnZ.z) * normal.z);

    AtlasSurface surface;
    surface.albedo = albedoX.rgb * blend.x + albedoY.rgb * blend.y + albedoZ.rgb * blend.z;
    surface.normal = safe_normalize(tnX.zyx * blend.x + tnY.xzy * blend.y + tnZ.xyz * blend.z, normal);
    surface.roughness = normalX.z * blend.x + normalY.z * blend.y + normalZ.z * blend.z;
    return surface;
}

/// uv-mapped sampling of the atlases with a TBN normal perturbation. A degenerate
/// vertex tangent falls back to an arbitrary orthonormal basis around the normal.
inline AtlasSurface sample_uv_mapped(texture2d_array<float> albedoAtlas,
                                     texture2d_array<float> normalAtlas,
                                     uint layer, float2 uv, float3 normal, float4 tangent,
                                     float uvScale, float normalStrength) {
    float2 st = uv * uvScale;
    float4 albedoTexel = albedoAtlas.sample(kAtlasSampler, st, layer);
    float4 normalTexel = normalAtlas.sample(kAtlasSampler, st, layer);
    float3 tn = decode_atlas_normal(normalTexel, normalStrength);

    float3 t;
    float3 b;
    float3 projected = tangent.xyz - normal * dot(normal, tangent.xyz);
    if (dot(projected, projected) > 1e-8f) {
        t = normalize(projected);
        b = cross(normal, t) * (tangent.w < 0.0f ? -1.0f : 1.0f);
    } else {
        orthonormal_basis(normal, t, b);
    }

    AtlasSurface surface;
    surface.albedo = albedoTexel.rgb;
    surface.normal = safe_normalize(t * tn.x + b * tn.y + normal * tn.z, normal);
    surface.roughness = normalTexel.z;
    return surface;
}

// MARK: - Vertex

vertex GBufferVaryings gbuffer_vertex(GBufferVertexIn in [[stage_in]],
                                      constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                                      device const InstanceData *instances [[buffer(BufferIndexInstances)]],
                                      uint instanceID [[instance_id]]) {
    device const InstanceData &instance = instances[instanceID];

    float4 localPosition = float4(in.position, 1.0f);
    float4 worldPosition = instance.model * localPosition;
    float4 previousWorldPosition = instance.prevModel * localPosition;

    GBufferVaryings out;
    out.position = u.viewProjection * worldPosition;
    out.currentClip = u.unjitteredViewProjection * worldPosition;
    out.previousClip = u.prevViewProjection * previousWorldPosition;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = (instance.normalMatrix * float4(in.normal, 0.0f)).xyz;
    out.worldTangent = float4((instance.model * float4(in.tangent.xyz, 0.0f)).xyz, in.tangent.w);
    out.uv = in.uv;
    out.materialIndex = instance.materialIndex;
    return out;
}

// MARK: - Fragment

fragment GBufferOut gbuffer_fragment(GBufferVaryings in [[stage_in]],
                                     bool frontFacing [[front_facing]],
                                     constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                                     device const MaterialData *materials [[buffer(BufferIndexMaterials)]],
                                     texture2d_array<float> albedoAtlas [[texture(TextureIndexAlbedoAtlas)]],
                                     texture2d_array<float> normalAtlas [[texture(TextureIndexNormalAtlas)]],
                                     texture2d<float> chalkMask [[texture(TextureIndexChalkMask)]]) {
    device const MaterialData &material = materials[in.materialIndex];

    // Two-sided geometric normal (the room is drawn without culling).
    float3 geometricNormal = safe_normalize(in.worldNormal);
    if (!frontFacing) {
        geometricNormal = -geometricNormal;
    }

    // Atlas lookups.
    AtlasSurface surface;
    uint layer = material.textureLayer;
    if (layer == kNoTextureLayer || layer >= uint(MaterialTextureLayerCount)) {
        surface.albedo = float3(1.0f);
        surface.normal = geometricNormal;
        surface.roughness = 1.0f;
    } else if (layer_is_stone(layer)) {
        surface = sample_triplanar(albedoAtlas, normalAtlas, layer, in.worldPosition, geometricNormal,
                                   material.uvScale, material.normalStrength);
    } else {
        surface = sample_uv_mapped(albedoAtlas, normalAtlas, layer, in.uv, geometricNormal, in.worldTangent,
                                   material.uvScale, material.normalStrength);
    }

    float3 albedo = material.albedo * surface.albedo;
    float roughness = material.roughness * surface.roughness;
    float3 emissive = material.emissive;
    float metallic = saturate(material.metallic);

    // Chalk decal (floor): mask → chalk albedo/roughness, kindled ring → ember glow.
    if ((material.flags & MATERIAL_FLAG_CHALK) != 0u) {
        float2 chalkUV = in.worldPosition.xz / (2.0f * kChamberHalfExtent) + 0.5f;
        float mask = chalkMask.sample(kChalkSampler, chalkUV).r;
        albedo = mix(albedo, kChalkAlbedo, mask);
        roughness = mix(roughness, kChalkRoughness, mask);
        float radius = length(in.worldPosition.xz);
        float band = smoothstep(kRingBandInner - kRingBandFeather, kRingBandInner, radius)
                   * (1.0f - smoothstep(kRingBandOuter, kRingBandOuter + kRingBandFeather, radius));
        float glow = kRingEmberRadiance * saturate(u.ringKindle) * mask * band;
        emissive += blackbody_rgb(kRingEmberTemperatureK) * glow;
    }

    // Motion: texture-space pixels from the current pixel to where it was last frame.
    float2 currentUV = clip_to_uv(in.currentClip, in.position.xy * u.invRenderSize);
    float2 previousUV = clip_to_uv(in.previousClip, currentUV);
    float2 motion = (previousUV - currentUV) * u.renderSize;

    GBufferOut out;
    out.albedo = float4(saturate(albedo), float(in.materialIndex) * (1.0f / 255.0f));
    out.normalRough = float4(surface.normal, clamp(roughness, 0.02f, 1.0f));
    out.motion = motion;
    out.emissiveMetal = float4(max(emissive, 0.0f), metallic);
    return out;
}
