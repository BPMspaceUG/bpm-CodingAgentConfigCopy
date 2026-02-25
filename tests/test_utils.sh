#!/usr/bin/env bash
# tests/test_utils.sh - Utils module tests
#
# Run with: ./tests/test_utils.sh
# Or run all tests: ./tests/run_tests.sh
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source shared test framework
source "${SCRIPT_DIR}/test_framework.sh"

# Source library modules
source "${PROJECT_ROOT}/lib/logging.sh"
source "${PROJECT_ROOT}/lib/security.sh"
source "${PROJECT_ROOT}/lib/bundle.sh"
source "${PROJECT_ROOT}/lib/utils.sh"

# ============================================================================
# Argument Parsing Tests
# ============================================================================

test_parse_user_arg_with_user() {
    utils_parse_user_arg --user testuser
    assert_equals "testuser" "$PARSED_USER" "PARSED_USER"
}

test_parse_user_arg_no_user() {
    utils_parse_user_arg
    assert_equals "" "$PARSED_USER" "PARSED_USER should be empty"
}

test_parse_user_arg_strict_unknown() {
    assert_fails "unknown option in strict mode" utils_parse_user_arg --strict --unknown-option
}

test_parse_user_arg_nonstrict_unknown() {
    assert_success "unknown option in non-strict mode" utils_parse_user_arg --unknown-option
}

test_parse_user_arg_missing_value() {
    assert_fails "--user missing value" utils_parse_user_arg --user
}

# ============================================================================
# Variable Requirement Tests
# ============================================================================

test_require_var_set() {
    # shellcheck disable=SC2034  # TEST_VAR is used via indirect expansion
    local TEST_VAR="some_value"
    assert_success "require_var with set variable" utils_require_var TEST_VAR
}

test_require_var_empty() {
    # shellcheck disable=SC2034  # TEST_VAR is used via indirect expansion
    local TEST_VAR=""
    assert_fails "require_var with empty variable" utils_require_var TEST_VAR
}

test_require_var_unset() {
    unset TEST_VAR 2>/dev/null || true
    assert_fails "require_var with unset variable" utils_require_var TEST_VAR
}

test_require_var_custom_message() {
    # shellcheck disable=SC2034  # TEST_VAR is used via indirect expansion
    local TEST_VAR=""
    local error_output
    error_output=$(utils_require_var TEST_VAR "Custom error message" 2>&1) || true
    assert_contains "Custom error message" "$error_output" "custom message in error output"
}

test_require_var_default_message() {
    # shellcheck disable=SC2034  # TEST_VAR is used via indirect expansion
    local TEST_VAR=""
    local error_output
    error_output=$(utils_require_var TEST_VAR 2>&1) || true
    assert_contains "TEST_VAR not configured" "$error_output" "default message contains var name"
}

# ============================================================================
# Command Args Parsing Tests (with --dry-run support)
# ============================================================================

test_parse_command_args_user_only() {
    utils_parse_command_args --user testuser
    assert_equals "testuser" "$PARSED_USER" "PARSED_USER" &&
    assert_equals "false" "$PARSED_DRY_RUN" "PARSED_DRY_RUN"
}

test_parse_command_args_dry_run_only() {
    utils_parse_command_args --dry-run
    assert_equals "" "$PARSED_USER" "PARSED_USER should be empty" &&
    assert_equals "true" "$PARSED_DRY_RUN" "PARSED_DRY_RUN"
}

test_parse_command_args_both() {
    utils_parse_command_args --user myuser --dry-run
    assert_equals "myuser" "$PARSED_USER" "PARSED_USER" &&
    assert_equals "true" "$PARSED_DRY_RUN" "PARSED_DRY_RUN"
}

test_parse_command_args_reversed_order() {
    utils_parse_command_args --dry-run --user anotheruser
    assert_equals "anotheruser" "$PARSED_USER" "PARSED_USER" &&
    assert_equals "true" "$PARSED_DRY_RUN" "PARSED_DRY_RUN"
}

test_parse_command_args_strict_unknown() {
    assert_fails "unknown option in strict mode" utils_parse_command_args --strict --unknown-option
}

# ============================================================================
# Command Context Initialization Tests
# ============================================================================

