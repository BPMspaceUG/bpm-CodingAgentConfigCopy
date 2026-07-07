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
    filename=$(bundle_generate_filename "testuser" "claude")

    # Issue #41: New format: CodingAgentConfig_<HOST>_<USER>_<TOOL>_<YYMMDD-HHMMSS>.zip
    assert_match '^CodingAgentConfig_[^_]+_testuser_claude_[0-9]{6}-[0-9]{6}\.zip$' \
        "$filename" "filename format"
}

test_bundle_generate_filename_default_user() {
    local filename
    filename=$(bundle_generate_filename "" "all")

    # Should contain current user
    assert_contains "_${USER}_" "$filename" "filename"
}

test_bundle_generate_filename_with_tool() {
    # Issue #41: Per-tool bundle naming
    local filename
    filename=$(bundle_generate_filename "bob" "codex")

    assert_match '^CodingAgentConfig_[^_]+_bob_codex_[0-9]{6}-[0-9]{6}\.zip$' \
        "$filename" "per-tool filename format"
}

test_bundle_generate_filename_all_tool() {
    # Issue #41: "all" tool creates monolithic bundle
    local filename
    filename=$(bundle_generate_filename "alice" "all")

    assert_match '^CodingAgentConfig_[^_]+_alice_all_[0-9]{6}-[0-9]{6}\.zip$' \
        "$filename" "all-tool filename format"
}

test_bundle_parse_filename_valid() {
    # Issue #41: Old 4-segment format still parses, tool defaults to "all"
    local result
    result=$(bundle_parse_filename "CodingAgentConfig_myhost_ubuntu_250111-143022.zip")

    assert_equals "myhost ubuntu all 250111-143022" "$result" "parsed result (old format)"
}

test_bundle_parse_filename_new_format() {
    # Issue #41: New 5-segment format with tool field
    local result
    result=$(bundle_parse_filename "CodingAgentConfig_myhost_ubuntu_claude_250111-143022.zip")

    assert_equals "myhost ubuntu claude 250111-143022" "$result" "parsed result (new format)"
}

test_bundle_parse_filename_new_format_various_tools() {
    # Issue #41: Verify parsing works for all known tools
    local result

    result=$(bundle_parse_filename "CodingAgentConfig_srv1_bob_codex_250201-090000.zip")
    assert_equals "srv1 bob codex 250201-090000" "$result" "codex parse" || return 1

    result=$(bundle_parse_filename "CodingAgentConfig_srv1_bob_gemini_250201-090000.zip")
    assert_equals "srv1 bob gemini 250201-090000" "$result" "gemini parse" || return 1

    result=$(bundle_parse_filename "CodingAgentConfig_srv1_bob_mistral_250201-090000.zip")
    assert_equals "srv1 bob mistral 250201-090000" "$result" "mistral parse" || return 1

    result=$(bundle_parse_filename "CodingAgentConfig_srv1_bob_all_250201-090000.zip")
    assert_equals "srv1 bob all 250201-090000" "$result" "all parse"
}

test_bundle_parse_filename_invalid() {
    # Should fail for invalid format
    assert_fails "parse invalid filename" bundle_parse_filename "invalid_filename.zip"
}

test_bundle_parse_filename_old_format_backward_compat() {
    # Issue #41: Ensure old monolithic filenames without TOOL segment still work
    # These have exactly 4 segments: PREFIX_HOST_USER_TIMESTAMP
    local result

    result=$(bundle_parse_filename "CodingAgentConfig_prod-server_alice_250115-180000.zip")
    assert_equals "prod-server alice all 250115-180000" "$result" "old format backward compat" || return 1

    # Verify the tool field is "all" for old format
    local tool
    tool=$(bundle_get_tool "CodingAgentConfig_prod-server_alice_250115-180000.zip")
    assert_equals "all" "$tool" "old format tool defaults to all"
}

