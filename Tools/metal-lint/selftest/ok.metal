// metal-lint self-test: this file must lint with zero errors.
// It exercises every construct the stub <metal_stdlib> claims to support.
// It deliberately does NOT include ShaderTypes.h.
#include <metal_stdlib>
#include <metal_raytracing>
#include <metal_atomic>

using namespace metal;
using namespace metal::raytracing;

// ---------------------------------------------------------------------------
// Function constants
// ---------------------------------------------------------------------------
constant bool kUseShadows [[function_constant(0)]];
constant int kSampleCount [[function_constant(1)]];
constant float kExposure [[ function_constant(2) ]];
constant bool kHasEmissive [[function_constant(3)]];
constant bool kUseShadowsDefined = is_function_constant_defined(kUseShadows);

// ---------------------------------------------------------------------------
// Constants and literals
// ---------------------------------------------------------------------------
constant float kPi = M_PI_F;
constant half kPiH = M_PI_H;
constant float kInf = INFINITY;
constant float kBig = FLT_MAX;
constant float kEps = FLT_EPSILON;
constant half kHalfMax = HALF_MAX;
constant float kHuge = HUGE_VALF;
constexpr constant uint kMaxLights = 8u;
constexpr constant float3 kForward = float3(0.0, 0.0, -1.0);
constant float3 kUp = float3(0.0, 1.0, 0.0);
constant float2 kPoissonDisk[4] = {
    float2(-0.94201624, -0.39906216), float2(0.94558609, -0.76890725),
    float2(-0.094184101, -0.92938870), float2(0.34495938, 0.29387760)
};
constant array<float, 4> kWeights = { 0.1, 0.2, 0.3, 0.4 };
static constant uint kHistogramBins = 256u;

// ---------------------------------------------------------------------------
// Shared types (a real project keeps these in ShaderTypes.h)
// ---------------------------------------------------------------------------
struct Uniforms {
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4x4 viewProjectionMatrix;
    float3x3 normalMatrix;
    float3 cameraPosition;
    float time;
    uint lightCount;
    packed_float3 sunDirection;
    float sunIntensity;
};

struct Light {
    packed_float3 position;
    float radius;
    packed_float3 color;
    float intensity;
};
static_assert(sizeof(Light) == 32, "packed_float3 must be 12 bytes");

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float4 tangent  [[attribute(2)]];
    float2 texcoord [[attribute(3)]];
};

struct PackedVertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 uv;
};

struct VertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float3 worldTangent;
    float2 uv;
    half4 color [[flat]];
    float pointSize [[point_size]];
};

struct GBufferOut {
    half4 albedo    [[color(0)]];
    half4 normal    [[color(1)]];
    float4 emissive [[color(2)]];
    float depth     [[color(3)]];
};

struct ArgumentBuffer {
    texture2d<float> albedoMap [[id(0)]];
    texture2d<half> normalMap [[id(1)]];
    device float* scratch [[id(2)]];
    array<texture2d<float>, 4> extra [[id(3)]];
    sampler samp [[id(7)]];
};

struct RayPayload {
    float3 color;
    float distance;
    uint bounces;
};

// ---------------------------------------------------------------------------
// Samplers
// ---------------------------------------------------------------------------
constexpr sampler kLinearSampler(mag_filter::linear, min_filter::linear, mip_filter::linear, address::repeat);
constexpr sampler kNearestClamp(filter::nearest, address::clamp_to_edge, coord::normalized);
constexpr sampler kShadowSampler(filter::linear, address::clamp_to_zero, compare_func::less_equal,
                                 max_anisotropy(1), lod_clamp(0.0f, 4.0f));