test_init_command_context_current_user() {
    utils_init_command_context
    assert_equals "$USER" "$PARSED_TARGET_USER" "PARSED_TARGET_USER defaults to current user" &&
    assert_equals "false" "$PARSED_DRY_RUN" "PARSED_DRY_RUN defaults to false" &&
    [[ -n "$PARSED_HOME_DIR" ]] || { echo "PARSED_HOME_DIR should be set" >&2; return 1; }
}

test_init_command_context_with_options() {
    utils_init_command_context --user "$USER" --dry-run
    assert_equals "$USER" "$PARSED_TARGET_USER" "PARSED_TARGET_USER" &&
    assert_equals "true" "$PARSED_DRY_RUN" "PARSED_DRY_RUN should be true"
}

test_init_command_context_strict_unknown() {
    assert_fails "strict mode rejects unknown options" utils_init_command_context --strict --unknown-option
}

test_init_command_context_nonstrict_unknown() {
    assert_success "non-strict mode ignores unknown options" utils_init_command_context --unknown-option
}

test_init_command_context_invalid_user() {
    assert_fails "invalid user is rejected" utils_init_command_context --user nonexistent_user_xyz123
}

# ============================================================================
# Filter Args Tests
# ============================================================================

test_parse_filter_args_both() {
    utils_parse_filter_args --tool claude --user myuser
    assert_equals "claude" "$FILTER_TOOL" "FILTER_TOOL" &&
    assert_equals "myuser" "$FILTER_USER" "FILTER_USER"
}

test_parse_filter_args_tool_only() {
    utils_parse_filter_args --tool codex
    assert_equals "codex" "$FILTER_TOOL" "FILTER_TOOL" &&
    assert_equals "" "$FILTER_USER" "FILTER_USER should be empty"
}

test_parse_filter_args_empty() {
    utils_parse_filter_args
    assert_equals "" "$FILTER_TOOL" "FILTER_TOOL should be empty" &&
    assert_equals "" "$FILTER_USER" "FILTER_USER should be empty"
}

# ============================================================================
# Filter Description Tests
# ============================================================================

test_build_filter_description_both() {
    local desc
    desc=$(utils_build_filter_description "claude" "myuser")
    assert_equals "tool=claude, user=myuser" "$desc" "both filters"
}

test_build_filter_description_tool_only() {
    local desc
    desc=$(utils_build_filter_description "codex" "")
    assert_equals "tool=codex" "$desc" "tool only"
}

test_build_filter_description_user_only() {
    local desc
    desc=$(utils_build_filter_description "" "myuser")
    assert_equals "user=myuser" "$desc" "user only"
}

test_build_filter_description_empty() {
    local desc
    desc=$(utils_build_filter_description "" "")
    assert_equals "" "$desc" "no filters"
}

test_error_no_bundle_found_with_filters() {
    local output
    output=$(utils_error_no_bundle_found "claude" "myuser" "in storage" 2>&1)
    [[ "$output" == *"No bundle found matching: tool=claude, user=myuser"* ]] || return 1
}

test_error_no_bundle_found_no_filters() {
    local output
    output=$(utils_error_no_bundle_found "" "" "on server" 2>&1)
    [[ "$output" == *"No bundles found on server"* ]] || return 1
}

test_error_no_bundle_found_tool_only() {
    local output
    output=$(utils_error_no_bundle_found "codex" "" "in storage" 2>&1)
    [[ "$output" == *"No bundle found matching: tool=codex"* ]] || return 1
}

# ============================================================================
# JSON Parsing Tests
# ============================================================================

test_json_extract_field() {
    local json='{"Name":"test.zip","Id":"abc123","Size":1024}'
    local name
    name=$(utils_json_extract_field "$json" "Name")
    assert_equals "test.zip" "$name" "Name field"
}

test_json_extract_field_id() {
    local json='{"Name":"test.zip","Id":"abc123","Size":1024}'
    local id
    id=$(utils_json_extract_field "$json" "Id")
    assert_equals "abc123" "$id" "Id field"
}

test_json_extract_field_missing() {
    local json='{"Name":"test.zip"}'
    local result
    result=$(utils_json_extract_field "$json" "NonExistent")
    assert_equals "" "$result" "missing field should be empty"
}

