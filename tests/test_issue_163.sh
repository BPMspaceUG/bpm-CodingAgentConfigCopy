#!/usr/bin/env bash
# tests/test_issue_163.sh - Tests for Issue #163
#
# A host had two cac installs: ~/.local/bin/cac and /usr/local/bin/cac.
# `cac update` updated the copy on PATH only and said nothing about the other;
# `sudo cac …` then ran the stale /usr/local/bin/cac (sudo's secure_path has no
# ~/.local/bin) and #133's fix did not apply. After a successful update cac now
# warns about an older copy at the other standard location, and
# `cac update --check` lists both copies.
#
# Seams: update_self and update_check (lib/update.sh). The other location is
# injected through _update_global_cac_path (default /usr/local/bin/cac) and
# _update_sudo_user_home, root context through _update_is_root, so nothing
# touches the real /usr/local/bin. The version lookup and the install.sh
# download are stubbed as in test_issue_132.sh.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=tests/test_framework.sh
source "${SCRIPT_DIR}/test_framework.sh"
# shellcheck source=lib/update.sh
source "${PROJECT_ROOT}/lib/update.sh"

framework_init

# assert_not_contains <needle> <haystack> <message>
assert_not_contains() {
    if [[ "$2" == *"$1"* ]]; then
        echo "Expected $3 not to contain '$1', got: '$2'" >&2
        return 1
    fi
}

# Write a fake cac at $1 with version $2; it answers every command with exit 0.
_mk_cac() {
    mkdir -p "$(dirname "$1")"
    printf '#!/usr/bin/env bash\nVERSION="%s"\nexit 0\n' "$2" > "$1"
    chmod 755 "$1"
}

# Layout under $TEST_TMPDIR/<name>:
#   $USERCAC = <home>/.local/bin/cac   (user-local copy)
#   $SYSCAC  = <t>/usr-local-bin/cac   (stands in for /usr/local/bin/cac)
# Sets T, HOMEDIR, USERCAC, SYSCAC.
make_layout() {
    T="$TEST_TMPDIR/$1"
    HOMEDIR="$T/home"
    USERCAC="$HOMEDIR/.local/bin/cac"
    SYSCAC="$T/usr-local-bin/cac"
    mkdir -p "$HOMEDIR/.local/bin" "$T/usr-local-bin"
}

