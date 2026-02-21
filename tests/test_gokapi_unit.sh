#!/usr/bin/env bash
# tests/test_gokapi_unit.sh - Unit tests for Gokapi backend (lib/backend_gokapi.sh)
#
# Run with: ./tests/test_gokapi_unit.sh
# Or run all tests: ./tests/run_tests.sh gokapi_unit
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test
# shellcheck disable=SC2034  # Variables are used by sourced library modules

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source shared test framework
source "${SCRIPT_DIR}/test_framework.sh"

# Source library modules (order matters: logging first, then utils, bundle, backend)
source "${PROJECT_ROOT}/lib/logging.sh"
source "${PROJECT_ROOT}/lib/utils.sh"
source "${PROJECT_ROOT}/lib/bundle.sh"
source "${PROJECT_ROOT}/lib/backend_gokapi.sh"

# Disable retries and delays for fast tests
CAC_GOKAPI_MAX_RETRIES=1
CAC_GOKAPI_RETRY_DELAY=0

# ============================================================================
# Helper: Mock curl with request shape validation
# ============================================================================

# Log file for recording curl calls (method and endpoint)
MOCK_CURL_LOG=""

# Set up a mock curl that returns canned response and logs request shape.
# Usage: _mock_curl <stdout_data> [exit_code]
# Must be called inside test functions (which run in subshells via run_test).
# After the test, use _assert_mock_method to verify correct HTTP method/endpoint.
_mock_curl() {
    local response="$1"
    local exit_code="${2:-0}"
    MOCK_CURL_RESPONSE="$response"
    MOCK_CURL_EXIT="$exit_code"
    MOCK_CURL_LOG="${TEST_TMPDIR}/mock_curl_log.txt"
    : > "$MOCK_CURL_LOG"
    curl() {
        # Extract HTTP method (after -X) and URL (last arg) for validation
        local method="" prev=""
        for arg in "$@"; do
            if [[ "$prev" == "-X" ]]; then
                method="$arg"
            fi
            prev="$arg"
        done
        # Last arg is the URL
        echo "${method}|${prev}" >> "$MOCK_CURL_LOG"
        printf '%s' "$MOCK_CURL_RESPONSE"
        return "$MOCK_CURL_EXIT"
    }
    export -f curl
}

# Mock curl for download: writes content to the -o target file, logs calls
_mock_curl_download() {
    local api_response="$1"
    local file_content="$2"
    MOCK_CURL_API_RESP="$api_response"
    MOCK_CURL_FILE_CONTENT="$file_content"
    MOCK_CURL_LOG="${TEST_TMPDIR}/mock_curl_log.txt"
    : > "$MOCK_CURL_LOG"
    curl() {
        # Extract HTTP method and URL for logging
        local method="" prev="" output_file=""
        local saw_o=false
        for arg in "$@"; do
            if [[ "$prev" == "-X" ]]; then
                method="$arg"
            fi
            if $saw_o && [[ -z "$output_file" ]]; then
                output_file="$arg"
            fi
            if [[ "$arg" == "-o" ]]; then
                saw_o=true
            fi
            prev="$arg"
        done
        echo "${method}|${prev}" >> "$MOCK_CURL_LOG"
        # Download call (has -o flag): write file content
        if [[ -n "$output_file" ]]; then
            printf '%s' "$MOCK_CURL_FILE_CONTENT" > "$output_file"
            return 0
        fi
        # API call
        printf '%s' "$MOCK_CURL_API_RESP"
        return 0
    }
    export -f curl
}

# Assert that a specific mock curl call used the expected HTTP method
# Usage: _assert_mock_method <expected_method> [call_number]
# call_number defaults to 1 (first call)
_assert_mock_method() {
    local expected_method="$1"
    local call_num="${2:-1}"

    if [[ ! -s "$MOCK_CURL_LOG" ]]; then
        echo "No mock curl calls recorded" >&2
        return 1
    fi

    local log_line
    log_line=$(sed -n "${call_num}p" "$MOCK_CURL_LOG")
    local actual_method="${log_line%%|*}"

    assert_equals "$expected_method" "$actual_method" "HTTP method (call #${call_num})"
}