// ---------------------------------------------------------------------------
// Helpers: static / inline / template functions, metal:: qualification
// ---------------------------------------------------------------------------
static inline float3 srgbToLinear(float3 c) { return pow(c, float3(2.2)); }
template <typename T> static T lerp(T a, T b, float t) { return mix(a, b, t); }
inline float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static half3 encodeNormal(half3 n) { return n * 0.5h + 0.5h; }
static float3x3 tbn(float3 n, float3 t, float handedness) {
    float3 b = cross(n, t) * handedness;
    return float3x3(t, b, n);
}
static uint hashUint(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}
static float2 hammersley(uint i, uint n) {
    uint bits = reverse_bits(i);
    return float2(float(i) / float(n), float(bits) * 2.3283064365386963e-10);
}
static float bitsToFloat(uint bits) { return as_type<float>(bits); }
static uint floatToBits(float f) { return as_type<uint>(f); }
static half2 halfPair(uint packed) { return as_type<half2>(packed); }
static float3 unpackPacked(packed_float3 p) { return float3(p); }
static float fastAndPrecise(float x) { return metal::fast::sqrt(x) + precise::rsqrt(x) + fast::sin(x); }
[[visible]] float3 shadeLambert(float3 n, float3 l, float3 albedo) { return albedo * saturate(dot(n, l)); }

// ---------------------------------------------------------------------------
// Scalar / vector / swizzle / constructor coverage
// ---------------------------------------------------------------------------
static float4 vectorTests(float4 v, half4 h, uint3 gid, packed_float3 pp) {
    float3 p = v.xyz;
    float3 rgb = v.rgb;
    float2 xy = v.xy;
    float2 ba = v.ba;
    v.w = 1.0;
    v.xy = xy.yx;
    v.rgb *= 2.0;
    v.zw += float2(1.0, 2.0);
    float4 swz = v.wzyx;
    float x = v.x, y = v[1], z = v.z;
    half4 hc = half4(v);
    float4 fc = float4(h);
    half2 hp = half2(h.xy);
    half3 hn = half3(1.0h);
    half hs = h.x * 2.0h + 1.0h + kPiH;
    float4 fromHalf = float4(hc.rgb, 1.0h);
    uint2 g2 = gid.xy;
    uint gx = gid.x;
    uint3 g3 = uint3(gid.xy, 0u);
    int2 ig = int2(gid.xy);
    float2 fg = float2(gid.xy) / 2.0;
    float3 fp = pp;
    fp = float3(pp);
    pp = fp;
    pp.x = 2.0;
    float3 scaled = pp * 2.0;
    float3 added = fp + pp;
    float3 neg = -pp;
    pp += fp;
    float len = length(pp);
    float dp = dot(pp, fp);
    bool4 mask = v > 0.5;
    bool4 mask2 = bool4(true, false, true, false);
    bool4 m3 = !mask;
    bool4 m4 = mask && mask2;
    bool4 m5 = bool4(true);
    float4 sel = select(v, swz, mask);
    float4 sel2 = select(v, swz, v < swz);
    float4 sel3 = select(v, swz, m3.x);
    bool anyv = any(mask);
    bool allv = all(v == v);
    bool anyRaw = any(v > swz);
    bool allBool = all(m4 || m5);
    float4 zero = float4();
    float4 one = float4(1);
    float4 two = float4(2.0);
    float4 four = float4(1, 2, 3, 4);
    float4 c1 = float4(p, 1.0);
    float4 c2 = float4(1.0, p);
    float4 c3 = float4(xy, xy);
    float4 c4 = float4(xy, 1.0, 2.0);
    float4 c5 = float4(1.0, xy, 2.0);
    float4 c6 = float4(1.0, 2.0, xy);
    float3 c7 = float3(xy, 1.0);
    float3 c8 = float3(1.0, xy);
    float3 c9 = float3(1, 2, 3);
    float3 c10 = float3(p);
    float2 c11 = float2(1, 2);
    float2 c12 = float2(0.5);
    float2 c13 = float2(p.xy);
    uint4 u4 = uint4(v);
    int4 i4 = int4(1, 2, 3, 4);
    uint4 u4b = uint4(i4);
    float4 fromInt = float4(i4);
    ushort2 us = ushort2(g2);
    uchar4 uc = uchar4(u4);
    char2 ch = char2(1, 2);
    short3 sh = short3(1, 2, 3);
    long2 lg = long2(1, 2);
    ulong4 ul = ulong4(0ul);
    float4 arith = (v + swz) * 2.0 - swz / 4.0 + 1.0;
    arith = -arith;
    arith += 1.0;
    arith *= v;
    arith /= 2.0;
    int4 bits = ((i4 << 2) | (i4 & 3)) ^ (~i4);
    bits %= 7;
    bits >>= 1;
    float4 tern = (x > y) ? v : swz;
    float4 cmp = float4(v == swz) + float4(v != swz);
    float4 metalQualified = metal::float4(1.0, 2.0, 3.0, 4.0);
    metal::float3 mq3 = metal::float3(1.0);
    unsigned int plainUnsigned = 3u;
    uint hashed = hashUint(plainUnsigned) + floatToBits(bitsToFloat(7u));
    float2 ham = hammersley(hashed, 16u);
    half2 hpair = halfPair(hashed);
    float lum = luminance(rgb) + fastAndPrecise(x) + kWeights[3] + float(kWeights.size());
    float3 lambert = shadeLambert(p, kUp, unpackPacked(pp)) + kForward;
    float limits = numeric_limits<float>::max() + float(numeric_limits<uint>::max()) + kInf + kBig + kEps + kHuge + float(kHalfMax);
    float misc = ba.x + len + dp + float(gx + g3.z + uint(ig.x) + uint(us.x) + uint(uc.x) + uint(ch.x) + uint(sh.x) + uint(lg.x) + uint(ul.x))
               + float(anyv) + float(allv) + float(anyRaw) + float(allBool) + float(bits.x) + float(u4b.x) + float(hs + hp.x + hn.x + hpair.x) + float(mq3.x) + ham.x + lum + limits;
    return arith + swz + sel + sel2 + sel3 + fc + fromHalf + fromInt + tern + cmp + metalQualified + zero + one + two + four
         + c1 + c2 + c3 + c4 + c5 + c6
         + float4(c7 + c8 + c9 + c10 + scaled + added + neg + lambert, misc)
         + float4(c11 + c12 + c13 + fg, z, kPi);
}

