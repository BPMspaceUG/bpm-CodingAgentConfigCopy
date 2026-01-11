#!/usr/bin/env bash
# tests/test_integration.sh - End-to-end integration tests
#
# Run with: ./tests/test_integration.sh
# Or run all tests: ./tests/run_tests.sh
#
# These tests exercise the full push/pull/list/get workflow with the local backend.
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

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
# shellcheck disable=SC2034  # reserved for skip() output
YELLOW='\033[1;33m'
NC='\033[0m'

# Temporary test directory
TEST_TMPDIR=""
TEST_HOME=""
TEST_STORAGE=""
TEST_CONFIG_DIR=""

setup_test_env() {
    TEST_TMPDIR=$(mktemp -d -t cac-integration.XXXXXXXXXX)
    chmod 700 "$TEST_TMPDIR"

    # Create fake home directory with config files
    TEST_HOME="${TEST_TMPDIR}/home"
    mkdir -p "${TEST_HOME}/.claude"
    mkdir -p "${TEST_HOME}/.codex"
    mkdir -p "${TEST_HOME}/.gemini"

    echo '{"api_key": "test-claude-key"}' > "${TEST_HOME}/.claude.json"
    echo '{"credentials": "secret123"}' > "${TEST_HOME}/.claude/.credentials.json"
    echo '{"auth_token": "codex-token"}' > "${TEST_HOME}/.codex/auth.json"
    echo '{"oauth": "gemini-oauth"}' > "${TEST_HOME}/.gemini/oauth_creds.json"

    # Create local storage directory
    TEST_STORAGE="${TEST_TMPDIR}/storage"
    mkdir -p "$TEST_STORAGE"
    chmod 700 "$TEST_STORAGE"

    # Create config directory with .env
    TEST_CONFIG_DIR="${TEST_TMPDIR}/config"
    mkdir -p "$TEST_CONFIG_DIR"
    chmod 700 "$TEST_CONFIG_DIR"

    cat > "${TEST_CONFIG_DIR}/.env" <<EOF
CAC_BACKEND=local
CAC_LOCAL_STORAGE=${TEST_STORAGE}
EOF
    chmod 600 "${TEST_CONFIG_DIR}/.env"
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
# Config Loading Tests
# ============================================================================

test_config_load_from_env() {
    # Source the config module
    source "${PROJECT_ROOT}/lib/config.sh"

    # Set config dir environment variable
    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"

    if config_load 2>/dev/null; then
        if [[ "$CAC_BACKEND" == "local" && "$CAC_LOCAL_STORAGE" == "$TEST_STORAGE" ]]; then
            unset CAC_CONFIG_DIR
            return 0
        else
            echo "Config values not loaded correctly" >&2
            unset CAC_CONFIG_DIR
            return 1
        fi
    else
        echo "config_load failed" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi
}

test_config_validate_local_backend() {
    source "${PROJECT_ROOT}/lib/config.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    if config_validate 2>/dev/null; then
        unset CAC_CONFIG_DIR
        return 0
    else
        echo "config_validate failed" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi
}

test_config_insecure_permissions_rejected() {
    source "${PROJECT_ROOT}/lib/config.sh"

    local insecure_config="${TEST_TMPDIR}/insecure_config"
    mkdir -p "$insecure_config"
    echo "CAC_BACKEND=local" > "${insecure_config}/.env"
    chmod 644 "${insecure_config}/.env"  # World-readable

    export CAC_CONFIG_DIR="$insecure_config"

    if config_load 2>/dev/null; then
        echo "Expected failure for insecure .env" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi

    unset CAC_CONFIG_DIR
    return 0
}

# ============================================================================
# Tools Module Tests
# ============================================================================

test_tools_get_files_claude() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_get_files "claude")

    if [[ "$files" == *".claude.json"* && "$files" == *".claude/.credentials.json"* ]]; then
        return 0
    else
        echo "Missing expected claude files" >&2
        return 1
    fi
}

test_tools_get_files_all() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_get_files "all")

    if [[ "$files" == *".claude.json"* && \
          "$files" == *".codex/auth.json"* && \
          "$files" == *".gemini/oauth_creds.json"* ]]; then
        return 0
    else
        echo "Missing expected files" >&2
        return 1
    fi
}