test_json_is_error_true() {
    local json='{"Result":"error","ErrorMessage":"Something went wrong"}'
    assert_success "is_error detection" utils_json_is_error "$json"
}

test_json_is_error_false() {
    local json='{"Result":"ok","Id":"abc123"}'
    assert_fails "non-error should not trigger is_error" utils_json_is_error "$json"
}

test_json_get_error() {
    local json='{"Result":"error","ErrorMessage":"File not found"}'
    local msg
    msg=$(utils_json_get_error "$json")
    assert_equals "File not found" "$msg" "error message"
}

test_json_get_error_missing() {
    local json='{"Result":"error"}'
    local msg
    msg=$(utils_json_get_error "$json")
    assert_equals "unknown error" "$msg" "default error message"
}

# ============================================================================
# Bundle Metadata Parsing Tests
# ============================================================================

test_parse_bundle_metadata_valid_old_format() {
    local result
    result=$(utils_parse_bundle_metadata "CodingAgentConfig_myhost_alice_250111-120000.zip" "" "")
    assert_equals "CodingAgentConfig_myhost_alice_250111-120000.zip|myhost|alice|all|250111-120000" "$result" "parsed metadata (old format, tool=all)"
}

test_parse_bundle_metadata_valid_new_format() {
    local result
    result=$(utils_parse_bundle_metadata "CodingAgentConfig_myhost_alice_claude_250111-120000.zip" "" "")
    assert_equals "CodingAgentConfig_myhost_alice_claude_250111-120000.zip|myhost|alice|claude|250111-120000" "$result" "parsed metadata (new format)"
}

test_parse_bundle_metadata_invalid() {
    assert_fails "non-bundle file parsing" utils_parse_bundle_metadata "random_file.zip" "" ""
}

test_parse_bundle_metadata_filter_tool() {
    assert_success "matching tool filter" utils_parse_bundle_metadata "CodingAgentConfig_myhost_alice_claude_250111-120000.zip" "claude" "" &&
    assert_fails "non-matching tool filter" utils_parse_bundle_metadata "CodingAgentConfig_myhost_alice_claude_250111-120000.zip" "codex" ""
}

test_parse_bundle_metadata_filter_tool_old_format() {
    # Old format bundles have tool="all", so filtering by "all" should match
    assert_success "old format matches tool=all" utils_parse_bundle_metadata "CodingAgentConfig_myhost_alice_250111-120000.zip" "all" "" &&
    assert_fails "old format does not match specific tool" utils_parse_bundle_metadata "CodingAgentConfig_myhost_alice_250111-120000.zip" "claude" ""
}

test_parse_bundle_metadata_filter_user() {
    assert_success "matching user filter" utils_parse_bundle_metadata "CodingAgentConfig_myhost_alice_claude_250111-120000.zip" "" "alice" &&
    assert_fails "non-matching user filter" utils_parse_bundle_metadata "CodingAgentConfig_myhost_alice_claude_250111-120000.zip" "" "bob"
}

test_parse_bundle_metadata_filter_both() {
    assert_success "matching both filters" utils_parse_bundle_metadata "CodingAgentConfig_myhost_alice_claude_250111-120000.zip" "claude" "alice" &&
    assert_fails "non-matching user with matching tool" utils_parse_bundle_metadata "CodingAgentConfig_myhost_alice_claude_250111-120000.zip" "claude" "bob"
}

# ============================================================================
# Bundle Finding Tests
# ============================================================================

test_find_newest_bundle_single() {
    local result
    result=$(echo "CodingAgentConfig_host_user_claude_250111-120000.zip|host|user|claude|250111-120000" | utils_find_newest_bundle)
    assert_equals "CodingAgentConfig_host_user_claude_250111-120000.zip" "$result" "single bundle"
}

test_find_newest_bundle_multiple() {
    local input
    input=$(cat <<'EOF'
CodingAgentConfig_host_user_claude_250111-100000.zip|host|user|claude|250111-100000
CodingAgentConfig_host_user_claude_250111-130000.zip|host|user|claude|250111-130000
CodingAgentConfig_host_user_claude_250111-120000.zip|host|user|claude|250111-120000
EOF
)
    local result
    result=$(echo "$input" | utils_find_newest_bundle)
    assert_equals "CodingAgentConfig_host_user_claude_250111-130000.zip" "$result" "newest bundle"
}