// ---------------------------------------------------------------------------
// Math coverage
// ---------------------------------------------------------------------------
static float mathTests(float x, float3 v, half h, half3 hv, int i, uint u) {
    float c;
    float s = sincos(x, c);
    int e;
    float m = frexp(x, e);
    float ip;
    float frac = modf(x, ip);
    float r = sin(x) + cos(x) + tan(x) + asin(x) + acos(x) + atan(x) + atan2(x, c) + sinh(x) + tanh(x)
            + exp(x) + exp2(x) + log(x) + log2(x) + log10(x) + pow(x, 2.0) + sqrt(x) + rsqrt(x)
            + abs(x) + fabs(x) + floor(x) + ceil(x) + fract(x) + round(x) + trunc(x) + rint(x) + sign(x)
            + fmod(x, 3.0) + fmin(x, 1.0) + fmax(x, 0.0) + min(x, 1.0) + max(x, 0.0) + clamp(x, 0.0, 1.0)
            + saturate(x) + mix(x, c, 0.5) + step(0.5, x) + smoothstep(0.0, 1.0, x) + fma(x, x, x) + mad(x, x, c)
            + copysign(x, c) + ldexp(m, e) + frac + ip + s;
    float3 vr = normalize(v) * length(v) + reflect(v, kUp) + refract(v, kUp, 1.33) + cross(v, kUp)
              + faceforward(v, -v, kUp) + abs(v) + floor(v) + fract(v) + mix(v, -v, 0.25) + mix(v, -v, v)
              + clamp(v, 0.0, 1.0) + clamp(v, -v, v) + saturate(v) + pow(v, 2.0) + exp2(v) + sqrt(abs(v))
              + smoothstep(float3(0.0), float3(1.0), v) + step(0.5, v) + min(v, float3(1.0)) + max(v, 0.0)
              + sign(v) + fma(v, v, v) + normalize(v.xyz) + lerp(v, -v, 0.5) + lerp<float3>(v, v, x);
    float geo = dot(v, v) + length_squared(v) + distance(v, kUp) + distance_squared(v, kUp);
    half hr = sin(h) + sqrt(h) + rsqrt(h) + exp2(-h * 2.0h) + saturate(h) + clamp(h, 0.0h, 1.0h) + mix(h, h, 0.5h)
            + max(h, 0.0h) + abs(h) + dot(hv, hv) + length(hv) + fract(h) + pow(h, 2.0h) + step(0.5h, h);
    half3 hvr = normalize(hv) * saturate(dot(hv, half3(kUp))) + mix(hv, -hv, 0.5h) + clamp(hv, 0.0h, 1.0h) + abs(hv);
    int ir = abs(i) + min(i, 3) + max(i, -3) + clamp(i, -1, 1) + popcount(i) + clz(i) + ctz(i);
    uint ur = popcount(u) + clz(u) + ctz(u) + reverse_bits(u) + rotate(u, 3u) + extract_bits(u, 0, 4)
            + insert_bits(u, 1u, 4, 4) + mulhi(u, u) + absdiff(u, 1u) + addsat(u, 1u) + hadd(u, 1u);
    uint packed = pack_float_to_unorm4x8(float4(v, 1.0)) + pack_float_to_snorm2x16(v.xy);
    float4 unpacked = unpack_unorm4x8_to_float(packed) + unpack_snorm4x8_to_float(packed);
    bool flags = isnan(x) || isinf(x) || isfinite(x) || any(isnan(v)) || all(isfinite(v)) || any(isinf(hv)) || signbit(x);
    return r + vr.x + geo + float(hr) + float(hvr.y) + float(ir) + float(ur) + unpacked.x + float(flags) + kPi;
}

