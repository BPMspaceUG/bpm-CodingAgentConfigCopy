#!/usr/bin/env bash
# tests/test_issue_159.sh - Tests for Issue #159
#
# Without jq, the grep fallback of the Gokapi file-list lookup returned the
# first entry's URL (and the first entry's Id for delete) on the real
# /api/files/list answer, which is one line of JSON. `cac pull <NAME>` on a
# jq-less host then downloaded a different bundle under the requested name.
#
# Seams (run in a child bash whose PATH has no jq, so the real dispatchers
# take the grep path; UTILS_HAS_JQ is readonly and cannot be switched here):
#   utils_gokapi_find_file   exact name, Gokapi ID, unique partial match
#   utils_gokapi_find_id     ID lookup used by `cac delete`
# Both against the real-shape fixture gokapi-files-list.json.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/gokapi-files-list.json"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

# A PATH with every command of the normal PATH except jq.
NOJQ_BIN="$(mktemp -d)"
IFS=':' read -r -a _path_dirs <<< "$PATH"
for _dir in "${_path_dirs[@]}"; do
    [[ -d "$_dir" ]] || continue
    for _cmd in "$_dir"/*; do
        _name="${_cmd##*/}"
        [[ "$_name" == "jq" || -e "$NOJQ_BIN/$_name" || ! -x "$_cmd" ]] && continue
        ln -s "$_cmd" "$NOJQ_BIN/$_name" 2>/dev/null || true
    done
done

# nojq <function> <arg>: call a cac function with jq hidden, the fixture as
# first argument. Sets OUT (stdout) and RC.
nojq() {
    RC=0
    OUT=$(PATH="$NOJQ_BIN" bash -c '
        source "$1/bin/cac" >/dev/null 2>&1; set +e
        $UTILS_HAS_JQ && { echo "jq still visible" >&2; exit 99; }
        "$2" "$(cat "$3")" "$4"
    ' _ "$REPO_DIR" "$1" "$FIXTURE" "$2" 2>/dev/null) || RC=$?
}

NEWEST_CODEX="CodingAgentConfig_FIXTURE-HOST_fixture_codex_261116-155418.zip"
URL6="https://gokapi.example.invalid/downloadFile?id=FIXTURE6"

test_1_exact_name_returns_its_url() {
    nojq utils_gokapi_find_file "$NEWEST_CODEX"
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "$URL6|$NEWEST_CODEX" "$OUT" "by exact name"
}

test_2_gokapi_id_returns_its_url_and_name() {
    nojq utils_gokapi_find_file FIXTURE6
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "$URL6|$NEWEST_CODEX" "$OUT" "by id"
}

# FIXTURE1 is also a prefix of FIXTURE10..14: only the exact Id counts.
test_3_id_prefix_of_other_ids_is_exact() {
    nojq utils_gokapi_find_file FIXTURE1
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "https://gokapi.example.invalid/downloadFile?id=FIXTURE1|CodingAgentConfig_FIXTURE-HOST_fixture_claude_261110-081726.zip" "$OUT" "by id"
}

test_4_unique_partial_returns_its_url() {
    nojq utils_gokapi_find_file "codex_261116-155418"
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "$URL6|$NEWEST_CODEX" "$OUT" "by partial name"
}

test_5_last_entry_by_name() {
    nojq utils_gokapi_find_file "CodingAgentConfig_FIXTURE-HOST_fixture_gemini_261116-110152.zip"
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "https://gokapi.example.invalid/downloadFile?id=FIXTURE14|CodingAgentConfig_FIXTURE-HOST_fixture_gemini_261116-110152.zip" "$OUT" "last entry"
}

test_6_find_id_for_delete() {
    nojq utils_gokapi_find_id "$NEWEST_CODEX"
    assert_equals "FIXTURE6" "$OUT" "id for delete"
}

test_7_find_id_unknown_name_is_empty() {
    nojq utils_gokapi_find_id "CodingAgentConfig_nope.zip"
    assert_equals "" "$OUT" "no id"
}

test_8_unknown_returns_1() {
    nojq utils_gokapi_find_file "CodingAgentConfig_nope.zip"
    assert_equals 1 "$RC" "rc"
}

run_test "#159 no jq: exact name -> its URL"           test_1_exact_name_returns_its_url
run_test "#159 no jq: Gokapi ID -> its URL and name"   test_2_gokapi_id_returns_its_url_and_name
run_test "#159 no jq: ID prefix of other IDs is exact" test_3_id_prefix_of_other_ids_is_exact
run_test "#159 no jq: unique partial -> its URL"       test_4_unique_partial_returns_its_url
run_test "#159 no jq: last entry by name"              test_5_last_entry_by_name
run_test "#159 no jq: find_id for delete"              test_6_find_id_for_delete
run_test "#159 no jq: find_id unknown name is empty"   test_7_find_id_unknown_name_is_empty
run_test "#159 no jq: unknown bundle returns 1"        test_8_unknown_returns_1

rm -rf "$NOJQ_BIN"

framework_report
