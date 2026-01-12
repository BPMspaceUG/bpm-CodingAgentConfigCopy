#!/usr/bin/env bash
# tests/test_framework.sh - Shared test framework for cac tests
#
# This module provides common test utilities used by all test files.
# Source this file at the beginning of each test file.
#
# Usage:
#   source "${SCRIPT_DIR}/test_framework.sh"
#   framework_init
#   run_test "test name" test_function
#   framework_report

# shellcheck disable=SC2034  # Variables are used by test files

# ============================================================================
# Test Counters and Colors
# ============================================================================

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================================================
# Temporary Test Directory Management
# ============================================================================

TEST_TMPDIR=""

# Create secure temporary test directory
# Usage: framework_init
# Call this at the start of your test suite
framework_init() {
    TEST_TMPDIR=$(mktemp -d -t cac-test.XXXXXXXXXX)
    chmod 700 "$TEST_TMPDIR"
}

# Clean up temporary test directory
# This is automatically called on EXIT via trap
_framework_cleanup() {
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

trap _framework_cleanup EXIT

# ============================================================================
# Test Result Helpers
# ============================================================================

# Record a passing test
# Usage: pass "test_name"
pass() {
    local test_name="$1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓ PASS${NC}: $test_name"
}

# Record a failing test with optional message
# Usage: fail "test_name" ["error_message"]
fail() {
    local test_name="$1"
    local message="${2:-}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗ FAIL${NC}: $test_name"
    if [[ -n "$message" ]]; then
        echo "         $message"
    fi
}

# Record a skipped test with optional reason
# Usage: skip "test_name" ["reason"]
skip() {
    local test_name="$1"
    local reason="${2:-}"
    echo -e "${YELLOW}○ SKIP${NC}: $test_name"
    if [[ -n "$reason" ]]; then
        echo "         ($reason)"
    fi
}

# ============================================================================
# Test Runners
# ============================================================================

# Run a test function and record result
# Usage: run_test "test_name" test_function
#
# The test function should return 0 for success, non-zero for failure.
# Test functions are run in a subshell to catch failures without exiting.
run_test() {
    local test_name="$1"
    local test_func="$2"
    TESTS_RUN=$((TESTS_RUN + 1))

    # Run test in subshell to catch failures without exiting main script
    if (set +e; $test_func); then
        pass "$test_name"
    else
        fail "$test_name"
    fi
}

# Run a test only if a condition is met, otherwise skip
# Usage: run_test_if <condition_var> "test_name" test_function ["skip_reason"]
#
# Example:
#   HAS_JQ=true
#   run_test_if "$HAS_JQ" "jq parsing" test_jq_parsing "jq not installed"
run_test_if() {
    local condition="$1"
    local test_name="$2"
    local test_func="$3"
    local skip_reason="${4:-condition not met}"

    if $condition; then
        run_test "$test_name" "$test_func"
    else
        skip "$test_name" "$skip_reason"
    fi
}

# ============================================================================
# Reporting
# ============================================================================

# Print test results summary
# Usage: framework_report
# Returns: 0 if all tests passed, 1 if any failed
framework_report() {
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}$TESTS_FAILED test(s) failed${NC}"
        return 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    fi
}

# ============================================================================
# Dependency Checking
# ============================================================================

# Check if required commands are available
# Usage: framework_require_commands cmd1 cmd2 ...
# Returns: 0 if all present, exits with error if any missing
framework_require_commands() {
    local missing=()

    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required dependencies: ${missing[*]}" >&2
        echo "Install with: sudo apt-get install ${missing[*]}" >&2
        exit 1
    fi
}

# Check if a command is available (for conditional tests)
# Usage: if framework_has_command "jq"; then ...; fi
framework_has_command() {
    command -v "$1" &>/dev/null
}

# ============================================================================
# Assertion Helpers
# ============================================================================

# Assert that two values are equal
# Usage: assert_equals <expected> <actual> [description]
# Returns: 0 if equal, 1 if not (with error message to stderr)
#
# Example:
#   assert_equals "hello" "$result" "greeting should match"
assert_equals() {
    local expected="$1"
    local actual="$2"
    local description="${3:-value}"

    if [[ "$actual" == "$expected" ]]; then
        return 0
    else
        echo "Expected ${description}: '$expected', got: '$actual'" >&2
        return 1
    fi
}

# Assert that a value matches a regex pattern
# Usage: assert_match <pattern> <value> [description]
# Returns: 0 if matches, 1 if not (with error message to stderr)
#
# Example:
#   assert_match '^[0-9]+$' "$result" "should be numeric"
assert_match() {
    local pattern="$1"
    local value="$2"
    local description="${3:-value}"

    if [[ "$value" =~ $pattern ]]; then
        return 0
    else
        echo "Expected ${description} to match pattern '$pattern', got: '$value'" >&2
        return 1
    fi
}

# Assert that a value contains a substring
# Usage: assert_contains <needle> <haystack> [description]
# Returns: 0 if contains, 1 if not (with error message to stderr)
#
# Example:
#   assert_contains "error" "$output" "output should contain error"
assert_contains() {
    local needle="$1"
    local haystack="$2"
    local description="${3:-value}"

    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        echo "Expected ${description} to contain '$needle', got: '$haystack'" >&2
        return 1
    fi
}

# Assert that a file exists
# Usage: assert_file_exists <path> [description]
# Returns: 0 if exists, 1 if not (with error message to stderr)
#
# Example:
#   assert_file_exists "$output_file" "output file"
assert_file_exists() {
    local path="$1"
    local description="${2:-file}"

    if [[ -f "$path" ]]; then
        return 0
    else
        echo "Expected ${description} to exist: '$path'" >&2
        return 1
    fi
}

# Assert that a command succeeds (exit code 0)
# Usage: assert_success <description> <command> [args...]
# Returns: 0 if command succeeds, 1 if fails (with error message to stderr)
#
# Example:
#   assert_success "bundle creation" bundle_create "$home" "$output"
assert_success() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        return 0
    else
        echo "Expected ${description} to succeed, but it failed" >&2
        return 1
    fi
}

# Assert that a command fails (non-zero exit code)
# Usage: assert_fails <description> <command> [args...]
# Returns: 0 if command fails, 1 if succeeds (with error message to stderr)
#
# Example:
#   assert_fails "empty bundle creation" bundle_create "$empty_home" "$output"
assert_fails() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        echo "Expected ${description} to fail, but it succeeded" >&2
        return 1
    else
        return 0
    fi
}
