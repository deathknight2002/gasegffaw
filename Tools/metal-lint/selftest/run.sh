#!/usr/bin/env bash
# metal-lint self-test:
#   * selftest/ok.metal must lint with zero errors;
#   * selftest/bad.metal must fail, and every line marked EXPECT-ERROR must be
#     reported as an error.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$HERE/../lint.sh"
OK_FILE="$HERE/ok.metal"
BAD_FILE="$HERE/bad.metal"
status=0

say_pass() { printf 'PASS  %s\n' "$1"; }
say_fail() { printf 'FAIL  %s\n' "$1"; status=1; }

# --- 1. ok.metal -------------------------------------------------------------
ok_out="$("$LINT" "$OK_FILE" 2>&1)"
ok_rc=$?
if [ "$ok_rc" -eq 0 ]; then
    say_pass "ok.metal lints clean (exit 0)"
else
    say_fail "ok.metal should lint clean but exited $ok_rc"
    printf '%s\n' "$ok_out"
fi
ok_warnings="$(printf '%s\n' "$ok_out" | grep -c -E ':[0-9]+:[0-9]+: warning:')"
if [ "$ok_warnings" -eq 0 ]; then
    say_pass "ok.metal produces no warnings"
else
    # Warnings are not fatal for the linter, but the self-test file is meant
    # to be pristine, so surface them.
    say_fail "ok.metal produced $ok_warnings warning(s)"
    printf '%s\n' "$ok_out" | grep -E ': warning:'
fi
ok_lines="$(wc -l < "$OK_FILE")"
if [ "$ok_lines" -ge 250 ]; then
    say_pass "ok.metal has $ok_lines lines (>= 250)"
else
    say_fail "ok.metal has only $ok_lines lines (< 250)"
fi

# --- 2. bad.metal ------------------------------------------------------------
bad_out="$("$LINT" "$BAD_FILE" 2>&1)"
bad_rc=$?
if [ "$bad_rc" -ne 0 ]; then
    say_pass "bad.metal fails the lint (exit $bad_rc)"
else
    say_fail "bad.metal should fail the lint but exited 0"
    printf '%s\n' "$bad_out"
fi

expected_lines="$(grep -n 'EXPECT-ERROR:' "$BAD_FILE" | cut -d: -f1)"
expected_count="$(printf '%s\n' "$expected_lines" | grep -c .)"
if [ "$expected_count" -eq 5 ]; then
    say_pass "bad.metal declares 5 expected errors"
else
    say_fail "bad.metal declares $expected_count expected errors (want 5)"
fi
for line in $expected_lines; do
    if printf '%s\n' "$bad_out" | grep -q -E "bad\.metal:${line}:[0-9]+: error:"; then
        say_pass "error reported on bad.metal:$line"
    else
        say_fail "no error reported on bad.metal:$line"
    fi
done
reported="$(printf '%s\n' "$bad_out" | grep -c -E 'bad\.metal:[0-9]+:[0-9]+: error:')"
if [ "$reported" -eq 5 ]; then
    say_pass "exactly 5 errors reported in bad.metal"
else
    say_fail "$reported errors reported in bad.metal (want exactly 5)"
    printf '%s\n' "$bad_out" | grep -E ': error:'
fi

if [ "$status" -eq 0 ]; then
    echo "metal-lint selftest: ALL PASSED"
else
    echo "metal-lint selftest: FAILURES"
fi
exit "$status"
