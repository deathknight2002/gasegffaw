//
//  Reflection.metal
//  Bornless Ritual — traced glossy reflections (RENDER_CONTRACT §2 row 4
//  "ReflectionPass", §4 SDF sphere march, §5 RT closest hit + hit reconstruction).
//
//  Role: `reflection_trace` runs only on pixels whose material carries
//  MATERIAL_FLAG_GLOSSY or whose G-buffer roughness is below 0.35. It samples a GGX
//  visible-normal (VNDF, Heitz 2018) half vector from two hash uniforms, reflects the
//  view direction and traces one ray:
//    RT path:  RT.h `rtClosestHit` + `reconstructHit` → material albedo / emissive,
//              Lambert from the two strongest lights (no secondary shadow) + ambient;
//    fallback: SDF.h `sdfMarch` (64 steps, 8 m) → material id → the same shading.
//  A miss returns the dim chamber ambient. Flames are not in the acceleration
//  structure (nor the SDF), so an analytic flame glow is added when the reflected ray
//  passes within 4 cm of a flame (FlameData) before its hit.
//  Output TextureIndexReflection (rgba16Float): rgb = incoming radiance along the
//  sampled direction × G2/G1 (Fresnel is applied by CompositePass, "reflection × F"),
//  a = hit distance (8 m on a miss, 0 for pixels that were not traced).
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

/// True when the pipeline is specialised for the RT path (AS + geometry buffers bound).
constant bool kReflectionUsesRT = (kRenderPath == RENDER_PATH_RT);
/// True when the pipeline is specialised for the SDF fallback (SDF scene bound).
constant bool kReflectionUsesSDF = !kReflectionUsesRT;

// MARK: - Constants

/// Maximum reflection ray length (RENDER_CONTRACT §4: 8 m).
constant float kReflectionMaxDistance = 8.0f;
/// Roughness below which non-glossy materials are still traced.
constant float kReflectionRoughnessCutoff = 0.35f;
/// Distance from a flame centre within which the analytic glow is added (4 cm).
constant float kFlameGlowRadius = 0.04f;
/// Peak radiance of the analytic flame glow at intensity 1 (tuned against Flame.metal).
constant float kFlameGlowRadiance = 12.0f;
/// Number of FlameData entries scanned; ReflectionPass.swift binds a private buffer of
/// exactly this many entries, zero-filled beyond the live flames (intensity 0 = skip).
constant uint kReflectionMaxFlames = 16u;

// MARK: - GGX visible-normal sampling

/// Samples a GGX half vector from the distribution of normals visible from `viewLocal`
/// (+Z up local frame, alpha = roughness²) — Heitz 2018, "Sampling the GGX
/// Distribution of Visible Normals".
inline float3 sample_ggx_vndf(float3 viewLocal, float alpha, float2 xi) {
    float3 vh = normalize(float3(alpha * viewLocal.x, alpha * viewLocal.y, viewLocal.z));
    float lengthSquared = vh.x * vh.x + vh.y * vh.y;
    float3 t1 = lengthSquared > 1e-7f ? float3(-vh.y, vh.x, 0.0f) * rsqrt(lengthSquared) : float3(1.0f, 0.0f, 0.0f);
    float3 t2 = cross(vh, t1);
    float r = sqrt(xi.x);
    float phi = kTwoPi * xi.y;
    float p1 = r * cos(phi);
    float p2 = r * sin(phi);
    float s = 0.5f * (1.0f + vh.z);
    p2 = (1.0f - s) * sqrt(max(1.0f - p1 * p1, 0.0f)) + s * p2;
    float3 nh = p1 * t1 + p2 * t2 + sqrt(max(1.0f - p1 * p1 - p2 * p2, 0.0f)) * vh;
    return normalize(float3(alpha * nh.x, alpha * nh.y, max(nh.z, 0.0f)));
}

/// Smith Λ term for GGX (alpha = roughness²) at cosine `cosine`.
inline float smith_lambda(float cosine, float alpha) {
    float c2 = max(cosine * cosine, 1e-6f);
    float tan2 = (1.0f - c2) / c2;
    return 0.5f * (sqrt(1.0f + alpha * alpha * tan2) - 1.0f);
}

/// Weight of a VNDF sample: G2 / G1 (height-correlated Smith), ≤ 1.
inline float vndf_sample_weight(float NdotV, float NdotL, float alpha) {
    float lambdaV = smith_lambda(NdotV, alpha);
    float lambdaL = smith_lambda(NdotL, alpha);
    return (1.0f + lambdaV) / (1.0f + lambdaV + lambdaL);
}

// MARK: - Shading of the reflected hit

/// Radiance leaving a reflection hit toward the ray: material albedo × (Lambert from
/// the two strongest lights + ambient) + material emissive.
inline float3 shade_reflection_hit(float3 position, float3 normal, device const MaterialData &material,
                                   constant FrameUniforms &u, device const LightData *lights) {
    float3 irradiance = irradiance_two_strongest(u, lights, position, normal);
    float3 ambient = ambient_radiance(u, lights);
    float3 diffuse = material.albedo * (irradiance * kInvPi + ambient);
    return diffuse + max(material.emissive, 0.0f);
}

