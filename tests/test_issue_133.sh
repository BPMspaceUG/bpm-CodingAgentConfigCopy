#!/usr/bin/env bash
# tests/test_issue_133.sh - Tests for Issue #133
#
# Field report ICO-ROB-01: `sudo cac env update` re-ran the upstream curl
# installers as root against root's private copies (/usr/local/bin/vibe ->
# /root/.local/bin/vibe). The Mistral installer bootstrapped uv into
# /root/.local/bin and updated vibe there, and only THEN did the #99/#100
# post-install check report "update produced an install unreachable for
# non-root users". The layout was already unreachable before anything ran, so
# the refusal belongs before the installer.
#
# Seam: env_update_tool <tool> <scope>, with the _env_is_root/_env_root_home
# seams (as in tests/test_issue_100.sh) so root context is reachable as a normal
# user. The installer itself (_env_curl_update_with_capture) is a stub that
# leaves a marker file.
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
# Reachability is judged on modes: the scratch tree must be world-traversable.
chmod 755 "$TEST_TMPDIR"

_mkbin() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\nexit 0\n' > "$1"
    chmod 755 "$1"
}

# Build a layout under $TEST_TMPDIR/<name>: a launcher $T/bin/vibe133 that is a
# symlink to <target_kind>: "roothome" (inside the fake root home) or "shared"
# (a world-reachable dir). Sets T, ROOTLIKE, MARK, PROBE.
make_layout() {
    T="$TEST_TMPDIR/$1"
    mkdir -p "$T"; chmod 755 "$T"
    ROOTLIKE="$T/rootlike"
    MARK="$T/installer-ran"
    PROBE="$T/tool-executed"
    local payload
    case "$2" in
        roothome) payload="$ROOTLIKE/.local/bin/vibe133" ;;
        shared)   payload="$T/shared/bin/vibe133" ;;
    esac
    _mkbin "$payload"
    mkdir -p "$T/bin"
    ln -sf "$payload" "$T/bin/vibe133"
}

# Run env_update_tool mistral user in root context against the layout.
# Extra env assignments (e.g. SUDO_USER=rob) come as arguments. Sets OUT, RC.
run_root_update() {
    RC=0
    OUT=$(
        export HOME="$T" PATH="$T/bin:/bin:/usr/bin"
        for kv in "$@"; do export "${kv?}"; done
        _env_is_root() { return 0; }
        _env_root_home() { echo "$ROOTLIKE"; }
        _env_verify_check_path() { echo "$T/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "vibe133"; }
        _env_installer_target_dirs() { printf '%s\n' "$T/bin" "$ROOTLIKE/.local/bin"; }
        env_is_installed() { return 0; }
        env_get_version() { : > "$PROBE"; [[ -e "$MARK" ]] && echo "2.0.0" || echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$MARK"; return 0; }
        env_update_tool mistral user 2>&1
    ) || RC=$?
}

# 133.1 [anti-bug]: root context, launcher resolves into root's private home:
#       refused before the installer runs and before the tool is executed.
test_133_1_refused_before_installer() {
    make_layout 1331 roothome
    run_root_update

    [[ "$RC" -ne 0 ]] || { echo "rc 0: $OUT" >&2; return 1; }
    [[ ! -e "$MARK" ]] || { echo "installer ran before the refusal: $OUT" >&2; return 1; }
    [[ ! -e "$PROBE" ]] || { echo "tool executed before the refusal: $OUT" >&2; return 1; }
    assert_contains "$T/bin/vibe133" "$OUT" "launcher path named" || return 1
    assert_contains "$ROOTLIKE/.local/bin/vibe133" "$OUT" "resolved path named" || return 1
    assert_contains "root's private home" "$OUT" "reason named" || return 1
    assert_contains "cac env repair mistral" "$OUT" "repair remediation" || return 1
    if [[ "$OUT" == *"NOT a rollback"* ]]; then
        echo "reported as a post-install failure: $OUT" >&2
        return 1
    fi
}

# 133.2: under sudo the refusal names the invoking user and the non-sudo command.
test_133_2_names_sudo_user() {
    make_layout 1332 roothome
    run_root_update SUDO_USER=rob

    [[ "$RC" -ne 0 ]] || { echo "rc 0: $OUT" >&2; return 1; }
    [[ ! -e "$MARK" ]] || { echo "installer ran: $OUT" >&2; return 1; }
    assert_contains "update it as rob without sudo: cac env update mistral" "$OUT" "invoking user and command" || return 1
}

# 133.3: the refusal cause reaches the env_update_all batch summary.
test_133_3_cause_file() {
    make_layout 1333 roothome
    local cause="$T/cause"
    run_root_update ENV_DIAG_CAUSE_FILE="$cause"

    assert_contains "unreachable for non-root users" "$(cat "$cause" 2>/dev/null)" "cause recorded" || return 1
}

# 133.4 [control]: a world-reachable binary in root context is still updated.
test_133_4_reachable_still_updated() {
    make_layout 1334 shared
    run_root_update

    assert_equals 0 "$RC" "exit code for a reachable install" || { echo "$OUT" >&2; return 1; }
    [[ -e "$MARK" ]] || { echo "installer did not run: $OUT" >&2; return 1; }
}

# 133.5 [control]: a non-root update is not subject to the root-only check.
test_133_5_non_root_unaffected() {
    make_layout 1335 roothome
    RC=0
    OUT=$(
        export HOME="$T" PATH="$T/bin:/bin:/usr/bin"
        _env_is_root() { return 1; }
        _env_root_home() { echo "$ROOTLIKE"; }
        _env_verify_check_path() { echo "$T/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "vibe133"; }
        _env_installer_target_dirs() { printf '%s\n' "$T/bin"; }
        env_is_installed() { return 0; }
        env_get_version() { [[ -e "$MARK" ]] && echo "2.0.0" || echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$MARK"; return 0; }
        env_update_tool mistral user 2>&1
    ) || RC=$?

    [[ -e "$MARK" ]] || { echo "non-root update was refused: $OUT" >&2; return 1; }
}

echo "========================================"
echo "Issue #133: refuse unreachable root copies before the installer runs"
echo "========================================"

run_test "133.1 root-home launcher: refused before installer and probe" test_133_1_refused_before_installer
run_test "133.2 under sudo: names the invoking user and command" test_133_2_names_sudo_user
run_test "133.3 refusal cause reaches the batch summary" test_133_3_cause_file
run_test "133.4 reachable binary in root context still updated" test_133_4_reachable_still_updated
run_test "133.5 non-root update unaffected" test_133_5_non_root_unaffected

framework_report
