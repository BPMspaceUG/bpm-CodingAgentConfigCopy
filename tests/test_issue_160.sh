#!/usr/bin/env bash
# tests/test_issue_160.sh - Tests for Issue #160
#
# ICO-ROB-01: a user-local install (`curl … install.sh | bash`) ended with
# "[ERROR] Non-interactive mode requires configuration values." although
# /etc/cac/.env existed and cac uses it at runtime (config_find_env_path in
# lib/config.sh falls back to it). setup_config looked only at the user path.
#
# Seam: setup_config, called in a child bash that loads install.sh minus
# `main` and `set -euo pipefail` (as tests/test_issues_7_8_9.sh does). The
# system config dir is install.sh's SYS_CONFIG_DIR, pointed at a scratch dir.
# stdin is /dev/null, i.e. the non-interactive pipe mode.
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

# Layout under $TEST_TMPDIR/<name>: HOMEDIR (no user config) and SYSDIR.
# $2 = "sys" writes a complete system config into SYSDIR/.env.
make_layout() {
    T="$TEST_TMPDIR/$1"
    HOMEDIR="$T/home"
    SYSDIR="$T/etc-cac"
    mkdir -p "$HOMEDIR" "$SYSDIR"
    if [[ "${2:-}" == "sys" ]]; then
        printf 'CAC_BACKEND=gokapi\nCAC_GOKAPI_URL=https://gokapi.example.org/\nCAC_GOKAPI_API_KEY=x\n' > "$SYSDIR/.env"
        chmod 644 "$SYSDIR/.env"
    fi
}

# Run setup_config as a user-local install. Extra args are VAR=value pairs
# applied inside the child before the call. Sets OUT and RC.
run_setup() {
    RC=0
    OUT=$(
        env -i PATH="$PATH" HOME="$HOMEDIR" bash -c '
            source "$1"; shift
            SYS_CONFIG_DIR="$1"; shift
            set_user_local_paths
            for kv in "$@"; do export "${kv?}"; done
            for kv in "$@"; do case "$kv" in ARG_*) eval "${kv%%=*}=\"\${kv#*=}\"" ;; esac; done
            mkdir -p "$CONFIG_DIR"
            setup_config
        ' _ "$INSTALL_LIB" "$SYSDIR" "$@" </dev/null 2>&1
    ) || RC=$?
}

USER_ENV() { echo "$HOMEDIR/.config/cac/.env"; }

# ----------------------------------------------------------------------------
# 160.1 — system config present, no user config: accepted, exit 0, no user file.
# ----------------------------------------------------------------------------
test_1_system_config_accepted() {
    make_layout t1 sys
    run_setup
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "Using system configuration: $SYSDIR/.env" "$OUT" "info line" || return 1
    [[ "$OUT" != *"Non-interactive mode requires"* ]] || { echo "still the error: $OUT" >&2; return 1; }
    [[ ! -e "$(USER_ENV)" ]] || { echo "a user config was written" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 160.2 — no system config, no user config: the existing error, non-zero exit.
# ----------------------------------------------------------------------------
test_2_no_config_still_errors() {
    make_layout t2
    run_setup
    [[ "$RC" -ne 0 ]] || { echo "expected failure (out: $OUT)" >&2; return 1; }
    assert_contains "Non-interactive mode requires configuration values." "$OUT" "error text" || return 1
}

# ----------------------------------------------------------------------------
# 160.3 — explicit --backend local with a system config: user config written.
# ----------------------------------------------------------------------------
test_3_explicit_backend_writes_user_config() {
    make_layout t3 sys
    run_setup "ARG_BACKEND=local" "ARG_STORAGE=$T/bundles"
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    [[ -f "$(USER_ENV)" ]] || { echo "no user config written (out: $OUT)" >&2; return 1; }
    grep -q '^CAC_BACKEND=local' "$(USER_ENV)" || { echo "wrong backend in user config" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 160.4 — CAC_BACKEND in the environment counts as explicit too.
# ----------------------------------------------------------------------------
test_4_env_backend_writes_user_config() {
    make_layout t4 sys
    run_setup "CAC_BACKEND=local" "CAC_LOCAL_STORAGE=$T/bundles"
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    [[ -f "$(USER_ENV)" ]] || { echo "no user config written (out: $OUT)" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 160.5 — CAC_CONFIG_DIR with a .env (runtime priority 1): accepted as well.
# ----------------------------------------------------------------------------
test_5_cac_config_dir_accepted() {
    make_layout t5
    mkdir -p "$T/custom"
    printf 'CAC_BACKEND=local\n' > "$T/custom/.env"
    run_setup "CAC_CONFIG_DIR=$T/custom"
    assert_equals "0" "$RC" "exit code (out: $OUT)" || return 1
    assert_contains "$T/custom/.env" "$OUT" "names the config in use" || return 1
    [[ ! -e "$(USER_ENV)" ]] || { echo "a user config was written" >&2; return 1; }
}

run_test "160.1 user install, /etc/cac/.env present: accepted, exit 0, no user config" test_1_system_config_accepted
run_test "160.2 no config anywhere, non-interactive: existing error" test_2_no_config_still_errors
run_test "160.3 explicit --backend with system config: user config written" test_3_explicit_backend_writes_user_config
run_test "160.4 CAC_BACKEND env with system config: user config written" test_4_env_backend_writes_user_config
run_test "160.5 CAC_CONFIG_DIR/.env present: accepted" test_5_cac_config_dir_accepted

framework_report
