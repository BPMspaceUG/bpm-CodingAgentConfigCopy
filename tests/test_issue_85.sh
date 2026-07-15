#!/usr/bin/env bash
# tests/test_issue_85.sh - Issue #85: liveness+ownership preflight before rm -rf
#
# `cac env repair claude --yes` used to `rm -rf /opt/claude-code` guarded only by
# the tool name and `[[ -d ]]` — wiping the LIVE shared install on hosts where
# /opt/claude-code is the active install. These tests prove the fail-safe preflight
# REFUSES deletion on any liveness signal (and when it cannot verify liveness), and
# that `--yes` never bypasses it.
#
# Run with: ./tests/test_issue_85.sh   (or via ./tests/run_tests.sh)
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/test_framework.sh"
source "${PROJECT_ROOT}/lib/env.sh"

# ---------------------------------------------------------------------------
# Helper: load the REAL _env_repair_remove_bun_opt with /opt/claude-code rewritten
# to a temp dir and the root-EUID guard neutralised, so the destructive path can be
# exercised safely (same technique as test_env.sh:_load_real_symlink_func).
# ---------------------------------------------------------------------------
_load_real_remove_bun_opt() {
    local mockdir="$1"
    local body
    body=$(sed -n '/^_env_repair_remove_bun_opt()/,/^}/p' "${PROJECT_ROOT}/lib/env.sh")
    body=$(echo "$body" | sed -e "s|/opt/claude-code|${mockdir}|g")
    body=$(echo "$body" | sed 's|\[\[ "${EUID:-\$(id -u)}" -eq 0 \]\]|true|')
    eval "$body"
}

# ============================================================================
# Preflight unit tests
# ============================================================================

# REQUIRED: refuses deletion when a process is running from the target dir.
test_85_refuse_when_process_live() {
    local dir="${TEST_TMPDIR}/opt-claude-live"
    mkdir -p "$dir/node_modules"
    ps() { echo "$dir/node_modules/.bin/claude --agent-id foo"; }
    if PATH="/usr/bin:/bin" _env_repair_preflight_safe_to_delete "$dir" claude; then
        unset -f ps
        fail "refuse when process live" "preflight returned SAFE for a live dir"
        return 1
    fi
    unset -f ps
    assert_contains "running process" "$_ENV_LIVENESS_REASON" "reason mentions running process"
}

# Refuses when a wrapper script execs into the target dir (the exact
# /usr/local/bin/claude -> /opt/claude-code wrapper case).
test_85_refuse_when_wrapper_execs_into_dir() {
    local dir="${TEST_TMPDIR}/opt-claude-wrap"
    mkdir -p "$dir/node_modules/.bin"
    local mockbin="${TEST_TMPDIR}/mockbin-wrap"
    mkdir -p "$mockbin"
    cat > "$mockbin/claude" <<EOF
#!/bin/bash
exec $dir/node_modules/.bin/claude --dangerously-skip-permissions "\$@"
EOF
    chmod +x "$mockbin/claude"
    ps() { echo "some-unrelated-process --flag"; }
    if PATH="$mockbin:/usr/bin:/bin" _env_repair_preflight_safe_to_delete "$dir" claude; then
        unset -f ps
        fail "refuse when wrapper execs into dir" "preflight ignored the exec wrapper"
        return 1
    fi
    unset -f ps
    assert_contains "wrapper" "$_ENV_LIVENESS_REASON" "reason mentions wrapper"
}

# Refuses when the live binary's real target resolves under the target dir.
test_85_refuse_when_symlink_into_dir() {
    local dir="${TEST_TMPDIR}/opt-claude-sym"
    mkdir -p "$dir/node_modules/.bin"
    local realbin="$dir/node_modules/.bin/claude"
    printf '#!/bin/bash\necho x\n' > "$realbin"; chmod +x "$realbin"
    local mockbin="${TEST_TMPDIR}/mockbin-sym"
    mkdir -p "$mockbin"
    ln -s "$realbin" "$mockbin/claude"
    ps() { echo "nothing-relevant"; }
    if PATH="$mockbin:/usr/bin:/bin" _env_repair_preflight_safe_to_delete "$dir" claude; then
        unset -f ps
        fail "refuse when symlink into dir" "preflight ignored a symlink into the dir"
        return 1
    fi
    unset -f ps
    assert_contains "resolves into" "$_ENV_LIVENESS_REASON" "reason mentions resolution into dir"
}

