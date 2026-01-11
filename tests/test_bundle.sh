#!/usr/bin/env bash
# tests/test_bundle.sh - Bundle creation/extraction tests
#
# Run with: ./tests/test_bundle.sh
# Or run all tests: ./tests/run_tests.sh
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

# ============================================================================
# Test Framework Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check for required dependencies
check_dependencies() {
    local missing=()

    if ! command -v zip &>/dev/null; then
        missing+=("zip")
    fi
    if ! command -v unzip &>/dev/null; then
        missing+=("unzip")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required dependencies: ${missing[*]}" >&2
        echo "Install with: sudo apt-get install ${missing[*]}" >&2
        exit 1
    fi
}

check_dependencies

# Source library modules
source "${PROJECT_ROOT}/lib/tools.sh"
source "${PROJECT_ROOT}/lib/security.sh"
source "${PROJECT_ROOT}/lib/bundle.sh"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
# shellcheck disable=SC2034  # reserved for skip() output
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

# ============================================================================
# Bundle Filename Tests
# ============================================================================

test_bundle_generate_filename_format() {
    local filename
    filename=$(bundle_generate_filename "testuser")

    # Should match pattern: CodingAgentConfig_<host>_testuser_<YYMMDD-HHMMSS>.zip
    if [[ "$filename" =~ ^CodingAgentConfig_[^_]+_testuser_[0-9]{6}-[0-9]{6}\.zip$ ]]; then
        return 0
    else
        echo "Expected format CodingAgentConfig_*_testuser_YYMMDD-HHMMSS.zip, got: $filename" >&2
        return 1
    fi
}

test_bundle_generate_filename_default_user() {
    local filename
    filename=$(bundle_generate_filename)

    # Should contain current user
    if [[ "$filename" == *"_${USER}_"* ]]; then
        return 0
    else
        echo "Expected filename to contain _${USER}_, got: $filename" >&2
        return 1
    fi
}

test_bundle_parse_filename_valid() {
    local result
    result=$(bundle_parse_filename "CodingAgentConfig_myhost_ubuntu_250111-143022.zip")

    if [[ "$result" == "myhost ubuntu 250111-143022" ]]; then
        return 0
    else
        echo "Expected 'myhost ubuntu 250111-143022', got: '$result'" >&2
        return 1
    fi
}

test_bundle_parse_filename_invalid() {
    # Should fail for invalid format
    if bundle_parse_filename "invalid_filename.zip" 2>/dev/null; then
        echo "Expected parse to fail for invalid filename" >&2
        return 1
    fi
    return 0
}

test_bundle_get_host() {
    local host
    host=$(bundle_get_host "CodingAgentConfig_prod-server_bob_250111-120000.zip")

    if [[ "$host" == "prod-server" ]]; then
        return 0
    else
        echo "Expected 'prod-server', got: '$host'" >&2
        return 1
    fi
}

test_bundle_get_user() {
    local user
    user=$(bundle_get_user "CodingAgentConfig_prod-server_bob_250111-120000.zip")

    if [[ "$user" == "bob" ]]; then
        return 0
    else
        echo "Expected 'bob', got: '$user'" >&2
        return 1
    fi
}

test_bundle_get_timestamp() {
    local ts
    ts=$(bundle_get_timestamp "CodingAgentConfig_prod-server_bob_250111-120000.zip")

    if [[ "$ts" == "250111-120000" ]]; then
        return 0
    else
        echo "Expected '250111-120000', got: '$ts'" >&2
        return 1
    fi
}

# ============================================================================
# Bundle Creation Tests
# ============================================================================

