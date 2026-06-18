#!/usr/bin/env bash
# tests/test_issue_79.sh - Tests for Issue #79:
#   `cac env update` (no args, non-root) reported system-wide curl tools as hard
#   `Failed` instead of auto-escalating with sudo. The fix adds:
#     * ENV_PARSED_SCOPE_EXPLICIT (implicit-vs-explicit scope)
#     * _env_user_install_exists / _env_update_action (follow PATH-resolved copy)
#     * _env_resolve_cac_bin (safe entrypoint resolution for re-exec)
#     * _env_reexec_sudo_update (subprocess sudo re-exec, NOT exec)
#     * env_update_with_escalation orchestration in env_cmd_update
#
# Style mirrors tests/test_issue_71.sh: self-contained, ANSI colors, manual
# counters, set -uo pipefail (no errexit so ((c++)) from 0 is safe). Subshells
# isolate function-table overrides. Network-free — all sudo/cac/curl stubbed.
#
# Test inventory (mapped to Codex-reviewed acceptance criteria):
#   79.1   _env_parse_scope_args: explicit flags set EXPLICIT=true
#   79.2   _env_parse_scope_args: defaulted scope sets EXPLICIT=false
#   79.3   _env_user_install_exists: HOME copy -> yes; global/symlink -> no
#   79.4   _env_update_action: follows PATH-resolved copy (local vs escalate)
#   79.5   _env_resolve_cac_bin: CAC_BIN absolute+exec -> ok; relative -> fail
#   79.6   _env_reexec_sudo_update: sudo missing -> NEEDS_ROOT, no escalation
#   79.7   _env_reexec_sudo_update: invokes `sudo ... env update --global <tools>`
#   79.8   no-args mixed: local tool updated in-process, global escalated
#   79.9   explicit --user + global -> still refuses (Issue #71 preserved)
#   79.10  recursion guard: CAC_ENV_ESCALATED set -> no escalation branch
#   79.11  dual-install, user runs own copy -> user-scope update (override), no sudo
#   79.12  npm global tool -> NOT escalated (no behavior change)
#   79.13  empty target set -> SUCCESS (not ALL_FAILED)
#   79.14  exit codes: all-needs-root -> ALL_FAILED; mixed -> PARTIAL
#   79.15  invalid tool name never reaches sudo
#   79.16  cac path unresolvable -> NEEDS_ROOT, no sudo

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; ((PASSED++)) || true; ((TOTAL++)) || true; }
fail() {
    echo -e "${RED}FAIL${NC}: $1"
    [[ -n "${2:-}" ]] && echo "       Reason: $2"
    ((FAILED++)) || true; ((TOTAL++)) || true
}
skip() {
    echo -e "${YELLOW}SKIP${NC}: $1"
    [[ -n "${2:-}" ]] && echo "       Reason: $2"
    ((SKIPPED++)) || true; ((TOTAL++)) || true
}
header() { echo ""; echo "=========================================="; echo "$1"; echo "=========================================="; }

ROOT_TMP=$(mktemp -d -t cac-test-79.XXXXXXXXXX)
trap 'rm -rf "$ROOT_TMP" 2>/dev/null || true' EXIT

# shellcheck source=../lib/env.sh
source "${REPO_DIR}/lib/env.sh"

_scratch() { local d="${ROOT_TMP}/$1"; mkdir -p "$d"; echo "$d"; }

# Root cannot exercise the non-root auto-escalation path. Skip behavioural tests
# when running as root (parity with test_issue_71's root-only handling).
IS_ROOT=0
[[ "${EUID:-$(id -u)}" -eq 0 ]] && IS_ROOT=1

# ----------------------------------------------------------------------------
# 79.1 / 79.2 — scope explicitness
# ----------------------------------------------------------------------------
test_79_1_explicit_scope_flags() {
    (
        _env_parse_scope_args --user >/dev/null 2>&1
        [[ "$ENV_PARSED_SCOPE" == "user" && "$ENV_PARSED_SCOPE_EXPLICIT" == "true" ]] || exit 1
        # --global/--all require root to fully pass; only check the flag is set
        # before the root validation by parsing in a root-agnostic way.
        exit 0
    ) && pass "79.1 --user sets EXPLICIT=true" || fail "79.1 --user sets EXPLICIT=true"
}

