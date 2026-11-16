#!/usr/bin/env bash
# tests/test_issue_138.sh - Tests for Issue #138
#
# Field report ICO-ROB-01: Codex CLI installed system-wide via npm, user `rob`
# without passwordless sudo. `cac env update codex` ran
# `npm install -g --prefix ~/.local @openai/codex@latest`, reported
# "updated: unknown -> 0.164.0" and left a per-user copy shadowing the global
# one. The #71 dual-install guard covered curl tools only.
#
# Seams: env_cmd_update (non-root, implicit and explicit scope), env_cmd_check,
# and env_update_tool in root context (the _env_is_root seam, as in
# tests/test_issue_148.sh). The system-wide bin dir is the _ENV_SYSTEM_BIN_PATH
# seam pointed at a scratch dir; npm and sudo are stubs that log their argv.
# PATH carries a symlink farm of /usr/bin without sudo/npm/node/codex, so the
# host's real tools are never reached.
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

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "Issue #138 tests need a non-root user (the escalation path is non-root only); skipping."
    exit 0
fi

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
if [ "\$1" = prefix ]; then echo "$SYS"; exit 0; fi
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

# Run a lib/env.sh entry point as the non-root user against the layout.
# Sets OUT (stdout+stderr) and RC.
run_user() {
    RC=0
    OUT=$(
        export HOME="$HOMEDIR" CAC_BIN="$T/stubbin/cac"
        export PATH="$T/stubbin:$HOMEDIR/.local/bin:$SYS/bin:$T/hostbin"
        unset CAC_ENV_ESCALATED
        _ENV_SYSTEM_BIN_PATH="$SYS/bin"
        _env_is_root() { return 1; }
        "$@" 2>&1
    ) || RC=$?
}

# Same, in root context: HOME is root's (empty) home, sudo is irrelevant.
run_root() {
    RC=0
    OUT=$(
        export HOME="$T/root"
        mkdir -p "$HOME"
        export PATH="$T/stubbin:$SYS/bin:$T/hostbin"
        _ENV_SYSTEM_BIN_PATH="$SYS/bin"
        _env_is_root() { return 0; }
        "$@" 2>&1
    ) || RC=$?
}

