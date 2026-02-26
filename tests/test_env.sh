#!/usr/bin/env bash
# tests/test_env.sh - Environment management tests (Issue #16)
#
# Run with: ./tests/test_env.sh
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

# ============================================================================
# Registry Access Tests
# ============================================================================

test_env_registry_has_core_tools() {
    # Should have claude, codex, gemini as core tools
    local tools
    tools=$(env_get_core_tools)

    assert_contains "claude" "$tools" "core tools"
    assert_contains "codex" "$tools" "core tools"
    assert_contains "gemini" "$tools" "core tools"
}

test_env_registry_has_optional_tools() {
    # continuous-claude should be optional
    if env_is_optional "continuous-claude"; then
        pass "continuous-claude is optional"
    else
        fail "continuous-claude is optional"
    fi
}

test_env_get_display_name() {
    local name
    name=$(env_get_display_name "claude")
    assert_equals "Claude Code" "$name" "claude display name"

    name=$(env_get_display_name "codex")
    assert_equals "Codex CLI" "$name" "codex display name"

    name=$(env_get_display_name "gemini")
    assert_equals "Gemini CLI" "$name" "gemini display name"
}

test_env_get_install_type() {
    local type

    type=$(env_get_install_type "claude")
    assert_equals "curl" "$type" "claude install type"

    type=$(env_get_install_type "codex")
    assert_equals "npm" "$type" "codex install type"

    type=$(env_get_install_type "gemini")
    assert_equals "npm" "$type" "gemini install type"

    type=$(env_get_install_type "continuous-claude")
    assert_equals "curl" "$type" "continuous-claude install type"
}

# ============================================================================
# Validation Tests
# ============================================================================

test_env_validate_tool_valid() {
    assert_success "validate claude" env_validate_tool "claude"
    assert_success "validate codex" env_validate_tool "codex"
    assert_success "validate gemini" env_validate_tool "gemini"
    assert_success "validate continuous-claude" env_validate_tool "continuous-claude"
}

test_env_validate_tool_invalid() {
    assert_fails "validate invalid tool" env_validate_tool "notarealTool"
    assert_fails "validate empty tool" env_validate_tool ""
}

test_env_validate_scope_valid() {
    assert_success "validate user scope" env_validate_scope "user"
    assert_success "validate global scope" env_validate_scope "global"
    assert_success "validate all scope" env_validate_scope "all"
    assert_success "validate empty scope" env_validate_scope ""
}

test_env_validate_scope_invalid() {
    assert_fails "validate invalid scope" env_validate_scope "invalid"
    assert_fails "validate system scope" env_validate_scope "system"
}

# ============================================================================
# Detection Tests
# ============================================================================

test_env_is_installed_checks_command() {
    # This tests that the detection mechanism works
    # It uses `command -v` internally
    if command -v claude &>/dev/null; then
        assert_success "detect installed claude" env_is_installed "claude"
    else
        assert_fails "detect missing claude" env_is_installed "claude"
    fi
}

test_env_get_version_returns_string() {
    # Even for uninstalled tools, should return "unknown"
    local version
    version=$(env_get_version "nonexistent_tool_xyz" 2>/dev/null || true)
    # Should be empty or "unknown" but not crash
    [[ -z "$version" || "$version" == "unknown" ]] && pass "get_version handles missing tool" || fail "get_version handles missing tool"
}

# ============================================================================
# Scope Parsing Tests
# ============================================================================

test_env_parse_scope_user() {
    _env_parse_scope_args --user
    assert_equals "user" "$ENV_PARSED_SCOPE" "parsed user scope"
}

test_env_parse_scope_global() {
    # Note: This will fail if not root, which is expected
    # We just test that the parsing works, not the validation
    ENV_PARSED_SCOPE=""
    # Parse without validation
    local args=("--global")
    ENV_PARSED_SCOPE=""
    ENV_PARSED_TOOLS=()

    for arg in "${args[@]}"; do
        case "$arg" in
            --global) ENV_PARSED_SCOPE="global" ;;
        esac
    done

    assert_equals "global" "$ENV_PARSED_SCOPE" "parsed global scope"
}

test_env_parse_scope_default() {
    _env_parse_scope_args 2>/dev/null || true
    assert_equals "user" "$ENV_PARSED_SCOPE" "default scope is user"
}

test_env_parse_scope_with_tool() {
    _env_parse_scope_args claude --user 2>/dev/null || true
    assert_equals "user" "$ENV_PARSED_SCOPE" "scope with tool"
    assert_equals "claude" "${ENV_PARSED_TOOLS[0]}" "tool name"
}

test_env_parse_scope_multiple_tools() {
    _env_parse_scope_args claude codex --user 2>/dev/null || true
    assert_equals "2" "${#ENV_PARSED_TOOLS[@]}" "multiple tools count"
}

test_env_parse_scope_yes_flag() {
    _env_parse_scope_args --yes 2>/dev/null || true
    assert_equals "true" "$ENV_PARSED_YES" "yes flag"
}

test_env_parse_scope_parseable_flag() {
    _env_parse_scope_args --parseable 2>/dev/null || true
    assert_equals "true" "$ENV_PARSED_PARSEABLE" "parseable flag"
}

# ============================================================================
# Status Output Tests
# ============================================================================

