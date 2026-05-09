#!/usr/bin/env bash
# tests/test_issue_72.sh - Tests for Issue #72:
#   `cac push` against a Gokapi backend returning HTTP 404 currently reports
#   a generic "Failed to parse upload response — Response: 404 page not found"
#   with no diagnostic value. Fix: lib/backend_gokapi.sh now captures the
#   HTTP status (via curl -w '%{http_code}') and emits a structured error
#   with the status code, request URL, body excerpt, and a remediation hint.
#
# Style mirrors tests/test_issue_71.sh: self-contained helpers, ANSI colors,
# manual counters, set -uo pipefail (no errexit so ((c++)) from 0 is safe).
# Sources lib/* for unit-level coverage of the new helpers and behavioural
# coverage of the structured-error / hint-mapping path. Network-free —
# `curl` is overridden as a bash function inside each test subshell.
#
# Test inventory (11 cases, mapped to acceptance criteria of #72):
#   72.1   404 from upload -> structured error + URL/availability hint
#   72.2   401 from upload -> auth hint
#   72.2b  403 from upload -> auth hint
#   72.3   5xx retried CAC_GOKAPI_MAX_RETRIES times (utils_retry baseline)
#   72.4   200 + valid JSON -> success path unchanged
#   72.5   200 + invalid JSON -> existing parse-error preserved
#   72.7   curl exit non-zero -> status 000 + curl-exit code in error
#   72.8   defensive ?apikey= URL redaction
#   72.9   hint differentiation 404 vs 000
#   72.10  list endpoint also benefits (not just upload)
#   72.11  legacy _gokapi_request stub semantics preserved (R3)
#
# In all redaction-sensitive tests, the API key value is the unique sentinel
# string `secret-test-key-72-DO-NOT-PRINT-xyz` — so the absence assertion is
# the strongest possible "no leak" assertion.

set -uo pipefail

# ----------------------------------------------------------------------------
# Globals & helpers
# ----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((PASSED++)) || true
    ((TOTAL++)) || true
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "       Reason: $2"
    fi
    ((FAILED++)) || true
    ((TOTAL++)) || true
}

skip() {
    echo -e "${YELLOW}SKIP${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "       Reason: $2"
    fi
    ((SKIPPED++)) || true
    ((TOTAL++)) || true
}

header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

