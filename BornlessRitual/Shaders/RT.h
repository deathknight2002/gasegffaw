//
//  RT.h
//  Bornless Ritual — hardware ray-tracing helpers (RENDER_CONTRACT §5).
//
//  Role: shadow rays (any-hit) and closest-hit queries against the per-frame
//  `instance_acceleration_structure` bound at BufferIndexAccel, plus reconstruction
//  of the hit surface (position, interpolated normal, uv, material) from the shared
//  vertex/index buffers, the GeometryRange table and InstanceData.
//
//  Invariants relied upon (owned by Render/Scene/AccelerationStructures.swift):
//   • instance descriptor i in the instance AS corresponds to InstanceData[i], so
//     `intersection_result.instance_id` indexes BufferIndexInstances directly;
//   • every primitive AS is built from the shared vertex buffer with the geometry's
//     `GeometryRange` (firstIndex / indexCount / baseVertex) and 64-byte Vertex stride,
//     so `primitive_id` · 3 + firstIndex addresses the triangle's indices;
//   • MATERIAL_FLAG_NO_SHADOW instances are not in the AS (flame proxies).
//  Ray origins are offset 1 mm along the geometric normal (`rt_offset_origin`).
//

#ifndef RT_h
#define RT_h

#include <metal_stdlib>
#include <metal_raytracing>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;
using namespace metal::raytracing;

// MARK: - Results

/// Closest-hit query result.
struct RTHit {
    bool hit;                 ///< true when a triangle was hit before maxT
    float t;                  ///< ray parameter of the hit
    uint instance;            ///< index into InstanceData[] (instance_id)
    uint primitive;           ///< triangle index inside the instance's geometry
    float2 bary;              ///< barycentrics (u, v); vertex 0 weight = 1 − u − v
    bool frontFacing;         ///< true when the ray hit the front face
};

/// Reconstructed surface at a hit.
struct RTSurface {
    float3 position;          ///< world-space hit position
    float3 normal;            ///< world-space interpolated shading normal (faces the ray)
    float3 geometricNormal;   ///< world-space triangle plane normal (faces the ray)
    float2 uv;                ///< interpolated texture coordinate
    uint materialIndex;       ///< InstanceData.materialIndex
    uint instance;            ///< InstanceData index
};

// MARK: - Constants

/// Offset applied along the normal before tracing (metres).
constant float kRTOriginOffset = 1e-3f;

/// Ray origin pushed off the surface along `normal` by 1 mm.
inline float3 rt_offset_origin(float3 position, float3 normal) {
    return position + normal * kRTOriginOffset;
}

// MARK: - Shadow rays

/// True when anything in `accel` (matching `mask`) lies on the segment
/// [origin, origin + dir · maxT). Any-hit: the traversal stops at the first candidate.
inline bool rtShadowRay(instance_acceleration_structure accel, float3 origin, float3 dir, float maxT, uint mask) {
    intersector<triangle_data, instancing> shadowIntersector;
    shadowIntersector.accept_any_intersection(true);
    shadowIntersector.assume_geometry_type(geometry_type::triangle);
    shadowIntersector.force_opacity(forced_opacity::opaque);
    ray shadowRay(origin, dir, 0.0f, maxT);
    intersection_result<triangle_data, instancing> result = shadowIntersector.intersect(shadowRay, accel, mask);
    return result.type != intersection_type::none;
}

/// Shadow ray against every instance (mask 0xFFFFFFFF).
inline bool rtShadowRay(instance_acceleration_structure accel, float3 origin, float3 dir, float maxT) {
    return rtShadowRay(accel, origin, dir, maxT, 0xFFFFFFFFu);
}

