//
//  probe_headers.metal
//  Bornless Ritual — metal-lint probe for Shaders/Common.h, SDF.h and RT.h.
//
//  Role: includes the three shared headers exactly as a pass file would and calls
//  every helper once so the linter type-checks their bodies. Not part of the app.
//  Run: Tools/metal-lint/lint.sh Tools/metal-lint/selftest/probe_headers.metal
//

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "Common.h"
#include "SDF.h"
#include "RT.h"

using namespace metal;

kernel void probe_common(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                         texture2d<float, access::read> blueNoise [[texture(TextureIndexBlueNoise)]],
                         texture2d<float, access::write> outTex [[texture(TextureIndexHDRColor)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.renderSize.x) || gid.y >= uint(u.renderSize.y)) return;

    uint h = hash_u32(u.seedLo, u.seedHi, u.frameIndex, gid.x, gid.y);
    float r = hash_unit(h) + hash_unit(u.seedLo, u.seedHi, 1u, 2u, 3u);
    float2 r2 = hash_unit2(u.seedLo, u.seedHi, 1u, 2u, 3u);
    float3 r3 = hash_unit3(u.seedLo, u.seedHi, 1u, 2u, 3u);
    uint hf = hash_frame(u, u.tick, gid.x, 7u);

    float2 hal = halton23(u.frameIndex) + jitter_pixels(u.frameIndex);
    float3 p = float3(gid.x, gid.y, u.time) * 0.01f;
    float vn = value_noise3(p, 1u);
    float sn = simplex_noise3(p, 2u);
    float fb = fbm3(p, 4u, 3u) + fbm3(p, 3u, 2.0f, 0.5f, 4u);
    float3 curl = curl_noise3(p, 0.05f, 5u);

    float3 bb = blackbody_rgb(u.candleWarmthK) * blackbody_relative_power(1900.0f, 1900.0f);
    float lum = luminance(bb);
    float3 enc = linear_to_srgb(bb);
    float3 dec = srgb_to_linear(enc);

    float alpha = 0.25f;
    float d = ggx_ndf(0.9f, alpha);
    float v = smith_ggx_visibility(0.8f, 0.7f, alpha);
    float f = fresnel_schlick(0.6f, 0.04f);
    float3 f3 = fresnel_schlick(0.6f, float3(0.04f));
    float3 lam = lambert_brdf(bb);
    float3 spec = ggx_specular(0.8f, 0.7f, 0.9f, 0.6f, 0.5f, specular_f0(bb, 0.0f));
    float hg = henyey_greenstein(0.3f, 0.55f);

    float2 uv = pixel_center_uv(gid, u);
    float lin = linearize_depth(0.5f, u.nearPlane, u.farPlane);
    float dep = depth_from_linear(lin, u.nearPlane, u.farPlane);
    float3 wp = reconstruct_world_position(uv, dep, u.invViewProjection);
    float3 puv = project_to_uv(wp, u.viewProjection);
    bool bg = is_background_depth(dep) || pixel_in_render_bounds(gid, u);

    float3 sph = sample_sphere_light(wp, 0.02f, r2);
    float3 ring = sample_ring_light(wp, 0.75f, 0.006f, r2);
    float3 disc = sample_disc(wp, float3(1, 0, 0), float3(0, 0, 1), 0.1f, r2);
    float3 cosDir = to_world_basis(sample_cosine_hemisphere(r2), float3(0, 1, 0));
    float3 hv = to_world_basis(sample_ggx_half_vector(r2, alpha), float3(0, 1, 0));

    float slice = froxel_slice_from_depth(lin, 0.1f, 12.0f);
    float back = froxel_depth_from_slice(slice, 0.1f, 12.0f);
    uint sliceIndex = froxel_slice_index(lin, 0.1f, 12.0f);
    float3 fc = froxel_coordinate(uv, lin, 0.1f, 12.0f);

    float3 sn3 = safe_normalize(curl) + safe_normalize(curl, float3(0, 0, 1));
    float q = sqr(remap01(r, 0.2f, 0.8f));
    float3 rot = quat_rotate(float4(0, 0, 0, 1), sn3) + quat_rotate_inverse(float4(0, 0, 0, 1), sn3);
    float4 bn = blue_noise_sample(blueNoise, gid, u.frameIndex);

    float acc = r + r2.x + r3.z + float(hf) + hal.x + vn + sn + fb + curl.x + lum + dec.x + d + v + f + f3.x
              + lam.y + spec.z + hg + lin + puv.z + float(bg) + sph.x + ring.y + disc.z + cosDir.x + hv.y
              + back + float(sliceIndex) + fc.z + q + rot.x + bn.w + float(kRenderPath) + float(kMetalFX)
              + float(kDebugView) + kPi + kTwoPi + kInvPi + kInvFourPi + kBlackbodyWhite6500.x;
    outTex.write(float4(acc), gid);
}

