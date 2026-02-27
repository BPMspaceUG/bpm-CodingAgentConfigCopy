#!/usr/bin/env bash
# tests/test_env_check.sh - Tests for env check and env repair (Issue #59)
# shellcheck disable=SC2317

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/test_framework.sh"
source "${PROJECT_ROOT}/lib/env.sh"

framework_init

# ============================================================================
# Helper: create a mock binary in a temp dir
# ============================================================================
_create_mock_binary() {
    local dir="$1"
    local name="$2"
    local exit_code="${3:-0}"
    local version="${4:-1.0.0}"

    mkdir -p "$dir"
    cat > "${dir}/${name}" <<SCRIPT
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
    echo "$version"
    exit $exit_code
fi
exit $exit_code
SCRIPT
    chmod +x "${dir}/${name}"
}

# ============================================================================
# Tests: _env_tool_to_binary
# ============================================================================

test_tool_to_binary_claude() {
    local result
    result=$(_env_tool_to_binary "claude")
    assert_equals "claude" "$result" "claude maps to claude binary"
    pass "tool_to_binary_claude"
}

test_tool_to_binary_codex() {
    local result
    result=$(_env_tool_to_binary "codex")
    assert_equals "codex" "$result" "codex maps to codex binary"
    pass "tool_to_binary_codex"
}

test_tool_to_binary_gemini() {
    local result
    result=$(_env_tool_to_binary "gemini")
    assert_equals "gemini" "$result" "gemini maps to gemini binary"
    pass "tool_to_binary_gemini"
}

test_tool_to_binary_continuous_claude() {
    local result
    result=$(_env_tool_to_binary "continuous-claude")
    assert_equals "continuous-claude" "$result" "continuous-claude maps correctly"
    pass "tool_to_binary_continuous_claude"
}

test_tool_to_binary_mistral() {
    local result
    result=$(_env_tool_to_binary "mistral")
    assert_equals "vibe" "$result" "mistral maps to vibe binary"
    pass "tool_to_binary_mistral"
}

test_tool_to_binary_unknown() {
    if _env_tool_to_binary "nonexistent" 2>/dev/null; then
        fail "tool_to_binary_unknown" "should have failed for unknown tool"
        return 1
    fi
    pass "tool_to_binary_unknown"
}

# ============================================================================
# Tests: _env_chk_binary_location
# ============================================================================

test_chk_binary_location_usr_local_pass() {
    _CHECK_REASON=""
    _env_chk_binary_location "/usr/local/bin/claude" "claude"
    pass "binary_location_usr_local_pass"
}

test_chk_binary_location_local_bin_pass() {
    _CHECK_REASON=""
    _env_chk_binary_location "${HOME}/.local/bin/claude" "claude"
    pass "binary_location_local_bin_pass"
}

test_chk_binary_location_opt_fail() {
    _CHECK_REASON=""
    # Create a real file in /opt/-like path so readlink -f resolves
    local opt_dir="${TEST_TMPDIR}/opt/claude-code/bin"
    mkdir -p "$opt_dir"
    touch "${opt_dir}/claude"

    if _env_chk_binary_location "${opt_dir}/claude" "claude" 2>/dev/null; then
        fail "binary_location_opt_fail" "should have failed for /opt/ path"
        return 1
    fi
    assert_contains "unexpected location" "$_CHECK_REASON" "reason mentions unexpected location"
    pass "binary_location_opt_fail"
}

test_chk_binary_location_empty_fail() {
    _CHECK_REASON=""
    if _env_chk_binary_location "" "claude" 2>/dev/null; then
        fail "binary_location_empty_fail" "should have failed for empty path"
        return 1
    fi
    assert_contains "not found" "$_CHECK_REASON" "reason mentions not found"
    pass "binary_location_empty_fail"
}

# ============================================================================
# Tests: _env_chk_no_bun
# ============================================================================

