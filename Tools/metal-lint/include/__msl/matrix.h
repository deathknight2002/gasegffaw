// metal-lint stub: <metal_matrix>. matrix<T, Cols, Rows> is column-major:
// floatCxR has C columns of R components; m[c] is a column vector.
#ifndef __MSL_MATRIX_H
#define __MSL_MATRIX_H

#include "types.h"

namespace metal {

template <class T, int C, int R>
struct matrix {
    typedef __msl::vec<T, R> column_t;
    typedef __msl::vec<T, C> row_t;
    column_t columns[C];

    matrix() = default;
    // Diagonal matrix from a scalar: float4x4(1.0) is the identity.
    explicit matrix(T diag);
    // From C column vectors, or from C*R scalars (column-major order).
    template <class... Args, __msl::en<(sizeof...(Args) == C || sizeof...(Args) == C * R)> = 0>
    matrix(Args...);
    // Truncation / extension between sizes: float3x3(float4x4).
    template <int C2, int R2, __msl::en<(C2 != C || R2 != R)> = 0>
    explicit matrix(const matrix<T, C2, R2>&);
    // Element type conversion: half4x4(float4x4).
    template <class U, __msl::en<!__msl::is_same<U, T>::value> = 0>
    explicit matrix(const matrix<U, C, R>&);

    column_t& operator[](int i) { return columns[i]; }
    const column_t& operator[](int i) const { return columns[i]; }

    matrix& operator+=(const matrix&);
    matrix& operator-=(const matrix&);
    matrix& operator*=(__msl::id_t<T>);
    matrix& operator/=(__msl::id_t<T>);
    template <int C2, __msl::en<(C2 == C)> = 0>
    matrix& operator*=(const matrix<T, C2, C>&);
};

template <class T, int C, int R> matrix<T, C, R> operator+(const matrix<T, C, R>&, const matrix<T, C, R>&);
template <class T, int C, int R> matrix<T, C, R> operator-(const matrix<T, C, R>&, const matrix<T, C, R>&);
template <class T, int C, int R> matrix<T, C, R> operator-(const matrix<T, C, R>&);
template <class T, int C, int R> matrix<T, C, R> operator*(const matrix<T, C, R>&, __msl::id_t<T>);
template <class T, int C, int R> matrix<T, C, R> operator*(__msl::id_t<T>, const matrix<T, C, R>&);
template <class T, int C, int R> matrix<T, C, R> operator/(const matrix<T, C, R>&, __msl::id_t<T>);
// M * v (v has C components) -> R components
template <class T, int C, int R> __msl::vec<T, R> operator*(const matrix<T, C, R>&, __msl::vec<T, C>);
// v * M (v has R components) -> C components
template <class T, int C, int R> __msl::vec<T, C> operator*(__msl::vec<T, R>, const matrix<T, C, R>&);
// A(C x R) * B(C2 x C) -> (C2 x R)
template <class T, int C, int R, int C2>
matrix<T, C2, R> operator*(const matrix<T, C, R>&, const matrix<T, C2, C>&);

template <class T, int C, int R> matrix<T, R, C> transpose(const matrix<T, C, R>&);
template <class T, int N> T determinant(const matrix<T, N, N>&);

typedef matrix<float, 2, 2> float2x2;
typedef matrix<float, 2, 3> float2x3;
typedef matrix<float, 2, 4> float2x4;
typedef matrix<float, 3, 2> float3x2;
typedef matrix<float, 3, 3> float3x3;
typedef matrix<float, 3, 4> float3x4;
typedef matrix<float, 4, 2> float4x2;
typedef matrix<float, 4, 3> float4x3;
typedef matrix<float, 4, 4> float4x4;
typedef matrix<half, 2, 2> half2x2;
typedef matrix<half, 2, 3> half2x3;
typedef matrix<half, 2, 4> half2x4;
typedef matrix<half, 3, 2> half3x2;
typedef matrix<half, 3, 3> half3x3;
typedef matrix<half, 3, 4> half3x4;
typedef matrix<half, 4, 2> half4x2;
typedef matrix<half, 4, 3> half4x3;
typedef matrix<half, 4, 4> half4x4;

} // namespace metal

// MSL exposes the matrix typedefs globally as well as in metal::.
using metal::float2x2; using metal::float2x3; using metal::float2x4;
using metal::float3x2; using metal::float3x3; using metal::float3x4;
using metal::float4x2; using metal::float4x3; using metal::float4x4;
using metal::half2x2; using metal::half2x3; using metal::half2x4;
using metal::half3x2; using metal::half3x3; using metal::half3x4;
using metal::half4x2; using metal::half4x3; using metal::half4x4;

#endif // __MSL_MATRIX_H