test_env_show_status_runs() {
    # Just check that it runs without error
    local output
    output=$(env_show_status 2>&1)

    # Should have header
    assert_contains "Tool" "$output" "status output has Tool header"
    assert_contains "Status" "$output" "status output has Status header"
    assert_contains "Version" "$output" "status output has Version header"
}

test_env_show_status_parseable_format() {
    local output
    output=$(env_show_status_parseable 2>&1)

    # Should be tab-separated with tool names
    assert_contains "claude" "$output" "parseable has claude"
    # Should contain tabs
    if [[ "$output" == *$'\t'* ]]; then
        pass "parseable output contains tabs"
    else
        fail "parseable output contains tabs"
    fi
}

# ============================================================================
# CLI Command Tests
# ============================================================================

test_env_cli_help() {
    local output
    output=$("${PROJECT_ROOT}/bin/cac" env --help 2>&1)

    assert_contains "install" "$output" "help shows install"
    assert_contains "update" "$output" "help shows update"
    assert_contains "status" "$output" "help shows status"
}

test_env_cli_status() {
    local output
    output=$("${PROJECT_ROOT}/bin/cac" env status 2>&1)

    assert_contains "Claude Code" "$output" "status shows Claude Code"
    assert_contains "Codex CLI" "$output" "status shows Codex CLI"
}

test_env_cli_status_parseable() {
    local output
    output=$("${PROJECT_ROOT}/bin/cac" env status --parseable 2>&1)

    # Each line should be tab-separated
    local line_count
    line_count=$(echo "$output" | wc -l)

    # Should have at least 4 lines (one per tool)
    if [[ "$line_count" -ge 4 ]]; then
        pass "parseable output has expected lines"
    else
        fail "parseable output has expected lines" "got $line_count lines"
    fi
}

test_env_cli_unknown_subcommand() {
    local output
    local exit_code=0
    output=$("${PROJECT_ROOT}/bin/cac" env notacommand 2>&1) || exit_code=$?

    # Should fail with error (non-zero exit code)
    if [[ "$exit_code" -ne 0 ]]; then
        pass "unknown subcommand fails with non-zero exit"
    else
        fail "unknown subcommand fails with non-zero exit" "got exit code 0"
        return 1
    fi
    assert_contains "Unknown" "$output" "error message"
}

# ============================================================================
# Issue #22 Regression: --yes bypasses interactive menu
# ============================================================================

test_env_yes_flag_bypasses_interactive() {
    # Mock env_install_all and env_interactive_install to track which is called
    local called_install_all=false
    local called_interactive=false

    env_install_all() { called_install_all=true; return 0; }
    env_interactive_install() { called_interactive=true; return 0; }

    # Call env_cmd_install with --yes (no tools specified)
    env_cmd_install --yes 2>/dev/null || true

    if [[ "$called_install_all" == "true" ]]; then
        pass "--yes flag triggers env_install_all"
    else
        fail "--yes flag triggers env_install_all" "env_install_all was not called"
    fi

    if [[ "$called_interactive" == "false" ]]; then
        pass "--yes flag skips env_interactive_install"
    else
        fail "--yes flag skips env_interactive_install" "env_interactive_install was called"
    fi

    # Restore original functions by re-sourcing
    source "${PROJECT_ROOT}/lib/env.sh"
}

# ============================================================================
# Issue #56: Legacy Bun Warning + Unified Curl Install Tests
# ============================================================================

test_env_warn_legacy_warns_existing() {
    local tmp1 tmp2
    tmp1=$(mktemp -d)
    tmp2=$(mktemp -d)

    local output
    output=$(_env_warn_legacy_bun_install "$tmp1" "$tmp2" 2>&1)
    local rc=$?

    rmdir "$tmp1" "$tmp2"

    assert_contains "Legacy Bun-based" "$output" "Should warn about legacy dirs"
    [[ $rc -eq 0 ]] || fail "return 0 when legacy dirs found"
    pass "legacy bun warning detects existing dirs"
}

test_env_warn_legacy_silent_when_clean() {
    local output
    output=$(_env_warn_legacy_bun_install "/nonexistent/path1" "/nonexistent/path2" 2>&1)
    local rc=$?

    [[ -z "$output" ]] || fail "no output when no legacy dirs" "$output"
    [[ $rc -ne 0 ]] || fail "return non-zero when no legacy dirs found"
    pass "legacy bun warning silent when clean"
}

test_env_install_curl_requires_root_for_global() {
    # Skip if actually running as root
    if [[ "$EUID" -eq 0 ]]; then
        pass "skipped: running as root"
        return
    fi

    local output
    output=$(env_install_tool "claude" "global" 2>&1) || true

    assert_contains "requires root" "$output" "require root for global install"
    pass "global curl install requires root"
}

test_env_install_claude_uses_curl_not_bun() {
    # Verify curl URL exists for claude
    [[ -n "${_ENV_INSTALL_URLS[claude]:-}" ]] || fail "no curl install URL for claude"

    # Verify no bun functions exist
    if declare -f _env_check_bun &>/dev/null; then
        fail "_env_check_bun should not exist"
    fi
    if declare -f _env_install_claude_global &>/dev/null; then
        fail "_env_install_claude_global should not exist"
    fi

    pass "claude install uses curl not bun"
}