# Single root tmp tree, removed on EXIT.
ROOT_TMP=$(mktemp -d -t cac-test-72.XXXXXXXXXX)
trap '_teardown' EXIT
_teardown() {
    rm -rf "$ROOT_TMP" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Source library modules
# ----------------------------------------------------------------------------
# Order matches tests/test_gokapi_unit.sh: logging -> utils -> bundle -> backend.
# shellcheck source=../lib/logging.sh
source "${REPO_DIR}/lib/logging.sh"
# shellcheck source=../lib/utils.sh
source "${REPO_DIR}/lib/utils.sh"
# shellcheck source=../lib/bundle.sh
source "${REPO_DIR}/lib/bundle.sh"
# shellcheck source=../lib/backend_gokapi.sh
source "${REPO_DIR}/lib/backend_gokapi.sh"

# Disable retries by default for fast tests. Test 72.3 raises this explicitly.
CAC_GOKAPI_MAX_RETRIES=1
CAC_GOKAPI_RETRY_DELAY=0

# Test fixtures: unique, recognisable values so absence assertions are strong.
TEST_API_KEY="secret-test-key-72-DO-NOT-PRINT-xyz"
TEST_BASE_URL="https://test.example/api"

# ----------------------------------------------------------------------------
# Common helpers used inside test subshells
# ----------------------------------------------------------------------------
_scratch() {
    local name="$1"
    local d="${ROOT_TMP}/${name}"
    mkdir -p "$d"
    echo "$d"
}

# Build a tiny dummy zip file for upload tests (must exist on disk; content
# does not matter because curl is stubbed).
_make_dummy_zip() {
    local out="$1"
    : > "$out"
    return 0
}

# ----------------------------------------------------------------------------
# 72.1 — 404 from upload -> structured error + URL/availability hint
# ----------------------------------------------------------------------------
test_72_1_upload_404_structured_error() {
    local name="72.1"
    local T STDERR_FILE STDOUT_FILE
    T=$(_scratch "$name")
    STDERR_FILE="$T/stderr"
    STDOUT_FILE="$T/stdout"
    local ZIP="$T/dummy.zip"
    _make_dummy_zip "$ZIP"

    (
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        export CAC_GOKAPI_MAX_RETRIES=1
        export CAC_GOKAPI_RETRY_DELAY=0

        # Stub curl: status=404, body="404 page not found".
        # The body is appended with the -w trailer (\n<status>) when -w is
        # in argv (which our new helper always passes).
        curl() {
            local has_w=false
            for arg in "$@"; do [[ "$arg" == "-w" ]] && has_w=true; done
            if $has_w; then
                printf '%s\n%s' "404 page not found" "404"
            else
                printf '%s' "404 page not found"
            fi
            return 0
        }
        export -f curl

        backend_gokapi_upload "$ZIP" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo $? > "$T/exit"
    )

    local exit_code stderr_content stdout_content
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")
    stdout_content=$(cat "$STDOUT_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name 404 structured error" "expected non-zero exit, got 0. stderr=$stderr_content"
        return
    fi
    if [[ "$stderr_content" != *"HTTP 404"* ]]; then
        fail "$name 404 structured error" "stderr missing 'HTTP 404': $stderr_content"
        return
    fi
    if [[ "$stderr_content" != *"from ${TEST_BASE_URL}/api/files/add"* ]]; then
        fail "$name 404 structured error" "stderr missing URL: $stderr_content"
        return
    fi
    if [[ "$stderr_content" != *"404 page not found"* ]]; then
        fail "$name 404 structured error" "stderr missing body excerpt: $stderr_content"
        return
    fi
    if [[ "$stderr_content" != *"Backend URL/availability"* ]]; then
        fail "$name 404 structured error" "stderr missing availability hint: $stderr_content"
        return
    fi
    # CRITICAL: no API key leak (literal sentinel must NOT appear).
    if [[ "$stderr_content" == *"$TEST_API_KEY"* || "$stdout_content" == *"$TEST_API_KEY"* ]]; then
        fail "$name 404 structured error" "API key sentinel leaked into output"
        return
    fi
    pass "$name 404 from upload yields structured error + URL/availability hint, no API key leak"
}

# ----------------------------------------------------------------------------
# 72.2 — 401 from upload -> auth hint
# ----------------------------------------------------------------------------
test_72_2_upload_401_auth_hint() {
    local name="72.2"
    local T STDERR_FILE STDOUT_FILE
    T=$(_scratch "$name")
    STDERR_FILE="$T/stderr"
    STDOUT_FILE="$T/stdout"
    local ZIP="$T/dummy.zip"
    _make_dummy_zip "$ZIP"

    (
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        export CAC_GOKAPI_MAX_RETRIES=1
        export CAC_GOKAPI_RETRY_DELAY=0

        curl() {
            printf '%s\n%s' '{"error":"unauthorized"}' "401"
            return 0
        }
        export -f curl

        backend_gokapi_upload "$ZIP" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo $? > "$T/exit"
    )

    local exit_code stderr_content stdout_content
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")
    stdout_content=$(cat "$STDOUT_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name 401 auth hint" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$stderr_content" != *"HTTP 401"* ]]; then
        fail "$name 401 auth hint" "stderr missing 'HTTP 401': $stderr_content"
        return
    fi
    if [[ "$stderr_content" != *"Authentication"* ]] || [[ "$stderr_content" != *"rotate"* ]]; then
        fail "$name 401 auth hint" "stderr missing auth hint: $stderr_content"
        return
    fi
    if [[ "$stderr_content" == *"$TEST_API_KEY"* || "$stdout_content" == *"$TEST_API_KEY"* ]]; then
        fail "$name 401 auth hint" "API key sentinel leaked"
        return
    fi
    pass "$name 401 from upload yields auth hint, no API key leak"
}

# ----------------------------------------------------------------------------
# 72.2b — 403 from upload -> auth hint (same code path as 401)
# ----------------------------------------------------------------------------
test_72_2b_upload_403_auth_hint() {
    local name="72.2b"
    local T STDERR_FILE STDOUT_FILE
    T=$(_scratch "$name")
    STDERR_FILE="$T/stderr"
    STDOUT_FILE="$T/stdout"
    local ZIP="$T/dummy.zip"
    _make_dummy_zip "$ZIP"

    (
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        export CAC_GOKAPI_MAX_RETRIES=1
        export CAC_GOKAPI_RETRY_DELAY=0

        curl() {
            printf '%s\n%s' '{"error":"forbidden"}' "403"
            return 0
        }
        export -f curl

        backend_gokapi_upload "$ZIP" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo $? > "$T/exit"
    )

    local exit_code stderr_content stdout_content
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")
    stdout_content=$(cat "$STDOUT_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name 403 auth hint" "expected non-zero exit"
        return
    fi
    if [[ "$stderr_content" != *"HTTP 403"* ]]; then
        fail "$name 403 auth hint" "stderr missing 'HTTP 403': $stderr_content"
        return
    fi
    if [[ "$stderr_content" != *"Authentication"* ]] || [[ "$stderr_content" != *"rotate"* ]]; then
        fail "$name 403 auth hint" "stderr missing auth hint: $stderr_content"
        return
    fi
    if [[ "$stderr_content" == *"$TEST_API_KEY"* || "$stdout_content" == *"$TEST_API_KEY"* ]]; then
        fail "$name 403 auth hint" "API key sentinel leaked"
        return
    fi
    pass "$name 403 from upload yields auth hint, no API key leak"
}

# ----------------------------------------------------------------------------
# 72.3 — 5xx retried CAC_GOKAPI_MAX_RETRIES times (utils_retry baseline pin)
# ----------------------------------------------------------------------------
test_72_3_5xx_retried_max_retries_times() {
    local name="72.3"
    local T STDERR_FILE STDOUT_FILE COUNTER
    T=$(_scratch "$name")
    STDERR_FILE="$T/stderr"
    STDOUT_FILE="$T/stdout"
    COUNTER="$T/curl_count"
    : > "$COUNTER"
    local ZIP="$T/dummy.zip"
    _make_dummy_zip "$ZIP"

    (
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        export CAC_GOKAPI_MAX_RETRIES=3
        export CAC_GOKAPI_RETRY_DELAY=0
        export STUB_COUNTER="$COUNTER"

        curl() {
            # Bump invocation counter.
            local n=0
            [[ -s "$STUB_COUNTER" ]] && n=$(cat "$STUB_COUNTER")
            echo $((n + 1)) > "$STUB_COUNTER"
            printf '%s\n%s' "Bad Gateway" "502"
            return 0
        }
        export -f curl

        backend_gokapi_upload "$ZIP" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo $? > "$T/exit"
    )

    local exit_code stderr_content count
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")
    count=$(cat "$COUNTER" 2>/dev/null || echo "0")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name 5xx retry count" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$count" != "3" ]]; then
        fail "$name 5xx retry count" "expected 3 curl invocations, got $count"
        return
    fi
    if [[ "$stderr_content" != *"HTTP 502"* ]]; then
        fail "$name 5xx retry count" "stderr missing 'HTTP 502': $stderr_content"
        return
    fi
    if [[ "$stderr_content" != *"Server error"* ]]; then
        fail "$name 5xx retry count" "stderr missing 'Server error' hint: $stderr_content"
        return
    fi
    pass "$name 5xx retried CAC_GOKAPI_MAX_RETRIES (=3) times, server-error hint emitted"
}

# ----------------------------------------------------------------------------
# 72.4 — 200 + valid JSON -> success path unchanged
# ----------------------------------------------------------------------------
test_72_4_200_valid_json_success() {
    local name="72.4"
    local T STDERR_FILE STDOUT_FILE
    T=$(_scratch "$name")
    STDERR_FILE="$T/stderr"
    STDOUT_FILE="$T/stdout"
    local ZIP="$T/dummy.zip"
    _make_dummy_zip "$ZIP"

    (
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        export CAC_GOKAPI_MAX_RETRIES=1
        export CAC_GOKAPI_RETRY_DELAY=0

        curl() {
            printf '%s\n%s' '{"Id":"abc123","Name":"x.zip","Result":"ok"}' "200"
            return 0
        }
        export -f curl

        backend_gokapi_upload "$ZIP" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo $? > "$T/exit"
        # Capture the GOKAPI_RESPONSE value (only meaningful inside this subshell).
        # Use :- guard because under set -u, an unset var would crash the subshell.
        echo "${GOKAPI_RESPONSE:-}" > "$T/response"
    )

    local exit_code stdout_content stderr_content response
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stdout_content=$(cat "$STDOUT_FILE" 2>/dev/null || echo "")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")
    response=$(cat "$T/response" 2>/dev/null || echo "")

    if [[ "$exit_code" != "0" ]]; then
        fail "$name 200 success path" "expected exit 0, got $exit_code. stderr=$stderr_content"
        return
    fi
    if [[ "$stdout_content" != *"Uploaded:"* ]] || [[ "$stdout_content" != *"abc123"* ]]; then
        fail "$name 200 success path" "stdout missing 'Uploaded:' or file id 'abc123': $stdout_content"
        return
    fi
    if [[ "$stderr_content" == *"ERROR:"* ]]; then
        fail "$name 200 success path" "stderr contains ERROR line on success path: $stderr_content"
        return
    fi
    if [[ "$response" != *'"Id":"abc123"'* ]]; then
        fail "$name 200 success path" "GOKAPI_RESPONSE not set to expected body: $response"
        return
    fi
    pass "$name 200 + valid JSON: success path unchanged, GOKAPI_RESPONSE populated"
}

# ----------------------------------------------------------------------------
# 72.5 — 200 + invalid JSON -> existing parse-error preserved
# ----------------------------------------------------------------------------
test_72_5_200_invalid_json_parse_error() {
    local name="72.5"
    local T STDERR_FILE STDOUT_FILE
    T=$(_scratch "$name")
    STDERR_FILE="$T/stderr"
    STDOUT_FILE="$T/stdout"
    local ZIP="$T/dummy.zip"
    _make_dummy_zip "$ZIP"

    (
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        export CAC_GOKAPI_MAX_RETRIES=1
        export CAC_GOKAPI_RETRY_DELAY=0

        curl() {
            # 200 OK transport, but body is HTML (no Id/Name fields).
            printf '%s\n%s' '<html>oops</html>' "200"
            return 0
        }
        export -f curl

        backend_gokapi_upload "$ZIP" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo $? > "$T/exit"
    )

    local exit_code stderr_content combined
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")
    combined=$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name 200+invalid JSON" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$stderr_content" != *"Failed to parse upload response"* ]]; then
        fail "$name 200+invalid JSON" "stderr missing 'Failed to parse upload response': $stderr_content"
        return
    fi
    # CRITICAL: the new HTTP-error path must NOT have fired (this is a
    # different failure class — 2xx with bad body, not non-2xx transport).
    if [[ "$combined" == *"HTTP 200"* ]] || [[ "$combined" == *"Gokapi upload failed: HTTP"* ]]; then
        fail "$name 200+invalid JSON" "new HTTP-error path incorrectly fired on 2xx body: $combined"
        return
    fi
    pass "$name 200 + invalid JSON: existing parse-error preserved, HTTP-error path not triggered"
}