test_bundle_parse_filename_ambiguous_old_format() {
    # Codex note: Test old 4-segment names where host or user could look like a tool name
    # e.g., hostname "claude" or username "codex" — these should parse as old format
    local result

    # Host named "claude" — old format: PREFIX_claude_bob_TIMESTAMP
    result=$(bundle_parse_filename "CodingAgentConfig_claude_bob_250115-180000.zip")
    assert_equals "claude bob all 250115-180000" "$result" "host named claude (old format)" || return 1

    # User named "codex" — old format: PREFIX_myhost_codex_TIMESTAMP
    result=$(bundle_parse_filename "CodingAgentConfig_myhost_codex_250115-180000.zip")
    assert_equals "myhost codex all 250115-180000" "$result" "user named codex (old format)"
}

test_bundle_get_host() {
    # Test with new format
    local host
    host=$(bundle_get_host "CodingAgentConfig_prod-server_bob_claude_250111-120000.zip")
    assert_equals "prod-server" "$host" "host (new format)" || return 1

    # Test with old format
    host=$(bundle_get_host "CodingAgentConfig_prod-server_bob_250111-120000.zip")
    assert_equals "prod-server" "$host" "host (old format)"
}

test_bundle_get_user() {
    # Test with new format
    local user
    user=$(bundle_get_user "CodingAgentConfig_prod-server_bob_claude_250111-120000.zip")
    assert_equals "bob" "$user" "user (new format)" || return 1

    # Test with old format
    user=$(bundle_get_user "CodingAgentConfig_prod-server_bob_250111-120000.zip")
    assert_equals "bob" "$user" "user (old format)"
}

test_bundle_get_tool() {
    # Issue #41: New accessor for tool field
    local tool

    tool=$(bundle_get_tool "CodingAgentConfig_srv1_alice_claude_250201-100000.zip")
    assert_equals "claude" "$tool" "tool from new format" || return 1

    tool=$(bundle_get_tool "CodingAgentConfig_srv1_alice_250201-100000.zip")
    assert_equals "all" "$tool" "tool from old format defaults to all"
}

test_bundle_get_timestamp() {
    # Test with new format
    local ts
    ts=$(bundle_get_timestamp "CodingAgentConfig_prod-server_bob_claude_250111-120000.zip")
    assert_equals "250111-120000" "$ts" "timestamp (new format)" || return 1

    # Test with old format
    ts=$(bundle_get_timestamp "CodingAgentConfig_prod-server_bob_250111-120000.zip")
    assert_equals "250111-120000" "$ts" "timestamp (old format)"
}

test_bundle_generate_filename_rejects_username_with_underscore() {
    # Should fail when username contains underscore (conflicts with delimiter)
    assert_fails "username with underscore" bundle_generate_filename "test_user" "claude"
}

test_bundle_generate_filename_rejects_hostname_with_underscore() {
    # Create a mock hostname function that returns hostname with underscore
    hostname() { echo "my_server"; }
    export -f hostname

    # Should fail when hostname contains underscore
    assert_fails "hostname with underscore" bundle_generate_filename "validuser" "claude"

    # Restore hostname
    unset -f hostname
}

