#!/usr/bin/env bash
# tests/test_issue_83.sh - Tests for Issue #83
#
# `cac pull` synced credentials while the local CLI was far behind; the stale
# CLI then failed with errors that looked like auth or model problems. Pull now
# warns on stderr, before extraction, for every tool it is about to install
# whose installed CLI is older than the newest published version. The warning
# never changes the exit status; --skip-version-check skips the lookup.
#
# Seams:
#   PATH stub bin   `codex`, `claude` and `npm` replay verbatim captures from
#                   tests/fixtures (codex-version.out, npm-view-*.out/.err), so
#                   the real env_is_installed / env_get_version /
#                   env_get_latest_version and the version parser run. `npm`
#                   logs every call to $T/npm.calls.
#   backend_call    get_newest answers one fixture bundle name per tool.
#   utils_download_and_extract  records "EXTRACTED <bundle>" instead of
#                   downloading, so the order warning → extraction is visible.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$SCRIPT_DIR/fixtures"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=bin/cac
source "$REPO_DIR/bin/cac"
set +e

framework_init

T="$(mktemp -d)"
TEST_HOME="$T/home"
mkdir -p "$TEST_HOME"

CAC_BACKEND="gokapi"
CAC_GOKAPI_URL="https://gokapi.example.invalid"
CAC_GOKAPI_API_KEY="FIXTURE"

security_check_user_access()   { return 0; }
security_resolve_user_home()   { echo "$TEST_HOME"; }

bundle_name() { echo "CodingAgentConfig_FIXTURE-HOST_fixture_${1}_261118-053000.zip"; }

backend_call() {
    local op="$1"; shift
    if [[ "$op" == "get_newest" ]]; then
        local tool=""
        while [[ $# -gt 0 ]]; do
            [[ "$1" == "--tool" ]] && tool="$2"
            shift
        done
        if [[ "$tool" == "codex" || "$tool" == "claude" || "$tool" == "gemini" ]]; then
            bundle_name "$tool"
            return 0
        fi
        echo "ERROR: No bundles found matching: --tool $tool" >&2
        return 1
    fi
    return 1
}
# Records whether the stale-CLI warning was already on stderr when extraction
# started (pull() sends stderr to $T/err, unbuffered).
utils_download_and_extract() {
    local when="no-warning-yet"
    grep -qF "cac env update" "$T/err" 2>/dev/null && when="after-warning"
    echo "EXTRACTED $1 ($when)"
}

# Stub bin: codex and claude print their captured --version; npm prints the
# captured `npm view <pkg> version` answer, or the captured 404 when
# NPM_MODE=fail. gemini, vibe and opencode are not installed.
mkdir -p "$T/stubbin"
cat > "$T/stubbin/codex" <<EOF
#!/bin/sh
cat "$FIX/codex-version.out"
EOF
cat > "$T/stubbin/claude" <<EOF
#!/bin/sh
cat "$FIX/claude-version.out"
EOF
cat > "$T/stubbin/npm" <<EOF
#!/bin/sh
echo "\$*" >> "$T/npm.calls"
if [ "\${NPM_MODE:-}" = fail ]; then cat "$FIX/npm-view-404.err" >&2; exit 1; fi
case "\$2" in
    @openai/codex)             cat "$FIX/npm-view-codex-version.out" ;;
    @anthropic-ai/claude-code) cat "$FIX/npm-view-claude-code-version.out" ;;
    *) cat "$FIX/npm-view-404.err" >&2; exit 1 ;;
esac
EOF
chmod 755 "$T/stubbin/"*

