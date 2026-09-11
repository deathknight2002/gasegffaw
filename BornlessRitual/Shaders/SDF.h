//
//  SDF.h
//  Bornless Ritual — fallback-path signed-distance scene (RENDER_CONTRACT §4).
//
//  Role: evaluates the `SDFScene` uploaded by SceneUpdater (BufferIndexSDFScene) as a
//  union of primitives, provides normals by central differences, a physically
//  motivated cone-traced soft shadow for DirectLightingPass and a bounded sphere
//  march for ReflectionPass. Mirrors the triangle scene of the RT path.
//
//  Conventions: all positions are world space (metres, +Y up). Primitive
//  `rotation` is a unit quaternion (x, y, z, w) applied to the primitive's local frame;
//  `halfExtents` meaning per type is documented in ShaderTypes.h.
//

#ifndef SDF_h
#define SDF_h

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;

// MARK: - Results

/// Nearest-surface query result.
struct SDFResult {
    float dist;         ///< signed distance (negative inside)
    uint material;      ///< material index of the nearest primitive
};

/// Sphere-march result.
struct SDFMarchResult {
    bool hit;           ///< true when a surface was found before maxT
    float t;            ///< ray parameter of the hit (or maxT on miss)
    uint material;      ///< material index of the hit primitive (0 on miss)
    float3 position;    ///< origin + dir · t
};

// MARK: - Primitive distances (local frames)

/// Axis-aligned box with half extents `b` centred at the origin.
inline float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0f)) + min(max(q.x, max(q.y, q.z)), 0.0f);
}

/// Sphere of radius `r` at the origin.
inline float sdSphere(float3 p, float r) {
    return length(p) - r;
}

/// Capsule between world points `a` and `b` with radius `r`.
inline float sdCapsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a;
    float3 ba = b - a;
    float denom = max(dot(ba, ba), 1e-8f);
    float h = clamp(dot(pa, ba) / denom, 0.0f, 1.0f);
    return length(pa - ba * h) - r;
}

/// Y-axis cylinder of radius `r` and half height `halfH` centred at the origin.
inline float sdCylinder(float3 p, float r, float halfH) {
    float2 d = abs(float2(length(p.xz), p.y)) - float2(r, halfH);
    return min(max(d.x, d.y), 0.0f) + length(max(d, 0.0f));
}

/// Half-space below the plane with unit normal `n` through the origin (`h` offsets it).
inline float sdPlane(float3 p, float3 n, float h) {
    return dot(p, n) + h;
}

/// Interior of a box (the chamber): negative outside the walls, positive inside.
inline float sdRoom(float3 p, float3 halfExtents) {
    return -sdBox(p, halfExtents);
}

// MARK: - Scene

/// Distance from `p` to one `SDFPrimitive`, in world space.
inline float sdPrimitive(float3 p, constant SDFPrimitive &prim) {
    float3 local = quat_rotate_inverse(prim.rotation, p - prim.position);
    switch (prim.type) {
        case SDF_BOX:
            return sdBox(local, max(prim.halfExtents - prim.rounding, 0.0f)) - prim.rounding;
        case SDF_SPHERE:
            return sdSphere(local, prim.halfExtents.x);
        case SDF_CAPSULE:
            return sdCapsule(p, prim.position, prim.endB, prim.halfExtents.x);
        case SDF_CYLINDER:
            return sdCylinder(local, max(prim.halfExtents.x - prim.rounding, 0.0f),
                              max(prim.halfExtents.y - prim.rounding, 0.0f)) - prim.rounding;
        case SDF_PLANE:
            return sdPlane(local, float3(0.0f, 1.0f, 0.0f), 0.0f);
        case SDF_ROOM:
            return sdRoom(local, prim.halfExtents);
        default:
            return 1e6f;
    }
}

/// Union of every primitive in `scene`; returns the nearest distance and its material.
inline SDFResult sdScene(float3 p, constant SDFScene &scene) {
    SDFResult best;
    best.dist = 1e6f;
    best.material = 0u;
    uint count = min(scene.count, uint(MAX_SDF_PRIMITIVES));
    for (uint i = 0u; i < count; ++i) {
        float d = sdPrimitive(p, scene.primitives[i]);
        if (d < best.dist) {
            best.dist = d;
            best.material = scene.primitives[i].materialIndex;
        }
    }
    return best;
}