test_bundle_generate_filename_rejects_tool_with_underscore() {
    # Issue #41: Tool name must not contain underscores
    assert_fails "tool with underscore" bundle_generate_filename "validuser" "my_tool"
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
# Issue #46: Settings Extraction Guard Tests
# ============================================================================

test_bundle_create_includes_settings() {
    local fake_home="${TEST_TMPDIR}/settings_home"
    local output_zip="${TEST_TMPDIR}/settings_output.zip"

    # Create fake home with credential AND settings files
    mkdir -p "${fake_home}/.claude"
    echo '{"test": true}' > "${fake_home}/.claude.json"
    echo '{"creds": "secret"}' > "${fake_home}/.claude/.credentials.json"
    echo '{"teammateMode": "tmux"}' > "${fake_home}/.claude/settings.json"

    # Create bundle (bundle_create always includes settings)
    assert_success "bundle_create with settings" bundle_create "$fake_home" "$output_zip" "all"

    # Verify ZIP contains settings file
    local contents
    contents=$(unzip -Z1 "$output_zip")

    assert_contains ".claude/settings.json" "$contents" "ZIP contents"
}

test_bundle_extract_settings_host_match() {
    local current_host
    current_host=$(hostname -s)
    local current_user
    current_user=$(whoami)

    local fake_home="${TEST_TMPDIR}/settings_match_src"
    local target_home="${TEST_TMPDIR}/settings_match_dst"

    # Create source home with settings
    mkdir -p "${fake_home}/.claude"
    echo '{"test": true}' > "${fake_home}/.claude.json"
    echo '{"teammateMode": "tmux"}' > "${fake_home}/.claude/settings.json"

    # Create bundle with matching host+user in OLD filename format (backward compat)
    local bundle_zip="${TEST_TMPDIR}/CodingAgentConfig_${current_host}_${current_user}_250101-100000.zip"
    (cd "$fake_home" && zip -q "$bundle_zip" .claude.json .claude/settings.json)

    # Create target home
    mkdir -p "$target_home"

    # Extract — host+user match, settings should be extracted
    bundle_extract "$bundle_zip" "$target_home" "$current_user" >/dev/null 2>&1

    assert_file_exists "${target_home}/.claude/settings.json" "settings.json should be extracted on match (old format)"
}

test_bundle_extract_settings_host_match_new_format() {
    # Issue #41: Settings extraction also works with new 5-segment format
    local current_host
    current_host=$(hostname -s)
    local current_user
    current_user=$(whoami)

    local fake_home="${TEST_TMPDIR}/settings_match_new_src"
    local target_home="${TEST_TMPDIR}/settings_match_new_dst"

    # Create source home with settings
    mkdir -p "${fake_home}/.claude"
    echo '{"test": true}' > "${fake_home}/.claude.json"
    echo '{"teammateMode": "tmux"}' > "${fake_home}/.claude/settings.json"

    # Create bundle with matching host+user in NEW filename format
    local bundle_zip="${TEST_TMPDIR}/CodingAgentConfig_${current_host}_${current_user}_claude_250101-100000.zip"
    (cd "$fake_home" && zip -q "$bundle_zip" .claude.json .claude/settings.json)

    # Create target home
    mkdir -p "$target_home"

    # Extract — host+user match, settings should be extracted
    bundle_extract "$bundle_zip" "$target_home" "$current_user" >/dev/null 2>&1

    assert_file_exists "${target_home}/.claude/settings.json" "settings.json should be extracted on match (new format)"
}

test_bundle_extract_settings_lost_with_generic_filename() {
    # Issue #46 regression test: proves that using a generic filename like
    # "bundle.zip" (the old download path in utils_download_and_extract) causes
    # settings to never be extracted, even when host+user should match.
    local current_host
    current_host=$(hostname -s)
    local current_user
    current_user=$(whoami)

    local fake_home="${TEST_TMPDIR}/settings_generic_src"
    local target_home="${TEST_TMPDIR}/settings_generic_dst"

    # Create source home with settings
    mkdir -p "${fake_home}/.claude"
    echo '{"test": true}' > "${fake_home}/.claude.json"
    echo '{"teammateMode": "tmux"}' > "${fake_home}/.claude/settings.json"

    # Create bundle with GENERIC filename (simulating the old bug)
    local bundle_zip="${TEST_TMPDIR}/bundle.zip"
    (cd "$fake_home" && zip -q "$bundle_zip" .claude.json .claude/settings.json)

    # Create target home
    mkdir -p "$target_home"

    # Extract — filename has no host/user metadata, so settings should be SKIPPED
    local output
    output=$(bundle_extract "$bundle_zip" "$target_home" "$current_user" 2>&1)

    # Credential file should still be extracted
    assert_file_exists "${target_home}/.claude.json" "credential file extracted"

    # Settings file should NOT be extracted because bundle_get_host returns ""
    if [[ -f "${target_home}/.claude/settings.json" ]]; then
        echo "settings.json should NOT be extracted with generic filename 'bundle.zip'" >&2
        return 1
    fi

    # Now verify that the SAME content with a proper filename DOES extract settings
    local target_home2="${TEST_TMPDIR}/settings_generic_dst2"
    mkdir -p "$target_home2"

    local proper_zip="${TEST_TMPDIR}/CodingAgentConfig_${current_host}_${current_user}_250101-120000.zip"
    cp "$bundle_zip" "$proper_zip"

    bundle_extract "$proper_zip" "$target_home2" "$current_user" >/dev/null 2>&1

    assert_file_exists "${target_home2}/.claude/settings.json" \
        "settings.json SHOULD be extracted with proper bundle filename"
}

test_bundle_extract_settings_host_mismatch() {
    local current_user
    current_user=$(whoami)

    local fake_home="${TEST_TMPDIR}/settings_mismatch_src"
    local target_home="${TEST_TMPDIR}/settings_mismatch_dst"

    # Create source home with settings
    mkdir -p "${fake_home}/.claude"
    echo '{"test": true}' > "${fake_home}/.claude.json"
    echo '{"teammateMode": "tmux"}' > "${fake_home}/.claude/settings.json"

    # Create bundle with DIFFERENT host in filename
    local bundle_zip="${TEST_TMPDIR}/CodingAgentConfig_otherhost_${current_user}_250101-100000.zip"
    (cd "$fake_home" && zip -q "$bundle_zip" .claude.json .claude/settings.json)

    # Create target home
    mkdir -p "$target_home"

    # Extract — host mismatch, settings should be SKIPPED
    local output
    output=$(bundle_extract "$bundle_zip" "$target_home" "$current_user" 2>&1)

    # Credential file should be extracted
    assert_file_exists "${target_home}/.claude.json" "credential file should be extracted"

    # Settings file should NOT be extracted
    if [[ -f "${target_home}/.claude/settings.json" ]]; then
        echo "settings.json should NOT be extracted on host mismatch" >&2
        return 1
    fi

    # Output should mention skipping
    assert_contains "skipped (host-specific)" "$output" "skip message"
}

# ============================================================================
# Issue #76: bundle_extract tool-filter argument (legacy _all_ read-fallback)
# ============================================================================

# Build a combined (_all_) bundle containing claude + codex + gemini files.
_make_all_bundle() {
    local src_home="$1" bundle_zip="$2"
    mkdir -p "${src_home}/.claude" "${src_home}/.codex" "${src_home}/.gemini"
    echo '{"m":"claude"}'  > "${src_home}/.claude.json"
    echo '{"m":"creds"}'   > "${src_home}/.claude/.credentials.json"
    echo '{"m":"codex"}'   > "${src_home}/.codex/auth.json"
    echo '{"m":"gemini"}'  > "${src_home}/.gemini/oauth_creds.json"
    ( cd "$src_home" && zip -q "$bundle_zip" \
        .claude.json .claude/.credentials.json .codex/auth.json .gemini/oauth_creds.json )
}

# B.1 [anti-bug]: tool-filtered extract installs only that tool's files.
test_bundle_extract_tool_filter_claude_only() {
    local src="${TEST_TMPDIR}/bf_src" dst="${TEST_TMPDIR}/bf_dst"
    local zip="${TEST_TMPDIR}/CodingAgentConfig_HOSTA_$(whoami)_all_250101-100000.zip"
    mkdir -p "$dst"
    _make_all_bundle "$src" "$zip"

    assert_success "filtered extract" bundle_extract "$zip" "$dst" "$(whoami)" "claude"
    assert_file_exists "${dst}/.claude.json" "claude extracted" || return 1
    assert_file_exists "${dst}/.claude/.credentials.json" "claude creds extracted" || return 1
    if [[ -f "${dst}/.codex/auth.json" ]]; then echo "codex leaked past filter"; return 1; fi
    if [[ -f "${dst}/.gemini/oauth_creds.json" ]]; then echo "gemini leaked past filter"; return 1; fi
    return 0
}

# B.2 [sentinel]: no filter arg -> everything installed (back-compat).
test_bundle_extract_no_filter_installs_all() {
    local src="${TEST_TMPDIR}/bf2_src" dst="${TEST_TMPDIR}/bf2_dst"
    local zip="${TEST_TMPDIR}/CodingAgentConfig_HOSTA_$(whoami)_all_250101-100000.zip"
    mkdir -p "$dst"
    _make_all_bundle "$src" "$zip"

    assert_success "unfiltered extract" bundle_extract "$zip" "$dst" "$(whoami)"
    assert_file_exists "${dst}/.claude.json" "claude extracted" || return 1
    assert_file_exists "${dst}/.codex/auth.json" "codex extracted" || return 1
    assert_file_exists "${dst}/.gemini/oauth_creds.json" "gemini extracted"
}

# B.3: filtered extract still skips host-specific settings on host mismatch.
test_bundle_extract_tool_filter_settings_gated() {
    local src="${TEST_TMPDIR}/bf3_src" dst="${TEST_TMPDIR}/bf3_dst"
    # HOSTA != current host -> settings must be skipped even when in the filter set
    local zip="${TEST_TMPDIR}/CodingAgentConfig_HOSTA_$(whoami)_all_250101-100000.zip"
    mkdir -p "$dst" "${src}/.claude"
    echo '{"m":"claude"}' > "${src}/.claude.json"
    echo '{"teammateMode":"tmux"}' > "${src}/.claude/settings.json"
    ( cd "$src" && zip -q "$zip" .claude.json .claude/settings.json )

    local output
    output=$(bundle_extract "$zip" "$dst" "$(whoami)" "claude" 2>&1)
    assert_file_exists "${dst}/.claude.json" "claude extracted" || return 1
    if [[ -f "${dst}/.claude/settings.json" ]]; then echo "settings extracted on host mismatch"; return 1; fi
    assert_contains "skipped (host-specific)" "$output" "settings skip message"
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
    run_test "bundle_generate_filename with tool" test_bundle_generate_filename_with_tool
    run_test "bundle_generate_filename all tool" test_bundle_generate_filename_all_tool
    run_test "bundle_generate_filename rejects username with underscore" test_bundle_generate_filename_rejects_username_with_underscore
    run_test "bundle_generate_filename rejects hostname with underscore" test_bundle_generate_filename_rejects_hostname_with_underscore
    run_test "bundle_generate_filename rejects tool with underscore" test_bundle_generate_filename_rejects_tool_with_underscore
    run_test "bundle_parse_filename valid (old format)" test_bundle_parse_filename_valid
    run_test "bundle_parse_filename new format" test_bundle_parse_filename_new_format
    run_test "bundle_parse_filename new format various tools" test_bundle_parse_filename_new_format_various_tools
    run_test "bundle_parse_filename invalid" test_bundle_parse_filename_invalid
    run_test "bundle_parse_filename old format backward compat" test_bundle_parse_filename_old_format_backward_compat
    run_test "bundle_parse_filename ambiguous old format" test_bundle_parse_filename_ambiguous_old_format
    run_test "bundle_get_host" test_bundle_get_host
    run_test "bundle_get_user" test_bundle_get_user
    run_test "bundle_get_tool" test_bundle_get_tool
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

    echo "--- Issue #46: Settings Extraction Guard ---"
    run_test "bundle_create includes settings" test_bundle_create_includes_settings
    run_test "bundle_extract settings on host match" test_bundle_extract_settings_host_match
    run_test "bundle_extract settings on host match (new format)" test_bundle_extract_settings_host_match_new_format
    run_test "bundle_extract settings lost with generic filename" test_bundle_extract_settings_lost_with_generic_filename
    run_test "bundle_extract settings skipped on host mismatch" test_bundle_extract_settings_host_mismatch
    echo ""

    echo "--- Mistral Bundle Tests (Issue #45) ---"
    run_test "bundle_create with mistral files" test_bundle_create_with_mistral_files
    run_test "bundle_create mistral only" test_bundle_create_mistral_only
    run_test "bundle_extract mistral permissions" test_bundle_extract_mistral_permissions
    echo ""

    echo "--- Issue #76: bundle_extract tool filter ---"
    run_test "bundle_extract tool filter (claude only)" test_bundle_extract_tool_filter_claude_only
    run_test "bundle_extract no filter installs all" test_bundle_extract_no_filter_installs_all
    run_test "bundle_extract tool filter settings gated" test_bundle_extract_tool_filter_settings_gated
    echo ""

    framework_report
    exit $?
}

main "$@"
