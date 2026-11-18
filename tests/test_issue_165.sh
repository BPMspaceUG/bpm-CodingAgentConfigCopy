#!/usr/bin/env bash
# tests/test_issue_165.sh - Tests for Issue #165
#
# Escalated `cac env update` runs left residue in root's home and
# /usr/local/bin links into it (#96). `cac env repair` (as root) and
# uninstall.sh now remove it, but only where every tool still works
# afterwards: each candidate is moved into a quarantine, the binaries are
# probed for root and a non-root user, and a failing probe rolls it back.
#
# Seams: env_remove_root_residue and env_cmd_repair (lib/env.sh),
# do_uninstall (uninstall.sh, sourced: main only runs when executed).
# Root context through _env_is_root, root's home through _env_root_home, the
# system-wide bin dirs through _ENV_SYSTEM_BIN_PATH, all on a sandbox. The
# non-root probe is stubbed: a binary works for the user when it resolves on
# the system bin dirs and its real path is outside root's home (root's home
# is 0700 on a real host). The root probe is the real one. PATH carries a
# farm of /usr/bin without the AI tools, so no host tool is reached.
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

# A tool binary at <path> that prints "<name> <version>" on --version.
_mk_bin() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\necho "%s %s"\n' "$(basename "$1")" "$2" > "$1"
    chmod 755 "$1"
}