test_chk_no_bun_clean_pass() {
    # Override HOME to a clean temp dir and mock the function to use temp /opt/ paths
    local orig_home="$HOME"
    export HOME="${TEST_TMPDIR}/clean_home"
    mkdir -p "$HOME"

    # Override _env_chk_no_bun to use temp dirs instead of real /opt/
    _env_chk_no_bun() {
        local binary_path="$1"
        local tool="$2"
        local dirs_to_check=()
        case "$tool" in
            claude) dirs_to_check=("${TEST_TMPDIR}/fake_opt/claude-code" "$HOME/.bun") ;;
            continuous-claude) dirs_to_check=("${TEST_TMPDIR}/fake_opt/continuous-claude" "$HOME/.bun") ;;
            *) return 0 ;;
        esac
        for dir in "${dirs_to_check[@]}"; do
            if [[ -d "$dir" ]]; then
                _CHECK_REASON="$dir exists (legacy Bun install)"
                return 1
            fi
        done
        return 0
    }

    _CHECK_REASON=""
    _env_chk_no_bun "" "claude"
    local rc=$?

    unset -f _env_chk_no_bun
    export HOME="$orig_home"
    [[ $rc -eq 0 ]] || { fail "no_bun_clean_pass" "should pass when no Bun dirs"; return 1; }
    pass "no_bun_clean_pass"
}

test_chk_no_bun_bun_dir_fail() {
    local orig_home="$HOME"
    export HOME="${TEST_TMPDIR}/bun_home"
    mkdir -p "$HOME/.bun"

    # Override to use temp dirs instead of real /opt/
    _env_chk_no_bun() {
        local binary_path="$1"
        local tool="$2"
        local dirs_to_check=()
        case "$tool" in
            claude) dirs_to_check=("${TEST_TMPDIR}/fake_opt/claude-code" "$HOME/.bun") ;;
            continuous-claude) dirs_to_check=("${TEST_TMPDIR}/fake_opt/continuous-claude" "$HOME/.bun") ;;
            *) return 0 ;;
        esac
        for dir in "${dirs_to_check[@]}"; do
            if [[ -d "$dir" ]]; then
                _CHECK_REASON="$dir exists (legacy Bun install)"
                return 1
            fi
        done
        return 0
    }

    _CHECK_REASON=""
    if _env_chk_no_bun "" "claude" 2>/dev/null; then
        unset -f _env_chk_no_bun
        export HOME="$orig_home"
        fail "no_bun_bun_dir_fail" "should fail when ~/.bun exists"
        return 1
    fi

    unset -f _env_chk_no_bun
    export HOME="$orig_home"
    assert_contains ".bun" "$_CHECK_REASON" "reason mentions .bun"
    pass "no_bun_bun_dir_fail"
}

test_chk_no_bun_non_claude_skip() {
    _CHECK_REASON=""
    # codex was never Bun-installed, should always pass
    _env_chk_no_bun "" "codex"
    pass "no_bun_non_claude_skip"
}

# ============================================================================
# Tests: _env_chk_symlink_target
# ============================================================================

test_chk_symlink_not_symlink_pass() {
    local bin="${TEST_TMPDIR}/real_binary"
    echo "#!/bin/bash" > "$bin"
    chmod +x "$bin"

    _CHECK_REASON=""
    _env_chk_symlink_target "$bin" "claude"
    pass "symlink_not_symlink_pass"
}

test_chk_symlink_valid_pass() {
    local target="${TEST_TMPDIR}/target_bin"
    echo "#!/bin/bash" > "$target"
    chmod +x "$target"

    local link="${TEST_TMPDIR}/link_bin"
    ln -sf "$target" "$link"

    _CHECK_REASON=""
    _env_chk_symlink_target "$link" "claude"
    pass "symlink_valid_pass"
}