# Assert that a specific mock curl call targeted the expected endpoint
# Usage: _assert_mock_endpoint <expected_endpoint_substring> [call_number]
_assert_mock_endpoint() {
    local expected_endpoint="$1"
    local call_num="${2:-1}"

    if [[ ! -s "$MOCK_CURL_LOG" ]]; then
        echo "No mock curl calls recorded" >&2
        return 1
    fi

    local log_line
    log_line=$(sed -n "${call_num}p" "$MOCK_CURL_LOG")
    local actual_url="${log_line#*|}"

    assert_contains "$expected_endpoint" "$actual_url" "endpoint (call #${call_num})"
}

# ============================================================================
# Sample JSON responses for mocking
# ============================================================================

SAMPLE_UPLOAD_OK='{"Id":"abc123","Name":"test.zip","Result":"ok"}'
SAMPLE_UPLOAD_ERR='{"Result":"error","ErrorMessage":"upload failed"}'
SAMPLE_FILE_LIST='[{"Id":"id1","Name":"CodingAgentConfig_host1_user1_250101-120000.zip","UrlHotlink":"/dl/id1"},{"Id":"id2","Name":"CodingAgentConfig_host2_user2_250102-130000.zip","UrlHotlink":"/dl/id2"},{"Id":"id3","Name":"CodingAgentConfig_host1_user1_250103-140000.zip","UrlHotlink":"/dl/id3"}]'
SAMPLE_EMPTY_LIST='null'

# ============================================================================
# TTL Validation Tests
# ============================================================================

test_ttl_valid_range() {
    CAC_GOKAPI_EXPIRY_DAYS=5
    local stderr_output
    stderr_output=$(_gokapi_validate_ttl 2>&1)
    assert_equals "5" "$CAC_GOKAPI_EXPIRY_DAYS" "TTL value" &&
    assert_equals "" "$stderr_output" "no warning expected"
}

test_ttl_zero_override() {
    CAC_GOKAPI_EXPIRY_DAYS=0
    # Capture stderr to file to avoid subshell (which would lose var changes)
    _gokapi_validate_ttl 2>"${TEST_TMPDIR}/ttl_stderr.txt"
    local stderr_output
    stderr_output=$(cat "${TEST_TMPDIR}/ttl_stderr.txt")
    assert_equals "7" "$CAC_GOKAPI_EXPIRY_DAYS" "TTL capped to max" &&
    assert_contains "overridden" "$stderr_output" "warning message"
}

test_ttl_over_max() {
    CAC_GOKAPI_EXPIRY_DAYS=30
    _gokapi_validate_ttl 2>"${TEST_TMPDIR}/ttl_stderr.txt"
    local stderr_output
    stderr_output=$(cat "${TEST_TMPDIR}/ttl_stderr.txt")
    assert_equals "7" "$CAC_GOKAPI_EXPIRY_DAYS" "TTL capped to 7" &&
    assert_contains "exceeds maximum" "$stderr_output" "warning message"
}

test_ttl_non_numeric() {
    CAC_GOKAPI_EXPIRY_DAYS=abc
    _gokapi_validate_ttl 2>"${TEST_TMPDIR}/ttl_stderr.txt"
    local stderr_output
    stderr_output=$(cat "${TEST_TMPDIR}/ttl_stderr.txt")
    assert_equals "7" "$CAC_GOKAPI_EXPIRY_DAYS" "TTL reset to max" &&
    assert_contains "Invalid" "$stderr_output" "warning message"
}

test_ttl_boundary_seven() {
    CAC_GOKAPI_EXPIRY_DAYS=7
    local stderr_output
    stderr_output=$(_gokapi_validate_ttl 2>&1)
    assert_equals "7" "$CAC_GOKAPI_EXPIRY_DAYS" "TTL stays at 7" &&
    assert_equals "" "$stderr_output" "no warning expected"
}

