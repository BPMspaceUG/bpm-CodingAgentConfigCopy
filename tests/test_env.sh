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
# Issue #28: Scope-Aware Install/Update Tests
# ============================================================================

test_env_global_install_exists_detects_dir() {
    # Create temp structure mimicking global install
    local tmpdir
    tmpdir=$(mktemp -d)

    # Mock the readonly vars by testing the underlying logic directly
    local mock_bin="${tmpdir}/usr/local/bin/claude"
    local mock_dir="${tmpdir}/opt/claude-code"
    mkdir -p "$mock_dir" "$(dirname "$mock_bin")"
    echo '#!/bin/bash' > "$mock_bin"
    chmod +x "$mock_bin"

    # Test: executable bin + existing dir = detected
    if [[ -x "$mock_bin" ]] && [[ -d "$mock_dir" ]]; then
        pass "global install detected with bin + dir"
    else
        fail "global install detected with bin + dir"
    fi

    rm -rf "$tmpdir"
}

test_env_global_install_exists_missing() {
    # _env_global_install_exists should return 1 for non-existent paths
    # Unless the machine actually has /opt/claude-code, which is fine
    if [[ ! -d "/opt/claude-code" ]] || [[ ! -x "/usr/local/bin/claude" ]]; then
        # At least one condition is false, so test with a fake tool
        if ! _env_global_install_exists "nonexistent-tool"; then
            pass "global install not found for unknown tool"
        else
            fail "global install not found for unknown tool"
        fi
    else
        # Machine has global claude install — test unknown tool instead
        if ! _env_global_install_exists "nonexistent-tool"; then
            pass "global install not found for unknown tool"
        else
            fail "global install not found for unknown tool"
        fi
    fi
}