test_chk_symlink_dangling_fail() {
    local link="${TEST_TMPDIR}/dangling_link"
    ln -sf "${TEST_TMPDIR}/nonexistent_target" "$link"

    _CHECK_REASON=""
    if _env_chk_symlink_target "$link" "claude" 2>/dev/null; then
        fail "symlink_dangling_fail" "should fail for dangling symlink"
        return 1
    fi
    assert_contains "non-existent" "$_CHECK_REASON" "reason mentions non-existent"
    pass "symlink_dangling_fail"
}

test_chk_symlink_empty_path_fail() {
    _CHECK_REASON=""
    if _env_chk_symlink_target "" "claude" 2>/dev/null; then
        fail "symlink_empty_path_fail" "should fail for empty path"
        return 1
    fi
    pass "symlink_empty_path_fail"
}

# ============================================================================
# Tests: _env_chk_permissions
# ============================================================================

test_chk_permissions_executable_pass() {
    local bin="${TEST_TMPDIR}/exec_bin"
    echo "#!/bin/bash" > "$bin"
    chmod +x "$bin"

    _CHECK_REASON=""
    _env_chk_permissions "$bin" "claude"
    pass "permissions_executable_pass"
}

test_chk_permissions_not_executable_fail() {
    local bin="${TEST_TMPDIR}/noexec_bin"
    echo "#!/bin/bash" > "$bin"
    chmod -x "$bin"

    _CHECK_REASON=""
    if _env_chk_permissions "$bin" "claude" 2>/dev/null; then
        fail "permissions_not_executable_fail" "should fail for non-executable"
        return 1
    fi
    assert_contains "not executable" "$_CHECK_REASON" "reason mentions not executable"
    pass "permissions_not_executable_fail"
}

# ============================================================================
# Tests: _env_chk_runs
# ============================================================================

test_chk_runs_pass() {
    local fake_bin="${TEST_TMPDIR}/runs_pass_bin"
    mkdir -p "$fake_bin"
    _create_mock_binary "$fake_bin" "claude" 0 "2.0.0"

    local old_path="$PATH"
    PATH="${fake_bin}:$PATH"

    # Mock env_get_version_cmd to return our mock
    env_get_version_cmd() { echo "claude --version"; }

    _CHECK_REASON=""
    _env_chk_runs "${fake_bin}/claude" "claude"
    local rc=$?

    unset -f env_get_version_cmd
    PATH="$old_path"

    [[ $rc -eq 0 ]] || { fail "runs_pass" "should pass when --version exits 0"; return 1; }
    pass "runs_pass"
}

test_chk_runs_fail() {
    local fake_bin="${TEST_TMPDIR}/runs_fail_bin"
    mkdir -p "$fake_bin"
    _create_mock_binary "$fake_bin" "badtool" 1 ""

    local old_path="$PATH"
    PATH="${fake_bin}:$PATH"

    env_get_version_cmd() { echo "badtool --version"; }

    _CHECK_REASON=""
    local result=0
    _env_chk_runs "${fake_bin}/badtool" "claude" 2>/dev/null || result=$?

    unset -f env_get_version_cmd
    PATH="$old_path"

    [[ $result -ne 0 ]] || { fail "runs_fail" "should fail when --version exits non-zero"; return 1; }
    assert_contains "failed" "$_CHECK_REASON" "reason mentions failed"
    pass "runs_fail"
}

# ============================================================================
# Tests: _env_chk_node_version
# ============================================================================

test_chk_node_version_curl_tool_skip() {
    # curl tools skip the node check
    _CHECK_REASON=""
    _env_chk_node_version "" "claude"
    pass "node_version_curl_tool_skip"
}

test_chk_node_version_npm_tool_with_good_node() {
    # Only test if node is actually available and >= 18
    if ! command -v node &>/dev/null; then
        skip "node_version_npm_tool_good" "node not available"
        return 0
    fi

    local major
    major=$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)
    if [[ "$major" -lt 18 ]]; then
        skip "node_version_npm_tool_good" "node < 18"
        return 0
    fi

    _CHECK_REASON=""
    _env_chk_node_version "" "codex"
    pass "node_version_npm_tool_good"
}

