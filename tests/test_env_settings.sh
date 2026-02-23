#!/usr/bin/env bash
# tests/test_env_settings.sh - Tests for Claude Code settings.json merge (Issues #39, #40)
#
# Run with: ./tests/test_env_settings.sh
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

# Source library module under test
source "${PROJECT_ROOT}/lib/env.sh"

# Initialize test framework (creates TEST_TMPDIR)
framework_init

# ============================================================================
# Helper
# ============================================================================

# Read a JSON key using python3
_json_get() {
    local file="$1"
    local key_path="$2"
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
keys = sys.argv[2].split('.')
for k in keys:
    d = d[k]
print(d)
" "$file" "$key_path"
}

# ============================================================================
# Tests: _env_write_claude_settings
# ============================================================================

test_settings_create_new_file() {
    local settings_file="${TEST_TMPDIR}/create_new/.claude/settings.json"

    _env_write_claude_settings '{"env":{"KEY":"1"}}' "$settings_file"

    # File should exist
    [[ -f "$settings_file" ]] || { fail "settings file not created"; return 1; }

    # Content should be valid JSON with the key
    local val
    val=$(_json_get "$settings_file" "env.KEY")
    assert_equals "1" "$val" "new file env.KEY value"
}

test_settings_file_permissions() {
    local settings_file="${TEST_TMPDIR}/perms/.claude/settings.json"

    _env_write_claude_settings '{"foo":"bar"}' "$settings_file"

    local perms
    perms=$(stat -c '%a' "$settings_file")
    assert_equals "600" "$perms" "settings.json permissions"
}

test_settings_merge_existing() {
    local settings_dir="${TEST_TMPDIR}/merge/.claude"
    local settings_file="${settings_dir}/settings.json"
    mkdir -p "$settings_dir"

    # Create existing file with some content
    echo '{"existing":"value","env":{"OLD_KEY":"old"}}' > "$settings_file"
    chmod 600 "$settings_file"

    # Merge new content
    _env_write_claude_settings '{"env":{"NEW_KEY":"new"}}' "$settings_file"

    # Existing keys should be preserved
    local existing_val old_val new_val
    existing_val=$(_json_get "$settings_file" "existing")
    old_val=$(_json_get "$settings_file" "env.OLD_KEY")
    new_val=$(_json_get "$settings_file" "env.NEW_KEY")

    assert_equals "value" "$existing_val" "existing key preserved"
    assert_equals "old" "$old_val" "nested existing key preserved"
    assert_equals "new" "$new_val" "new key merged"
}

test_settings_deep_merge_replaces_non_dict() {
    local settings_dir="${TEST_TMPDIR}/replace/.claude"
    local settings_file="${settings_dir}/settings.json"
    mkdir -p "$settings_dir"

    # Existing file with a string value
    echo '{"teammateMode":"old","env":{"K":"v"}}' > "$settings_file"
    chmod 600 "$settings_file"

    # Merge with replacement value
    _env_write_claude_settings '{"teammateMode":"tmux"}' "$settings_file"

    local val
    val=$(_json_get "$settings_file" "teammateMode")
    assert_equals "tmux" "$val" "teammateMode replaced"

    # env should be untouched
    local env_val
    env_val=$(_json_get "$settings_file" "env.K")
    assert_equals "v" "$env_val" "env preserved during replace"
}

test_settings_invalid_json_skips_merge() {
    local settings_dir="${TEST_TMPDIR}/invalid/.claude"
    local settings_file="${settings_dir}/settings.json"
    mkdir -p "$settings_dir"

    # Create file with invalid JSON
    echo 'NOT VALID JSON{{{' > "$settings_file"
    chmod 600 "$settings_file"
    local original_content
    original_content=$(cat "$settings_file")

    # Merge should fail but NOT overwrite
    if _env_write_claude_settings '{"key":"val"}' "$settings_file" 2>/dev/null; then
        fail "should return non-zero for invalid JSON"
        return 1
    fi

    # Original content should be preserved
    local after_content
    after_content=$(cat "$settings_file")
    assert_equals "$original_content" "$after_content" "invalid JSON file preserved"
}