test_79_2_default_scope_implicit() {
    (
        _env_parse_scope_args claude >/dev/null 2>&1
        [[ "$ENV_PARSED_SCOPE" == "user" && "$ENV_PARSED_SCOPE_EXPLICIT" == "false" ]] || exit 1
        exit 0
    ) && pass "79.2 defaulted scope sets EXPLICIT=false" || fail "79.2 defaulted scope sets EXPLICIT=false"
}

# ----------------------------------------------------------------------------
# 79.3 — _env_user_install_exists (layout-agnostic)
# ----------------------------------------------------------------------------
test_79_3_user_install_detection() {
    local T; T=$(_scratch 79_3)
    (
        local marker="cac79_bin_$$"
        # HOME copy: real file under $HOME, on PATH -> user install
        export HOME="$T/home"
        mkdir -p "$HOME/.local/bin"
        : > "$HOME/.local/bin/$marker"; chmod +x "$HOME/.local/bin/$marker"
        export PATH="$HOME/.local/bin:$PATH"
        _env_tool_to_binary() { echo "$marker"; }
        _env_user_install_exists claude || { echo "expected user install detected" >&2; exit 1; }

        # Symlink into /usr/* must NOT count as a user install
        ln -sf /usr/bin/true "$HOME/.local/bin/$marker"
        if _env_user_install_exists claude; then
            echo "symlink into /usr should not count as user install" >&2; exit 1
        fi
        # Codex gap: a symlink under $HOME whose REAL target is a non-global,
        # non-home location must also NOT count (only target-under-$HOME does).
        local ext="$T/external"; mkdir -p "$ext"; : > "$ext/realbin"; chmod +x "$ext/realbin"
        ln -sf "$ext/realbin" "$HOME/.local/bin/$marker"
        if _env_user_install_exists claude; then
            echo "symlink to non-home target should not count as user install" >&2; exit 1
        fi
        exit 0
    ) && pass "79.3 _env_user_install_exists: only real-target-under-\$HOME counts" \
       || fail "79.3 _env_user_install_exists: only real-target-under-\$HOME counts"
}

# ----------------------------------------------------------------------------
# 79.4 — _env_update_action (follow what the user runs)
# ----------------------------------------------------------------------------
test_79_4_update_action() {
    (
        # no global at all -> local (plain user update is safe)
        _env_global_install_exists() { return 1; }
        _env_user_install_exists()   { return 1; }
        [[ "$(_env_update_action claude)" == "local" ]] || { echo "no-global should be local" >&2; exit 1; }

        # global exists + user runs own copy -> local (update the copy they run)
        _env_global_install_exists() { return 0; }
        _env_user_install_exists()   { return 0; }
        [[ "$(_env_update_action claude)" == "local" ]] || { echo "own-copy should be local" >&2; exit 1; }

        # global exists + user runs the global copy -> escalate
        _env_global_install_exists() { return 0; }
        _env_user_install_exists()   { return 1; }
        [[ "$(_env_update_action claude)" == "escalate" ]] || { echo "global-run should escalate" >&2; exit 1; }
        exit 0
    ) && pass "79.4 _env_update_action: follows PATH-resolved copy (local vs escalate)" \
       || fail "79.4 _env_update_action: follows PATH-resolved copy (local vs escalate)"
}

# ----------------------------------------------------------------------------
# 79.5 — _env_resolve_cac_bin
# ----------------------------------------------------------------------------
test_79_5_resolve_cac_bin() {
    local T; T=$(_scratch 79_5)
    (
        : > "$T/cac"; chmod +x "$T/cac"
        export CAC_BIN="$T/cac"
        local got; got=$(_env_resolve_cac_bin) || { echo "expected success" >&2; exit 1; }
        [[ "$got" == "$T/cac" ]] || { echo "wrong path: $got" >&2; exit 1; }

        # Relative path must be rejected (no $0 reconstruction for priv boundary)
        export CAC_BIN="relative/cac"
        if _env_resolve_cac_bin >/dev/null 2>&1; then echo "relative accepted" >&2; exit 1; fi

        # Non-executable must be rejected
        export CAC_BIN="$T/not_exec"; : > "$T/not_exec"
        if _env_resolve_cac_bin >/dev/null 2>&1; then echo "non-exec accepted" >&2; exit 1; fi
        exit 0
    ) && pass "79.5 _env_resolve_cac_bin: absolute+exec only" \
       || fail "79.5 _env_resolve_cac_bin: absolute+exec only"
}