// ---------------------------------------------------------------------------
// Matrix coverage
// ---------------------------------------------------------------------------
static float4x4 makeTranslation(float3 t) {
    float4x4 m = float4x4(1.0);
    m[3] = float4(t, 1.0);
    return m;
}
static float4x4 makeRotationY(float a) {
    float c = cos(a), s = sin(a);
    return float4x4(float4(c, 0, -s, 0), float4(0, 1, 0, 0), float4(s, 0, c, 0), float4(0, 0, 0, 1));
}
static float3x3 normalMatrixFrom(float4x4 m) { return transpose(float3x3(m)); }
static float2x2 rot2(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(c, s, -s, c);
}
static void matrixTests(thread float4x4& m, float3 p) {
    float4x4 t = makeTranslation(p) * makeRotationY(1.0);
    float4 v = t * float4(p, 1.0);
    float4 v2 = float4(p, 1.0) * t;
    float3 q = float3x3(t) * p;
    float3x3 nm = normalMatrixFrom(t);
    half3x3 hnm = half3x3(nm);
    half3 hn = hnm * half3(p);
    float2 r = rot2(0.5) * p.xy;
    float d = determinant(nm);
    m = t + (m * 2.0) - t * 0.5;
    m *= 2.0;
    m += t;
    m *= t;
    m[0][1] = v.x + v2.y + q.z + float(hn.x) + r.x + d;
    float4x3 rect = float4x3(float3(1.0), float3(2.0), float3(3.0), float3(4.0));
    float3 rv = rect * v;
    float4 back = p.xyz * rect;
    m[1] = float4(rv, 1.0) + back;
    float2x3 m23 = float2x3(float3(1.0), float3(2.0));
    float3x2 m32 = transpose(m23);
    m[2].xy = (m32 * float3(1.0)) + float2(1.0);
    float3x3 fromCols = float3x3(t[0].xyz, t[1].xyz, t[2].xyz);
    m[3].xyz = fromCols * p;
}

// ---------------------------------------------------------------------------
// Vertex functions
// ---------------------------------------------------------------------------
vertex VertexOut vertexMain(VertexIn in [[stage_in]],
                            constant Uniforms& u [[buffer(1)]],
                            uint vid [[vertex_id]],
                            uint iid [[instance_id]]) {
    VertexOut out;
    float4 worldPos = u.modelMatrix * float4(in.position, 1.0);
    out.worldPosition = worldPos.xyz;
    out.position = u.viewProjectionMatrix * worldPos;
    out.worldNormal = normalize(u.normalMatrix * in.normal);
    out.worldTangent = normalize((u.modelMatrix * float4(in.tangent.xyz, 0.0)).xyz);
    out.uv = in.texcoord;
    out.color = half4(half3(float3(1.0) * float(vid % 3u) / 3.0), 1.0h);
    out.pointSize = 1.0 + float(iid);
    return out;
}

