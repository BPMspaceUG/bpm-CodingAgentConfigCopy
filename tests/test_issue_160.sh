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
        env -i PATH="$PATH" HOME="$HOMEDIR" RUN_MODE="${RUN_MODE:-user}" bash -c '
            source "$1"; shift
            SYS_CONFIG_DIR="$1"; shift
            if [[ "${RUN_MODE:-user}" == global ]]; then set_system_wide_paths; else set_user_local_paths; fi
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
    grep -q '^CAC_BACKEND=local' "$(USER_ENV)" || { echo "wrong backend in user config" >&2; return 1; }
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

# ----------------------------------------------------------------------------
# 160.6 — --global pass: the caller's own user config is no reason to skip
# the system config (unchanged: non-interactive without values -> error).
# ----------------------------------------------------------------------------
test_6_global_pass_unchanged() {
    make_layout t6
    mkdir -p "$HOMEDIR/.config/cac"
    printf 'CAC_BACKEND=local\n' > "$(USER_ENV)"
    RUN_MODE=global run_setup
    [[ "$RC" -ne 0 ]] || { echo "global pass accepted a user config (out: $OUT)" >&2; return 1; }
    assert_contains "Non-interactive mode requires configuration values." "$OUT" "unchanged error" || return 1
}

# ----------------------------------------------------------------------------
# 160.7 — system config present but unreadable: not accepted.
# ----------------------------------------------------------------------------
test_7_unreadable_system_config() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then echo "(root reads any file; skipped)"; return 0; fi
    make_layout t7 sys
    chmod 000 "$SYSDIR/.env"
    run_setup
    chmod 644 "$SYSDIR/.env"
    [[ "$RC" -ne 0 ]] || { echo "accepted an unreadable system config (out: $OUT)" >&2; return 1; }
    [[ "$OUT" != *"Using system configuration"* ]] || { echo "claimed to use it: $OUT" >&2; return 1; }
    assert_contains "not readable" "$OUT" "says why" || return 1
}

# ----------------------------------------------------------------------------
# 160.8 — any explicit config value (here CAC_GOKAPI_URL alone) means the
# caller wants a config written: the system config is not silently used.
# ----------------------------------------------------------------------------
test_8_partial_explicit_values() {
    make_layout t8 sys
    run_setup "CAC_GOKAPI_URL=https://other.example.org/"
    [[ "$OUT" != *"Using system configuration"* ]] || { echo "explicit value ignored: $OUT" >&2; return 1; }
    run_setup "ARG_STORAGE=$T/bundles"
    [[ "$OUT" != *"Using system configuration"* ]] || { echo "explicit --storage ignored: $OUT" >&2; return 1; }
}

# ----------------------------------------------------------------------------
# 160.9 — the installer's lookup agrees with config_find_env_path for the
# user-side cases (the system path is hard-wired at runtime, so it is
# compared by name only).
# ----------------------------------------------------------------------------
test_9_lookup_matches_runtime() {
    make_layout t9
    mkdir -p "$T/custom" "$T/xdg/cac" "$HOMEDIR/.config/cac"
    printf 'CAC_BACKEND=local\n' | tee "$T/custom/.env" "$T/xdg/cac/.env" "$(USER_ENV)" >/dev/null
    local case_env got_install got_runtime
    for case_env in "CAC_CONFIG_DIR=$T/custom" "XDG_CONFIG_HOME=$T/xdg" "NONE=1"; do
        got_install=$(env -i PATH="$PATH" HOME="$HOMEDIR" "$case_env" bash -c \
            'source "$1"; _install_runtime_env_path' _ "$INSTALL_LIB" 2>/dev/null)
        got_runtime=$(env -i PATH="$PATH" HOME="$HOMEDIR" "$case_env" bash -c \
            'source "$1/lib/config.sh"; config_find_env_path' _ "$REPO_DIR" 2>/dev/null)
        assert_equals "$got_runtime" "$got_install" "lookup for $case_env" || return 1
    done
    grep -q 'system_config="/etc/cac/.env"' "$REPO_DIR/lib/config.sh" || { echo "runtime system path moved" >&2; return 1; }
    grep -q '^SYS_CONFIG_DIR="/etc/cac"' "$REPO_DIR/install.sh" || { echo "installer system dir moved" >&2; return 1; }
}

run_test "160.1 user install, /etc/cac/.env present: accepted, exit 0, no user config" test_1_system_config_accepted
run_test "160.2 no config anywhere, non-interactive: existing error" test_2_no_config_still_errors
run_test "160.3 explicit --backend with system config: user config written" test_3_explicit_backend_writes_user_config
run_test "160.4 CAC_BACKEND env with system config: user config written" test_4_env_backend_writes_user_config
run_test "160.5 CAC_CONFIG_DIR/.env present: accepted" test_5_cac_config_dir_accepted
run_test "160.6 --global pass: user config does not replace the system config" test_6_global_pass_unchanged
run_test "160.7 unreadable system config: not accepted, says why" test_7_unreadable_system_config
run_test "160.8 any explicit config value: system config not silently used" test_8_partial_explicit_values
run_test "160.9 installer lookup matches config_find_env_path" test_9_lookup_matches_runtime

framework_report