test_find_newest_bundle_empty() {
    # Pipe empty string to utils_find_newest_bundle - use subshell to test exit code
    ! (echo "" | utils_find_newest_bundle) >/dev/null 2>&1
}

# ============================================================================
# File Operation Tests
# ============================================================================

test_safe_copy() {
    local src="${TEST_TMPDIR}/source.txt"
    local dst="${TEST_TMPDIR}/dest.txt"

    echo "test content" > "$src"
    assert_success "safe_copy operation" utils_safe_copy "$src" "$dst" &&
    assert_file_exists "$dst" "destination file" &&
    assert_equals "test content" "$(cat "$dst")" "copied content"
}

test_safe_copy_missing_source() {
    assert_fails "copy from missing source" utils_safe_copy "/nonexistent/file" "${TEST_TMPDIR}/dst"
}

test_safe_chmod() {
    local testfile="${TEST_TMPDIR}/chmod_test.txt"
    echo "test" > "$testfile"
    chmod 644 "$testfile"

    assert_success "safe_chmod operation" utils_safe_chmod 600 "$testfile" &&
    assert_equals "600" "$(security_get_file_perms "$testfile")" "file permissions"
}

# ============================================================================
# Regex Escaping Tests
# ============================================================================

test_escape_regex_plain_string() {
    local result
    result=$(utils_escape_regex "simple")
    assert_equals "simple" "$result" "plain string unchanged"
}

test_escape_regex_with_dots() {
    local result
    result=$(utils_escape_regex "file.name.zip")
    assert_equals "file\\.name\\.zip" "$result" "dots escaped"
}

test_escape_regex_with_asterisk() {
    local result
    result=$(utils_escape_regex "*.zip")
    assert_equals "\\*\\.zip" "$result" "asterisk and dot escaped"
}

test_escape_regex_with_brackets() {
    local result
    result=$(utils_escape_regex "[abc]")
    # Only opening bracket needs escaping in grep patterns
    assert_equals "\\[abc]" "$result" "opening bracket escaped"
}

test_escape_regex_with_caret_dollar() {
    local result
    result=$(utils_escape_regex '^start$end')
    assert_equals '\^start\$end' "$result" "caret and dollar escaped"
}

test_escape_regex_with_parens() {
    local result
    result=$(utils_escape_regex "(group)")
    assert_equals "\\(group\\)" "$result" "parentheses escaped"
}

test_escape_regex_bundle_name() {
    # Realistic bundle name with dots that need escaping
    local result
    result=$(utils_escape_regex "CodingAgentConfig_host_user_250111-120000.zip")
    assert_equals "CodingAgentConfig_host_user_250111-120000\\.zip" "$result" "bundle name dot escaped"
}

# ============================================================================
# Find Result Handling Tests
# ============================================================================

test_handle_find_result_success() {
    assert_success "exit code 0" utils_handle_find_result 0 "test_id"
}

test_handle_find_result_not_found() {
    local output
    output=$(utils_handle_find_result 1 "test_id" 2>&1) || true
    assert_contains "No bundle found matching: test_id" "$output" "not found error message"
}