test_bundle_create_with_files() {
    local fake_home="${TEST_TMPDIR}/home"
    local output_zip="${TEST_TMPDIR}/output.zip"

    # Create fake home with config files
    mkdir -p "${fake_home}/.claude"
    mkdir -p "${fake_home}/.codex"
    echo '{"test": true}' > "${fake_home}/.claude.json"
    echo '{"creds": "secret"}' > "${fake_home}/.claude/.credentials.json"
    echo '{"auth": "token"}' > "${fake_home}/.codex/auth.json"

    # Create bundle
    if ! bundle_create "$fake_home" "$output_zip" "all" >/dev/null 2>&1; then
        echo "bundle_create failed" >&2
        return 1
    fi

    # Verify ZIP was created
    if [[ ! -f "$output_zip" ]]; then
        echo "Output ZIP not created" >&2
        return 1
    fi

    # Verify ZIP contains expected files
    local contents
    contents=$(unzip -Z1 "$output_zip")

    if [[ "$contents" != *".claude.json"* ]]; then
        echo "ZIP missing .claude.json" >&2
        return 1
    fi

    if [[ "$contents" != *".claude/.credentials.json"* ]]; then
        echo "ZIP missing .claude/.credentials.json" >&2
        return 1
    fi

    if [[ "$contents" != *".codex/auth.json"* ]]; then
        echo "ZIP missing .codex/auth.json" >&2
        return 1
    fi

    return 0
}

test_bundle_create_empty_fails() {
    local fake_home="${TEST_TMPDIR}/empty_home"
    local output_zip="${TEST_TMPDIR}/empty.zip"

    mkdir -p "$fake_home"

    # Should fail when no config files exist
    if bundle_create "$fake_home" "$output_zip" "all" 2>/dev/null; then
        echo "Expected bundle_create to fail for empty home" >&2
        return 1
    fi

    return 0
}

test_bundle_create_claude_only() {
    local fake_home="${TEST_TMPDIR}/home2"
    local output_zip="${TEST_TMPDIR}/claude_only.zip"

    # Create fake home with all tool configs
    mkdir -p "${fake_home}/.claude"
    mkdir -p "${fake_home}/.codex"
    echo '{"test": true}' > "${fake_home}/.claude.json"
    echo '{"auth": "token"}' > "${fake_home}/.codex/auth.json"

    # Create bundle for claude only
    if ! bundle_create "$fake_home" "$output_zip" "claude" >/dev/null 2>&1; then
        echo "bundle_create failed" >&2
        return 1
    fi

    # Verify ZIP contains only claude files
    local contents
    contents=$(unzip -Z1 "$output_zip")

    if [[ "$contents" != *".claude.json"* ]]; then
        echo "ZIP missing .claude.json" >&2
        return 1
    fi

    # Should NOT contain codex files
    if [[ "$contents" == *".codex"* ]]; then
        echo "ZIP should not contain .codex files" >&2
        return 1
    fi

    return 0
}

# ============================================================================
# Bundle Extraction Tests
# ============================================================================

test_bundle_extract_basic() {
    local fake_home="${TEST_TMPDIR}/src_home"
    local target_home="${TEST_TMPDIR}/dst_home"
    local bundle_zip="${TEST_TMPDIR}/test_bundle.zip"

    # Create source home with config
    mkdir -p "${fake_home}/.claude"
    echo '{"original": true}' > "${fake_home}/.claude.json"
    echo '{"creds": "secret123"}' > "${fake_home}/.claude/.credentials.json"

    # Create target home (empty)
    mkdir -p "$target_home"

    # Create bundle
    bundle_create "$fake_home" "$bundle_zip" "claude" >/dev/null 2>&1

    # Extract to target
    if ! bundle_extract "$bundle_zip" "$target_home" "$(whoami)" >/dev/null 2>&1; then
        echo "bundle_extract failed" >&2
        return 1
    fi

    # Verify files were extracted
    if [[ ! -f "${target_home}/.claude.json" ]]; then
        echo "Extracted file .claude.json not found" >&2
        return 1
    fi

    if [[ ! -f "${target_home}/.claude/.credentials.json" ]]; then
        echo "Extracted file .claude/.credentials.json not found" >&2
        return 1
    fi

    # Verify content
    local content
    content=$(cat "${target_home}/.claude.json")
    if [[ "$content" != '{"original": true}' ]]; then
        echo "Extracted content mismatch" >&2
        return 1
    fi

    return 0
}