test_ttl_boundary_one() {
    CAC_GOKAPI_EXPIRY_DAYS=1
    local stderr_output
    stderr_output=$(_gokapi_validate_ttl 2>&1)
    assert_equals "1" "$CAC_GOKAPI_EXPIRY_DAYS" "TTL stays at 1" &&
    assert_equals "" "$stderr_output" "no warning expected"
}

# ============================================================================
# Response Validation Tests
# ============================================================================

test_validate_response_valid() {
    _gokapi_validate_response "some data" "test op" 2>/dev/null
}

test_validate_response_empty() {
    ! _gokapi_validate_response "" "test op" 2>/dev/null
}

test_validate_response_null() {
    ! _gokapi_validate_response "null" "test op" 2>/dev/null
}

# ============================================================================
# Config Validation Tests
# ============================================================================

test_validate_config_both_set() {
    CAC_GOKAPI_URL="https://example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _gokapi_validate_config 2>/dev/null
}

test_validate_config_missing_url() {
    CAC_GOKAPI_URL=""
    CAC_GOKAPI_API_KEY="testkey"
    ! _gokapi_validate_config 2>/dev/null
}

test_validate_config_missing_apikey() {
    CAC_GOKAPI_URL="https://example.com"
    CAC_GOKAPI_API_KEY=""
    ! _gokapi_validate_config 2>/dev/null
}

# ============================================================================
# JSON Utility Tests
# ============================================================================

test_json_extract_field() {
    local result
    result=$(utils_json_extract_field '{"Id":"abc123","Name":"test.zip"}' "Id")
    assert_equals "abc123" "$result" "extracted Id"
}

test_json_extract_field_name() {
    local result
    result=$(utils_json_extract_field '{"Id":"abc123","Name":"test.zip"}' "Name")
    assert_equals "test.zip" "$result" "extracted Name"
}

test_json_extract_field_missing() {
    local result
    result=$(utils_json_extract_field '{"Id":"abc123"}' "Missing")
    assert_equals "" "$result" "missing field"
}

test_json_is_error_true() {
    utils_json_is_error '{"Result":"error","ErrorMessage":"something"}'
}

test_json_is_error_false() {
    ! utils_json_is_error '{"Result":"ok","Id":"abc"}'
}

test_json_check_error_pass() {
    utils_json_check_error '{"Result":"ok","Id":"abc"}' "test" 2>/dev/null
}

test_json_check_error_fail() {
    ! utils_json_check_error '{"Result":"error","ErrorMessage":"bad"}' "test" 2>/dev/null
}

test_json_get_error_message() {
    local result
    result=$(utils_json_get_error '{"Result":"error","ErrorMessage":"something broke"}')
    assert_equals "something broke" "$result" "error message"
}

test_json_get_error_unknown() {
    local result
    result=$(utils_json_get_error '{"Result":"error"}')
    assert_equals "unknown error" "$result" "default error message"
}

# ============================================================================
# Gokapi Name Extraction Tests
# ============================================================================

test_extract_names_from_list() {
    local output
    output=$(utils_gokapi_extract_names "$SAMPLE_FILE_LIST")
    assert_contains "CodingAgentConfig_host1_user1_250101-120000.zip" "$output" "first file" &&
    assert_contains "CodingAgentConfig_host2_user2_250102-130000.zip" "$output" "second file" &&
    assert_contains "CodingAgentConfig_host1_user1_250103-140000.zip" "$output" "third file"
}

test_extract_names_with_ids() {
    local output
    output=$(utils_gokapi_extract_names "$SAMPLE_FILE_LIST")
    # With jq, output includes IDs; with grep, IDs may be empty
    # Either way, format is "name|..." per line
    local line_count
    line_count=$(echo "$output" | wc -l)
    assert_equals "3" "$line_count" "number of entries"
}

# ============================================================================
# Find File Tests
# ============================================================================

