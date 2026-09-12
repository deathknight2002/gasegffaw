//
//  LightShading.h
//  Bornless Ritual — light helpers shared by Lighting.metal and Reflection.metal
//  (RENDER_CONTRACT §2 rows 3–4; ShaderTypes.h `LightData`, LIGHT_TYPE_*).
//
//  Role: the colour / bounding radius / importance of a `LightData` entry, the
//  chamber ambient constant scaled by the `ambient` slider, and the "N strongest
//  lights" point-light approximation used for reflection hits. Emitter sampling with
//  its pdf lives in Lighting.metal (the only pass that traces shadow rays to lights).
//
//  Radiometric convention (documented for SceneUpdater, which fills LightData):
//  `radiance × intensity` is the light's radiant intensity I (W·sr⁻¹ analogue): the
//  irradiance at distance d from a small emitter is I · cosθ / d². For the ring it is
//  the on-axis radiant intensity of the whole torus. `temperatureK > 0` tints the
//  colour by the normalised blackbody chromaticity (6500 K = white).
//

#ifndef LightShading_h
#define LightShading_h

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"

using namespace metal;

/// Dim warm stone-chamber ambient radiance at `ambient` = 1 (the slider scales it,
/// RENDER_CONTRACT §2 row 3 "unshadowed ambient term × ambient").
constant float3 kChamberAmbientRadiance = float3(0.10f, 0.085f, 0.07f);

/// Radiant intensity colour of a light: radiance × intensity, tinted by the blackbody
/// chromaticity when `temperatureK` > 0.
inline float3 light_color(LightData light) {
    float3 color = light.radiance * light.intensity;
    if (light.temperatureK > 0.0f) {
        color *= blackbody_rgb(light.temperatureK);
    }
    return max(color, 0.0f);
}

/// Radius of the sphere bounding the emitter (tube + major radius for rings).
inline float light_bounding_radius(LightData light) {
    float radius = max(light.radius, 0.0f);
    if (light.type == LIGHT_TYPE_RING) {
        radius += max(light.ringRadius, 0.0f);
    }
    return radius;
}

/// Selection importance of a light for the surface point `position` with normal
/// `normal`: luminance(I) / (d² + r²), zero for ambient lights and for emitters whose
/// bounding sphere lies entirely below the surface's tangent plane (they cannot
/// contribute, so excluding them keeps the estimator unbiased).
inline float light_importance(LightData light, float3 position, float3 normal) {
    if (light.type == LIGHT_TYPE_AMBIENT) {
        return 0.0f;
    }
    float3 toCenter = light.position - position;
    float bound = light_bounding_radius(light);
    if (dot(normal, toCenter) < -bound) {
        return 0.0f;
    }
    float d2 = dot(toCenter, toCenter);
    return luminance(light_color(light)) / max(d2 + bound * bound, 1e-6f);
}

/// Ambient radiance seen by a surface: the chamber constant plus every
/// LIGHT_TYPE_AMBIENT entry, scaled by the `ambient` slider.
inline float3 ambient_radiance(constant FrameUniforms &u, device const LightData *lights) {
    float3 ambient = kChamberAmbientRadiance;
    uint count = min(u.lightCount, uint(MAX_LIGHTS));
    for (uint i = 0u; i < count; ++i) {
        if (lights[i].type == LIGHT_TYPE_AMBIENT) {
            ambient += light_color(lights[i]);
        }
    }
    return ambient * max(u.ambient, 0.0f);
}

/// Unshadowed Lambert irradiance at `position` from the two lights with the highest
/// importance, treating each as a point source softened by its bounding radius:
/// E = Σ I · max(N·L, 0) / (d² + r²). Used for reflection hits (RENDER_CONTRACT §2 row 4).
inline float3 irradiance_two_strongest(constant FrameUniforms &u, device const LightData *lights,
                                       float3 position, float3 normal) {
    uint count = min(u.lightCount, uint(MAX_LIGHTS));
    uint best0 = 0xFFFFFFFFu;
    uint best1 = 0xFFFFFFFFu;
    float importance0 = 0.0f;
    float importance1 = 0.0f;
    for (uint i = 0u; i < count; ++i) {
        float importance = light_importance(lights[i], position, normal);
        if (importance > importance0) {
            best1 = best0;
            importance1 = importance0;
            best0 = i;
            importance0 = importance;
        } else if (importance > importance1) {
            best1 = i;
            importance1 = importance;
        }
    }

    float3 irradiance = float3(0.0f);
    for (uint k = 0u; k < 2u; ++k) {
        uint index = (k == 0u) ? best0 : best1;
        if (index == 0xFFFFFFFFu) {
            continue;
        }
        LightData light = lights[index];
        float3 toLight = light.position - position;
        float d2 = dot(toLight, toLight);
        float3 direction = safe_normalize(toLight, normal);
        float bound = light_bounding_radius(light);
        float cosine = max(dot(normal, direction), 0.0f);
        irradiance += light_color(light) * (cosine / max(d2 + bound * bound, 1e-6f));
    }
    return irradiance;
}

#endif /* LightShading_h */