# ----------------------------------------------------------------------------
# 79.6 — sudo missing -> NEEDS_ROOT
# ----------------------------------------------------------------------------
test_79_6_sudo_missing() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.6 sudo-missing (root)" "needs non-root"; return; fi
    local T; T=$(_scratch 79_6)
    (
        # PATH with NO sudo
        : > "$T/cac"; chmod +x "$T/cac"; export CAC_BIN="$T/cac"
        export PATH="$T"   # contains cac but not sudo
        local rc=0
        _env_reexec_sudo_update claude >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq "$ENV_EXIT_NEEDS_ROOT" ]] || { echo "rc=$rc expected NEEDS_ROOT=$ENV_EXIT_NEEDS_ROOT" >&2; exit 1; }
        exit 0
    ) && pass "79.6 sudo missing -> NEEDS_ROOT, no escalation" \
       || fail "79.6 sudo missing -> NEEDS_ROOT, no escalation"
}

# ----------------------------------------------------------------------------
# 79.7 — re-exec invokes `sudo ... env update --global <tools>`
# ----------------------------------------------------------------------------
test_79_7_reexec_invocation() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.7 reexec-invocation (root)" "needs non-root"; return; fi
    local T; T=$(_scratch 79_7)
    (
        local argfile="$T/sudo_args"
        # Mock sudo: record all args, exit 0. Mirrors what real sudo would exec.
        cat > "$T/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$argfile"
exit 0
EOF
        chmod +x "$T/sudo"
        : > "$T/cac"; chmod +x "$T/cac"; export CAC_BIN="$T/cac"
        export PATH="$T:$PATH"
        local rc=0
        _env_reexec_sudo_update claude continuous-claude >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq 0 ]] || { echo "rc=$rc" >&2; exit 1; }
        local args; args=$(cat "$argfile")
        # Must carry --preserve-env, the resolved cac, and the exact subcommand.
        [[ "$args" == *"--preserve-env=CAC_ENV_ESCALATED"* ]] || { echo "missing preserve-env: $args" >&2; exit 1; }
        [[ "$args" == *"$T/cac"* ]] || { echo "missing cac bin: $args" >&2; exit 1; }
        # Verify ordered tokens: env / update / --global / claude / continuous-claude
        printf '%s' "$args" | tr '\n' ' ' | grep -q -- "env update --global claude continuous-claude" \
            || { echo "bad argv order: $args" >&2; exit 1; }
        exit 0
    ) && pass "79.7 re-exec builds 'sudo --preserve-env -- <cac> env update --global <tools>'" \
       || fail "79.7 re-exec builds 'sudo --preserve-env -- <cac> env update --global <tools>'"
}

# Shared harness: drive env_update_with_escalation with fully mocked leaves.
# Args via env vars set by caller:
#   MOCK_TOOLS         : space-separated installed tools (for no-arg path)
#   MOCK_TYPE_<tool>   : curl|npm
#   MOCK_ACTION_<tool> : local|escalate  (result of _env_update_action; curl only)
#   MOCK_LOCAL_RC      : rc for env_update_tool (default 0)
#   MOCK_SUDO_RC       : rc for _env_reexec_sudo_update (default 0)
# Records: $REEXEC_LOG (tools passed to escalation, one line)
_run_escalation() {
    # $@ = ENV_PARSED_TOOLS contents (empty => no-args path)
    ENV_PARSED_TOOLS=("$@")
    ENV_PARSED_SCOPE="user"
    ENV_PARSED_SCOPE_EXPLICIT="false"

    env_get_all_tools() { local _x; for _x in $MOCK_TOOLS; do echo "$_x"; done; }
    env_is_installed() { [[ " $MOCK_TOOLS " == *" $1 "* ]]; }
    env_validate_tool() { [[ " $MOCK_TOOLS ALL_VALID " == *" $1 "* ]] || _env_tool_to_binary "$1" >/dev/null 2>&1; }
    env_get_display_name() { echo "$1"; }
    env_get_install_type() { local v="MOCK_TYPE_${1//-/_}"; echo "${!v:-curl}"; }
    _env_update_action() { local v="MOCK_ACTION_${1//-/_}"; echo "${!v:-escalate}"; }
    # Record the Issue #79 override, which now arrives as the 3rd PARAMETER
    # (unforgeable from the environment), not a shell/env variable.
    env_update_tool() {
        echo "LOCAL_UPDATE:$1:override=${3:-0}"
        return "${MOCK_LOCAL_RC:-0}"
    }
    # Per-tool escalation: append each invocation so multi-tool batches are visible.
    # Per-tool rc override: MOCK_SUDO_RC_<tool> wins over MOCK_SUDO_RC.
    _env_reexec_sudo_update() {
        printf '%s\n' "$1" >> "$REEXEC_LOG"
        local pv="MOCK_SUDO_RC_${1//-/_}"
        return "${!pv:-${MOCK_SUDO_RC:-0}}"
    }

    env_update_with_escalation
}