vertex VertexOut vertexPacked(const device PackedVertex* vertices [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]],
                              uint vid [[vertex_id]]) {
    VertexOut out;
    PackedVertex vtx = vertices[vid];
    float3 p = vtx.position;
    float3 n = float3(vtx.normal);
    float2 uv = vtx.uv;
    float4 worldPos = u.modelMatrix * float4(p, 1.0);
    out.position = u.projectionMatrix * (u.viewMatrix * worldPos);
    out.worldPosition = worldPos.xyz;
    out.worldNormal = normalize(float3x3(u.modelMatrix) * n);
    out.worldTangent = kUp;
    out.uv = uv;
    out.color = half4(1.0h);
    out.pointSize = 1.0;
    return out;
}

// ---------------------------------------------------------------------------
// Fragment functions: MRT struct, single half4 output, argument buffers
// ---------------------------------------------------------------------------
fragment GBufferOut gbufferFragment(VertexOut in [[stage_in]],
                                    constant Uniforms& u [[buffer(1)]],
                                    texture2d<float> albedoTex [[texture(0)]],
                                    texture2d<half> normalTex [[texture(1)]],
                                    sampler texSampler [[sampler(0)]],
                                    bool isFrontFacing [[front_facing]],
                                    float4 fragCoord [[position]]) {
    GBufferOut out;
    float4 albedo = albedoTex.sample(texSampler, in.uv);
    if (albedo.a < 0.5) {
        discard_fragment();
    }
    half3 tsNormal = normalTex.sample(kLinearSampler, in.uv).xyz * 2.0h - 1.0h;
    float3 n = normalize(in.worldNormal);
    float3 t = normalize(in.worldTangent - n * dot(in.worldTangent, n));
    float3x3 basis = tbn(n, t, isFrontFacing ? 1.0 : -1.0);
    float3 worldN = normalize(basis * float3(tsNormal));
    out.albedo = half4(half3(srgbToLinear(albedo.rgb)), 1.0h);
    out.normal = half4(encodeNormal(half3(worldN)), 1.0h);
    out.emissive = kHasEmissive ? float4(albedo.rgb * kExposure, 1.0) : float4(0.0);
    out.depth = fragCoord.z / fragCoord.w;
    float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
    float lod = log2(max(length(dx), length(dy)) * float(albedoTex.get_width()));
    out.emissive.a = lod + fwidth(in.uv.x) + u.time + float(albedoTex.get_height(0)) + float(albedoTex.get_num_mip_levels());
    return out;
}

