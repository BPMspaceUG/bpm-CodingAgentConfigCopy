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
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source shared test framework
source "${SCRIPT_DIR}/test_framework.sh"

# Check for required dependencies
framework_require_commands zip unzip

# Additional test directory paths (set by setup_integration_env)
TEST_HOME=""
TEST_STORAGE=""
TEST_CONFIG_DIR=""

# Override the default framework setup with integration-specific setup
setup_integration_env() {
    # Call the base framework init to create TEST_TMPDIR
    framework_init

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

# ============================================================================
# Config Loading Tests
# ============================================================================

test_config_load_from_env() {
    source "${PROJECT_ROOT}/lib/config.sh"
    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"

    assert_success "config_load" config_load || { unset CAC_CONFIG_DIR; return 1; }
    assert_equals "local" "$CAC_BACKEND" "CAC_BACKEND" || { unset CAC_CONFIG_DIR; return 1; }
    assert_equals "$TEST_STORAGE" "$CAC_LOCAL_STORAGE" "CAC_LOCAL_STORAGE" || { unset CAC_CONFIG_DIR; return 1; }

    unset CAC_CONFIG_DIR
}

test_config_validate_local_backend() {
    source "${PROJECT_ROOT}/lib/config.sh"
    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    assert_success "config_validate" config_validate || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

test_config_insecure_permissions_rejected() {
    source "${PROJECT_ROOT}/lib/config.sh"

    local insecure_config="${TEST_TMPDIR}/insecure_config"
    mkdir -p "$insecure_config"
    echo "CAC_BACKEND=local" > "${insecure_config}/.env"
    chmod 644 "${insecure_config}/.env"  # World-readable

    export CAC_CONFIG_DIR="$insecure_config"
    assert_fails "insecure .env should be rejected" config_load || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

# ============================================================================
# Tools Module Tests
# ============================================================================

test_tools_get_files_claude() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_get_files "claude")

    assert_contains ".claude.json" "$files" "claude files" &&
    assert_contains ".claude/.credentials.json" "$files" "claude files"
}

test_tools_get_files_all() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_get_files "all")

    assert_contains ".claude.json" "$files" "all files" &&
    assert_contains ".codex/auth.json" "$files" "all files" &&
    assert_contains ".gemini/oauth_creds.json" "$files" "all files"
}

test_tools_is_valid() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    assert_success "claude is valid" tools_is_valid "claude" &&
    assert_success "codex is valid" tools_is_valid "codex" &&
    assert_success "all is valid" tools_is_valid "all" &&
    assert_fails "invalid_tool is not valid" tools_is_valid "invalid_tool"
}

test_tools_collect_existing() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_collect_existing "$TEST_HOME" "all")

    assert_contains ".claude.json" "$files" "existing files" &&
    assert_contains ".codex/auth.json" "$files" "existing files" &&
    assert_contains ".gemini/oauth_creds.json" "$files" "existing files"
}

test_tools_count_existing() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local count
    count=$(tools_count_existing "$TEST_HOME" "all")

    # We created 4 files in setup - check minimum
    [[ "$count" -ge 4 ]] || { echo "Expected at least 4 files, got $count" >&2; return 1; }
}

# ============================================================================
# Local Backend Internal Utility Tests
# ============================================================================

test_local_find_bundle_exact_match() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create a test bundle
    local test_bundle="${TEST_STORAGE}/CodingAgentConfig_findtest_alice_250101-100000.zip"
    echo "test" | zip -q "$test_bundle" -

    # Test exact filename match
    local result
    result=$(_local_find_bundle_file "$TEST_STORAGE" "CodingAgentConfig_findtest_alice_250101-100000.zip")

    assert_equals "$test_bundle" "$result" "exact match result" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

test_local_find_bundle_partial_match() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create a test bundle
    local test_bundle="${TEST_STORAGE}/CodingAgentConfig_partialtest_bob_250102-100000.zip"
    echo "test" | zip -q "$test_bundle" -

    # Test partial match
    local result
    result=$(_local_find_bundle_file "$TEST_STORAGE" "partialtest_bob")

    assert_equals "$test_bundle" "$result" "partial match result" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

test_local_find_bundle_not_found() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Search for non-existent bundle - should return 1 (not found)
    _local_find_bundle_file "$TEST_STORAGE" "nonexistent_xyz123" >/dev/null 2>&1
    local ret=$?

    assert_equals "1" "$ret" "not found return code" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