# ----------------------------------------------------------------------------
# 72.7 — curl exit non-zero -> status 000 + curl-exit code in error message
# ----------------------------------------------------------------------------
test_72_7_curl_exit_nonzero_status_000() {
    local name="72.7"
    local T STDERR_FILE STDOUT_FILE
    T=$(_scratch "$name")
    STDERR_FILE="$T/stderr"
    STDOUT_FILE="$T/stdout"
    local ZIP="$T/dummy.zip"
    _make_dummy_zip "$ZIP"

    (
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        export CAC_GOKAPI_MAX_RETRIES=1
        export CAC_GOKAPI_RETRY_DELAY=0

        # Stub: simulate curl exit 6 (host unreachable). No stdout, return 6.
        curl() {
            return 6
        }
        export -f curl

        backend_gokapi_upload "$ZIP" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo $? > "$T/exit"
    )

    local exit_code stderr_content
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name curl exit nonzero" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$stderr_content" != *"HTTP 000"* ]]; then
        fail "$name curl exit nonzero" "stderr missing 'HTTP 000': $stderr_content"
        return
    fi
    if [[ "$stderr_content" != *"curl exit 6"* ]]; then
        fail "$name curl exit nonzero" "stderr missing 'curl exit 6': $stderr_content"
        return
    fi
    if [[ "$stderr_content" != *"Backend URL/availability"* ]]; then
        fail "$name curl exit nonzero" "stderr missing availability hint: $stderr_content"
        return
    fi
    pass "$name curl exit non-zero produces HTTP 000 + curl-exit code + URL/availability hint"
}

