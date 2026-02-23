#!/usr/bin/env bash
# tests/test_bundle.sh - Bundle creation/extraction tests
#
# Run with: ./tests/test_bundle.sh
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

# Check for required dependencies
framework_require_commands zip unzip

# Source library modules
source "${PROJECT_ROOT}/lib/tools.sh"
source "${PROJECT_ROOT}/lib/security.sh"
source "${PROJECT_ROOT}/lib/bundle.sh"

# ============================================================================
# Bundle Filename Tests
# ============================================================================

test_bundle_generate_filename_format() {
    local filename
    filename=$(bundle_generate_filename "testuser")

    # Should match pattern: CodingAgentConfig_<host>_testuser_<YYMMDD-HHMMSS>.zip
    assert_match '^CodingAgentConfig_[^_]+_testuser_[0-9]{6}-[0-9]{6}\.zip$' \
        "$filename" "filename format"
}

test_bundle_generate_filename_default_user() {
    local filename
    filename=$(bundle_generate_filename)

    # Should contain current user
    assert_contains "_${USER}_" "$filename" "filename"
}

test_bundle_parse_filename_valid() {
    local result
    result=$(bundle_parse_filename "CodingAgentConfig_myhost_ubuntu_250111-143022.zip")

    assert_equals "myhost ubuntu 250111-143022" "$result" "parsed result"
}

test_bundle_parse_filename_invalid() {
    # Should fail for invalid format
    assert_fails "parse invalid filename" bundle_parse_filename "invalid_filename.zip"
}

test_bundle_get_host() {
    local host
    host=$(bundle_get_host "CodingAgentConfig_prod-server_bob_250111-120000.zip")

    assert_equals "prod-server" "$host" "host"
}

test_bundle_get_user() {
    local user
    user=$(bundle_get_user "CodingAgentConfig_prod-server_bob_250111-120000.zip")

    assert_equals "bob" "$user" "user"
}

test_bundle_get_timestamp() {
    local ts
    ts=$(bundle_get_timestamp "CodingAgentConfig_prod-server_bob_250111-120000.zip")

    assert_equals "250111-120000" "$ts" "timestamp"
}

test_bundle_generate_filename_rejects_username_with_underscore() {
    # Should fail when username contains underscore (conflicts with delimiter)
    assert_fails "username with underscore" bundle_generate_filename "test_user"
}

test_bundle_generate_filename_rejects_hostname_with_underscore() {
    # Create a mock hostname function that returns hostname with underscore
    hostname() { echo "my_server"; }
    export -f hostname

    # Should fail when hostname contains underscore
    assert_fails "hostname with underscore" bundle_generate_filename "validuser"

    # Restore hostname
    unset -f hostname
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
    assert_success "bundle_create" bundle_create "$fake_home" "$output_zip" "all"

    # Verify ZIP was created
    assert_file_exists "$output_zip" "output ZIP"

    # Verify ZIP contains expected files
    local contents
    contents=$(unzip -Z1 "$output_zip")

    assert_contains ".claude.json" "$contents" "ZIP contents"
    assert_contains ".claude/.credentials.json" "$contents" "ZIP contents"
    assert_contains ".codex/auth.json" "$contents" "ZIP contents"
}

test_bundle_create_empty_fails() {
    local fake_home="${TEST_TMPDIR}/empty_home"
    local output_zip="${TEST_TMPDIR}/empty.zip"

    mkdir -p "$fake_home"

    # Should fail when no config files exist
    assert_fails "bundle_create with empty home" bundle_create "$fake_home" "$output_zip" "all"
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
    assert_success "bundle_create claude only" bundle_create "$fake_home" "$output_zip" "claude"

    # Verify ZIP contains only claude files
    local contents
    contents=$(unzip -Z1 "$output_zip")

    assert_contains ".claude.json" "$contents" "ZIP contents"

    # Should NOT contain codex files
    if [[ "$contents" == *".codex"* ]]; then
        echo "ZIP should not contain .codex files, got: $contents" >&2
        return 1
    fi
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
    assert_success "bundle_extract" bundle_extract "$bundle_zip" "$target_home" "$(whoami)"

    # Verify files were extracted
    assert_file_exists "${target_home}/.claude.json" "extracted .claude.json"
    assert_file_exists "${target_home}/.claude/.credentials.json" "extracted .credentials.json"

    # Verify content
    local content
    content=$(cat "${target_home}/.claude.json")
    assert_equals '{"original": true}' "$content" "extracted content"
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

    assert_contains ".claude.json" "$output" "list_contents output"
}

test_bundle_list_contents_nonexistent() {
    # Should fail for non-existent file
    assert_fails "list_contents nonexistent" bundle_list_contents "/nonexistent/file.zip"
}