# Run "$@" (an update.sh function) in a subshell.
#   ROOT=true|false   root context (default false)
#   ONPATH=user|sys   which copy is on PATH (default user)
#   REMOTE            remote version (default 260201-0000)
#   NEWVER            version install.sh installs (default = REMOTE)
# Sets OUT (stdout+stderr) and RC.
run_fn() {
    local root="${ROOT:-false}" onpath="${ONPATH:-user}"
    local remote="${REMOTE:-260201-0000}" newver="${NEWVER:-${REMOTE:-260201-0000}}"
    local pathdir="$HOMEDIR/.local/bin"
    [[ "$onpath" == "sys" ]] && pathdir="$T/usr-local-bin"
    local target="$pathdir/cac"
    local src="$T/new-cac"
    _mk_cac "$src" "$newver"
    RC=0
    OUT=$(
        export HOME="$HOMEDIR" PATH="$pathdir:/usr/bin:/bin" SUDO_USER="${SUDO_USER_FAKE:-}"
        _update_global_cac_path() { echo "$SYSCAC"; }
        _update_sudo_user_home() { echo "$HOMEDIR"; }
        _update_is_root() { [[ "$root" == "true" ]]; }
        update_get_remote_version() { echo "$remote"; }
        _update_print_tool_report() { :; }
        curl() {
            local out=""
            while [[ $# -gt 0 ]]; do
                [[ "$1" == "-o" ]] && { out="$2"; shift; }
                shift
            done
            printf '#!/usr/bin/env bash\ncp "%s" "%s"\n' "$src" "$target" > "$out"
        }
        "$@" 2>&1
    ) || RC=$?
}

# 163.1: user copy updated, older system copy → warning with path, old version
# and `sudo cac update`; exit 0.
test_163_1_stale_system_copy_warns() {
    make_layout t1
    _mk_cac "$USERCAC" "260101-0000"
    _mk_cac "$SYSCAC" "251110-0619"
    run_fn update_self
    assert_equals 0 "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "Update complete: 260101-0000 -> 260201-0000" "$OUT" "update ran" || return 1
    assert_contains "$SYSCAC" "$OUT" "warning names the stale path" || return 1
    assert_contains "251110-0619" "$OUT" "warning names the stale version" || return 1
    assert_contains "sudo cac" "$OUT" "warning says sudo runs that copy" || return 1
    assert_contains "sudo cac update" "$OUT" "warning gives the update command" || return 1
}

# 163.2: same version at both locations → no warning.
test_163_2_same_version_no_warning() {
    make_layout t2
    _mk_cac "$USERCAC" "260101-0000"
    _mk_cac "$SYSCAC" "260201-0000"
    run_fn update_self
    assert_equals 0 "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "Update complete" "$OUT" "update ran" || return 1
    assert_not_contains "WARNING" "$OUT" "no warning for an equal copy" || return 1
}

# 163.3: no second copy → no warning.
test_163_3_no_second_copy_no_warning() {
    make_layout t3
    _mk_cac "$USERCAC" "260101-0000"
    run_fn update_self
    assert_equals 0 "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "Update complete" "$OUT" "update ran" || return 1
    assert_not_contains "WARNING" "$OUT" "no warning without a second copy" || return 1
}

# 163.4: `cac update --check` lists both copies with their versions and marks
# the older one with its update command.
test_163_4_check_lists_both_copies() {
    make_layout t4
    _mk_cac "$USERCAC" "260201-0000"
    _mk_cac "$SYSCAC" "251110-0619"
    run_fn update_cmd_main --check
    assert_equals 0 "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "$USERCAC  260201-0000" "$OUT" "PATH copy listed with version" || return 1
    assert_contains "$SYSCAC  251110-0619" "$OUT" "system copy listed with version" || return 1
    assert_contains "update with: sudo cac update" "$OUT" "older copy carries its update command" || return 1
}

# 163.5: run as root via sudo, the system copy is updated and an older
# user-local copy of $SUDO_USER is warned about with the user-local command.
test_163_5_root_update_warns_stale_user_copy() {
    make_layout t5
    _mk_cac "$SYSCAC" "260101-0000"
    _mk_cac "$USERCAC" "251110-0619"
    ROOT=true ONPATH=sys SUDO_USER_FAKE=rob run_fn update_self
    assert_equals 0 "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "Installation scope: global" "$OUT" "system copy updated" || return 1
    assert_contains "$USERCAC" "$OUT" "warning names the user-local path" || return 1
    assert_contains "251110-0619" "$OUT" "warning names its version" || return 1
    assert_contains "cac update (as rob, without sudo)" "$OUT" "user-local update command" || return 1
    assert_not_contains "sudo cac update" "$OUT" "no system-copy command for a user copy" || return 1
}

# 163.6: already up to date is a successful update too: the stale copy is
# still reported (the ICO-ROB-01 case after a second `cac update`).
test_163_6_up_to_date_still_warns() {
    make_layout t6
    _mk_cac "$USERCAC" "260201-0000"
    _mk_cac "$SYSCAC" "251110-0619"
    run_fn update_self
    assert_equals 0 "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "Already up to date" "$OUT" "up-to-date path" || return 1
    assert_contains "$SYSCAC" "$OUT" "warning names the stale path" || return 1
    assert_contains "sudo cac update" "$OUT" "warning gives the update command" || return 1
}

# 163.7: the other location is a symlink to the PATH copy → one install, no
# warning and no second list entry.
test_163_7_symlink_is_one_copy() {
    make_layout t7
    _mk_cac "$USERCAC" "260201-0000"
    ln -s "$USERCAC" "$SYSCAC"
    run_fn update_cmd_main --check
    assert_equals 0 "$RC" "exit code (out: $OUT)" || return 1
    assert_not_contains "Installed copies" "$OUT" "symlink is not a second copy" || return 1
}

run_test "163.1 stale system copy after a user update → warning, exit 0" test_163_1_stale_system_copy_warns
run_test "163.2 same version at both locations → no warning" test_163_2_same_version_no_warning
run_test "163.3 no second copy → no warning" test_163_3_no_second_copy_no_warning
run_test "163.4 update --check lists both copies with versions" test_163_4_check_lists_both_copies
run_test "163.5 sudo cac update warns about a stale user-local copy" test_163_5_root_update_warns_stale_user_copy
run_test "163.6 already up to date still warns about a stale copy" test_163_6_up_to_date_still_warns
run_test "163.7 a symlinked second location is one copy" test_163_7_symlink_is_one_copy

framework_report