# ----------------------------------------------------------------------------
# 79.8 — no-args mixed: local in-process, global escalated
# ----------------------------------------------------------------------------
test_79_8_mixed_noargs() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.8 mixed-noargs (root)" "needs non-root"; return; fi
    local T; T=$(_scratch 79_8)
    (
        export REEXEC_LOG="$T/reexec"
        export MOCK_TOOLS="codex claude"
        export MOCK_TYPE_codex="npm"   MOCK_ACTION_codex="local"
        export MOCK_TYPE_claude="curl" MOCK_ACTION_claude="escalate"
        local out rc=0
        out=$(_run_escalation) || rc=$?
        [[ "$out" == *"LOCAL_UPDATE:codex"* ]] || { echo "codex not updated in-process: $out" >&2; exit 1; }
        [[ "$(cat "$REEXEC_LOG" 2>/dev/null)" == "claude" ]] || { echo "claude not escalated" >&2; exit 1; }
        [[ "$rc" -eq 0 ]] || { echo "rc=$rc expected 0" >&2; exit 1; }
        exit 0
    ) && pass "79.8 no-args mixed: npm in-process + curl-global escalated -> SUCCESS" \
       || fail "79.8 no-args mixed: npm in-process + curl-global escalated -> SUCCESS"
}

# ----------------------------------------------------------------------------
# 79.9 — explicit --user + global -> Issue #71 refusal preserved
# ----------------------------------------------------------------------------
test_79_9_explicit_user_refuses() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.9 explicit-user (root)" "needs non-root"; return; fi
    (
        # Explicit --user must bypass escalation entirely and hit env_update_tool,
        # which fires the Issue #71 refusal for a globally-installed curl tool.
        env_validate_tool() { return 0; }
        env_is_installed() { return 0; }
        env_get_display_name() { echo "Claude Code"; }
        env_get_version() { echo "1.0.0"; }
        env_get_install_type() { echo "curl"; }
        _env_global_install_exists() { return 0; }
        # Sentinel that escalation must NOT be reached.
        _env_reexec_sudo_update() { echo "ESCALATED" ; return 0; }
        local out rc=0
        out=$(env_cmd_update --user claude 2>&1) || rc=$?
        [[ "$out" == *"system-wide install"* ]] || { echo "no #71 refusal: $out" >&2; exit 1; }
        [[ "$out" != *"ESCALATED"* ]] || { echo "escalation wrongly triggered on --user" >&2; exit 1; }
        [[ "$rc" -ne 0 ]] || { echo "expected non-zero" >&2; exit 1; }
        exit 0
    ) && pass "79.9 explicit --user still refuses global (Issue #71 preserved, no escalation)" \
       || fail "79.9 explicit --user still refuses global (Issue #71 preserved, no escalation)"
}

# ----------------------------------------------------------------------------
# 79.10 — recursion guard via CAC_ENV_ESCALATED
# ----------------------------------------------------------------------------
test_79_10_recursion_guard() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.10 recursion-guard (root)" "needs non-root"; return; fi
    (
        export CAC_ENV_ESCALATED=1
        env_validate_tool() { return 0; }
        env_is_installed() { return 0; }
        env_get_display_name() { echo "$1"; }
        env_get_version() { echo "1.0.0"; }
        env_get_install_type() { echo "curl"; }
        _env_global_install_exists() { return 0; }
        # If escalation runs we fail.
        _env_reexec_sudo_update() { echo "ESCALATED"; return 0; }
        # env_update_tool would refuse (curl+global+nonroot) -> non-zero, but the
        # point is escalation must be skipped.
        local out; out=$(env_cmd_update 2>&1)
        [[ "$out" != *"ESCALATED"* ]] || { echo "escalation ran despite sentinel" >&2; exit 1; }
        exit 0
    ) && pass "79.10 CAC_ENV_ESCALATED set -> auto-escalation branch skipped" \
       || fail "79.10 CAC_ENV_ESCALATED set -> auto-escalation branch skipped"
}

