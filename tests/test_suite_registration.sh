#!/usr/bin/env bash
# tests/test_suite_registration.sh - Every suite is registered AND runnable (#101)
#
# Run with: ./tests/test_suite_registration.sh
#
# Two failure modes have each cost this repo months of dark tests:
#
#   #101  a suite file exists but is not named in tests/run_tests.sh
#   #107  a suite IS named there but is not executable, so it was skipped
#
# This suite fails on either. That is why the runner keeps explicit enumeration
# rather than globbing: a glob would fix the first class and leave the second
# untouched, and it would cost the per-issue filter keys (`run_tests.sh 93`).
# The guard closes both classes and turns silent drift into a red test instead
# of a finding waiting for the next human audit.
#
# KNOWN LIMITATION, recorded deliberately: if this file AND its registration
# block in run_tests.sh are both deleted, nothing here detects it. A guard
# cannot detect its own complete removal from inside itself; that case closes
# at review time. Deleting only one of the two IS caught — the runner
# hard-fails on a MISSING or NOT EXECUTABLE registered suite, and this guard
# fails on an unregistered file.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/test_framework.sh disable=SC1091
source "${SCRIPT_DIR}/test_framework.sh"

RUNNER="${SCRIPT_DIR}/run_tests.sh"

framework_init

# ============================================================================
# Exception table
# ============================================================================
# Files that are intentionally NOT registered, each with its reason and, where
# one exists, the issue tracking its return. Printed on every run so an expired
# entry is visible in every CI log rather than quietly becoming permanent.
#
# Format: "<filename>|<reason>"
EXCEPTIONS=(
    "test_framework.sh|sourced library, not a suite — correctly non-executable"
    "test_issue_6.sh|4 REQUIRED failures are a behavioural triage question, tracked in #108"
)

_print_exceptions() {
    echo "Registration exceptions in force:"
    local entry
    for entry in "${EXCEPTIONS[@]}"; do
        echo "  - ${entry%%|*}: ${entry#*|}"
    done
    echo ""
}

# ============================================================================
# Core check
# ============================================================================
# Report every suite file in <tests-dir> that is unregistered in <runner-file>
# or not executable. Remaining arguments are exception entries, so the same
# logic can be pointed at a fixture directory by the tests below.
#
# Usage: _registration_report <tests-dir> <runner-file> [<exception> ...]
# Prints one line per offender; returns 1 if there were any.
_registration_report() {
    local tests_dir="$1" runner="$2"
    shift 2
    local -a exceptions=("$@")

    local found=0 file base entry excepted

    for file in "${tests_dir}"/test_*.sh; do
        [[ -e "$file" ]] || continue
        base="$(basename "$file")"

        excepted=0
        for entry in ${exceptions[@]+"${exceptions[@]}"}; do
            if [[ "${entry%%|*}" == "$base" ]]; then
                excepted=1
                break
            fi
        done
        [[ $excepted -eq 1 ]] && continue

        # -F: the runner names suites as literal quoted filenames.
        if ! grep -qF "\"${base}\"" "$runner"; then
            echo "UNREGISTERED: ${base} is not named in $(basename "$runner")"
            found=1
        fi

        if [[ ! -x "$file" ]]; then
            echo "NOT EXECUTABLE: ${base} (chmod +x)"
            found=1
        fi
    done

    return $(( found ))
}

# Build a fixture tests directory: $1 = dir, $2 = runner contents.
_fixture() {
    local dir="$1" runner_body="$2"
    mkdir -p "$dir"
    printf '%s\n' "$runner_body" > "${dir}/run_tests.sh"
}

# ============================================================================
# Tests
# ============================================================================

# 1: THE REAL TREE. Every suite registered and executable, exceptions aside.
test_real_tree_is_clean() {
    local report
    report=$(_registration_report "$SCRIPT_DIR" "$RUNNER" "${EXCEPTIONS[@]}") || {
        echo "Registration drift detected:" >&2
        echo "$report" >&2
        return 1
    }
    [[ -z "$report" ]] || { echo "Unexpected report: ${report}" >&2; return 1; }
}

