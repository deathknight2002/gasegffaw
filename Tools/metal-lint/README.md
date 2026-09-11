# metal-lint — offline Metal Shading Language linter for Linux

There is no Metal compiler on Linux. `metal-lint` gets most of the value of one
by running **`clang++ -fsyntax-only`** over `.metal` files against a **stub
`<metal_stdlib>`** written with clang extensions. It catches the mistakes that
would otherwise only surface when the project is next built on a Mac.

```
Tools/metal-lint/
├── lint.sh                 the linter (bash + clang++, nothing else)
├── include/
│   ├── metal_stdlib        stub entry point (no extension, like the real one)
│   ├── metal_raytracing    metal::raytracing stubs
│   ├── metal_*             thin aliases (metal_math, metal_atomic, ...)
│   ├── simd/simd.h         simd_float4 / vector_float3 / matrix_float4x4 aliases
│   └── __msl/              the implementation, split by area
├── selftest/
│   ├── ok.metal            ~670 lines exercising every supported construct; must pass
│   ├── bad.metal           five deliberate errors; must fail with all five reported
│   └── run.sh              asserts both
└── README.md
```

## Running

```bash
Tools/metal-lint/lint.sh                      # lint BornlessRitual/Shaders/*.metal
Tools/metal-lint/lint.sh path/to/Foo.metal    # lint specific files
Tools/metal-lint/selftest/run.sh              # self-test (run after editing the stub)
```

One summary line per file (`OK   file (N warnings)` / `FAIL file (E errors, W
warnings)`) preceded by the clang diagnostics, which point at the original
`.metal` line numbers. Exit status: `0` all clean, `1` at least one file has
errors, `2` setup problem (no compiler, no input files).

Environment variables:

| variable                 | meaning                                                             |
|--------------------------|---------------------------------------------------------------------|
| `METAL_LINT_CLANG`       | clang++ to use. Default: `clang++`/`clang++-NN` on `PATH`, then `/opt/swift/usr/bin/clang++` |
| `METAL_LINT_SHADER_DIR`  | default input directory and extra `-I` path (default `BornlessRitual/Shaders`) |
| `METAL_LINT_MSL_VERSION` | value of `__METAL_VERSION__` (default `320`)                        |
| `METAL_LINT_FLAGS`       | extra compiler flags, e.g. `-Wno-unused-variable`                   |
| `METAL_LINT_QUIET=1`     | print only the per-file summary lines                               |

Compiler invocation (see `lint.sh`): `-std=c++17 -x c++ -fsyntax-only -nostdinc
-nostdinc++ -fno-exceptions -fno-rtti -ferror-limit=50 -Xclang
-cl-single-precision-constant -I include -I <shader dir> -iquote <file dir>
-DMETAL_LINT -D__METAL_VERSION__=320 -D__METAL_MACOS__ -Wall
-Wno-unknown-attributes -Wno-unused-parameter -Wno-missing-braces
-Wno-elaborated-enum-base ...`. (`-Wno-elaborated-enum-base` keeps the Xcode
template's `NS_ENUM` idiom in `ShaderTypes.h` legal, as it is under Apple's
clang.)
Sources are piped through a tiny `sed` fix-up (see *Function constants*) with
a `#line` directive so diagnostics name the real file.

## What it catches

* Syntax errors (missing semicolons, unbalanced braces, malformed templates).
* Undeclared identifiers, misspelled MSL functions, missing `using namespace
  metal;` / `metal::` qualification, missing `#include <metal_raytracing>`.
* Most type errors: `float3 = float4`, implicit `float3 -> half3`, bad
  swizzles (`.xyzq`), wrong constructor arity (`float3(float4)` is rejected,
  as in MSL), wrong argument types/counts to `sample`/`read`/`write`,
  `texture2d::sample` with a `float3`, matrix/vector dimension mismatches,
  wrong column counts in matrix constructors, ambiguous `min/max/clamp` on
  mixed `int`/`uint`/`float`/`half` (a real Metal error too).
* Access-qualifier misuse on textures: `write()` on `access::sample`,
  `read()` on `access::write`, `sample()` on `access::read`.
* Writes through `constant` references/pointers (`constant` maps to `const`).
* Use of C++ features MSL lacks: `<cmath>`/`<cstdint>`/any host header
  (`-nostdinc`), exceptions, RTTI.
* Unsuffixed floating literals are `float`, as in MSL, so `sqrt(2.0)` and
  `v * 0.5` type-check the same way they do under Metal.
* `-Wall` warnings (unused variables, uninitialised reads, ...) are printed but
  do not fail the lint.

## What it cannot catch

* **Address-space rules.** `device`, `threadgroup`, `thread`, `ray_data`,
  `object_data` are no-ops, so passing a `threadgroup` pointer where `device`
  is required, or returning a pointer to threadgroup memory, is not diagnosed.
  Only `constant` is modelled (as `const`).
* **Resource binding validity**: duplicate `[[buffer(n)]]` indices, argument
  buffer layouts, `[[id(n)]]` conflicts, attribute arguments of the wrong
  kind, attributes on the wrong kind of declaration (attributes are parsed and
  ignored: `-Wno-unknown-attributes`).
