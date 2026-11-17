#!/usr/bin/env bash
# tests/test_issue_129.sh - Tests for Issue #129
#
# contabo03: `sudo cac env update codex` (root, no scope flag) defaulted to
# scope `user`. With HOME=/root the npm command became
# `npm install -g --prefix /root/.local @openai/codex@latest`: a second,
# orphaned copy in root's home, reported as "updated", while the system-wide
# copy on PATH kept its old version.
#
# Chosen design (a): in root context an implicit scope resolves to `global`
# for an npm tool that has a system-wide install. Explicit --user keeps its
# meaning; curl tools keep their #94/#95/#133 root-context handling.
#
# Seams: env_cmd_update in root context (the _env_is_root seam, as in
# tests/test_issue_148.sh). Layout helpers as in tests/test_issue_138.sh:
# _ENV_SYSTEM_BIN_PATH points at a scratch system prefix, npm is a stub that
# logs its argv.
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

# Write an npm-shaped Codex install under <prefix>: package.json with <version>,
# bin/codex.js printing it, and <prefix>/bin/codex -> ../lib/.../codex.js.
_mk_codex() {
    local prefix="$1" version="$2"
    mkdir -p "$prefix/$PKG_REL/bin" "$prefix/bin"
    printf '{\n  "name": "@openai/codex",\n  "version": "%s"\n}\n' "$version" > "$prefix/$PKG_REL/package.json"
    printf '#!/bin/sh\necho "codex-cli %s"\n' "$version" > "$prefix/$PKG_REL/bin/codex.js"
    chmod 755 "$prefix/$PKG_REL/bin/codex.js"
    ln -sfn "../$PKG_REL/bin/codex.js" "$prefix/bin/codex"
}

