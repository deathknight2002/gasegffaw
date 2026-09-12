// metal-lint stub: <metal_texture> -- samplers, sample options, texture types.
#ifndef __MSL_TEXTURE_H
#define __MSL_TEXTURE_H

#include "types.h"

namespace metal {

enum class access { sample = 0, read = 1, write = 2, read_write = 3 };

// ---- sampler state enums --------------------------------------------------
enum class coord { normalized, pixel };
enum class filter { nearest, linear, bicubic };
enum class min_filter { nearest, linear };
enum class mag_filter { nearest, linear, bicubic };
enum class mip_filter { none, nearest, linear };
enum class address { clamp_to_zero, clamp_to_edge, repeat, mirrored_repeat, clamp_to_border };
enum class s_address { clamp_to_zero, clamp_to_edge, repeat, mirrored_repeat, clamp_to_border };
enum class t_address { clamp_to_zero, clamp_to_edge, repeat, mirrored_repeat, clamp_to_border };
enum class r_address { clamp_to_zero, clamp_to_edge, repeat, mirrored_repeat, clamp_to_border };
enum class border_color { transparent_black, opaque_black, opaque_white };
enum class compare_func { none, less, less_equal, greater, greater_equal, equal, not_equal, always, never };
enum class reduction { weighted_average, minimum, maximum };
struct max_anisotropy { constexpr explicit max_anisotropy(int) {} };
struct lod_clamp { constexpr lod_clamp(float, float) {} };

struct sampler {
    constexpr sampler() {}
    template <class... Args> constexpr sampler(Args...) {}
};

// ---- sample() options -----------------------------------------------------
struct level { constexpr explicit level(float) {} };
struct bias { constexpr explicit bias(float) {} };
struct min_lod_clamp { constexpr explicit min_lod_clamp(float) {} };
struct gradient2d { constexpr gradient2d(float2, float2) {} };
struct gradient3d { constexpr gradient3d(float3, float3) {} };
struct gradientcube { constexpr gradientcube(float3, float3) {} };
enum class component { x, y, z, w };

// ---- shared method sets (macros keep the 20-odd texture types in sync) -----
// A = access; methods are SFINAE-gated so that e.g. write() on an
// access::sample texture and sample() on access::read are errors, as in MSL.
#define __MSL_TEX_QUERY_COMMON                                                    \
    template <access AA = A, __msl::en<(AA != access::write)> = 0>                \
    uint get_num_mip_levels() const;                                              \
    uint get_width(uint lod = 0) const;

#define __MSL_TEX_SAMPLE(COORD)                                                   \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    __msl::vec<T, 4> sample(sampler, COORD, Opts...) const;                       \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    __msl::vec<T, 4> gather(sampler, COORD, Opts...) const;
#define __MSL_TEX_SAMPLE_ARRAY(COORD)                                             \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    __msl::vec<T, 4> sample(sampler, COORD, uint array, Opts...) const;           \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    __msl::vec<T, 4> gather(sampler, COORD, uint array, Opts...) const;
#define __MSL_TEX_READ(UC, SC)                                                    \
    template <access AA = A, __msl::en<(AA != access::write)> = 0>                \
    __msl::vec<T, 4> read(UC coord, uint lod = 0) const;                          \
    template <access AA = A, __msl::en<(AA != access::write)> = 0>                \
    __msl::vec<T, 4> read(SC coord, ushort lod = 0) const;
#define __MSL_TEX_READ_ARRAY(UC, SC)                                              \
    template <access AA = A, __msl::en<(AA != access::write)> = 0>                \
    __msl::vec<T, 4> read(UC coord, uint array, uint lod = 0) const;              \
    template <access AA = A, __msl::en<(AA != access::write)> = 0>                \
    __msl::vec<T, 4> read(SC coord, ushort array, ushort lod = 0) const;
#define __MSL_TEX_WRITE(UC, SC)                                                   \
    template <access AA = A, __msl::en<(AA == access::write || AA == access::read_write)> = 0> \
    void write(__msl::vec<T, 4> color, UC coord, uint lod = 0);                   \
    template <access AA = A, __msl::en<(AA == access::write || AA == access::read_write)> = 0> \
    void write(__msl::vec<T, 4> color, SC coord, ushort lod = 0);
#define __MSL_TEX_WRITE_ARRAY(UC, SC)                                             \
    template <access AA = A, __msl::en<(AA == access::write || AA == access::read_write)> = 0> \
    void write(__msl::vec<T, 4> color, UC coord, uint array, uint lod = 0);       \
    template <access AA = A, __msl::en<(AA == access::write || AA == access::read_write)> = 0> \
    void write(__msl::vec<T, 4> color, SC coord, ushort array, ushort lod = 0);
#define __MSL_TEX_FENCE                                                           \
    template <access AA = A, __msl::en<(AA == access::read_write)> = 0>           \
    void fence();

// ---- colour textures --------------------------------------------------------
template <class T, access A = access::sample>
struct texture1d {
    __MSL_TEX_SAMPLE(float)
    __MSL_TEX_READ(uint, ushort)
    __MSL_TEX_WRITE(uint, ushort)
    __MSL_TEX_QUERY_COMMON
    __MSL_TEX_FENCE
};
template <class T, access A = access::sample>
struct texture1d_array {
    __MSL_TEX_SAMPLE_ARRAY(float)
    __MSL_TEX_READ_ARRAY(uint, ushort)
    __MSL_TEX_WRITE_ARRAY(uint, ushort)
    __MSL_TEX_QUERY_COMMON
    __MSL_TEX_FENCE
    uint get_array_size() const;
};
template <class T, access A = access::sample>
struct texture2d {
    __MSL_TEX_SAMPLE(float2)
    __MSL_TEX_READ(uint2, ushort2)
    __MSL_TEX_WRITE(uint2, ushort2)
    __MSL_TEX_QUERY_COMMON
    __MSL_TEX_FENCE
    uint get_height(uint lod = 0) const;
};
template <class T, access A = access::sample>
struct texture2d_array {
    __MSL_TEX_SAMPLE_ARRAY(float2)
    __MSL_TEX_READ_ARRAY(uint2, ushort2)
    __MSL_TEX_WRITE_ARRAY(uint2, ushort2)
    __MSL_TEX_QUERY_COMMON
    __MSL_TEX_FENCE
    uint get_height(uint lod = 0) const;
    uint get_array_size() const;
};
template <class T, access A = access::sample>
struct texture3d {
    __MSL_TEX_SAMPLE(float3)
    __MSL_TEX_READ(uint3, ushort3)
    __MSL_TEX_WRITE(uint3, ushort3)
    __MSL_TEX_QUERY_COMMON
    __MSL_TEX_FENCE
    uint get_height(uint lod = 0) const;
    uint get_depth(uint lod = 0) const;
};
template <class T, access A = access::sample>
struct texturecube {
    __MSL_TEX_SAMPLE(float3)
    __MSL_TEX_READ_ARRAY(uint2, ushort2)   // read(coord, face, lod)
    __MSL_TEX_WRITE_ARRAY(uint2, ushort2)  // write(color, coord, face, lod)
    __MSL_TEX_QUERY_COMMON
    __MSL_TEX_FENCE
    uint get_height(uint lod = 0) const;
};
template <class T, access A = access::sample>
struct texturecube_array {
    __MSL_TEX_SAMPLE_ARRAY(float3)
    __MSL_TEX_QUERY_COMMON
    template <access AA = A, __msl::en<(AA != access::write)> = 0>
    __msl::vec<T, 4> read(uint2 coord, uint face, uint array, uint lod = 0) const;
    template <access AA = A, __msl::en<(AA == access::write || AA == access::read_write)> = 0>
    void write(__msl::vec<T, 4> color, uint2 coord, uint face, uint array, uint lod = 0);
    uint get_height(uint lod = 0) const;
    uint get_array_size() const;
};
template <class T, access A = access::read>
struct texture2d_ms {
    template <access AA = A, __msl::en<(AA != access::write)> = 0>
    __msl::vec<T, 4> read(uint2 coord, uint sample) const;
    template <access AA = A, __msl::en<(AA != access::write)> = 0>
    __msl::vec<T, 4> read(ushort2 coord, ushort sample) const;
    uint get_width() const;
    uint get_height() const;
    uint get_num_samples() const;
};
template <class T, access A = access::read>
struct texture2d_ms_array {
    template <access AA = A, __msl::en<(AA != access::write)> = 0>
    __msl::vec<T, 4> read(uint2 coord, uint array, uint sample) const;
    uint get_width() const;
    uint get_height() const;
    uint get_num_samples() const;
    uint get_array_size() const;
};
template <class T, access A = access::read>
struct texture_buffer {
    template <access AA = A, __msl::en<(AA != access::write)> = 0>
    __msl::vec<T, 4> read(uint coord) const;
    template <access AA = A, __msl::en<(AA == access::write || AA == access::read_write)> = 0>
    void write(__msl::vec<T, 4> color, uint coord);
    uint get_width() const;
};

// ---- depth textures ----------------------------------------------------------
#define __MSL_DEPTH_SAMPLE(COORD)                                                 \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    T sample(sampler, COORD, Opts...) const;                                      \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    T sample_compare(sampler, COORD, T compare_value, Opts...) const;             \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    __msl::vec<T, 4> gather(sampler, COORD, Opts...) const;                       \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    __msl::vec<T, 4> gather_compare(sampler, COORD, T compare_value, Opts...) const;
#define __MSL_DEPTH_SAMPLE_ARRAY(COORD)                                           \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    T sample(sampler, COORD, uint array, Opts...) const;                          \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    T sample_compare(sampler, COORD, uint array, T compare_value, Opts...) const; \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    __msl::vec<T, 4> gather(sampler, COORD, uint array, Opts...) const;           \
    template <class... Opts, access AA = A, __msl::en<(AA == access::sample)> = 0> \
    __msl::vec<T, 4> gather_compare(sampler, COORD, uint array, T compare_value, Opts...) const;

template <class T, access A = access::sample>
struct depth2d {
    __MSL_DEPTH_SAMPLE(float2)
    template <access AA = A, __msl::en<(AA != access::write)> = 0>
    T read(uint2 coord, uint lod = 0) const;
    template <access AA = A, __msl::en<(AA != access::write)> = 0>
    T read(ushort2 coord, ushort lod = 0) const;
    __MSL_TEX_QUERY_COMMON
    uint get_height(uint lod = 0) const;
};
template <class T, access A = access::sample>
struct depth2d_array {
    __MSL_DEPTH_SAMPLE_ARRAY(float2)
    template <access AA = A, __msl::en<(AA != access::write)> = 0>
    T read(uint2 coord, uint array, uint lod = 0) const;
    __MSL_TEX_QUERY_COMMON
    uint get_height(uint lod = 0) const;
    uint get_array_size() const;
};
template <class T, access A = access::sample>
struct depthcube {
    __MSL_DEPTH_SAMPLE(float3)
    template <access AA = A, __msl::en<(AA != access::write)> = 0>
    T read(uint2 coord, uint face, uint lod = 0) const;
    __MSL_TEX_QUERY_COMMON
    uint get_height(uint lod = 0) const;
};
template <class T, access A = access::sample>
struct depthcube_array {
    __MSL_DEPTH_SAMPLE_ARRAY(float3)
    __MSL_TEX_QUERY_COMMON
    uint get_height(uint lod = 0) const;
    uint get_array_size() const;
};
template <class T, access A = access::read>
struct depth2d_ms {
    T read(uint2 coord, uint sample) const;
    uint get_width() const;
    uint get_height() const;
    uint get_num_samples() const;
};

#undef __MSL_TEX_QUERY_COMMON
#undef __MSL_TEX_SAMPLE
#undef __MSL_TEX_SAMPLE_ARRAY
#undef __MSL_TEX_READ
#undef __MSL_TEX_READ_ARRAY
#undef __MSL_TEX_WRITE
#undef __MSL_TEX_WRITE_ARRAY
#undef __MSL_TEX_FENCE
#undef __MSL_DEPTH_SAMPLE
#undef __MSL_DEPTH_SAMPLE_ARRAY

// ---- imageblocks (minimal) -------------------------------------------------
template <class T> struct imageblock_data_rate {};
template <class T, class Layout = void> struct imageblock {
    T read(ushort2 coord) const;
    void write(T data, ushort2 coord);
    ushort get_width() const;
    ushort get_height() const;
};

} // namespace metal

#endif // __MSL_TEXTURE_H