_no_user_prefix_npm_call() {
    if grep -q -- "--prefix $HOMEDIR" "$NPM_LOG"; then
        echo "npm was called with a --prefix under HOME: $(cat "$NPM_LOG")" >&2
        return 1
    fi
    [[ ! -e "$HOMEDIR/.local/$PKG_REL" ]] || { echo "a user-scope copy was created" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 138.1 — global npm Codex, no user copy, sudo unavailable: refuse, remediation,
# no user-scope npm call (the ICO-ROB-01 run).
# ----------------------------------------------------------------------------
test_1_refuses_without_sudo() {
    make_layout t1 "" no
    run_user env_cmd_update codex
    [[ "$RC" -ne 0 ]] || { echo "expected non-zero exit (out: $OUT)" >&2; return 1; }
    assert_contains "sudo cac env update codex --global" "$OUT" "remediation names the --global update" || return 1
    _no_user_prefix_npm_call || return 1
    [[ "$OUT" != *"unknown ->"* ]] || { echo "reported an unknown -> transition: $OUT" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 138.2 — same layout, sudo available: escalates with --global, no user call.
# ----------------------------------------------------------------------------
test_2_escalates_with_sudo() {
    make_layout t2 "" yes
    run_user env_cmd_update codex
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "env update --global codex" "$(cat "$SUDO_LOG")" "sudo re-exec argv" || return 1
    _no_user_prefix_npm_call || return 1
}

# ----------------------------------------------------------------------------
# 138.3 — explicit --user with a global install present: refused (#71).
# ----------------------------------------------------------------------------
test_3_explicit_user_refused() {
    make_layout t3 "" yes
    run_user env_cmd_update --user codex
    [[ "$RC" -ne 0 ]] || { echo "expected refusal (out: $OUT)" >&2; return 1; }
    assert_contains "system-wide install" "$OUT" "#71 refusal" || return 1
    assert_contains "sudo cac env update codex --global" "$OUT" "remediation" || return 1
    _no_user_prefix_npm_call || return 1
    [[ ! -s "$SUDO_LOG" ]] || { echo "explicit --user escalated: $(cat "$SUDO_LOG")" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 138.4 — the user runs their own copy (first on PATH): updated in place, with
# real before -> after versions, no sudo.
# ----------------------------------------------------------------------------
test_4_own_copy_updates_in_place() {
    make_layout t4 "0.160.0" yes
    run_user env_cmd_update codex
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "Codex CLI updated: 0.160.0 -> 0.164.0" "$OUT" "real before -> after" || return 1
    grep -q -- "--prefix $HOMEDIR/.local" "$NPM_LOG" || { echo "user copy not updated: $(cat "$NPM_LOG")" >&2; return 1; }
    [[ ! -s "$SUDO_LOG" ]] || { echo "escalated although the user runs their own copy" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 138.5 — `--global` in root context updates the system prefix and reports
# the versions read from it.
# ----------------------------------------------------------------------------
test_5_global_root_reports_versions() {
    make_layout t5 "" no
    run_root env_update_tool codex global
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "Codex CLI updated: 0.155.0 -> 0.164.0" "$OUT" "versions from the global prefix" || return 1
    grep -q -- "--prefix" "$NPM_LOG" && { echo "global update used --prefix: $(cat "$NPM_LOG")" >&2; return 1; }
    return 0
}

# ----------------------------------------------------------------------------
# 138.6 — `cac env check codex` flags user + global coexisting.
# ----------------------------------------------------------------------------
test_6_check_flags_dual_install() {
    make_layout t6 "0.164.0" no
    run_user env_cmd_check codex
    [[ "$RC" -ne 0 ]] || { echo "expected a failing check (out: $OUT)" >&2; return 1; }
    assert_contains "[FAIL] dual_install" "$OUT" "dual_install finding" || return 1
    assert_contains "$HOMEDIR/.local/bin/codex" "$OUT" "names the user copy" || return 1
    assert_contains "$SYS/bin/codex" "$OUT" "names the global copy" || return 1

    run_user env_cmd_check codex --parseable
    assert_contains "$(printf 'codex\tdual_install\tfail\t')" "$OUT" "parseable row" || return 1
}

# ----------------------------------------------------------------------------
# 138.7 — only the global copy: no dual_install finding.
# ----------------------------------------------------------------------------
test_7_check_global_only_clean() {
    make_layout t7 "" no
    run_user env_cmd_check codex
    assert_contains "[PASS] dual_install" "$OUT" "dual_install passes (out: $OUT)" || return 1
}

# ----------------------------------------------------------------------------
# 138.8 — `cac env repair codex` gives the remediation and deletes nothing.
# ----------------------------------------------------------------------------
test_8_repair_gives_remediation() {
    make_layout t8 "0.164.0" no
    run_user env_cmd_repair codex
    assert_contains "npm uninstall -g --prefix $HOMEDIR/.local @openai/codex" "$OUT" "names the uninstall (out: $OUT)" || return 1
    [[ -e "$HOMEDIR/.local/$PKG_REL/package.json" ]] || { echo "repair removed the user copy" >&2; return 1; }
    [[ "$RC" -ne 0 ]] || { echo "repair reported resolved although nothing changed" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 138.9 — sudo needs a password and there is no terminal (agent session on
# ICO-ROB-01): reported as needs-root with the --global hint, no user copy.
# ----------------------------------------------------------------------------
test_9_password_sudo_without_terminal() {
    make_layout t9 "" password
    run_user env_cmd_update codex </dev/null
    [[ "$RC" -ne 0 ]] || { echo "expected non-zero exit (out: $OUT)" >&2; return 1; }
    assert_contains "sudo needs a password" "$OUT" "names the cause" || return 1
    assert_contains "sudo cac env update codex --global" "$OUT" "remediation" || return 1
    if grep -q -- "env update" "$SUDO_LOG"; then
        echo "re-exec attempted without a terminal: $(cat "$SUDO_LOG")" >&2; return 1
    fi
    _no_user_prefix_npm_call || return 1
}

run_test "138.1 global npm codex, no sudo: refused with --global remediation, no user copy" test_1_refuses_without_sudo
run_test "138.2 global npm codex, sudo available: escalates with --global" test_2_escalates_with_sudo
run_test "138.3 explicit --user with global npm codex: refused" test_3_explicit_user_refused
run_test "138.4 user runs own copy: updated in place, real before -> after" test_4_own_copy_updates_in_place
run_test "138.5 --global as root: updates system prefix, versions from it" test_5_global_root_reports_versions
run_test "138.6 env check flags user + global dual install" test_6_check_flags_dual_install
run_test "138.7 env check: global only is not a dual install" test_7_check_global_only_clean
run_test "138.8 env repair: remediation, nothing deleted" test_8_repair_gives_remediation
run_test "138.9 password sudo without a terminal: needs-root with --global hint" test_9_password_sudo_without_terminal

framework_report