test_find_file_by_id() {
    local result
    result=$(utils_gokapi_find_file "$SAMPLE_FILE_LIST" "id2")
    assert_contains "CodingAgentConfig_host2_user2_250102-130000.zip" "$result" "found by ID"
}

test_find_file_by_name() {
    local result
    result=$(utils_gokapi_find_file "$SAMPLE_FILE_LIST" "CodingAgentConfig_host2_user2_250102-130000.zip")
    assert_contains "/dl/id2" "$result" "download URL" &&
    assert_contains "CodingAgentConfig_host2_user2_250102-130000.zip" "$result" "filename"
}

test_find_file_not_found() {
    ! utils_gokapi_find_file "$SAMPLE_FILE_LIST" "nonexistent" 2>/dev/null
}

test_find_file_partial_match() {
    local result
    result=$(utils_gokapi_find_file "$SAMPLE_FILE_LIST" "host2_user2")
    assert_contains "CodingAgentConfig_host2_user2_250102-130000.zip" "$result" "partial match"
}

# ============================================================================
# Find Newest Bundle Tests
# ============================================================================

test_find_newest_bundle() {
    local input
    input=$(printf '%s\n' \
        "CodingAgentConfig_h_u_250101-120000.zip|h|u|250101-120000" \
        "CodingAgentConfig_h_u_250103-140000.zip|h|u|250103-140000" \
        "CodingAgentConfig_h_u_250102-130000.zip|h|u|250102-130000")
    local result
    result=$(echo "$input" | utils_find_newest_bundle)
    assert_equals "CodingAgentConfig_h_u_250103-140000.zip" "$result" "newest bundle"
}

test_find_newest_bundle_empty() {
    ! echo "" | utils_find_newest_bundle
}

# ============================================================================
# Parse Bundle Metadata Tests
# ============================================================================

test_parse_bundle_metadata_valid() {
    local result
    result=$(utils_parse_bundle_metadata "CodingAgentConfig_myhost_bob_250115-100000.zip" "" "")
    assert_contains "myhost" "$result" "host" &&
    assert_contains "bob" "$result" "user" &&
    assert_contains "250115-100000" "$result" "timestamp"
}

test_parse_bundle_metadata_filter_host() {
    # Should pass when filter matches
    utils_parse_bundle_metadata "CodingAgentConfig_myhost_bob_250115-100000.zip" "myhost" "" >/dev/null &&
    # Should fail when filter doesn't match
    ! utils_parse_bundle_metadata "CodingAgentConfig_myhost_bob_250115-100000.zip" "otherhost" "" >/dev/null
}

test_parse_bundle_metadata_filter_user() {
    # Should pass when filter matches
    utils_parse_bundle_metadata "CodingAgentConfig_myhost_bob_250115-100000.zip" "" "bob" >/dev/null &&
    # Should fail when filter doesn't match
    ! utils_parse_bundle_metadata "CodingAgentConfig_myhost_bob_250115-100000.zip" "" "alice" >/dev/null
}

test_parse_bundle_metadata_invalid_name() {
    ! utils_parse_bundle_metadata "random_file.txt" "" "" >/dev/null
}

# ============================================================================
# Mock-based Backend Function Tests: Upload
# ============================================================================

test_upload_success() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl "$SAMPLE_UPLOAD_OK"

    local tmpfile="${TEST_TMPDIR}/upload_test.zip"
    echo "fake zip content" > "$tmpfile"

    local output
    output=$(backend_gokapi_upload "$tmpfile" 2>/dev/null)
    assert_contains "Uploaded:" "$output" "upload confirmation" &&
    _assert_mock_method "POST" &&
    _assert_mock_endpoint "/api/files/add"
}

test_upload_missing_file() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"

    ! backend_gokapi_upload "/nonexistent/file.zip" 2>/dev/null
}

test_upload_api_error() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl "$SAMPLE_UPLOAD_ERR"

    local tmpfile="${TEST_TMPDIR}/upload_err.zip"
    echo "fake zip content" > "$tmpfile"

    ! backend_gokapi_upload "$tmpfile" 2>/dev/null
}

