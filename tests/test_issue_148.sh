#!/usr/bin/env bash
# tests/test_issue_148.sh - Tests for Issue #148
#
# Field report contabo03: `claude` on PATH was /usr/local/bin/claude, a root
# bash wrapper that execs the apt package's /usr/bin/claude. cac did not create
# it and its installer cannot update it. `cac env install claude --global`
# refused with "installer cannot update the copy on PATH" and sent the operator
# to `cac env check` (PASS 10/10) and `cac env repair` (refused the same way).
#
# Owner decision: cac leaves a launcher it does not manage alone and says so.
# install/update/repair report the tool as skipped (not failed), name the
# launcher, its real path and the package that owns it, and run nothing.
# `env check` shows a WARN not_managed finding instead of a clean PASS.
#
# Seams: env_update_tool, env_install_tool, env_update_all, env_cmd_update,
# env_cmd_repair, env_cmd_check. Root context through the _env_is_root seam
# (as in tests/test_issue_94_95.sh and tests/test_issue_133.sh); the upstream
# installer (_env_curl_update_with_capture) is a stub that leaves a marker.
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
# The #133 reachability guard judges modes: the scratch tree must be
# world-traversable, or every fixture would be refused for that reason instead.
chmod 755 "$TEST_TMPDIR"

_mkbin() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\nexit 0\n' > "$1"
    chmod 755 "$1"
}

# Build a layout under $TEST_TMPDIR/<name>. Sets T, ROOTHOME, MARK, LAUNCHER, REAL.
#   wrapper  : the contabo03 shape. $T/usr/local/bin/claude148 is a wrapper
#              script that execs $T/usr/bin/claude148. Neither lies in a dir the
#              installer writes ($ROOTHOME/.local/bin).
#   managed  : the #57 layout. $T/usr/local/bin/claude148 -> $ROOTHOME/.local/bin/claude148.
make_layout() {
    T="$TEST_TMPDIR/$1"
    mkdir -p "$T"; chmod 755 "$T"
    ROOTHOME="$T/root"
    mkdir -p "$ROOTHOME/.local/bin"
    MARK="$T/installer-ran"
    LAUNCHER="$T/usr/local/bin/claude148"
    mkdir -p "$T/usr/local/bin" "$T/stubbin"
    case "$2" in
        wrapper)
            _mkbin "$T/usr/bin/claude148"
            printf '#!/bin/bash\nexec %s "$@"\n' "$T/usr/bin/claude148" > "$LAUNCHER"
            chmod 755 "$LAUNCHER"
            REAL="$LAUNCHER"
            ;;
        managed)
            _mkbin "$ROOTHOME/.local/bin/claude148"
            ln -sf "$ROOTHOME/.local/bin/claude148" "$LAUNCHER"
            REAL="$ROOTHOME/.local/bin/claude148"
            ;;
    esac
}

# Put a package-manager stub on PATH: `dpkg -S <path>` answers "<pkg>: <path>"
# for every path when PKG is set, and fails ("no path found") otherwise. The
# stubbin dir comes first on PATH, so the host's real dpkg is never asked.
stub_dpkg() {
    local pkg="${1:-}"
    if [[ -n "$pkg" ]]; then
        printf '#!/bin/sh\n[ "$1" = "-S" ] || exit 2\necho "%s: $2"\n' "$pkg" > "$T/stubbin/dpkg"
    else
        printf '#!/bin/sh\necho "dpkg-query: no path found matching pattern $2" >&2\nexit 1\n' > "$T/stubbin/dpkg"
    fi
    chmod 755 "$T/stubbin/dpkg"
}