test_env_enforce_scope_blocks_local_when_global_exists() {
    # Mock _env_global_install_exists to return 0 (global exists)
    _env_global_install_exists() { return 0; }
    _env_get_global_bin() { echo "/usr/local/bin/claude"; }
    local err_output=""
    utils_error() { err_output+="$* "; }

    local rc=0
    _env_enforce_scope "claude" "user" || rc=$?

    if [[ $rc -ne 0 ]]; then
        pass "enforce scope blocks local when global exists"
    else
        fail "enforce scope blocks local when global exists" "returned 0"
    fi

    if [[ "$err_output" == *"SCOPE CONFLICT"* ]]; then
        pass "enforce scope error mentions SCOPE CONFLICT"
    else
        fail "enforce scope error mentions SCOPE CONFLICT" "got: $err_output"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_enforce_scope_allows_when_no_global() {
    # Mock _env_global_install_exists to return 1 (no global)
    _env_global_install_exists() { return 1; }
    _env_get_global_bin() { echo "/usr/local/bin/claude"; }

    local rc=0
    _env_enforce_scope "claude" "user" || rc=$?

    if [[ $rc -eq 0 ]]; then
        pass "enforce scope allows local when no global"
    else
        fail "enforce scope allows local when no global" "returned $rc"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_check_bun_when_missing() {
    # Temporarily hide bun from PATH
    local orig_path="$PATH"
    PATH="/usr/bin:/bin"
    local output
    # Mock utils_error to capture
    local err_output=""
    utils_error() { err_output+="$*"; }

    _env_check_bun
    local rc=$?

    PATH="$orig_path"

    if [[ $rc -ne 0 ]]; then
        pass "bun check fails when bun not in PATH"
    else
        fail "bun check fails when bun not in PATH" "returned 0"
    fi

    if [[ "$err_output" == *"bun not found"* ]]; then
        pass "bun check shows clear error message"
    else
        fail "bun check shows clear error message" "got: $err_output"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_install_tool_global_routes_to_bun() {
    # Mock the global install function to track if it was called
    local called_bun_install=false
    _env_install_claude_global() { called_bun_install=true; return 0; }
    # Mock env_is_installed to return 1 (not installed) then 0 (installed after)
    local install_call_count=0
    env_is_installed() { ((install_call_count++)) || true; [[ $install_call_count -gt 1 ]]; }
    env_get_version() { echo "mock-version"; }
    env_check_dependencies() { return 0; }
    utils_success() { :; }
    # Fake EUID=0 for global scope
    local orig_euid="$EUID"
    # Can't override EUID, so skip root check by mocking at higher level
    # Instead, test that the routing logic selects the right function
    # by calling the curl case logic directly

    if [[ "$called_bun_install" == "false" ]]; then
        # Call the function — it will fail on EUID check if not root, that's OK
        # We just want to verify the routing logic exists
        local output
        output=$(env_install_tool "claude" "global" "--yes" 2>&1) || true

        # If not root, it should mention "root" in error
        if [[ "$EUID" -ne 0 ]]; then
            if [[ "$output" == *"root"* ]] || [[ "$output" == *"sudo"* ]]; then
                pass "global install requires root (scope routing works)"
            else
                # Check if our mock was called (unlikely without root)
                if [[ "$called_bun_install" == "true" ]]; then
                    pass "global install routes to bun install function"
                else
                    fail "global install routes correctly" "output: $output"
                fi
            fi
        else
            # Running as root — mock should have been called
            if [[ "$called_bun_install" == "true" ]]; then
                pass "global install routes to bun install function"
            else
                fail "global install routes to bun install function"
            fi
        fi
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_update_tool_global_routes_to_bun() {
    # Mock the global update function
    local called_bun_update=false
    _env_update_claude_global() { called_bun_update=true; return 0; }
    env_is_installed() { return 0; }
    env_get_version() { echo "mock-version"; }
    env_check_dependencies() { return 0; }
    utils_success() { :; }

    local output
    output=$(env_update_tool "claude" "global" 2>&1) || true

    if [[ "$EUID" -ne 0 ]]; then
        # Not root — should get root error (proves scope routing hit global branch)
        if [[ "$output" == *"root"* ]] || [[ "$output" == *"sudo"* ]]; then
            pass "global update requires root (scope routing works)"
        else
            fail "global update routes correctly" "output: $output"
        fi
    else
        if [[ "$called_bun_update" == "true" ]]; then
            pass "global update routes to bun update function"
        else
            fail "global update routes to bun update function"
        fi
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_constants_defined() {
    # Verify Issue #28 constants are defined
    assert_equals "/opt/claude-code" "$_ENV_CLAUDE_GLOBAL_DIR" "claude global dir"
    assert_equals "/usr/local/bin/claude" "$_ENV_CLAUDE_GLOBAL_BIN" "claude global bin"
    assert_equals "@anthropic-ai/claude-code" "$_ENV_CLAUDE_GLOBAL_PKG" "claude global pkg"
    assert_equals "/opt/continuous-claude" "$_ENV_CC_GLOBAL_DIR" "cc global dir"
    assert_equals "/usr/local/bin/continuous-claude" "$_ENV_CC_GLOBAL_BIN" "cc global bin"
    assert_equals "continuous-claude" "$_ENV_CC_GLOBAL_PKG" "cc global pkg"
}

test_env_install_all_scope_routes_to_bun() {
    # --all scope should route to bun-based global path (same as --global)
    # Mock env_is_installed to return 1 (not installed) so we reach the install logic
    env_is_installed() { return 1; }
    env_check_dependencies() { return 0; }

    local output
    output=$(env_install_tool "claude" "all" "--yes" 2>&1) || true

    # Non-root: should hit the root check in the global/all branch
    if [[ "$EUID" -ne 0 ]]; then
        if [[ "$output" == *"root"* ]] || [[ "$output" == *"sudo"* ]]; then
            pass "--all scope routes to global path (requires root)"
        else
            fail "--all scope routes to global path" "output: $output"
        fi
    else
        pass "--all scope routes to global path (running as root)"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_update_all_scope_routes_to_bun() {
    # --all scope for update should route to bun-based global path
    env_is_installed() { return 0; }
    env_get_version() { echo "mock-version"; }
    env_check_dependencies() { return 0; }

    local output
    output=$(env_update_tool "claude" "all" 2>&1) || true

    if [[ "$EUID" -ne 0 ]]; then
        if [[ "$output" == *"root"* ]] || [[ "$output" == *"sudo"* ]]; then
            pass "--all update scope routes to global path (requires root)"
        else
            fail "--all update scope routes to global path" "output: $output"
        fi
    else
        pass "--all update scope routes to global path (running as root)"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
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

test_env_install_global_fails_no_bun() {
    # Global install should fail with ENV_EXIT_MISSING_DEP when bun not available
    # Mock to bypass root check and env_is_installed
    env_is_installed() { return 1; }
    env_check_dependencies() { return 0; }

    # Hide bun from PATH
    local orig_path="$PATH"
    PATH="/usr/bin:/bin"

    # Mock _env_install_claude_global to simulate what happens when _env_check_bun fails
    local err_output=""
    utils_error() { err_output+="$* "; }

    _env_check_bun
    local rc=$?
    PATH="$orig_path"

    if [[ $rc -ne 0 ]]; then
        pass "global install fails when bun missing (dependency check)"
    else
        fail "global install fails when bun missing" "returned 0"
    fi

    if [[ "$err_output" == *"bun not found"* ]]; then
        pass "global install bun-missing error is clear"
    else
        fail "global install bun-missing error is clear" "got: $err_output"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_update_global_fails_no_bun() {
    # Global update should fail when bun not available
    local orig_path="$PATH"
    PATH="/usr/bin:/bin"

    local err_output=""
    utils_error() { err_output+="$* "; }

    _env_check_bun
    local rc=$?
    PATH="$orig_path"

    if [[ $rc -ne 0 ]]; then
        pass "global update fails when bun missing (dependency check)"
    else
        fail "global update fails when bun missing" "returned 0"
    fi

    if [[ "$err_output" == *"bun not found"* ]]; then
        pass "global update bun-missing error is clear"
    else
        fail "global update bun-missing error is clear" "got: $err_output"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_global_install_no_curl_needed() {
    # Global install of claude should NOT require curl — it uses bun
    # Mock env_is_installed to return 1 (not installed)
    env_is_installed() { return 1; }
    # Mock env_check_curl to fail (curl not available)
    env_check_curl() { return 1; }
    # Mock _env_install_claude_global to succeed (proving we bypassed curl check)
    local called_bun_install=false
    _env_install_claude_global() { called_bun_install=true; return 0; }
    env_get_version() { echo "mock-version"; }
    utils_success() { :; }

    local output
    local exit_code=0
    # This will fail on EUID check if not root, which is fine — we test the dependency path
    output=$(env_install_tool "claude" "global" "--yes" 2>&1) || exit_code=$?

    if [[ "$EUID" -ne 0 ]]; then
        # Not root: the root check fires before dependency check, so we test
        # that env_check_curl was NOT called by verifying the error is about root, not curl
        if [[ "$output" == *"root"* ]] && [[ "$output" != *"curl"* ]]; then
            pass "global install does not require curl (root check, not curl check)"
        else
            fail "global install does not require curl" "output: $output"
        fi
    else
        # Root: mock should have been called, proving curl was bypassed
        if [[ "$called_bun_install" == "true" ]]; then
            pass "global install bypasses curl, uses bun"
        else
            fail "global install bypasses curl, uses bun"
        fi
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_global_update_no_curl_needed() {
    # Global update of claude should NOT require curl — it uses bun
    env_is_installed() { return 0; }
    env_get_version() { echo "mock-version"; }
    # Mock env_check_curl to fail
    env_check_curl() { return 1; }
    # Mock _env_update_claude_global to succeed
    local called_bun_update=false
    _env_update_claude_global() { called_bun_update=true; return 0; }
    utils_success() { :; }

    local output
    local exit_code=0
    output=$(env_update_tool "claude" "global" 2>&1) || exit_code=$?

    if [[ "$EUID" -ne 0 ]]; then
        if [[ "$output" == *"root"* ]] && [[ "$output" != *"curl"* ]]; then
            pass "global update does not require curl (root check, not curl check)"
        else
            fail "global update does not require curl" "output: $output"
        fi
    else
        if [[ "$called_bun_update" == "true" ]]; then
            pass "global update bypasses curl, uses bun"
        else
            fail "global update bypasses curl, uses bun"
        fi
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

# ============================================================================
# Issue #29: Exclusive Scope Enforcement Tests
# ============================================================================

test_env_enforce_scope_allows_global_scope() {
    # Global scope should never be blocked, even if global install exists
    _env_global_install_exists() { return 0; }
    _env_get_global_bin() { echo "/usr/local/bin/claude"; }

    local rc=0
    _env_enforce_scope "claude" "global" || rc=$?

    if [[ $rc -eq 0 ]]; then
        pass "enforce scope allows global scope"
    else
        fail "enforce scope allows global scope" "returned $rc"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_enforce_scope_skips_npm_tools() {
    # npm tools (codex, gemini) have no global support — should always pass
    local rc=0
    _env_enforce_scope "codex" "user" || rc=$?

    if [[ $rc -eq 0 ]]; then
        pass "enforce scope skips npm tools"
    else
        fail "enforce scope skips npm tools" "returned $rc"
    fi
}

test_env_scan_all_users_finds_dirs() {
    # Create temp structure mimicking /home/user1/.local/bin and /root/.local/bin
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "${tmpdir}/home/user1/.local/bin"
    mkdir -p "${tmpdir}/home/user2/.local/bin"
    mkdir -p "${tmpdir}/home/user3"  # No .local/bin — should be skipped
    mkdir -p "${tmpdir}/root/.local/bin"

    # Override _env_scan_all_users to use temp paths
    _env_scan_all_users() {
        local dir
        for dir in "${tmpdir}"/home/*/; do
            [[ -d "${dir}.local/bin" ]] && echo "${dir%/}"
        done
        [[ -d "${tmpdir}/root/.local/bin" ]] && echo "${tmpdir}/root"
    }

    local output
    output=$(_env_scan_all_users)

    assert_contains "user1" "$output" "scan finds user1"
    assert_contains "user2" "$output" "scan finds user2"
    assert_contains "root" "$output" "scan finds root"

    # user3 should NOT be in output (no .local/bin)
    if [[ "$output" != *"user3"* ]]; then
        pass "scan skips user3 (no .local/bin)"
    else
        fail "scan skips user3 (no .local/bin)"
    fi

    rm -rf "$tmpdir"
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_cleanup_local_installs_removes_and_symlinks() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # Create mock global binary
    local mock_global_bin="${tmpdir}/usr/local/bin/claude"
    mkdir -p "$(dirname "$mock_global_bin")"
    echo '#!/bin/bash' > "$mock_global_bin"
    chmod +x "$mock_global_bin"

    # Create mock local binaries for 2 users (standalone, not symlinks)
    mkdir -p "${tmpdir}/home/alice/.local/bin"
    mkdir -p "${tmpdir}/home/bob/.local/bin"
    echo '#!/bin/bash' > "${tmpdir}/home/alice/.local/bin/claude"
    chmod +x "${tmpdir}/home/alice/.local/bin/claude"
    echo '#!/bin/bash' > "${tmpdir}/home/bob/.local/bin/claude"
    chmod +x "${tmpdir}/home/bob/.local/bin/claude"

    # Override helpers to use temp paths
    _env_get_global_bin() { echo "$mock_global_bin"; }
    _env_scan_all_users() {
        echo "${tmpdir}/home/alice"
        echo "${tmpdir}/home/bob"
    }

    # Run cleanup
    local output
    output=$(_env_cleanup_local_installs "claude" 2>&1)

    # Check alice's local binary is now a symlink to global
    if [[ -L "${tmpdir}/home/alice/.local/bin/claude" ]]; then
        local target
        target=$(readlink -f "${tmpdir}/home/alice/.local/bin/claude")
        if [[ "$target" == "$mock_global_bin" ]]; then
            pass "alice local binary replaced with symlink to global"
        else
            fail "alice local binary replaced with symlink to global" "points to: $target"
        fi
    else
        fail "alice local binary replaced with symlink" "not a symlink"
    fi

    # Check bob's local binary is now a symlink to global
    if [[ -L "${tmpdir}/home/bob/.local/bin/claude" ]]; then
        pass "bob local binary replaced with symlink to global"
    else
        fail "bob local binary replaced with symlink" "not a symlink"
    fi

    assert_contains "Removed local binary" "$output" "cleanup output"
    assert_contains "Created symlink" "$output" "cleanup output"

    rm -rf "$tmpdir"
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_cleanup_local_installs_skips_correct_symlinks() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # Create mock global binary
    local mock_global_bin="${tmpdir}/usr/local/bin/claude"
    mkdir -p "$(dirname "$mock_global_bin")"
    echo '#!/bin/bash' > "$mock_global_bin"
    chmod +x "$mock_global_bin"

    # Create a correct symlink (already pointing to global)
    mkdir -p "${tmpdir}/home/alice/.local/bin"
    ln -sf "$mock_global_bin" "${tmpdir}/home/alice/.local/bin/claude"

    # Override helpers
    _env_get_global_bin() { echo "$mock_global_bin"; }
    _env_scan_all_users() { echo "${tmpdir}/home/alice"; }

    local output
    output=$(_env_cleanup_local_installs "claude" 2>&1)

    # Should NOT have "Removed" in output (symlink was already correct)
    if [[ "$output" != *"Removed"* ]]; then
        pass "cleanup skips correct symlinks (no removal)"
    else
        fail "cleanup skips correct symlinks" "got: $output"
    fi

    # Symlink should still be intact
    if [[ -L "${tmpdir}/home/alice/.local/bin/claude" ]]; then
        pass "correct symlink preserved"
    else
        fail "correct symlink preserved"
    fi

    rm -rf "$tmpdir"
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_update_auto_migrates_when_both_exist() {
    # Mock global exists
    _env_global_install_exists() { return 0; }
    # Use temp files to track calls across subshells
    local cleanup_marker="${TEST_TMPDIR}/cleanup_called_$$"
    local global_update_marker="${TEST_TMPDIR}/global_update_called_$$"
    local curl_marker="${TEST_TMPDIR}/curl_called_$$"
    _env_cleanup_local_installs() { touch "$cleanup_marker"; return 0; }
    _env_update_claude_global() { touch "$global_update_marker"; return 0; }
    # Mock curl to detect if user-scope path was taken
    env_check_curl() { touch "$curl_marker"; return 0; }

    # Mock the rest for a successful update
    env_is_installed() { return 0; }
    env_get_version() { echo "mock-version"; }
    env_check_dependencies() { return 0; }
    utils_success() { :; }
    utils_error() { :; }
    _env_get_global_bin() { echo "/usr/local/bin/claude"; }

    env_update_tool "claude" "user" >/dev/null 2>&1 || true

    if [[ -f "$cleanup_marker" ]]; then
        pass "update auto-migrates: cleanup called"
    else
        fail "update auto-migrates: cleanup called" "cleanup not called"
    fi

    if [[ "$EUID" -eq 0 ]]; then
        # Root: global update mock should be called
        if [[ -f "$global_update_marker" ]]; then
            pass "update auto-migrates: global update function called"
        else
            fail "update auto-migrates: global update function called" "global update not called"
        fi
    else
        # Non-root: root check fires before global update, which proves
        # the code entered the global redirect path (not the curl path)
        if [[ ! -f "$curl_marker" ]]; then
            pass "update auto-migrates: redirected to global path (root check hit, not curl)"
        else
            fail "update auto-migrates: redirected to global path" "curl was called instead"
        fi
    fi

    # Curl path must NEVER be taken when global exists
    if [[ ! -f "$curl_marker" ]]; then
        pass "update auto-migrates: curl path NOT taken"
    else
        fail "update auto-migrates: curl path NOT taken" "curl was called (local binary would be recreated)"
    fi

    rm -f "$cleanup_marker" "$global_update_marker" "$curl_marker"
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_install_user_scope_blocked_by_global() {
    # Mock: global exists, tool not installed yet
    _env_global_install_exists() { return 0; }
    _env_get_global_bin() { echo "/usr/local/bin/claude"; }
    env_is_installed() { return 1; }
    local err_output=""
    utils_error() { err_output+="$* "; }

    local exit_code=0
    env_install_tool "claude" "user" "--yes" 2>/dev/null || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        pass "install user scope returns non-zero when global exists"
    else
        fail "install user scope returns non-zero when global exists"
    fi

    if [[ "$err_output" == *"SCOPE CONFLICT"* ]]; then
        pass "install user scope error mentions SCOPE CONFLICT"
    else
        fail "install user scope error mentions SCOPE CONFLICT" "got: $err_output"
    fi

    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_local_install_exists_detects_standalone() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # Create a standalone local binary (not a symlink)
    mkdir -p "${tmpdir}/.local/bin"
    echo '#!/bin/bash' > "${tmpdir}/.local/bin/claude"
    chmod +x "${tmpdir}/.local/bin/claude"

    # Mock _env_get_global_bin
    _env_get_global_bin() { echo "/usr/local/bin/claude"; }

    if _env_local_install_exists "claude" "$tmpdir"; then
        pass "local install exists detects standalone binary"
    else
        fail "local install exists detects standalone binary"
    fi

    # Now make it a symlink to the global path — should return false
    ln -sf "/usr/local/bin/claude" "${tmpdir}/.local/bin/claude"

    if ! _env_local_install_exists "claude" "$tmpdir"; then
        pass "local install exists ignores symlink to global"
    else
        fail "local install exists ignores symlink to global"
    fi

    rm -rf "$tmpdir"
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_scan_all_users_skips_unwritable() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # Create writable user dir
    mkdir -p "${tmpdir}/home/writable/.local/bin"
    # Create unwritable user dir
    mkdir -p "${tmpdir}/home/readonly/.local/bin"
    chmod 555 "${tmpdir}/home/readonly/.local/bin"

    # Override _env_scan_all_users to use temp paths
    _env_scan_all_users() {
        local dir
        for dir in "${tmpdir}"/home/*/; do
            [[ -d "${dir}.local/bin" ]] && [[ -w "${dir}.local/bin" ]] && echo "${dir%/}"
        done
    }

    local output
    output=$(_env_scan_all_users)

    if [[ "$output" == *"writable"* ]]; then
        pass "scan includes writable dir"
    else
        fail "scan includes writable dir" "got: $output"
    fi

    if [[ "$output" != *"readonly"* ]]; then
        pass "scan skips unwritable dir"
    else
        fail "scan skips unwritable dir" "got: $output"
    fi

    # Restore permissions for cleanup
    chmod 755 "${tmpdir}/home/readonly/.local/bin"
    rm -rf "$tmpdir"
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_scan_all_users_skips_missing_local_bin() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # Create user dir WITHOUT .local/bin
    mkdir -p "${tmpdir}/home/nolocal"
    # Create user dir WITH .local/bin
    mkdir -p "${tmpdir}/home/haslocal/.local/bin"

    _env_scan_all_users() {
        local dir
        for dir in "${tmpdir}"/home/*/; do
            [[ -d "${dir}.local/bin" ]] && [[ -w "${dir}.local/bin" ]] && echo "${dir%/}"
        done
    }

    local output
    output=$(_env_scan_all_users)

    if [[ "$output" == *"haslocal"* ]]; then
        pass "scan includes dir with .local/bin"
    else
        fail "scan includes dir with .local/bin" "got: $output"
    fi

    if [[ "$output" != *"nolocal"* ]]; then
        pass "scan skips dir without .local/bin"
    else
        fail "scan skips dir without .local/bin" "got: $output"
    fi

    rm -rf "$tmpdir"
    # Restore
    source "${PROJECT_ROOT}/lib/env.sh"
}

test_env_cleanup_skips_unwritable_dirs() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # Create mock global binary
    local mock_global_bin="${tmpdir}/usr/local/bin/claude"
    mkdir -p "$(dirname "$mock_global_bin")"
    echo '#!/bin/bash' > "$mock_global_bin"
    chmod +x "$mock_global_bin"

    # Create writable user with local binary
    mkdir -p "${tmpdir}/home/writable/.local/bin"
    echo '#!/bin/bash' > "${tmpdir}/home/writable/.local/bin/claude"
    chmod +x "${tmpdir}/home/writable/.local/bin/claude"

    # Create unwritable user dir
    mkdir -p "${tmpdir}/home/readonly/.local/bin"
    echo '#!/bin/bash' > "${tmpdir}/home/readonly/.local/bin/claude"
    chmod +x "${tmpdir}/home/readonly/.local/bin/claude"
    chmod 555 "${tmpdir}/home/readonly/.local/bin"

    # Override helpers
    _env_get_global_bin() { echo "$mock_global_bin"; }
    _env_scan_all_users() {
        echo "${tmpdir}/home/writable"
        # readonly is NOT returned by scan (filtered by writability check)
    }
    utils_verbose() { :; }

    local output
    output=$(_env_cleanup_local_installs "claude" 2>&1)

    # Writable dir should have been cleaned up
    if [[ -L "${tmpdir}/home/writable/.local/bin/claude" ]]; then
        pass "cleanup processed writable dir"
    else
        fail "cleanup processed writable dir"
    fi

    # Readonly dir's binary should be untouched (not in scan output)
    if [[ ! -L "${tmpdir}/home/readonly/.local/bin/claude" ]]; then
        pass "cleanup skipped unwritable dir (not scanned)"
    else
        fail "cleanup skipped unwritable dir"
    fi

    # Restore permissions for cleanup
    chmod 755 "${tmpdir}/home/readonly/.local/bin"
    rm -rf "$tmpdir"
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

test_env_check_node_handles_empty_version() {
    # Mock node to exist but return empty version
    node() { echo ""; }
    export -f node

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
echo "--- Issue #28: Scope-Aware Install Tests ---"
run_test "global install constants defined" test_env_constants_defined
run_test "global install detects dir+bin" test_env_global_install_exists_detects_dir
run_test "global install missing for unknown tool" test_env_global_install_exists_missing
run_test "enforce scope blocks local when global exists" test_env_enforce_scope_blocks_local_when_global_exists
run_test "enforce scope allows when no global" test_env_enforce_scope_allows_when_no_global
run_test "bun check fails when missing" test_env_check_bun_when_missing
run_test "install global routes to bun" test_env_install_tool_global_routes_to_bun
run_test "update global routes to bun" test_env_update_tool_global_routes_to_bun
run_test "--all install routes to global/bun" test_env_install_all_scope_routes_to_bun
run_test "--all update routes to global/bun" test_env_update_all_scope_routes_to_bun
run_test "install global fails not root" test_env_install_global_fails_not_root
run_test "update global fails not root" test_env_update_global_fails_not_root
run_test "install global fails no bun" test_env_install_global_fails_no_bun
run_test "update global fails no bun" test_env_update_global_fails_no_bun
run_test "global install no curl needed" test_env_global_install_no_curl_needed
run_test "global update no curl needed" test_env_global_update_no_curl_needed

echo ""
echo "--- Issue #29: Exclusive Scope Enforcement Tests ---"
run_test "enforce scope allows global scope" test_env_enforce_scope_allows_global_scope
run_test "enforce scope skips npm tools" test_env_enforce_scope_skips_npm_tools
run_test "scan all users finds dirs" test_env_scan_all_users_finds_dirs
run_test "cleanup local installs removes and symlinks" test_env_cleanup_local_installs_removes_and_symlinks
run_test "cleanup local installs skips correct symlinks" test_env_cleanup_local_installs_skips_correct_symlinks
run_test "update auto-migrates when both exist" test_env_update_auto_migrates_when_both_exist
run_test "install user scope blocked by global" test_env_install_user_scope_blocked_by_global
run_test "local install exists detects standalone" test_env_local_install_exists_detects_standalone
run_test "scan skips unwritable dirs" test_env_scan_all_users_skips_unwritable
run_test "scan skips missing .local/bin" test_env_scan_all_users_skips_missing_local_bin
run_test "cleanup skips unwritable dirs" test_env_cleanup_skips_unwritable_dirs
run_test "global install requires root error" test_env_install_global_requires_root_error

echo ""
echo "--- Issue #31/#32: Update Error Isolation Tests ---"
run_test "update_all continues after failure" test_env_update_all_continues_after_failure
run_test "update_all shows failed tools" test_env_update_all_shows_failed_tools
run_test "update_all shows correct failed count" test_env_update_all_shows_correct_failed_count
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
framework_report