# Sandbox under $TEST_TMPDIR/<name>. Sets T, ROOTHOME, ULB (stands in for
# /usr/local/bin), UB (stands in for /usr/bin), HOSTBIN.
make_layout() {
    T="$TEST_TMPDIR/$1"
    ROOTHOME="$T/root"
    ULB="$T/usr-local-bin"
    UB="$T/usr-bin"
    HOSTBIN="$T/hostbin"
    mkdir -p "$ROOTHOME/.local/bin" "$ULB" "$UB" "$HOSTBIN"
    ln -s /usr/bin/* "$HOSTBIN/" 2>/dev/null || true
    local b
    for b in claude codex gemini vibe continuous-claude playwright uv uvx npm node nodejs runuser sudo cac; do
        rm -f "$HOSTBIN/$b"
    done
}

# Run "$@" in root context against the sandbox. INPUT feeds stdin (default
# empty). Sets OUT and RC.
run_root() {
    RC=0
    OUT=$(
        export HOME="$ROOTHOME" PATH="$ULB:$UB:$HOSTBIN"
        _ENV_SYSTEM_BIN_PATH="$ULB:$UB"
        _env_is_root() { return 0; }
        _env_root_home() { echo "$ROOTHOME"; }
        _env_residue_works_as_user() {
            local p
            p=$(PATH="$_ENV_SYSTEM_BIN_PATH" type -P "$1" 2>/dev/null) || return 1
            [[ "$(readlink -f "$p")" == "$ROOTHOME"/* ]] && return 1
            "$p" --version >/dev/null 2>&1
        }
        "$@" 2>&1 <<< "${INPUT:-}"
    ) || RC=$?
}

# Does <binary> run for root after the run? (root PATH + root's ~/.local/bin)
root_runs() {
    local p
    p=$(PATH="$ULB:$UB:$HOSTBIN:$ROOTHOME/.local/bin" type -P "$1") || return 1
    "$p" --version >/dev/null 2>&1
}

# The curl-installer layout of Claude Code in root's home at <version>.
_mk_root_claude() {
    _mk_bin "$ROOTHOME/.local/share/claude/versions/$1" "$1"
    ln -s "$ROOTHOME/.local/share/claude/versions/$1" "$ROOTHOME/.local/bin/claude"
}

# 165.1: a /usr/local/bin link into root's home goes; root keeps its claude.
test_165_1_link_into_root_home_removed() {
    make_layout t1
    _mk_root_claude 2.1.300
    ln -s "$ROOTHOME/.local/bin/claude" "$ULB/claude"
    run_root env_remove_root_residue true claude
    assert_equals 0 "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "Removed: $ULB/claude" "$OUT" "link listed as removed" || return 1
    [[ ! -L "$ULB/claude" ]] || { echo "link still there: $OUT" >&2; return 1; }
    root_runs claude || { echo "claude no longer runs for root: $OUT" >&2; return 1; }
}

# 165.2 [control arm]: the root-home copy is root's only working claude → it
# is kept (moved back from the quarantine), with the reason.
test_165_2_only_working_copy_kept() {
    make_layout t2
    _mk_root_claude 2.1.300
    run_root env_remove_root_residue true claude
    assert_equals 0 "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "Kept: $ROOTHOME/.local/bin/claude" "$OUT" "kept line" || return 1
    assert_contains "claude would stop working for root" "$OUT" "reason" || return 1
    [[ -L "$ROOTHOME/.local/bin/claude" && -d "$ROOTHOME/.local/share/claude" ]] \
        || { echo "copy not restored: $OUT" >&2; return 1; }
    root_runs claude || { echo "claude no longer runs for root" >&2; return 1; }
    [[ -z "$(find "$ROOTHOME" -maxdepth 1 -name '.cac-residue.*')" ]] \
        || { echo "quarantine dir left behind" >&2; return 1; }
}

# 165.3: a root-home copy older than the system-wide one goes (launcher and
# data dir); root then runs the system-wide copy.
test_165_3_older_root_copy_removed() {
    make_layout t3
    _mk_root_claude 2.1.300
    _mk_bin "$ULB/claude" 2.1.327
    run_root env_remove_root_residue true claude
    assert_contains "Removed: $ROOTHOME/.local/bin/claude" "$OUT" "launcher removed (out: $OUT)" || return 1
    assert_contains "Removed: $ROOTHOME/.local/share/claude" "$OUT" "data dir removed" || return 1
    [[ ! -e "$ROOTHOME/.local/share/claude" ]] || { echo "data dir still there" >&2; return 1; }
    root_runs claude || { echo "claude no longer runs for root" >&2; return 1; }
}

# 165.4: a root-home copy newer than the system-wide one stays.
test_165_4_newer_root_copy_kept() {
    make_layout t4
    _mk_root_claude 2.1.400
    _mk_bin "$ULB/claude" 2.1.327
    run_root env_remove_root_residue true claude
    assert_contains "Kept: $ROOTHOME/.local/bin/claude" "$OUT" "kept (out: $OUT)" || return 1
    assert_contains "newer than the system-wide copy" "$OUT" "reason" || return 1
    [[ -L "$ROOTHOME/.local/bin/claude" ]] || { echo "newer copy removed" >&2; return 1; }
}

# 165.5: root's npm-prefix copy next to a system-wide npm install goes.
test_165_5_root_npm_copy_removed() {
    make_layout t5
    local pkg="$ROOTHOME/.local/lib/node_modules/@openai/codex"
    _mk_bin "$pkg/bin/codex.js" 0.164.0
    ln -s "$pkg/bin/codex.js" "$ROOTHOME/.local/bin/codex"
    _mk_bin "$UB/codex" 0.164.0
    run_root env_remove_root_residue true codex
    assert_contains "Removed: $ROOTHOME/.local/bin/codex" "$OUT" "launcher removed (out: $OUT)" || return 1
    assert_contains "Removed: $pkg" "$OUT" "package dir removed" || return 1
    [[ ! -e "$pkg" ]] || { echo "package dir still there" >&2; return 1; }
    root_runs codex || { echo "codex no longer runs for root" >&2; return 1; }
}

# 165.6: Mistral residue: vibe copy, uv tools, uv/uvx, env.fish and ~/.vibe
# without config go; env stays while .bashrc sources it; unrelated files in
# root's ~/.local/bin survive.
test_165_6_mistral_residue_and_unrelated_files() {
    make_layout t6
    _mk_bin "$ROOTHOME/.local/share/uv/tools/mistral-vibe/bin/vibe" 3.1.2
    ln -s "$ROOTHOME/.local/share/uv/tools/mistral-vibe/bin/vibe" "$ROOTHOME/.local/bin/vibe"
    _mk_bin "$ULB/vibe" 3.1.2
    _mk_bin "$ROOTHOME/.local/bin/uv" 0.9.0
    _mk_bin "$ROOTHOME/.local/bin/uvx" 0.9.0
    echo 'export PATH="$HOME/.local/bin:$PATH"' > "$ROOTHOME/.local/bin/env"
    echo 'set -gx PATH $HOME/.local/bin $PATH' > "$ROOTHOME/.local/bin/env.fish"
    echo '. "$HOME/.local/bin/env"' > "$ROOTHOME/.bashrc"
    mkdir -p "$ROOTHOME/.vibe/logs"
    _mk_bin "$ROOTHOME/.local/bin/ast-grep" 0.30.0
    _mk_bin "$ROOTHOME/.local/bin/typos" 1.0.0
    run_root env_remove_root_residue true mistral
    local p
    for p in "$ROOTHOME/.local/bin/vibe" "$ROOTHOME/.local/share/uv/tools/mistral-vibe" \
             "$ROOTHOME/.local/share/uv/tools" "$ROOTHOME/.local/bin/uv" "$ROOTHOME/.local/bin/uvx" \
             "$ROOTHOME/.local/bin/env.fish" "$ROOTHOME/.vibe"; do
        assert_contains "Removed: $p" "$OUT" "removed $p (out: $OUT)" || return 1
        [[ ! -e "$p" ]] || { echo "$p still there" >&2; return 1; }
    done
    assert_contains "Kept: $ROOTHOME/.local/bin/env" "$OUT" "sourced env kept" || return 1
    [[ -f "$ROOTHOME/.local/bin/env" ]] || { echo "sourced env removed" >&2; return 1; }
    [[ -x "$ROOTHOME/.local/bin/ast-grep" && -x "$ROOTHOME/.local/bin/typos" ]] \
        || { echo "unrelated files removed" >&2; return 1; }
    assert_contains "Removed 7 path(s)." "$OUT" "count" || return 1
    root_runs vibe || { echo "vibe no longer runs for root" >&2; return 1; }
}

# 165.7: a uv of root's own (no uv tools dir) and a ~/.vibe with config stay.
test_165_7_own_uv_and_configured_vibe_stay() {
    make_layout t7
    _mk_bin "$ROOTHOME/.local/bin/uv" 0.9.0
    mkdir -p "$ROOTHOME/.vibe"
    echo 'model = "x"' > "$ROOTHOME/.vibe/config.toml"
    run_root env_remove_root_residue true mistral
    [[ -x "$ROOTHOME/.local/bin/uv" ]] || { echo "root's own uv removed: $OUT" >&2; return 1; }
    [[ -f "$ROOTHOME/.vibe/config.toml" ]] || { echo "configured ~/.vibe removed: $OUT" >&2; return 1; }
}

# 165.8: non-root context: a no-op.
test_165_8_non_root_is_noop() {
    make_layout t8
    _mk_root_claude 2.1.300
    ln -s "$ROOTHOME/.local/bin/claude" "$ULB/claude"
    RC=0
    OUT=$(
        _env_is_root() { return 1; }
        _env_root_home() { echo "$ROOTHOME"; }
        _ENV_SYSTEM_BIN_PATH="$ULB:$UB"
        env_remove_root_residue true claude 2>&1
    ) || RC=$?
    assert_equals 0 "$RC" "exit code" || return 1
    assert_equals "" "$OUT" "no output" || return 1
    [[ -L "$ULB/claude" ]] || { echo "link removed as non-root" >&2; return 1; }
}

# 165.9: without --yes and without a yes on stdin nothing is removed.
test_165_9_without_yes_nothing_removed() {
    make_layout t9
    _mk_root_claude 2.1.300
    ln -s "$ROOTHOME/.local/bin/claude" "$ULB/claude"
    INPUT="" run_root env_remove_root_residue false claude
    assert_contains "candidate: $ULB/claude" "$OUT" "candidate listed (out: $OUT)" || return 1
    assert_contains "Skipped" "$OUT" "skipped" || return 1
    [[ -L "$ULB/claude" ]] || { echo "link removed without consent" >&2; return 1; }
}

# 165.10: no way to probe as a non-root user → nothing is removed.
test_165_10_unprovable_user_probe_keeps() {
    make_layout t10
    _mk_root_claude 2.1.300
    _mk_bin "$ULB/claude" 2.1.327
    RC=0
    OUT=$(
        export HOME="$ROOTHOME" PATH="$ULB:$UB:$HOSTBIN"
        _ENV_SYSTEM_BIN_PATH="$ULB:$UB"
        _env_is_root() { return 0; }
        _env_root_home() { echo "$ROOTHOME"; }
        _env_residue_works_as_user() { return 2; }
        env_remove_root_residue true claude 2>&1
    ) || RC=$?
    assert_contains "cannot verify claude for a non-root user" "$OUT" "reason (out: $OUT)" || return 1
    [[ -L "$ROOTHOME/.local/bin/claude" ]] || { echo "removed without proof" >&2; return 1; }
}

# 165.11: `cac env repair --yes` runs the residue cleanup.
test_165_11_env_repair_runs_cleanup() {
    make_layout t11
    _mk_root_claude 2.1.300
    ln -s "$ROOTHOME/.local/bin/claude" "$ULB/claude"
    env_is_installed() { return 1; }
    run_root env_cmd_repair claude --yes
    unset -f env_is_installed
    # shellcheck source=lib/env.sh
    source "$REPO_DIR/lib/env.sh"
    assert_contains "Root-home residue" "$OUT" "residue section (out: $OUT)" || return 1
    assert_contains "Removed: $ULB/claude" "$OUT" "link removed" || return 1
}

# 165.12: uninstall.sh removes the same residue through lib/env.sh.
test_165_12_uninstall_removes_residue() {
    make_layout t12
    _mk_root_claude 2.1.300
    ln -s "$ROOTHOME/.local/bin/claude" "$ULB/claude"
    RC=0
    OUT=$(
        export HOME="$ROOTHOME" PATH="$ULB:$UB:$HOSTBIN"
        # shellcheck source=uninstall.sh
        source "$REPO_DIR/uninstall.sh"
        set +e
        SYS_BIN_DIR="$T/sys-bin" SYS_LIB_DIR="$T/no-sys-lib" SYS_CONFIG_DIR="$T/etc-cac"
        USER_BIN_DIR="$T/user-bin" USER_LIB_DIR="$T/user-lib" USER_CONFIG_DIR="$T/user-config"
        PURGE=false FULL_PURGE=false
        is_root() { return 0; }
        _uninstall_residue_seams() {
            _ENV_SYSTEM_BIN_PATH="$ULB:$UB"
            _env_is_root() { return 0; }
            _env_root_home() { echo "$ROOTHOME"; }
            _env_residue_works_as_user() { return 1; }
        }
        do_uninstall
        echo "COUNT=$_RESIDUE_REMOVED"
    ) || RC=$?
    assert_contains "Removed: $ULB/claude" "$OUT" "link removed (out: $OUT)" || return 1
    assert_contains "COUNT=1" "$OUT" "removed count" || return 1
    [[ -L "$ROOTHOME/.local/bin/claude" ]] || { echo "root's only claude removed" >&2; return 1; }
}

run_test "165.1 a /usr/local/bin link into root's home is removed" test_165_1_link_into_root_home_removed
run_test "165.2 the only working root copy is kept, with the reason" test_165_2_only_working_copy_kept
run_test "165.3 an older root copy is removed, root runs the system copy" test_165_3_older_root_copy_removed
run_test "165.4 a newer root copy is kept" test_165_4_newer_root_copy_kept
run_test "165.5 root's npm-prefix copy next to the system install is removed" test_165_5_root_npm_copy_removed
run_test "165.6 Mistral residue goes, sourced env and unrelated files stay" test_165_6_mistral_residue_and_unrelated_files
run_test "165.7 root's own uv and a configured ~/.vibe stay" test_165_7_own_uv_and_configured_vibe_stay
run_test "165.8 non-root context is a no-op" test_165_8_non_root_is_noop
run_test "165.9 without --yes nothing is removed" test_165_9_without_yes_nothing_removed
run_test "165.10 no non-root probe → nothing removed" test_165_10_unprovable_user_probe_keeps
run_test "165.11 cac env repair --yes runs the cleanup" test_165_11_env_repair_runs_cleanup
run_test "165.12 uninstall.sh removes the same residue" test_165_12_uninstall_removes_residue

framework_report
