#!/usr/bin/env bash
# tests/test_issue_128.sh - Tests for Issue #128
#
# A Gokapi attempt that failed but was going to be retried printed the full
# ERROR block (status, curl exit, hint), even when the retry then succeeded.
# Live: three ERROR lines, then "SUCCESS: [claude] uploaded: ..." for the same
# bundle. A failed attempt with another attempt pending now prints one WARNING
# line; only the final failed attempt prints the ERROR block.
#
# Seams: _gokapi_op_with_retry (request and download paths) and a direct
# _gokapi_try_request call, with a curl stub first on PATH. The stub fails
# with exit 55 (no output) while its call count is <= $FAIL_CALLS, then
# answers like a real curl: a non-empty file for `-o <file>`, otherwise
# `[]` plus the `-w` status trailer 200.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

# shellcheck source=lib/utils.sh
source "$REPO_DIR/lib/utils.sh"
# shellcheck source=lib/backend_gokapi.sh
source "$REPO_DIR/lib/backend_gokapi.sh"

STUB_BIN="$TEST_TMPDIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$CURL_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$CURL_COUNT"
if [[ "$n" -le "$FAIL_CALLS" ]]; then
    exit 55
fi
out=""
prev=""
for a in "$@"; do
    [[ "$prev" == "-o" ]] && out="$a"
    prev="$a"
done
if [[ -n "$out" ]]; then
    echo "zipdata" > "$out"
    exit 0
fi
printf '[]\n200'
EOF
chmod 755 "$STUB_BIN/curl"
PATH="$STUB_BIN:$PATH"

export CAC_GOKAPI_URL="https://h.example"
export CAC_GOKAPI_API_KEY="FIXTURE"
CAC_GOKAPI_MAX_RETRIES=3
CAC_GOKAPI_RETRY_DELAY=0

# stub_fails <n>: the next <n> curl calls fail with exit 55.
stub_fails() {
    CURL_COUNT="$TEST_TMPDIR/count-$RANDOM"
    : > "$CURL_COUNT"
    export CURL_COUNT FAIL_CALLS="$1"
}

# count_lines <prefix> <text>: number of lines in <text> starting with <prefix>.
count_lines() {
    grep -c "^$1" <<< "$2" || true
}

test_1_fail_once_then_succeed_warns_only() {
    stub_fails 1
    local err rc=0
    err=$(_gokapi_op_with_retry request _gokapi_try_request GET /api/files/list 2>&1 >/dev/null) || rc=$?
    assert_equals "0" "$rc" "return code" || return 1
    assert_equals "0" "$(count_lines 'ERROR:' "$err")" "ERROR lines in: $err" || return 1
    assert_equals "1" "$(count_lines 'WARNING:' "$err")" "WARNING lines in: $err" || return 1
    assert_contains "Gokapi list failed (HTTP 000, curl exit 55), retrying (attempt 1/3)" "$err" "warning text"
}

test_2_every_attempt_fails() {
    stub_fails 99
    local err rc=0
    err=$(_gokapi_op_with_retry request _gokapi_try_request GET /api/files/list 2>&1 >/dev/null) || rc=$?
    assert_equals "1" "$rc" "return code" || return 1
    assert_equals "2" "$(count_lines 'WARNING:' "$err")" "WARNING lines in: $err" || return 1
    assert_contains "retrying (attempt 2/3)" "$err" "second warning" || return 1
    # The full #72 block once (status, curl exit, hint), then the summary.
    assert_equals "4" "$(count_lines 'ERROR:' "$err")" "ERROR lines in: $err" || return 1
    assert_equals "1" "$(count_lines 'ERROR:   Hint: Backend URL' "$err")" "hint lines" || return 1
    assert_equals "ERROR: Failed to connect to Gokapi server after 3 attempts" "$(tail -n 1 <<< "$err")" "last line"
}

test_3_direct_call_outside_retry_prints_full_block() {
    stub_fails 1
    local err rc=0
    err=$(_gokapi_try_request GET /api/files/list 2>&1 >/dev/null) || rc=$?
    assert_equals "1" "$rc" "return code" || return 1
    assert_equals "0" "$(count_lines 'WARNING:' "$err")" "WARNING lines in: $err" || return 1
    assert_contains "ERROR: Gokapi list failed: HTTP 000 from https://h.example/api/files/list" "$err" "status line" || return 1
    assert_contains "ERROR:   curl exit 55" "$err" "curl exit line" || return 1
    assert_contains "ERROR:   Hint: Backend URL/availability" "$err" "hint line"
}

test_4_download_fail_once_then_succeed_warns_only() {
    stub_fails 1
    local err rc=0 out="$TEST_TMPDIR/out-$RANDOM.zip"
    err=$(_gokapi_op_with_retry download _gokapi_try_download "https://h.example/hotlink/FIXTURE.zip" "$out" 2>&1 >/dev/null) || rc=$?
    assert_equals "0" "$rc" "return code" || return 1
    assert_equals "0" "$(count_lines 'ERROR:' "$err")" "ERROR lines in: $err" || return 1
    assert_equals "1" "$(count_lines 'WARNING:' "$err")" "WARNING lines in: $err" || return 1
    assert_contains "Gokapi download failed (curl exit 55), retrying (attempt 1/3)" "$err" "warning text"
}

test_5_download_every_attempt_fails() {
    stub_fails 99
    local err rc=0 out="$TEST_TMPDIR/out-$RANDOM.zip"
    err=$(_gokapi_op_with_retry download _gokapi_try_download "https://h.example/hotlink/FIXTURE.zip" "$out" 2>&1 >/dev/null) || rc=$?
    assert_equals "1" "$rc" "return code" || return 1
    assert_equals "2" "$(count_lines 'WARNING:' "$err")" "WARNING lines in: $err" || return 1
    assert_equals "ERROR: Failed to download bundle after 3 attempts" "$(tail -n 1 <<< "$err")" "last line"
}

echo "========================================"
echo "Issue #128 Tests"
echo "========================================"

run_test "128.1 fail once, then succeed: one WARNING, no ERROR" test_1_fail_once_then_succeed_warns_only
run_test "128.2 every attempt fails: N-1 WARNINGs, then the ERROR block once" test_2_every_attempt_fails
run_test "128.3 direct call outside a retry: full ERROR block" test_3_direct_call_outside_retry_prints_full_block
run_test "128.4 download fails once, then succeeds: one WARNING, no ERROR" test_4_download_fail_once_then_succeed_warns_only
run_test "128.5 download fails every attempt: N-1 WARNINGs, then the summary" test_5_download_every_attempt_fails

framework_report
