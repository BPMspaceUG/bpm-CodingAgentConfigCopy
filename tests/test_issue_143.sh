#!/usr/bin/env bash
# tests/test_issue_143.sh - Framework self-test for Issue #143
#
# run_test runs each test function in a subshell and used to judge only its
# exit code. fail() increments TESTS_FAILED inside that subshell, where the
# increment is lost, so a test that called `fail "..."` without `return 1`
# was reported as PASS and its suite exited 0.
#
# Seam: a throwaway suite file that sources test_framework.sh, run as its own
# process; we observe only its exit code and output, exactly as run_tests.sh
# does.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

# Write a one-test suite whose test function body is $1, run it, and leave
# its exit code in CHILD_RC and its output in CHILD_OUT.
_run_child_suite() {
    local body="$1"
    local suite="$TEST_TMPDIR/child_suite_$RANDOM.sh"
    cat > "$suite" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$SCRIPT_DIR/test_framework.sh"
framework_init
child_test() {
$body
}
run_test "child test" child_test
framework_report
EOF
    CHILD_OUT=$(bash "$suite" 2>&1)
    CHILD_RC=$?
}

test_fail_without_return_turns_suite_red() {
    _run_child_suite '    fail "inner check" "deliberate"'
    assert_equals 1 "$CHILD_RC" "child suite exit code" || return 1
    assert_contains "0/1 passed" "$CHILD_OUT" "child summary" || return 1
    if [[ "$CHILD_OUT" == *"PASS"*"child test"* ]]; then
        echo "child test was reported as PASS: $CHILD_OUT" >&2
        return 1
    fi
}

test_fail_then_return_zero_still_red() {
    _run_child_suite '    fail "inner check"
    return 0'
    assert_equals 1 "$CHILD_RC" "child suite exit code" || return 1
}

test_return_one_turns_suite_red() {
    _run_child_suite '    return 1'
    assert_equals 1 "$CHILD_RC" "child suite exit code" || return 1
}

test_clean_test_stays_green() {
    _run_child_suite '    true'
    assert_equals 0 "$CHILD_RC" "child suite exit code" || return 1
    assert_contains "1/1 passed" "$CHILD_OUT" "child summary" || return 1
}

echo "========================================"
echo "Issue #143: fail() inside run_test turns the test red"
echo "========================================"

run_test "fail without return 1 makes the test and suite FAIL" test_fail_without_return_turns_suite_red
run_test "fail followed by return 0 still FAILs" test_fail_then_return_zero_still_red
run_test "return 1 makes the test FAIL" test_return_one_turns_suite_red
run_test "a test with no fail stays green" test_clean_test_stays_green

framework_report
