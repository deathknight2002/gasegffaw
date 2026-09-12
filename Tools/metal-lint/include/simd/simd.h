// metal-lint stub for <simd/simd.h> as seen from Metal: the simd_* / vector_* /
// matrix_* spellings alias the MSL builtin types, so a ShaderTypes.h shared
// with Swift/ObjC type-checks the same way it does under the Metal compiler.
#ifndef __MSL_SIMD_SIMD_H
#define __MSL_SIMD_SIMD_H
#include "../metal_stdlib"

#define __MSL_SIMD_ALIAS(T)                                                     \
    typedef T##2 simd_##T##2; typedef T##3 simd_##T##3; typedef T##4 simd_##T##4; \
    typedef T##2 vector_##T##2; typedef T##3 vector_##T##3; typedef T##4 vector_##T##4; \
    typedef packed_##T##2 simd_packed_##T##2; typedef packed_##T##3 simd_packed_##T##3; \
    typedef packed_##T##4 simd_packed_##T##4;
__MSL_SIMD_ALIAS(char)
__MSL_SIMD_ALIAS(uchar)
__MSL_SIMD_ALIAS(short)
__MSL_SIMD_ALIAS(ushort)
__MSL_SIMD_ALIAS(int)
__MSL_SIMD_ALIAS(uint)
__MSL_SIMD_ALIAS(long)
__MSL_SIMD_ALIAS(ulong)
__MSL_SIMD_ALIAS(half)
__MSL_SIMD_ALIAS(float)
#undef __MSL_SIMD_ALIAS
typedef float simd_float1; typedef half simd_half1; typedef int simd_int1; typedef uint simd_uint1;
typedef bool2 simd_bool2; typedef bool3 simd_bool3; typedef bool4 simd_bool4;

#define __MSL_SIMD_MAT(T)                                                       \
    typedef metal::T##2x2 simd_##T##2x2; typedef metal::T##2x3 simd_##T##2x3;   \
    typedef metal::T##2x4 simd_##T##2x4; typedef metal::T##3x2 simd_##T##3x2;   \
    typedef metal::T##3x3 simd_##T##3x3; typedef metal::T##3x4 simd_##T##3x4;   \
    typedef metal::T##4x2 simd_##T##4x2; typedef metal::T##4x3 simd_##T##4x3;   \
    typedef metal::T##4x4 simd_##T##4x4;                                        \
    typedef metal::T##2x2 matrix_##T##2x2; typedef metal::T##2x3 matrix_##T##2x3; \
    typedef metal::T##2x4 matrix_##T##2x4; typedef metal::T##3x2 matrix_##T##3x2; \
    typedef metal::T##3x3 matrix_##T##3x3; typedef metal::T##3x4 matrix_##T##3x4; \
    typedef metal::T##4x2 matrix_##T##4x2; typedef metal::T##4x3 matrix_##T##4x3; \
    typedef metal::T##4x4 matrix_##T##4x4;
__MSL_SIMD_MAT(float)
__MSL_SIMD_MAT(half)
#undef __MSL_SIMD_MAT

namespace simd {
using ::float2; using ::float3; using ::float4; using ::half2; using ::half3; using ::half4;
using ::int2; using ::int3; using ::int4; using ::uint2; using ::uint3; using ::uint4;
using ::short2; using ::short3; using ::short4; using ::ushort2; using ::ushort3; using ::ushort4;
using ::char2; using ::char3; using ::char4; using ::uchar2; using ::uchar3; using ::uchar4;
using ::bool2; using ::bool3; using ::bool4;
using metal::float2x2; using metal::float3x3; using metal::float4x4; using metal::float4x3;
using metal::float3x4; using metal::float2x3; using metal::float3x2; using metal::float2x4; using metal::float4x2;
using metal::half2x2; using metal::half3x3; using metal::half4x4;
typedef float float1; typedef half half1; typedef int int1; typedef uint uint1;
} // namespace simd
#endif