/// Visibility (1 = lit, 0 = occluded) from a surface point toward a point on a light.
/// The origin is offset along `normal`; the ray stops `lightRadius` short of the
/// sample so the light's own proxy geometry never self-occludes.
inline float rtLightVisibility(instance_acceleration_structure accel, float3 position, float3 normal, float3 lightSample, float lightRadius) {
    float3 origin = rt_offset_origin(position, normal);
    float3 toLight = lightSample - origin;
    float dist = length(toLight);
    if (dist < 1e-4f) {
        return 1.0f;
    }
    float3 dir = toLight / dist;
    float maxT = max(dist - lightRadius, kRTOriginOffset);
    return rtShadowRay(accel, origin, dir, maxT) ? 0.0f : 1.0f;
}

// MARK: - Closest hit

/// Closest triangle along the ray within [0, maxT).
inline RTHit rtClosestHit(instance_acceleration_structure accel, float3 origin, float3 dir, float maxT, uint mask) {
    intersector<triangle_data, instancing> closestIntersector;
    closestIntersector.accept_any_intersection(false);
    closestIntersector.assume_geometry_type(geometry_type::triangle);
    closestIntersector.force_opacity(forced_opacity::opaque);
    ray queryRay(origin, dir, 0.0f, maxT);
    intersection_result<triangle_data, instancing> result = closestIntersector.intersect(queryRay, accel, mask);

    RTHit hit;
    hit.hit = (result.type == intersection_type::triangle);
    hit.t = hit.hit ? result.distance : maxT;
    hit.instance = hit.hit ? result.instance_id : 0u;
    hit.primitive = hit.hit ? result.primitive_id : 0u;
    hit.bary = hit.hit ? result.triangle_barycentric_coord : float2(0.0f);
    hit.frontFacing = hit.hit ? result.triangle_front_facing : true;
    return hit;
}

/// Closest hit against every instance (mask 0xFFFFFFFF).
inline RTHit rtClosestHit(instance_acceleration_structure accel, float3 origin, float3 dir, float maxT) {
    return rtClosestHit(accel, origin, dir, maxT, 0xFFFFFFFFu);
}

// MARK: - Hit reconstruction

/// Rebuilds the world-space surface at `hit` from the shared geometry buffers.
///
/// Position and normal are interpolated in object space with the barycentrics, then
/// transformed by `InstanceData.model` / `normalMatrix`. Both normals are flipped to
/// face the incoming ray when the back face was hit, so shading is two-sided.
inline RTSurface reconstructHit(RTHit hit,
                                device const Vertex *vertices,
                                device const uint *indices,
                                device const GeometryRange *ranges,
                                device const InstanceData *instances) {
    InstanceData instance = instances[hit.instance];
    GeometryRange range = ranges[instance.geometryIndex];

    uint base = range.firstIndex + hit.primitive * 3u;
    uint i0 = indices[base + 0u] + range.baseVertex;
    uint i1 = indices[base + 1u] + range.baseVertex;
    uint i2 = indices[base + 2u] + range.baseVertex;
    Vertex v0 = vertices[i0];
    Vertex v1 = vertices[i1];
    Vertex v2 = vertices[i2];

    float w1 = hit.bary.x;
    float w2 = hit.bary.y;
    float w0 = 1.0f - w1 - w2;

    float3 localPosition = v0.position * w0 + v1.position * w1 + v2.position * w2;
    float3 localNormal = v0.normal * w0 + v1.normal * w1 + v2.normal * w2;
    float2 uv = v0.uv * w0 + v1.uv * w1 + v2.uv * w2;
    float3 localGeometric = cross(v1.position - v0.position, v2.position - v0.position);

    RTSurface surface;
    surface.position = (instance.model * float4(localPosition, 1.0f)).xyz;
    surface.normal = safe_normalize((instance.normalMatrix * float4(localNormal, 0.0f)).xyz);
    surface.geometricNormal = safe_normalize((instance.normalMatrix * float4(localGeometric, 0.0f)).xyz);
    if (!hit.frontFacing) {
        surface.normal = -surface.normal;
        surface.geometricNormal = -surface.geometricNormal;
    }
    surface.uv = uv;
    surface.materialIndex = instance.materialIndex;
    surface.instance = hit.instance;
    return surface;
}

#endif /* RT_h */