# ----------------------------------------------------------------------------
# 72.8 — defensive ?apikey= URL redaction
# ----------------------------------------------------------------------------
test_72_8_apikey_url_redaction() {
    local name="72.8"
    local T STDERR_FILE STDOUT_FILE
    T=$(_scratch "$name")
    STDERR_FILE="$T/stderr"
    STDOUT_FILE="$T/stdout"
    local ZIP="$T/dummy.zip"
    _make_dummy_zip "$ZIP"

    local URL_KEY_SENTINEL="visible-key-72-DO-NOT-PRINT"

    (
        # Configure URL with apikey query param to exercise the redact helper.
        export CAC_GOKAPI_URL="https://x.example/api?apikey=${URL_KEY_SENTINEL}"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        export CAC_GOKAPI_MAX_RETRIES=1
        export CAC_GOKAPI_RETRY_DELAY=0

        curl() {
            printf '%s\n%s' "404 page not found" "404"
            return 0
        }
        export -f curl

        backend_gokapi_upload "$ZIP" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo $? > "$T/exit"
    )

    local exit_code stderr_content stdout_content combined
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")
    stdout_content=$(cat "$STDOUT_FILE" 2>/dev/null || echo "")
    combined="${stdout_content}${stderr_content}"

    if [[ "$exit_code" == "0" ]]; then
        fail "$name URL redaction" "expected non-zero exit"
        return
    fi
    if [[ "$stderr_content" != *"apikey=***"* ]]; then
        fail "$name URL redaction" "stderr missing 'apikey=***' redaction marker: $stderr_content"
        return
    fi
    if [[ "$combined" == *"$URL_KEY_SENTINEL"* ]]; then
        fail "$name URL redaction" "URL apikey sentinel leaked: $combined"
        return
    fi
    if [[ "$combined" == *"$TEST_API_KEY"* ]]; then
        fail "$name URL redaction" "header API key sentinel leaked: $combined"
        return
    fi
    pass "$name URL apikey= query parameter redacted to ***, no key sentinel leaked"
}