# ----------------------------------------------------------------------------
# 79.11 — dual-install but user runs own copy -> local update, override honored
# ----------------------------------------------------------------------------
test_79_11_dual_user_copy_local() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.11 dual-user-copy (root)" "needs non-root"; return; fi
    local T; T=$(_scratch 79_11)
    (
        export REEXEC_LOG="$T/reexec"
        export MOCK_TOOLS="claude"
        # User has a global AND their own copy -> action=local (update the one
        # they run). No sudo; env_update_tool must receive the #71 override.
        export MOCK_TYPE_claude="curl" MOCK_ACTION_claude="local"
        local out rc=0
        out=$(_run_escalation) || rc=$?
        [[ "$out" == *"LOCAL_UPDATE:claude:override=1"* ]] || { echo "no local update with override param: $out" >&2; exit 1; }
        [[ ! -s "$REEXEC_LOG" ]] || { echo "escalation ran when user runs own copy" >&2; exit 1; }
        [[ "$rc" -eq 0 ]] || { echo "rc=$rc expected SUCCESS" >&2; exit 1; }
        exit 0
    ) && pass "79.11 dual-install own copy -> user-scope update (override param=1), no sudo" \
       || fail "79.11 dual-install own copy -> user-scope update (override param=1), no sudo"
}

# ----------------------------------------------------------------------------
# 79.12 — npm global tool not escalated
# ----------------------------------------------------------------------------
test_79_12_npm_not_escalated() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.12 npm (root)" "needs non-root"; return; fi
    local T; T=$(_scratch 79_12)
    (
        export REEXEC_LOG="$T/reexec"
        export MOCK_TOOLS="codex"
        # npm tool: never reaches _env_update_action (curl-only); always local.
        export MOCK_TYPE_codex="npm" MOCK_ACTION_codex="escalate"
        local out rc=0
        out=$(_run_escalation) || rc=$?
        [[ "$out" == *"LOCAL_UPDATE:codex"* ]] || { echo "npm not updated in-process: $out" >&2; exit 1; }
        [[ ! -s "$REEXEC_LOG" ]] || { echo "npm tool escalated!" >&2; exit 1; }
        [[ "$rc" -eq 0 ]] || { echo "rc=$rc" >&2; exit 1; }
        exit 0
    ) && pass "79.12 npm tool never escalated (no behavior change)" \
       || fail "79.12 npm tool never escalated (no behavior change)"
}

# ----------------------------------------------------------------------------
# 79.13 — empty target set -> SUCCESS
# ----------------------------------------------------------------------------
test_79_13_empty_targets() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.13 empty (root)" "needs non-root"; return; fi
    local T; T=$(_scratch 79_13)
    (
        export REEXEC_LOG="$T/reexec"
        export MOCK_TOOLS=""   # nothing installed
        local out rc=0
        out=$(_run_escalation) || rc=$?
        [[ "$rc" -eq "$ENV_EXIT_SUCCESS" ]] || { echo "rc=$rc expected SUCCESS: $out" >&2; exit 1; }
        [[ "$out" == *"No installed AI tools"* ]] || { echo "missing empty msg: $out" >&2; exit 1; }
        exit 0
    ) && pass "79.13 empty target set -> SUCCESS (not ALL_FAILED)" \
       || fail "79.13 empty target set -> SUCCESS (not ALL_FAILED)"
}