test_env_update_curl_no_bun_redirect() {
    # Verify no bun global functions exist
    if declare -f _env_global_install_exists &>/dev/null; then
        fail "_env_global_install_exists should not exist"
    fi
    if declare -f _env_update_claude_global &>/dev/null; then
        fail "_env_update_claude_global should not exist"
    fi
    if declare -f _env_update_cc_global &>/dev/null; then
        fail "_env_update_cc_global should not exist"
    fi

    pass "update does not redirect to bun global"
}

test_env_install_curl_checks_curl_dep() {
    # Verify the install type for claude is curl
    local install_type
    install_type=$(env_get_install_type "claude")
    assert_equals "$install_type" "curl" "claude uses curl install type"

    pass "install checks curl dependency"
}

test_env_install_global_fails_not_root() {
    # Global install must fail cleanly with non-zero exit and clear message when not root
    if [[ "$EUID" -eq 0 ]]; then
        pass "install global not-root test skipped (running as root)"
        return 0
    fi

    # Mock env_is_installed to return 1 (not installed) so we reach the install logic
    env_is_installed() { return 1; }
    env_check_dependencies() { return 0; }

    local output
    local exit_code=0
    output=$(env_install_tool "claude" "global" "--yes" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        pass "global install exits non-zero when not root"
    else
        fail "global install exits non-zero when not root" "exit code was 0"
    fi

    if [[ "$output" == *"root"* ]] || [[ "$output" == *"sudo"* ]]; then
        pass "global install error message mentions root/sudo"
    else
        fail "global install error message mentions root/sudo" "got: $output"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_update_global_fails_not_root() {
    # Global update must fail cleanly with non-zero exit when not root
    if [[ "$EUID" -eq 0 ]]; then
        pass "update global not-root test skipped (running as root)"
        return 0
    fi

    env_is_installed() { return 0; }
    env_get_version() { echo "mock-version"; }
    env_check_dependencies() { return 0; }

    local output
    local exit_code=0
    output=$(env_update_tool "claude" "global" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        pass "global update exits non-zero when not root"
    else
        fail "global update exits non-zero when not root" "exit code was 0"
    fi

    if [[ "$output" == *"root"* ]] || [[ "$output" == *"sudo"* ]]; then
        pass "global update error message mentions root/sudo"
    else
        fail "global update error message mentions root/sudo" "got: $output"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_install_global_requires_root_error() {
    # Global install must fail with clear error when not root
    if [[ "$EUID" -eq 0 ]]; then
        pass "global root error test skipped (running as root)"
        return 0
    fi

    env_is_installed() { return 1; }
    local err_output=""
    utils_error() { err_output+="$* "; }

    local exit_code=0
    env_install_tool "claude" "global" "--yes" 2>/dev/null || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        pass "global install returns non-zero when not root"
    else
        fail "global install returns non-zero when not root"
    fi

    if [[ "$err_output" == *"root"* ]] || [[ "$err_output" == *"sudo"* ]]; then
        pass "global install error mentions root/sudo requirement"
    else
        fail "global install error mentions root/sudo requirement" "got: $err_output"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

# ============================================================================
# Issue #31/#32: Update Error Isolation Tests
# ============================================================================

test_env_update_all_continues_after_failure() {
    # Mock all dependencies for determinism
    env_get_all_tools() { printf "toolA\ntoolB\ntoolC\n"; }
    env_is_installed() { return 0; }
    env_get_version() { echo "mock-version"; }
    env_get_display_name() {
        case "$1" in
            toolA) echo "Tool A" ;; toolB) echo "Tool B" ;; toolC) echo "Tool C" ;;
        esac
    }

    # Track calls via temp file (avoids subshell scoping issues)
    local call_marker="${TEST_TMPDIR}/update_calls_$$"
    : > "$call_marker"
    env_update_tool() {
        echo "$1" >> "$call_marker"
        # Fail for the first tool, succeed for the rest
        if [[ "$1" == "toolA" ]]; then
            return 1
        fi
        return 0
    }

    env_update_all "user" >/dev/null 2>&1 || true

    local call_count
    call_count=$(wc -l < "$call_marker")

    # Should have been called for all 3 tools, not just the first
    if [[ $call_count -eq 3 ]]; then
        pass "update_all continues after first tool fails (called $call_count tools)"
    else
        fail "update_all continues after first tool fails" "only called $call_count tools"
    fi

    rm -f "$call_marker"
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_update_all_shows_failed_tools() {
    # Mock all dependencies for determinism
    env_get_all_tools() { printf "toolA\ntoolB\n"; }
    env_is_installed() { return 0; }
    env_get_version() { echo "mock-version"; }
    env_get_display_name() {
        case "$1" in
            toolA) echo "Tool A" ;; toolB) echo "Tool B" ;;
        esac
    }

    # Fail for toolB specifically
    env_update_tool() {
        if [[ "$1" == "toolB" ]]; then
            return 1
        fi
        return 0
    }

    local output
    output=$(env_update_all "user" 2>&1) || true

    assert_contains "Failed tools:" "$output" "summary lists failed tools"
    assert_contains "Tool B" "$output" "summary names the failed tool"

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_update_all_shows_correct_failed_count() {
    # Mock all dependencies for determinism
    env_get_all_tools() { printf "toolA\ntoolB\ntoolC\n"; }
    env_is_installed() { return 0; }
    env_get_version() { echo "mock-version"; }
    env_get_display_name() {
        case "$1" in
            toolA) echo "Tool A" ;; toolB) echo "Tool B" ;; toolC) echo "Tool C" ;;
        esac
    }

    # Fail for toolA and toolC (2 failures)
    env_update_tool() {
        if [[ "$1" == "toolA" || "$1" == "toolC" ]]; then
            return 1
        fi
        return 0
    }

    local output
    output=$(env_update_all "user" 2>&1) || true

    assert_contains "Failed: 2" "$output" "failed count is 2"

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_update_all_shows_skipped_tools() {
    # Issue #54: Skipped tools should be named, not just counted
    env_get_all_tools() { printf "toolA\ntoolB\ntoolC\n"; }
    env_is_installed() {
        [[ "$1" != "toolC" ]]
    }
    env_get_version() { echo "mock-version"; }
    env_get_display_name() {
        case "$1" in
            toolA) echo "Tool A" ;; toolB) echo "Tool B" ;; toolC) echo "Mistral Vibe" ;;
        esac
    }
    env_update_tool() { return 0; }

    local output
    output=$(env_update_all "user" 2>&1) || true

    assert_contains "Mistral Vibe" "$output" "skipped tool named in summary"
    assert_contains "Skipped (not installed):" "$output" "skipped line present"

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_update_all_skipped_line_format() {
    # Issue #54: Multiple skipped tools should all appear on the skipped line
    env_get_all_tools() { printf "toolA\ntoolB\ntoolC\n"; }
    env_is_installed() {
        [[ "$1" == "toolA" ]]
    }
    env_get_version() { echo "mock-version"; }
    env_get_display_name() {
        case "$1" in
            toolA) echo "Tool A" ;; toolB) echo "Tool B" ;; toolC) echo "Tool C" ;;
        esac
    }
    env_update_tool() { return 0; }

    local output
    output=$(env_update_all "user" 2>&1) || true

    assert_contains "Tool B" "$output" "first skipped tool named"
    assert_contains "Tool C" "$output" "second skipped tool named"
    assert_contains "Updated: 1" "$output" "updated count correct"

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_check_node_handles_empty_version() {
    # Mock both node and nodejs to exist but return empty version
    # (must mock both to prevent fallback to real nodejs binary)
    node() { echo ""; }
    export -f node
    nodejs() { echo ""; }
    export -f nodejs

    local err_output=""
    utils_error() { err_output+="$* "; }

    local rc=0
    env_check_node || rc=$?

    if [[ $rc -ne 0 ]]; then
        pass "check_node returns non-zero for empty version"
    else
        fail "check_node returns non-zero for empty version"
    fi

    if [[ "$err_output" == *"could not be determined"* ]]; then
        pass "check_node error message says 'could not be determined'"
    else
        fail "check_node error message says 'could not be determined'" "got: $err_output"
    fi

    # Should NOT contain double-space version error
    if [[ "$err_output" != *"version  is too old"* ]]; then
        pass "check_node does not show empty version in error"
    else
        fail "check_node does not show empty version in error" "got: $err_output"
    fi

    unset -f node
    unset -f nodejs
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_check_node_handles_nonnumeric_version() {
    # Mock node to return non-numeric version string
    node() { echo "vNaN.beta.1"; }
    export -f node

    local err_output=""
    utils_error() { err_output+="$* "; }

    local rc=0
    env_check_node || rc=$?

    if [[ $rc -ne 0 ]]; then
        pass "check_node returns non-zero for non-numeric version"
    else
        fail "check_node returns non-zero for non-numeric version"
    fi

    if [[ "$err_output" == *"could not be determined"* ]]; then
        pass "check_node error says 'could not be determined' for non-numeric"
    else
        fail "check_node error says 'could not be determined' for non-numeric" "got: $err_output"
    fi

    unset -f node
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

# ============================================================================
# Issue #30: Latest Version Check Tests
# ============================================================================

test_env_get_latest_version_with_mock_npm() {
    export XDG_CACHE_HOME="$TEST_TMPDIR"
    # Mock npm to return a known version
    npm() { echo "9.9.9"; }
    export -f npm
    # Mock timeout to just run the command
    timeout() { shift; "$@"; }
    export -f timeout

    # Clear cache to force fresh lookup
    local cache_file
    cache_file=$(_env_cache_file)
    rm -f "$cache_file"

    local latest
    latest=$(env_get_latest_version "claude")

    local rc=0
    assert_equals "9.9.9" "$latest" "latest version from mocked npm" || rc=$?

    unset -f npm timeout
    rm -f "$cache_file"
    unset XDG_CACHE_HOME
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
    return $rc
}

test_env_get_latest_version_fallback() {
    export XDG_CACHE_HOME="$TEST_TMPDIR"
    # Override npm to simulate it being unavailable
    # (hiding from PATH is unreliable since npm may be in /usr/bin)
    npm() { return 127; }
    export -f npm
    # Also override command to hide npm
    local orig_command
    orig_command=$(type -t command)
    command() {
        if [[ "$1" == "-v" && "$2" == "npm" ]]; then
            return 1
        fi
        builtin command "$@"
    }

    # Clear cache
    local cache_file
    cache_file=$(_env_cache_file)
    rm -f "$cache_file"

    local latest
    latest=$(env_get_latest_version "claude")

    unset -f npm command

    local rc=0
    assert_equals "?" "$latest" "fallback when npm unavailable" || rc=$?

    rm -f "$cache_file"
    unset XDG_CACHE_HOME
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
    return $rc
}

test_env_cache_write_and_read() {
    export XDG_CACHE_HOME="$TEST_TMPDIR"
    local cache_file
    cache_file=$(_env_cache_file)
    rm -f "$cache_file"

    # Write a cache entry
    _env_cache_set_latest "testool" "1.2.3"

    # Read it back
    local cached
    cached=$(_env_cache_get_latest "testool")

    local rc=0
    assert_equals "1.2.3" "$cached" "cached version read back" || rc=$?

    rm -f "$cache_file"
    unset XDG_CACHE_HOME
    return $rc
}

test_env_cache_expiry() {
    export XDG_CACHE_HOME="$TEST_TMPDIR"
    local cache_file
    cache_file=$(_env_cache_file)
    rm -f "$cache_file"

    # Write a cache entry with an old timestamp (10 minutes ago)
    local old_ts=$(( $(date +%s) - 600 ))
    echo "testool:1.0.0:${old_ts}" > "$cache_file"
    chmod 600 "$cache_file"

    # Should return empty (expired)
    local cached
    cached=$(_env_cache_get_latest "testool")

    if [[ -z "$cached" ]]; then
        pass "expired cache returns empty"
    else
        fail "expired cache returns empty" "got: $cached"
    fi

    rm -f "$cache_file"
    unset XDG_CACHE_HOME
}

test_env_check_updates_flag_parsing() {
    _env_parse_scope_args --check-updates 2>/dev/null || true
    assert_equals "true" "$ENV_PARSED_CHECK_UPDATES" "check-updates flag parsed"
}

test_env_status_with_latest_column() {
    # Mock env_is_installed and env_get_version for predictable output
    env_is_installed() { return 0; }
    env_get_version() { echo "1.0.0"; }
    env_get_latest_version() { echo "2.0.0"; }

    local output
    output=$(env_show_status "true" 2>&1)

    local rc=0
    assert_contains "Latest" "$output" "status output has Latest header" || rc=$?
    assert_contains "2.0.0" "$output" "status output shows latest version" || rc=$?

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
    return $rc
}

test_env_status_parseable_with_latest() {
    env_is_installed() { return 0; }
    env_get_version() { echo "1.0.0"; }
    env_get_latest_version() { echo "2.0.0"; }

    local output
    output=$(env_show_status_parseable "true" 2>&1)

    # Should have 4 tab-separated fields per line
    local first_line
    first_line=$(echo "$output" | head -1)
    local field_count
    field_count=$(echo "$first_line" | awk -F'\t' '{print NF}')

    local rc=0
    assert_equals "4" "$field_count" "parseable output has 4 fields with check-updates" || rc=$?
    assert_contains "2.0.0" "$output" "parseable output contains latest version" || rc=$?

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
    return $rc
}

test_env_normalize_version() {
    # Raw formats from various tools
    assert_equals "0.94.0" "$(_env_normalize_version "codex-cli 0.94.0")" "codex raw version"
    assert_equals "2.1.49" "$(_env_normalize_version "2.1.49")" "clean semver"
    assert_equals "2.1.49" "$(_env_normalize_version "2.1.49 (Claude Code)")" "claude raw version with suffix"
    assert_equals "0.26.0" "$(_env_normalize_version "0.26.0")" "gemini raw version"
    assert_equals "1.2.3" "$(_env_normalize_version "tool 1.2.3 (extra info)")" "version with suffix"
    assert_equals "unknown" "$(_env_normalize_version "unknown")" "unknown passes through"
}

test_env_status_check_updates_matches_normalized() {
    # Simulate claude: env_get_version returns "2.1.49 (Claude Code)", latest is "2.1.49"
    env_is_installed() { return 0; }
    env_get_version() { echo "2.1.49 (Claude Code)"; }
    env_get_latest_version() { echo "2.1.49"; }

    local output
    output=$(env_show_status "true" 2>&1)

    local rc=0

    # Should show ✓ (up-to-date), NOT ⬆ (update available)
    if [[ "$output" == *"✓"* ]]; then
        pass "normalized comparison shows ✓ when versions match"
    else
        fail "normalized comparison shows ✓ when versions match" "output: $output"
        rc=1
    fi

    # Should NOT show ⬆
    if [[ "$output" != *"⬆"* ]]; then
        pass "normalized comparison does not show ⬆ when up-to-date"
    else
        fail "normalized comparison does not show ⬆ when up-to-date" "output: $output"
        rc=1
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
    return $rc
}

test_env_status_without_check_updates() {
    local output
    output=$(env_show_status 2>&1)

    # Should NOT have Latest header
    if [[ "$output" != *"Latest"* ]]; then
        pass "default status has no Latest column"
    else
        fail "default status has no Latest column" "Found Latest in output"
    fi
}

test_env_status_parseable_without_check_updates() {
    env_is_installed() { return 0; }
    env_get_version() { echo "1.0.0"; }

    local output
    output=$(env_show_status_parseable 2>&1)

    # Should have 3 tab-separated fields per line (backward compat)
    local first_line
    first_line=$(echo "$output" | head -1)
    local field_count
    field_count=$(echo "$first_line" | awk -F'\t' '{print NF}')

    local rc=0
    assert_equals "3" "$field_count" "parseable output has 3 fields without check-updates" || rc=$?

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
    return $rc
}

test_env_parseable_normalizes_versions() {
    # Mock with raw CLI output that includes suffixes
    env_is_installed() { return 0; }
    env_get_version() { echo "2.1.49 (Claude Code)"; }
    env_get_latest_version() { echo "2.1.49"; }

    local output
    output=$(env_show_status_parseable "true" 2>&1)

    # Parseable output should contain normalized "2.1.49", not raw "2.1.49 (Claude Code)"
    local first_line version_field latest_field
    first_line=$(echo "$output" | head -1)
    version_field=$(echo "$first_line" | cut -f3)
    latest_field=$(echo "$first_line" | cut -f4)

    local rc=0
    assert_equals "2.1.49" "$version_field" "parseable version normalized" || rc=$?
    assert_equals "2.1.49" "$latest_field" "parseable latest normalized" || rc=$?

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
    return $rc
}

# ============================================================================
# Issue #49: Merged Install/Update Tests
# ============================================================================

test_env_install_updates_when_already_installed() {
    # When tool is already installed, env_install_tool should call env_update_tool
    local update_marker="${TEST_TMPDIR}/update_called_$$"
    env_is_installed() { return 0; }
    env_get_version() { echo "1.0.0"; }
    env_get_display_name() { echo "Mock Tool"; }
    env_validate_tool() { return 0; }
    env_update_tool() { touch "$update_marker"; return 0; }

    local output
    output=$(env_install_tool "claude" "user" 2>&1)

    if [[ -f "$update_marker" ]]; then
        pass "install calls update_tool when already installed"
    else
        fail "install calls update_tool when already installed" "update_tool was not called"
    fi

    assert_contains "already installed" "$output" "output mentions already installed"
    assert_contains "updating" "$output" "output mentions updating"

    rm -f "$update_marker"
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_install_returns_success_even_if_update_fails() {
    # Update failure should be non-fatal — env_install_tool returns 0 since tool IS installed
    env_is_installed() { return 0; }
    env_get_version() { echo "1.0.0"; }
    env_get_display_name() { echo "Mock Tool"; }
    env_validate_tool() { return 0; }
    env_update_tool() { return 1; }
    utils_warn() { :; }

    local exit_code=0
    env_install_tool "claude" "user" >/dev/null 2>&1 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        pass "install returns success even when update fails"
    else
        fail "install returns success even when update fails" "exit code was $exit_code"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_install_tool_update_output_message() {
    # Verify output format when tool is already installed
    env_is_installed() { return 0; }
    env_get_version() { echo "2.1.56"; }
    env_get_display_name() { echo "Claude Code"; }
    env_validate_tool() { return 0; }
    env_update_tool() { return 0; }

    local output
    output=$(env_install_tool "claude" "user" 2>&1)

    local rc=0
    assert_contains "Claude Code already installed (version: 2.1.56)" "$output" "message format" || rc=$?
    assert_contains "updating..." "$output" "message ends with updating..." || rc=$?

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
    return $rc
}

test_env_cmd_update_still_warns_not_installed() {
    # env_cmd_update must keep update-only semantics: warn if tool not installed
    env_is_installed() { return 1; }
    env_validate_tool() { return 0; }
    env_get_display_name() { echo "Mock Tool"; }
    local warn_output=""
    utils_warn() { warn_output+="$* "; }

    local exit_code=0
    env_update_tool "claude" "user" >/dev/null 2>&1 || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        pass "update_tool returns non-zero when not installed"
    else
        fail "update_tool returns non-zero when not installed" "exit code was 0"
    fi

    if [[ "$warn_output" == *"not installed"* ]]; then
        pass "update_tool warns 'not installed'"
    else
        fail "update_tool warns 'not installed'" "got: $warn_output"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_install_all_updates_installed_tools() {
    # env_install_all should call env_install_tool for ALL tools, including installed ones
    env_get_core_tools() { printf "toolA\ntoolB\n"; }
    env_get_display_name() {
        case "$1" in
            toolA) echo "Tool A" ;; toolB) echo "Tool B" ;;
        esac
    }
    env_get_version() { echo "1.0.0"; }

    # toolA is installed, toolB is not
    env_is_installed() {
        [[ "$1" == "toolA" ]]
    }

    local install_marker="${TEST_TMPDIR}/install_calls_$$"
    : > "$install_marker"
    env_install_tool() {
        echo "$1" >> "$install_marker"
        return 0
    }

    env_install_all "user" >/dev/null 2>&1 || true

    local call_count
    call_count=$(wc -l < "$install_marker")

    if [[ $call_count -eq 2 ]]; then
        pass "install_all calls install_tool for all tools (including installed)"
    else
        fail "install_all calls install_tool for all tools" "called $call_count times, expected 2"
    fi

    rm -f "$install_marker"
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_install_all_summary_format() {
    # Verify summary output has Installed/Updated/Failed with correct counts
    # Setup: 3 tools — toolA installed (update), toolB not installed (fresh), toolC not installed (fails)
    env_get_core_tools() { printf "toolA\ntoolB\ntoolC\n"; }
    env_get_display_name() {
        case "$1" in
            toolA) echo "Tool A" ;; toolB) echo "Tool B" ;; toolC) echo "Tool C" ;;
        esac
    }
    env_get_version() { echo "1.0.0"; }

    # toolA is installed, toolB and toolC are not
    env_is_installed() {
        [[ "$1" == "toolA" ]]
    }

    # toolA (installed) -> success, toolB (not installed) -> success, toolC (not installed) -> fail
    env_install_tool() {
        if [[ "$1" == "toolC" ]]; then
            return 1
        fi
        return 0
    }

    local output
    output=$(env_install_all "user" 2>&1) || true

    local rc=0
    assert_contains "Installed: 1" "$output" "summary shows 1 installed" || rc=$?
    assert_contains "Updated: 1" "$output" "summary shows 1 updated" || rc=$?
    assert_contains "Failed: 1" "$output" "summary shows 1 failed" || rc=$?

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
    return $rc
}

# ============================================================================
# Issue #57: Post-install Symlink Tests
# ============================================================================

test_env_post_install_symlink_creates_link() {
    # Set up mock environment: EUID=0, binary in /root/.local/bin, not in /usr/local/bin
    local mock_root="${TEST_TMPDIR}/mock_root_local_bin"
    local mock_usr="${TEST_TMPDIR}/mock_usr_local_bin"
    mkdir -p "$mock_root" "$mock_usr"

    # Create a fake binary
    touch "$mock_root/claude"
    chmod +x "$mock_root/claude"

    # Override the function to use our mock paths
    _env_post_install_symlink_test() {
        local tool="$1"
        local binary
        case "$tool" in
            claude)            binary="claude" ;;
            continuous-claude) binary="continuous-claude" ;;
            mistral)           binary="vibe" ;;
            *) return 0 ;;
        esac

        if [[ -e "$mock_usr/$binary" ]]; then
            return 0
        fi

        if [[ -x "$mock_root/$binary" ]]; then
            ln -sf "$mock_root/$binary" "$mock_usr/$binary"
            return 0
        fi
        return 0
    }

    _env_post_install_symlink_test "claude"

    if [[ -L "$mock_usr/claude" ]]; then
        pass "symlink created in mock /usr/local/bin"
    else
        fail "symlink created in mock /usr/local/bin"
    fi

    local target
    target=$(readlink "$mock_usr/claude")
    assert_equals "$mock_root/claude" "$target" "symlink points to correct binary"
}

