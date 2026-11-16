#!/usr/bin/env bash
# tests/test_issue_158.sh - Tests for Issue #158
#
# `cac pull codex` took "codex" as a BUNDLE_ID substring and failed with
# "Multiple bundles match" as soon as the backend held two codex bundles. A
# known tool name as positional argument now means `--tool <TOOL>`. The
# "Be more specific" list printed the match count between the names.
#
# Seams:
#   cmd_pull ... --dry-run   real Gokapi backend; only the HTTP fetch of the
#                            file list (_gokapi_fetch_file_list) is replaced
#                            by the real-shape fixture gokapi-files-list.json.
#   utils_gokapi_find_file   the same fixture, jq and grep paths.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/gokapi-files-list.json"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=bin/cac
source "$REPO_DIR/bin/cac"
set +e

framework_init

TEST_HOME="$(mktemp -d)"

CAC_BACKEND="gokapi"
CAC_GOKAPI_URL="https://gokapi.example.invalid"
CAC_GOKAPI_API_KEY="FIXTURE"

_gokapi_fetch_file_list() {
    GOKAPI_FILE_LIST="$(cat "$FIXTURE")"
    return 0
}
security_check_user_access()   { return 0; }
security_resolve_user_home()   { echo "$TEST_HOME"; }
utils_preview_extraction()     { :; }

NEWEST_CODEX="CodingAgentConfig_FIXTURE-HOST_fixture_codex_261116-155418.zip"

# pull <args...>: run cmd_pull, set OUT (stdout+stderr) and RC.
pull() {
    RC=0
    OUT=$(cmd_pull "$@" 2>&1) || RC=$?
}

test_1_tool_name_pulls_newest_of_that_tool() {
    pull codex --dry-run
    assert_equals 0 "$RC" "rc (output: $OUT)" || return 1
    assert_contains "Bundle to download: $NEWEST_CODEX" "$OUT" "newest codex bundle"
}

test_2_tool_name_conflicting_with_tool_flag_fails() {
    pull codex --tool claude --dry-run
    [[ "$RC" -ne 0 ]] || { echo "expected non-zero exit, output: $OUT" >&2; return 1; }
    assert_contains "Conflicting tools" "$OUT" "error names the conflict" || return 1
    [[ "$OUT" != *"Bundle to download"* ]] || { echo "a bundle was chosen: $OUT" >&2; return 1; }
}

test_3_tool_name_matching_tool_flag_is_fine() {
    pull codex --tool codex --dry-run
    assert_equals 0 "$RC" "rc (output: $OUT)" || return 1
    assert_contains "Bundle to download: $NEWEST_CODEX" "$OUT" "newest codex bundle"
}

test_4_non_tool_positional_stays_bundle_id() {
    pull FIXTURE-HOST --dry-run
    assert_equals 0 "$RC" "rc (output: $OUT)" || return 1
    assert_contains "Would get bundle: FIXTURE-HOST" "$OUT" "taken as BUNDLE_ID"
}

# A name that only contains a tool name is still a BUNDLE_ID.
test_5_tool_inside_longer_word_stays_bundle_id() {
    pull "claude codex" --dry-run
    assert_contains "Would get bundle: claude codex" "$OUT" "taken as BUNDLE_ID"
}

# find_in_fixture <jq|grep> <bundle_id>: run that implementation behind
# utils_gokapi_find_file (UTILS_HAS_JQ is readonly, so the dispatcher cannot
# be switched). Sets FOUT (stdout), FERR (stderr) and RC.
find_in_fixture() {
    local impl="$1" id="$2" err_file="$TEST_TMPDIR/find.err"
    RC=0
    FOUT=$("_gokapi_find_file_$impl" "$(cat "$FIXTURE")" "$id" 2>"$err_file") || RC=$?
    FERR=$(cat "$err_file")
}

# The names listed after the error line, sorted, must be exactly the five
# codex bundles of the fixture.
assert_lists_exactly_the_codex_bundles() {
    local listed expected
    listed=$(printf '%s\n' "$FERR" | grep -v 'Multiple bundles match' | sort)
    expected=$(printf '%s\n' \
        CodingAgentConfig_FIXTURE-HOST_fixture_codex_261110-065832.zip \
        CodingAgentConfig_FIXTURE-HOST_fixture_codex_261110-081727.zip \
        CodingAgentConfig_FIXTURE-HOST_fixture_codex_261112-164236.zip \
        CodingAgentConfig_FIXTURE-HOST_fixture_codex_261116-110152.zip \
        CodingAgentConfig_FIXTURE-HOST_fixture_codex_261116-155418.zip)
    assert_equals "$expected" "$listed" "listed names"
}

test_6_ambiguous_list_has_no_count_lines_jq() {
    find_in_fixture jq FIXTURE-HOST_fixture_codex
    assert_equals 2 "$RC" "rc" || return 1
    assert_contains "Multiple bundles match 'FIXTURE-HOST_fixture_codex'" "$FERR" "error line" || return 1
    assert_lists_exactly_the_codex_bundles
}

test_7_ambiguous_list_has_no_count_lines_grep() {
    find_in_fixture grep FIXTURE-HOST_fixture_codex
    assert_equals 2 "$RC" "rc" || return 1
    assert_lists_exactly_the_codex_bundles
}

# jq path only: without jq an exact name on the real one-line list returns the
# first entry's URL, a separate bug tracked in its own issue (#159).
test_8_exact_name_and_id_unchanged() {
    find_in_fixture jq "$NEWEST_CODEX"
    assert_equals 0 "$RC" "rc by name" || return 1
    assert_equals "https://gokapi.example.invalid/downloadFile?id=FIXTURE6|$NEWEST_CODEX" "$FOUT" "by name" || return 1
    find_in_fixture jq FIXTURE6
    assert_equals 0 "$RC" "rc by id" || return 1
    assert_equals "https://gokapi.example.invalid/downloadFile?id=FIXTURE6|$NEWEST_CODEX" "$FOUT" "by id"
}

run_test "#158 'pull codex' pulls the newest codex bundle" test_1_tool_name_pulls_newest_of_that_tool
run_test "#158 'pull codex --tool claude' fails"         test_2_tool_name_conflicting_with_tool_flag_fails
run_test "#158 'pull codex --tool codex' works"          test_3_tool_name_matching_tool_flag_is_fine
run_test "#158 non-tool positional stays BUNDLE_ID"      test_4_non_tool_positional_stays_bundle_id
run_test "#158 'claude codex' stays BUNDLE_ID"           test_5_tool_inside_longer_word_stays_bundle_id
run_test "#158 ambiguous list: names only (jq)"          test_6_ambiguous_list_has_no_count_lines_jq
run_test "#158 ambiguous list: names only (grep)"        test_7_ambiguous_list_has_no_count_lines_grep
run_test "#158 exact name and Gokapi ID unchanged"       test_8_exact_name_and_id_unchanged

rm -rf "$TEST_HOME"

framework_report