# ----------------------------------------------------------------------------
# 72.9 — hint differentiation 404 vs 000
# ----------------------------------------------------------------------------
test_72_9_hint_differentiation_404_vs_000() {
    local name="72.9"
    local T
    T=$(_scratch "$name")
    local ZIP="$T/dummy.zip"
    _make_dummy_zip "$ZIP"

    # ----- 404 leg -----
    local STDERR_404="$T/stderr_404"
    (
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        export CAC_GOKAPI_MAX_RETRIES=1
        export CAC_GOKAPI_RETRY_DELAY=0
        curl() {
            printf '%s\n%s' "Not Found" "404"
            return 0
        }
        export -f curl
        backend_gokapi_upload "$ZIP" >/dev/null 2>"$STDERR_404"
    )

    local stderr_404
    stderr_404=$(cat "$STDERR_404" 2>/dev/null || echo "")

    if [[ "$stderr_404" != *"Backend URL/availability"* ]]; then
        fail "$name 404 hint" "404 stderr missing URL/availability hint: $stderr_404"
        return
    fi
    if [[ "$stderr_404" == *"curl exit"* ]]; then
        fail "$name 404 hint" "404 stderr unexpectedly contains 'curl exit' (only 000 should): $stderr_404"
        return
    fi

    # ----- 000 leg -----
    local STDERR_000="$T/stderr_000"
    (
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        export CAC_GOKAPI_MAX_RETRIES=1
        export CAC_GOKAPI_RETRY_DELAY=0
        curl() { return 7; }
        export -f curl
        backend_gokapi_upload "$ZIP" >/dev/null 2>"$STDERR_000"
    )

    local stderr_000
    stderr_000=$(cat "$STDERR_000" 2>/dev/null || echo "")

    if [[ "$stderr_000" != *"Backend URL/availability"* ]]; then
        fail "$name 000 hint" "000 stderr missing URL/availability hint: $stderr_000"
        return
    fi
    if [[ "$stderr_000" != *"curl exit 7"* ]]; then
        fail "$name 000 hint" "000 stderr missing 'curl exit 7': $stderr_000"
        return
    fi

    pass "$name hint differentiation: 404 omits 'curl exit' (HTTP-only), 000 includes 'curl exit N'"
}