test_settings_non_object_root_recreates() {
    local settings_dir="${TEST_TMPDIR}/nonobj/.claude"
    local settings_file="${settings_dir}/settings.json"
    mkdir -p "$settings_dir"

    # Create file with array root (valid JSON but not an object)
    echo '["not","an","object"]' > "$settings_file"
    chmod 600 "$settings_file"

    # Merge should succeed by recreating as object
    _env_write_claude_settings '{"key":"val"}' "$settings_file" 2>/dev/null

    local val
    val=$(_json_get "$settings_file" "key")
    assert_equals "val" "$val" "recreated with correct content"
}

test_settings_array_replace_not_concat() {
    local settings_dir="${TEST_TMPDIR}/array/.claude"
    local settings_file="${settings_dir}/settings.json"
    mkdir -p "$settings_dir"

    # Create file with an array value
    echo '{"items":["a","b"]}' > "$settings_file"
    chmod 600 "$settings_file"

    # Merge should replace the array, not append
    _env_write_claude_settings '{"items":["c"]}' "$settings_file"

    local count
    count=$(python3 -c "
import json
with open('$settings_file') as f:
    d = json.load(f)
print(len(d['items']))
")
    assert_equals "1" "$count" "array replaced (not concatenated)"
}

# ============================================================================
# Tests: _env_configure_claude_settings
# ============================================================================

test_configure_always_sets_agent_teams() {
    # Override HOME to use test dir
    local orig_home="$HOME"
    export HOME="${TEST_TMPDIR}/configure_teams"
    mkdir -p "${HOME}/.claude"

    _env_configure_claude_settings "false" 2>/dev/null

    local val
    val=$(_json_get "${HOME}/.claude/settings.json" "env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS")
    assert_equals "1" "$val" "agent teams always enabled"

    export HOME="$orig_home"
}

test_configure_tmux_sets_teammate_mode() {
    # Only run if tmux is available
    if ! command -v tmux &>/dev/null; then
        skip "tmux not installed"
        return 0
    fi

    local orig_home="$HOME"
    export HOME="${TEST_TMPDIR}/configure_tmux"
    mkdir -p "${HOME}/.claude"

    _env_configure_claude_settings "true" 2>/dev/null

    local val
    val=$(_json_get "${HOME}/.claude/settings.json" "teammateMode")
    assert_equals "tmux" "$val" "teammateMode set to tmux"

    # Agent teams should also be set
    local teams_val
    teams_val=$(_json_get "${HOME}/.claude/settings.json" "env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS")
    assert_equals "1" "$teams_val" "agent teams also set with --tmux"

    export HOME="$orig_home"
}

# ============================================================================
# Tests: --tmux flag parsing
# ============================================================================

test_parse_tmux_flag() {
    _env_parse_scope_args --tmux
    assert_equals "true" "$ENV_PARSED_TMUX" "--tmux parsed"
}

test_parse_tmux_with_tool() {
    _env_parse_scope_args claude --tmux
    assert_equals "true" "$ENV_PARSED_TMUX" "--tmux with tool"
    assert_equals "claude" "${ENV_PARSED_TOOLS[0]}" "tool parsed with --tmux"
}

test_parse_no_tmux_default() {
    _env_parse_scope_args claude
    assert_equals "false" "$ENV_PARSED_TMUX" "default tmux is false"
}

# ============================================================================
# Run all tests
# ============================================================================

echo "========================================"
echo "Environment Settings Tests (Issues #39, #40)"
echo "========================================"
echo ""

echo "--- Settings JSON Merge ---"
run_test "create new settings file" test_settings_create_new_file
run_test "settings file has 600 permissions" test_settings_file_permissions
run_test "merge with existing file preserves keys" test_settings_merge_existing
run_test "deep merge replaces non-dict values" test_settings_deep_merge_replaces_non_dict
run_test "invalid JSON skips merge preserves file" test_settings_invalid_json_skips_merge
run_test "non-object root recreates file" test_settings_non_object_root_recreates
run_test "array values replaced not concatenated" test_settings_array_replace_not_concat

echo ""
echo "--- Configure Claude Settings ---"
run_test "always sets agent teams env var" test_configure_always_sets_agent_teams
run_test "tmux flag sets teammateMode" test_configure_tmux_sets_teammate_mode

echo ""
echo "--- Flag Parsing ---"
run_test "--tmux flag parsed" test_parse_tmux_flag
run_test "--tmux with tool argument" test_parse_tmux_with_tool
run_test "default tmux is false" test_parse_no_tmux_default

echo ""
framework_report