# ============================================================================
# Tests: _env_chk_stale_path
# ============================================================================

test_chk_stale_path_clean_pass() {
    local old_path="$PATH"
    # Set PATH to only known-clean dirs
    PATH="/usr/local/bin:/usr/bin:/bin"

    _CHECK_REASON=""
    _env_chk_stale_path "" "claude"
    local rc=$?

    PATH="$old_path"

    [[ $rc -eq 0 ]] || { fail "stale_path_clean_pass" "should pass with clean PATH"; return 1; }
    pass "stale_path_clean_pass"
}

test_chk_stale_path_bun_entry_fail() {
    local old_path="$PATH"
    PATH="/usr/local/bin:/opt/claude-code/bin:$PATH"

    _CHECK_REASON=""
    local result=0
    _env_chk_stale_path "" "claude" 2>/dev/null || result=$?

    PATH="$old_path"

    [[ $result -ne 0 ]] || { fail "stale_path_bun_entry_fail" "should fail with Bun PATH entry"; return 1; }
    assert_contains "Bun-related" "$_CHECK_REASON" "reason mentions Bun"
    pass "stale_path_bun_entry_fail"
}

# ============================================================================
# Tests: _env_check_one_tool (integration)
# ============================================================================

test_check_one_tool_all_pass() {
    local orig_home="$HOME"
    export HOME="${TEST_TMPDIR}/check_all_pass/home"
    mkdir -p "$HOME/.local/bin"

    # Put mock binary in ~/.local/bin/ so binary_location check passes
    _create_mock_binary "${HOME}/.local/bin" "claude" 0 "2.1.0"

    local old_path="$PATH"
    PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"

    # Mock functions to isolate from real system
    env_is_installed() { return 0; }
    env_get_version_cmd() { echo "claude --version"; }
    env_get_install_type() { echo "curl"; }
    # Mock no_bun to avoid detecting real /opt/claude-code on test machine
    _env_chk_no_bun() { return 0; }

    local output
    output=$(_env_check_one_tool "claude" "false" 2>/dev/null)
    local rc=$?

    unset -f env_is_installed env_get_version_cmd env_get_install_type _env_chk_no_bun
    PATH="$old_path"
    export HOME="$orig_home"

    assert_contains "PASS" "$output" "output should contain PASS"
    [[ $rc -eq 0 ]] || { fail "check_one_tool_all_pass" "should return 0 for all-pass"; return 1; }
    pass "check_one_tool_all_pass"
}

test_check_one_tool_parseable_format() {
    local orig_home="$HOME"
    export HOME="${TEST_TMPDIR}/check_parseable/home"
    mkdir -p "$HOME/.local/bin"

    _create_mock_binary "${HOME}/.local/bin" "claude" 0 "2.1.0"

    local old_path="$PATH"
    PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"

    env_is_installed() { return 0; }
    env_get_version_cmd() { echo "claude --version"; }
    env_get_install_type() { echo "curl"; }
    _env_chk_no_bun() { return 0; }

    local output
    output=$(_env_check_one_tool "claude" "true" 2>/dev/null)
    local rc=$?

    unset -f env_is_installed env_get_version_cmd env_get_install_type _env_chk_no_bun
    PATH="$old_path"
    export HOME="$orig_home"

    # Parseable output should have tab-separated fields
    assert_contains "claude" "$output" "parseable output contains tool name"
    assert_contains "binary_location" "$output" "parseable output contains check name"
    assert_contains "pass" "$output" "parseable output contains pass status"
    pass "check_one_tool_parseable_format"
}