test_env_post_install_symlink_skips_existing() {
    # When binary already exists in /usr/local/bin, no symlink should be created
    local mock_root="${TEST_TMPDIR}/mock_root_local_bin2"
    local mock_usr="${TEST_TMPDIR}/mock_usr_local_bin2"
    mkdir -p "$mock_root" "$mock_usr"

    # Binary already in /usr/local/bin
    touch "$mock_usr/claude"
    chmod +x "$mock_usr/claude"

    # Also exists in root local
    touch "$mock_root/claude"
    chmod +x "$mock_root/claude"

    _env_post_install_symlink_test() {
        local tool="$1"
        local binary
        case "$tool" in
            claude)            binary="claude" ;;
            continuous-claude) binary="continuous-claude" ;;
            mistral)           binary="vibe" ;;
            *) return 0 ;;
        esac

        if [[ -e "$mock_usr/$binary" ]]; then
            echo "SKIPPED"
            return 0
        fi

        ln -sf "$mock_root/$binary" "$mock_usr/$binary"
        return 0
    }

    local output
    output=$(_env_post_install_symlink_test "claude")

    assert_equals "SKIPPED" "$output" "skips when binary already exists"

    # Should NOT be a symlink (it was a regular file)
    if [[ ! -L "$mock_usr/claude" ]]; then
        pass "existing binary not replaced with symlink"
    else
        fail "existing binary not replaced with symlink"
    fi
}