test_tools_is_valid() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    if ! tools_is_valid "claude"; then
        echo "claude should be valid" >&2
        return 1
    fi

    if ! tools_is_valid "codex"; then
        echo "codex should be valid" >&2
        return 1
    fi

    if ! tools_is_valid "all"; then
        echo "all should be valid" >&2
        return 1
    fi

    if tools_is_valid "invalid_tool"; then
        echo "invalid_tool should not be valid" >&2
        return 1
    fi

    return 0
}

test_tools_collect_existing() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_collect_existing "$TEST_HOME" "all")

    # Should find our test files
    if [[ "$files" == *".claude.json"* && \
          "$files" == *".codex/auth.json"* && \
          "$files" == *".gemini/oauth_creds.json"* ]]; then
        return 0
    else
        echo "Missing expected existing files" >&2
        return 1
    fi
}

test_tools_count_existing() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local count
    count=$(tools_count_existing "$TEST_HOME" "all")

    # We created 4 files in setup
    if [[ "$count" -ge 4 ]]; then
        return 0
    else
        echo "Expected at least 4 files, got $count" >&2
        return 1
    fi
}

# ============================================================================
# Local Backend Integration Tests
# ============================================================================

test_local_backend_push_and_list() {
    # Source all required modules
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create a bundle
    local bundle_name
    bundle_name=$(bundle_generate_filename "testuser")
    local bundle_path="${TEST_TMPDIR}/${bundle_name}"

    if ! bundle_create "$TEST_HOME" "$bundle_path" "all" >/dev/null 2>&1; then
        echo "bundle_create failed" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi

    # Upload to local storage
    if ! backend_local_upload "$bundle_path" >/dev/null 2>&1; then
        echo "backend_local_upload failed" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi

    # List bundles
    local list_output
    list_output=$(backend_local_list 2>&1)

    if [[ "$list_output" != *"testuser"* ]]; then
        echo "List output missing testuser: $list_output" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi

    unset CAC_CONFIG_DIR
    return 0
}

test_local_backend_download() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create and upload a bundle
    local bundle_name
    bundle_name=$(bundle_generate_filename "dltest")
    local bundle_path="${TEST_TMPDIR}/${bundle_name}"

    bundle_create "$TEST_HOME" "$bundle_path" "all" >/dev/null 2>&1
    backend_local_upload "$bundle_path" >/dev/null 2>&1

    # Download it
    local download_path="${TEST_TMPDIR}/downloaded.zip"

    if ! backend_local_download "$bundle_name" "$download_path" >/dev/null 2>&1; then
        echo "backend_local_download failed" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi

    if [[ ! -f "$download_path" ]]; then
        echo "Downloaded file not found" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi

    # Verify it's a valid ZIP
    if ! unzip -t "$download_path" >/dev/null 2>&1; then
        echo "Downloaded file is not a valid ZIP" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi

    unset CAC_CONFIG_DIR
    return 0
}

test_local_backend_get_newest() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create multiple bundles with different timestamps
    local bundle1="${TEST_TMPDIR}/bundle1.zip"
    local bundle2="${TEST_TMPDIR}/bundle2.zip"

    # Create first bundle
    bundle_create "$TEST_HOME" "$bundle1" "all" >/dev/null 2>&1
    sleep 1  # Ensure different timestamp
    bundle_create "$TEST_HOME" "$bundle2" "all" >/dev/null 2>&1

    # Rename to have specific timestamps for predictable ordering
    local host
    host=$(hostname -s)
    cp "$bundle1" "${TEST_STORAGE}/CodingAgentConfig_${host}_newestuser_250101-100000.zip"
    cp "$bundle2" "${TEST_STORAGE}/CodingAgentConfig_${host}_newestuser_250101-120000.zip"

    # Get newest
    local newest
    if ! newest=$(backend_local_get_newest --host "$host" --user "newestuser"); then
        echo "backend_local_get_newest failed" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi

    # Should be the one with later timestamp
    if [[ "$newest" == *"120000"* ]]; then
        unset CAC_CONFIG_DIR
        return 0
    else
        echo "Expected newest bundle with 120000, got: $newest" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi
}

test_local_backend_filter_by_host() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create bundles for different hosts
    local bundle="${TEST_TMPDIR}/host_test.zip"
    bundle_create "$TEST_HOME" "$bundle" "all" >/dev/null 2>&1

    cp "$bundle" "${TEST_STORAGE}/CodingAgentConfig_host-a_alice_250101-100000.zip"
    cp "$bundle" "${TEST_STORAGE}/CodingAgentConfig_host-b_bob_250101-100000.zip"

    # List with host filter
    local list_output
    list_output=$(backend_local_list --host "host-a" 2>&1)

    if [[ "$list_output" == *"host-a"* && "$list_output" != *"host-b"* ]]; then
        unset CAC_CONFIG_DIR
        return 0
    else
        echo "Host filter not working correctly" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi
}