[[early_fragment_tests]]
fragment half4 lightingFragment(VertexOut in [[stage_in]],
                                constant Uniforms& u [[buffer(1)]],
                                const device Light* lights [[buffer(2)]],
                                constant ArgumentBuffer& args [[buffer(3)]],
                                texture2d<half> gAlbedo [[texture(0)]],
                                texture2d<half> gNormal [[texture(1)]],
                                depth2d<float> shadowMap [[texture(2)]],
                                texturecube<half> envMap [[texture(3)]],
                                texture2d_array<float> lut [[texture(4)]],
                                texture3d<half> fog [[texture(5)]]) {
    uint2 pixel = uint2(in.position.xy);
    half4 albedo = gAlbedo.read(pixel);
    half3 n = normalize(gNormal.read(pixel, 0).xyz * 2.0h - 1.0h);
    half3 v = half3(normalize(u.cameraPosition - in.worldPosition));
    half3 color = half3(0.0h);
    for (uint i = 0; i < min(u.lightCount, kMaxLights); ++i) {
        float3 lp = lights[i].position;
        float3 toLight = lp - in.worldPosition;
        float dist2 = length_squared(toLight);
        half3 l = half3(normalize(toLight));
        half ndotl = saturate(dot(n, l));
        half3 h = normalize(l + v);
        half spec = pow(saturate(dot(n, h)), 32.0h);
        half atten = half(lights[i].intensity / max(dist2, 1e-4));
        half3 lc = half3(float3(lights[i].color));
        color += (albedo.rgb * ndotl + spec) * lc * atten;
    }
    float3 sunDir = u.sunDirection;
    half3 sun = half3(1.0h, 0.95h, 0.9h) * half(u.sunIntensity) * saturate(dot(n, half3(normalize(sunDir))));
    if (kUseShadows && kUseShadowsDefined) {
        float4 lightClip = u.viewProjectionMatrix * float4(in.worldPosition, 1.0);
        float3 lightNdc = lightClip.xyz / lightClip.w;
        float2 shadowUv = lightNdc.xy * 0.5 + 0.5;
        float shadow = 0.0;
        for (int i = 0; i < 4; ++i) {
            shadow += shadowMap.sample_compare(kShadowSampler, shadowUv + kPoissonDisk[i] * 0.001, lightNdc.z);
        }
        shadow += shadowMap.sample(kNearestClamp, shadowUv) + shadowMap.read(pixel);
        sun *= half(shadow * 0.25);
    }
    color += albedo.rgb * sun;
    half3 r = reflect(-v, n);
    half4 env = envMap.sample(kLinearSampler, float3(r), level(2.0));
    half4 env2 = envMap.sample(kLinearSampler, float3(r), bias(-1.0));
    float4 lutValue = lut.sample(kNearestClamp, in.uv, 2u);
    float4 lut2 = lut.sample(kNearestClamp, in.uv, 0, gradient2d(dfdx(in.uv), dfdy(in.uv)));
    half4 fogSample = fog.sample(kLinearSampler, float3(in.uv, 0.5), level(0));
    float4 argSample = args.albedoMap.sample(args.samp, in.uv) + args.extra[1].sample(kLinearSampler, in.uv, int2(1, 0));
    color = mix(color, env.rgb * env2.a, half(lutValue.r) * fogSample.a * half(lut2.g) * half(argSample.b));
    half4 gathered = gAlbedo.gather(kNearestClamp, in.uv, int2(1, 0), component::x);
    color += gathered.rgb * 0.001h;
    color = select(color, half3(1.0h, 0.0h, 1.0h), any(isnan(color)));
    bool3 mask = color > 1.0h;
    if (all(mask)) {
        color = half3(1.0h);
    }
    if (any(color < half3(0.0h))) {
        color = abs(color);
    }
    return half4(color, albedo.a);
}

fragment float4 simpleFragment(VertexOut in [[stage_in]]) {
    return float4(in.uv, 0.0, 1.0) * float4(in.color);
}

