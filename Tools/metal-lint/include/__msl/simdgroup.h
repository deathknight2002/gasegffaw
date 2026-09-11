// metal-lint stub: <metal_compute> / <metal_simdgroup> / <metal_simdgroup_matrix>.
#ifndef __MSL_SIMDGROUP_H
#define __MSL_SIMDGROUP_H

#include "types.h"

namespace metal {

enum class mem_flags {
    mem_none = 0,
    mem_device = 1,
    mem_threadgroup = 2,
    mem_texture = 4,
    mem_threadgroup_imageblock = 8,
    mem_object_data = 16,
};
constexpr mem_flags operator|(mem_flags a, mem_flags b) { return (mem_flags)((int)a | (int)b); }
constexpr mem_flags operator&(mem_flags a, mem_flags b) { return (mem_flags)((int)a & (int)b); }

void threadgroup_barrier(mem_flags flags);
void simdgroup_barrier(mem_flags flags);

// ---- simd-group reductions / shuffles (T = scalar or vector) --------------
struct simd_vote {
    typedef ulong vote_t;
    constexpr simd_vote() : __v(0) {}
    constexpr explicit simd_vote(vote_t v) : __v(v) {}
    explicit operator vote_t() const { return __v; }
    bool all() const;
    bool any() const;
    vote_t __v;
};

template <class T> T simd_sum(T);
template <class T> T simd_product(T);
template <class T> T simd_min(T);
template <class T> T simd_max(T);
template <class T> T simd_and(T);
template <class T> T simd_or(T);
template <class T> T simd_xor(T);
template <class T> T simd_prefix_inclusive_sum(T);
template <class T> T simd_prefix_exclusive_sum(T);
template <class T> T simd_prefix_inclusive_product(T);
template <class T> T simd_prefix_exclusive_product(T);
template <class T> T simd_broadcast(T data, ushort simd_lane_id);
template <class T> T simd_broadcast_first(T data);
template <class T> T simd_shuffle(T data, ushort simd_lane_id);
template <class T> T simd_shuffle_down(T data, ushort delta);
template <class T> T simd_shuffle_up(T data, ushort delta);
template <class T> T simd_shuffle_xor(T data, ushort mask);
template <class T> T simd_shuffle_rotate_down(T data, ushort delta);
template <class T> T simd_shuffle_rotate_up(T data, ushort delta);
template <class T> T simd_shuffle_and_fill_down(T data, T filling, ushort delta);
template <class T> T simd_shuffle_and_fill_down(T data, T filling, ushort delta, ushort modulo);
template <class T> T simd_shuffle_and_fill_up(T data, T filling, ushort delta);
template <class T> T simd_shuffle_and_fill_up(T data, T filling, ushort delta, ushort modulo);
bool simd_is_first();
bool simd_all(bool);
bool simd_any(bool);
simd_vote simd_ballot(bool);
simd_vote simd_active_threads_mask();
bool simd_is_helper_thread();

template <class T> T quad_sum(T);
template <class T> T quad_product(T);
template <class T> T quad_min(T);
template <class T> T quad_max(T);
template <class T> T quad_and(T);
template <class T> T quad_or(T);
template <class T> T quad_xor(T);
template <class T> T quad_prefix_inclusive_sum(T);
template <class T> T quad_prefix_exclusive_sum(T);
template <class T> T quad_broadcast(T data, ushort quad_lane_id);
template <class T> T quad_broadcast_first(T data);
template <class T> T quad_shuffle(T data, ushort quad_lane_id);
template <class T> T quad_shuffle_down(T data, ushort delta);
template <class T> T quad_shuffle_up(T data, ushort delta);
template <class T> T quad_shuffle_xor(T data, ushort mask);
template <class T> T quad_shuffle_rotate_down(T data, ushort delta);
template <class T> T quad_shuffle_rotate_up(T data, ushort delta);
bool quad_is_first();
bool quad_all(bool);
bool quad_any(bool);
simd_vote quad_ballot(bool);

// ---- simdgroup matrices (Apple7+) -----------------------------------------
template <class T, int Rows, int Cols>
struct simdgroup_matrix {
    T thread_elements_storage[Rows * Cols / 32 + 1];
    simdgroup_matrix() = default;
    explicit simdgroup_matrix(T value);
    thread T* thread_elements();
};
typedef simdgroup_matrix<float, 8, 8> simdgroup_float8x8;
typedef simdgroup_matrix<half, 8, 8> simdgroup_half8x8;

template <class T, int R, int C> simdgroup_matrix<T, R, C> make_filled_simdgroup_matrix(T value);
template <class T, int R, int C, class... Args>
void simdgroup_load(thread simdgroup_matrix<T, R, C>& d, const T* src, Args...);
template <class T, int R, int C, class... Args>
void simdgroup_store(thread simdgroup_matrix<T, R, C>& a, T* dst, Args...);
template <class T, int R, int C, int K>
void simdgroup_multiply(thread simdgroup_matrix<T, R, C>& d, thread simdgroup_matrix<T, R, K>& a,
                        thread simdgroup_matrix<T, K, C>& b);
template <class T, int R, int C, int K>
void simdgroup_multiply_accumulate(thread simdgroup_matrix<T, R, C>& d, thread simdgroup_matrix<T, R, K>& a,
                                   thread simdgroup_matrix<T, K, C>& b, thread simdgroup_matrix<T, R, C>& c);

// ---- visible function tables (function pointers) --------------------------
template <class F>
struct visible_function_table {
    F* operator[](uint index) const;
    uint size() const;
    bool empty() const;
};

} // namespace metal

#endif // __MSL_SIMDGROUP_H
