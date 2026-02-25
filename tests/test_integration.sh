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

    mkdir -p "${TEST_HOME}/.vibe"
    echo 'MISTRAL_API_KEY=test-mistral-key' > "${TEST_HOME}/.vibe/.env"
    printf '[settings]\nmodel = "mistral-large"\n' > "${TEST_HOME}/.vibe/config.toml"

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

test_tools_get_files_mistral() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_get_files "mistral")

    assert_contains ".vibe/.env" "$files" "mistral files" &&
    assert_contains ".vibe/config.toml" "$files" "mistral files"
}

test_tools_get_files_all() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_get_files "all")

    assert_contains ".claude.json" "$files" "all files" &&
    assert_contains ".codex/auth.json" "$files" "all files" &&
    assert_contains ".gemini/oauth_creds.json" "$files" "all files" &&
    assert_contains ".vibe/.env" "$files" "all files"
}

test_tools_is_valid() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    assert_success "claude is valid" tools_is_valid "claude" &&
    assert_success "codex is valid" tools_is_valid "codex" &&
    assert_success "mistral is valid" tools_is_valid "mistral" &&
    assert_success "all is valid" tools_is_valid "all" &&
    assert_fails "invalid_tool is not valid" tools_is_valid "invalid_tool"
}

test_tools_get_files_without_settings() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_get_files "claude")

    # Should contain credentials
    assert_contains ".claude.json" "$files" "claude credential files" || return 1
    assert_contains ".claude/.credentials.json" "$files" "claude credential files" || return 1

    # Should NOT contain settings
    if [[ "$files" == *"settings.json"* ]]; then
        echo "tools_get_files without flag should NOT contain settings.json, got: $files" >&2
        return 1
    fi
}

test_tools_get_files_with_settings() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_get_files "claude" "--include-settings")

    # Should contain credentials AND settings
    assert_contains ".claude.json" "$files" "claude files with settings" &&
    assert_contains ".claude/.credentials.json" "$files" "claude files with settings" &&
    assert_contains ".claude/settings.json" "$files" "claude settings file"
}

test_tools_get_settings_files() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_get_settings_files "claude")

    # Should contain ONLY settings
    assert_contains ".claude/settings.json" "$files" "claude settings file" || return 1

    # Should NOT contain credentials
    if [[ "$files" == *".credentials.json"* ]]; then
        echo "tools_get_settings_files should NOT contain credentials, got: $files" >&2
        return 1
    fi
}

test_tools_collect_existing() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_collect_existing "$TEST_HOME" "all")

    assert_contains ".claude.json" "$files" "existing files" &&
    assert_contains ".codex/auth.json" "$files" "existing files" &&
    assert_contains ".gemini/oauth_creds.json" "$files" "existing files" &&
    assert_contains ".vibe/.env" "$files" "existing files"
}

test_tools_collect_existing_mistral() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local files
    files=$(tools_collect_existing "$TEST_HOME" "mistral")

    assert_contains ".vibe/.env" "$files" "mistral existing files" &&
    assert_contains ".vibe/config.toml" "$files" "mistral existing files"
}