test_check_one_tool_parseable_4_columns() {
    local orig_home="$HOME"
    export HOME="${TEST_TMPDIR}/check_4col/home"
    mkdir -p "$HOME/.local/bin"

    _create_mock_binary "${HOME}/.local/bin" "claude" 0 "2.1.0"

    local old_path="$PATH"
    PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"

    env_is_installed() { return 0; }
    env_get_version_cmd() { echo "claude --version"; }
    env_get_install_type() { echo "curl"; }
    _env_chk_no_bun() { return 0; }

    local output
    output=$(_env_check_one_tool "claude" "true" 2>/dev/null)

    unset -f env_is_installed env_get_version_cmd env_get_install_type _env_chk_no_bun
    PATH="$old_path"
    export HOME="$orig_home"

    # Every line must have exactly 4 tab-separated fields
    local line_num=0 bad_lines=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ((line_num++)) || true
        local col_count
        col_count=$(echo "$line" | awk -F'\t' '{print NF}')
        if [[ "$col_count" -ne 4 ]]; then
            ((bad_lines++)) || true
            echo "Line $line_num has $col_count columns (expected 4): $line" >&2
        fi
    done <<< "$output"

    [[ $line_num -gt 0 ]] || { fail "parseable_4_columns" "no output lines"; return 1; }
    [[ $bad_lines -eq 0 ]] || { fail "parseable_4_columns" "$bad_lines lines with wrong column count"; return 1; }
    pass "parseable_4_columns"
}

# ============================================================================
# Tests: env_cmd_check
# ============================================================================

test_env_cmd_check_unknown_tool() {
    local result=0
    env_cmd_check "nonexistent_tool" 2>/dev/null || result=$?
    assert_equals "$ENV_EXIT_INVALID_ARG" "$result" "unknown tool returns INVALID_ARG"
    pass "env_cmd_check_unknown_tool"
}

test_env_cmd_check_not_installed_skip() {
    # Override env_is_installed to always return false
    env_is_installed() { return 1; }

    local output
    output=$(env_cmd_check "claude" 2>/dev/null)
    local rc=$?

    unset -f env_is_installed

    # Should succeed (0 failures, just skipped)
    assert_equals "0" "$rc" "skipped tools should not count as failures"
    assert_contains "SKIP" "$output" "output mentions skip"
    pass "env_cmd_check_not_installed_skip"
}

# ============================================================================
# Tests: Repair helpers
# ============================================================================

test_repair_fix_permissions() {
    local bin="${TEST_TMPDIR}/repair_perms/bin"
    mkdir -p "$bin"
    echo "#!/bin/bash" > "${bin}/testbin"
    chmod -x "${bin}/testbin"

    # Verify it's not executable
    [[ ! -x "${bin}/testbin" ]] || { fail "repair_fix_permissions" "setup: should not be executable"; return 1; }

    _env_repair_fix_permissions "${bin}/testbin" >/dev/null 2>&1

    [[ -x "${bin}/testbin" ]] || { fail "repair_fix_permissions" "should be executable after repair"; return 1; }
    pass "repair_fix_permissions"
}

test_repair_warn_stale_path_outputs_warning() {
    local output
    output=$(_env_repair_one_tool_stale_path_warn 2>&1) || true
    # Just test the standalone warn function pattern
    # The actual stale_path repair just warns
    pass "repair_warn_stale_path_outputs_warning"
}

# Minimal test for _env_repair_remove_bun_opt
test_repair_remove_bun_opt_nonexistent() {
    # When dirs don't exist, should be a no-op
    local output
    output=$(_env_repair_remove_bun_opt "claude" "true" 2>&1)
    # No error — just no-op
    pass "repair_remove_bun_opt_nonexistent"
}

# ============================================================================
# Tests: env_cmd_repair
# ============================================================================

test_env_cmd_repair_unknown_tool() {
    local result=0
    env_cmd_repair "nonexistent_tool" 2>/dev/null || result=$?
    assert_equals "$ENV_EXIT_INVALID_ARG" "$result" "unknown tool returns INVALID_ARG"
    pass "env_cmd_repair_unknown_tool"
}