# pull <cmd> <args...>: run cmd_pull/cmd_get with the stub PATH and an empty
# latest-version cache. Sets OUT (stdout), ERR (stderr), RC.
pull() {
    local cmd="$1"; shift
    rm -rf "$T/cache" "$T/npm.calls"
    RC=0
    (
        export PATH="$T/stubbin:/usr/bin:/bin"
        export XDG_CACHE_HOME="$T/cache"
        "$cmd" "$@"
    ) >"$T/out" 2>"$T/err" || RC=$?
    OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
npm_calls() { cat "$T/npm.calls" 2>/dev/null; }

test_1_outdated_cli_warns_before_extraction() {
    pull cmd_pull --tool codex
    assert_equals 0 "$RC" "rc (out: $OUT err: $ERR)" || return 1
    assert_contains "0.169.1" "$ERR" "installed version on stderr" || return 1
    assert_contains "0.170.0" "$ERR" "latest version on stderr" || return 1
    assert_contains "cac env update codex" "$ERR" "update command on stderr" || return 1
    [[ "$OUT" != *"0.170.0"* ]] || { echo "warning on stdout: $OUT" >&2; return 1; }
    assert_contains "EXTRACTED $(bundle_name codex) (after-warning)" "$OUT" "extracted after the warning"
}

test_2_equal_versions_no_warning() {
    pull cmd_pull --tool claude
    assert_equals 0 "$RC" "rc (out: $OUT err: $ERR)" || return 1
    [[ "$ERR" != *"outdated"* ]] || { echo "warned on equal versions: $ERR" >&2; return 1; }
    assert_contains "EXTRACTED $(bundle_name claude)" "$OUT" "bundle extracted"
}

test_3_unknown_latest_no_warning() {
    NPM_MODE=fail pull cmd_pull --tool codex
    assert_equals 0 "$RC" "rc (out: $OUT err: $ERR)" || return 1
    [[ "$ERR" != *"outdated"* ]] || { echo "warned with unknown latest: $ERR" >&2; return 1; }
    assert_contains "@openai/codex" "$(npm_calls)" "lookup was tried" || return 1
    assert_contains "EXTRACTED $(bundle_name codex)" "$OUT" "bundle extracted"
}

test_4_skip_version_check_skips_lookup() {
    pull cmd_pull --tool codex --skip-version-check
    assert_equals 0 "$RC" "rc (out: $OUT err: $ERR)" || return 1
    assert_equals "" "$(npm_calls)" "no npm lookup" || return 1
    [[ "$ERR" != *"outdated"* ]] || { echo "warned despite skip: $ERR" >&2; return 1; }
    assert_contains "EXTRACTED $(bundle_name codex)" "$OUT" "bundle extracted"
}

test_5_tool_filter_checks_only_that_tool() {
    pull cmd_pull --tool codex
    assert_equals 0 "$RC" "rc (out: $OUT err: $ERR)" || return 1
    assert_equals "view @openai/codex version" "$(npm_calls)" "only codex looked up"
}

test_6_per_tool_pull_warns_per_tool() {
    pull cmd_pull
    assert_equals 0 "$RC" "rc (out: $OUT err: $ERR)" || return 1
    assert_contains "cac env update codex" "$ERR" "codex warned" || return 1
    [[ "$ERR" != *"cac env update claude"* ]] || { echo "claude warned: $ERR" >&2; return 1; }
    assert_contains "EXTRACTED $(bundle_name codex)" "$OUT" "codex extracted" || return 1
    assert_contains "EXTRACTED $(bundle_name claude)" "$OUT" "claude extracted" || return 1
    # gemini has a bundle but no CLI on PATH: extracted, never looked up.
    assert_contains "EXTRACTED $(bundle_name gemini)" "$OUT" "gemini extracted" || return 1
    [[ "$(npm_calls)" != *gemini* ]] || { echo "gemini looked up: $(npm_calls)" >&2; return 1; }
}

test_7_bundle_id_pull_checks_its_tool() {
    pull cmd_pull "$(bundle_name codex)"
    assert_equals 0 "$RC" "rc (out: $OUT err: $ERR)" || return 1
    assert_contains "cac env update codex" "$ERR" "codex warned" || return 1
    assert_contains "EXTRACTED $(bundle_name codex)" "$OUT" "bundle extracted"
}

test_8_get_alias_accepts_skip_flag() {
    pull cmd_get --tool codex --skip-version-check
    assert_equals 0 "$RC" "rc (out: $OUT err: $ERR)" || return 1
    assert_equals "" "$(npm_calls)" "no npm lookup" || return 1
    assert_contains "EXTRACTED $(bundle_name codex)" "$OUT" "bundle extracted"
}

test_9_not_installed_tool_not_looked_up() {
    pull cmd_pull --tool gemini
    # gemini has a bundle but no CLI on PATH: the pull goes ahead, no lookup.
    assert_equals 0 "$RC" "rc (out: $OUT err: $ERR)" || return 1
    assert_contains "EXTRACTED $(bundle_name gemini)" "$OUT" "bundle extracted" || return 1
    assert_equals "" "$(npm_calls)" "no npm lookup" || return 1
    [[ "$ERR" != *"outdated"* ]] || { echo "warned for an uninstalled CLI: $ERR" >&2; return 1; }
}

test_10_help_documents_flag() {
    assert_contains "--skip-version-check" "$(show_help 2>&1)" "help text"
}

run_test "#83 outdated CLI: warning on stderr before extraction" test_1_outdated_cli_warns_before_extraction
run_test "#83 equal versions: no warning"                         test_2_equal_versions_no_warning
run_test "#83 latest unknown (npm 404): no warning"               test_3_unknown_latest_no_warning
run_test "#83 --skip-version-check: no lookup"                    test_4_skip_version_check_skips_lookup
run_test "#83 --tool codex looks up only codex"                   test_5_tool_filter_checks_only_that_tool
run_test "#83 pull without --tool warns per tool"                 test_6_per_tool_pull_warns_per_tool
run_test "#83 pull BUNDLE_ID checks the bundle's tool"            test_7_bundle_id_pull_checks_its_tool
run_test "#83 'cac get' accepts --skip-version-check"             test_8_get_alias_accepts_skip_flag
run_test "#83 tool not installed: no lookup"                      test_9_not_installed_tool_not_looked_up
run_test "#83 help documents --skip-version-check"                test_10_help_documents_flag

rm -rf "$T"

framework_report
