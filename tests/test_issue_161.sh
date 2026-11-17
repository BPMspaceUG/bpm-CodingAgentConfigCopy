#!/usr/bin/env bash
# tests/test_issue_161.sh - Tests for Issue #161
#
# ICO-ROB-01, after #160: the installer said "Using system configuration:
# /etc/cac/.env" and then closed with "Configuration: /home/rob/.config/cac/.env",
# a file that does not exist. The closing line printed a fixed path per mode.
#
# Seam: print_config_summary, called in a child bash that loads install.sh
# minus `main` and `set -euo pipefail` (as tests/test_issue_160.sh does). The
# system config dir is install.sh's SYS_CONFIG_DIR, pointed at a scratch dir.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

INSTALL_LIB="$TEST_TMPDIR/install_functions.sh"
sed -E \
    -e '/^[[:space:]]*main([[:space:]]+.*)?([[:space:]]*#.*)?$/d' \
    -e '/^[[:space:]]*set[[:space:]]+-euo[[:space:]]+pipefail/d' \
    "$REPO_DIR/install.sh" > "$INSTALL_LIB"

# Layout under $TEST_TMPDIR/<name>. $2/$3: "user" / "sys" write that config.
make_layout() {
    T="$TEST_TMPDIR/$1"
    HOMEDIR="$T/home"
    SYSDIR="$T/etc-cac"
    USER_ENV="$HOMEDIR/.config/cac/.env"
    mkdir -p "$HOMEDIR/.config/cac" "$SYSDIR"
    shift
    local which
    for which in "$@"; do
        case "$which" in
            user) printf 'CAC_BACKEND=local\n' > "$USER_ENV" ;;
            sys)  printf 'CAC_BACKEND=local\n' > "$SYSDIR/.env" ;;
        esac
    done
}

# Print the summary line for a mode: user | global | all. Sets OUT.
summary() {
    OUT=$(
        env -i PATH="$PATH" HOME="$HOMEDIR" bash -c '
            source "$1"
            SYS_CONFIG_DIR="$2"
            case "$3" in
                global) set_system_wide_paths ;;
                all)    INSTALL_MODE_FLAG=all; set_system_wide_paths ;;
                *)      set_user_local_paths ;;
            esac
            print_config_summary
        ' _ "$INSTALL_LIB" "$SYSDIR" "$1" 2>&1
    )
}

test_1_user_mode_system_config_only() {
    make_layout t1 sys
    summary user
    assert_equals "Configuration: $SYSDIR/.env (system)" "$OUT" "summary line" || return 1
}

test_2_user_mode_user_config() {
    make_layout t2 user sys
    summary user
    assert_equals "Configuration: $USER_ENV" "$OUT" "summary line" || return 1
}

test_3_all_mode_only_existing_files() {
    make_layout t3 sys
    summary all
    assert_equals "Configuration: $SYSDIR/.env (system)" "$OUT" "only the system file" || return 1

    make_layout t3b user
    summary all
    assert_equals "Configuration: $USER_ENV (user)" "$OUT" "only the user file" || return 1

    make_layout t3c user sys
    summary all
    assert_equals "Configuration: $USER_ENV (user) and $SYSDIR/.env (system)" "$OUT" "both" || return 1
}

test_4_global_mode_unchanged() {
    make_layout t4 sys
    summary global
    assert_equals "Configuration: $SYSDIR/.env" "$OUT" "summary line" || return 1
}

test_5_cac_config_dir_in_effect() {
    make_layout t5 sys
    mkdir -p "$T/custom"
    printf 'CAC_BACKEND=local\n' > "$T/custom/.env"
    OUT=$(
        env -i PATH="$PATH" HOME="$HOMEDIR" CAC_CONFIG_DIR="$T/custom" bash -c '
            source "$1"; SYS_CONFIG_DIR="$2"; set_user_local_paths; print_config_summary
        ' _ "$INSTALL_LIB" "$SYSDIR" 2>&1
    )
    assert_equals "Configuration: $T/custom/.env" "$OUT" "summary line" || return 1
}

run_test "161.1 user-local, system config only: names /etc/cac/.env (system)" test_1_user_mode_system_config_only
run_test "161.2 user-local with a user config: names the user config" test_2_user_mode_user_config
run_test "161.3 --all: lists only files that exist" test_3_all_mode_only_existing_files
run_test "161.4 --global: system config, as before" test_4_global_mode_unchanged
run_test "161.5 CAC_CONFIG_DIR/.env in effect: names it" test_5_cac_config_dir_in_effect

framework_report