# ----------------------------------------------------------------------------
# 72.10 — list endpoint also benefits (helper-level fix, not just upload)
# ----------------------------------------------------------------------------
test_72_10_list_endpoint_also_benefits() {
    local name="72.10"
    local T STDERR_FILE STDOUT_FILE
    T=$(_scratch "$name")
    STDERR_FILE="$T/stderr"
    STDOUT_FILE="$T/stdout"

    (
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        export CAC_GOKAPI_MAX_RETRIES=1
        export CAC_GOKAPI_RETRY_DELAY=0

        curl() {
            printf '%s\n%s' "404 page not found" "404"
            return 0
        }
        export -f curl

        backend_gokapi_list >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo $? > "$T/exit"
    )

    local exit_code stderr_content
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name list 404" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$stderr_content" != *"HTTP 404"* ]]; then
        fail "$name list 404" "stderr missing 'HTTP 404': $stderr_content"
        return
    fi
    if [[ "$stderr_content" != *"/api/files/list"* ]]; then
        fail "$name list 404" "stderr missing '/api/files/list' in URL: $stderr_content"
        return
    fi
    if [[ "$stderr_content" != *"Backend URL/availability"* ]]; then
        fail "$name list 404" "stderr missing availability hint: $stderr_content"
        return
    fi
    pass "$name list endpoint also produces structured HTTP-error (helper-level fix verified)"
}