test_handle_find_result_multiple_matches() {
    local output
    output=$(utils_handle_find_result 2 "partial" "bundle1.zip
bundle2.zip" 2>&1) || true
    assert_contains "Multiple bundles match" "$output" "multiple match error" &&
    assert_contains "bundle1.zip" "$output" "first match listed" &&
    assert_contains "bundle2.zip" "$output" "second match listed"
}

test_handle_find_result_multiple_no_output() {
    # When exit code is 2 but no match_output provided (error already printed by caller)
    local exit_code=0
    utils_handle_find_result 2 "test_id" "" 2>/dev/null || exit_code=$?
    [[ $exit_code -eq 1 ]] || { echo "Expected exit code 1, got $exit_code" >&2; return 1; }
}

test_handle_find_result_unexpected_code() {
    local output
    output=$(utils_handle_find_result 99 "test_id" 2>&1) || true
    assert_contains "Unexpected find error" "$output" "unexpected code error message"
}

# ============================================================================
# Gokapi Extract Names Tests
# ============================================================================

test_gokapi_extract_names() {
    local response='[{"Name":"CodingAgentConfig_host1_user1_250111-120000.zip","Id":"abc123"},{"Name":"CodingAgentConfig_host2_user2_250111-130000.zip","Id":"def456"}]'

    local names
    names=$(utils_gokapi_extract_names "$response")
    assert_contains "CodingAgentConfig_host1_user1_250111-120000.zip" "$names" "first bundle" &&
    assert_contains "CodingAgentConfig_host2_user2_250111-130000.zip" "$names" "second bundle"
}

# ============================================================================
# Retry Logic Tests
# ============================================================================

# Counter for retry tests (file-based to work across subshells)
_RETRY_TEST_COUNTER_FILE=""

_retry_test_init_counter() {
    _RETRY_TEST_COUNTER_FILE="${TEST_TMPDIR}/retry_counter"
    echo "0" > "$_RETRY_TEST_COUNTER_FILE"
}

_retry_test_increment() {
    local count
    count=$(cat "$_RETRY_TEST_COUNTER_FILE")
    echo "$((count + 1))" > "$_RETRY_TEST_COUNTER_FILE"
}

_retry_test_get_count() {
    cat "$_RETRY_TEST_COUNTER_FILE"
}

# Helper: always succeeds
_retry_helper_success() {
    _retry_test_increment
    return 0
}

# Helper: fails N times, then succeeds
_retry_helper_fail_then_succeed() {
    local fail_count="$1"
    _retry_test_increment
    local current
    current=$(_retry_test_get_count)
    if [[ "$current" -le "$fail_count" ]]; then
        return 1
    fi
    return 0
}

# Helper: always fails
_retry_helper_always_fail() {
    _retry_test_increment
    return 1
}

# Helper: returns sum of arguments (for testing argument passing)
_retry_helper_with_args() {
    local arg1="$1"
    local arg2="$2"
    _retry_test_increment
    echo "$((arg1 + arg2))"
    return 0
}

test_retry_succeeds_immediately() {
    _retry_test_init_counter

    # Should succeed on first try
    utils_retry 3 0 "test" _retry_helper_success 2>/dev/null || return 1

    local count
    count=$(_retry_test_get_count)
    assert_equals "1" "$count" "attempt count"
}

test_retry_succeeds_after_failures() {
    _retry_test_init_counter

    # Fail twice, succeed on third attempt
    utils_retry 5 0 "test" _retry_helper_fail_then_succeed 2 2>/dev/null || return 1

    local count
    count=$(_retry_test_get_count)
    assert_equals "3" "$count" "attempt count (2 failures + 1 success)"
}

test_retry_exhausted() {
    _retry_test_init_counter

    # Should exhaust all retries and fail
    local exit_code=0
    utils_retry 3 0 "test" _retry_helper_always_fail 2>/dev/null || exit_code=$?

    [[ "$exit_code" -ne 0 ]] || { echo "Expected non-zero exit code" >&2; return 1; }

    local count
    count=$(_retry_test_get_count)
    assert_equals "3" "$count" "attempt count (all 3 attempts)"
}

test_retry_passes_arguments() {
    _retry_test_init_counter

    local result
    result=$(utils_retry 3 0 "test" _retry_helper_with_args 5 7 2>/dev/null)
    assert_equals "12" "$result" "sum of arguments (5 + 7)"
}

# ============================================================================
# JSON Check Error Tests
# ============================================================================

test_json_check_error_no_error() {
    local response='{"Id":"abc123","Name":"test.zip"}'

    # Should return success (0) when no error
    utils_json_check_error "$response" "test operation" 2>/dev/null
}

test_json_check_error_with_error() {
    local response='{"Result":"error","ErrorMessage":"Something went wrong"}'

    local output exit_code=0
    output=$(utils_json_check_error "$response" "test operation" 2>&1) || exit_code=$?

    [[ "$exit_code" -ne 0 ]] || { echo "Expected non-zero exit code for error response" >&2; return 1; }
    assert_contains "Something went wrong" "$output" "error message"
}

# ============================================================================
# Bundle List Formatting Tests
# ============================================================================

test_print_bundle_list_header() {
    local output
    output=$(utils_print_bundle_list_header)

    # Header should contain column names
    assert_contains "BUNDLE" "$output" "BUNDLE column" &&
    assert_contains "HOST" "$output" "HOST column" &&
    assert_contains "USER" "$output" "USER column" &&
    assert_contains "TOOL" "$output" "TOOL column" &&
    assert_contains "TIMESTAMP" "$output" "TIMESTAMP column"
}

test_print_bundle_list_entry() {
    local output
    output=$(utils_print_bundle_list_entry "test_bundle.zip" "myhost" "alice" "claude" "250111-120000")

    # Entry should contain all provided values
    assert_contains "test_bundle.zip" "$output" "bundle name" &&
    assert_contains "myhost" "$output" "host" &&
    assert_contains "alice" "$output" "user" &&
    assert_contains "claude" "$output" "tool" &&
    assert_contains "250111-120000" "$output" "timestamp"
}

test_print_bundle_list_footer() {
    local output
    output=$(utils_print_bundle_list_footer 5)

    # Footer should show count
    assert_contains "5" "$output" "count" &&
    assert_contains "bundle" "$output" "bundle label"
}

# ============================================================================
# Gokapi Find File Tests
# ============================================================================

# Sample Gokapi JSON response for testing
_GOKAPI_TEST_RESPONSE='[
  {"Id":"abc123","Name":"CodingAgentConfig_host1_alice_250111-120000.zip","UrlDownload":"http://example.com/d/abc123","UrlHotlink":"http://example.com/dl/abc123"},
  {"Id":"def456","Name":"CodingAgentConfig_host2_bob_250111-130000.zip","UrlDownload":"http://example.com/d/def456","UrlHotlink":"http://example.com/dl/def456"},
  {"Id":"ghi789","Name":"other_bundle.zip","UrlDownload":"http://example.com/d/ghi789","UrlHotlink":"http://example.com/dl/ghi789"}
]'