# Run "$@" (a lib/env.sh function call) in root context against the layout.
# Sets OUT (stdout+stderr) and RC.
run_root() {
    RC=0
    OUT=$(
        export HOME="$ROOTHOME" PATH="$T/stubbin:$T/usr/local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_root_home() { echo "$ROOTHOME"; }
        _env_verify_check_path() { echo "$T/usr/local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude148"; }
        env_get_detect_cmd() { echo "type -P claude148"; }
        env_get_version_cmd() { echo "claude148 --version"; }
        env_get_all_tools() { echo claude; }
        env_get_core_tools() { echo claude; }
        env_get_version() { [[ -e "$MARK" ]] && echo "2.0.0" || echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$MARK"; return 0; }
        _env_configure_claude_settings() { :; }
        "$@" 2>&1
    ) || RC=$?
}

# ----------------------------------------------------------------------------
# 148.1 — env_update_tool skips a launcher it does not manage
# ----------------------------------------------------------------------------
test_1_update_skips_unmanaged_launcher() {
    make_layout t1 wrapper
    stub_dpkg ""
    run_root env_update_tool claude user

    [[ ! -e "$MARK" ]] || { echo "installer ran for an unmanaged launcher" >&2; return 1; }
    assert_contains "skipped" "$OUT" "outcome is skipped" || return 1
    assert_contains "not managed by cac" "$OUT" "says cac does not manage it" || return 1
    assert_contains "$LAUNCHER" "$OUT" "names the launcher" || return 1
    assert_contains "no package owns it; update or remove it by hand" "$OUT" "no-owner note" || return 1
    if [[ "$OUT" == *"cac env check"* || "$OUT" == *"cac env repair"* ]]; then
        echo "message still points to env check/repair: $OUT" >&2
        return 1
    fi
    if [[ "$OUT" == *"installer cannot update"* ]]; then
        echo "old refusal text still printed: $OUT" >&2
        return 1
    fi
    [[ "$RC" -eq "$ENV_EXIT_NOT_MANAGED" ]] || { echo "rc=$RC, expected ENV_EXIT_NOT_MANAGED" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 148.2 — the message names the owning package and manager
# ----------------------------------------------------------------------------
test_2_names_owning_package() {
    make_layout t2 wrapper
    stub_dpkg "claude-code"
    run_root env_update_tool claude user

    assert_contains "belongs to package claude-code (dpkg)" "$OUT" "owner named" || return 1
    if [[ "$OUT" == *"no package owns it"* ]]; then
        echo "no-owner note printed although dpkg owns it: $OUT" >&2
        return 1
    fi
    [[ ! -e "$MARK" ]] || { echo "installer ran" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 148.3 — `cac env install claude --yes` reports the skip and exits 0
# (the first leg of the contabo03 loop: "already installed — updating" then
# a refusal and "Update failed").
# ----------------------------------------------------------------------------
test_3_install_skips_and_exits_0() {
    make_layout t3 wrapper
    stub_dpkg ""
    run_root env_cmd_install claude --yes

    assert_equals "0" "$RC" "exit code" || return 1
    [[ ! -e "$MARK" ]] || { echo "installer ran" >&2; return 1; }
    assert_contains "skipped" "$OUT" "skip reported" || return 1
    assert_contains "not managed by cac" "$OUT" "reason" || return 1
    if [[ "$OUT" == *"Update failed"* || "$OUT" == *"ERROR"* ]]; then
        echo "skip reported as a failure: $OUT" >&2
        return 1
    fi
}

# ----------------------------------------------------------------------------
# 148.4 — `cac env install --yes` (all core tools) counts it as skipped
# ----------------------------------------------------------------------------
test_4_install_all_counts_skip() {
    make_layout t4 wrapper
    stub_dpkg ""
    run_root env_cmd_install --yes

    assert_equals "0" "$RC" "exit code" || return 1
    assert_contains "Skipped (not managed by cac): Claude Code" "$OUT" "summary" || return 1
    assert_contains "Updated: 0" "$OUT" "not counted as updated" || return 1
}

# ----------------------------------------------------------------------------
# 148.5 — `cac env update` (all tools, root) lists it as skipped, exit 0
# ----------------------------------------------------------------------------
test_5_update_all_lists_skip() {
    make_layout t5 wrapper
    stub_dpkg ""
    run_root env_update_all user

    assert_equals "0" "$RC" "exit code" || return 1
    [[ ! -e "$MARK" ]] || { echo "installer ran" >&2; return 1; }
    assert_contains "Skipped (not managed by cac): Claude Code ($REAL)" "$OUT" "summary names tool and reason" || return 1
    assert_contains "Updated: 0" "$OUT" "not counted as updated" || return 1
    assert_contains "Failed: 0" "$OUT" "not counted as failed" || return 1
}

# ----------------------------------------------------------------------------
# 148.6 — `cac env update claude` (per-tool loop) exits 0 on the skip
# ----------------------------------------------------------------------------
test_6_update_one_tool_exits_0() {
    make_layout t6 wrapper
    stub_dpkg ""
    # --user makes the scope explicit, so the per-tool loop runs (the same loop
    # a root caller runs); the #71 refusal is stubbed out in run_root.
    run_root env_cmd_update claude --user

    assert_equals "0" "$RC" "exit code" || return 1
    [[ ! -e "$MARK" ]] || { echo "installer ran" >&2; return 1; }
    assert_contains "not managed by cac" "$OUT" "skip reported" || return 1
}

# ----------------------------------------------------------------------------
# 148.7 — the sudo-escalated path: the root child signals the skip, and the
# non-root parent counts it as skipped (not "Updated", not failed).
# ----------------------------------------------------------------------------
test_7_escalated_skip_counted() {
    make_layout t7 wrapper
    stub_dpkg ""

    # Child leg: an escalated child whose only tool was skipped says so.
    RC=0
    OUT=$(CAC_ENV_ESCALATED=1 run_root env_cmd_update claude --user; echo "rc=$RC")
    assert_contains "rc=$ENV_EXIT_NOT_MANAGED" "$OUT" "escalated child signals the skip" || return 1

    # Parent leg: the re-exec returns that signal.
    RC=0
    OUT=$(
        ENV_PARSED_TOOLS=(claude)
        _env_reexec_sudo_update() { echo "child: skipped"; return "$ENV_EXIT_NOT_MANAGED"; }
        _env_update_action() { echo escalate; }
        env_get_all_tools() { echo claude; }
        env_is_installed() { return 0; }
        env_update_with_escalation 2>&1
    ) || RC=$?
    assert_equals "0" "$RC" "parent exit code (out: $OUT)" || return 1
    assert_contains "Updated: 0" "$OUT" "not counted as updated" || return 1
    assert_contains "Skipped (not managed by cac): Claude Code" "$OUT" "parent summary" || return 1
}

# Snapshot of every path, type, mode and size under $T (not the marker).
_tree_state() { find "$T" -path "$T/installer-ran" -prune -o -printf '%p %y %m %s %l\n' | sort; }

# ----------------------------------------------------------------------------
# 148.8 — `cac env repair claude --yes` reports the skip, exits 0, changes
# nothing on disk (the second leg of the contabo03 loop).
# ----------------------------------------------------------------------------
test_8_repair_skips_changes_nothing() {
    make_layout t8 wrapper
    stub_dpkg ""
    # Make a repair arm want to act: a non-executable launcher would trip the
    # permissions check, whose repair is chmod +x on a file cac does not own.
    chmod 644 "$LAUNCHER"
    local before after
    before=$(_tree_state)
    run_root env_cmd_repair claude --yes
    after=$(_tree_state)

    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    [[ ! -e "$MARK" ]] || { echo "installer ran" >&2; return 1; }
    assert_contains "skipped" "$OUT" "skip reported" || return 1
    assert_contains "not managed by cac" "$OUT" "reason" || return 1
    assert_contains "Skipped: 1" "$OUT" "counted as skipped" || return 1
    assert_equals "$before" "$after" "nothing on disk changed" || return 1
}

# Run `env check` in the given context with the ten standard checks stubbed to
# pass: the fixture lives under /tmp, so binary_location & co. would fail for
# reasons unrelated to this issue. Only the not_managed finding is under test.
# $1 = "root" (HOME is root's) or "user" (HOME is another user's). Rest: args.
run_check() {
    local ctx="$1"; shift
    RC=0
    OUT=$(
        local n home="$ROOTHOME"
        for n in "${_ENV_CHECK_NAMES[@]}"; do eval "_env_chk_$n() { return 0; }"; done
        if [[ "$ctx" == "user" ]]; then
            home="$T/home/rob"
            mkdir -p "$home/.local/bin"
            _env_is_root() { return 1; }
        else
            _env_is_root() { return 0; }
        fi
        export HOME="$home" PATH="$T/stubbin:$T/usr/local/bin:/bin:/usr/bin"
        _env_root_home() { echo "$ROOTHOME"; }
        _env_tool_to_binary() { echo "claude148"; }
        env_get_detect_cmd() { echo "type -P claude148"; }
        env_get_all_tools() { echo claude; }
        env_cmd_check "$@" 2>&1
    ) || RC=$?
}

# ----------------------------------------------------------------------------
# 148.9 — `cac env check claude`: WARN not_managed, no clean PASS, exit 0
# ----------------------------------------------------------------------------
test_9_check_warns_not_managed() {
    make_layout t9 wrapper
    stub_dpkg "claude-code"
    run_check root claude

    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "[WARN] not_managed: launcher on PATH $LAUNCHER" "$OUT" "WARN line with path" || return 1
    assert_contains "belongs to package claude-code (dpkg)" "$OUT" "owner note" || return 1
    if [[ "$OUT" == *"PASS (11/11)"* ]]; then
        echo "still reads as a clean PASS: $OUT" >&2
        return 1
    fi
    assert_contains "Passed: 0  Failed: 0  Skipped: 0  Warnings: 1" "$OUT" "summary counts it as a warning, not a pass" || return 1

    # Machine-readable output carries the same finding as a warn row.
    run_check root claude --parseable
    assert_equals "0" "$RC" "parseable exit code" || return 1
    assert_contains "$(printf 'claude\tnot_managed\twarn\tlauncher on PATH %s' "$LAUNCHER")" "$OUT" "parseable warn row" || return 1
}

# ----------------------------------------------------------------------------
# 148.10 — managed layouts are unchanged: no WARN, clean PASS, as root and as
# a non-root user looking at the #57 layout root's installer manages.
# ----------------------------------------------------------------------------
test_10_check_managed_layout_unchanged() {
    make_layout t10 managed
    stub_dpkg ""
    run_check root claude
    assert_equals "0" "$RC" "exit code" || return 1
    assert_contains "PASS (11/11)" "$OUT" "root: clean PASS" || return 1
    [[ "$OUT" != *"not_managed"* ]] || { echo "root: managed layout flagged: $OUT" >&2; return 1; }

    run_check user claude
    assert_contains "PASS (11/11)" "$OUT" "user: clean PASS (out: $OUT)" || return 1
    [[ "$OUT" != *"not_managed"* ]] || { echo "user: #57 layout flagged: $OUT" >&2; return 1; }

    # The update path does not skip it as not managed. (It is refused by the
    # #133 reachability guard instead, because the payload sits in root's
    # home; that refusal is covered by tests/test_issue_133.sh.)
    run_root env_update_tool claude user
    [[ "$OUT" != *"not managed by cac"* ]] || { echo "update skipped a managed layout: $OUT" >&2; return 1; }
    [[ "$RC" -ne "$ENV_EXIT_NOT_MANAGED" ]] || { echo "update returned the skip code" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 148.11 — a legacy Bun copy cac itself created (/opt/claude-code, #56) is cac's
# own debt, not a foreign launcher: repair still routes it to the Bun cleanup
# and check does not call it "not managed". The legacy dir is redirected into
# the fixture through _env_legacy_bun_dirs, since /opt cannot be written here.
# ----------------------------------------------------------------------------
test_11_legacy_bun_copy_still_repaired() {
    make_layout t11 wrapper
    stub_dpkg ""
    local legacy="$T/opt/claude-code"
    _mkbin "$legacy/bin/claude148"
    ln -sf "$legacy/bin/claude148" "$LAUNCHER"

    RC=0
    OUT=$(
        export HOME="$ROOTHOME" PATH="$T/stubbin:$T/usr/local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_root_home() { echo "$ROOTHOME"; }
        _env_tool_to_binary() { echo "claude148"; }
        _env_legacy_bun_dirs() { echo "$legacy"; }
        _ENV_CHECK_NAMES=(no_bun)                       # isolate the Bun arm
        _env_repair_remove_bun_opt() { echo "REMOVE_BUN_CALLED"; }
        _env_repair_remove_bun_home() { :; }
        _env_repair_one_tool claude true 2>&1
    ) || RC=$?

    assert_contains "REMOVE_BUN_CALLED" "$OUT" "legacy Bun copy routed to the cleanup" || return 1
    [[ "$OUT" != *"not managed by cac"* ]] || { echo "legacy Bun copy skipped as not managed: $OUT" >&2; return 1; }
}

echo "========================================"
echo "Issue #148 Tests"
echo "========================================"

run_test "148.1  env_update_tool skips an unmanaged launcher, runs nothing" test_1_update_skips_unmanaged_launcher
run_test "148.2  the skip names the owning package and manager" test_2_names_owning_package
run_test "148.3  env install <tool> reports the skip and exits 0" test_3_install_skips_and_exits_0
run_test "148.4  env install (all) counts the tool as skipped" test_4_install_all_counts_skip
run_test "148.5  env update (all) lists the tool as skipped, exit 0" test_5_update_all_lists_skip
run_test "148.6  env update <tool> exits 0 on the skip" test_6_update_one_tool_exits_0
run_test "148.7  escalated child signals the skip, parent counts it" test_7_escalated_skip_counted
run_test "148.8  env repair reports the skip and changes nothing" test_8_repair_skips_changes_nothing
run_test "148.9  env check shows WARN not_managed, no clean PASS, exit 0" test_9_check_warns_not_managed
run_test "148.10 managed layouts unchanged (check + update)" test_10_check_managed_layout_unchanged
run_test "148.11 legacy Bun copy (/opt, #56) is still repaired" test_11_legacy_bun_copy_still_repaired

framework_report