# REQUIRED (Codex safety gap): a live process whose /proc/<pid>/exe resolves under
# $dir must be refused EVEN WHEN its argv (ps) text does NOT contain $dir — e.g. the
# binary is off PATH and ps shows /usr/local/bin/claude (the wrapper), not the /opt
# path. Simulated via a mock /proc tree (_ENV_PROC_ROOT).
test_85_refuse_when_proc_exe_under_dir_argv_masked() {
    local dir="${TEST_TMPDIR}/opt-proc-exe"
    mkdir -p "$dir/node_modules/.bin"
    local realbin="$dir/node_modules/.bin/claude"
    printf '#!/bin/bash\necho x\n' > "$realbin"; chmod +x "$realbin"
    local mockproc="${TEST_TMPDIR}/proc-exe"
    mkdir -p "$mockproc/4242"
    ln -s "$realbin" "$mockproc/4242/exe"
    printf 'no-match-here\n' > "$mockproc/4242/maps"
    # ps args deliberately do NOT contain $dir (argv-masked as the wrapper path).
    ps() { echo "/usr/local/bin/claude --agent-id ratelimit-builder"; }
    if _ENV_PROC_ROOT="$mockproc" PATH="/usr/bin:/bin" \
        _env_repair_preflight_safe_to_delete "$dir" claude; then
        unset -f ps
        fail "refuse on /proc exe under dir" "preflight returned SAFE despite a live /proc exe"
        return 1
    fi
    unset -f ps
    assert_contains "executes from" "$_ENV_LIVENESS_REASON" "reason mentions /proc exe"
}

# REQUIRED (Codex safety gap): a live interpreter (node) whose exe is elsewhere but
# whose /proc/<pid>/maps maps files out of $dir must be refused.
test_85_refuse_when_proc_maps_under_dir() {
    local dir="${TEST_TMPDIR}/opt-proc-maps"
    mkdir -p "$dir/lib"
    local mockproc="${TEST_TMPDIR}/proc-maps"
    mkdir -p "$mockproc/5555"
    ln -s "/bin/sh" "$mockproc/5555/exe"   # exe NOT under dir
    printf '7f0000000000-7f0000010000 r-xp 00000000 00:00 0  %s/lib/index.js\n' "$dir" \
        > "$mockproc/5555/maps"
    ps() { echo "node /usr/local/bin/gemini serve"; }
    if _ENV_PROC_ROOT="$mockproc" PATH="/usr/bin:/bin" \
        _env_repair_preflight_safe_to_delete "$dir" claude; then
        unset -f ps
        fail "refuse on /proc maps under dir" "preflight ignored mmapped files under dir"
        return 1
    fi
    unset -f ps
    assert_contains "maps files under" "$_ENV_LIVENESS_REASON" "reason mentions /proc maps"
}

# REQUIRED (uncertain => refuse): refuses when `ps` cannot run.
test_85_refuse_when_ps_unavailable() {
    local dir="${TEST_TMPDIR}/opt-claude-nops"
    mkdir -p "$dir"
    ps() { return 127; }
    if PATH="/usr/bin:/bin" _env_repair_preflight_safe_to_delete "$dir" claude; then
        unset -f ps
        fail "refuse when ps unavailable" "preflight returned SAFE without a working ps"
        return 1
    fi
    unset -f ps
    assert_contains "ps" "$_ENV_LIVENESS_REASON" "reason mentions ps"
}

