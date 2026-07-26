#!/usr/bin/env bash
# tests/test_issue_94_95.sh - Tests for Issues #94 and #95:
#
#   #94  `cac env update` sudo escalation could never update Claude Code:
#        claude.ai/install.sh hard-refuses a sudo invocation, and even with the
#        override it would write /root/.local/bin — not the copy users run.
#   #95  Escalated `cac env update mistral` always failed AND mutated /root:
#        the installer took the `uv tool upgrade` path in root's context (uv
#        state is per-user) after bootstrapping uv/uvx into /root/.local/bin.
#
# The fix, all in lib/env.sh:
#   * _ENV_CURL_TARGET_DIR now records the dir(s) each installer actually
#     WRITES, with '$HOME' stored literally and expanded at call time (it was
#     baked at source time, so a sudo re-exec described the wrong directory).
#   * _env_installer_target_dirs / _env_installer_can_update — a pre-flight
#     guard that refuses when neither the launcher on PATH nor its payload
#     lives in a dir this installer writes.
#   * The guard runs in ROOT CONTEXT ONLY (_env_is_root), which is what makes
#     the Issue #79 contract hold structurally: _env_update_action is consulted
#     only by env_update_with_escalation, which env_cmd_update enters only for
#     a non-root caller, so a "local" verdict can never reach the guard.
#   * CLAUDE_INSTALL_ALLOW_SUDO=1 is forwarded to the claude installer in the
#     escalated shape, via optional KEY=VALUE args to
#     _env_curl_update_with_capture.
#
# Network-free, sudo-free, and root-free: every layout is built under a fake
# HOME inside TEST_TMPDIR, curl is never invoked, and the _env_is_root seam
# makes the root-only branches reachable from a normal user.
#
# Test inventory:
#   94/95.1   registry expands $HOME at call time; list splits; #73 contract
#   94/95.2   A1 direct install in a target dir            -> allowed
#   94/95.3   A2 Issue #57 symlink into root's home        -> allowed (payload)
#   94/95.4   A3 uv shim symlink -> tools payload          -> allowed
#   94/95.5   A4 uv shim as a real file, payload elsewhere -> allowed (launcher)
#   94/95.6   R1 #94 repro: wrapper into unmanaged tree    -> refused
#   94/95.7   R2 #95 repro: foreign uv tools dir           -> refused
#   94/95.8   A5 safe defaults (unregistered / off PATH)   -> allowed
#   94/95.9   refusal mutates NOTHING under root's HOME
#   94/95.10  Issue #71 refusal still short-circuits first
#   94/95.11  guard unreachable on the non-root local path
#   94/95.12  ENV_DIAG_CAUSE_FILE carries the cause
#   94/95.13  installer env forwarding (and no-arg parity)
#   94/95.14  override never set for a non-root caller
#   94/95.15  override set in the root+sudo shape

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "${SCRIPT_DIR}/test_framework.sh"
# shellcheck source=lib/env.sh
source "${REPO_DIR}/lib/env.sh"

framework_init

# Build a scratch dir for one test.
_scratch() {
    local d="${TEST_TMPDIR}/$1"
    mkdir -p "$d"
    echo "$d"
}

# Create an executable regular file (a "real" binary or a wrapper script).
_mkbin() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\nexit 0\n' > "$1"
    chmod +x "$1"
}