# 2: CONTROL ARM for test 1 — an unregistered suite must be REPORTED. Without
# this, test 1 would pass just as well against a check that reports nothing.
test_unregistered_suite_is_reported() {
    local dir="${TEST_TMPDIR}/f_unreg"
    _fixture "$dir" 'run_test_suite "Nothing" "test_other.sh"'
    printf '#!/usr/bin/env bash\nexit 0\n' > "${dir}/test_fake_a.sh"
    chmod +x "${dir}/test_fake_a.sh"

    local report rc=0
    report=$(_registration_report "$dir" "${dir}/run_tests.sh") || rc=$?

    [[ $rc -eq 1 ]] || { echo "Expected rc 1, got ${rc}" >&2; return 1; }
    echo "$report" | grep -q "UNREGISTERED: test_fake_a.sh" || {
        echo "Expected test_fake_a.sh reported unregistered: ${report}" >&2; return 1
    }
}

# 3: the #107 shape — registered but not executable. This is the case a globbing
# runner would NOT catch, and the empirical reason the guard beats a glob.
test_non_executable_suite_is_reported() {
    local dir="${TEST_TMPDIR}/f_noexec"
    _fixture "$dir" 'run_test_suite "Fake B" "test_fake_b.sh"'
    printf '#!/usr/bin/env bash\nexit 0\n' > "${dir}/test_fake_b.sh"
    chmod 644 "${dir}/test_fake_b.sh"

    local report rc=0
    report=$(_registration_report "$dir" "${dir}/run_tests.sh") || rc=$?

    [[ $rc -eq 1 ]] || { echo "Expected rc 1, got ${rc}" >&2; return 1; }
    echo "$report" | grep -q "NOT EXECUTABLE: test_fake_b.sh" || {
        echo "Expected test_fake_b.sh reported non-executable: ${report}" >&2; return 1
    }
    # It IS registered, so it must not also be reported as unregistered.
    if echo "$report" | grep -q "UNREGISTERED: test_fake_b.sh"; then
        echo "Registered file wrongly reported unregistered: ${report}" >&2
        return 1
    fi
}

# 4: a correct fixture produces no report at all — proves the check is not
# firing unconditionally.
test_clean_fixture_produces_no_report() {
    local dir="${TEST_TMPDIR}/f_clean"
    _fixture "$dir" 'run_test_suite "Fake C" "test_fake_c.sh"'
    printf '#!/usr/bin/env bash\nexit 0\n' > "${dir}/test_fake_c.sh"
    chmod +x "${dir}/test_fake_c.sh"

    local report rc=0
    report=$(_registration_report "$dir" "${dir}/run_tests.sh") || rc=$?

    [[ $rc -eq 0 ]] || { echo "Expected rc 0, got ${rc}: ${report}" >&2; return 1; }
    [[ -z "$report" ]] || { echo "Expected empty report, got: ${report}" >&2; return 1; }
}

# 5: an excepted file is skipped — and the SAME file without the exception is
# reported. Proves the exception list is doing the work, not the absence of a
# problem.
test_exception_is_honoured_and_is_load_bearing() {
    local dir="${TEST_TMPDIR}/f_except"
    _fixture "$dir" 'run_test_suite "Nothing" "test_other.sh"'
    printf '#!/usr/bin/env bash\nexit 0\n' > "${dir}/test_fake_d.sh"
    chmod +x "${dir}/test_fake_d.sh"

    local report rc=0
    report=$(_registration_report "$dir" "${dir}/run_tests.sh" "test_fake_d.sh|under test") || rc=$?
    [[ $rc -eq 0 ]] || { echo "Excepted file was still reported: ${report}" >&2; return 1; }

    rc=0
    report=$(_registration_report "$dir" "${dir}/run_tests.sh") || rc=$?
    [[ $rc -eq 1 ]] || { echo "Without the exception it should be reported, rc=${rc}" >&2; return 1; }
}

# 6: test_framework.sh must stay non-executable — it is sourced, not run. A
# well-meaning `chmod +x tests/*.sh` would make the runner try to execute it.
test_framework_is_not_executable() {
    if [[ -x "${SCRIPT_DIR}/test_framework.sh" ]]; then
        echo "test_framework.sh is executable; it is a sourced library" >&2
        return 1
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "=========================================="
echo "Issue #101 tests: suite registration guard"
echo "=========================================="
_print_exceptions

run_test "real tree: every suite registered + executable" test_real_tree_is_clean
run_test "unregistered suite IS reported"                 test_unregistered_suite_is_reported
run_test "non-executable suite IS reported (#107 shape)"  test_non_executable_suite_is_reported
run_test "clean fixture produces no report"               test_clean_fixture_produces_no_report
run_test "exception honoured and load-bearing"            test_exception_is_honoured_and_is_load_bearing
run_test "test_framework.sh stays non-executable"         test_framework_is_not_executable

framework_report