/// Additive analytic glow of the flames the ray passes within `kFlameGlowRadius` of
/// before reaching `hitT`. Flame centre = base + height / 2.
inline float3 flame_glow_along_ray(float3 origin, float3 direction, float hitT,
                                   device const FlameData *flames, constant FrameUniforms &u) {
    float3 glow = float3(0.0f);
    for (uint i = 0u; i < kReflectionMaxFlames; ++i) {
        FlameData flame = flames[i];
        if (flame.intensity <= 0.0f) {
            continue;
        }
        float3 center = flame.position + float3(0.0f, 0.5f * max(flame.height, 0.0f), 0.0f);
        float t = dot(center - origin, direction);
        if (t <= 0.0f || t >= hitT) {
            continue;
        }
        float3 closest = origin + direction * t;
        float miss = distance(closest, center);
        if (miss >= kFlameGlowRadius) {
            continue;
        }
        float falloff = sqr(1.0f - miss / kFlameGlowRadius);
        float3 color = max(flame.color, 0.0f);
        if (flame.temperatureK > 0.0f) {
            color *= blackbody_rgb(flame.temperatureK);
        }
        glow += color * (kFlameGlowRadiance * flame.intensity * max(u.flameIntensity, 0.0f) * falloff);
    }
    return glow;
}

// MARK: - Kernel

kernel void reflection_trace(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                             device const LightData *lights [[buffer(BufferIndexLights)]],
                             device const MaterialData *materials [[buffer(BufferIndexMaterials)]],
                             device const FlameData *flames [[buffer(BufferIndexFlames)]],
                             device const Vertex *vertices [[buffer(BufferIndexVertices), function_constant(kReflectionUsesRT)]],
                             device const uint *indices [[buffer(BufferIndexIndices), function_constant(kReflectionUsesRT)]],
                             device const GeometryRange *ranges [[buffer(BufferIndexGeometryRanges), function_constant(kReflectionUsesRT)]],
                             device const InstanceData *instances [[buffer(BufferIndexInstances), function_constant(kReflectionUsesRT)]],
                             instance_acceleration_structure accel [[buffer(BufferIndexAccel), function_constant(kReflectionUsesRT)]],
                             constant SDFScene &sdf [[buffer(BufferIndexSDFScene), function_constant(kReflectionUsesSDF)]],
                             texture2d<float, access::read> albedoTex [[texture(TextureIndexGBufferAlbedo)]],
                             texture2d<float, access::read> normalTex [[texture(TextureIndexGBufferNormal)]],
                             depth2d<float, access::read> depthTex [[texture(TextureIndexDepth)]],
                             texture2d<float, access::write> outReflection [[texture(TextureIndexReflection)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.renderSize.x) || gid.y >= uint(u.renderSize.y)) return;

    float depth = depthTex.read(gid);
    if (is_background_depth(depth)) {
        outReflection.write(float4(0.0f), gid);
        return;
    }

    float4 albedoTexel = albedoTex.read(gid);
    float4 normalTexel = normalTex.read(gid);
    uint materialIndex = uint(albedoTexel.a * 255.0f + 0.5f);
    device const MaterialData &material = materials[materialIndex];
    float roughness = clamp(normalTexel.w, 0.02f, 1.0f);
    bool glossy = (material.flags & MATERIAL_FLAG_GLOSSY) != 0u || roughness < kReflectionRoughnessCutoff;
    if (!glossy) {
        outReflection.write(float4(0.0f), gid);
        return;
    }

    float2 uv = pixel_center_uv(gid, u);
    float3 position = reconstruct_world_position(uv, depth, u.invViewProjection);
    float3 normal = safe_normalize(normalTexel.xyz);
    float3 view = safe_normalize(u.cameraPosition - position, normal);
    float NdotV = max(dot(normal, view), 1e-4f);
    float alpha = max(roughness * roughness, 1e-3f);

    // GGX VNDF sample in the local frame around the normal.
    uint pixelIndex = gid.y * uint(u.renderSize.x) + gid.x;
    float2 xi = hash_unit2(u.seedLo, u.seedHi, u.frameIndex, pixelIndex, 0x100u);
    float3 tangent;
    float3 bitangent;
    orthonormal_basis(normal, tangent, bitangent);
    float3 viewLocal = float3(dot(view, tangent), dot(view, bitangent), NdotV);
    float3 halfLocal = sample_ggx_vndf(viewLocal, alpha, xi);
    float3 halfVector = safe_normalize(tangent * halfLocal.x + bitangent * halfLocal.y + normal * halfLocal.z, normal);
    float3 direction = reflect(-view, halfVector);
    float NdotR = dot(normal, direction);
    if (NdotR <= 1e-4f) {
        // Sample below the horizon: absorbed (zero-weight sample keeps the estimate consistent).
        outReflection.write(float4(0.0f, 0.0f, 0.0f, kReflectionMaxDistance), gid);
        return;
    }
    float weight = vndf_sample_weight(NdotV, NdotR, alpha);

    // Trace.
    float3 origin = rt_offset_origin(position, normal);
    float3 radiance = ambient_radiance(u, lights);
    float hitT = kReflectionMaxDistance;
    if (kReflectionUsesSDF) {
        SDFMarchResult march = sdfMarch(origin, direction, kReflectionMaxDistance, sdf);
        if (march.hit) {
            float3 hitNormal = sceneNormal(march.position, sdf);
            if (dot(hitNormal, direction) > 0.0f) {
                hitNormal = -hitNormal;
            }
            radiance = shade_reflection_hit(march.position, hitNormal, materials[march.material], u, lights);
            hitT = march.t;
        }
    } else {
        RTHit hit = rtClosestHit(accel, origin, direction, kReflectionMaxDistance);
        if (hit.hit) {
            RTSurface surface = reconstructHit(hit, vertices, indices, ranges, instances);
            radiance = shade_reflection_hit(surface.position, surface.normal, materials[surface.materialIndex], u, lights);
            hitT = hit.t;
        }
    }

    radiance += flame_glow_along_ray(origin, direction, hitT, flames, u);
    outReflection.write(float4(radiance * weight, hitT), gid);
}