// ---------------------------------------------------------------------------
// Compute: threadgroup memory, atomics, barriers, simdgroup ops
// ---------------------------------------------------------------------------
[[max_total_threads_per_threadgroup(256)]]
kernel void reduceLuminance(texture2d<float, access::read> hdr [[texture(0)]],
                            texture2d<float, access::write> preview [[texture(1)]],
                            device atomic_uint* histogram [[buffer(0)]],
                            device float* result [[buffer(1)]],
                            constant Uniforms& u [[buffer(2)]],
                            device atomic<float>* luminanceSum [[buffer(3)]],
                            uint3 gid [[thread_position_in_grid]],
                            uint3 tptg [[threads_per_threadgroup]],
                            uint tid [[thread_index_in_threadgroup]],
                            ushort2 tgid [[threadgroup_position_in_grid]],
                            uint sgIndex [[simdgroup_index_in_threadgroup]],
                            uint lane [[thread_index_in_simdgroup]],
                            uint simdWidth [[threads_per_simdgroup]]) {
    threadgroup float shared[256];
    threadgroup atomic_uint tgCounter;
    threadgroup uint tgFlags[2];
    if (tid == 0) {
        atomic_store_explicit(&tgCounter, 0u, memory_order_relaxed);
        tgFlags[0] = 0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lum = 0.0;
    if (gid.x < hdr.get_width() && gid.y < hdr.get_height()) {
        float4 c = hdr.read(gid.xy);
        lum = luminance(c.rgb);
        preview.write(float4(c.rgb * kExposure, 1.0), gid.xy);
    }
    shared[tid] = lum;
    threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device);
    float sum = simd_sum(lum);
    float mx = simd_max(lum);
    float neighbor = simd_shuffle_down(lum, 1);
    float first = simd_broadcast_first(lum);
    float lane0 = simd_broadcast(lum, 0);
    float xored = simd_shuffle_xor(lum, 1);
    float prefix = simd_prefix_exclusive_sum(lum);
    simd_vote vote = simd_ballot(lum > 0.5);
    uint votes = popcount((simd_vote::vote_t)vote);
    bool allBright = simd_all(lum > 0.5) || vote.any();
    if (simd_is_first()) {
        uint bin = clamp(uint(log2(sum + 1.0) * 8.0), 0u, kHistogramBins - 1u);
        atomic_fetch_add_explicit(&histogram[bin], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&tgCounter, 1, memory_order_relaxed);
        atomic_fetch_max_explicit(histogram + 256, votes, memory_order_relaxed);
        atomic_fetch_add_explicit(luminanceSum, sum, memory_order_relaxed);
    }
    simdgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = tptg.x * tptg.y / 2; stride > 0; stride >>= 1) {
        if (tid < stride) {
            shared[tid] += shared[tid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) {
        uint expected = 0;
        uint count = atomic_load_explicit(&tgCounter, memory_order_relaxed);
        while (!atomic_compare_exchange_weak_explicit(&histogram[257], &expected, count,
                                                      memory_order_relaxed, memory_order_relaxed)) {
            if (expected >= count) {
                break;
            }
        }
        uint old = atomic_exchange_explicit(&histogram[258], 0u, memory_order_relaxed);
        uint index = uint(tgid.x) + uint(tgid.y) * 64u;
        result[index] = shared[0] + mx + neighbor + first + lane0 + xored + prefix + float(old) + float(allBright)
                      + float(simdWidth + sgIndex + lane) + kWeights[3] + u.time + float(tgFlags[0]);
    }
}

[[kernel]] void clearBuffer(device float4* data [[buffer(0)]],
                            uint id [[thread_position_in_grid]],
                            uint count [[threads_per_grid]]) {
    if (id < count) {
        data[id] = float4(0.0);
    }
}

// ---------------------------------------------------------------------------
// Ray tracing
// ---------------------------------------------------------------------------
kernel void raytraceKernel(instance_acceleration_structure accel [[buffer(0)]],
                           intersection_function_table<triangle_data, instancing> functionTable [[buffer(1)]],
                           constant Uniforms& u [[buffer(2)]],
                           const device Light* lights [[buffer(3)]],
                           primitive_acceleration_structure prims [[buffer(4)]],
                           acceleration_structure<instancing, primitive_motion> motionAccel [[buffer(5)]],
                           texture2d<float, access::write> output [[texture(0)]],
                           texture2d<float, access::read_write> accum [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]],
                           uint2 gridSize [[threads_per_grid]]) {
    if (gid.x >= gridSize.x || gid.y >= gridSize.y) {
        return;
    }
    float2 uv = (float2(gid) + 0.5) / float2(gridSize);
    float2 ndc = uv * 2.0 - 1.0;
    float4 target = u.projectionMatrix * float4(ndc, 1.0, 1.0);
    float3 dir = normalize((u.viewMatrix * float4(target.xyz / target.w, 0.0)).xyz);
    ray r(u.cameraPosition, dir, 0.001, INFINITY);
    ray r2 = ray(u.cameraPosition, dir);
    r2.min_distance = 0.01;
    r2.max_distance = 100.0;

    intersector<triangle_data, instancing> isect;
    isect.accept_any_intersection(false);
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    isect.set_triangle_cull_mode(triangle_cull_mode::back);
    intersection_result<triangle_data, instancing> hit = isect.intersect(r, accel, 0xFFu);
    intersector<triangle_data, instancing>::result hit2 = isect.intersect(r2, accel, 0xFFu, functionTable);
    intersector<triangle_data, instancing, world_space_data> motionIsect;
    auto hit3 = motionIsect.intersect(r, motionAccel);

    float3 color = float3(0.0);
    if (hit.type == intersection_type::triangle) {
        float2 bary = hit.triangle_barycentric_coord;
        float3 weights = float3(1.0 - bary.x - bary.y, bary.x, bary.y);
        uint prim = hit.primitive_id;
        uint geom = hit.geometry_id;
        uint inst = hit.instance_id;
        float3 hitPos = r.origin + r.direction * hit.distance;
        float4x3 o2w = hit.object_to_world_transform;
        float3 worldHit = o2w * float4(hitPos, 1.0);
        color = weights * (hit.triangle_front_facing ? 1.0 : 0.5)
              + float3(float(prim % 7u), float(geom % 5u), float(inst % 3u)) * 0.1 + worldHit * 0.0;
        intersector<triangle_data, instancing> shadowIsect;
        shadowIsect.accept_any_intersection(true);
        ray shadowRay(hitPos + kUp * 0.001, normalize(float3(u.sunDirection)), 0.0, 1000.0);
        auto shadowHit = shadowIsect.intersect(shadowRay, accel);
        if (shadowHit.type != intersection_type::none) {
            color *= 0.3;
        }
        color += lights[0].intensity * float3(lights[0].color) * 0.0;
    } else if (hit2.type == intersection_type::bounding_box) {
        color = float3(hit2.distance);
    } else if (hit3.type == intersection_type::none) {
        color = float3(0.1, 0.2, 0.3);
    }

    RayPayload payload;
    payload.color = color;
    payload.distance = hit.distance;
    payload.bounces = 0;

    intersection_query<triangle_data> query(r, prims, 0xFFu);
    while (query.next()) {
        query.commit_triangle_intersection();
    }
    if (query.get_committed_intersection_type() == intersection_type::triangle) {
        color += query.get_committed_distance() * 0.0 + payload.color * 0.0;
    }

    float4 prev = accum.read(gid);
    float4 blended = mix(prev, float4(color, 1.0), 1.0 / float(kSampleCount + 1));
    accum.write(blended, gid);
    accum.fence();
    output.write(float4(blended.rgb * kExposure, 1.0), gid);
}