# ----------------------------------------------------------------------------
# 94/95.1 — registry is expanded at CALL time and split into a list
# ----------------------------------------------------------------------------
test_1_registry_expansion() {
    local T; T=$(_scratch t1)
    export HOME="$T"

    local got
    got=$(_env_installer_target_dirs mistral | tr '\n' ' ')
    assert_equals "$T/.local/share/uv/tools $T/.local/bin " "$got" \
        "mistral dirs (payload first)" || return 1

    got=$(_env_installer_target_dirs claude | tr '\n' ' ')
    assert_equals "$T/.local/bin " "$got" "claude dirs" || return 1

    # Regression for the /opt/continuous-claude mis-registration: its installer
    # writes $HOME/.local/bin (INSTALL_DIR default), never /opt.
    got=$(_env_installer_target_dirs continuous-claude | tr '\n' ' ')
    assert_equals "$T/.local/bin " "$got" "continuous-claude dirs" || return 1

    # Unregistered tool yields nothing (safe default for both consumers).
    got=$(_env_installer_target_dirs codex)
    assert_equals "" "$got" "unregistered tool" || return 1

    # Issue #73 single-value contract preserved: FIRST dir only.
    got=$(_env_diag_target_dir mistral)
    assert_equals "$T/.local/share/uv/tools" "$got" "#73 preflight target" || return 1

    # Call-time expansion is the point: a second HOME yields new answers from
    # the same already-sourced registry (this is the sudo/HOME=/root case).
    export HOME="$T/other"
    got=$(_env_diag_target_dir claude)
    assert_equals "$T/other/.local/bin" "$got" "target after HOME change" || return 1
}

# ----------------------------------------------------------------------------
# 94/95.2 — A1: a direct install inside a target dir is updatable
# ----------------------------------------------------------------------------
test_2_accept_direct_install() {
    local T; T=$(_scratch t2)
    export HOME="$T/root"
    _mkbin "$HOME/.local/bin/claude94"
    export PATH="$HOME/.local/bin:$PATH"
    _env_tool_to_binary() { echo "claude94"; }

    _env_installer_can_update claude || {
        echo "direct install should be accepted (real=$_ENV_INSTALLER_REAL_PATH)" >&2
        return 1
    }
}

# ----------------------------------------------------------------------------
# 94/95.3 — A2: the Issue #57 layout (global symlink into root's home)
# ----------------------------------------------------------------------------
test_3_accept_issue57_symlink() {
    local T; T=$(_scratch t3)
    export HOME="$T/root"
    _mkbin "$HOME/.local/bin/claude94"
    mkdir -p "$T/usr/local/bin"
    ln -sf "$HOME/.local/bin/claude94" "$T/usr/local/bin/claude94"
    # PATH prefers the global copy, as it does in the escalated child.
    export PATH="$T/usr/local/bin:$HOME/.local/bin:$PATH"
    _env_tool_to_binary() { echo "claude94"; }

    _env_installer_can_update claude || {
        echo "#57 symlink layout should be accepted via the payload clause" >&2
        return 1
    }
    assert_equals "$T/usr/local/bin/claude94" "$_ENV_INSTALLER_LAUNCHER_PATH" "launcher" || return 1
    assert_equals "$HOME/.local/bin/claude94" "$_ENV_INSTALLER_REAL_PATH" "payload" || return 1
}

# ----------------------------------------------------------------------------
# 94/95.4 — A3: native uv layout, shim symlink -> tools payload
# Direct regression test for the Codex BLOCKING-1 false-refusal finding.
# ----------------------------------------------------------------------------
test_4_accept_uv_shim_symlink() {
    local T; T=$(_scratch t4)
    export HOME="$T/root"
    local payload="$HOME/.local/share/uv/tools/mistral-vibe/bin/vibe94"
    _mkbin "$payload"
    mkdir -p "$HOME/.local/bin"
    ln -sf "$payload" "$HOME/.local/bin/vibe94"
    export PATH="$HOME/.local/bin:$PATH"
    _env_tool_to_binary() { echo "vibe94"; }

    _env_installer_can_update mistral || {
        echo "native uv layout must be accepted (real=$_ENV_INSTALLER_REAL_PATH)" >&2
        return 1
    }
}

# ----------------------------------------------------------------------------
# 94/95.5 — A4: uv shim as a REAL file whose payload is outside every listed
# dir. Only the launcher clause can accept this — proves launcher-vs-payload
# acceptance rather than mere symlink-following.
# ----------------------------------------------------------------------------
test_5_accept_launcher_clause() {
    local T; T=$(_scratch t5)
    export HOME="$T/root"
    _mkbin "$HOME/.local/bin/vibe94"        # real file, not a symlink
    export PATH="$HOME/.local/bin:$PATH"
    _env_tool_to_binary() { echo "vibe94"; }

    _env_installer_can_update mistral || {
        echo "shim-as-real-file must be accepted via the launcher clause" >&2
        return 1
    }
    # Launcher and payload are the same path here; the point is that the match
    # came from the uv BIN dir, not the uv tools dir.
    assert_equals "$HOME/.local/bin/vibe94" "$_ENV_INSTALLER_REAL_PATH" "payload" || return 1
}

