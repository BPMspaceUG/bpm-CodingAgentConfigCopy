#!/usr/bin/env bash
# tests/test_issue_130.sh - Tests for Issue #130
#
# After `cac env install codex --global`, a non-root user who accepts Codex's
# own in-app "Update now" gets a raw npm EACCES stack trace: Codex runs
# `npm install -g @openai/codex` as that user against a root-owned prefix.
# cac cannot intercept that call, so it says so up front:
#   * env check codex: WARN self_update (not a failure) when the current user
#     cannot write the npm package directory;
#   * a successful global install/update prints a note naming
#     `sudo cac env update codex --global`.
#
# Seams: env_cmd_check (non-root), env_install_tool and env_update_tool in
# root context (the _env_is_root seam). The install lives under
# $HOME/.local so the location/prefix checks pass; "cannot write" is a 0555
# scope dir, which a non-root test user cannot write.
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
# Restore write bits so the framework's cleanup can remove the 0555 dirs.
trap 'chmod -R u+w "$TEST_TMPDIR" 2>/dev/null; _framework_cleanup' EXIT

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "Issue #130 tests need a non-root user (root can write any dir); skipping."
    exit 0
fi

PKG_REL="lib/node_modules/@openai/codex"
NOTE="sudo cac env update codex --global"

# Layout under $TEST_TMPDIR/<name>: HOMEDIR with Codex 0.164.0 in ~/.local,
# stub npm (prefix -g -> $HOMEDIR/.local, install/update writes into --prefix or
# $HOMEDIR/.local), stub node. Sets T, HOMEDIR, NPM_LOG.
make_layout() {
    T="$TEST_TMPDIR/$1"
    HOMEDIR="$T/home"
    NPM_LOG="$T/npm.log"
    mkdir -p "$T/stubbin" "$HOMEDIR/.local/$PKG_REL/bin" "$HOMEDIR/.local/bin"
    : > "$NPM_LOG"
    printf '{"name":"@openai/codex","version":"0.164.0"}\n' > "$HOMEDIR/.local/$PKG_REL/package.json"
    printf '#!/bin/sh\necho "codex-cli 0.164.0"\n' > "$HOMEDIR/.local/$PKG_REL/bin/codex.js"
    chmod 755 "$HOMEDIR/.local/$PKG_REL/bin/codex.js"
    ln -sfn "../$PKG_REL/bin/codex.js" "$HOMEDIR/.local/bin/codex"

    printf '#!/bin/sh\necho v20.11.0\n' > "$T/stubbin/node"
    cat > "$T/stubbin/npm" <<EOF
#!/bin/bash
echo "\$*" >> "$NPM_LOG"
if [ "\$1" = prefix ]; then echo "$HOMEDIR/.local"; exit 0; fi
# install/update: write Codex 0.164.0 into --prefix, else into ~/.local (the
# stand-in global prefix of this fixture).
prefix="$HOMEDIR/.local"; prev=""
for a in "\$@"; do [ "\$prev" = --prefix ] && prefix="\$a"; prev="\$a"; done
d="\$prefix/$PKG_REL"
mkdir -p "\$d/bin" "\$prefix/bin"
printf '{"name":"@openai/codex","version":"0.164.0"}\n' > "\$d/package.json"
printf '#!/bin/sh\necho "codex-cli 0.164.0"\n' > "\$d/bin/codex.js"
chmod 755 "\$d/bin/codex.js"
ln -sfn "../$PKG_REL/bin/codex.js" "\$prefix/bin/codex"
EOF
    chmod 755 "$T/stubbin/"*
}

# Run a lib/env.sh entry point. $1 = root|user; rest = the call. Sets OUT, RC.
run_as() {
    local ctx="$1"; shift
    RC=0
    OUT=$(
        export HOME="$HOMEDIR"
        export PATH="$T/stubbin:$HOMEDIR/.local/bin:/usr/bin:/bin"
        _ENV_SYSTEM_BIN_PATH="$T/none"
        if [[ "$ctx" == "root" ]]; then
            _env_is_root() { return 0; }
        else
            _env_is_root() { return 1; }
        fi
        "$@" 2>&1
    ) || RC=$?
}

# ----------------------------------------------------------------------------
# 130.1 — env check: package dir not writable -> WARN self_update, exit 0.
# ----------------------------------------------------------------------------
test_1_check_warns_unwritable() {
    make_layout t1
    chmod 555 "$HOMEDIR/.local/lib/node_modules/@openai"
    run_as user env_cmd_check codex
    assert_contains "[WARN] self_update:" "$OUT" "warn line (out: $OUT)" || return 1
    assert_contains "$NOTE" "$OUT" "remediation" || return 1
    [[ "$OUT" != *"FAIL"* ]] || { echo "check failed: $OUT" >&2; return 1; }
    assert_equals "0" "$RC" "exit code" || return 1

    run_as user env_cmd_check codex --parseable
    assert_contains "$(printf 'codex\tself_update\twarn\t')" "$OUT" "parseable warn row" || return 1
}

# ----------------------------------------------------------------------------
# 130.2 — env check: user-writable install -> no self_update warning.
# ----------------------------------------------------------------------------
test_2_check_quiet_when_writable() {
    make_layout t2
    run_as user env_cmd_check codex
    [[ "$OUT" != *"self_update"* ]] || { echo "warned on a writable install: $OUT" >&2; return 1; }
    assert_contains "PASS" "$OUT" "clean pass (out: $OUT)" || return 1
}

# ----------------------------------------------------------------------------
# 130.3 — successful global install prints the note.
# ----------------------------------------------------------------------------
test_3_global_install_note() {
    make_layout t3
    rm -rf "$HOMEDIR/.local/lib" "$HOMEDIR/.local/bin/codex"   # fresh install
    run_as root env_install_tool codex global
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "installed successfully" "$OUT" "install succeeded" || return 1
    assert_contains "$NOTE" "$OUT" "note after global install" || return 1
}

# ----------------------------------------------------------------------------
# 130.4 — user-scope install: no note (the in-app updater works there).
# ----------------------------------------------------------------------------
test_4_user_install_no_note() {
    make_layout t4
    rm -rf "$HOMEDIR/.local/lib" "$HOMEDIR/.local/bin/codex"   # fresh install
    run_as user env_install_tool codex user
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    [[ "$OUT" != *"$NOTE"* ]] || { echo "note on a user install: $OUT" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 130.5 — successful global update prints the note too.
# ----------------------------------------------------------------------------
test_5_global_update_note() {
    make_layout t5
    run_as root env_update_tool codex global
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "$NOTE" "$OUT" "note after global update" || return 1
}

run_test "130.1 env check: unwritable package dir -> WARN self_update, exit 0" test_1_check_warns_unwritable
run_test "130.2 env check: writable install -> no warning" test_2_check_quiet_when_writable
run_test "130.3 global install prints the in-app updater note" test_3_global_install_note
run_test "130.4 user install: no note" test_4_user_install_no_note
run_test "130.5 global update prints the note" test_5_global_update_note

framework_report
