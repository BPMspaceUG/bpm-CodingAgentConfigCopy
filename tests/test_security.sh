#!/usr/bin/env bash
# tests/test_security.sh - Security validation tests
#
# Run with: ./tests/test_security.sh
# Or run all tests: ./tests/run_tests.sh
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source shared test framework
source "${SCRIPT_DIR}/test_framework.sh"

# Check for optional dependencies (some tests may be skipped if missing)
HAS_ZIP=false
if framework_has_command zip; then
    HAS_ZIP=true
fi

# Source library modules
source "${PROJECT_ROOT}/lib/security.sh"

# ============================================================================
# User Access Tests
# ============================================================================

test_security_check_user_access_same_user() {
    # Should always allow access to own files
    assert_success "access own user" security_check_user_access "$(whoami)"
}

test_security_check_user_access_different_user_non_root() {
    # Non-root should fail for other users
    if [[ "$EUID" -eq 0 ]]; then
        echo "SKIP: Test requires non-root" >&2
        return 0
    fi

    assert_fails "access root as non-root" security_check_user_access "root"
}

# ============================================================================
# User Home Resolution Tests
# ============================================================================

test_security_resolve_user_home_valid() {
    local home
    home=$(security_resolve_user_home "$(whoami)") || { echo "Failed to resolve home" >&2; return 1; }
    [[ -d "$home" ]] || { echo "Home directory does not exist: $home" >&2; return 1; }
}

test_security_resolve_user_home_invalid() {
    # Non-existent user should fail
    assert_fails "resolve non-existent user" security_resolve_user_home "nonexistent_user_xyz123"
}

# ============================================================================
# File Permission Tests
# ============================================================================

test_security_check_file_permissions_secure() {
    local test_file="${TEST_TMPDIR}/secure_file"
    echo "test" > "$test_file"
    chmod 600 "$test_file"

    assert_success "check secure permissions" security_check_file_permissions "$test_file" 600
}

test_security_check_file_permissions_insecure() {
    local test_file="${TEST_TMPDIR}/insecure_file"
    echo "test" > "$test_file"
    chmod 644 "$test_file"

    # 644 should fail when max is 600
    assert_fails "check insecure permissions" security_check_file_permissions "$test_file" 600
}

test_security_check_file_permissions_nonexistent() {
    # Non-existent file should pass (nothing to check)
    assert_success "check nonexistent file" security_check_file_permissions "/nonexistent/file" 600
}

test_security_check_file_permissions_world_readable() {
    local test_file="${TEST_TMPDIR}/world_readable"
    echo "test" > "$test_file"
    chmod 644 "$test_file"

    # 644 is world readable, should fail for 600 max
    assert_fails "check world-readable permissions" security_check_file_permissions "$test_file" 600
}

test_security_check_file_permissions_group_readable() {
    local test_file="${TEST_TMPDIR}/group_readable"
    echo "test" > "$test_file"
    chmod 640 "$test_file"

    # 640 is group readable, should fail for 600 max
    assert_fails "check group-readable permissions" security_check_file_permissions "$test_file" 600
}

# ============================================================================
# ZIP Path Validation (Zip-Slip Protection) Tests
# ============================================================================

test_security_validate_zip_path_normal() {
    # Normal relative path should pass
    assert_success "normal relative path" security_validate_zip_path ".claude.json" "/home/user"
}

test_security_validate_zip_path_nested() {
    # Nested path should pass
    assert_success "nested relative path" security_validate_zip_path ".claude/.credentials.json" "/home/user"
}

test_security_validate_zip_path_absolute_rejected() {
    # Absolute path should be rejected
    assert_fails "reject absolute path" security_validate_zip_path "/etc/passwd" "/home/user"
}

test_security_validate_zip_path_traversal_dotdot_rejected() {
    # Path traversal with .. should be rejected
    assert_fails "reject path traversal" security_validate_zip_path "../../../etc/passwd" "/home/user"
}

test_security_validate_zip_path_traversal_embedded_rejected() {
    # Embedded .. should be rejected
    assert_fails "reject embedded traversal" security_validate_zip_path ".claude/../../etc/passwd" "/home/user"
}

test_security_validate_zip_path_dotdot_only() {
    # Just .. should be rejected
    assert_fails "reject dotdot only" security_validate_zip_path ".." "/home/user"
}

test_security_validate_zip_path_similar_prefix_rejected() {
    # Path to sibling directory with similar prefix should be rejected
    # e.g., /home/user123 should NOT match target /home/user
    assert_fails "reject similar prefix path" security_validate_zip_path "../user123/file.txt" "/home/user"
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

    assert_success "validate valid zip" security_validate_zip "$zip_file" "/home/user"
}

test_security_validate_zip_nonexistent() {
    # Non-existent ZIP should fail
    assert_fails "reject non-existent zip" security_validate_zip "/nonexistent/file.zip" "/home/user"
}

test_security_validate_zip_too_large() {
    local zip_file="${TEST_TMPDIR}/large.zip"
    local src_dir="${TEST_TMPDIR}/large_src"

    mkdir -p "$src_dir"

    # Set smaller limit for testing
    SECURITY_MAX_ZIP_SIZE=1000  # 1KB limit for test

    # Create a 2KB file with random data (zeros compress too well)
    dd if=/dev/urandom of="$src_dir/bigfile" bs=1024 count=2 2>/dev/null

    (cd "$src_dir" && zip -q "$zip_file" bigfile)

    assert_fails "reject oversized zip" security_validate_zip "$zip_file" "/home/user"
    SECURITY_MAX_ZIP_SIZE=104857600  # Reset
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

    assert_fails "reject too many files" security_validate_zip "$zip_file" "/home/user"
    SECURITY_MAX_ZIP_FILES=100  # Reset
}

# ============================================================================
# Secure Temp Directory Tests
# ============================================================================

test_security_mktemp_dir() {
    local tmpdir
    tmpdir=$(security_mktemp_dir "test-prefix")

    [[ -d "$tmpdir" ]] || { echo "Temp directory not created" >&2; return 1; }

    # Check permissions
    local perms
    perms=$(security_get_file_perms "$tmpdir")

    assert_equals "700" "$perms" "temp dir permissions"
    rm -rf "$tmpdir"
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
    perms=$(security_get_file_perms "$test_file")

    assert_equals "600" "$perms" "secured file permissions"
}

test_security_secure_dir() {
    local test_dir="${TEST_TMPDIR}/dir_to_secure"
    mkdir -p "$test_dir"
    chmod 755 "$test_dir"

    security_secure_dir "$test_dir" ""

    local perms
    perms=$(security_get_file_perms "$test_dir")

    assert_equals "700" "$perms" "secured directory permissions"
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "Security Module Tests"
    echo "========================================"
    echo ""

    framework_init

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
    run_test "validate_zip_path similar prefix rejected" test_security_validate_zip_path_similar_prefix_rejected
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

    framework_report
    exit $?
}

main "$@"
