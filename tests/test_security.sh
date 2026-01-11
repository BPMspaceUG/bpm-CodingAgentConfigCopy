#!/usr/bin/env bash
# tests/test_security.sh - Security validation tests
#
# Run with: ./tests/test_security.sh
# Or run all tests: ./tests/run_tests.sh
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

# ============================================================================
# Test Framework Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check for optional dependencies (some tests may be skipped if missing)
HAS_ZIP=false
if command -v zip &>/dev/null; then
    HAS_ZIP=true
fi

# Source library modules
source "${PROJECT_ROOT}/lib/security.sh"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Temporary test directory
TEST_TMPDIR=""

setup_test_env() {
    TEST_TMPDIR=$(mktemp -d -t cac-test.XXXXXXXXXX)
    chmod 700 "$TEST_TMPDIR"
}

cleanup_test_env() {
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

trap cleanup_test_env EXIT

# Test result helpers
pass() {
    local test_name="$1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓ PASS${NC}: $test_name"
}

fail() {
    local test_name="$1"
    local message="${2:-}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗ FAIL${NC}: $test_name"
    if [[ -n "$message" ]]; then
        echo "         $message"
    fi
}

skip() {
    local test_name="$1"
    local reason="${2:-}"
    echo -e "${YELLOW}○ SKIP${NC}: $test_name"
    if [[ -n "$reason" ]]; then
        echo "         ($reason)"
    fi
}

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

# Run test only if condition is met, otherwise skip
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
# User Access Tests
# ============================================================================

test_security_check_user_access_same_user() {
    # Should always allow access to own files
    if security_check_user_access "$(whoami)" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

test_security_check_user_access_different_user_non_root() {
    # Non-root should fail for other users
    if [[ "$EUID" -eq 0 ]]; then
        echo "SKIP: Test requires non-root" >&2
        return 0
    fi

    if security_check_user_access "root" 2>/dev/null; then
        echo "Expected failure for accessing root as non-root" >&2
        return 1
    fi

    return 0
}

# ============================================================================
# User Home Resolution Tests
# ============================================================================

test_security_resolve_user_home_valid() {
    local home
    # Current user should always have a valid home
    if home=$(security_resolve_user_home "$(whoami)"); then
        if [[ -d "$home" ]]; then
            return 0
        fi
    fi
    return 1
}

test_security_resolve_user_home_invalid() {
    # Non-existent user should fail
    if security_resolve_user_home "nonexistent_user_xyz123" 2>/dev/null; then
        echo "Expected failure for non-existent user" >&2
        return 1
    fi
    return 0
}

# ============================================================================
# File Permission Tests
# ============================================================================

test_security_check_file_permissions_secure() {
    local test_file="${TEST_TMPDIR}/secure_file"
    echo "test" > "$test_file"
    chmod 600 "$test_file"

    if security_check_file_permissions "$test_file" 600 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

test_security_check_file_permissions_insecure() {
    local test_file="${TEST_TMPDIR}/insecure_file"
    echo "test" > "$test_file"
    chmod 644 "$test_file"

    # 644 should fail when max is 600
    if security_check_file_permissions "$test_file" 600 2>/dev/null; then
        echo "Expected failure for insecure permissions" >&2
        return 1
    fi
    return 0
}

test_security_check_file_permissions_nonexistent() {
    # Non-existent file should pass (nothing to check)
    if security_check_file_permissions "/nonexistent/file" 600 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

test_security_check_file_permissions_world_readable() {
    local test_file="${TEST_TMPDIR}/world_readable"
    echo "test" > "$test_file"
    chmod 644 "$test_file"

    # 644 is world readable, should fail for 600 max
    if security_check_file_permissions "$test_file" 600 2>/dev/null; then
        echo "Expected failure for world-readable file" >&2
        return 1
    fi
    return 0
}

test_security_check_file_permissions_group_readable() {
    local test_file="${TEST_TMPDIR}/group_readable"
    echo "test" > "$test_file"
    chmod 640 "$test_file"

    # 640 is group readable, should fail for 600 max
    if security_check_file_permissions "$test_file" 600 2>/dev/null; then
        echo "Expected failure for group-readable file" >&2
        return 1
    fi
    return 0
}

# ============================================================================
# ZIP Path Validation (Zip-Slip Protection) Tests
# ============================================================================

test_security_validate_zip_path_normal() {
    # Normal relative path should pass
    if security_validate_zip_path ".claude.json" "/home/user" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

test_security_validate_zip_path_nested() {
    # Nested path should pass
    if security_validate_zip_path ".claude/.credentials.json" "/home/user" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

test_security_validate_zip_path_absolute_rejected() {
    # Absolute path should be rejected
    if security_validate_zip_path "/etc/passwd" "/home/user" 2>/dev/null; then
        echo "Expected absolute path to be rejected" >&2
        return 1
    fi
    return 0
}

test_security_validate_zip_path_traversal_dotdot_rejected() {
    # Path traversal with .. should be rejected
    if security_validate_zip_path "../../../etc/passwd" "/home/user" 2>/dev/null; then
        echo "Expected path traversal to be rejected" >&2
        return 1
    fi
    return 0
}

test_security_validate_zip_path_traversal_embedded_rejected() {
    # Embedded .. should be rejected
    if security_validate_zip_path ".claude/../../etc/passwd" "/home/user" 2>/dev/null; then
        echo "Expected embedded path traversal to be rejected" >&2
        return 1
    fi
    return 0
}

test_security_validate_zip_path_dotdot_only() {
    # Just .. should be rejected
    if security_validate_zip_path ".." "/home/user" 2>/dev/null; then
        echo "Expected .. to be rejected" >&2
        return 1
    fi
    return 0
}

# ============================================================================
# Full ZIP Validation Tests
# ============================================================================

test_security_validate_zip_valid() {
    local zip_file="${TEST_TMPDIR}/valid.zip"
    local src_dir="${TEST_TMPDIR}/src"

    mkdir -p "$src_dir/.claude"
    echo '{}' > "$src_dir/.claude.json"
    echo '{}' > "$src_dir/.claude/.credentials.json"

    (cd "$src_dir" && zip -q "$zip_file" .claude.json .claude/.credentials.json)

    if security_validate_zip "$zip_file" "/home/user" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

test_security_validate_zip_nonexistent() {
    # Non-existent ZIP should fail
    if security_validate_zip "/nonexistent/file.zip" "/home/user" 2>/dev/null; then
        echo "Expected failure for non-existent ZIP" >&2
        return 1
    fi
    return 0
}

test_security_validate_zip_too_large() {
    local zip_file="${TEST_TMPDIR}/large.zip"
    local src_dir="${TEST_TMPDIR}/large_src"

    mkdir -p "$src_dir"

    # Create a file larger than the limit (default 100MB)
    # We'll set a smaller limit for testing
    SECURITY_MAX_ZIP_SIZE=1000  # 1KB limit for test

    # Create a 2KB file with random data (zeros compress too well)
    dd if=/dev/urandom of="$src_dir/bigfile" bs=1024 count=2 2>/dev/null

    (cd "$src_dir" && zip -q "$zip_file" bigfile)

    if security_validate_zip "$zip_file" "/home/user" 2>/dev/null; then
        echo "Expected failure for oversized ZIP" >&2
        SECURITY_MAX_ZIP_SIZE=104857600  # Reset
        return 1
    fi

    SECURITY_MAX_ZIP_SIZE=104857600  # Reset
    return 0
}

test_security_validate_zip_too_many_files() {
    local zip_file="${TEST_TMPDIR}/many_files.zip"
    local src_dir="${TEST_TMPDIR}/many_src"

    mkdir -p "$src_dir"

    # Set low limit for testing
    SECURITY_MAX_ZIP_FILES=5

    # Create more files than the limit
    for i in {1..10}; do
        echo "test" > "$src_dir/file${i}.txt"
    done

    (cd "$src_dir" && zip -q "$zip_file" -- *.txt)

    if security_validate_zip "$zip_file" "/home/user" 2>/dev/null; then
        echo "Expected failure for too many files" >&2
        SECURITY_MAX_ZIP_FILES=100  # Reset
        return 1
    fi

    SECURITY_MAX_ZIP_FILES=100  # Reset
    return 0
}

# ============================================================================
# Secure Temp Directory Tests
# ============================================================================

test_security_mktemp_dir() {
    local tmpdir
    tmpdir=$(security_mktemp_dir "test-prefix")

    if [[ ! -d "$tmpdir" ]]; then
        echo "Temp directory not created" >&2
        return 1
    fi

    # Check permissions
    local perms
    perms=$(stat -c "%a" "$tmpdir" 2>/dev/null || stat -f "%Lp" "$tmpdir" 2>/dev/null)

    if [[ "$perms" != "700" ]]; then
        echo "Expected permissions 700, got $perms" >&2
        rm -rf "$tmpdir"
        return 1
    fi

    rm -rf "$tmpdir"
    return 0
}

# ============================================================================
# Secure File/Dir Permission Setting Tests
# ============================================================================

test_security_secure_file() {
    local test_file="${TEST_TMPDIR}/to_secure"
    echo "test" > "$test_file"
    chmod 644 "$test_file"

    security_secure_file "$test_file" ""

    local perms
    perms=$(stat -c "%a" "$test_file" 2>/dev/null || stat -f "%Lp" "$test_file" 2>/dev/null)

    if [[ "$perms" == "600" ]]; then
        return 0
    else
        echo "Expected permissions 600, got $perms" >&2
        return 1
    fi
}

test_security_secure_dir() {
    local test_dir="${TEST_TMPDIR}/dir_to_secure"
    mkdir -p "$test_dir"
    chmod 755 "$test_dir"

    security_secure_dir "$test_dir" ""

    local perms
    perms=$(stat -c "%a" "$test_dir" 2>/dev/null || stat -f "%Lp" "$test_dir" 2>/dev/null)

    if [[ "$perms" == "700" ]]; then
        return 0
    else
        echo "Expected permissions 700, got $perms" >&2
        return 1
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "Security Module Tests"
    echo "========================================"
    echo ""

    setup_test_env

    echo "--- User Access ---"
    run_test "check_user_access same user" test_security_check_user_access_same_user
    run_test "check_user_access different user (non-root)" test_security_check_user_access_different_user_non_root
    echo ""

    echo "--- User Home Resolution ---"
    run_test "resolve_user_home valid" test_security_resolve_user_home_valid
    run_test "resolve_user_home invalid" test_security_resolve_user_home_invalid
    echo ""

    echo "--- File Permissions ---"
    run_test "check_file_permissions secure" test_security_check_file_permissions_secure
    run_test "check_file_permissions insecure" test_security_check_file_permissions_insecure
    run_test "check_file_permissions nonexistent" test_security_check_file_permissions_nonexistent
    run_test "check_file_permissions world-readable" test_security_check_file_permissions_world_readable
    run_test "check_file_permissions group-readable" test_security_check_file_permissions_group_readable
    echo ""

    echo "--- Zip-Slip Protection ---"
    run_test "validate_zip_path normal" test_security_validate_zip_path_normal
    run_test "validate_zip_path nested" test_security_validate_zip_path_nested
    run_test "validate_zip_path absolute rejected" test_security_validate_zip_path_absolute_rejected
    run_test "validate_zip_path traversal (..) rejected" test_security_validate_zip_path_traversal_dotdot_rejected
    run_test "validate_zip_path embedded traversal rejected" test_security_validate_zip_path_traversal_embedded_rejected
    run_test "validate_zip_path dotdot only rejected" test_security_validate_zip_path_dotdot_only
    echo ""

    echo "--- Full ZIP Validation ---"
    run_test_if "$HAS_ZIP" "validate_zip valid" test_security_validate_zip_valid "zip not installed"
    run_test "validate_zip nonexistent" test_security_validate_zip_nonexistent
    run_test_if "$HAS_ZIP" "validate_zip too large" test_security_validate_zip_too_large "zip not installed"
    run_test_if "$HAS_ZIP" "validate_zip too many files" test_security_validate_zip_too_many_files "zip not installed"
    echo ""

    echo "--- Secure Temp/File Operations ---"
    run_test "mktemp_dir" test_security_mktemp_dir
    run_test "secure_file" test_security_secure_file
    run_test "secure_dir" test_security_secure_dir
    echo ""

    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}$TESTS_FAILED test(s) failed${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