test_gokapi_find_file_by_id() {
    local result
    result=$(utils_gokapi_find_file "$_GOKAPI_TEST_RESPONSE" "abc123")
    assert_equals "http://example.com/dl/abc123|CodingAgentConfig_host1_alice_250111-120000.zip" "$result" "find by ID"
}

test_gokapi_find_file_by_exact_name() {
    local result
    result=$(utils_gokapi_find_file "$_GOKAPI_TEST_RESPONSE" "other_bundle.zip")
    assert_equals "http://example.com/dl/ghi789|other_bundle.zip" "$result" "find by exact name"
}

test_gokapi_find_file_by_partial_name() {
    local result
    result=$(utils_gokapi_find_file "$_GOKAPI_TEST_RESPONSE" "host1_alice")
    assert_equals "http://example.com/dl/abc123|CodingAgentConfig_host1_alice_250111-120000.zip" "$result" "find by partial name"
}

test_gokapi_find_file_not_found() {
    local exit_code=0
    utils_gokapi_find_file "$_GOKAPI_TEST_RESPONSE" "nonexistent" >/dev/null 2>&1 || exit_code=$?
    [[ "$exit_code" -eq 1 ]] || { echo "Expected exit code 1 (not found), got $exit_code" >&2; return 1; }
}

test_gokapi_find_file_multiple_matches() {
    # "CodingAgentConfig" appears in multiple entries
    local exit_code=0
    utils_gokapi_find_file "$_GOKAPI_TEST_RESPONSE" "CodingAgentConfig" >/dev/null 2>&1 || exit_code=$?
    [[ "$exit_code" -eq 2 ]] || { echo "Expected exit code 2 (multiple matches), got $exit_code" >&2; return 1; }
}

# ============================================================================
# Gokapi Find ID Tests
# ============================================================================

test_gokapi_find_id_success() {
    local result
    result=$(utils_gokapi_find_id "$_GOKAPI_TEST_RESPONSE" "CodingAgentConfig_host1_alice_250111-120000.zip")
    assert_equals "abc123" "$result" "find ID by filename"
}