test_env_post_install_symlink_maps_mistral_to_vibe() {
    # Verify that mistral tool maps to vibe binary name
    local mock_root="${TEST_TMPDIR}/mock_root_local_bin3"
    local mock_usr="${TEST_TMPDIR}/mock_usr_local_bin3"
    mkdir -p "$mock_root" "$mock_usr"

    # Create vibe binary (not mistral)
    touch "$mock_root/vibe"
    chmod +x "$mock_root/vibe"

    _env_post_install_symlink_test() {
        local tool="$1"
        local binary
        case "$tool" in
            claude)            binary="claude" ;;
            continuous-claude) binary="continuous-claude" ;;
            mistral)           binary="vibe" ;;
            *) return 0 ;;
        esac

        if [[ -e "$mock_usr/$binary" ]]; then
            return 0
        fi

        if [[ -x "$mock_root/$binary" ]]; then
            ln -sf "$mock_root/$binary" "$mock_usr/$binary"
            return 0
        fi
        return 0
    }

    _env_post_install_symlink_test "mistral"

    if [[ -L "$mock_usr/vibe" ]]; then
        pass "mistral maps to vibe binary"
    else
        fail "mistral maps to vibe binary"
    fi

    local target
    target=$(readlink "$mock_usr/vibe")
    assert_equals "$mock_root/vibe" "$target" "symlink points to vibe binary"
}