test_upload_missing_config() {
    CAC_GOKAPI_URL=""
    CAC_GOKAPI_API_KEY=""

    ! backend_gokapi_upload "/some/file.zip" 2>/dev/null
}

# ============================================================================
# Mock-based Backend Function Tests: Download
# ============================================================================

test_download_success() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl_download "$SAMPLE_FILE_LIST" "downloaded-bundle-content"

    local outfile="${TEST_TMPDIR}/downloaded.zip"
    local output
    output=$(backend_gokapi_download "id2" "$outfile" 2>/dev/null)
    assert_contains "Downloaded:" "$output" "download confirmation" &&
    assert_file_exists "$outfile" "downloaded file" &&
    _assert_mock_method "GET" 1 &&
    _assert_mock_endpoint "/api/files/list" 1
}

test_download_not_found() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl "$SAMPLE_FILE_LIST"

    local outfile="${TEST_TMPDIR}/notfound.zip"
    ! backend_gokapi_download "nonexistent_id" "$outfile" 2>/dev/null
}

# ============================================================================
# Mock-based Backend Function Tests: List
# ============================================================================

test_list_empty() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl "$SAMPLE_EMPTY_LIST"

    local output
    output=$(backend_gokapi_list 2>/dev/null)
    assert_contains "No bundles found" "$output" "empty list message"
}

test_list_with_bundles() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl "$SAMPLE_FILE_LIST"

    local output
    output=$(backend_gokapi_list 2>/dev/null)
    assert_contains "BUNDLE" "$output" "table header" &&
    assert_contains "host1" "$output" "host1 entry" &&
    assert_contains "host2" "$output" "host2 entry" &&
    assert_contains "Total:" "$output" "footer" &&
    _assert_mock_method "GET" &&
    _assert_mock_endpoint "/api/files/list"
}

test_list_filter_host() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl "$SAMPLE_FILE_LIST"

    local output
    output=$(backend_gokapi_list --host host2 2>/dev/null)
    assert_contains "host2" "$output" "filtered host" &&
    assert_contains "Total: 1" "$output" "single result"
}

test_list_filter_user() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl "$SAMPLE_FILE_LIST"

    local output
    output=$(backend_gokapi_list --user user1 2>/dev/null)
    assert_contains "user1" "$output" "filtered user" &&
    assert_contains "Total: 2" "$output" "two results for user1"
}

# ============================================================================
# Mock-based Backend Function Tests: Get Newest
# ============================================================================

test_get_newest() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl "$SAMPLE_FILE_LIST"

    local output
    output=$(backend_gokapi_get_newest 2>/dev/null)
    # id3 has timestamp 250103-140000, which is the newest
    assert_equals "CodingAgentConfig_host1_user1_250103-140000.zip" "$output" "newest bundle" &&
    _assert_mock_method "GET" &&
    _assert_mock_endpoint "/api/files/list"
}

test_get_newest_filtered() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl "$SAMPLE_FILE_LIST"

    local output
    output=$(backend_gokapi_get_newest --host host2 2>/dev/null)
    assert_equals "CodingAgentConfig_host2_user2_250102-130000.zip" "$output" "newest for host2"
}

test_get_newest_pipefail_regression() {
    # Regression test: non-matching entries AFTER matching entries must not
    # cause get_newest to fail under set -o pipefail
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    # host2 entry is in the middle; host1 entries come AFTER it — the last
    # utils_parse_bundle_metadata call returns 1 (non-match for --host host2)
    local mixed_list='[{"Id":"id2","Name":"CodingAgentConfig_host2_user2_250102-130000.zip","UrlHotlink":"/dl/id2"},{"Id":"id1","Name":"CodingAgentConfig_host1_user1_250101-120000.zip","UrlHotlink":"/dl/id1"},{"Id":"id3","Name":"CodingAgentConfig_host1_user1_250103-140000.zip","UrlHotlink":"/dl/id3"}]'
    _mock_curl "$mixed_list"

    local output
    output=$(backend_gokapi_get_newest --host host2 2>/dev/null)
    assert_equals "CodingAgentConfig_host2_user2_250102-130000.zip" "$output" "newest for host2 despite trailing non-matches"
}