[[intersection(triangle, triangle_data, instancing)]]
bool alphaTestIntersection(uint primitiveId [[primitive_id]],
                           uint instanceId [[instance_id]],
                           float2 bary [[barycentric_coord]],
                           float dist [[distance]],
                           ray_data RayPayload& payload [[payload]],
                           const device float* alphas [[buffer(0)]]) {
    payload.distance = dist;
    return alphas[primitiveId] > 0.5 && bary.x + bary.y <= 1.0 && instanceId != 0xFFFFFFFFu;
}

struct BoundingBoxResult {
    bool accept [[accept_intersection]];
    float distance [[distance]];
};

[[intersection(bounding_box)]]
BoundingBoxResult sphereIntersection(float3 origin [[origin]],
                                     float3 direction [[direction]],
                                     float minDistance [[min_distance]],
                                     float maxDistance [[max_distance]],
                                     uint primitiveId [[primitive_id]],
                                     const device float4* spheres [[buffer(0)]]) {
    BoundingBoxResult result;
    result.accept = false;
    result.distance = maxDistance;
    float4 s = spheres[primitiveId];
    float3 oc = origin - s.xyz;
    float b = dot(oc, direction);
    float c = dot(oc, oc) - s.w * s.w;
    float disc = b * b - c;
    if (disc >= 0.0) {
        float t = -b - sqrt(disc);
        if (t > minDistance && t < maxDistance) {
            result.accept = true;
            result.distance = t;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Ties the coverage helpers together so nothing is flagged as unused.
// ---------------------------------------------------------------------------
kernel void coverageKernel(device float4* out [[buffer(0)]],
                           uint3 gid [[thread_position_in_grid]]) {
    float4x4 m = float4x4(1.0);
    matrixTests(m, float3(gid));
    float4 v = vectorTests(m[0], half4(m[1]), gid, packed_float3(1.0, 2.0, 3.0));
    float f = mathTests(v.x, v.xyz, half(v.y), half3(v.xyz), int(gid.x), gid.y);
    out[gid.x] = v + f;
}
