// metal-lint stub: scalar, vector, packed and bool-vector types.
//
// Design (verified empirically against clang 18, see README.md):
//  * Vector types are plain clang ext_vector_type typedefs. That gives native
//    .xyzw/.rgba swizzles (read and write), element subscripts, component-wise
//    arithmetic, scalar splats and comparisons for free.
//  * MSL's function-style constructors (float4(a, b, c, d), float4(v3, 1.0),
//    half4(f4)) are NOT supported by clang for ext_vector typedefs. They are
//    provided by function-like macros: '#define float4(...)' expands only when
//    the name is directly followed by '(' -- so 'float4 v', 'texture2d<float4>',
//    'sizeof(float4)' and 'static_cast<float4>(x)' are untouched, while
//    'float4(x, y, z, w)' becomes '__msl_make_float4(x, y, z, w)'.
//  * Overload sets for the makers mirror the MSL constructor rules: splat from
//    a scalar, explicit conversion from a same-size vector, or composition of
//    scalars/vectors whose component counts add up to N. (float3(float4) is
//    rejected, as in MSL; use .xyz.)
//  * half is _Float16; the MSL 'h' literal suffix (1.0h, 2h) is a UDL.
//  * bool2/3/4 are small structs (clang comparisons on ext vectors yield int
//    vectors, which cannot convert to clang's bool vectors), implicitly
//    constructible from any same-size vector.
//  * packed_* types are structs with .x/.y/.z/.w, implicitly convertible to and
//    from the unpacked vector. Swizzles on packed types are not supported.
#ifndef __MSL_TYPES_H
#define __MSL_TYPES_H

#include "config.h"

// ---------------------------------------------------------------------------
// Scalars
// ---------------------------------------------------------------------------
typedef unsigned char uchar;
typedef unsigned short ushort;
typedef unsigned int uint;
typedef unsigned long ulong;
typedef _Float16 half;
typedef __SIZE_TYPE__ size_t;
typedef __PTRDIFF_TYPE__ ptrdiff_t;
typedef signed char int8_t;
typedef unsigned char uint8_t;
typedef short int16_t;
typedef unsigned short uint16_t;
typedef int int32_t;
typedef unsigned int uint32_t;
typedef long int64_t;
typedef unsigned long uint64_t;
typedef long intptr_t;
typedef unsigned long uintptr_t;

// ---------------------------------------------------------------------------
// Vectors (ext_vector_type)
// ---------------------------------------------------------------------------
#define __MSL_VEC_TYPEDEFS(T)                                  \
    typedef T T##2 __attribute__((ext_vector_type(2)));        \
    typedef T T##3 __attribute__((ext_vector_type(3)));        \
    typedef T T##4 __attribute__((ext_vector_type(4)));

__MSL_VEC_TYPEDEFS(char)
__MSL_VEC_TYPEDEFS(uchar)
__MSL_VEC_TYPEDEFS(short)
__MSL_VEC_TYPEDEFS(ushort)
__MSL_VEC_TYPEDEFS(int)
__MSL_VEC_TYPEDEFS(uint)
__MSL_VEC_TYPEDEFS(long)
__MSL_VEC_TYPEDEFS(ulong)
__MSL_VEC_TYPEDEFS(half)
__MSL_VEC_TYPEDEFS(float)
#undef __MSL_VEC_TYPEDEFS

