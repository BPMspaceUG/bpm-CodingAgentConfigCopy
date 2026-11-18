#!/usr/bin/env bash
# tests/test_issue_164.sh - Tests for Issue #164
#
# Field report ICO-ROB-01: `sudo cac env repair codex` found a per-user Codex
# copy in /root/.local next to the system-wide one and printed
#   npm uninstall -g --prefix /root/.local @openai/codex
# without sudo. Copied into the operator's non-root shell it fails: /root is
# 0700. In root context the line now starts with `sudo `; run by a normal user
# for their own copy it stays without sudo.
#
# Seam: env_cmd_repair, root context through _env_is_root (#156) and root's
# home through _env_root_home (the copy's location decides). Layout as in
# tests/test_issue_138.sh: the system-wide bin dir is the _ENV_SYSTEM_BIN_PATH
# seam on a scratch dir, npm/node are stubs, PATH carries /usr/bin without
# sudo/npm/node/codex so no real tool is reached.
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

PKG_REL="lib/node_modules/@openai/codex"

# npm-shaped Codex install under <prefix> at <version>.
_mk_codex() {
    local prefix="$1" version="$2"
    mkdir -p "$prefix/$PKG_REL/bin" "$prefix/bin"
    printf '{\n  "name": "@openai/codex",\n  "version": "%s"\n}\n' "$version" > "$prefix/$PKG_REL/package.json"
    printf '#!/bin/sh\necho "codex-cli %s"\n' "$version" > "$prefix/$PKG_REL/bin/codex.js"
    chmod 755 "$prefix/$PKG_REL/bin/codex.js"
    ln -sfn "../$PKG_REL/bin/codex.js" "$prefix/bin/codex"
}

# Layout under $TEST_TMPDIR/<name>: system-wide Codex in $SYS, a per-user copy
# in $HOMEDIR/.local. Sets T, SYS, HOMEDIR.
make_layout() {
    T="$TEST_TMPDIR/$1"
    SYS="$T/sys"
    HOMEDIR="$T/home"
    mkdir -p "$T/stubbin" "$T/hostbin" "$HOMEDIR/.local/bin"
    _mk_codex "$SYS" "0.164.0"
    _mk_codex "$HOMEDIR/.local" "0.155.0"
    ln -s /usr/bin/* "$T/hostbin/" 2>/dev/null || true
    rm -f "$T/hostbin/sudo" "$T/hostbin/npm" "$T/hostbin/node" "$T/hostbin/nodejs" \
          "$T/hostbin/codex" "$T/hostbin/cac"
    printf '#!/bin/sh\necho v20.11.0\n' > "$T/stubbin/node"
    printf '#!/bin/sh\n[ "$1" = prefix ] && echo "%s"\nexit 0\n' "$SYS" > "$T/stubbin/npm"
    printf '#!/bin/sh\nexit 0\n' > "$T/stubbin/cac"
    chmod 755 "$T/stubbin/"*
}

# Run env_cmd_repair codex. $1 = true|false for _env_is_root; $2 = the
# directory _env_root_home names (default: HOMEDIR when root, else a dir that
# is not HOME). Sets OUT, RC.
run_repair() {
    local root_ctx="$1" root_home="${2:-}"
    if [[ -z "$root_home" ]]; then
        root_home="$T/not-home"
        [[ "$root_ctx" == "true" ]] && root_home="$HOMEDIR"
    fi
    mkdir -p "$root_home"
    RC=0
    OUT=$(
        export HOME="$HOMEDIR" CAC_BIN="$T/stubbin/cac"
        export PATH="$T/stubbin:$HOMEDIR/.local/bin:$SYS/bin:$T/hostbin"
        unset CAC_ENV_ESCALATED
        _ENV_SYSTEM_BIN_PATH="$SYS/bin"
        _env_is_root() { [[ "$root_ctx" == "true" ]]; }
        _env_root_home() { echo "$root_home"; }
        env_cmd_repair codex 2>&1
    ) || RC=$?
}

# The remediation uninstall line, leading spaces stripped.
_uninstall_line() {
    printf '%s\n' "$OUT" | grep -- "npm uninstall -g --prefix" | head -1 | sed 's/^ *//'
}

# 164.1: root context, HOME is root's home (sudo resets HOME) → the line
# starts with sudo.
test_164_1_root_copy_needs_sudo() {
    make_layout t1
    run_repair true
    assert_equals "sudo npm uninstall -g --prefix $HOMEDIR/.local @openai/codex" \
        "$(_uninstall_line)" "remediation line (out: $OUT)" || return 1
    [[ -e "$HOMEDIR/.local/$PKG_REL/package.json" ]] || { echo "repair removed the user copy" >&2; return 1; }
}

# 164.2: non-root user, own copy → the line stays without sudo.
test_164_2_user_copy_without_sudo() {
    make_layout t2
    run_repair false
    assert_equals "npm uninstall -g --prefix $HOMEDIR/.local @openai/codex" \
        "$(_uninstall_line)" "remediation line (out: $OUT)" || return 1
}

# 164.3: root context, but sudo kept HOME (sudo -E, macOS): the copy is the
# invoking user's own → no sudo.
test_164_3_root_with_kept_home_no_sudo() {
    make_layout t3
    run_repair true "$T/root"
    assert_equals "npm uninstall -g --prefix $HOMEDIR/.local @openai/codex" \
        "$(_uninstall_line)" "remediation line (out: $OUT)" || return 1
}

run_test "164.1 root context: the uninstall line starts with sudo" test_164_1_root_copy_needs_sudo
run_test "164.2 non-root: the uninstall line has no sudo" test_164_2_user_copy_without_sudo
run_test "164.3 root with HOME kept: the user's own copy gets no sudo" test_164_3_root_with_kept_home_no_sudo

framework_report