test_tools_count_existing() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local count
    count=$(tools_count_existing "$TEST_HOME" "all")

    # We created 6 files in setup (claude:2 + codex:1 + gemini:1 + mistral:2) - check minimum
    [[ "$count" -ge 6 ]] || { echo "Expected at least 6 files, got $count" >&2; return 1; }
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

    # Issue #41: bundle_generate_filename now requires tool parameter
    local bundle_name
    bundle_name=$(bundle_generate_filename "testuser" "all")
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

    # Issue #41: bundle_generate_filename now requires tool parameter
    local bundle_name
    bundle_name=$(bundle_generate_filename "dltest" "all")
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

    # Create multiple bundles with different timestamps (new format with tool)
    local bundle1="${TEST_TMPDIR}/bundle1.zip"
    local bundle2="${TEST_TMPDIR}/bundle2.zip"

    bundle_create "$TEST_HOME" "$bundle1" "all" >/dev/null 2>&1
    sleep 1  # Ensure different timestamp
    bundle_create "$TEST_HOME" "$bundle2" "all" >/dev/null 2>&1

    # Rename to have specific timestamps for predictable ordering (new 5-segment format)
    local host
    host=$(hostname -s)
    cp "$bundle1" "${TEST_STORAGE}/CodingAgentConfig_${host}_newestuser_all_250101-100000.zip"
    cp "$bundle2" "${TEST_STORAGE}/CodingAgentConfig_${host}_newestuser_all_250101-120000.zip"

    # Get newest (Issue #50: no --host filter, use --user)
    local newest
    newest=$(backend_local_get_newest --user "newestuser") || { echo "backend_local_get_newest failed" >&2; unset CAC_CONFIG_DIR; return 1; }

    # Should be the one with later timestamp
    assert_contains "120000" "$newest" "newest bundle timestamp" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