test_gokapi_find_id_second_entry() {
    local result
    result=$(utils_gokapi_find_id "$_GOKAPI_TEST_RESPONSE" "CodingAgentConfig_host2_bob_250111-130000.zip")
    assert_equals "def456" "$result" "find ID of second entry"
}

test_gokapi_find_id_not_found() {
    local result
    result=$(utils_gokapi_find_id "$_GOKAPI_TEST_RESPONSE" "nonexistent.zip")
    assert_equals "" "$result" "nonexistent filename returns empty"
}

# ============================================================================
# Internal Field Extraction Tests
# ============================================================================

test_gokapi_extract_field_for_name() {
    local result
    result=$(_gokapi_extract_field_for_name "$_GOKAPI_TEST_RESPONSE" "other_bundle.zip" "UrlDownload")
    assert_equals "http://example.com/d/ghi789" "$result" "extract URL for name"
}

test_gokapi_extract_field_for_name_id() {
    local result
    result=$(_gokapi_extract_field_for_name "$_GOKAPI_TEST_RESPONSE" "other_bundle.zip" "Id")
    assert_equals "ghi789" "$result" "extract ID for name"
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "Utils Module Tests"
    echo "========================================"
    echo ""

    framework_init

    echo "--- Argument Parsing ---"
    run_test "parse_user_arg with --user" test_parse_user_arg_with_user
    run_test "parse_user_arg without --user" test_parse_user_arg_no_user
    run_test "parse_user_arg strict unknown option" test_parse_user_arg_strict_unknown
    run_test "parse_user_arg non-strict unknown option" test_parse_user_arg_nonstrict_unknown
    run_test "parse_user_arg missing value" test_parse_user_arg_missing_value
    echo ""

    echo "--- Variable Requirement ---"
    run_test "require_var with set variable" test_require_var_set
    run_test "require_var with empty variable" test_require_var_empty
    run_test "require_var with unset variable" test_require_var_unset
    run_test "require_var custom message" test_require_var_custom_message
    run_test "require_var default message" test_require_var_default_message
    echo ""

    echo "--- Command Args Parsing (--dry-run) ---"
    run_test "parse_command_args user only" test_parse_command_args_user_only
    run_test "parse_command_args dry-run only" test_parse_command_args_dry_run_only
    run_test "parse_command_args both" test_parse_command_args_both
    run_test "parse_command_args reversed order" test_parse_command_args_reversed_order
    run_test "parse_command_args strict unknown" test_parse_command_args_strict_unknown
    echo ""

    echo "--- Command Context Initialization ---"
    run_test "init_command_context current user" test_init_command_context_current_user
    run_test "init_command_context with options" test_init_command_context_with_options
    run_test "init_command_context strict unknown" test_init_command_context_strict_unknown
    run_test "init_command_context nonstrict unknown" test_init_command_context_nonstrict_unknown
    run_test "init_command_context invalid user" test_init_command_context_invalid_user
    echo ""

    echo "--- Filter Args Parsing ---"
    run_test "parse_filter_args both" test_parse_filter_args_both
    run_test "parse_filter_args tool only" test_parse_filter_args_tool_only
    run_test "parse_filter_args empty" test_parse_filter_args_empty
    echo ""

    echo "--- Filter Description Building ---"
    run_test "build_filter_description both" test_build_filter_description_both
    run_test "build_filter_description tool only" test_build_filter_description_tool_only
    run_test "build_filter_description user only" test_build_filter_description_user_only
    run_test "build_filter_description empty" test_build_filter_description_empty
    run_test "error_no_bundle_found with filters" test_error_no_bundle_found_with_filters
    run_test "error_no_bundle_found no filters" test_error_no_bundle_found_no_filters
    run_test "error_no_bundle_found tool only" test_error_no_bundle_found_tool_only
    echo ""

    echo "--- JSON Parsing ---"
    run_test "json_extract_field name" test_json_extract_field
    run_test "json_extract_field id" test_json_extract_field_id
    run_test "json_extract_field missing" test_json_extract_field_missing
    run_test "json_is_error true" test_json_is_error_true
    run_test "json_is_error false" test_json_is_error_false
    run_test "json_get_error" test_json_get_error
    run_test "json_get_error missing" test_json_get_error_missing
    echo ""

    echo "--- Bundle Metadata Parsing ---"
    run_test "parse_bundle_metadata valid (old format)" test_parse_bundle_metadata_valid_old_format
    run_test "parse_bundle_metadata valid (new format)" test_parse_bundle_metadata_valid_new_format
    run_test "parse_bundle_metadata invalid" test_parse_bundle_metadata_invalid
    run_test "parse_bundle_metadata filter tool" test_parse_bundle_metadata_filter_tool
    run_test "parse_bundle_metadata filter tool (old format)" test_parse_bundle_metadata_filter_tool_old_format
    run_test "parse_bundle_metadata filter user" test_parse_bundle_metadata_filter_user
    run_test "parse_bundle_metadata filter both" test_parse_bundle_metadata_filter_both
    echo ""

    echo "--- Bundle Finding ---"
    run_test "find_newest_bundle single" test_find_newest_bundle_single
    run_test "find_newest_bundle multiple" test_find_newest_bundle_multiple
    run_test "find_newest_bundle empty" test_find_newest_bundle_empty
    echo ""

    echo "--- File Operations ---"
    run_test "safe_copy" test_safe_copy
    run_test "safe_copy missing source" test_safe_copy_missing_source
    run_test "safe_chmod" test_safe_chmod
    echo ""

    echo "--- Regex Escaping ---"
    run_test "escape_regex plain string" test_escape_regex_plain_string
    run_test "escape_regex with dots" test_escape_regex_with_dots
    run_test "escape_regex with asterisk" test_escape_regex_with_asterisk
    run_test "escape_regex with brackets" test_escape_regex_with_brackets
    run_test "escape_regex with caret/dollar" test_escape_regex_with_caret_dollar
    run_test "escape_regex with parens" test_escape_regex_with_parens
    run_test "escape_regex bundle name" test_escape_regex_bundle_name
    echo ""

    echo "--- Find Result Handling ---"
    run_test "handle_find_result success" test_handle_find_result_success
    run_test "handle_find_result not found" test_handle_find_result_not_found
    run_test "handle_find_result multiple matches" test_handle_find_result_multiple_matches
    run_test "handle_find_result multiple no output" test_handle_find_result_multiple_no_output
    run_test "handle_find_result unexpected code" test_handle_find_result_unexpected_code
    echo ""

    echo "--- Gokapi Utilities ---"
    run_test "gokapi_extract_names" test_gokapi_extract_names
    run_test "gokapi_find_file by ID" test_gokapi_find_file_by_id
    run_test "gokapi_find_file by exact name" test_gokapi_find_file_by_exact_name
    run_test "gokapi_find_file by partial name" test_gokapi_find_file_by_partial_name
    run_test "gokapi_find_file not found" test_gokapi_find_file_not_found
    run_test "gokapi_find_file multiple matches" test_gokapi_find_file_multiple_matches
    run_test "gokapi_find_id success" test_gokapi_find_id_success
    run_test "gokapi_find_id second entry" test_gokapi_find_id_second_entry
    run_test "gokapi_find_id not found" test_gokapi_find_id_not_found
    run_test "gokapi_extract_field for URL" test_gokapi_extract_field_for_name
    run_test "gokapi_extract_field for ID" test_gokapi_extract_field_for_name_id
    echo ""

    echo "--- Retry Logic ---"
    run_test "retry succeeds immediately" test_retry_succeeds_immediately
    run_test "retry succeeds after failures" test_retry_succeeds_after_failures
    run_test "retry exhausted" test_retry_exhausted
    run_test "retry passes arguments" test_retry_passes_arguments
    echo ""

    echo "--- JSON Check Error ---"
    run_test "json_check_error no error" test_json_check_error_no_error
    run_test "json_check_error with error" test_json_check_error_with_error
    echo ""

    echo "--- Bundle List Formatting ---"
    run_test "print_bundle_list_header format" test_print_bundle_list_header
    run_test "print_bundle_list_entry format" test_print_bundle_list_entry
    run_test "print_bundle_list_footer format" test_print_bundle_list_footer
    echo ""

    framework_report
    exit $?
}

main "$@"