test_local_backend_filter_by_user() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create bundles for different users
    local bundle="${TEST_TMPDIR}/user_test.zip"
    bundle_create "$TEST_HOME" "$bundle" "all" >/dev/null 2>&1

    cp "$bundle" "${TEST_STORAGE}/CodingAgentConfig_myhost_charlie_250101-100000.zip"
    cp "$bundle" "${TEST_STORAGE}/CodingAgentConfig_myhost_david_250101-100000.zip"

    # List with user filter
    local list_output
    list_output=$(backend_local_list --user "charlie" 2>&1)

    if [[ "$list_output" == *"charlie"* && "$list_output" != *"david"* ]]; then
        unset CAC_CONFIG_DIR
        return 0
    else
        echo "User filter not working correctly" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi
}

# ============================================================================
# Full Workflow Tests
# ============================================================================

test_full_push_pull_workflow() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    local host
    host=$(hostname -s)

    # Create a bundle and upload
    local bundle_name
    bundle_name=$(bundle_generate_filename "workflow")
    local bundle_path="${TEST_TMPDIR}/${bundle_name}"

    bundle_create "$TEST_HOME" "$bundle_path" "all" >/dev/null 2>&1
    backend_local_upload "$bundle_path" >/dev/null 2>&1

    # Create empty target home
    local target_home="${TEST_TMPDIR}/target_home"
    mkdir -p "$target_home"

    # Find and download the newest bundle
    local newest
    newest=$(backend_local_get_newest --host "$host" --user "workflow")

    local download_path="${TEST_TMPDIR}/workflow_download.zip"
    backend_local_download "$newest" "$download_path" >/dev/null 2>&1

    # Extract to target
    bundle_extract "$download_path" "$target_home" "$(whoami)" >/dev/null 2>&1

    # Verify files were restored
    if [[ -f "${target_home}/.claude.json" && \
          -f "${target_home}/.codex/auth.json" && \
          -f "${target_home}/.gemini/oauth_creds.json" ]]; then
        unset CAC_CONFIG_DIR
        return 0
    else
        echo "Restored files missing" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi
}

test_extract_preserves_content() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create bundle
    local bundle_path="${TEST_TMPDIR}/content_test.zip"
    bundle_create "$TEST_HOME" "$bundle_path" "all" >/dev/null 2>&1

    # Extract to new location
    local target_home="${TEST_TMPDIR}/content_target"
    mkdir -p "$target_home"

    bundle_extract "$bundle_path" "$target_home" "$(whoami)" >/dev/null 2>&1

    # Verify content matches
    local original_content
    local extracted_content

    original_content=$(cat "${TEST_HOME}/.claude.json")
    extracted_content=$(cat "${target_home}/.claude.json")

    if [[ "$original_content" == "$extracted_content" ]]; then
        unset CAC_CONFIG_DIR
        return 0
    else
        echo "Content mismatch after extraction" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "Integration Tests"
    echo "========================================"
    echo ""

    setup_test_env

    echo "--- Configuration ---"
    run_test "config load from env" test_config_load_from_env
    run_test "config validate local backend" test_config_validate_local_backend
    run_test "config insecure permissions rejected" test_config_insecure_permissions_rejected
    echo ""

    echo "--- Tools Module ---"
    run_test "tools_get_files claude" test_tools_get_files_claude
    run_test "tools_get_files all" test_tools_get_files_all
    run_test "tools_is_valid" test_tools_is_valid
    run_test "tools_collect_existing" test_tools_collect_existing
    run_test "tools_count_existing" test_tools_count_existing
    echo ""

    echo "--- Local Backend ---"
    run_test "push and list" test_local_backend_push_and_list
    run_test "download" test_local_backend_download
    run_test "get newest" test_local_backend_get_newest
    run_test "filter by host" test_local_backend_filter_by_host
    run_test "filter by user" test_local_backend_filter_by_user
    echo ""

    echo "--- Full Workflow ---"
    run_test "push/pull workflow" test_full_push_pull_workflow
    run_test "extract preserves content" test_extract_preserves_content
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