# ----------------------------------------------------------------------------
# 72.11 — legacy _gokapi_request stub semantics preserved (R3)
# ----------------------------------------------------------------------------
# Two-part contract test:
#  (a) The unchanged _gokapi_request still returns the legacy (no-trailer)
#      body verbatim when overridden as a function — proves test_gokapi_unit.sh
#      style stubs continue to work.
#  (b) The new _gokapi_request_with_status enforces the strict trailer
#      contract: a curl stub that does NOT honour -w must yield status="000"
#      and a non-zero return — NOT a silent "assume 200" fall-through.
test_72_11_legacy_request_stub_compat() {
    local name="72.11"
    local T
    T=$(_scratch "$name")

    # ----- Part (a): legacy _gokapi_request stub returns body verbatim -----
    local part_a_out part_a_exit
    part_a_out=$(
        # Override the legacy helper directly (no trailer awareness).
        _gokapi_request() {
            printf '%s' '{"Result":"ok","Id":"legacy123"}'
            return 0
        }
        _gokapi_request "GET" "/api/files/list"
    )
    part_a_exit=$?

    if [[ "$part_a_exit" != "0" || "$part_a_out" != '{"Result":"ok","Id":"legacy123"}' ]]; then
        fail "$name legacy stub compat (a)" \
             "_gokapi_request override broke. exit=$part_a_exit, out=$part_a_out"
        return
    fi

    # ----- Part (b): legacy curl-stub (no \n in output) takes the documented
    # legacy-stub compatibility path: status=200, return 0. This is the
    # branch in lib/backend_gokapi.sh:_gokapi_request_with_status that
    # exists SOLELY for tests/test_gokapi_unit.sh's _mock_curl helper
    # which prints the canned body to stdout and ignores the -w flag.
    # In production, real curl always appends the trailer, so this branch
    # is unreachable with curl_exit==0.
    local b_status b_rc
    b_status=$(
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        # Stub curl that ignores -w and returns body only (no \n).
        curl() {
            printf '%s' '{"Id":"abc"}'
            return 0
        }
        export -f curl

        _gokapi_request_with_status "GET" "/api/files/list" >/dev/null 2>&1
        local rc=$?
        printf '%s|%s|%s' "${GOKAPI_HTTP_STATUS:-MISSING}" "${GOKAPI_RAW_BODY:-MISSING}" "$rc"
    )
    b_rc="${b_status##*|}"
    local b_rest="${b_status%|*}"
    local b_body="${b_rest##*|}"
    local b_http="${b_rest%|*}"

    if [[ "$b_http" != "200" ]]; then
        fail "$name legacy stub compat (b)" \
             "expected GOKAPI_HTTP_STATUS=200 on no-newline legacy stub, got '$b_http' (rc=$b_rc, body=$b_body)"
        return
    fi
    if [[ "$b_rc" != "0" ]]; then
        fail "$name legacy stub compat (b)" \
             "expected rc=0 on no-newline legacy stub (compat path), got $b_rc"
        return
    fi
    if [[ "$b_body" != '{"Id":"abc"}' ]]; then
        fail "$name legacy stub compat (b)" \
             "expected GOKAPI_RAW_BODY to hold legacy body, got '$b_body'"
        return
    fi

    # ----- Part (b2): GENUINELY malformed trailer (has \n but not a 3-digit
    # last line) IS rejected with status=000 and rc=1. This is the strict
    # path that protects against real transport corruption — distinct from
    # the legacy-stub compat path above.
    local b2_status b2_rc
    b2_status=$(
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        curl() {
            # Has \n, but last line is NOT a 3-digit code → strict path rejects.
            printf '%s\n%s' '{"Id":"abc"}' "garbage-not-a-status-code"
            return 0
        }
        export -f curl

        _gokapi_request_with_status "GET" "/api/files/list" >/dev/null 2>&1
        local rc=$?
        printf '%s|%s' "${GOKAPI_HTTP_STATUS:-MISSING}" "$rc"
    )
    b2_rc="${b2_status##*|}"
    local b2_http="${b2_status%|*}"

    if [[ "$b2_http" != "000" ]]; then
        fail "$name strict-malformed-trailer (b2)" \
             "expected status=000 on malformed-trailer (with \\n), got '$b2_http' (rc=$b2_rc)"
        return
    fi
    if [[ "$b2_rc" == "0" ]]; then
        fail "$name strict-malformed-trailer (b2)" \
             "expected rc!=0 on malformed-trailer, got 0"
        return
    fi

    # ----- Part (c): legacy _gokapi_request and new helper are independent -----
    # Override _gokapi_request to a sentinel; calling _gokapi_request_with_status
    # must NOT route through it (they are separate functions).
    #
    # NOTE: The new helper writes the body to GOKAPI_RAW_BODY (a global), NOT
    # stdout — see lib/backend_gokapi.sh:_gokapi_request_with_status. We
    # therefore capture state via a printf line at the end of the subshell.
    local c_marker c_rc c_body c_status
    c_marker=$(
        export CAC_GOKAPI_URL="$TEST_BASE_URL"
        export CAC_GOKAPI_API_KEY="$TEST_API_KEY"
        # Override _gokapi_request to print a unique sentinel.
        _gokapi_request() {
            printf '%s' "LEGACY_PATH_HIT_SENTINEL"
            return 0
        }
        # Curl stub provides a proper trailer so the new helper succeeds.
        curl() {
            printf '%s\n%s' '{"ok":true}' "200"
            return 0
        }
        export -f curl

        _gokapi_request_with_status "GET" "/api/files/list" >/dev/null 2>&1
        local rc=$?
        # Print "<body>|<status>|<rc>" (body is now in GOKAPI_RAW_BODY).
        printf '%s|%s|%s' "${GOKAPI_RAW_BODY:-MISSING}" "${GOKAPI_HTTP_STATUS:-MISSING}" "$rc"
    )
    # Parse "<body>|<status>|<rc>" — split from the right since body may
    # contain '|' chars. Pattern: ${var%|*} strips the trailing |<rc>.
    c_rc="${c_marker##*|}"
    local c_rest="${c_marker%|*}"
    c_status="${c_rest##*|}"
    c_body="${c_rest%|*}"

    if [[ "$c_rc" != "0" ]]; then
        fail "$name independence (c)" "new helper returned $c_rc with valid stub (body=$c_body, status=$c_status)"
        return
    fi
    if [[ "$c_status" != "200" ]]; then
        fail "$name independence (c)" "expected status=200, got $c_status"
        return
    fi
    if [[ "$c_body" == *"LEGACY_PATH_HIT_SENTINEL"* ]]; then
        fail "$name independence (c)" \
             "new helper unexpectedly routed through legacy _gokapi_request: $c_body"
        return
    fi
    if [[ "$c_body" != '{"ok":true}' ]]; then
        fail "$name independence (c)" "new helper returned unexpected body: $c_body"
        return
    fi

    pass "$name legacy _gokapi_request stub still works; new helper has strict trailer contract; the two functions are independent"
}

# ----------------------------------------------------------------------------
# Runner
# ----------------------------------------------------------------------------

header "Issue #72 tests: surface HTTP status from Gokapi backend"

test_72_1_upload_404_structured_error
test_72_2_upload_401_auth_hint
test_72_2b_upload_403_auth_hint
test_72_3_5xx_retried_max_retries_times
test_72_4_200_valid_json_success
test_72_5_200_invalid_json_parse_error
test_72_7_curl_exit_nonzero_status_000
test_72_8_apikey_url_redaction
test_72_9_hint_differentiation_404_vs_000
test_72_10_list_endpoint_also_benefits
test_72_11_legacy_request_stub_compat

echo ""
echo "=========================================="
echo "Results: $PASSED/$TOTAL passed (skipped: $SKIPPED)"
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED}$FAILED test(s) failed${NC}"
    exit 1
fi
echo -e "${GREEN}All run tests passed${NC}"
exit 0
