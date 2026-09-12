// metal-lint stub: <metal_raytracing> -- metal::raytracing.
// intersection_result carries the union of all tag-dependent members
// (the linter does not model which tags enable which fields).
#ifndef __MSL_RAYTRACING_H
#define __MSL_RAYTRACING_H

#include "types.h"
#include "matrix.h"

namespace metal {
namespace raytracing {

// ---- tags ---------------------------------------------------------------------
struct triangle_data {};
struct instancing {};
struct world_space_data {};
struct primitive_motion {};
struct instance_motion {};
struct curve_data {};
struct extended_limits {};
struct user_instance_id {};
struct intersection_function_buffer {};
template <int N> struct max_levels {};

// ---- enums --------------------------------------------------------------------
enum class intersection_type { none = 0, triangle = 1, bounding_box = 2, curve = 4 };
enum class geometry_type { none = 0, triangle = 1, bounding_box = 2, curve = 4, all = 7 };
enum class forced_opacity { none, opaque, non_opaque };
enum class triangle_cull_mode { none, front, back };
enum class opacity_cull_mode { none, opaque, non_opaque };
enum class geometry_cull_mode { none = 0, triangle = 1, bounding_box = 2, curve = 4 };
enum class instance_options { none = 0, disable_triangle_culling = 1, triangle_front_facing_winding_counter_clockwise = 2, opaque = 4, non_opaque = 8 };
enum class curve_type { round, flat };
enum class curve_basis { bspline, catmull_rom, linear, bezier };
constexpr geometry_type operator|(geometry_type a, geometry_type b) { return (geometry_type)((int)a | (int)b); }
constexpr geometry_type operator&(geometry_type a, geometry_type b) { return (geometry_type)((int)a & (int)b); }
constexpr intersection_type operator|(intersection_type a, intersection_type b) { return (intersection_type)((int)a | (int)b); }
constexpr intersection_type operator&(intersection_type a, intersection_type b) { return (intersection_type)((int)a & (int)b); }

// ---- ray ------------------------------------------------------------------
struct ray {
    float3 origin;
    float3 direction;
    float min_distance;
    float max_distance;
    ray() : origin{0, 0, 0}, direction{0, 0, 1}, min_distance(0.0f), max_distance(__builtin_inff()) {}
    ray(float3 o, float3 d, float min_d = 0.0f, float max_d = __builtin_inff())
        : origin(o), direction(d), min_distance(min_d), max_distance(max_d) {}
};

// ---- acceleration structures ---------------------------------------------------
template <class... Tags> struct acceleration_structure {};
typedef acceleration_structure<> primitive_acceleration_structure;
typedef acceleration_structure<instancing> instance_acceleration_structure;

template <class... Tags> struct intersection_function_table {};

// ---- results ------------------------------------------------------------------
template <class... Tags>
struct intersection_result {
    intersection_type type;
    float distance;
    uint primitive_id;
    uint geometry_id;
    uint instance_id;
    uint user_instance_id;
    uint instance_count;
    float2 triangle_barycentric_coord;
    bool triangle_front_facing;
    float curve_parameter;
    float4x3 object_to_world_transform;
    float4x3 world_to_object_transform;
    uint instance_ids[16];
};

// ---- intersector ----------------------------------------------------------------
template <class... Tags>
struct intersector {
    typedef intersection_result<Tags...> result;
    intersector() = default;
    void accept_any_intersection(bool);
    void assume_geometry_type(geometry_type);
    void force_opacity(forced_opacity);
    void set_triangle_cull_mode(triangle_cull_mode);
    void set_opacity_cull_mode(opacity_cull_mode);
    void set_geometry_cull_mode(geometry_cull_mode);
    void assume_identity_transforms(bool);
    void assume_curve_type(curve_type);
    void assume_curve_basis(curve_basis);
    void assume_curve_control_point_count(uint);
    void set_curve_type(curve_type);
    void set_curve_basis(curve_basis);
    // intersect(ray, accel [, mask] [, function_table] [, payload]) --
    // extra arguments are not validated.
    template <class... As, class... Rest>
    result intersect(ray r, acceleration_structure<As...> accel, Rest... rest) const;
};

// ---- intersection_query (Metal 3+) ------------------------------------------------
template <class... Tags>
struct intersection_query {
    intersection_query() = default;
    template <class... As>
    intersection_query(ray r, acceleration_structure<As...> accel, uint mask = ~0u);
    template <class... As>
    void reset(ray r, acceleration_structure<As...> accel, uint mask = ~0u);
    template <class... As, class... Rest>
    void reset(ray r, acceleration_structure<As...> accel, uint mask, Rest...);
    bool next();
    void abort();
    void commit_triangle_intersection();
    void commit_bounding_box_intersection(float distance);
    intersection_type get_committed_intersection_type() const;
    intersection_type get_candidate_intersection_type() const;
    float get_committed_distance() const;
    float get_candidate_triangle_distance() const;
    uint get_committed_primitive_id() const;
    uint get_candidate_primitive_id() const;
    uint get_committed_geometry_id() const;
    uint get_candidate_geometry_id() const;
    uint get_committed_instance_id() const;
    uint get_candidate_instance_id() const;
    uint get_committed_user_instance_id() const;
    uint get_candidate_user_instance_id() const;
    float2 get_committed_triangle_barycentric_coord() const;
    float2 get_candidate_triangle_barycentric_coord() const;
    bool get_committed_triangle_front_facing() const;
    bool get_candidate_triangle_front_facing() const;
    bool is_candidate_non_opaque_bounding_box() const;
    float4x3 get_committed_object_to_world_transform() const;
    float4x3 get_candidate_object_to_world_transform() const;
    float4x3 get_committed_world_to_object_transform() const;
    float4x3 get_candidate_world_to_object_transform() const;
    ray get_world_space_ray() const;
    float3 get_candidate_object_space_ray_origin() const;
    float3 get_candidate_object_space_ray_direction() const;
};

} // namespace raytracing
} // namespace metal

#endif // __MSL_RAYTRACING_H