* **Entry-point rules**: return types of vertex/fragment functions, which
  attributes a stage may use, threadgroup memory limits, `[[stage_in]]` layout
  matching a vertex descriptor.
* **Ray-tracing tag semantics**: `intersection_result` exposes the union of all
  fields (`instance_id` without `instancing`, etc. is accepted), and extra
  arguments to `intersect()` are not validated.
* **Performance**, register pressure, precision (`fast::` vs `precise::` are
  identical stubs), GPU family / feature availability.
* Actual Metal front-end differences: Apple's compiler is a different clang
  fork with MSL-specific semantic checks; anything not modelled here passes
  silently. A file that lints clean here can still fail under `xcrun metal`.

## How the stub works (design notes)

Decisions were verified empirically against clang 18 (`/usr/bin/clang++`) and
the clang bundled with the Swift 6.2 toolchain (`/opt/swift/usr/bin/clang++`).

* **Vectors are clang `ext_vector_type` typedefs.** That gives native
  `.xyzw`/`.rgba` swizzles (read and write), `v[i]`, component-wise
  arithmetic, scalar splats and comparisons. clang does *not* accept MSL's
  function-style constructors on such typedefs (`float4(1,2,3,4)` -> "excess
  elements in scalar initializer", `half4(f4)` -> "different size").
* **Constructors are function-like macros.** `#define float4(...)
  __msl_make_float4(__VA_ARGS__)` expands only when `float4` is immediately
  followed by `(`, so `float4 v;`, `texture2d<float4>`, `sizeof(float4)` and
  `static_cast<float4>(x)` are untouched. The `__msl_make_*` overload sets
  mirror MSL's constructor rules (splat, same-size explicit conversion,
  composition whose component counts add up to N). Scalar-only forms are
  `constexpr`, so `constexpr constant float3 k = float3(0, 1, 0);` works;
  forms taking vectors are declarations only (clang 18 cannot
  constant-evaluate vector element reads).
* **`half` is `_Float16`**; the `h` literal suffix (`1.0h`, `2h`) is a
  user-defined literal.
* **`bool2/3/4` are structs**, implicitly constructible from any same-size
  vector, because clang comparisons on ext vectors yield `int`/`short` vectors
  that cannot convert to clang's own bool vectors. `any`, `all`, `select`
  accept both.
* **`packed_*` are structs** with `.x/.y/.z/.w`, implicit conversion to/from
  the unpacked vector, and arithmetic operators. No swizzles on packed types.
* **Matrices are `matrix<T, Cols, Rows>` classes** with column constructors,
  scalar (diagonal) constructor, `float3x3(float4x4)` truncation,
  `half4x4(float4x4)` conversion, `m[c]`, `m[c][r]`, `M*M`, `M*v`, `v*M`,
  `transpose`, `determinant`.
* **Library functions are declarations only** (`-fsyntax-only` never needs
  bodies), with concrete overloads for float/half scalars and vectors so that
  implicit scalar->vector splats behave as in MSL.
* **Textures/samplers**: templates with SFINAE-gated `sample`/`read`/`write`
  according to the `access` parameter; `sampler` has a `constexpr` variadic
  constructor accepting the MSL sampler state enums.
* **Keywords**: `kernel`/`vertex`/`fragment`/`visible` and the address-space
  words are macros (they are reserved in MSL, so they cannot collide with user
  identifiers). `constant` -> `const`.
* **Function constants**: `constant bool X [[function_constant(0)]];` is an
  uninitialised `const` in C++. `lint.sh` appends `= {}` to namespace-scope
  lines that start with `constant` and mention `function_constant` before
  compiling. Function-constant attributes on kernel parameters are not touched.

## Known-unsupported MSL constructs

* Direct-initialisation of vectors: `float4 v(1, 2, 3, 4);` — write
  `float4 v = float4(1, 2, 3, 4);` (brace init `float4 v{1,2,3,4};` also works).
* Swizzles on `packed_*` types (`p.xy`); use `float3(p).xy`.
* `constexpr` vectors built from other vectors: `constexpr float4 k =
  float4(v3, 1.0);` (scalar-argument forms are fine). Use `constant` instead.
* Swizzles on `bool2/3/4`.
* `float3x3(m[0].xyz, ...)` works, but constructing a matrix from a mix of
  vectors and scalars is not checked precisely.
* Mesh shaders (`mesh<...>`, `[[object]]`/`[[mesh]]` payload types), indirect
  command buffers (`command_buffer`, `render_command`), tessellation patch
  types, `interpolant<T,P>`, `imageblock` layouts, `os_log`: not stubbed.
  Attributes on these are ignored, but the types will be reported as
  undeclared.
* `double` does not exist in MSL; the stub does not forbid it, but with
  `-cl-single-precision-constant` unsuffixed literals never produce one.

Extending the stub is usually a one-line declaration in the matching
`include/__msl/*.h`; re-run `selftest/run.sh` afterwards.