test_get_newest_all_non_matching() {
    # When ALL entries fail the filter, get_newest must return failure
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl "$SAMPLE_FILE_LIST"

    ! backend_gokapi_get_newest --host totally_unknown_host 2>/dev/null
}

test_get_newest_no_match() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    _mock_curl "$SAMPLE_FILE_LIST"

    ! backend_gokapi_get_newest --host nonexistent 2>/dev/null
}

# ============================================================================
# Mock-based Backend Function Tests: Delete
# ============================================================================

test_delete_by_id() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    # _gokapi_try_request requires non-empty response; use a valid JSON
    _mock_curl '{"Result":"ok"}'

    local output
    output=$(backend_gokapi_delete "someid" 2>/dev/null)
    assert_contains "Deleted:" "$output" "delete confirmation" &&
    _assert_mock_method "DELETE" &&
    _assert_mock_endpoint "/api/files/delete"
}

test_delete_by_name() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    MOCK_CURL_LOG="${TEST_TMPDIR}/mock_curl_log.txt"
    : > "$MOCK_CURL_LOG"
    # First call returns file list (GET /api/files/list to look up ID),
    # second returns valid JSON for delete (DELETE /api/files/delete)
    MOCK_DELETE_CALL=0
    curl() {
        MOCK_DELETE_CALL=$((MOCK_DELETE_CALL + 1))
        # Record method and URL
        local method="" prev=""
        for arg in "$@"; do
            if [[ "$prev" == "-X" ]]; then method="$arg"; fi
            prev="$arg"
        done
        echo "${method}|${prev}" >> "$MOCK_CURL_LOG"
        if [[ "$MOCK_DELETE_CALL" -le 1 ]]; then
            printf '%s' "$SAMPLE_FILE_LIST"
        else
            printf '%s' '{"Result":"ok"}'
        fi
        return 0
    }
    export -f curl

    local output
    output=$(backend_gokapi_delete "CodingAgentConfig_host1_user1_250101-120000.zip" 2>/dev/null)
    assert_contains "Deleted:" "$output" "delete by name confirmation" &&
    _assert_mock_method "GET" 1 &&
    _assert_mock_endpoint "/api/files/list" 1 &&
    _assert_mock_method "DELETE" 2 &&
    _assert_mock_endpoint "/api/files/delete" 2
}

# ============================================================================
# Handle Find Result Tests
# ============================================================================

test_handle_find_result_success() {
    utils_handle_find_result 0 "test" 2>/dev/null
}

test_handle_find_result_not_found() {
    ! utils_handle_find_result 1 "test" 2>/dev/null
}

test_handle_find_result_multiple() {
    ! utils_handle_find_result 2 "test" "file1 file2" 2>/dev/null
}

# ============================================================================
# Curl Timeout Tests
# ============================================================================

