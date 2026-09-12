// metal-lint stub: <metal_atomic>.
#ifndef __MSL_ATOMIC_H
#define __MSL_ATOMIC_H

#include "types.h"

namespace metal {

enum memory_order { memory_order_relaxed = 0 };
enum thread_scope { thread_scope_thread, thread_scope_simdgroup, thread_scope_threadgroup, thread_scope_device, thread_scope_system };

// MSL atomics are non-copyable objects that live in device or threadgroup
// memory; they are only accessed through the atomic_* functions below.
template <class T>
struct atomic {
    T __value;
    atomic() = default;
    constexpr atomic(T v) : __value(v) {}
    atomic(const atomic&) = delete;
    atomic& operator=(const atomic&) = delete;
};
typedef atomic<int> atomic_int;
typedef atomic<uint> atomic_uint;
typedef atomic<bool> atomic_bool;
typedef atomic<float> atomic_float;
typedef atomic<long> atomic_long;
typedef atomic<ulong> atomic_ulong;

// The 'operand' parameters are non-deduced (id_t) so that
// atomic_fetch_add_explicit(&counter_uint, 1, memory_order_relaxed) works.
template <class T> void atomic_store_explicit(volatile atomic<T>* obj, __msl::id_t<T> desired, memory_order);
template <class T> T atomic_load_explicit(const volatile atomic<T>* obj, memory_order);
template <class T> T atomic_exchange_explicit(volatile atomic<T>* obj, __msl::id_t<T> desired, memory_order);
template <class T> bool atomic_compare_exchange_weak_explicit(volatile atomic<T>* obj, thread T* expected,
                                                              __msl::id_t<T> desired, memory_order success,
                                                              memory_order failure);
template <class T> T atomic_fetch_add_explicit(volatile atomic<T>* obj, __msl::id_t<T> operand, memory_order);
template <class T> T atomic_fetch_sub_explicit(volatile atomic<T>* obj, __msl::id_t<T> operand, memory_order);
template <class T> T atomic_fetch_and_explicit(volatile atomic<T>* obj, __msl::id_t<T> operand, memory_order);
template <class T> T atomic_fetch_or_explicit(volatile atomic<T>* obj, __msl::id_t<T> operand, memory_order);
template <class T> T atomic_fetch_xor_explicit(volatile atomic<T>* obj, __msl::id_t<T> operand, memory_order);
template <class T> T atomic_fetch_min_explicit(volatile atomic<T>* obj, __msl::id_t<T> operand, memory_order);
template <class T> T atomic_fetch_max_explicit(volatile atomic<T>* obj, __msl::id_t<T> operand, memory_order);

// Metal 3.1+ non-explicit spellings (relaxed by definition).
template <class T> void atomic_store(volatile atomic<T>* obj, __msl::id_t<T> desired);
template <class T> T atomic_load(const volatile atomic<T>* obj);
template <class T> T atomic_fetch_add(volatile atomic<T>* obj, __msl::id_t<T> operand);
template <class T> T atomic_fetch_sub(volatile atomic<T>* obj, __msl::id_t<T> operand);
template <class T> T atomic_fetch_min(volatile atomic<T>* obj, __msl::id_t<T> operand);
template <class T> T atomic_fetch_max(volatile atomic<T>* obj, __msl::id_t<T> operand);

} // namespace metal

#endif // __MSL_ATOMIC_H