# ----------------------------------------------------------------------------
# 79.14 — exit codes: all-needs-root -> ALL_FAILED; mixed -> PARTIAL
# ----------------------------------------------------------------------------
test_79_14_exit_codes() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.14 exit-codes (root)" "needs non-root"; return; fi
    local T; T=$(_scratch 79_14)
    # (a) only a global tool, escalation can't run (NEEDS_ROOT) -> ALL_FAILED
    (
        export REEXEC_LOG="$T/r1"
        export MOCK_TOOLS="claude"
        export MOCK_TYPE_claude="curl" MOCK_ACTION_claude="escalate"
        export MOCK_SUDO_RC="$ENV_EXIT_NEEDS_ROOT"
        local rc=0; _run_escalation >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq "$ENV_EXIT_ALL_FAILED" ]] || { echo "a: rc=$rc expected ALL_FAILED" >&2; exit 1; }
        exit 0
    ) && pass "79.14a all-needs-root -> ALL_FAILED" || fail "79.14a all-needs-root -> ALL_FAILED"

    # (b) one local ok + one global needs-root -> PARTIAL
    (
        export REEXEC_LOG="$T/r2"
        export MOCK_TOOLS="codex claude"
        export MOCK_TYPE_codex="npm"   MOCK_ACTION_codex="local"
        export MOCK_TYPE_claude="curl" MOCK_ACTION_claude="escalate"
        export MOCK_SUDO_RC="$ENV_EXIT_NEEDS_ROOT"
        local rc=0; _run_escalation >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq "$ENV_EXIT_PARTIAL" ]] || { echo "b: rc=$rc expected PARTIAL" >&2; exit 1; }
        exit 0
    ) && pass "79.14b local ok + global needs-root -> PARTIAL" || fail "79.14b local ok + global needs-root -> PARTIAL"

    # (c) one local ok + global child FAILED (rc 2) -> PARTIAL
    (
        export REEXEC_LOG="$T/r3"
        export MOCK_TOOLS="codex claude"
        export MOCK_TYPE_codex="npm"   MOCK_ACTION_codex="local"
        export MOCK_TYPE_claude="curl" MOCK_ACTION_claude="escalate"
        export MOCK_SUDO_RC=2
        local rc=0; _run_escalation >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq "$ENV_EXIT_PARTIAL" ]] || { echo "c: rc=$rc expected PARTIAL" >&2; exit 1; }
        exit 0
    ) && pass "79.14c local ok + global child failed -> PARTIAL" || fail "79.14c local ok + global child failed -> PARTIAL"
}

# ----------------------------------------------------------------------------
# 79.15 — invalid tool name never reaches sudo
# ----------------------------------------------------------------------------
test_79_15_invalid_tool() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.15 invalid (root)" "needs non-root"; return; fi
    local T; T=$(_scratch 79_15)
    (
        export REEXEC_LOG="$T/reexec"
        # Explicit bogus tool; validate returns false for it.
        ENV_PARSED_TOOLS=("definitely-not-a-tool")
        ENV_PARSED_SCOPE="user"; ENV_PARSED_SCOPE_EXPLICIT="false"
        env_validate_tool() { return 1; }
        env_is_installed() { return 0; }
        env_get_display_name() { echo "$1"; }
        _env_reexec_sudo_update() { printf '%s\n' "$*" > "$REEXEC_LOG"; return 0; }
        local rc=0; env_update_with_escalation >/dev/null 2>&1 || rc=$?
        [[ ! -s "$REEXEC_LOG" ]] || { echo "invalid tool reached sudo" >&2; exit 1; }
        [[ "$rc" -ne 0 ]] || { echo "invalid tool returned success" >&2; exit 1; }
        exit 0
    ) && pass "79.15 invalid tool never reaches sudo, non-zero exit" \
       || fail "79.15 invalid tool never reaches sudo, non-zero exit"
}

# ----------------------------------------------------------------------------
# 79.16 — cac path unresolvable -> NEEDS_ROOT, no sudo
# ----------------------------------------------------------------------------
test_79_16_cac_unresolvable() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.16 cac-unresolvable (root)" "needs non-root"; return; fi
    local T; T=$(_scratch 79_16)
    (
        local sudolog="$T/sudo_called"
        cat > "$T/sudo" <<EOF
#!/usr/bin/env bash
echo called > "$sudolog"
EOF
        chmod +x "$T/sudo"
        # Restrict PATH to ONLY our scratch dir: sudo is present, cac is not.
        # _env_reexec_sudo_update needs no external binaries beyond sudo here.
        export PATH="$T"
        unset CAC_BIN
        command -v cac >/dev/null 2>&1 && { echo "cac unexpectedly resolvable" >&2; exit 1; }
        local rc=0
        _env_reexec_sudo_update claude >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq "$ENV_EXIT_NEEDS_ROOT" ]] || { echo "rc=$rc expected NEEDS_ROOT" >&2; exit 1; }
        [[ ! -e "$sudolog" ]] || { echo "sudo was called despite unresolved cac" >&2; exit 1; }
        exit 0
    ) && pass "79.16 unresolved cac -> NEEDS_ROOT, no sudo" \
       || fail "79.16 unresolved cac -> NEEDS_ROOT, no sudo"
}