test_gokapi_request_includes_timeout() {
    CAC_GOKAPI_URL="https://mock.example.com"
    CAC_GOKAPI_API_KEY="testkey"
    # Mock curl to capture all arguments
    local arglog="${TEST_TMPDIR}/curl_args.txt"
    curl() {
        printf '%s\n' "$@" > "$arglog"
        echo '{"ok":true}'
        return 0
    }
    export -f curl

    _gokapi_request GET "/api/files/list" 2>/dev/null
    local args
    args=$(cat "$arglog")
    assert_contains "-m" "$args" "curl timeout flag" &&
    assert_contains "30" "$args" "curl timeout value (30s)"
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "Gokapi Unit Tests"
    echo "========================================"
    echo ""

    framework_init

    echo "--- TTL Validation ---"
    run_test "TTL valid range (5)" test_ttl_valid_range
    run_test "TTL zero override" test_ttl_zero_override
    run_test "TTL over max (30)" test_ttl_over_max
    run_test "TTL non-numeric" test_ttl_non_numeric
    run_test "TTL boundary (7)" test_ttl_boundary_seven
    run_test "TTL boundary (1)" test_ttl_boundary_one
    echo ""

    echo "--- Response Validation ---"
    run_test "validate_response valid" test_validate_response_valid
    run_test "validate_response empty" test_validate_response_empty
    run_test "validate_response null" test_validate_response_null
    echo ""

    echo "--- Config Validation ---"
    run_test "validate_config both set" test_validate_config_both_set
    run_test "validate_config missing URL" test_validate_config_missing_url
    run_test "validate_config missing API key" test_validate_config_missing_apikey
    echo ""

    echo "--- JSON Utilities ---"
    run_test "json_extract_field Id" test_json_extract_field
    run_test "json_extract_field Name" test_json_extract_field_name
    run_test "json_extract_field missing" test_json_extract_field_missing
    run_test "json_is_error true" test_json_is_error_true
    run_test "json_is_error false" test_json_is_error_false
    run_test "json_check_error pass" test_json_check_error_pass
    run_test "json_check_error fail" test_json_check_error_fail
    run_test "json_get_error message" test_json_get_error_message
    run_test "json_get_error unknown" test_json_get_error_unknown
    echo ""

    echo "--- Name Extraction ---"
    run_test "extract_names from list" test_extract_names_from_list
    run_test "extract_names with IDs" test_extract_names_with_ids
    echo ""

    echo "--- Find File ---"
    run_test "find_file by ID" test_find_file_by_id
    run_test "find_file by name" test_find_file_by_name
    run_test "find_file not found" test_find_file_not_found
    run_test "find_file partial match" test_find_file_partial_match
    echo ""

    echo "--- Find Newest Bundle ---"
    run_test "find_newest_bundle" test_find_newest_bundle
    run_test "find_newest_bundle empty" test_find_newest_bundle_empty
    echo ""

    echo "--- Parse Bundle Metadata ---"
    run_test "parse_bundle_metadata valid" test_parse_bundle_metadata_valid
    run_test "parse_bundle_metadata filter host" test_parse_bundle_metadata_filter_host
    run_test "parse_bundle_metadata filter user" test_parse_bundle_metadata_filter_user
    run_test "parse_bundle_metadata invalid name" test_parse_bundle_metadata_invalid_name
    echo ""

    echo "--- Handle Find Result ---"
    run_test "handle_find_result success" test_handle_find_result_success
    run_test "handle_find_result not found" test_handle_find_result_not_found
    run_test "handle_find_result multiple" test_handle_find_result_multiple
    echo ""

    echo "--- Backend Upload (mocked) ---"
    run_test "upload success" test_upload_success
    run_test "upload missing file" test_upload_missing_file
    run_test "upload API error" test_upload_api_error
    run_test "upload missing config" test_upload_missing_config
    echo ""

    echo "--- Backend Download (mocked) ---"
    run_test "download success" test_download_success
    run_test "download not found" test_download_not_found
    echo ""

    echo "--- Backend List (mocked) ---"
    run_test "list empty" test_list_empty
    run_test "list with bundles" test_list_with_bundles
    run_test "list filter host" test_list_filter_host
    run_test "list filter user" test_list_filter_user
    echo ""

    echo "--- Backend Get Newest (mocked) ---"
    run_test "get_newest" test_get_newest
    run_test "get_newest filtered" test_get_newest_filtered
    run_test "get_newest pipefail regression" test_get_newest_pipefail_regression
    run_test "get_newest all non-matching" test_get_newest_all_non_matching
    run_test "get_newest no match" test_get_newest_no_match
    echo ""

    echo "--- Backend Delete (mocked) ---"
    run_test "delete by ID" test_delete_by_id
    run_test "delete by name" test_delete_by_name
    echo ""

    echo "--- Curl Timeout ---"
    run_test "gokapi_request includes timeout" test_gokapi_request_includes_timeout
    echo ""

    framework_report
    exit $?
}

main "$@"