test_local_find_bundle_multiple_matches() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create multiple matching bundles
    echo "test1" | zip -q "${TEST_STORAGE}/CodingAgentConfig_multitest_user1_250101-100000.zip" -
    echo "test2" | zip -q "${TEST_STORAGE}/CodingAgentConfig_multitest_user2_250101-110000.zip" -

    # Search for ambiguous pattern - should return 2 (multiple matches)
    _local_find_bundle_file "$TEST_STORAGE" "multitest" >/dev/null 2>&1
    local ret=$?

    assert_equals "2" "$ret" "multiple matches return code" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

test_local_list_bundle_files_sorted() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create bundles with different modification times
    local bundle1="${TEST_STORAGE}/CodingAgentConfig_listtest_user1_250101-090000.zip"
    local bundle2="${TEST_STORAGE}/CodingAgentConfig_listtest_user2_250101-100000.zip"

    echo "old" | zip -q "$bundle1" -
    sleep 1
    echo "new" | zip -q "$bundle2" -

    # List should return newest first
    local result
    result=$(_local_list_bundle_files "$TEST_STORAGE" | head -1)

    assert_equals "$bundle2" "$result" "newest bundle first" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

# ============================================================================
# Local Backend Integration Tests
# ============================================================================

test_local_backend_push_and_list() {
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

    assert_success "bundle_create" bundle_create "$TEST_HOME" "$bundle_path" "all" || { unset CAC_CONFIG_DIR; return 1; }
    assert_success "backend_local_upload" backend_local_upload "$bundle_path" || { unset CAC_CONFIG_DIR; return 1; }

    # List bundles and verify output
    local list_output
    list_output=$(backend_local_list 2>&1)

    assert_contains "testuser" "$list_output" "list output" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
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

    assert_success "backend_local_download" backend_local_download "$bundle_name" "$download_path" || { unset CAC_CONFIG_DIR; return 1; }
    assert_file_exists "$download_path" "downloaded file" || { unset CAC_CONFIG_DIR; return 1; }
    assert_success "unzip validation" unzip -t "$download_path" || { unset CAC_CONFIG_DIR; return 1; }

    unset CAC_CONFIG_DIR
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
    newest=$(backend_local_get_newest --host "$host" --user "newestuser") || { echo "backend_local_get_newest failed" >&2; unset CAC_CONFIG_DIR; return 1; }

    # Should be the one with later timestamp
    assert_contains "120000" "$newest" "newest bundle timestamp" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
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

    assert_contains "host-a" "$list_output" "filtered list" || { unset CAC_CONFIG_DIR; return 1; }
    # Ensure host-b is NOT in output
    [[ "$list_output" != *"host-b"* ]] || { echo "Host filter should exclude host-b" >&2; unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
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

    assert_contains "charlie" "$list_output" "filtered list" || { unset CAC_CONFIG_DIR; return 1; }
    # Ensure david is NOT in output
    [[ "$list_output" != *"david"* ]] || { echo "User filter should exclude david" >&2; unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
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
    assert_file_exists "${target_home}/.claude.json" "restored claude.json" || { unset CAC_CONFIG_DIR; return 1; }
    assert_file_exists "${target_home}/.codex/auth.json" "restored codex auth" || { unset CAC_CONFIG_DIR; return 1; }
    assert_file_exists "${target_home}/.gemini/oauth_creds.json" "restored gemini oauth" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
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
    local original_content extracted_content
    original_content=$(cat "${TEST_HOME}/.claude.json")
    extracted_content=$(cat "${target_home}/.claude.json")

    assert_equals "$original_content" "$extracted_content" "file content" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "Integration Tests"
    echo "========================================"
    echo ""

    setup_integration_env

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

    echo "--- Local Backend Utilities ---"
    run_test "find bundle exact match" test_local_find_bundle_exact_match
    run_test "find bundle partial match" test_local_find_bundle_partial_match
    run_test "find bundle not found" test_local_find_bundle_not_found
    run_test "find bundle multiple matches" test_local_find_bundle_multiple_matches
    run_test "list bundle files sorted" test_local_list_bundle_files_sorted
    echo ""

    echo "--- Local Backend Operations ---"
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

    framework_report
    exit $?
}

main "$@"