kernel void probe_sdf(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                      constant SDFScene &scene [[buffer(BufferIndexSDFScene)]],
                      texture2d<float, access::write> outTex [[texture(TextureIndexReflection)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.renderSize.x) || gid.y >= uint(u.renderSize.y)) return;

    float3 p = float3(gid.x, 1.0f, gid.y) * 0.01f;
    float a = sdBox(p, float3(1.0f)) + sdSphere(p, 0.5f) + sdCapsule(p, float3(0), float3(0, 1, 0), 0.1f)
            + sdCylinder(p, 0.1f, 0.5f) + sdPlane(p, float3(0, 1, 0), 0.0f) + sdRoom(p, float3(3, 2, 3));
    float b = sdPrimitive(p, scene.primitives[0]);
    SDFResult s = sdScene(p, scene);
    float dist = sdSceneDistance(p, scene);
    float3 n = sceneNormal(p, scene) + sceneNormal(p, scene, 2e-3f);
    float shadow = sdfSoftShadow(p, n, 3.0f, 0.03f, scene);
    SDFMarchResult m = sdfMarch(p, n, 8.0f, scene);
    float vis = sdfLightVisibility(p, n, float3(0, 1.13f, 1.8f), 0.03f, scene);

    float acc = a + b + s.dist + float(s.material) + dist + n.x + shadow + m.t + float(m.hit) + float(m.material)
              + m.position.y + vis;
    outTex.write(float4(acc), gid);
}

kernel void probe_rt(constant FrameUniforms &u [[buffer(BufferIndexFrameUniforms)]],
                     device const Vertex *vertices [[buffer(BufferIndexVertices)]],
                     device const uint *indices [[buffer(BufferIndexIndices)]],
                     device const InstanceData *instances [[buffer(BufferIndexInstances)]],
                     device const GeometryRange *ranges [[buffer(BufferIndexGeometryRanges)]],
                     instance_acceleration_structure accel [[buffer(BufferIndexAccel)]],
                     texture2d<float, access::write> outTex [[texture(TextureIndexReflection)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.renderSize.x) || gid.y >= uint(u.renderSize.y)) return;

    float3 origin = rt_offset_origin(u.cameraPosition, float3(0, 1, 0));
    float3 dir = float3(0, 0, -1);
    bool occluded = rtShadowRay(accel, origin, dir, 10.0f) || rtShadowRay(accel, origin, dir, 10.0f, 0xFFu);
    float vis = rtLightVisibility(accel, origin, float3(0, 1, 0), float3(0, 1.13f, 1.8f), 0.03f);
    RTHit hit = rtClosestHit(accel, origin, dir, 30.0f);
    RTHit hit2 = rtClosestHit(accel, origin, dir, 30.0f, 0xFFu);
    float acc = float(occluded) + vis + hit2.t;
    if (hit.hit) {
        RTSurface surface = reconstructHit(hit, vertices, indices, ranges, instances);
        acc += surface.position.x + surface.normal.y + surface.geometricNormal.z + surface.uv.x
             + float(surface.materialIndex) + float(surface.instance) + float(hit.frontFacing) + hit.bary.x
             + float(hit.primitive) + float(hit.instance) + kRTOriginOffset;
    }
    outTex.write(float4(acc), gid);
}
