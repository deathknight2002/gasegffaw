//
//  Lighting.metal
//  Bornless Ritual — direct lighting with one shadow ray per pixel
//  (RENDER_CONTRACT §2 row 3 "DirectLightingPass", §4 SDF soft shadows, §5 RT shadow
//  rays; ARCHITECTURE §6 hash-driven randomness keyed by (seed, frameIndex, pixel)).
//
//  Role: `lighting_direct` reconstructs the world position from reversed-Z depth,
//  reads the G-buffer, builds a CDF over the lights' importance
//  luminance(I) / (d² + r²), picks ONE light with hash_unit(seed, frameIndex, pixel, 0),
//  samples a point on its surface (sphere / daemon: uniform on the sphere; ring:
//  uniform angles on the torus), traces a shadow ray (kRenderPath == RENDER_PATH_RT:
//  RT.h `rtShadowRay`; fallback: SDF.h `sdfSoftShadow`) and weights the sample by
//  1 / (P(light) · pdf_area) — a one-sample estimator over all lights, unbiased.
//  Outputs (both rgba16Float, noisy, denoised by DenoisePass):
//    TextureIndexDirectDiffuse  rgb = Lambert irradiance / π WITHOUT albedo (so the SSS
//                                blur operates on irradiance; Composite multiplies by
//                                albedo), scaled by (1 − metallic); plus the unshadowed
//                                ambient term × `ambient`. a = shadow visibility.
//    TextureIndexDirectSpecular rgb = GGX specular radiance (D·V·F with Fresnel from
//                                specular_f0(albedo, metallic)); a = distance to the
//                                sampled light point (for the denoiser).
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"
#include "SDF.h"
#include "RT.h"
#include "LightShading.h"

using namespace metal;
using namespace metal::raytracing;

// MARK: - Function-constant derived switches

/// True when the pipeline is specialised for the RT path (acceleration structure bound).
constant bool kLightingUsesRT = (kRenderPath == RENDER_PATH_RT);
/// True when the pipeline is specialised for the SDF fallback (SDF scene bound).
constant bool kLightingUsesSDF = !kLightingUsesRT;

// MARK: - Emitter sampling

/// A point sampled on an emitter's surface with everything the estimator needs.
struct EmitterSample {
    float3 position;        ///< world-space point on the emitter
    float3 normal;          ///< outward emitter normal at the point
    float3 radiance;        ///< emitted radiance L_e (uniform over the emitter)
    float invAreaPdf;       ///< 1 / pdf_area of the sample (m²)
    float shadowRadius;     ///< radius handed to the SDF cone shadow (tube / sphere radius)
};

/// Samples a point on `light` with two uniforms. Sphere and daemon lights are uniform
/// on the sphere surface (pdf = 1 / 4πr²), rings uniform in (θ, φ) on the torus
/// (pdf_area = 1 / (4π² r (R + r cos φ))). The emitted radiance follows from the
/// radiant-intensity convention in LightShading.h: sphere L_e = I / (π r²) (projected
/// disc), ring L_e = I / (4π R r) (on-axis projected annulus).
inline EmitterSample sample_emitter(LightData light, float2 xi) {
    EmitterSample sample;
    float3 color = light_color(light);
    if (light.type == LIGHT_TYPE_RING) {
        float majorRadius = max(light.ringRadius, 1e-3f);
        float tubeRadius = max(light.radius, 1e-3f);
        float3 point = sample_ring_light(light.position, majorRadius, tubeRadius, xi);
        float theta = kTwoPi * xi.x;                       // same angle as sample_ring_light
        float3 radial = float3(cos(theta), 0.0f, sin(theta));
        float3 ringPoint = light.position + majorRadius * radial;
        float3 normal = safe_normalize(point - ringPoint, float3(0.0f, 1.0f, 0.0f));
        float cosPhi = dot(normal, radial);
        sample.position = point;
        sample.normal = normal;
        sample.radiance = color / (4.0f * kPi * majorRadius * tubeRadius);
        sample.invAreaPdf = 4.0f * kPi * kPi * tubeRadius * (majorRadius + tubeRadius * cosPhi);
        sample.shadowRadius = tubeRadius;
    } else {
        float radius = max(light.radius, 1e-3f);
        float3 direction = sample_sphere_direction(xi);
        sample.position = light.position + radius * direction;
        sample.normal = direction;
        sample.radiance = color / (kPi * radius * radius);
        sample.invAreaPdf = 4.0f * kPi * radius * radius;
        sample.shadowRadius = radius;
    }
    return sample;
}

// MARK: - Kernel

