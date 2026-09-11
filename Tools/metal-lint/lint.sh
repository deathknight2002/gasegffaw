#!/usr/bin/env bash
# metal-lint: offline syntax/type check for Metal Shading Language (.metal)
# files on Linux, using clang++ -fsyntax-only and stub <metal_stdlib> headers.
#
# usage: Tools/metal-lint/lint.sh [file.metal ...]
#   With no arguments, lints every *.metal in BornlessRitual/Shaders/.
#   Exit status: 0 = all files clean, 1 = at least one file had errors,
#                2 = setup problem (no compiler / no input files).
#
# Environment:
#   METAL_LINT_CLANG        path to clang++ (default: search PATH, then
#                           /opt/swift/usr/bin/clang++)
#   METAL_LINT_SHADER_DIR   default shader directory / extra -I path
#   METAL_LINT_MSL_VERSION  value for __METAL_VERSION__ (default 320)
#   METAL_LINT_FLAGS        extra compiler flags (word-split)
#   METAL_LINT_QUIET=1      print only the per-file summary lines
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INCLUDE_DIR="$SCRIPT_DIR/include"
SHADER_DIR="${METAL_LINT_SHADER_DIR:-$REPO_ROOT/BornlessRitual/Shaders}"

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
    esac
done

# ---------------------------------------------------------------------------
# Locate a working clang++: $METAL_LINT_CLANG, then PATH, then the Swift
# toolchain's bundled clang.
# ---------------------------------------------------------------------------
clang_works() {
    printf 'int main() { return 0; }\n' | "$1" -x c++ -std=c++17 -fsyntax-only - >/dev/null 2>&1
}

find_clang() {
    local candidate
    if [ -n "${METAL_LINT_CLANG:-}" ]; then
        if clang_works "$METAL_LINT_CLANG"; then
            printf '%s\n' "$METAL_LINT_CLANG"
            return 0
        fi
        echo "metal-lint: METAL_LINT_CLANG='$METAL_LINT_CLANG' is not a working clang++" >&2
        return 1
    fi
    for candidate in clang++ clang++-20 clang++-19 clang++-18 clang++-17 clang++-16 clang++-15; do
        if command -v "$candidate" >/dev/null 2>&1 && clang_works "$candidate"; then
            command -v "$candidate"
            return 0
        fi
    done
    for candidate in /opt/swift/usr/bin/clang++ /usr/lib/llvm-*/bin/clang++ /usr/local/opt/llvm/bin/clang++; do
        if [ -x "$candidate" ] && clang_works "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

CXX="$(find_clang)" || {
    echo "metal-lint: no working clang++ found (install clang or set METAL_LINT_CLANG)" >&2
    exit 2
}

# ---------------------------------------------------------------------------
# Input files
# ---------------------------------------------------------------------------
FILES=()
if [ "$#" -gt 0 ]; then
    FILES=("$@")
else
    shopt -s nullglob
    FILES=("$SHADER_DIR"/*.metal)
    shopt -u nullglob
fi
if [ "${#FILES[@]}" -eq 0 ]; then
    echo "metal-lint: no .metal files found in $SHADER_DIR" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Compiler flags
# ---------------------------------------------------------------------------
FLAGS=(
    -std=c++17 -x c++ -fsyntax-only
    # MSL has no C/C++ standard library; only the stub headers are visible.
    -nostdinc -nostdinc++
    -fno-exceptions -fno-rtti
    -ferror-limit=50
    # MSL: an unsuffixed floating literal is a float, not a double.
    -Xclang -cl-single-precision-constant
    -I "$INCLUDE_DIR"
    -I "$SHADER_DIR"
    -DMETAL_LINT=1
    -D__METAL_VERSION__="${METAL_LINT_MSL_VERSION:-320}"
    -D__METAL_MACOS__=1
    -Wall
    -Wno-unknown-attributes        # [[position]], [[buffer(0)]], ...
    -Wno-unused-parameter
    -Wno-missing-braces
    -Wno-duplicate-decl-specifier  # 'constant const T' -> 'const const T'
    -Wno-user-defined-literals     # the stub's 'h' half-literal suffix
    -Wno-unused-function           # static helpers shared across files
    -Wno-elaborated-enum-base      # Xcode's NS_ENUM idiom in ShaderTypes.h (typedef enum X : int X;)
)
# shellcheck disable=SC2206
EXTRA_FLAGS=(${METAL_LINT_FLAGS:-})

# Namespace-scope function constants ('constant bool X [[function_constant(0)]];')
# are uninitialised consts, which C++ rejects. Append '= {}' to those lines only.
FUNCTION_CONSTANT_FIXUP='/^[[:space:]]*(static[[:space:]]+)?constant[[:space:]].*function_constant/ s/\]\]([[:space:]]*);/]] = {}\1;/g'

# ---------------------------------------------------------------------------
# Lint each file
# ---------------------------------------------------------------------------
TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/metal-lint.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

total=0
failed=0
for file in "${FILES[@]}"; do
    total=$((total + 1))
    if [ ! -f "$file" ]; then
        echo "FAIL $file (file not found)"
        failed=$((failed + 1))
        continue
    fi
    abs_path="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
    file_dir="$(dirname "$abs_path")"

    {
        printf '#line 1 "%s"\n' "$abs_path"
        sed -E "$FUNCTION_CONSTANT_FIXUP" "$file"
    } | "$CXX" "${FLAGS[@]}" "${EXTRA_FLAGS[@]}" -iquote "$file_dir" - >"$TMP_OUT" 2>&1
    rc=$?

    errors=$(grep -c -E '^[^ ].*:[0-9]+:[0-9]+: (fatal )?error:' "$TMP_OUT" || true)
    warnings=$(grep -c -E '^[^ ].*:[0-9]+:[0-9]+: warning:' "$TMP_OUT" || true)
    # Errors without a location (e.g. driver failures) still fail the file.
    if [ "$rc" -ne 0 ] && [ "$errors" -eq 0 ]; then
        errors=$(grep -c -E 'error:' "$TMP_OUT" || true)
        [ "$errors" -eq 0 ] && errors=1
    fi

    if [ "${METAL_LINT_QUIET:-0}" != "1" ] && [ -s "$TMP_OUT" ]; then
        cat "$TMP_OUT"
    fi
    if [ "$rc" -eq 0 ]; then
        printf 'OK   %s (%d warnings)\n' "$file" "$warnings"
    else
        printf 'FAIL %s (%d errors, %d warnings)\n' "$file" "$errors" "$warnings"
        failed=$((failed + 1))
    fi
done

if [ "$failed" -ne 0 ]; then
    echo "metal-lint: $failed of $total file(s) failed [$CXX]"
    exit 1
fi
echo "metal-lint: $total file(s) OK [$CXX]"
exit 0
