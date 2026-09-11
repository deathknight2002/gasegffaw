// metal-lint stub: <metal_math>, <metal_integer>, <metal_relational>,
// <metal_geometric>, <metal_common>, <metal_pack>, <metal_limits>.
#ifndef __MSL_MATH_H
#define __MSL_MATH_H

#include "types.h"

namespace metal {

// ---- floating-point math, also in fast:: and precise:: --------------------
#include "math_decls.inc"
namespace fast {
#include "math_decls.inc"
}
namespace precise {
#include "math_decls.inc"
}

// ---- integer math ---------------------------------------------------------
#define __MSL_ID1(T, name) T name(T);
#define __MSL_ID2(T, name) T name(T, T);
#define __MSL_ID3(T, name) T name(T, T, T);
#define __MSL_IDBITS(T, name) T name(T, uint, uint);
#define __MSL_IDINS(T, name) T name(T, T, uint, uint);
#define __MSL_I_EACH(X, name)                                                   \
    X(char, name) X(char2, name) X(char3, name) X(char4, name)                  \
    X(uchar, name) X(uchar2, name) X(uchar3, name) X(uchar4, name)              \
    X(short, name) X(short2, name) X(short3, name) X(short4, name)              \
    X(ushort, name) X(ushort2, name) X(ushort3, name) X(ushort4, name)          \
    X(int, name) X(int2, name) X(int3, name) X(int4, name)                      \
    X(uint, name) X(uint2, name) X(uint3, name) X(uint4, name)                  \
    X(long, name) X(long2, name) X(long3, name) X(long4, name)                  \
    X(ulong, name) X(ulong2, name) X(ulong3, name) X(ulong4, name)
#define __MSL_I1(name) __MSL_I_EACH(__MSL_ID1, name)
#define __MSL_I2(name) __MSL_I_EACH(__MSL_ID2, name)
#define __MSL_I3(name) __MSL_I_EACH(__MSL_ID3, name)

__MSL_I1(abs)
__MSL_I2(min) __MSL_I2(max)
__MSL_I3(clamp)
__MSL_I1(popcount) __MSL_I1(clz) __MSL_I1(ctz) __MSL_I1(reverse_bits)
__MSL_I2(rotate) __MSL_I2(mulhi) __MSL_I2(mul24) __MSL_I2(absdiff)
__MSL_I2(addsat) __MSL_I2(subsat) __MSL_I2(hadd) __MSL_I2(rhadd)
__MSL_I3(mad24) __MSL_I3(madsat) __MSL_I3(madhi)
__MSL_I_EACH(__MSL_IDBITS, extract_bits)
__MSL_I_EACH(__MSL_IDINS, insert_bits)

#undef __MSL_I1
#undef __MSL_I2
#undef __MSL_I3
#undef __MSL_I_EACH
#undef __MSL_ID1
#undef __MSL_ID2
#undef __MSL_ID3
#undef __MSL_IDBITS
#undef __MSL_IDINS

// ---- relational -----------------------------------------------------------
#define __MSL_REL1(name)                                                        \
    bool name(float); bool2 name(float2); bool3 name(float3); bool4 name(float4); \
    bool name(half); bool2 name(half2); bool3 name(half3); bool4 name(half4);
#define __MSL_REL2(name)                                                        \
    bool name(float, float); bool2 name(float2, float2);                        \
    bool3 name(float3, float3); bool4 name(float4, float4);                     \
    bool name(half, half); bool2 name(half2, half2);                            \
    bool3 name(half3, half3); bool4 name(half4, half4);
__MSL_REL1(isnan) __MSL_REL1(isinf) __MSL_REL1(isfinite) __MSL_REL1(isnormal)
__MSL_REL1(signbit)
__MSL_REL2(isordered) __MSL_REL2(isunordered)
#undef __MSL_REL1
#undef __MSL_REL2

// any/all accept bool vectors and raw comparison results (int vectors).
template <class C> bool any(C);
template <class C> bool all(C);
// select(a, b, c): c may be bool, boolN, or the intN/shortN result of a
// vector comparison.
template <class T, class C> T select(T a, T b, C c);

// ---- pack / unpack --------------------------------------------------------
uint pack_float_to_unorm4x8(float4);
uint pack_float_to_snorm4x8(float4);
uint pack_float_to_unorm2x16(float2);
uint pack_float_to_snorm2x16(float2);
uint pack_float_to_srgb_unorm4x8(float4);
uint pack_float_to_unorm10a2(float4);
uint pack_half_to_unorm4x8(half4);
uint pack_half_to_snorm4x8(half4);
uint pack_half_to_unorm2x16(half2);
uint pack_half_to_snorm2x16(half2);
float4 unpack_unorm4x8_to_float(uint);
float4 unpack_snorm4x8_to_float(uint);
float2 unpack_unorm2x16_to_float(uint);
float2 unpack_snorm2x16_to_float(uint);
float4 unpack_unorm4x8_srgb_to_float(uint);
float4 unpack_unorm10a2_to_float(uint);
half4 unpack_unorm4x8_to_half(uint);
half4 unpack_snorm4x8_to_half(uint);
half2 unpack_unorm2x16_to_half(uint);
half2 unpack_snorm2x16_to_half(uint);

// ---- numeric_limits -------------------------------------------------------
template <class T> struct numeric_limits;
#define __MSL_LIMITS(T, MINV, MAXV, LOWV, EPSV, INFV, NANV, DIGITS)             \
    template <> struct numeric_limits<T> {                                      \
        static constexpr bool is_specialized = true;                            \
        static constexpr int digits = DIGITS;                                   \
        static constexpr T min() { return MINV; }                               \
        static constexpr T max() { return MAXV; }                               \
        static constexpr T lowest() { return LOWV; }                            \
        static constexpr T epsilon() { return EPSV; }                           \
        static constexpr T infinity() { return INFV; }                          \
        static constexpr T quiet_NaN() { return NANV; }                          \
        static constexpr T denorm_min() { return MINV; }                        \
    };
__MSL_LIMITS(float, FLT_MIN, FLT_MAX, -FLT_MAX, FLT_EPSILON, __builtin_inff(), __builtin_nanf(""), 24)
__MSL_LIMITS(half, HALF_MIN, HALF_MAX, -HALF_MAX, HALF_EPSILON, HUGE_VALH, (half)__builtin_nanf(""), 11)
__MSL_LIMITS(bool, false, true, false, false, false, false, 1)
__MSL_LIMITS(char, SCHAR_MIN, SCHAR_MAX, SCHAR_MIN, 0, 0, 0, 7)
__MSL_LIMITS(uchar, 0, UCHAR_MAX, 0, 0, 0, 0, 8)
__MSL_LIMITS(short, SHRT_MIN, SHRT_MAX, SHRT_MIN, 0, 0, 0, 15)
__MSL_LIMITS(ushort, 0, USHRT_MAX, 0, 0, 0, 0, 16)
__MSL_LIMITS(int, INT_MIN, INT_MAX, INT_MIN, 0, 0, 0, 31)
__MSL_LIMITS(uint, 0u, UINT_MAX, 0u, 0u, 0u, 0u, 32)
__MSL_LIMITS(long, LONG_MIN, LONG_MAX, LONG_MIN, 0, 0, 0, 63)
__MSL_LIMITS(ulong, 0ul, ULONG_MAX, 0ul, 0ul, 0ul, 0ul, 64)
#undef __MSL_LIMITS

// ---- fragment-only helpers ------------------------------------------------
void discard_fragment();

// ---- function constants ---------------------------------------------------
template <class T> constexpr bool is_function_constant_defined(const T&) { return true; }

// ---- array<T, N> ----------------------------------------------------------
template <class T, size_t N>
struct array {
    T __elems[N];
    constexpr size_t size() const { return N; }
    constexpr T& operator[](size_t i) { return __elems[i]; }
    constexpr const T& operator[](size_t i) const { return __elems[i]; }
    constexpr T* data() { return __elems; }
    constexpr const T* data() const { return __elems; }
    constexpr T* begin() { return __elems; }
    constexpr T* end() { return __elems + N; }
    constexpr const T* begin() const { return __elems; }
    constexpr const T* end() const { return __elems + N; }
    constexpr T& front() { return __elems[0]; }
    constexpr T& back() { return __elems[N - 1]; }
};
template <class T> struct array_ref {
    const T* __p; size_t __n;
    constexpr size_t size() const { return __n; }
    constexpr const T& operator[](size_t i) const { return __p[i]; }
};

} // namespace metal

#endif // __MSL_MATH_H
