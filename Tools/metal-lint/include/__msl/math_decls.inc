// metal-lint stub: floating-point math declarations.
// No include guard on purpose: this file is included three times, inside
// namespace metal, metal::fast and metal::precise. Everything here is a
// declaration only -- -fsyntax-only never needs bodies.

#define __MSL_D1(T, name) T name(T);
#define __MSL_D2(T, name) T name(T, T);
#define __MSL_D3(T, name) T name(T, T, T);
#define __MSL_DREF(T, name) T name(T, thread T&);

#define __MSL_F1(name)                                                         \
    __MSL_D1(float, name) __MSL_D1(float2, name) __MSL_D1(float3, name)        \
    __MSL_D1(float4, name) __MSL_D1(half, name) __MSL_D1(half2, name)          \
    __MSL_D1(half3, name) __MSL_D1(half4, name)
#define __MSL_F2(name)                                                         \
    __MSL_D2(float, name) __MSL_D2(float2, name) __MSL_D2(float3, name)        \
    __MSL_D2(float4, name) __MSL_D2(half, name) __MSL_D2(half2, name)          \
    __MSL_D2(half3, name) __MSL_D2(half4, name)
#define __MSL_F3(name)                                                         \
    __MSL_D3(float, name) __MSL_D3(float2, name) __MSL_D3(float3, name)        \
    __MSL_D3(float4, name) __MSL_D3(half, name) __MSL_D3(half2, name)          \
    __MSL_D3(half3, name) __MSL_D3(half4, name)
#define __MSL_FREF(name)                                                       \
    __MSL_DREF(float, name) __MSL_DREF(float2, name) __MSL_DREF(float3, name)  \
    __MSL_DREF(float4, name) __MSL_DREF(half, name) __MSL_DREF(half2, name)    \
    __MSL_DREF(half3, name) __MSL_DREF(half4, name)

// Trigonometric / hyperbolic
__MSL_F1(sin) __MSL_F1(cos) __MSL_F1(tan)
__MSL_F1(asin) __MSL_F1(acos) __MSL_F1(atan)
__MSL_F1(sinh) __MSL_F1(cosh) __MSL_F1(tanh)
__MSL_F1(asinh) __MSL_F1(acosh) __MSL_F1(atanh)
__MSL_F1(sinpi) __MSL_F1(cospi) __MSL_F1(tanpi)
__MSL_F2(atan2)
__MSL_FREF(sincos)
// Exponential / power
__MSL_F1(exp) __MSL_F1(exp2) __MSL_F1(exp10)
__MSL_F1(log) __MSL_F1(log2) __MSL_F1(log10)
__MSL_F1(sqrt) __MSL_F1(rsqrt) __MSL_F1(cbrt)
__MSL_F2(pow) __MSL_F2(powr) __MSL_F2(divide)
// Rounding / sign
__MSL_F1(fabs) __MSL_F1(abs) __MSL_F1(sign)
__MSL_F1(floor) __MSL_F1(ceil) __MSL_F1(round) __MSL_F1(rint) __MSL_F1(trunc)
__MSL_F1(fract) __MSL_F1(saturate)
__MSL_F2(fmod) __MSL_F2(fmin) __MSL_F2(fmax) __MSL_F2(fdim)
__MSL_F2(min) __MSL_F2(max) __MSL_F2(copysign) __MSL_F2(nextafter)
__MSL_FREF(modf)
// Blending / interpolation
__MSL_F2(step)
__MSL_F3(mix) __MSL_F3(clamp) __MSL_F3(smoothstep)
__MSL_F3(fma) __MSL_F3(mad)
// Geometric
__MSL_F1(normalize)
__MSL_F2(reflect) __MSL_F3(faceforward)
float dot(float2, float2);   float dot(float3, float3);   float dot(float4, float4);
half dot(half2, half2);      half dot(half3, half3);      half dot(half4, half4);
float dot(float, float);     half dot(half, half);
float3 cross(float3, float3);
half3 cross(half3, half3);
float length(float);   float length(float2);   float length(float3);   float length(float4);
half length(half);     half length(half2);     half length(half3);     half length(half4);
float length_squared(float);   float length_squared(float2);
float length_squared(float3);  float length_squared(float4);
half length_squared(half);     half length_squared(half2);
half length_squared(half3);    half length_squared(half4);
float distance(float, float);   float distance(float2, float2);
float distance(float3, float3); float distance(float4, float4);
half distance(half, half);      half distance(half2, half2);
half distance(half3, half3);    half distance(half4, half4);
float distance_squared(float, float);   float distance_squared(float2, float2);
float distance_squared(float3, float3); float distance_squared(float4, float4);
half distance_squared(half, half);      half distance_squared(half2, half2);
half distance_squared(half3, half3);    half distance_squared(half4, half4);
float refract(float, float, float);     float2 refract(float2, float2, float);
float3 refract(float3, float3, float);  float4 refract(float4, float4, float);
half refract(half, half, half);         half2 refract(half2, half2, half);
half3 refract(half3, half3, half);      half4 refract(half4, half4, half);
// Derivatives (fragment functions)
__MSL_F1(dfdx) __MSL_F1(dfdy) __MSL_F1(fwidth)
// ldexp / frexp
float ldexp(float, int);   float2 ldexp(float2, int2);   float3 ldexp(float3, int3);   float4 ldexp(float4, int4);
half ldexp(half, int);     half2 ldexp(half2, int2);     half3 ldexp(half3, int3);     half4 ldexp(half4, int4);
float frexp(float, thread int&);   float2 frexp(float2, thread int2&);
float3 frexp(float3, thread int3&); float4 frexp(float4, thread int4&);
half frexp(half, thread int&);     half2 frexp(half2, thread int2&);
half3 frexp(half3, thread int3&);  half4 frexp(half4, thread int4&);
int ilogb(float); int2 ilogb(float2); int3 ilogb(float3); int4 ilogb(float4);
int ilogb(half);  int2 ilogb(half2);  int3 ilogb(half3);  int4 ilogb(half4);

#undef __MSL_F1
#undef __MSL_F2
#undef __MSL_F3
#undef __MSL_FREF
#undef __MSL_D1
#undef __MSL_D2
#undef __MSL_D3
#undef __MSL_DREF