# ----------------------------------------------------------------------------
# 94/95.6 — R1: the #94 repro. A script wrapper delegating into an unmanaged
# tree (on the real host: /opt/claude-code, a legacy Bun install).
# ----------------------------------------------------------------------------
test_6_refuse_wrapper_into_unmanaged_tree() {
    local T; T=$(_scratch t6)
    export HOME="$T/root"
    mkdir -p "$HOME/.local/bin" "$T/opt/claude-code"
    _mkbin "$T/opt/claude-code/claude94"
    mkdir -p "$T/usr/local/bin"
    printf '#!/bin/bash\nexec %s/opt/claude-code/claude94 "$@"\n' "$T" \
        > "$T/usr/local/bin/claude94"
    chmod +x "$T/usr/local/bin/claude94"
    export PATH="$T/usr/local/bin:$HOME/.local/bin:$PATH"
    _env_tool_to_binary() { echo "claude94"; }

    if _env_installer_can_update claude; then
        echo "wrapper into an unmanaged tree must be refused" >&2
        return 1
    fi
    assert_equals "$T/usr/local/bin/claude94" "$_ENV_INSTALLER_REAL_PATH" "real path" || return 1
}

# ----------------------------------------------------------------------------
# 94/95.7 — R2: the #95 repro. Global vibe resolving into a uv tools dir that
# root's own uv registry knows nothing about.
# ----------------------------------------------------------------------------
test_7_refuse_foreign_uv_tools_dir() {
    local T; T=$(_scratch t7)
    export HOME="$T/root"
    mkdir -p "$HOME/.local/share/uv/tools" "$HOME/.local/bin"
    local foreign="$T/usr/local/share/uv/tools/mistral-vibe/bin/vibe94"
    _mkbin "$foreign"
    mkdir -p "$T/usr/local/bin"
    ln -sf "$foreign" "$T/usr/local/bin/vibe94"
    export PATH="$T/usr/local/bin:$HOME/.local/bin:$PATH"
    _env_tool_to_binary() { echo "vibe94"; }

    if _env_installer_can_update mistral; then
        echo "foreign uv tools dir must be refused" >&2
        return 1
    fi
    assert_equals "$foreign" "$_ENV_INSTALLER_REAL_PATH" "real path" || return 1
}

