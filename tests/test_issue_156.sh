#!/usr/bin/env bash
# tests/test_issue_156.sh - Tests for Issue #156
#
# The env command layer read "$EUID" directly in _env_parse_scope_args,
# env_install_tool, env_update_tool (global scope) and env_cmd_update, while
# the guards inside env_update_tool used the _env_is_root seam. A non-root
# test suite could therefore not reach `--global` or the direct root path of
# env_cmd_update; #148 had to test its acceptance commands through --user.
#
# Every root check in lib/env.sh now goes through _env_is_root, except the
# sudo escalation guard in _env_reexec_sudo_update, which keeps the real EUID
# (see the comment there).
#
# Seams: env_cmd_install, env_cmd_update. Root context through the
# _env_is_root seam; the upstream installer is a `curl` stub on PATH that
# prints a script leaving a marker, so nothing is downloaded.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=lib/env.sh
source "$REPO_DIR/lib/env.sh"

framework_init
chmod 755 "$TEST_TMPDIR"

# Build a layout under $TEST_TMPDIR/<name>. Sets T, ROOTHOME, MARK.
# $T/stubbin/curl ignores its URL and prints a shell script that creates $MARK,
# standing in for the upstream installer piped into bash.
make_layout() {
    T="$TEST_TMPDIR/$1"
    ROOTHOME="$T/root"
    MARK="$T/installer-ran"
    mkdir -p "$ROOTHOME/.local/bin" "$T/stubbin"
    chmod 755 "$T" "$ROOTHOME"
    printf '#!/bin/sh\necho "touch %s"\n' "$MARK" > "$T/stubbin/curl"
    chmod 755 "$T/stubbin/curl"
}

# Run "$@" (a lib/env.sh function call) with the given root context.
# $1 = true|false for _env_is_root. Sets OUT (stdout+stderr) and RC.
run_ctx() {
    local root_ctx="$1"; shift
    RC=0
    OUT=$(
        export HOME="$ROOTHOME" PATH="$T/stubbin:/bin:/usr/bin"
        unset CAC_ENV_ESCALATED
        _env_is_root() { [[ "$root_ctx" == "true" ]]; }
        _env_root_home() { echo "$ROOTHOME"; }
        env_is_installed() { [[ "${INSTALLED:-}" == "1" || -e "$MARK" ]]; }
        env_get_version() { [[ -e "$MARK" ]] && echo "2.0.0" || echo "1.0.0"; }
        _env_global_install_exists() { return 0; }
        _env_installer_can_update() { return 0; }
        _env_binary_reachable_by_all() { return 0; }
        _env_diag_preflight_curl() { return 0; }
        _env_post_install_symlink() { echo "POST_INSTALL_SYMLINK $1"; }
        _env_curl_update_with_capture() { : > "$MARK"; return 0; }
        _env_configure_claude_settings() { :; }
        env_update_with_escalation() { echo "ESCALATION_PATH"; return 0; }
        "$@" 2>&1
    ) || RC=$?
}

# ----------------------------------------------------------------------------
# 156.1 — `cac env install claude --global --yes` in root context installs
# ----------------------------------------------------------------------------
test_1_install_global_as_root() {
    make_layout t1
    INSTALLED=0 run_ctx true env_cmd_install claude --global --yes

    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    [[ -e "$MARK" ]] || { echo "installer did not run: $OUT" >&2; return 1; }
    assert_contains "POST_INSTALL_SYMLINK claude" "$OUT" "global install symlinks into /usr/local/bin" || return 1
    [[ "$OUT" != *"requires root"* ]] || { echo "root context refused: $OUT" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 156.2 — the same command outside root context is still refused
# ----------------------------------------------------------------------------
test_2_install_global_refused_non_root() {
    make_layout t2
    INSTALLED=0 run_ctx false env_cmd_install claude --global --yes

    [[ "$RC" -ne 0 ]] || { echo "non-root --global succeeded: $OUT" >&2; return 1; }
    assert_contains "Scope --global requires root privileges." "$OUT" "refusal text" || return 1
    [[ ! -e "$MARK" ]] || { echo "installer ran for a non-root caller" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 156.3 — `cac env update claude --global` in root context runs the installer
# ----------------------------------------------------------------------------
test_3_update_global_as_root() {
    make_layout t3
    INSTALLED=1 run_ctx true env_cmd_update claude --global

    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    [[ -e "$MARK" ]] || { echo "installer did not run: $OUT" >&2; return 1; }
    [[ "$OUT" != *"requires root"* ]] || { echo "root context refused: $OUT" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 156.4 — `cac env update claude` (implicit scope) in root context takes the
# direct root path, not the #79 sudo escalation path
# ----------------------------------------------------------------------------
test_4_update_implicit_as_root_skips_escalation() {
    make_layout t4
    INSTALLED=1 run_ctx true env_cmd_update claude

    [[ "$OUT" != *"ESCALATION_PATH"* ]] || { echo "root caller took the escalation path: $OUT" >&2; return 1; }
    [[ -e "$MARK" ]] || { echo "installer did not run: $OUT" >&2; return 1; }
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
}

# ----------------------------------------------------------------------------
# 156.5 — implicit scope outside root context still escalates (#79)
# ----------------------------------------------------------------------------
test_5_update_implicit_non_root_escalates() {
    make_layout t5
    INSTALLED=1 run_ctx false env_cmd_update claude

    assert_contains "ESCALATION_PATH" "$OUT" "non-root implicit scope escalates" || return 1
}

# ----------------------------------------------------------------------------
# 156.6 — no direct EUID root check is left outside the documented exception
# ----------------------------------------------------------------------------
test_6_no_stray_euid_checks() {
    local stray
    # Code lines that compare EUID, minus the seam itself and the documented
    # escalation guard (marked "#156: real EUID").
    stray=$(grep -nE 'EUID[^=]*" -(eq|ne) 0' "$REPO_DIR/lib/env.sh" \
        | grep -vE '^[0-9]+:\s*#' \
        | grep -v '#156: real EUID' \
        | grep -v '^[0-9]*:    \[\[ "\${EUID:-\$(id -u)}" -eq 0 \]\]$' || true)
    [[ -z "$stray" ]] || { echo "direct EUID checks outside the seam:" >&2; echo "$stray" >&2; return 1; }
}

echo "========================================"
echo "Issue #156 Tests"
echo "========================================"

run_test "156.1 env install claude --global --yes runs in root context" test_1_install_global_as_root
run_test "156.2 env install --global is refused outside root context" test_2_install_global_refused_non_root
run_test "156.3 env update claude --global runs in root context" test_3_update_global_as_root
run_test "156.4 env update claude as root takes the direct path" test_4_update_implicit_as_root_skips_escalation
run_test "156.5 env update claude as non-root escalates (#79)" test_5_update_implicit_non_root_escalates
run_test "156.6 every EUID root check goes through the seam" test_6_no_stray_euid_checks

framework_report