# ----------------------------------------------------------------------------
# 79.17 — per-tool escalation: one global succeeds, one fails -> PARTIAL
# (Codex gap: a batched child PARTIAL was previously misattributed)
# ----------------------------------------------------------------------------
test_79_17_mixed_global_partial() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.17 mixed-global (root)" "needs non-root"; return; fi
    local T; T=$(_scratch 79_17)
    (
        export REEXEC_LOG="$T/reexec"
        export MOCK_TOOLS="claude mistral"
        export MOCK_TYPE_claude="curl"  MOCK_ACTION_claude="escalate"
        export MOCK_TYPE_mistral="curl" MOCK_ACTION_mistral="escalate"
        # claude escalation succeeds, mistral fails -> exactly one of each.
        export MOCK_SUDO_RC_claude=0
        export MOCK_SUDO_RC_mistral=2
        local out rc=0
        out=$(_run_escalation) || rc=$?
        # Both tools were escalated individually (per-tool, not one batch).
        grep -qx claude "$REEXEC_LOG"  || { echo "claude not escalated" >&2; exit 1; }
        grep -qx mistral "$REEXEC_LOG" || { echo "mistral not escalated" >&2; exit 1; }
        [[ "$rc" -eq "$ENV_EXIT_PARTIAL" ]] || { echo "rc=$rc expected PARTIAL: $out" >&2; exit 1; }
        [[ "$out" == *"Updated: 1"* ]] || { echo "expected Updated: 1: $out" >&2; exit 1; }
        [[ "$out" == *"Failed: 1"* ]] || { echo "expected Failed: 1: $out" >&2; exit 1; }
        exit 0
    ) && pass "79.17 per-tool escalation: 1 ok + 1 fail -> PARTIAL (correct attribution)" \
       || fail "79.17 per-tool escalation: 1 ok + 1 fail -> PARTIAL (correct attribution)"
}

# ----------------------------------------------------------------------------
# 79.18 — forged env var must NOT bypass Issue #71 (override is parameter-only)
# ----------------------------------------------------------------------------
test_79_18_forged_env_no_bypass() {
    if [[ $IS_ROOT -eq 1 ]]; then skip "79.18 forged-env (root)" "needs non-root"; return; fi
    (
        # Attacker sets the old override name in the environment and asks for an
        # explicit --user update of a globally-installed curl tool. The refusal
        # must still fire, because the override is now a function parameter.
        export ENV_ALLOW_USER_OVERRIDE_GLOBAL=1
        env_validate_tool() { return 0; }
        env_is_installed() { return 0; }
        env_get_display_name() { echo "Claude Code"; }
        env_get_version() { echo "1.0.0"; }
        env_get_install_type() { echo "curl"; }
        _env_global_install_exists() { return 0; }
        _env_reexec_sudo_update() { echo "ESCALATED"; return 0; }
        local out rc=0
        out=$(env_cmd_update --user claude 2>&1) || rc=$?
        [[ "$out" == *"system-wide install"* ]] || { echo "forged env bypassed #71: $out" >&2; exit 1; }
        [[ "$rc" -ne 0 ]] || { echo "expected non-zero" >&2; exit 1; }
        exit 0
    ) && pass "79.18 forged ENV_ALLOW_USER_OVERRIDE_GLOBAL does NOT bypass Issue #71" \
       || fail "79.18 forged ENV_ALLOW_USER_OVERRIDE_GLOBAL does NOT bypass Issue #71"
}

# ----------------------------------------------------------------------------
# Runner
# ----------------------------------------------------------------------------
header "Issue #79 tests: cac env update auto-escalation for system-wide tools"

test_79_1_explicit_scope_flags
test_79_2_default_scope_implicit
test_79_3_user_install_detection
test_79_4_update_action
test_79_5_resolve_cac_bin
test_79_6_sudo_missing
test_79_7_reexec_invocation
test_79_8_mixed_noargs
test_79_9_explicit_user_refuses
test_79_10_recursion_guard
test_79_11_dual_user_copy_local
test_79_12_npm_not_escalated
test_79_13_empty_targets
test_79_14_exit_codes
test_79_15_invalid_tool
test_79_16_cac_unresolvable
test_79_17_mixed_global_partial
test_79_18_forged_env_no_bypass

echo ""
echo "=========================================="
echo "Results: $PASSED/$TOTAL passed (skipped: $SKIPPED)"
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED}$FAILED test(s) failed${NC}"
    exit 1
fi
echo -e "${GREEN}All run tests passed${NC}"
exit 0