test_bundle_extract_creates_backup() {
    local fake_home="${TEST_TMPDIR}/src_home3"
    local target_home="${TEST_TMPDIR}/dst_home3"
    local bundle_zip="${TEST_TMPDIR}/backup_test.zip"

    # Create source home
    mkdir -p "${fake_home}/.claude"
    echo '{"new": "content"}' > "${fake_home}/.claude.json"

    # Create target home with existing file
    mkdir -p "$target_home"
    echo '{"old": "content"}' > "${target_home}/.claude.json"

    # Create and extract bundle
    bundle_create "$fake_home" "$bundle_zip" "claude" >/dev/null 2>&1
    bundle_extract "$bundle_zip" "$target_home" "$(whoami)" >/dev/null 2>&1

    # Check that a backup was created
    local backup_count
    backup_count=$(find "$target_home" -name ".claude.json.backup*" | wc -l)

    if [[ "$backup_count" -lt 1 ]]; then
        echo "No backup file created" >&2
        return 1
    fi

    # Verify backup contains old content
    local backup_file
    backup_file=$(find "$target_home" -name ".claude.json.backup*" | head -1)
    local backup_content
    backup_content=$(cat "$backup_file")

    if [[ "$backup_content" != '{"old": "content"}' ]]; then
        echo "Backup content mismatch" >&2
        return 1
    fi

    # Verify main file has new content
    local main_content
    main_content=$(cat "${target_home}/.claude.json")
    if [[ "$main_content" != '{"new": "content"}' ]]; then
        echo "Main file content not updated" >&2
        return 1
    fi

    return 0
}

test_bundle_list_contents() {
    local fake_home="${TEST_TMPDIR}/list_home"
    local bundle_zip="${TEST_TMPDIR}/list_test.zip"

    # Create source home with config
    mkdir -p "${fake_home}/.claude"
    echo '{}' > "${fake_home}/.claude.json"

    # Create bundle
    bundle_create "$fake_home" "$bundle_zip" "claude" >/dev/null 2>&1

    # Test list_contents
    local output
    output=$(bundle_list_contents "$bundle_zip")

    if [[ "$output" != *".claude.json"* ]]; then
        echo "list_contents missing expected file" >&2
        return 1
    fi

    return 0
}

test_bundle_list_contents_nonexistent() {
    # Should fail for non-existent file
    if bundle_list_contents "/nonexistent/file.zip" 2>/dev/null; then
        echo "Expected failure for non-existent file" >&2
        return 1
    fi

    return 0
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "Bundle Module Tests"
    echo "========================================"
    echo ""

    setup_test_env

    echo "--- Filename Generation/Parsing ---"
    run_test "bundle_generate_filename format" test_bundle_generate_filename_format
    run_test "bundle_generate_filename default user" test_bundle_generate_filename_default_user
    run_test "bundle_parse_filename valid" test_bundle_parse_filename_valid
    run_test "bundle_parse_filename invalid" test_bundle_parse_filename_invalid
    run_test "bundle_get_host" test_bundle_get_host
    run_test "bundle_get_user" test_bundle_get_user
    run_test "bundle_get_timestamp" test_bundle_get_timestamp
    echo ""

    echo "--- Bundle Creation ---"
    run_test "bundle_create with files" test_bundle_create_with_files
    run_test "bundle_create empty fails" test_bundle_create_empty_fails
    run_test "bundle_create claude only" test_bundle_create_claude_only
    echo ""

    echo "--- Bundle Extraction ---"
    run_test "bundle_extract basic" test_bundle_extract_basic
    run_test "bundle_extract creates backup" test_bundle_extract_creates_backup
    run_test "bundle_list_contents" test_bundle_list_contents
    run_test "bundle_list_contents nonexistent" test_bundle_list_contents_nonexistent
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