# ----------------------------------------------------------------------------
# 94/95.8 — A5: safe defaults. Never block on unknowns.
# ----------------------------------------------------------------------------
test_8_safe_defaults() {
    local T; T=$(_scratch t8)
    export HOME="$T/root"

    # Unregistered tool: no dirs -> allowed regardless of layout.
    _env_tool_to_binary() { echo "codex94"; }
    _env_installer_can_update codex || { echo "unregistered tool must be allowed" >&2; return 1; }

    # Registered tool whose binary is not on PATH at all -> allowed.
    _env_tool_to_binary() { echo "definitely-not-on-path-94"; }
    _env_installer_can_update claude || { echo "off-PATH binary must be allowed" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 94/95.9 — the refusal must mutate NOTHING under root's HOME.
# This is what #95 actually asks for: the old code bootstrapped uv+uvx into
# /root/.local/bin before failing. Sentinels prove ordering; the find(1)
# assertions prove absence of mutation.
# ----------------------------------------------------------------------------
test_9_refusal_has_no_side_effects() {
    local T; T=$(_scratch t9)
    export HOME="$T/root"
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/uv/tools"

    # R2 layout: global vibe into a uv tools dir root does not own.
    local foreign="$T/usr/local/share/uv/tools/mistral-vibe/bin/vibe94"
    _mkbin "$foreign"
    mkdir -p "$T/usr/local/bin"
    ln -sf "$foreign" "$T/usr/local/bin/vibe94"

    local marker_dir="$T/markers"; mkdir -p "$marker_dir"

    local out rc=0
    out=$(
        # No curl anywhere on PATH: if the guard ever let execution through,
        # the failure mode would be loud rather than silent.
        export PATH="$T/usr/local/bin:$HOME/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_tool_to_binary() { echo "vibe94"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }   # keep #71 from pre-empting
        _env_diag_preflight_curl() { : > "$marker_dir/preflight"; return 0; }
        _env_curl_update_with_capture() { : > "$marker_dir/installer"; return 0; }
        env_update_tool mistral user 2>&1
    ) || rc=$?

    [[ "$rc" -ne 0 ]] || { echo "expected non-zero exit, got 0" >&2; return 1; }
    assert_contains "Launcher on PATH:" "$out" "refusal message" || return 1
    assert_contains "$foreign" "$out" "refusal names the real path" || return 1

    [[ -e "$marker_dir/preflight" ]] && { echo "pre-flight ran despite refusal" >&2; return 1; }
    [[ -e "$marker_dir/installer" ]] && { echo "installer ran despite refusal" >&2; return 1; }

    # The binding assertions: root's HOME is untouched.
    local leaked
    leaked=$(find "$HOME/.local/bin" -mindepth 1 2>/dev/null)
    assert_equals "" "$leaked" "no files created in root's ~/.local/bin" || return 1
    leaked=$(find "$HOME/.local/share/uv/tools" -mindepth 1 2>/dev/null)
    assert_equals "" "$leaked" "no files created in root's uv tools dir" || return 1
    return 0
}

# ----------------------------------------------------------------------------
# 94/95.10 — ordering: the Issue #71 refusal still fires FIRST.
# ----------------------------------------------------------------------------
test_10_issue71_refusal_still_first() {
    if _env_is_root; then
        echo "SKIP-CONDITION: running as root" >&2
        return 0
    fi
    local T; T=$(_scratch t10)
    export HOME="$T/root"
    mkdir -p "$HOME/.local/bin"
    local marker_dir="$T/markers"; mkdir -p "$marker_dir"

    local out rc=0
    out=$(
        export PATH="$HOME/.local/bin:/bin:/usr/bin"
        _env_tool_to_binary() { echo "claude94"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 0; }   # #71 condition
        _env_installer_can_update() { : > "$marker_dir/guard"; return 1; }
        _env_diag_preflight_curl() { : > "$marker_dir/preflight"; return 0; }
        env_update_tool claude user 2>&1
    ) || rc=$?

    [[ "$rc" -ne 0 ]] || { echo "expected non-zero exit, got 0" >&2; return 1; }
    assert_contains "system-wide install" "$out" "#71 refusal text" || return 1
    [[ -e "$marker_dir/guard" ]] && { echo "guard ran before the #71 refusal" >&2; return 1; }
    [[ -e "$marker_dir/preflight" ]] && { echo "pre-flight ran before the #71 refusal" >&2; return 1; }
    return 0
}

# ----------------------------------------------------------------------------
# 94/95.11 — the guard is unreachable on the non-root local-update path.
#
# SCOPE OF THIS CLAIM: it proves one link of the Issue #79 argument — that a
# non-root user-scope update is never refused by the guard, even in a layout
# the guard would refuse under root. It does NOT by itself prove the whole
# dispatch argument (that env_cmd_update only enters
# env_update_with_escalation for non-root callers, and that "local" tools are
# updated at user scope); that rests on the existing Issue #79 coverage in
# tests/test_issue_79.sh.
# ----------------------------------------------------------------------------
test_11_guard_unreachable_when_non_root() {
    if _env_is_root; then
        echo "SKIP-CONDITION: running as root" >&2
        return 0
    fi
    local T; T=$(_scratch t11)
    export HOME="$T/root"
    mkdir -p "$HOME/.local/bin"

    # R1 layout — refused under root, must NOT be refused here.
    mkdir -p "$T/opt/claude-code" "$T/usr/local/bin"
    _mkbin "$T/opt/claude-code/claude94"
    printf '#!/bin/bash\nexec %s/opt/claude-code/claude94 "$@"\n' "$T" \
        > "$T/usr/local/bin/claude94"
    chmod +x "$T/usr/local/bin/claude94"

    local out rc=0
    out=$(
        export PATH="$T/usr/local/bin:$HOME/.local/bin:/bin:/usr/bin"
        _env_tool_to_binary() { echo "claude94"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        # Stop before any real work; we only care whether the guard fired.
        _env_diag_preflight_curl() { return 1; }
        env_update_tool claude user 1 2>&1
    ) || rc=$?

    # It stops at the stubbed pre-flight, but must NOT carry the guard's text.
    if [[ "$out" == *"Launcher on PATH:"* ]]; then
        echo "guard refused a non-root update: $out" >&2
        return 1
    fi

    # Control arm — without it this test is vacuous: it would also pass against
    # a build that has no guard at all. Prove the layout IS guard-refusable and
    # that only the root gate spared it above.
    out=$(
        export PATH="$T/usr/local/bin:$HOME/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_tool_to_binary() { echo "claude94"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_diag_preflight_curl() { return 1; }
        env_update_tool claude user 1 2>&1
    ) || true
    assert_contains "Launcher on PATH:" "$out" "same layout refused under root" || return 1
    return 0
}

# ----------------------------------------------------------------------------
# 94/95.12 — the cause one-liner reaches ENV_DIAG_CAUSE_FILE, so
# env_update_all's batch summary can name it (parity with Issue #73).
# ----------------------------------------------------------------------------
test_12_cause_file_written() {
    local T; T=$(_scratch t12)
    export HOME="$T/root"
    mkdir -p "$HOME/.local/bin"
    local cause_file="$T/cause"; : > "$cause_file"

    mkdir -p "$T/usr/local/bin" "$T/elsewhere"
    _mkbin "$T/elsewhere/vibe94"
    ln -sf "$T/elsewhere/vibe94" "$T/usr/local/bin/vibe94"

    (
        export PATH="$T/usr/local/bin:$HOME/.local/bin:/bin:/usr/bin"
        export ENV_DIAG_CAUSE_FILE="$cause_file"
        _env_is_root() { return 0; }
        _env_tool_to_binary() { echo "vibe94"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        env_update_tool mistral user
    ) >/dev/null 2>&1

    local cause; cause=$(cat "$cause_file")
    assert_contains "installer cannot update the copy on PATH" "$cause" "cause line" || return 1
    assert_contains "$T/elsewhere/vibe94" "$cause" "cause names the real path" || return 1
}

# ----------------------------------------------------------------------------
# 94/95.13 — _env_curl_update_with_capture forwards KEY=VALUE args into the
# installer's environment, and the no-arg form is unchanged.
# ----------------------------------------------------------------------------
test_13_installer_env_forwarding() {
    local T; T=$(_scratch t13)
    mkdir -p "$T/bin"
    # Stub curl: "download" an installer that reports what it sees.
    cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == "-o" ]] && { out="$2"; shift 2; continue; }
    shift
done
printf '#!/usr/bin/env bash\necho "SAW=${CLAUDE_INSTALL_ALLOW_SUDO:-unset}"\n' > "$out"
exit 0
EOF
    chmod +x "$T/bin/curl"

    local with without
    with=$(
        export PATH="$T/bin:$PATH"
        _env_curl_update_with_capture claude "https://example/i.sh" "Claude Code" \
            CLAUDE_INSTALL_ALLOW_SUDO=1 2>&1
    )
    assert_contains "SAW=1" "$with" "forwarded assignment" || return 1

    without=$(
        export PATH="$T/bin:$PATH"
        _env_curl_update_with_capture claude "https://example/i.sh" "Claude Code" 2>&1
    )
    assert_contains "SAW=unset" "$without" "no-arg parity" || return 1
}

# ----------------------------------------------------------------------------
# 94/95.14 — the override is NEVER set for a non-root caller, even with
# SUDO_USER present in the environment.
# ----------------------------------------------------------------------------
test_14_override_never_set_non_root() {
    if _env_is_root; then
        echo "SKIP-CONDITION: running as root" >&2
        return 0
    fi
    local T; T=$(_scratch t14)
    export HOME="$T/root"
    _mkbin "$HOME/.local/bin/claude94"
    local seen="$T/seen"; : > "$seen"

    (
        export PATH="$HOME/.local/bin:/bin:/usr/bin"
        export SUDO_USER="someone"
        _env_tool_to_binary() { echo "claude94"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { printf '%s' "${4:-}" > "$seen"; return 0; }
        env_update_tool claude user 1
    ) >/dev/null 2>&1

    assert_equals "" "$(cat "$seen")" "4th arg for a non-root caller" || return 1

    # Control arm — without it this test is vacuous: it would also pass against
    # a build that never forwards any 4th arg. Prove the emptiness came from
    # the non-root condition, not from an absent mechanism.
    (
        export PATH="$HOME/.local/bin:/bin:/usr/bin"
        export SUDO_USER="someone"
        _env_is_root() { return 0; }
        _env_tool_to_binary() { echo "claude94"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { printf '%s' "${4:-}" > "$seen"; return 0; }
        env_update_tool claude user 1
    ) >/dev/null 2>&1

    assert_equals "CLAUDE_INSTALL_ALLOW_SUDO=1" "$(cat "$seen")" "same layout under root" || return 1
}

# ----------------------------------------------------------------------------
# 94/95.15 — the override IS set in the root + sudo shape (the Issue #79
# escalated child). Reachable without real root thanks to the seam.
# ----------------------------------------------------------------------------
test_15_override_set_root_sudo() {
    local T; T=$(_scratch t15)
    export HOME="$T/root"
    _mkbin "$HOME/.local/bin/claude94"
    local seen="$T/seen"; : > "$seen"

    (
        export PATH="$HOME/.local/bin:/bin:/usr/bin"
        export SUDO_USER="someone"
        _env_is_root() { return 0; }
        _env_tool_to_binary() { echo "claude94"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { printf '%s' "${4:-}" > "$seen"; return 0; }
        env_update_tool claude user 1
    ) >/dev/null 2>&1

    assert_equals "CLAUDE_INSTALL_ALLOW_SUDO=1" "$(cat "$seen")" "4th arg in the escalated shape" || return 1
}

echo "========================================"
echo "Issue #94/#95 Tests"
echo "========================================"

run_test "94/95.1  registry expands \$HOME at call time; #73 contract kept" test_1_registry_expansion
run_test "94/95.2  A1 direct install accepted" test_2_accept_direct_install
run_test "94/95.3  A2 Issue #57 symlink accepted (payload clause)" test_3_accept_issue57_symlink
run_test "94/95.4  A3 native uv shim->payload accepted" test_4_accept_uv_shim_symlink
run_test "94/95.5  A4 shim-as-real-file accepted (launcher clause)" test_5_accept_launcher_clause
run_test "94/95.6  R1 #94 repro: wrapper into unmanaged tree refused" test_6_refuse_wrapper_into_unmanaged_tree
run_test "94/95.7  R2 #95 repro: foreign uv tools dir refused" test_7_refuse_foreign_uv_tools_dir
run_test "94/95.8  A5 safe defaults never block" test_8_safe_defaults
run_test "94/95.9  refusal mutates nothing under root's HOME" test_9_refusal_has_no_side_effects
run_test "94/95.10 Issue #71 refusal still fires first" test_10_issue71_refusal_still_first
run_test "94/95.11 guard unreachable on the non-root local path" test_11_guard_unreachable_when_non_root
run_test "94/95.12 ENV_DIAG_CAUSE_FILE carries the cause" test_12_cause_file_written
run_test "94/95.13 installer env forwarding + no-arg parity" test_13_installer_env_forwarding
run_test "94/95.14 override never set for a non-root caller" test_14_override_never_set_non_root
run_test "94/95.15 override set in the root+sudo shape" test_15_override_set_root_sudo

framework_report