kernel void lighting_direct(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                            device const LightData *lights [[buffer(BufferIndexLights)]],
                            device const MaterialData *materials [[buffer(BufferIndexMaterials)]],
                            instance_acceleration_structure accel [[buffer(BufferIndexAccel), function_constant(kLightingUsesRT)]],
                            constant SDFScene &sdf [[buffer(BufferIndexSDFScene), function_constant(kLightingUsesSDF)]],
                            texture2d<float, access::read> albedoTex [[texture(TextureIndexGBufferAlbedo)]],
                            texture2d<float, access::read> normalTex [[texture(TextureIndexGBufferNormal)]],
                            texture2d<float, access::read> emissiveTex [[texture(TextureIndexGBufferEmissive)]],
                            depth2d<float, access::read> depthTex [[texture(TextureIndexDepth)]],
                            texture2d<float, access::write> outDiffuse [[texture(TextureIndexDirectDiffuse)]],
                            texture2d<float, access::write> outSpecular [[texture(TextureIndexDirectSpecular)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.renderSize.x) || gid.y >= uint(u.renderSize.y)) return;

    // Sky / background: nothing was rasterised here.
    float depth = depthTex.read(gid);
    if (is_background_depth(depth)) {
        outDiffuse.write(float4(0.0f), gid);
        outSpecular.write(float4(0.0f), gid);
        return;
    }

    // Surface from the G-buffer (the jittered inverse view-projection matches the rasterised depth).
    float2 uv = pixel_center_uv(gid, u);
    float3 position = reconstruct_world_position(uv, depth, u.invViewProjection);
    float4 albedoTexel = albedoTex.read(gid);
    float4 normalTexel = normalTex.read(gid);
    float4 emissiveTexel = emissiveTex.read(gid);
    uint materialIndex = uint(albedoTexel.a * 255.0f + 0.5f);
    device const MaterialData &material = materials[materialIndex];

    // Flame proxies (MATERIAL_FLAG_NO_SHADOW), if ever rasterised, receive no light.
    if ((material.flags & MATERIAL_FLAG_NO_SHADOW) != 0u) {
        outDiffuse.write(float4(0.0f), gid);
        outSpecular.write(float4(0.0f), gid);
        return;
    }

    float3 normal = safe_normalize(normalTexel.xyz);
    float roughness = clamp(normalTexel.w, 0.02f, 1.0f);
    float metallic = saturate(emissiveTexel.a);
    float3 albedo = albedoTexel.rgb;
    float3 view = safe_normalize(u.cameraPosition - position, normal);
    float NdotV = max(dot(normal, view), 1e-4f);
    float3 f0 = specular_f0(albedo, metallic);
    float diffuseScale = 1.0f - metallic;

    // Unshadowed ambient (E / π of a uniform environment equals its radiance).
    float3 diffuse = ambient_radiance(u, lights) * diffuseScale;
    float3 specular = float3(0.0f);
    float visibility = 1.0f;
    float lightDistance = 0.0f;

    // Importance CDF over the lights.
    uint lightCount = min(u.lightCount, uint(MAX_LIGHTS));
    float importance[MAX_LIGHTS];
    float total = 0.0f;
    for (uint i = 0u; i < uint(MAX_LIGHTS); ++i) {
        float value = (i < lightCount) ? light_importance(lights[i], position, normal) : 0.0f;
        importance[i] = value;
        total += value;
    }

    if (total > 0.0f) {
        uint pixelIndex = gid.y * uint(u.renderSize.x) + gid.x;
        float xiSelect = hash_unit(hash_frame(u, u.frameIndex, pixelIndex, 0u));
        float target = xiSelect * total;
        uint chosen = 0xFFFFFFFFu;
        float cumulative = 0.0f;
        for (uint i = 0u; i < lightCount; ++i) {
            if (importance[i] <= 0.0f) {
                continue;
            }
            cumulative += importance[i];
            chosen = i;                       // the last positive entry catches float round-off at the top
            if (target < cumulative) {
                break;
            }
        }

        if (chosen != 0xFFFFFFFFu) {
            float selectProbability = importance[chosen] / total;
            float2 xi = hash_unit2(u.seedLo, u.seedHi, u.frameIndex, pixelIndex, 1u);
            EmitterSample emitter = sample_emitter(lights[chosen], xi);
            float3 toSample = emitter.position - position;
            float distance = length(toSample);
            if (distance > 1e-4f) {
                float3 lightDir = toSample / distance;
                float NdotL = dot(normal, lightDir);
                float cosEmitter = dot(emitter.normal, -lightDir);
                lightDistance = distance;
                if (NdotL > 0.0f && cosEmitter > 0.0f) {
                    float3 origin = rt_offset_origin(position, normal);
                    float maxT = max(distance - 2.0f * kRTOriginOffset, kRTOriginOffset);
                    if (kLightingUsesSDF) {
                        visibility = sdfSoftShadow(origin, lightDir, maxT, emitter.shadowRadius, sdf);
                    } else {
                        visibility = rtShadowRay(accel, origin, lightDir, maxT) ? 0.0f : 1.0f;
                    }
                    // Irradiance estimate: L_e · cosθ · cosθ_l / d² · (1 / (P(light) · pdf_area)).
                    float geometry = NdotL * cosEmitter / (distance * distance);
                    float weight = emitter.invAreaPdf / max(selectProbability, 1e-6f);
                    float3 irradiance = emitter.radiance * (geometry * weight * visibility);

                    diffuse += irradiance * (kInvPi * diffuseScale);

                    float3 halfVector = safe_normalize(lightDir + view, normal);
                    float NdotH = saturate(dot(normal, halfVector));
                    float VdotH = saturate(dot(view, halfVector));
                    specular += ggx_specular(NdotL, NdotV, NdotH, VdotH, roughness, f0) * irradiance;
                }
            }
        }
    }

    outDiffuse.write(float4(diffuse, visibility), gid);
    outSpecular.write(float4(specular, lightDistance), gid);
}
