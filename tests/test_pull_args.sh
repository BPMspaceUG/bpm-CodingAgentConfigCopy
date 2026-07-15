#!/usr/bin/env bash
# tests/test_pull_args.sh - Tests for cac pull argument/dispatch path
#
# Covers three related fixes in bin/cac's cmd_pull / cmd_pull_all:
#   #91 (bug): `cac pull --user X` crashed with "Option --user requires an
#              argument" because --user fell into the generic --*) branch (pushed
#              alone) while its value was swallowed as BUNDLE_ID. Fixed by
#              consuming --user + value as a pair in the pre-parse loop.
#   #92 (enh): no --user is uploader-agnostic (newest bundle per tool); an
#              explicit --user narrows to that uploader.
#   #89 (bug): `cac pull --all` discovery missed opencode-only users whose config
#              lives under .config/opencode / .local/share/opencode.
#
# Strategy: bin/cac is source-safe ((return 0) || main "$@" guard), so we source
# it and install stubs AFTER sourcing so real definitions never overwrite them.
# cmd_pull is exercised in --dry-run (no real download/extract); the discovery
# fix is tested via the extracted _pull_all_find_users helper directly, because
# cmd_pull_all's EUID!=0 guard blocks a non-root test run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

# Sourcing bin/cac pulls in all lib modules and (via its own `set -euo pipefail`)
# turns on errexit for this script. Disable it again so setup/among-test glue is
# not aborted by an expected non-zero (run_test already runs each case with -e off).
# shellcheck source=bin/cac
source "$REPO_DIR/bin/cac"
set +e

framework_init

# ============================================================================
# Shared stubs — installed AFTER sourcing bin/cac so they win.
# ============================================================================

CAPTURE_FILE="$(mktemp)"
TEST_HOME="$(mktemp -d)"

# Record every backend_call invocation; return a fake bundle for get_newest so
# cmd_pull proceeds past the "no bundle" branches.
backend_call() {
    echo "backend_call $*" >> "$CAPTURE_FILE"
    case "${1:-}" in
        get_newest) echo "FAKE_BUNDLE.zip" ;;
    esac
    return 0
}

# Neutralise the parts of cmd_pull that touch the real filesystem / user db.
security_check_user_access()   { return 0; }
security_resolve_user_home()   { echo "$TEST_HOME"; }
utils_download_and_extract()   { return 0; }
utils_preview_extraction()     { :; }

# For _pull_all_find_users: emit the fake home dirs built per test.
TEST_HOMES=()
platform_list_user_homes()     { printf '%s\n' "${TEST_HOMES[@]+"${TEST_HOMES[@]}"}"; }

reset_capture() { : > "$CAPTURE_FILE"; }

# ============================================================================
# #91 / #92 — cmd_pull argument parsing
# ============================================================================

# #91: `--user X` with no --tool (Path B) must not error and must filter to X.
test_user_without_tool_filters() {
    reset_capture
    local out rc
    out="$(cmd_pull --user testuser --dry-run 2>&1)"; rc=$?
    assert_equals "0" "$rc" "exit code (no 'requires an argument' crash)" || return 1
    assert_contains "--user testuser" "$(cat "$CAPTURE_FILE")" \
        "backend get_newest should carry --user testuser"
}

# #91: `--tool claude --user X` (Path A) forwards both filters.
test_user_with_tool_filters() {
    reset_capture
    local out rc
    out="$(cmd_pull --tool claude --user testuser --dry-run 2>&1)"; rc=$?
    assert_equals "0" "$rc" "exit code" || return 1
    local cap; cap="$(cat "$CAPTURE_FILE")"
    assert_contains "--tool claude" "$cap" "should carry --tool claude" || return 1
    assert_contains "--user testuser" "$cap" "should carry --user testuser"
}

# #91 regression: a trailing --user with no value must error cleanly.
test_user_missing_value_errors() {
    reset_capture
    local out rc
    out="$(cmd_pull --tool claude --user 2>&1)"; rc=$?
    [[ "$rc" -ne 0 ]] || { echo "expected non-zero exit for missing --user value" >&2; return 1; }
    assert_contains "requires an argument" "$out" "error message"
}

# #92: no --user is uploader-agnostic — get_newest must carry NO --user filter.
test_no_user_is_uploader_agnostic() {
    reset_capture
    local out rc
    out="$(cmd_pull --tool claude --dry-run 2>&1)"; rc=$?
    assert_equals "0" "$rc" "exit code" || return 1
    local cap; cap="$(cat "$CAPTURE_FILE")"
    assert_contains "--tool claude" "$cap" "should carry --tool claude" || return 1
    if [[ "$cap" == *"--user"* ]]; then
        echo "unexpected --user filter in uploader-agnostic pull: $cap" >&2
        return 1
    fi
    return 0
}

# #92 regression: a lone non-flag token is still treated as BUNDLE_ID.
test_positional_bundle_id_preserved() {
    reset_capture
    local out rc
    out="$(cmd_pull SOMEBUNDLE.zip --dry-run 2>&1)"; rc=$?
    assert_equals "0" "$rc" "exit code" || return 1
    assert_contains "SOMEBUNDLE.zip" "$out" "dry-run output should reference the BUNDLE_ID"
}

# ============================================================================
# #89 — _pull_all_find_users opencode discovery
# ============================================================================

# Build fake homes: opencode via .config, opencode via .local/share, a control
# .claude user, and a config-less user that must NOT be discovered.
setup_fake_homes() {
    local root; root="$(mktemp -d)"
    mkdir -p "$root/claudeuser/.claude"
    mkdir -p "$root/ocuser/.config/opencode"; : > "$root/ocuser/.config/opencode/opencode.json"
    mkdir -p "$root/shareuser/.local/share/opencode"; : > "$root/shareuser/.local/share/opencode/auth.json"
    mkdir -p "$root/noneuser"
    TEST_HOMES=("$root/claudeuser" "$root/ocuser" "$root/shareuser" "$root/noneuser")
}

# #89: opencode-only user (.config/opencode) is discovered alongside the control.
test_discovers_opencode_config_user() {
    setup_fake_homes
    local users; users="$(_pull_all_find_users)"
    assert_contains "claudeuser" "$users" "control .claude user discovered" || return 1
    assert_contains "ocuser" "$users" ".config/opencode user discovered" || return 1
    if [[ "$users" == *"noneuser"* ]]; then
        echo "config-less user should not be discovered: $users" >&2
        return 1
    fi
    return 0
}

# #89 regression: opencode via .local/share/opencode is also discovered.
test_discovers_opencode_share_user() {
    setup_fake_homes
    local users; users="$(_pull_all_find_users)"
    assert_contains "shareuser" "$users" ".local/share/opencode user discovered"
}

# ============================================================================
run_test "#91 --user without --tool filters to user"      test_user_without_tool_filters
run_test "#91 --user with --tool forwards both filters"    test_user_with_tool_filters
run_test "#91 missing --user value errors cleanly"         test_user_missing_value_errors
run_test "#92 no --user is uploader-agnostic"              test_no_user_is_uploader_agnostic
run_test "#92 positional BUNDLE_ID preserved"              test_positional_bundle_id_preserved
run_test "#89 discovers .config/opencode user"             test_discovers_opencode_config_user
run_test "#89 discovers .local/share/opencode user"        test_discovers_opencode_share_user

rm -f "$CAPTURE_FILE"
rm -rf "$TEST_HOME"

framework_report