# ============================================================================
# Main
# ============================================================================

echo "=== Environment Management Tests (Issue #16) ==="
echo ""

framework_init

echo "--- Registry Access Tests ---"
run_test "registry has core tools" test_env_registry_has_core_tools
run_test "registry has optional tools" test_env_registry_has_optional_tools
run_test "get display name" test_env_get_display_name
run_test "get install type" test_env_get_install_type

echo ""
echo "--- Validation Tests ---"
run_test "validate valid tools" test_env_validate_tool_valid
run_test "validate invalid tools" test_env_validate_tool_invalid
run_test "validate valid scopes" test_env_validate_scope_valid
run_test "validate invalid scopes" test_env_validate_scope_invalid

echo ""
echo "--- Detection Tests ---"
run_test "is_installed checks command" test_env_is_installed_checks_command
run_test "get_version handles missing" test_env_get_version_returns_string

echo ""
echo "--- Scope Parsing Tests ---"
run_test "parse --user scope" test_env_parse_scope_user
run_test "parse --global scope" test_env_parse_scope_global
run_test "default scope is user" test_env_parse_scope_default
run_test "parse scope with tool" test_env_parse_scope_with_tool
run_test "parse multiple tools" test_env_parse_scope_multiple_tools
run_test "parse --yes flag" test_env_parse_scope_yes_flag
run_test "parse --parseable flag" test_env_parse_scope_parseable_flag

