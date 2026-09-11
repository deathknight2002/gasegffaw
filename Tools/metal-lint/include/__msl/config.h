// metal-lint stub: language configuration (keywords, address spaces, feature macros).
// This is NOT the real Metal Standard Library. It only exists so that clang++
// -fsyntax-only can type-check .metal sources on Linux. See ../../README.md.
#ifndef __MSL_CONFIG_H
#define __MSL_CONFIG_H

#if !defined(__clang__)
#error "metal-lint stub headers require clang (ext_vector_type, _Float16)"
#endif

// The stub uses a user-defined literal named "h" (the MSL half suffix), which
// clang flags as reserved. Silence that for the whole translation unit.
#pragma clang diagnostic ignored "-Wuser-defined-literals"
// "constant const T" (legal MSL) expands to "const const T".
#pragma clang diagnostic ignored "-Wduplicate-decl-specifier"

#ifndef __METAL_VERSION__
#define __METAL_VERSION__ 320
#endif
#ifndef __METAL__
#define __METAL__ 1
#endif
#ifndef METAL_LINT
#define METAL_LINT 1
#endif
#if !defined(__METAL_MACOS__) && !defined(__METAL_IOS__)
#define __METAL_MACOS__ 1
#endif
#ifndef __HAVE_RAYTRACING__
#define __HAVE_RAYTRACING__ 1
#endif

// ---- Function qualifiers -> no-ops ----------------------------------------
// These are reserved words in MSL, so they can never collide with user
// identifiers. Note: [[kernel]] / [[vertex]] / [[fragment]] / [[visible]] in
// attribute position expand to [[]], which is a valid empty attribute list.
#define kernel
#define vertex
#define fragment
#define visible

// ---- Address space qualifiers ---------------------------------------------
// 'constant' maps to 'const' so writes through constant references/pointers are
// diagnosed. Uninitialised namespace-scope function constants
// ('constant bool X [[function_constant(0)]];') are made legal C++ by lint.sh,
// which appends '= {}' to such lines before compiling.
#define constant const
#define device
#define threadgroup
#define threadgroup_imageblock
#define thread
#define ray_data
#define object_data

#endif // __MSL_CONFIG_H