# Allows deletion when provably inactive (no signal fires).
test_85_allow_when_inactive() {
    local dir="${TEST_TMPDIR}/opt-claude-dead"
    mkdir -p "$dir"
    touch "$dir/leftover"
    ps() { echo "init"; echo "sshd: /usr/sbin/sshd"; }
    if PATH="/usr/bin:/bin" _env_repair_preflight_safe_to_delete "$dir" claude; then
        unset -f ps
        pass "allow deletion when provably inactive"
    else
        unset -f ps
        fail "allow when inactive" "preflight refused a dead dir: $_ENV_LIVENESS_REASON"
        return 1
    fi
}

# lsof degrades safely: when lsof errors and no other signal fires, still SAFE.
test_85_lsof_degrades_safely() {
    local dir="${TEST_TMPDIR}/opt-claude-lsofdeg"
    mkdir -p "$dir"
    ps() { echo "init"; }
    lsof() { return 4; }  # lsof present but unusable
    if PATH="/usr/bin:/bin" _env_repair_preflight_safe_to_delete "$dir" claude; then
        unset -f ps lsof
        pass "lsof error degrades to other signals (safe)"
    else
        unset -f ps lsof
        fail "lsof degrades safely" "unexpected refuse: $_ENV_LIVENESS_REASON"
        return 1
    fi
}

# ============================================================================
# Integration tests (wired into _env_repair_remove_bun_opt)
# ============================================================================

# REQUIRED: --yes does NOT bypass the preflight; a live dir is NOT deleted.
test_85_yes_does_not_bypass_preflight() {
    local dir="${TEST_TMPDIR}/opt-live-int"
    mkdir -p "$dir/node_modules/.bin"
    touch "$dir/marker"
    _load_real_remove_bun_opt "$dir"
    ps() { echo "$dir/node_modules/.bin/claude --run"; }
    local out=""
    out=$(_env_repair_remove_bun_opt claude true 2>&1) || true
    unset -f ps
    if [[ ! -d "$dir" ]]; then
        fail "--yes does not bypass preflight" "live dir was DELETED despite --yes"
        return 1
    fi
    assert_contains "REFUSING" "$out" "prints refusal message" || return 1
    pass "--yes does not bypass preflight (live dir kept)"
}

# REQUIRED counterpart: a provably-inactive dir IS removed.
test_85_inactive_is_removed() {
    local dir="${TEST_TMPDIR}/opt-dead-int"
    mkdir -p "$dir"
    touch "$dir/leftover"
    _load_real_remove_bun_opt "$dir"
    ps() { echo "init"; echo "sshd"; }
    _env_repair_remove_bun_opt claude true >/dev/null 2>&1 || true
    unset -f ps
    if [[ -d "$dir" ]]; then
        fail "inactive dir is removed" "dead dir was not removed"
        return 1
    fi
    pass "provably-inactive dir is removed"
}

# ============================================================================
# Test registration
# ============================================================================

framework_init

# Default the /proc scan at an EMPTY tree so tests are hermetic, deterministic, and
# fast — no dependency on the host's live /proc (which on a busy host holds thousands
# of PIDs). The two /proc-signal tests override this with their own mock tree via an
# _ENV_PROC_ROOT command-prefix; all others exercise the ps/lsof/exec-chain signals.
export _ENV_PROC_ROOT="${TEST_TMPDIR}/empty-proc"
mkdir -p "$_ENV_PROC_ROOT"

run_test "preflight refuses when a process is live" test_85_refuse_when_process_live
run_test "preflight refuses when a wrapper execs into dir" test_85_refuse_when_wrapper_execs_into_dir
run_test "preflight refuses when symlink resolves into dir" test_85_refuse_when_symlink_into_dir
run_test "preflight refuses on /proc exe under dir (argv masked)" test_85_refuse_when_proc_exe_under_dir_argv_masked
run_test "preflight refuses on /proc maps under dir" test_85_refuse_when_proc_maps_under_dir
run_test "preflight refuses when ps unavailable" test_85_refuse_when_ps_unavailable
run_test "preflight allows deletion when inactive" test_85_allow_when_inactive
run_test "preflight lsof degrades safely" test_85_lsof_degrades_safely
run_test "--yes does not bypass preflight" test_85_yes_does_not_bypass_preflight
run_test "provably-inactive dir is removed" test_85_inactive_is_removed
framework_report