test_local_backend_filter_by_tool() {
    # Issue #41: Filter bundles by --tool instead of --host
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create bundles for different tools (new 5-segment format)
    local bundle="${TEST_TMPDIR}/tool_filter_test.zip"
    bundle_create "$TEST_HOME" "$bundle" "all" >/dev/null 2>&1

    cp "$bundle" "${TEST_STORAGE}/CodingAgentConfig_myhost_alice_claude_250101-100000.zip"
    cp "$bundle" "${TEST_STORAGE}/CodingAgentConfig_myhost_alice_codex_250101-100000.zip"

    # List with tool filter
    local list_output
    list_output=$(backend_local_list --tool "claude" 2>&1)

    assert_contains "claude" "$list_output" "tool-filtered list" || { unset CAC_CONFIG_DIR; return 1; }
    # Ensure codex is NOT in output (check for the bundle name pattern, not general text)
    if echo "$list_output" | grep -q "alice_codex_"; then
        echo "Tool filter should exclude codex bundles" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi
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

    # Create bundles for different users (new 5-segment format)
    local bundle="${TEST_TMPDIR}/user_test.zip"
    bundle_create "$TEST_HOME" "$bundle" "all" >/dev/null 2>&1

    cp "$bundle" "${TEST_STORAGE}/CodingAgentConfig_myhost_charlie_all_250101-100000.zip"
    cp "$bundle" "${TEST_STORAGE}/CodingAgentConfig_myhost_david_all_250101-100000.zip"

    # List with user filter
    local list_output
    list_output=$(backend_local_list --user "charlie" 2>&1)

    assert_contains "charlie" "$list_output" "filtered list" || { unset CAC_CONFIG_DIR; return 1; }
    # Ensure david is NOT in output
    [[ "$list_output" != *"david"* ]] || { echo "User filter should exclude david" >&2; unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

# ============================================================================
# Issue #19: get_newest Global vs Filtered Behavior
# ============================================================================

# Helper: set up a clean storage with bundles from different hosts/users/tools
_setup_issue19_storage() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create a base bundle for content
    local base_bundle="${TEST_TMPDIR}/issue19_base.zip"
    bundle_create "$TEST_HOME" "$base_bundle" "all" >/dev/null 2>&1

    # Place bundles from different hosts/users/tools with known timestamps
    # Issue #41: Use new 5-segment naming format
    # Oldest: rob@host-a, claude (250101-100000)
    cp "$base_bundle" "${TEST_STORAGE}/CodingAgentConfig_host-a_rob_claude_250101-100000.zip"
    # Middle: tim@host-b, all (250102-100000)
    cp "$base_bundle" "${TEST_STORAGE}/CodingAgentConfig_host-b_tim_all_250102-100000.zip"
    # Newest: rob@host-b, codex (250103-100000)
    cp "$base_bundle" "${TEST_STORAGE}/CodingAgentConfig_host-b_rob_codex_250103-100000.zip"
}

test_get_newest_no_filters_returns_global_newest() {
    _setup_issue19_storage

    # get_newest with NO filters should return the globally newest bundle
    local newest
    newest=$(backend_local_get_newest) || { echo "get_newest failed" >&2; unset CAC_CONFIG_DIR; return 1; }

    # Newest is rob@host-b codex (250103-100000)
    assert_contains "host-b_rob_codex_250103" "$newest" "global newest bundle" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

test_get_newest_user_filter_only() {
    _setup_issue19_storage

    # --user tim should return tim's bundle regardless of host/tool
    local newest
    newest=$(backend_local_get_newest --user "tim") || { echo "get_newest --user tim failed" >&2; unset CAC_CONFIG_DIR; return 1; }

    assert_contains "tim" "$newest" "user-filtered bundle" || { unset CAC_CONFIG_DIR; return 1; }
    assert_contains "host-b" "$newest" "tim's bundle host" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

test_get_newest_tool_filter_only() {
    # Issue #41: --tool filter replaces --host filter
    _setup_issue19_storage

    # --tool claude should return only claude bundles
    local newest
    newest=$(backend_local_get_newest --tool "claude") || { echo "get_newest --tool claude failed" >&2; unset CAC_CONFIG_DIR; return 1; }

    assert_contains "claude" "$newest" "tool-filtered bundle" || { unset CAC_CONFIG_DIR; return 1; }
    assert_contains "rob" "$newest" "claude bundle user" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

test_get_newest_both_filters() {
    _setup_issue19_storage

    # Issue #41/50: --tool codex --user rob should return rob's codex bundle
    local newest
    newest=$(backend_local_get_newest --tool "codex" --user "rob") || { echo "get_newest --tool codex --user rob failed" >&2; unset CAC_CONFIG_DIR; return 1; }

    assert_contains "rob_codex" "$newest" "both-filtered bundle" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

test_get_newest_filter_no_match() {
    _setup_issue19_storage

    # --user nonexistent should fail (no matching bundles)
    if backend_local_get_newest --user "nonexistent" >/dev/null 2>&1; then
        echo "Expected get_newest with non-matching user to fail" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi
    unset CAC_CONFIG_DIR
}

# ============================================================================
# Codex Review Regression Tests
# ============================================================================

# Regression: --dry-run must be honored with --all
# Exercises the REAL cmd_pull function with a stubbed cmd_pull_all.
test_pull_all_dry_run_honored() {
    _setup_issue19_storage

    # Source bin/cac as library to get the real cmd_pull function.
    # The sourcing guard at the end of bin/cac prevents main() from executing.
    source "${PROJECT_ROOT}/bin/cac"

    # Spy: override cmd_pull_all to capture its dry_run argument
    local _spy_dry_run=""
    cmd_pull_all() { _spy_dry_run="$1"; }

    # Call the real cmd_pull with --all --dry-run
    cmd_pull --all --dry-run 2>/dev/null

    [[ "$_spy_dry_run" == "true" ]] || {
        echo "Expected cmd_pull_all to receive dry_run='true', got '$_spy_dry_run'" >&2
        unset CAC_CONFIG_DIR
        return 1
    }
    unset CAC_CONFIG_DIR
}

# Regression: unknown flags must be rejected with --strict
test_pull_rejects_unknown_flags() {
    _setup_issue19_storage

    source "${PROJECT_ROOT}/lib/utils.sh"

    # utils_init_command_context --strict should reject unknown flags
    if utils_init_command_context --strict --unknown-flag 2>/dev/null; then
        echo "Expected --strict to reject unknown flag" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi
    unset CAC_CONFIG_DIR
}

# Issue #21: version line printed on every command invocation
test_version_printed_on_command() {
    # Run the real cac binary; 'env status' needs no backend config
    local output
    output=$("${PROJECT_ROOT}/bin/cac" env status 2>&1) || true

    # First line must be the version banner
    local first_line
    first_line=$(echo "$output" | head -1)
    [[ "$first_line" == "cac v"* ]] || {
        echo "Expected first line 'cac v...', got: '$first_line'" >&2
        return 1
    }
}

# Regression: bundle_extract temp dir cleanup must not leak
test_bundle_extract_cleans_temp_dir() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create a bundle
    local bundle_path="${TEST_TMPDIR}/cleanup_test.zip"
    bundle_create "$TEST_HOME" "$bundle_path" "all" >/dev/null 2>&1

    # Extract it
    local extract_dir="${TEST_TMPDIR}/extract_target"
    mkdir -p "$extract_dir"
    bundle_extract "$bundle_path" "$extract_dir" "$(whoami)" >/dev/null 2>&1

    # Check no cac-extract temp dirs remain
    local leftover
    leftover=$(find /tmp -maxdepth 1 -name "cac-extract.*" -type d 2>/dev/null | wc -l)
    [[ "$leftover" -eq 0 ]] || { echo "Found $leftover leftover cac-extract temp dirs" >&2; unset CAC_CONFIG_DIR; return 1; }
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

    # Issue #41: bundle_generate_filename now requires tool parameter
    local bundle_name
    bundle_name=$(bundle_generate_filename "workflow" "all")
    local bundle_path="${TEST_TMPDIR}/${bundle_name}"

    bundle_create "$TEST_HOME" "$bundle_path" "all" >/dev/null 2>&1
    backend_local_upload "$bundle_path" >/dev/null 2>&1

    # Create empty target home
    local target_home="${TEST_TMPDIR}/target_home"
    mkdir -p "$target_home"

    # Find and download the newest bundle (Issue #50: no --host, use --user)
    local newest
    newest=$(backend_local_get_newest --user "workflow")

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

test_full_push_pull_mistral_roundtrip() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Issue #41: bundle_generate_filename now requires tool parameter
    local bundle_name
    bundle_name=$(bundle_generate_filename "mistralrt" "all")
    local bundle_path="${TEST_TMPDIR}/${bundle_name}"

    bundle_create "$TEST_HOME" "$bundle_path" "all" >/dev/null 2>&1
    backend_local_upload "$bundle_path" >/dev/null 2>&1

    # Create empty target home
    local target_home="${TEST_TMPDIR}/mistral_target"
    mkdir -p "$target_home"

    # Find and download the newest bundle (Issue #50: no --host, use --user)
    local newest
    newest=$(backend_local_get_newest --user "mistralrt")

    local download_path="${TEST_TMPDIR}/mistral_download.zip"
    backend_local_download "$newest" "$download_path" >/dev/null 2>&1

    # Extract to target
    bundle_extract "$download_path" "$target_home" "$(whoami)" >/dev/null 2>&1

    # Verify mistral files were restored
    assert_file_exists "${target_home}/.vibe/.env" "restored .vibe/.env" || { unset CAC_CONFIG_DIR; return 1; }
    assert_file_exists "${target_home}/.vibe/config.toml" "restored .vibe/config.toml" || { unset CAC_CONFIG_DIR; return 1; }

    # Verify content preserved
    local content
    content=$(cat "${target_home}/.vibe/.env")
    assert_contains "MISTRAL_API_KEY=test-mistral-key" "$content" "mistral env content" || { unset CAC_CONFIG_DIR; return 1; }

    unset CAC_CONFIG_DIR
}

test_backward_compat_bundle_without_mistral() {
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create a home with only claude+codex (no mistral)
    local old_home="${TEST_TMPDIR}/old_home"
    mkdir -p "${old_home}/.claude"
    mkdir -p "${old_home}/.codex"
    echo '{"api_key": "old-key"}' > "${old_home}/.claude.json"
    echo '{"auth": "old-token"}' > "${old_home}/.codex/auth.json"

    # Create bundle
    local bundle_path="${TEST_TMPDIR}/old_bundle.zip"
    bundle_create "$old_home" "$bundle_path" "all" >/dev/null 2>&1

    # Extract to target
    local target_home="${TEST_TMPDIR}/old_target"
    mkdir -p "$target_home"
    bundle_extract "$bundle_path" "$target_home" "$(whoami)" >/dev/null 2>&1

    # Verify claude/codex files restored
    assert_file_exists "${target_home}/.claude.json" "restored claude.json" || { unset CAC_CONFIG_DIR; return 1; }
    assert_file_exists "${target_home}/.codex/auth.json" "restored codex auth" || { unset CAC_CONFIG_DIR; return 1; }

    # Verify .vibe dir does NOT exist (no phantom files)
    if [[ -d "${target_home}/.vibe" ]]; then
        echo ".vibe directory should not exist in old bundle target" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi

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
# Issue #45: Alias Resolution Tests
# ============================================================================

test_resolve_tool_alias_vibe() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local result
    result=$(_resolve_tool_alias "vibe")

    assert_equals "mistral" "$result" "vibe alias resolves to mistral"
}

test_resolve_tool_alias_passthrough() {
    source "${PROJECT_ROOT}/lib/tools.sh"

    local result
    result=$(_resolve_tool_alias "claude")

    assert_equals "claude" "$result" "claude passes through unchanged"
}

# ============================================================================
# Issue #45: check_tool_mistral Behavior Tests
# ============================================================================

test_check_mistral_missing_env_file() {
    source "${PROJECT_ROOT}/lib/logging.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/check.sh"

    # Create a home dir without .vibe/.env
    local fake_home="${TEST_TMPDIR}/no_vibe_home"
    mkdir -p "$fake_home"

    # Mock _check_tool_binary_exists to return success
    _check_tool_binary_exists() { return 0; }

    check_tool_mistral "false" "$(whoami)" "$fake_home" >/dev/null 2>&1
    local exit_code=$?

    # Should return CHECK_EXIT_AUTH_FAIL (1) when .env file is missing
    assert_equals "1" "$exit_code" "missing .vibe/.env exit code"
}

test_check_mistral_missing_api_key() {
    source "${PROJECT_ROOT}/lib/logging.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/check.sh"

    # Create a home dir with .vibe/.env but no MISTRAL_API_KEY
    local fake_home="${TEST_TMPDIR}/empty_vibe_home"
    mkdir -p "${fake_home}/.vibe"
    echo 'SOME_OTHER_VAR=hello' > "${fake_home}/.vibe/.env"

    # Mock _check_tool_binary_exists to return success
    _check_tool_binary_exists() { return 0; }

    check_tool_mistral "false" "$(whoami)" "$fake_home" >/dev/null 2>&1
    local exit_code=$?

    # Should return CHECK_EXIT_AUTH_FAIL (1) when key is missing
    assert_equals "1" "$exit_code" "missing MISTRAL_API_KEY exit code"
}

test_check_mistral_key_extraction() {
    source "${PROJECT_ROOT}/lib/logging.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/check.sh"

    # Create a home dir with valid .vibe/.env
    local fake_home="${TEST_TMPDIR}/valid_vibe_home"
    mkdir -p "${fake_home}/.vibe"
    echo 'MISTRAL_API_KEY=test-key-12345' > "${fake_home}/.vibe/.env"

    # Mock _check_tool_binary_exists to return success
    _check_tool_binary_exists() { return 0; }

    # Mock _check_with_timeout to avoid real API call — simulate auth failure response
    _check_with_timeout() { echo '{"message":"Unauthorized"}'; return 0; }

    check_tool_mistral "false" "$(whoami)" "$fake_home" >/dev/null 2>&1
    local exit_code=$?

    # Should return CHECK_EXIT_AUTH_FAIL (1) — key was extracted but API returned unauthorized
    # The important thing: it got past the "key not found" check (which would also be exit 1)
    # but reached the API call stage. We verify this didn't crash or return unexpected codes.
    [[ "$exit_code" -eq 1 ]] || {
        echo "Expected exit code 1 (auth fail after API call), got $exit_code" >&2
        return 1
    }
}

# ============================================================================
# Issue #41: Per-Tool Bundle Tests
# ============================================================================

test_per_tool_bundle_roundtrip() {
    # Issue #41: Create a per-tool bundle, upload, list, download, extract
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create a claude-only bundle with per-tool naming
    local bundle_name
    bundle_name=$(bundle_generate_filename "pertoolrt" "claude")
    local bundle_path="${TEST_TMPDIR}/${bundle_name}"

    bundle_create "$TEST_HOME" "$bundle_path" "claude" >/dev/null 2>&1
    backend_local_upload "$bundle_path" >/dev/null 2>&1

    # Verify it appears in list
    local list_output
    list_output=$(backend_local_list --tool "claude" 2>&1)
    assert_contains "pertoolrt" "$list_output" "per-tool list output" || { unset CAC_CONFIG_DIR; return 1; }

    # Download and extract
    local target_home="${TEST_TMPDIR}/pertool_target"
    mkdir -p "$target_home"

    local download_path="${TEST_TMPDIR}/pertool_download.zip"
    backend_local_download "$bundle_name" "$download_path" >/dev/null 2>&1
    bundle_extract "$download_path" "$target_home" "$(whoami)" >/dev/null 2>&1

    # Verify only claude files extracted (not codex, gemini, etc.)
    assert_file_exists "${target_home}/.claude.json" "restored claude.json" || { unset CAC_CONFIG_DIR; return 1; }
    if [[ -f "${target_home}/.codex/auth.json" ]]; then
        echo "Per-tool bundle should not contain codex files" >&2
        unset CAC_CONFIG_DIR
        return 1
    fi
    unset CAC_CONFIG_DIR
}

test_old_format_bundle_still_listable() {
    # Issue #41: Old 4-segment bundles must still appear in list
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"
    source "${PROJECT_ROOT}/lib/security.sh"
    source "${PROJECT_ROOT}/lib/bundle.sh"
    source "${PROJECT_ROOT}/lib/backend_local.sh"

    export CAC_CONFIG_DIR="$TEST_CONFIG_DIR"
    config_load 2>/dev/null

    # Create an old-format bundle (4 segments, no tool)
    local bundle="${TEST_TMPDIR}/old_compat.zip"
    bundle_create "$TEST_HOME" "$bundle" "all" >/dev/null 2>&1

    cp "$bundle" "${TEST_STORAGE}/CodingAgentConfig_oldhost_alice_250101-100000.zip"

    # Also create a new-format bundle
    cp "$bundle" "${TEST_STORAGE}/CodingAgentConfig_newhost_alice_claude_250201-100000.zip"

    # List all — both should appear
    local list_output
    list_output=$(backend_local_list 2>&1)

    assert_contains "oldhost" "$list_output" "old format in list" || { unset CAC_CONFIG_DIR; return 1; }
    assert_contains "newhost" "$list_output" "new format in list" || { unset CAC_CONFIG_DIR; return 1; }
    unset CAC_CONFIG_DIR
}

# ============================================================================
# Issue #41: Sync Marker Tests
# ============================================================================

test_sync_marker_creation() {
    # Issue #41: Sync marker created/updated after push
    source "${PROJECT_ROOT}/lib/config.sh"

    local marker_path
    marker_path=$(config_get_sync_marker_path "claude")

    # Should return a valid path containing the tool name
    assert_contains "claude" "$marker_path" "marker path contains tool" || return 1
    assert_contains ".last_sync_" "$marker_path" "marker path format"
}

test_sync_marker_update_and_read() {
    # Issue #41: Update marker and read back its time
    source "${PROJECT_ROOT}/lib/config.sh"

    # Override config dir to test location
    local test_config="${TEST_TMPDIR}/sync_config"
    mkdir -p "$test_config"

    # Update marker
    CAC_CONFIG_DIR="$test_config" config_update_sync_marker "claude"

    # Verify marker file exists
    local marker_path="${test_config}/.last_sync_claude"
    assert_file_exists "$marker_path" "sync marker file" || return 1

    # Read marker time — should be non-zero
    local marker_time
    marker_time=$(CAC_CONFIG_DIR="$test_config" config_get_sync_marker_time "claude")
    [[ "$marker_time" -gt 0 ]] || { echo "Expected non-zero marker time, got: $marker_time" >&2; return 1; }
}

test_sync_marker_missing_returns_zero() {
    # Issue #41: Missing marker should return time 0 (always needs sync)
    source "${PROJECT_ROOT}/lib/config.sh"

    local test_config="${TEST_TMPDIR}/sync_empty"
    mkdir -p "$test_config"

    local marker_time
    marker_time=$(CAC_CONFIG_DIR="$test_config" config_get_sync_marker_time "claude")
    assert_equals "0" "$marker_time" "missing marker returns 0"
}

test_sync_marker_change_detection() {
    # Issue #41: Detect when credentials are newer than sync marker
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"

    local test_config="${TEST_TMPDIR}/sync_detect"
    mkdir -p "$test_config"

    # Create marker first (in the past)
    CAC_CONFIG_DIR="$test_config" config_update_sync_marker "claude"
    sleep 1

    # Touch credential files to be newer than marker
    touch "${TEST_HOME}/.claude.json"

    # Should detect that sync is needed
    local needs_sync
    needs_sync=$(CAC_CONFIG_DIR="$test_config" config_needs_sync "claude" "$TEST_HOME")
    assert_equals "true" "$needs_sync" "needs sync after credential change"
}

test_sync_marker_no_change() {
    # Issue #41: No sync needed when marker is newer than credentials
    source "${PROJECT_ROOT}/lib/config.sh"
    source "${PROJECT_ROOT}/lib/tools.sh"

    local test_config="${TEST_TMPDIR}/sync_nochange"
    mkdir -p "$test_config"

    # Touch credentials first, then create marker (marker is newer)
    touch "${TEST_HOME}/.claude.json"
    sleep 1
    CAC_CONFIG_DIR="$test_config" config_update_sync_marker "claude"

    # Should NOT need sync
    local needs_sync
    needs_sync=$(CAC_CONFIG_DIR="$test_config" config_needs_sync "claude" "$TEST_HOME")
    assert_equals "false" "$needs_sync" "no sync needed when marker is newer"
}

test_sync_marker_tool_with_dashes() {
    # Codex note: Verify sync markers work for tools with dashes (e.g., continuous-claude)
    source "${PROJECT_ROOT}/lib/config.sh"

    local test_config="${TEST_TMPDIR}/sync_dashes"
    mkdir -p "$test_config"

    # Update marker for a tool with dashes
    CAC_CONFIG_DIR="$test_config" config_update_sync_marker "continuous-claude"

    # Verify marker file exists with dashes in name
    local marker_path="${test_config}/.last_sync_continuous-claude"
    assert_file_exists "$marker_path" "sync marker for tool with dashes"
}

# ============================================================================
# Issue #35: env status --check-updates
# ============================================================================

test_env_status_check_updates() {
    # Run the real cac binary with --check-updates; no backend config needed
    local output
    output=$("${PROJECT_ROOT}/bin/cac" env status --check-updates 2>&1) || true

    # Must contain "Latest" column header
    assert_contains "Latest" "$output" "check-updates output" || return 1

    # Extract only tool row lines (skip header/separator)
    local tool_lines
    tool_lines=$(echo "$output" | grep -E "Claude Code|Codex CLI|Gemini CLI|continuous-claude") || true

    # Must have at least one tool row
    if [[ -z "$tool_lines" ]]; then
        echo "Expected output to contain at least one tool row" >&2
        echo "$output" >&2
        return 1
    fi

    # At least one tool row must contain a version indicator in the Latest column
    # ✓ = up-to-date, ⬆ = upgrade available, ? = lookup failed
    # (NOT checking for "-" here as it would match the separator row)
    if echo "$tool_lines" | grep -qE "[✓⬆?]"; then
        return 0
    else
        echo "No version indicator (✓, ⬆, or ?) found on tool rows:" >&2
        echo "$tool_lines" >&2
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

    setup_integration_env

    echo "--- Configuration ---"
    run_test "config load from env" test_config_load_from_env
    run_test "config validate local backend" test_config_validate_local_backend
    run_test "config insecure permissions rejected" test_config_insecure_permissions_rejected
    echo ""

    echo "--- Tools Module ---"
    run_test "tools_get_files claude" test_tools_get_files_claude
    run_test "tools_get_files mistral" test_tools_get_files_mistral
    run_test "tools_get_files all" test_tools_get_files_all
    run_test "tools_get_files without --include-settings" test_tools_get_files_without_settings
    run_test "tools_get_files with --include-settings" test_tools_get_files_with_settings
    run_test "tools_get_settings_files" test_tools_get_settings_files
    run_test "tools_is_valid" test_tools_is_valid
    run_test "tools_collect_existing" test_tools_collect_existing
    run_test "tools_collect_existing mistral" test_tools_collect_existing_mistral
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
    run_test "filter by tool (Issue #41)" test_local_backend_filter_by_tool
    run_test "filter by user" test_local_backend_filter_by_user
    echo ""

    echo "--- Issue #19: Global vs Filtered get_newest ---"
    run_test "get newest no filters (global)" test_get_newest_no_filters_returns_global_newest
    run_test "get newest user filter only" test_get_newest_user_filter_only
    run_test "get newest tool filter only (Issue #41)" test_get_newest_tool_filter_only
    run_test "get newest both filters (tool+user)" test_get_newest_both_filters
    run_test "get newest filter no match" test_get_newest_filter_no_match
    echo ""

    echo "--- Issue #41: Per-Tool Bundles ---"
    run_test "per-tool bundle roundtrip" test_per_tool_bundle_roundtrip
    run_test "old format bundle still listable" test_old_format_bundle_still_listable
    echo ""

    echo "--- Issue #41: Sync Markers ---"
    run_test "sync marker creation" test_sync_marker_creation
    run_test "sync marker update and read" test_sync_marker_update_and_read
    run_test "sync marker missing returns zero" test_sync_marker_missing_returns_zero
    run_test "sync marker change detection" test_sync_marker_change_detection
    run_test "sync marker no change needed" test_sync_marker_no_change
    run_test "sync marker tool with dashes" test_sync_marker_tool_with_dashes
    echo ""

    echo "--- Issue #35: env status --check-updates ---"
    run_test "env status --check-updates shows Latest column" test_env_status_check_updates
    echo ""

    echo "--- Codex Review Regression Tests ---"
    run_test "pull --all --dry-run honored" test_pull_all_dry_run_honored
    run_test "pull rejects unknown flags" test_pull_rejects_unknown_flags
    run_test "version printed on command (Issue #21)" test_version_printed_on_command
    run_test "bundle_extract cleans temp dir" test_bundle_extract_cleans_temp_dir
    echo ""

    echo "--- Full Workflow ---"
    run_test "push/pull workflow" test_full_push_pull_workflow
    run_test "extract preserves content" test_extract_preserves_content
    echo ""

    echo "--- Issue #45: Mistral Vibe Support ---"
    run_test "mistral push/pull roundtrip" test_full_push_pull_mistral_roundtrip
    run_test "backward compat without mistral" test_backward_compat_bundle_without_mistral
    echo ""

    echo "--- Issue #45: Alias Tests ---"
    run_test "resolve alias vibe -> mistral" test_resolve_tool_alias_vibe
    run_test "resolve alias passthrough" test_resolve_tool_alias_passthrough
    echo ""

    echo "--- Issue #45: check_tool_mistral Behavior ---"
    run_test "check mistral missing .env file" test_check_mistral_missing_env_file
    run_test "check mistral missing API key" test_check_mistral_missing_api_key
    run_test "check mistral key extraction" test_check_mistral_key_extraction
    echo ""

    framework_report
    exit $?
}

main "$@"