# ============================================================================
# Mistral Bundle Tests (Issue #45)
# ============================================================================

test_bundle_create_with_mistral_files() {
    local fake_home="${TEST_TMPDIR}/mistral_home"
    local output_zip="${TEST_TMPDIR}/mistral_output.zip"

    # Create fake home with mistral config files
    mkdir -p "${fake_home}/.vibe"
    echo 'MISTRAL_API_KEY=test-key' > "${fake_home}/.vibe/.env"
    printf '[settings]\nmodel = "mistral-large"\n' > "${fake_home}/.vibe/config.toml"

    # Create bundle
    assert_success "bundle_create mistral" bundle_create "$fake_home" "$output_zip" "mistral"

    # Verify ZIP was created
    assert_file_exists "$output_zip" "output ZIP"

    # Verify ZIP contains expected files
    local contents
    contents=$(unzip -Z1 "$output_zip")

    assert_contains ".vibe/.env" "$contents" "ZIP contents" &&
    assert_contains ".vibe/config.toml" "$contents" "ZIP contents"
}

test_bundle_create_mistral_only() {
    local fake_home="${TEST_TMPDIR}/mistral_only_home"
    local output_zip="${TEST_TMPDIR}/mistral_only.zip"

    # Create fake home with both claude AND mistral configs
    mkdir -p "${fake_home}/.claude"
    mkdir -p "${fake_home}/.vibe"
    echo '{"test": true}' > "${fake_home}/.claude.json"
    echo 'MISTRAL_API_KEY=test-key' > "${fake_home}/.vibe/.env"
    printf '[settings]\nmodel = "mistral-large"\n' > "${fake_home}/.vibe/config.toml"

    # Create bundle for mistral only
    assert_success "bundle_create mistral only" bundle_create "$fake_home" "$output_zip" "mistral"

    # Verify ZIP contains only mistral files
    local contents
    contents=$(unzip -Z1 "$output_zip")

    assert_contains ".vibe/.env" "$contents" "ZIP contents"

    # Should NOT contain claude files
    if [[ "$contents" == *".claude"* ]]; then
        echo "ZIP should not contain .claude files, got: $contents" >&2
        return 1
    fi
}

test_bundle_extract_mistral_permissions() {
    local fake_home="${TEST_TMPDIR}/mistral_perm_src"
    local target_home="${TEST_TMPDIR}/mistral_perm_dst"
    local bundle_zip="${TEST_TMPDIR}/mistral_perm.zip"

    # Create source home with mistral config
    mkdir -p "${fake_home}/.vibe"
    echo 'MISTRAL_API_KEY=test-key' > "${fake_home}/.vibe/.env"
    printf '[settings]\nmodel = "mistral-large"\n' > "${fake_home}/.vibe/config.toml"

    # Create target home
    mkdir -p "$target_home"

    # Create and extract bundle
    bundle_create "$fake_home" "$bundle_zip" "mistral" >/dev/null 2>&1
    bundle_extract "$bundle_zip" "$target_home" "$(whoami)" >/dev/null 2>&1

    # Verify files exist
    assert_file_exists "${target_home}/.vibe/.env" "extracted .vibe/.env" &&
    assert_file_exists "${target_home}/.vibe/config.toml" "extracted .vibe/config.toml" || return 1

    # Verify 600 permissions
    local env_perms toml_perms
    env_perms=$(stat -c '%a' "${target_home}/.vibe/.env")
    toml_perms=$(stat -c '%a' "${target_home}/.vibe/config.toml")

    assert_equals "600" "$env_perms" ".vibe/.env permissions" &&
    assert_equals "600" "$toml_perms" ".vibe/config.toml permissions"
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "Bundle Module Tests"
    echo "========================================"
    echo ""

    framework_init

    echo "--- Filename Generation/Parsing ---"
    run_test "bundle_generate_filename format" test_bundle_generate_filename_format
    run_test "bundle_generate_filename default user" test_bundle_generate_filename_default_user
    run_test "bundle_generate_filename rejects username with underscore" test_bundle_generate_filename_rejects_username_with_underscore
    run_test "bundle_generate_filename rejects hostname with underscore" test_bundle_generate_filename_rejects_hostname_with_underscore
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

    echo "--- Mistral Bundle Tests (Issue #45) ---"
    run_test "bundle_create with mistral files" test_bundle_create_with_mistral_files
    run_test "bundle_create mistral only" test_bundle_create_mistral_only
    run_test "bundle_extract mistral permissions" test_bundle_extract_mistral_permissions
    echo ""

    framework_report
    exit $?
}

main "$@"