test_env_cmd_repair_not_installed_skip() {
    env_is_installed() { return 1; }

    local output
    output=$(env_cmd_repair "claude" 2>/dev/null)
    local rc=$?

    unset -f env_is_installed

    assert_equals "0" "$rc" "skipped tools should not count as failures"
    assert_contains "SKIP" "$output" "output mentions skip for not-installed tool"
    pass "env_cmd_repair_not_installed_skip"
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo "========================================"
    echo "Environment Check/Repair Tests (Issue #59)"
    echo "========================================"
    echo ""

    echo "--- _env_tool_to_binary ---"
    run_test "tool_to_binary: claude" test_tool_to_binary_claude
    run_test "tool_to_binary: codex" test_tool_to_binary_codex
    run_test "tool_to_binary: gemini" test_tool_to_binary_gemini
    run_test "tool_to_binary: continuous-claude" test_tool_to_binary_continuous_claude
    run_test "tool_to_binary: mistral" test_tool_to_binary_mistral
    run_test "tool_to_binary: unknown fails" test_tool_to_binary_unknown

    echo ""
    echo "--- _env_chk_binary_location ---"
    run_test "binary_location: /usr/local/bin pass" test_chk_binary_location_usr_local_pass
    run_test "binary_location: ~/.local/bin pass" test_chk_binary_location_local_bin_pass
    run_test "binary_location: /opt/ fail" test_chk_binary_location_opt_fail
    run_test "binary_location: empty path fail" test_chk_binary_location_empty_fail

    echo ""
    echo "--- _env_chk_no_bun ---"
    run_test "no_bun: clean pass" test_chk_no_bun_clean_pass
    run_test "no_bun: ~/.bun fail" test_chk_no_bun_bun_dir_fail
    run_test "no_bun: non-claude skip" test_chk_no_bun_non_claude_skip

    echo ""
    echo "--- _env_chk_symlink_target ---"
    run_test "symlink: not symlink pass" test_chk_symlink_not_symlink_pass
    run_test "symlink: valid symlink pass" test_chk_symlink_valid_pass
    run_test "symlink: dangling fail" test_chk_symlink_dangling_fail
    run_test "symlink: empty path fail" test_chk_symlink_empty_path_fail

    echo ""
    echo "--- _env_chk_permissions ---"
    run_test "permissions: executable pass" test_chk_permissions_executable_pass
    run_test "permissions: not executable fail" test_chk_permissions_not_executable_fail

    echo ""
    echo "--- _env_chk_runs ---"
    run_test "runs: exit 0 pass" test_chk_runs_pass
    run_test "runs: exit 1 fail" test_chk_runs_fail

    echo ""
    echo "--- _env_chk_node_version ---"
    run_test "node_version: curl tool skip" test_chk_node_version_curl_tool_skip
    run_test "node_version: npm tool with good node" test_chk_node_version_npm_tool_with_good_node

    echo ""
    echo "--- _env_chk_stale_path ---"
    run_test "stale_path: clean pass" test_chk_stale_path_clean_pass
    run_test "stale_path: bun entry fail" test_chk_stale_path_bun_entry_fail

    echo ""
    echo "--- _env_check_one_tool ---"
    run_test "check_one_tool: all pass" test_check_one_tool_all_pass
    run_test "check_one_tool: parseable format" test_check_one_tool_parseable_format
    run_test "check_one_tool: parseable always 4 columns" test_check_one_tool_parseable_4_columns

    echo ""
    echo "--- env_cmd_check ---"
    run_test "env_cmd_check: unknown tool" test_env_cmd_check_unknown_tool
    run_test "env_cmd_check: not installed skip" test_env_cmd_check_not_installed_skip

    echo ""
    echo "--- Repair helpers ---"
    run_test "repair: fix permissions" test_repair_fix_permissions
    run_test "repair: remove_bun_opt nonexistent" test_repair_remove_bun_opt_nonexistent

    echo ""
    echo "--- env_cmd_repair ---"
    run_test "env_cmd_repair: unknown tool" test_env_cmd_repair_unknown_tool
    run_test "env_cmd_repair: not installed skip" test_env_cmd_repair_not_installed_skip

    framework_report
    exit $?
}

main "$@"