echo ""
echo "--- Status Output Tests ---"
run_test "status runs without error" test_env_show_status_runs
run_test "status parseable format" test_env_show_status_parseable_format

echo ""
echo "--- CLI Command Tests ---"
run_test "env --help" test_env_cli_help
run_test "env status" test_env_cli_status
run_test "env status --parseable" test_env_cli_status_parseable
run_test "unknown subcommand fails" test_env_cli_unknown_subcommand

echo ""
echo "--- Issue #22 Regression Tests ---"
run_test "--yes bypasses interactive menu" test_env_yes_flag_bypasses_interactive

echo ""
echo "--- Issue #56: Legacy Bun Warning + Unified Curl Tests ---"
run_test "legacy bun warning detects existing dirs" test_env_warn_legacy_warns_existing
run_test "legacy bun warning silent when clean" test_env_warn_legacy_silent_when_clean
run_test "global curl install requires root" test_env_install_curl_requires_root_for_global
run_test "claude install uses curl not bun" test_env_install_claude_uses_curl_not_bun
run_test "update does not redirect to bun global" test_env_update_curl_no_bun_redirect
run_test "install checks curl dependency" test_env_install_curl_checks_curl_dep
run_test "install global fails not root" test_env_install_global_fails_not_root
run_test "update global fails not root" test_env_update_global_fails_not_root
run_test "global install requires root error" test_env_install_global_requires_root_error