/// Distance only (cheaper call site when the material is not needed).
inline float sdSceneDistance(float3 p, constant SDFScene &scene) {
    return sdScene(p, scene).dist;
}

/// Surface normal by central differences with step `eps` (six evaluations).
inline float3 sceneNormal(float3 p, constant SDFScene &scene, float eps) {
    float3 dx = float3(eps, 0.0f, 0.0f);
    float3 dy = float3(0.0f, eps, 0.0f);
    float3 dz = float3(0.0f, 0.0f, eps);
    float3 gradient = float3(sdSceneDistance(p + dx, scene) - sdSceneDistance(p - dx, scene),
                             sdSceneDistance(p + dy, scene) - sdSceneDistance(p - dy, scene),
                             sdSceneDistance(p + dz, scene) - sdSceneDistance(p - dz, scene));
    return safe_normalize(gradient, float3(0.0f, 1.0f, 0.0f));
}

/// Normal with the default 1 mm step.
inline float3 sceneNormal(float3 p, constant SDFScene &scene) {
    return sceneNormal(p, scene, 1e-3f);
}

// MARK: - Shadows

/// Cone-traced soft shadow toward a spherical light.
///
/// The light of radius `lightRadius` sits at distance `maxT` along `dir`; the cone
/// from the shaded point to the light disc has radius `lightRadius · t / maxT` at
/// parameter t (the physically motivated penumbra width). At each step the nearest
/// surface distance `h` is compared with the cone radius: an occluder closer to the
/// axis than the cone is wide blocks a proportional fraction of the disc. Returns
/// visibility in [0, 1] (0 = fully occluded). The linear h/r estimate widens the
/// penumbra slightly versus exact disc overlap but is continuous and cheap.
inline float sdfSoftShadow(float3 origin, float3 dir, float maxT, float lightRadius, constant SDFScene &scene) {
    float visibility = 1.0f;
    float t = 0.02f;
    const uint kMaxSteps = 48u;
    for (uint i = 0u; i < kMaxSteps; ++i) {
        if (t >= maxT) {
            break;
        }
        float h = sdSceneDistance(origin + dir * t, scene);
        if (h < 1e-4f) {
            return 0.0f;
        }
        float coneRadius = max(lightRadius * t / max(maxT, 1e-3f), 1e-4f);
        visibility = min(visibility, saturate(h / coneRadius));
        if (visibility < 1e-3f) {
            return 0.0f;
        }
        t += clamp(h, 0.01f, 0.30f);
    }
    return saturate(visibility);
}

// MARK: - Marching

/// Sphere-marches `dir` from `origin` up to `maxT` (64 steps). The hit epsilon
/// scales with distance so that far surfaces converge in fewer steps.
inline SDFMarchResult sdfMarch(float3 origin, float3 dir, float maxT, constant SDFScene &scene) {
    SDFMarchResult result;
    result.hit = false;
    result.t = maxT;
    result.material = 0u;
    result.position = origin + dir * maxT;

    float t = 0.0f;
    const uint kMaxSteps = 64u;
    for (uint i = 0u; i < kMaxSteps; ++i) {
        float3 p = origin + dir * t;
        SDFResult s = sdScene(p, scene);
        float eps = max(1e-4f, 5e-4f * t);
        if (s.dist < eps) {
            result.hit = true;
            result.t = t;
            result.material = s.material;
            result.position = p;
            return result;
        }
        t += max(s.dist, eps);
        if (t >= maxT) {
            break;
        }
    }
    return result;
}

/// Shadow-ray convenience for a point light of `lightRadius` at `lightPosition`: offsets
/// the origin along the normal (1 mm) and traces toward the light centre.
inline float sdfLightVisibility(float3 position, float3 normal, float3 lightPosition, float lightRadius, constant SDFScene &scene) {
    float3 origin = position + normal * 1e-3f;
    float3 toLight = lightPosition - origin;
    float dist = length(toLight);
    if (dist < 1e-4f) {
        return 1.0f;
    }
    float3 dir = toLight / dist;
    return sdfSoftShadow(origin, dir, max(dist - lightRadius, 1e-3f), lightRadius, scene);
}

#endif /* SDF_h */