# Build a layout under $TEST_TMPDIR/<name>. Sets T, SYS, HOMEDIR, NPM_LOG, SUDO_LOG.
#   SYS      system-wide npm prefix (outside HOME) holding Codex 0.155.0
#   HOMEDIR  the user's home; <user_version> non-empty -> ~/.local copy of it
#   sudo     "yes" puts a logging sudo stub on PATH, "password" one that
#            refuses without a password, "no" leaves sudo absent
make_layout() {
    local name="$1" user_version="$2" sudo="$3"
    T="$TEST_TMPDIR/$name"
    SYS="$T/sys"
    HOMEDIR="$T/home"
    NPM_LOG="$T/npm.log"
    SUDO_LOG="$T/sudo.log"
    mkdir -p "$T/stubbin" "$T/hostbin" "$HOMEDIR/.local/bin"
    : > "$NPM_LOG"; : > "$SUDO_LOG"

    _mk_codex "$SYS" "0.155.0"
    [[ -n "$user_version" ]] && _mk_codex "$HOMEDIR/.local" "$user_version"

    # Host tools minus the ones this test must control.
    ln -s /usr/bin/* "$T/hostbin/" 2>/dev/null || true
    rm -f "$T/hostbin/sudo" "$T/hostbin/npm" "$T/hostbin/node" "$T/hostbin/nodejs" \
          "$T/hostbin/codex" "$T/hostbin/cac"

    printf '#!/bin/sh\necho v20.11.0\n' > "$T/stubbin/node"
    # npm stub: logs argv; `prefix -g` names SYS; install/update writes 0.164.0
    # into the --prefix it was given (SYS when none, as `npm -g` would).
    cat > "$T/stubbin/npm" <<EOF
#!/bin/bash
echo "\$*" >> "$NPM_LOG"
if [ "\$1" = prefix ]; then echo "\${NPM_PREFIX_OVERRIDE:-$SYS}"; exit 0; fi
prefix="$SYS"; prev=""
for a in "\$@"; do [ "\$prev" = --prefix ] && prefix="\$a"; prev="\$a"; done
d="\$prefix/$PKG_REL"
mkdir -p "\$d/bin" "\$prefix/bin"
printf '{"name":"@openai/codex","version":"0.164.0"}\n' > "\$d/package.json"
printf '#!/bin/sh\necho "codex-cli 0.164.0"\n' > "\$d/bin/codex.js"
chmod 755 "\$d/bin/codex.js"
ln -sfn "../$PKG_REL/bin/codex.js" "\$prefix/bin/codex"
EOF
    case "$sudo" in
        yes)
            printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$SUDO_LOG" > "$T/stubbin/sudo"
            ;;
        password)
            # ICO-ROB-01: sudo exists but needs a password; -n fails.
            printf '#!/bin/sh\necho "$*" >> "%s"\necho "sudo: a password is required" >&2\nexit 1\n' "$SUDO_LOG" > "$T/stubbin/sudo"
            ;;
    esac
    printf '#!/bin/sh\nexit 0\n' > "$T/stubbin/cac"
    chmod 755 "$T/stubbin/"*
}

# Run a lib/env.sh entry point in root context: HOME is the fake root home
# ($HOMEDIR, as under sudo), the system prefix is on PATH.
run_root() {
    RC=0
    OUT=$(
        export HOME="$HOMEDIR"
        export PATH="$T/stubbin:$HOMEDIR/.local/bin:$SYS/bin:$T/hostbin"
        _ENV_SYSTEM_BIN_PATH="$SYS/bin"
        _env_is_root() { return 0; }
        "$@" 2>&1
    ) || RC=$?
}

_no_root_home_npm_call() {
    if grep -q -- "--prefix $HOMEDIR" "$NPM_LOG"; then
        echo "npm was called with a --prefix in root's home: $(cat "$NPM_LOG")" >&2
        return 1
    fi
    [[ ! -e "$HOMEDIR/.local/$PKG_REL" ]] || { echo "a copy was created in root's home" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 129.1 — `sudo cac env update codex`: global update, versions from the
# system prefix, nothing in root's home (the contabo03 run).
# ----------------------------------------------------------------------------
test_1_implicit_scope_updates_global() {
    make_layout t1 "" no
    run_root env_cmd_update codex
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    _no_root_home_npm_call || return 1
    assert_contains "Codex CLI updated: 0.155.0 -> 0.164.0" "$OUT" "versions from the system prefix" || return 1
    grep -q '"version":"0.164.0"' "$SYS/$PKG_REL/package.json" || { echo "system prefix not updated" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 129.2 — `sudo cac env update` (all tools): same for codex.
# ----------------------------------------------------------------------------
test_2_update_all_implicit_scope() {
    make_layout t2 "" no
    run_root env_cmd_update
    _no_root_home_npm_call || return 1
    assert_contains "Codex CLI updated: 0.155.0 -> 0.164.0" "$OUT" "codex updated globally (out: $OUT)" || return 1
}

# ----------------------------------------------------------------------------
# 129.3 — explicit --global under root still updates the system prefix.
# ----------------------------------------------------------------------------
test_3_explicit_global_regression() {
    make_layout t3 "" no
    run_root env_cmd_update --global codex
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    _no_root_home_npm_call || return 1
    assert_contains "Codex CLI updated: 0.155.0 -> 0.164.0" "$OUT" "versions" || return 1
}

# ----------------------------------------------------------------------------
# 129.4 — explicit --user under root keeps its meaning (root's own copy).
# ----------------------------------------------------------------------------
test_4_explicit_user_unchanged() {
    make_layout t4 "0.160.0" no
    run_root env_cmd_update --user codex
    grep -q -- "--prefix $HOMEDIR/.local" "$NPM_LOG" || { echo "--user did not target root's home: $(cat "$NPM_LOG") out: $OUT" >&2; return 1; }
    grep -q '"version": "0.155.0"' "$SYS/$PKG_REL/package.json" || { echo "--user touched the system prefix" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 129.5 — root, implicit scope, no system-wide install: nothing to promote,
# the root-home copy is updated as before.
# ----------------------------------------------------------------------------
test_5_no_global_install_stays_user() {
    make_layout t5 "0.160.0" no
    rm -rf "$SYS/bin/codex"
    run_root env_cmd_update codex
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    grep -q -- "--prefix $HOMEDIR/.local" "$NPM_LOG" || { echo "expected a root-home update: $(cat "$NPM_LOG")" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 129.6 — the system-wide launcher does not resolve into `npm prefix -g`
# (e.g. an old /usr/local copy while npm's prefix is /usr): refused with a
# remediation, no npm install into either prefix, non-zero exit.
# ----------------------------------------------------------------------------
test_6_launcher_outside_npm_prefix_refused() {
    make_layout t6 "" no
    local other="$T/other-prefix"
    mkdir -p "$other"
    RC=0
    OUT=$(
        export NPM_PREFIX_OVERRIDE="$other"
        run_root env_cmd_update codex
        printf '%s' "$OUT"
        exit "$RC"
    ) || RC=$?
    [[ "$RC" -ne 0 ]] || { echo "expected refusal (out: $OUT)" >&2; return 1; }
    assert_contains "does not resolve into npm's global prefix" "$OUT" "names the mismatch" || return 1
    assert_contains "cac env repair codex" "$OUT" "remediation" || return 1
    if grep -qE "^(install|update)" "$NPM_LOG"; then
        echo "npm install/update ran: $(cat "$NPM_LOG")" >&2; return 1
    fi
    _no_root_home_npm_call || return 1
}

run_test "129.1 sudo env update codex (no scope): global update, nothing in root's home" test_1_implicit_scope_updates_global
run_test "129.2 sudo env update (all, no scope): codex updated globally" test_2_update_all_implicit_scope
run_test "129.3 sudo env update --global codex: system prefix (regression)" test_3_explicit_global_regression
run_test "129.4 sudo env update --user codex: keeps its meaning" test_4_explicit_user_unchanged
run_test "129.5 root, no system-wide install: root-home copy updated as before" test_5_no_global_install_stays_user
run_test "129.6 launcher outside npm prefix -g: refused with remediation" test_6_launcher_outside_npm_prefix_refused

framework_report