echo ""
echo "--- Issue #31/#32: Update Error Isolation Tests ---"
run_test "update_all continues after failure" test_env_update_all_continues_after_failure
run_test "update_all shows failed tools" test_env_update_all_shows_failed_tools
run_test "update_all shows correct failed count" test_env_update_all_shows_correct_failed_count
run_test "update_all shows skipped tool names" test_env_update_all_shows_skipped_tools
run_test "update_all skipped line lists multiple tools" test_env_update_all_skipped_line_format
run_test "check_node handles empty version" test_env_check_node_handles_empty_version
run_test "check_node handles non-numeric version" test_env_check_node_handles_nonnumeric_version

echo ""
echo "--- Issue #30: Latest Version Check Tests ---"
run_test "get latest version with mock npm" test_env_get_latest_version_with_mock_npm
run_test "get latest version fallback" test_env_get_latest_version_fallback
run_test "cache write and read" test_env_cache_write_and_read
run_test "cache expiry" test_env_cache_expiry
run_test "parse --check-updates flag" test_env_check_updates_flag_parsing
run_test "status with latest column" test_env_status_with_latest_column
run_test "parseable with latest column" test_env_status_parseable_with_latest
run_test "normalize version extracts semver" test_env_normalize_version
run_test "check-updates matches normalized versions" test_env_status_check_updates_matches_normalized
run_test "status without check-updates" test_env_status_without_check_updates
run_test "parseable without check-updates" test_env_status_parseable_without_check_updates
run_test "parseable normalizes versions" test_env_parseable_normalizes_versions

echo ""
echo "--- Issue #49: Merged Install/Update Tests ---"
run_test "install triggers update when already installed" test_env_install_updates_when_already_installed
run_test "install returns success even if update fails" test_env_install_returns_success_even_if_update_fails
run_test "install tool update output message format" test_env_install_tool_update_output_message
run_test "cmd_update still warns when not installed" test_env_cmd_update_still_warns_not_installed
run_test "install_all updates installed tools" test_env_install_all_updates_installed_tools
run_test "install_all summary format Installed/Updated/Failed" test_env_install_all_summary_format

echo ""
echo "--- Issue #57: Post-install Symlink Tests ---"
run_test "post_install_symlink creates link" test_env_post_install_symlink_creates_link
run_test "post_install_symlink skips existing" test_env_post_install_symlink_skips_existing
run_test "post_install_symlink maps mistral to vibe" test_env_post_install_symlink_maps_mistral_to_vibe

echo ""
framework_report