// ---------------------------------------------------------------------------
// Minimal traits (no libc++ available: the linter runs with -nostdinc++)
// ---------------------------------------------------------------------------
namespace __msl {

template <bool B, class T = int> struct enable_if {};
template <class T> struct enable_if<true, T> { typedef T type; };
template <bool B> using en = typename enable_if<B, int>::type;

template <class A, class B> struct is_same { static constexpr bool value = false; };
template <class A> struct is_same<A, A> { static constexpr bool value = true; };

template <class T> struct identity { typedef T type; };
template <class T> using id_t = typename identity<T>::type;

template <class T> struct remove_cv { typedef T type; };
template <class T> struct remove_cv<const T> { typedef T type; };
template <class T> struct remove_cv<volatile T> { typedef T type; };
template <class T> struct remove_cv<const volatile T> { typedef T type; };
template <class T> struct remove_ref { typedef T type; };
template <class T> struct remove_ref<T&> { typedef T type; };
template <class T> struct remove_ref<T&&> { typedef T type; };
template <class T> using bare = typename remove_cv<typename remove_ref<T>::type>::type;

template <class T> struct is_scalar_impl { static constexpr bool value = false; };
#define __MSL_SCALAR(T) template <> struct is_scalar_impl<T> { static constexpr bool value = true; };
__MSL_SCALAR(bool)
__MSL_SCALAR(char)
__MSL_SCALAR(signed char)
__MSL_SCALAR(uchar)
__MSL_SCALAR(short)
__MSL_SCALAR(ushort)
__MSL_SCALAR(int)
__MSL_SCALAR(uint)
__MSL_SCALAR(long)
__MSL_SCALAR(ulong)
__MSL_SCALAR(long long)
__MSL_SCALAR(unsigned long long)
__MSL_SCALAR(half)
__MSL_SCALAR(float)
__MSL_SCALAR(double)
#undef __MSL_SCALAR
template <class T> struct is_scalar : is_scalar_impl<bare<T>> {};

// Number of components: 1 for scalars, N for vector-like types, 0 otherwise.
template <class T> struct ncomp_impl { static constexpr int value = is_scalar<T>::value ? 1 : 0; };
template <class T> struct ncomp : ncomp_impl<bare<T>> {};
#define __MSL_NCOMP(T, N) template <> struct ncomp_impl<T> { static constexpr int value = N; };

// Element type of a vector-like type (identity for scalars).
template <class T> struct elem_impl { typedef T type; };
template <class T> struct elem : elem_impl<bare<T>> {};
#define __MSL_ELEM(T, E) template <> struct elem_impl<T> { typedef E type; };

#define __MSL_VEC_TRAITS(T)     \
    __MSL_NCOMP(T##2, 2)        \
    __MSL_NCOMP(T##3, 3)        \
    __MSL_NCOMP(T##4, 4)        \
    __MSL_ELEM(T##2, T)         \
    __MSL_ELEM(T##3, T)         \
    __MSL_ELEM(T##4, T)
__MSL_VEC_TRAITS(char)
__MSL_VEC_TRAITS(uchar)
__MSL_VEC_TRAITS(short)
__MSL_VEC_TRAITS(ushort)
__MSL_VEC_TRAITS(int)
__MSL_VEC_TRAITS(uint)
__MSL_VEC_TRAITS(long)
__MSL_VEC_TRAITS(ulong)
__MSL_VEC_TRAITS(half)
__MSL_VEC_TRAITS(float)
#undef __MSL_VEC_TRAITS

template <class T> constexpr bool is_vec_v = ncomp<T>::value > 1;
template <class T> constexpr bool is_scalar_v = is_scalar<T>::value;
template <class T> constexpr int ncomp_v = ncomp<T>::value;

// Dependent ext_vector alias: vec<float, 3> is exactly float3. clang deduces
// T and N from ext_vector arguments, so library templates use this.
template <class T, int N> using vec = T __attribute__((ext_vector_type(N)));
template <class T, int N> struct vec_of { typedef vec<T, N> type; };
template <class T> struct vec_of<T, 1> { typedef T type; };
template <class T, int N> using vec_t = typename vec_of<T, N>::type;

} // namespace __msl

// ---------------------------------------------------------------------------
// Vector "constructors": __msl_make_<type>(...), exposed through macros below.
// Scalar-only forms are constexpr (clang 18 can constant-evaluate brace init
// of ext vectors); forms that take vectors are declarations only, because
// clang 18 cannot constant-evaluate vector element reads.
// ---------------------------------------------------------------------------
#define __MSL_MAKERS(T)                                                                      \
    constexpr T##2 __msl_make_##T##2() { return T##2{}; }                                    \
    constexpr T##3 __msl_make_##T##3() { return T##3{}; }                                    \
    constexpr T##4 __msl_make_##T##4() { return T##4{}; }                                    \
    /* splat */                                                                              \
    template <class A, __msl::en<__msl::is_scalar_v<A>> = 0>                                 \
    constexpr T##2 __msl_make_##T##2(A a) { return T##2{(T)a, (T)a}; }                       \
    template <class A, __msl::en<__msl::is_scalar_v<A>> = 0>                                 \
    constexpr T##3 __msl_make_##T##3(A a) { return T##3{(T)a, (T)a, (T)a}; }                 \
    template <class A, __msl::en<__msl::is_scalar_v<A>> = 0>                                 \
    constexpr T##4 __msl_make_##T##4(A a) { return T##4{(T)a, (T)a, (T)a, (T)a}; }           \
    /* explicit conversion from a same-size vector-like type */                              \
    template <class A, __msl::en<(__msl::ncomp_v<A> == 2 && !__msl::is_scalar_v<A>)> = 0>    \
    T##2 __msl_make_##T##2(A);                                                               \
    template <class A, __msl::en<(__msl::ncomp_v<A> == 3 && !__msl::is_scalar_v<A>)> = 0>    \
    T##3 __msl_make_##T##3(A);                                                               \
    template <class A, __msl::en<(__msl::ncomp_v<A> == 4 && !__msl::is_scalar_v<A>)> = 0>    \
    T##4 __msl_make_##T##4(A);                                                               \
    /* all-scalar composition */                                                             \
    template <class A, class B,                                                              \
              __msl::en<(__msl::is_scalar_v<A> && __msl::is_scalar_v<B>)> = 0>               \
    constexpr T##2 __msl_make_##T##2(A a, B b) { return T##2{(T)a, (T)b}; }                  \
    template <class A, class B, class C,                                                     \
              __msl::en<(__msl::is_scalar_v<A> && __msl::is_scalar_v<B> &&                   \
                         __msl::is_scalar_v<C>)> = 0>                                        \
    constexpr T##3 __msl_make_##T##3(A a, B b, C c) { return T##3{(T)a, (T)b, (T)c}; }       \
    template <class A, class B, class C, class D,                                            \
              __msl::en<(__msl::is_scalar_v<A> && __msl::is_scalar_v<B> &&                   \
                         __msl::is_scalar_v<C> && __msl::is_scalar_v<D>)> = 0>               \
    constexpr T##4 __msl_make_##T##4(A a, B b, C c, D d) {                                   \
        return T##4{(T)a, (T)b, (T)c, (T)d};                                                 \
    }                                                                                        \
    /* mixed vector/scalar composition: component counts must add up to N */                 \
    template <class A, class B,                                                              \
              __msl::en<(__msl::ncomp_v<A> >= 1 && __msl::ncomp_v<B> >= 1 &&                 \
                         __msl::ncomp_v<A> + __msl::ncomp_v<B> == 3)> = 0>                   \
    T##3 __msl_make_##T##3(A, B);                                                            \
    template <class A, class B,                                                              \
              __msl::en<(__msl::ncomp_v<A> >= 1 && __msl::ncomp_v<B> >= 1 &&                 \
                         __msl::ncomp_v<A> + __msl::ncomp_v<B> == 4)> = 0>                   \
    T##4 __msl_make_##T##4(A, B);                                                            \
    template <class A, class B, class C,                                                     \
              __msl::en<(__msl::ncomp_v<A> >= 1 && __msl::ncomp_v<B> >= 1 &&                 \
                         __msl::ncomp_v<C> >= 1 &&                                           \
                         __msl::ncomp_v<A> + __msl::ncomp_v<B> + __msl::ncomp_v<C> == 4)> = 0> \
    T##4 __msl_make_##T##4(A, B, C);

__MSL_MAKERS(char)
__MSL_MAKERS(uchar)
__MSL_MAKERS(short)
__MSL_MAKERS(ushort)
__MSL_MAKERS(int)
__MSL_MAKERS(uint)
__MSL_MAKERS(long)
__MSL_MAKERS(ulong)
__MSL_MAKERS(half)
__MSL_MAKERS(float)
#undef __MSL_MAKERS

// ---------------------------------------------------------------------------
// Packed vectors: structs with named components, convertible both ways.
// ---------------------------------------------------------------------------
#define __MSL_PACKED_OPS(T, N)                                                               \
    template <class B, __msl::en<(__msl::is_scalar_v<B> || __msl::ncomp_v<B> == N)> = 0>     \
    T##N operator+(const packed_##T##N&, B);                                                 \
    template <class B, __msl::en<(__msl::is_scalar_v<B> || __msl::ncomp_v<B> == N)> = 0>     \
    T##N operator-(const packed_##T##N&, B);                                                 \
    template <class B, __msl::en<(__msl::is_scalar_v<B> || __msl::ncomp_v<B> == N)> = 0>     \
    T##N operator*(const packed_##T##N&, B);                                                 \
    template <class B, __msl::en<(__msl::is_scalar_v<B> || __msl::ncomp_v<B> == N)> = 0>     \
    T##N operator/(const packed_##T##N&, B);                                                 \
    template <class A, __msl::en<(__msl::is_scalar_v<A> || __msl::ncomp_v<A> == N)> = 0>     \
    T##N operator+(A, const packed_##T##N&);                                                 \
    template <class A, __msl::en<(__msl::is_scalar_v<A> || __msl::ncomp_v<A> == N)> = 0>     \
    T##N operator-(A, const packed_##T##N&);                                                 \
    template <class A, __msl::en<(__msl::is_scalar_v<A> || __msl::ncomp_v<A> == N)> = 0>     \
    T##N operator*(A, const packed_##T##N&);                                                 \
    template <class A, __msl::en<(__msl::is_scalar_v<A> || __msl::ncomp_v<A> == N)> = 0>     \
    T##N operator/(A, const packed_##T##N&);                                                 \
    T##N operator+(const packed_##T##N&, const packed_##T##N&);                              \
    T##N operator-(const packed_##T##N&, const packed_##T##N&);                              \
    T##N operator*(const packed_##T##N&, const packed_##T##N&);                              \
    T##N operator/(const packed_##T##N&, const packed_##T##N&);                              \
    T##N operator-(const packed_##T##N&);
#define __MSL_PACKED_TRAITS(T, N)                                                            \
    __MSL_NCOMP(packed_##T##N, N)                                                            \
    __MSL_ELEM(packed_##T##N, T)

#define __MSL_PACKED_COMMON(T, N)                                                            \
    typedef T __elem_type;                                                                   \
    operator T##N() const;                                                                   \
    T& operator[](int i) { return (&x)[i]; }                                                 \
    const T& operator[](int i) const { return (&x)[i]; }                                     \
    template <class B> packed_##T##N& operator+=(const B& b) { return *this = T##N(*this) + b; } \
    template <class B> packed_##T##N& operator-=(const B& b) { return *this = T##N(*this) - b; } \
    template <class B> packed_##T##N& operator*=(const B& b) { return *this = T##N(*this) * b; } \
    template <class B> packed_##T##N& operator/=(const B& b) { return *this = T##N(*this) / b; }

#define __MSL_PACKED(T)                                                                      \
    struct packed_##T##2 {                                                                   \
        T x, y;                                                                              \
        constexpr packed_##T##2() : x(0), y(0) {}                                            \
        constexpr packed_##T##2(T a) : x(a), y(a) {}                                         \
        constexpr packed_##T##2(T a, T b) : x(a), y(b) {}                                    \
        packed_##T##2(T##2 v) : x(v.x), y(v.y) {}                                            \
        __MSL_PACKED_COMMON(T, 2)                                                            \
    };                                                                                       \
    struct packed_##T##3 {                                                                   \
        T x, y, z;                                                                           \
        constexpr packed_##T##3() : x(0), y(0), z(0) {}                                      \
        constexpr packed_##T##3(T a) : x(a), y(a), z(a) {}                                   \
        constexpr packed_##T##3(T a, T b, T c) : x(a), y(b), z(c) {}                         \
        packed_##T##3(T##3 v) : x(v.x), y(v.y), z(v.z) {}                                    \
        __MSL_PACKED_COMMON(T, 3)                                                            \
    };                                                                                       \
    struct packed_##T##4 {                                                                   \
        T x, y, z, w;                                                                        \
        constexpr packed_##T##4() : x(0), y(0), z(0), w(0) {}                                \
        constexpr packed_##T##4(T a) : x(a), y(a), z(a), w(a) {}                             \
        constexpr packed_##T##4(T a, T b, T c, T d) : x(a), y(b), z(c), w(d) {}              \
        packed_##T##4(T##4 v) : x(v.x), y(v.y), z(v.z), w(v.w) {}                            \
        __MSL_PACKED_COMMON(T, 4)                                                            \
    };                                                                                       \
    __MSL_PACKED_OPS(T, 2)                                                                   \
    __MSL_PACKED_OPS(T, 3)                                                                   \
    __MSL_PACKED_OPS(T, 4)                                                                   \
    namespace __msl {                                                                        \
    __MSL_PACKED_TRAITS(T, 2)                                                                \
    __MSL_PACKED_TRAITS(T, 3)                                                                \
    __MSL_PACKED_TRAITS(T, 4)                                                                \
    }

__MSL_PACKED(char)
__MSL_PACKED(uchar)
__MSL_PACKED(short)
__MSL_PACKED(ushort)
__MSL_PACKED(int)
__MSL_PACKED(uint)
__MSL_PACKED(long)
__MSL_PACKED(ulong)
__MSL_PACKED(half)
__MSL_PACKED(float)
#undef __MSL_PACKED
#undef __MSL_PACKED_COMMON
#undef __MSL_PACKED_OPS
#undef __MSL_PACKED_TRAITS

// ---------------------------------------------------------------------------
// bool vectors
// ---------------------------------------------------------------------------
struct bool2 {
    bool x, y;
    constexpr bool2() : x(false), y(false) {}
    constexpr bool2(bool a) : x(a), y(a) {}
    constexpr bool2(bool a, bool b) : x(a), y(b) {}
    template <class V, __msl::en<(!__msl::is_scalar_v<V> && __msl::ncomp_v<V> == 2 &&
                                  !__msl::is_same<V, bool2>::value)> = 0>
    bool2(const V& v) : x(v.x != 0), y(v.y != 0) {}
};
struct bool3 {
    bool x, y, z;
    constexpr bool3() : x(false), y(false), z(false) {}
    constexpr bool3(bool a) : x(a), y(a), z(a) {}
    constexpr bool3(bool a, bool b, bool c) : x(a), y(b), z(c) {}
    template <class V, __msl::en<(!__msl::is_scalar_v<V> && __msl::ncomp_v<V> == 3 &&
                                  !__msl::is_same<V, bool3>::value)> = 0>
    bool3(const V& v) : x(v.x != 0), y(v.y != 0), z(v.z != 0) {}
};
struct bool4 {
    bool x, y, z, w;
    constexpr bool4() : x(false), y(false), z(false), w(false) {}
    constexpr bool4(bool a) : x(a), y(a), z(a), w(a) {}
    constexpr bool4(bool a, bool b, bool c, bool d) : x(a), y(b), z(c), w(d) {}
    template <class V, __msl::en<(!__msl::is_scalar_v<V> && __msl::ncomp_v<V> == 4 &&
                                  !__msl::is_same<V, bool4>::value)> = 0>
    bool4(const V& v) : x(v.x != 0), y(v.y != 0), z(v.z != 0), w(v.w != 0) {}
};
namespace __msl {
__MSL_NCOMP(bool2, 2)
__MSL_NCOMP(bool3, 3)
__MSL_NCOMP(bool4, 4)
__MSL_ELEM(bool2, bool)
__MSL_ELEM(bool3, bool)
__MSL_ELEM(bool4, bool)
}
#define __MSL_BOOLVEC_OPS(BV)                                             \
    BV operator!(const BV& a);                                  \
    BV operator&&(const BV& a, const BV& b);                    \
    BV operator||(const BV& a, const BV& b);                    \
    BV operator&(const BV& a, const BV& b);                     \
    BV operator|(const BV& a, const BV& b);                     \
    BV operator^(const BV& a, const BV& b);                     \
    BV operator==(const BV& a, const BV& b);                    \
    BV operator!=(const BV& a, const BV& b);
__MSL_BOOLVEC_OPS(bool2)
__MSL_BOOLVEC_OPS(bool3)
__MSL_BOOLVEC_OPS(bool4)
#undef __MSL_BOOLVEC_OPS

// ---------------------------------------------------------------------------
// Function-style constructor macros. From here on, header code must not use
// 'float4(' style construction; use braces (float4{...}) instead.
// ---------------------------------------------------------------------------
#define char2(...) __msl_make_char2(__VA_ARGS__)
#define char3(...) __msl_make_char3(__VA_ARGS__)
#define char4(...) __msl_make_char4(__VA_ARGS__)
#define uchar2(...) __msl_make_uchar2(__VA_ARGS__)
#define uchar3(...) __msl_make_uchar3(__VA_ARGS__)
#define uchar4(...) __msl_make_uchar4(__VA_ARGS__)
#define short2(...) __msl_make_short2(__VA_ARGS__)
#define short3(...) __msl_make_short3(__VA_ARGS__)
#define short4(...) __msl_make_short4(__VA_ARGS__)
#define ushort2(...) __msl_make_ushort2(__VA_ARGS__)
#define ushort3(...) __msl_make_ushort3(__VA_ARGS__)
#define ushort4(...) __msl_make_ushort4(__VA_ARGS__)
#define int2(...) __msl_make_int2(__VA_ARGS__)
#define int3(...) __msl_make_int3(__VA_ARGS__)
#define int4(...) __msl_make_int4(__VA_ARGS__)
#define uint2(...) __msl_make_uint2(__VA_ARGS__)
#define uint3(...) __msl_make_uint3(__VA_ARGS__)
#define uint4(...) __msl_make_uint4(__VA_ARGS__)
#define long2(...) __msl_make_long2(__VA_ARGS__)
#define long3(...) __msl_make_long3(__VA_ARGS__)
#define long4(...) __msl_make_long4(__VA_ARGS__)
#define ulong2(...) __msl_make_ulong2(__VA_ARGS__)
#define ulong3(...) __msl_make_ulong3(__VA_ARGS__)
#define ulong4(...) __msl_make_ulong4(__VA_ARGS__)
#define half2(...) __msl_make_half2(__VA_ARGS__)
#define half3(...) __msl_make_half3(__VA_ARGS__)
#define half4(...) __msl_make_half4(__VA_ARGS__)
#define float2(...) __msl_make_float2(__VA_ARGS__)
#define float3(...) __msl_make_float3(__VA_ARGS__)
#define float4(...) __msl_make_float4(__VA_ARGS__)

// ---------------------------------------------------------------------------
// half literals: 1.0h, 2h
// ---------------------------------------------------------------------------
constexpr half operator""h(long double v) { return (half)v; }
constexpr half operator""h(unsigned long long v) { return (half)v; }

// ---------------------------------------------------------------------------
// as_type<T>(x): bit reinterpretation between same-size types
// ---------------------------------------------------------------------------
namespace metal {
template <class To, class From>
To as_type(From f) {
    static_assert(sizeof(To) == sizeof(From), "as_type<T>(x): T and the type of x must have the same size");
    To r;
    __builtin_memcpy(&r, &f, sizeof(To));
    return r;
}
} // namespace metal

// ---------------------------------------------------------------------------
// Numeric constants (macros, as in <metal_math> / <metal_limits>)
// ---------------------------------------------------------------------------
#define INFINITY __builtin_inff()
#define NAN __builtin_nanf("")
#define HUGE_VALF __builtin_huge_valf()
#define HUGE_VALH ((half)__builtin_huge_valf())
#define MAXFLOAT 0x1.fffffep+127f
#define MAXHALF 65504.0h
#define FLT_DIG 6
#define FLT_MANT_DIG 24
#define FLT_MAX_10_EXP +38
#define FLT_MAX_EXP +128
#define FLT_MIN_10_EXP -37
#define FLT_MIN_EXP -125
#define FLT_RADIX 2
#define FLT_MAX MAXFLOAT
#define FLT_MIN 0x1.0p-126f
#define FLT_EPSILON 0x1.0p-23f
#define FLT_TRUE_MIN 0x1.0p-149f
#define HALF_DIG 3
#define HALF_MANT_DIG 11
#define HALF_MAX_10_EXP +4
#define HALF_MAX_EXP +16
#define HALF_MIN_10_EXP -4
#define HALF_MIN_EXP -13
#define HALF_RADIX 2
#define HALF_MAX MAXHALF
#define HALF_MIN 6.103515625e-05h
#define HALF_EPSILON 9.765625e-04h
#define HALF_TRUE_MIN 5.9604644775390625e-08h
#define M_E_F 2.71828182845904523536028747135266250f
#define M_LOG2E_F 1.44269504088896340735992468100189214f
#define M_LOG10E_F 0.434294481903251827651128918916605082f
#define M_LN2_F 0.693147180559945309417232121458176568f
#define M_LN10_F 2.30258509299404568401799145468436421f
#define M_PI_F 3.14159265358979323846264338327950288f
#define M_PI_2_F 1.57079632679489661923132169163975144f
#define M_PI_4_F 0.785398163397448309615660845819875721f
#define M_1_PI_F 0.318309886183790671537767526745028724f
#define M_2_PI_F 0.636619772367581343075535053490057448f
#define M_2_SQRTPI_F 1.12837916709551257389615890312154517f
#define M_SQRT2_F 1.41421356237309504880168872420969808f
#define M_SQRT1_2_F 0.707106781186547524400844362104849039f
#define M_E_H 2.71828182845904523536028747135266250h
#define M_LOG2E_H 1.44269504088896340735992468100189214h
#define M_LOG10E_H 0.434294481903251827651128918916605082h
#define M_LN2_H 0.693147180559945309417232121458176568h
#define M_LN10_H 2.30258509299404568401799145468436421h
#define M_PI_H 3.14159265358979323846264338327950288h
#define M_PI_2_H 1.57079632679489661923132169163975144h
#define M_PI_4_H 0.785398163397448309615660845819875721h
#define M_1_PI_H 0.318309886183790671537767526745028724h
#define M_2_PI_H 0.636619772367581343075535053490057448h
#define M_2_SQRTPI_H 1.12837916709551257389615890312154517h
#define M_SQRT2_H 1.41421356237309504880168872420969808h
#define M_SQRT1_2_H 0.707106781186547524400844362104849039h
#define CHAR_BIT 8
#define SCHAR_MAX 127
#define SCHAR_MIN (-128)
#define UCHAR_MAX 255
#define CHAR_MAX SCHAR_MAX
#define CHAR_MIN SCHAR_MIN
#define USHRT_MAX 65535
#define SHRT_MAX 32767
#define SHRT_MIN (-32768)
#define UINT_MAX 0xffffffffU
#define INT_MAX 2147483647
#define INT_MIN (-2147483647 - 1)
#define ULONG_MAX 0xffffffffffffffffUL
#define LONG_MAX 0x7fffffffffffffffL
#define LONG_MIN (-0x7fffffffffffffffL - 1)

#endif // __MSL_TYPES_H
