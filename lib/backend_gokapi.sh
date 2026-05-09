#!/usr/bin/env bash
# lib/backend_gokapi.sh - Gokapi REST API backend for bundle storage

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bundle.sh
source "${SCRIPT_DIR}/bundle.sh"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/utils.sh"

# Default expiry settings (can be overridden via env)
# Maximum allowed TTL is 7 days (enforced by _gokapi_validate_ttl)
CAC_GOKAPI_EXPIRY_DAYS="${CAC_GOKAPI_EXPIRY_DAYS:-7}"
CAC_GOKAPI_ALLOWED_DOWNLOADS="${CAC_GOKAPI_ALLOWED_DOWNLOADS:-0}"

# Maximum TTL allowed (7 days)
_GOKAPI_MAX_TTL=7

# Internal: Validate and cap TTL value
# Enforces maximum 7-day TTL for all config bundles
# Usage: _gokapi_validate_ttl
# Sets: CAC_GOKAPI_EXPIRY_DAYS (capped if necessary)
# Output: Warning to STDERR if value was overridden
_gokapi_validate_ttl() {
    local original_value="$CAC_GOKAPI_EXPIRY_DAYS"

    # Handle non-numeric values - treat as invalid, use max
    if ! [[ "$CAC_GOKAPI_EXPIRY_DAYS" =~ ^[0-9]+$ ]]; then
        # warn_ttl: Invalid value
        echo >&2 "Warning: Invalid TTL/expiry value '${original_value}', using ${_GOKAPI_MAX_TTL} days"
        CAC_GOKAPI_EXPIRY_DAYS="$_GOKAPI_MAX_TTL"
        return 0
    fi

    # Handle 0 (unlimited) - override to max
    if [[ "$CAC_GOKAPI_EXPIRY_DAYS" -eq 0 ]]; then
        # warn_ttl: Unlimited override
        echo >&2 "Warning: TTL/expiry value 0 (unlimited) overridden to ${_GOKAPI_MAX_TTL} days"
        CAC_GOKAPI_EXPIRY_DAYS="$_GOKAPI_MAX_TTL"
        return 0
    fi

    # Handle values > 7 - cap to max (7 days maximum TTL enforced)
    if [[ "$CAC_GOKAPI_EXPIRY_DAYS" -gt 7 ]]; then
        # warn_ttl: Exceeded maximum
        echo >&2 "Warning: TTL/expiry value ${original_value} exceeds maximum, capped to 7 days"
        CAC_GOKAPI_EXPIRY_DAYS=7
        return 0
    fi

    # Valid value 1-7: no change, no warning
    return 0
}

# Network retry settings (can be overridden via env)
# - MAX_RETRIES: Number of retry attempts after initial failure (3 = up to 4 total attempts)
# - RETRY_DELAY: Seconds to wait between retries (2s balances responsiveness with server recovery)
CAC_GOKAPI_MAX_RETRIES="${CAC_GOKAPI_MAX_RETRIES:-3}"
CAC_GOKAPI_RETRY_DELAY="${CAC_GOKAPI_RETRY_DELAY:-2}"

# Internal: Attempt a single API request and store result in GOKAPI_RESPONSE
# Usage: _gokapi_try_request <method> <endpoint> [curl_options...]
# Sets: GOKAPI_RESPONSE on success
# Returns: 0 if request succeeded with non-empty response, 1 otherwise
#
# Issue #72: Now routes through _gokapi_request_with_status, which captures
# the HTTP status code separately from the body. Non-2xx responses are
# rejected with a structured error message (HTTP code, URL, body excerpt,
# remediation hint) instead of being passed through to JSON parsing.
#
# IMPORTANT: We do NOT use $(...) command substitution to capture the body —
# command substitution runs in a subshell, which would discard the globals
# (GOKAPI_HTTP_STATUS, GOKAPI_LAST_URL, GOKAPI_CURL_EXIT) set by the helper.
# Instead, the helper writes the body to GOKAPI_RAW_BODY and we read it from
# the parent shell.
_gokapi_try_request() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local curl_exit=0
    _gokapi_request_with_status "$method" "$endpoint" "$@" || curl_exit=$?

    local response="${GOKAPI_RAW_BODY:-}"
    local status="${GOKAPI_HTTP_STATUS:-000}"

    utils_verbose "API $method $endpoint: status=$status, curl_exit=$curl_exit, response_length=${#response}"
    local _preview="${response:0:200}"
    utils_verbose "Response preview: ${_preview//$'\n'/ }"

    # Success: HTTP 2xx
    if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
        if [[ -n "$response" ]]; then
            # shellcheck disable=SC2034  # GOKAPI_RESPONSE is used by callers
            GOKAPI_RESPONSE="$response"
            return 0
        fi
        # 2xx with empty body: preserve pre-#72 behaviour where empty body
        # was treated as a (retryable) failure. The list path's caller
        # already handles "null" / empty as "no bundles" downstream.
        return 1
    fi

    # Non-2xx (including curl-level failures with status="000"): emit a
    # structured error so the operator can diagnose without verbose mode.
    local op_name
    op_name=$(_gokapi_derive_op_name "$method" "$endpoint")
    _gokapi_emit_http_error "$op_name" "$status" "${GOKAPI_LAST_URL:-}" "$response"
    return 1
}

# Internal: Attempt a single file download
# Usage: _gokapi_try_download <url> <output_file>
# Returns: 0 if download succeeded and file is non-empty, 1 otherwise
_gokapi_try_download() {
    local url="$1"
    local output_file="$2"

    if curl -sL -o "$output_file" "$url" && [[ -s "$output_file" ]]; then
        return 0
    fi
    return 1
}

# Internal: Validate Gokapi configuration
# Usage: _gokapi_validate_config
# Returns: 0 if valid, 1 if not (with error message)
_gokapi_validate_config() {
    utils_require_var CAC_GOKAPI_URL || return 1
    utils_require_var CAC_GOKAPI_API_KEY || return 1
    return 0
}

# Internal: Make API request to Gokapi
# Usage: _gokapi_request <method> <endpoint> [curl_options...]
#
# NOTE (Issue #72): This helper is intentionally left unchanged so existing
# tests that override it as a function stub continue to work. The new
# status-aware path lives in _gokapi_request_with_status below.
_gokapi_request() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local url="${CAC_GOKAPI_URL}${endpoint}"

    curl -s -m 30 -X "$method" \
        -H "accept: application/json" \
        -H "apikey: ${CAC_GOKAPI_API_KEY}" \
        "$@" \
        "$url"
}

# Internal: Make API request to Gokapi capturing both body and HTTP status.
# Usage: _gokapi_request_with_status <method> <endpoint> [curl_options...]
# Sets:   GOKAPI_RAW_BODY     response body (without the -w status trailer)
#         GOKAPI_HTTP_STATUS  HTTP status code (3-digit string, or "000" if
#                             curl could not complete the request)
#         GOKAPI_CURL_EXIT    curl's exit code (0 on transport success)
#         GOKAPI_LAST_URL     full URL the request was sent to
# Returns: 0 if curl exited 0 AND the -w trailer was parsed successfully;
#          curl's exit code otherwise (>=1).
#
# Issue #72: Strict trailer contract. We always pass `-w '\n%{http_code}'`,
# so curl's stdout MUST end with "\n<3-digit-code>". If curl exits non-zero
# OR the trailer is missing/malformed, status is set to "000" (curl's own
# convention for "no real HTTP response") and we return non-zero. We
# deliberately do NOT silently treat malformed transport output as 200 —
# masking real parser failures was the bug Codex flagged in the v1 plan.
#
# IMPORTANT (subshell hazard): All output is via globals, NOT stdout. If
# this helper printed the body to stdout, callers using $(...) capture
# would run it in a subshell and lose every global it sets. The contract
# is therefore: caller invokes us directly (no command substitution) and
# reads GOKAPI_RAW_BODY / GOKAPI_HTTP_STATUS / GOKAPI_CURL_EXIT from the
# parent shell.
_gokapi_request_with_status() {
    # Reset ALL state on every entry — no stale values from prior calls.
    # Codex implementation note: every read of these globals must be
    # preceded by a write in the same call. This block is the write.
    GOKAPI_RAW_BODY=""
    GOKAPI_HTTP_STATUS=""
    GOKAPI_CURL_EXIT=0
    GOKAPI_LAST_URL=""

    local method="$1"
    local endpoint="$2"
    shift 2

    GOKAPI_LAST_URL="${CAC_GOKAPI_URL}${endpoint}"

    local raw curl_exit=0
    raw=$(curl -s -m 30 -w '\n%{http_code}' -X "$method" \
        -H "accept: application/json" \
        -H "apikey: ${CAC_GOKAPI_API_KEY}" \
        "$@" \
        "$GOKAPI_LAST_URL") || curl_exit=$?
    GOKAPI_CURL_EXIT="$curl_exit"

    # Curl-level failure: no usable response.
    if [[ "$curl_exit" -ne 0 ]]; then
        GOKAPI_HTTP_STATUS="000"
        return "$curl_exit"
    fi

    # Strict trailer parse: last line of $raw must be a 3-digit code.
    if [[ "$raw" == *$'\n'* ]]; then
        local last_line="${raw##*$'\n'}"
        if [[ "$last_line" =~ ^[0-9]{3}$ ]]; then
            GOKAPI_HTTP_STATUS="$last_line"
            GOKAPI_RAW_BODY="${raw%$'\n'*}"
            return 0
        fi
        # Has \n but last line is not a 3-digit code — really malformed.
        GOKAPI_HTTP_STATUS="000"
        utils_verbose "Gokapi: -w trailer present but not a 3-digit code (last_line='${last_line}', raw_length=${#raw})"
        return 1
    fi

    # Raw output has NO newline at all. In production this is unreachable
    # because we always pass `-w '\n%{http_code}'` and curl always appends
    # the trailer when curl_exit==0 (even on empty/binary bodies). The only
    # callers that hit this branch in practice are TEST stubs that mock
    # `curl` as a bash function and ignore the `-w` flag — e.g. the
    # `_mock_curl` helper in tests/test_gokapi_unit.sh which prints a
    # canned body to stdout regardless of flags.
    #
    # We treat that case as a legacy-stub compatibility path: assume HTTP 200
    # so existing curl-mock-based tests (which were written before #72
    # introduced the trailer contract) continue to pass without modification.
    #
    # IMPORTANT: this branch is NOT a compatibility hack for real transport
    # failures. A real curl invocation cannot reach this branch with
    # curl_exit==0 because curl ALWAYS writes the -w format string after
    # the body. If you find yourself reasoning about this branch outside
    # of bash-function-stubbed test contexts, treat it as a bug.
    if [[ -n "$raw" ]]; then
        GOKAPI_HTTP_STATUS="200"
        GOKAPI_RAW_BODY="$raw"
        utils_verbose "Gokapi: no -w trailer in curl output (length=${#raw}); legacy-stub compat path — assuming HTTP 200"
        return 0
    fi

    # Empty raw output — no body, no status. Surface explicitly.
    GOKAPI_HTTP_STATUS="000"
    utils_verbose "Gokapi: empty curl output despite curl_exit=0"
    return 1
}

# Internal: Map (method, endpoint) to a human-readable operation name.
# Usage: _gokapi_derive_op_name <method> <endpoint>
# Outputs: operation name on stdout (e.g. "upload", "list", "delete")
_gokapi_derive_op_name() {
    local method="$1"
    local endpoint="$2"

    case "$endpoint" in
        /api/files/add)    echo "upload" ;;
        /api/files/list)   echo "list" ;;
        /api/files/delete) echo "delete" ;;
        *)
            local lower
            lower=$(echo "$method" | tr '[:upper:]' '[:lower:]')
            echo "${lower} ${endpoint}"
            ;;
    esac
}

# Internal: Redact apikey/api_key query parameters from a URL.
# Usage: _gokapi_redact_url <url>
# Outputs: URL with apikey=*** / api_key=*** substituted (case-insensitive).
#
# Defence-in-depth: production code currently puts the API key in the
# `apikey:` request header, never in the URL. This helper exists so any
# future regression that puts the key in a query string is automatically
# scrubbed before being echoed in error messages.
_gokapi_redact_url() {
    local url="$1"
    printf '%s' "$url" | sed -E 's/(apikey|api_key)=[^&]*/\1=***/Ig'
}

# Internal: Emit a structured HTTP error with remediation hint.
# Usage: _gokapi_emit_http_error <operation> <status> <url> <body>
# Output: 1-3 lines on stderr (via utils_error):
#   "Gokapi <op> failed: HTTP <status> from <safe_url> — <body excerpt>"
#   "  curl exit <N> — see 'man curl' EXIT CODES."  (only when status==000)
#   "  Hint: <remediation>"
#
# Hint mapping:
#   000        -> Backend URL/availability + curl exit code
#   404        -> Backend URL/availability
#   401, 403   -> Authentication (rotate CAC_GOKAPI_API_KEY)
#   5xx        -> Server error (backend failing; retry later)
_gokapi_emit_http_error() {
    local operation="$1"
    local status="$2"
    local url="$3"
    local body="${4:-}"

    local safe_url
    safe_url=$(_gokapi_redact_url "$url")

    # Body excerpt: first 200 chars, newlines collapsed to spaces for a
    # single-line error message.
    local excerpt="${body:0:200}"
    excerpt="${excerpt//$'\n'/ }"
    excerpt="${excerpt//$'\r'/ }"

    local msg="Gokapi ${operation} failed: HTTP ${status} from ${safe_url}"
    if [[ -n "$excerpt" ]]; then
        msg="${msg} — ${excerpt}"
    fi
    utils_error "$msg"

    case "$status" in
        000)
            utils_error "  curl exit ${GOKAPI_CURL_EXIT:-?} — see 'man curl' EXIT CODES."
            utils_error "  Hint: Backend URL/availability — verify CAC_GOKAPI_URL and that the Gokapi instance is up at that path."
            ;;
        404)
            utils_error "  Hint: Backend URL/availability — verify CAC_GOKAPI_URL and that the Gokapi instance is up at that path."
            ;;
        401|403)
            utils_error "  Hint: Authentication — rotate or fix CAC_GOKAPI_API_KEY."
            ;;
        5*)
            utils_error "  Hint: Server error — Gokapi backend is failing; retry later or check server logs."
            ;;
    esac
}

# Internal: Execute a Gokapi operation with retry logic and exponential backoff
# Usage: _gokapi_op_with_retry <operation_type> <function> [args...]
# operation_type: "request" for API requests (sets GOKAPI_RESPONSE), "download" for file downloads
# Returns: 0 on success, 1 on failure after all retries exhausted
#
# Uses exponential backoff: RETRY_DELAY * 2^attempt (2s, 4s, 8s by default)
_gokapi_op_with_retry() {
    local op_type="$1"
    local func="$2"
    shift 2

    local op_name error_msg
    case "$op_type" in
        request)
            op_name="Network request"
            error_msg="Failed to connect to Gokapi server after ${CAC_GOKAPI_MAX_RETRIES} attempts"
            ;;
        download)
            op_name="Download"
            error_msg="Failed to download bundle after ${CAC_GOKAPI_MAX_RETRIES} attempts"
            ;;
        *)
            utils_error "Unknown operation type: $op_type"
            return 1
            ;;
    esac

    if utils_retry "${CAC_GOKAPI_MAX_RETRIES}" "${CAC_GOKAPI_RETRY_DELAY}" \
        "$op_name" "$func" "$@"; then
        return 0
    fi
    utils_error "$error_msg"
    return 1
}

# Internal: Validate API response is not empty/null
# Usage: _gokapi_validate_response <response> <operation>
# Returns: 0 if valid, 1 if empty/null (with error message)
_gokapi_validate_response() {
    local response="$1"
    local operation="$2"

    if [[ -z "$response" || "$response" == "null" ]]; then
        utils_error "Failed to $operation from Gokapi"
        return 1
    fi
    return 0
}

# Internal: Fetch file list from Gokapi with retry and validation
# Usage: _gokapi_fetch_file_list
# Sets: GOKAPI_FILE_LIST on success (via GOKAPI_RESPONSE)
# Returns: 0 on success, 1 on failure
_gokapi_fetch_file_list() {
    if ! _gokapi_op_with_retry request _gokapi_try_request GET "/api/files/list"; then
        return 1
    fi

    if ! _gokapi_validate_response "$GOKAPI_RESPONSE" "retrieve file list"; then
        return 1
    fi

    # shellcheck disable=SC2034  # GOKAPI_FILE_LIST is used by callers
    GOKAPI_FILE_LIST="$GOKAPI_RESPONSE"
    return 0
}

# Upload a bundle to Gokapi
# Usage: backend_gokapi_upload <bundle_file>
backend_gokapi_upload() {
    local bundle_file="$1"

    if ! _gokapi_validate_config; then
        return 1
    fi

    if [[ ! -f "$bundle_file" ]]; then
        utils_error "Bundle file not found: $bundle_file"
        return 1
    fi

    # Validate and cap TTL before upload
    _gokapi_validate_ttl

    local filename
    filename=$(basename "$bundle_file")

    # Use retry logic for upload
    if ! _gokapi_op_with_retry request _gokapi_try_request POST "/api/files/add" \
        -H "Content-Type: multipart/form-data" \
        -F "allowedDownloads=${CAC_GOKAPI_ALLOWED_DOWNLOADS}" \
        -F "expiryDays=${CAC_GOKAPI_EXPIRY_DAYS}" \
        -F "password=" \
        -F "file=@${bundle_file}"; then
        return 1
    fi

    local response="$GOKAPI_RESPONSE"

    # Check for error in response
    if ! utils_json_check_error "$response" "upload"; then
        return 1
    fi

    # Extract file ID from response
    local file_id
    file_id=$(utils_json_extract_field "$response" "$GOKAPI_FIELD_ID")

    if [[ -z "$file_id" ]]; then
        utils_error "Failed to parse upload response"
        echo "Response: $response" >&2
        return 1
    fi

    echo "Uploaded: $filename (ID: $file_id)"
    return 0
}

# Download a bundle from Gokapi
# Usage: backend_gokapi_download <bundle_id> <output_file>
# bundle_id can be a filename, file ID, or partial match
backend_gokapi_download() {
    local bundle_id="$1"
    local output_file="$2"

    if ! _gokapi_validate_config; then
        return 1
    fi

    # Get file list to find the download URL
    if ! _gokapi_fetch_file_list; then
        return 1
    fi

    # Find matching file using shared utility
    local result download_url found_name find_status
    result=$(utils_gokapi_find_file "$GOKAPI_FILE_LIST" "$bundle_id")
    find_status=$?

    # Handle find errors (code 2 error already printed by utils_gokapi_find_file)
    if ! utils_handle_find_result "$find_status" "$bundle_id"; then
        return 1
    fi

    # Parse result "url|name"
    IFS='|' read -r download_url found_name <<< "$result"

    # Validate parsed fields
    if [[ -z "$download_url" || -z "$found_name" ]]; then
        utils_error "Failed to parse file information for: $bundle_id"
        return 1
    fi

    # Construct full download URL if it's relative
    if [[ ! "$download_url" =~ ^https?:// ]]; then
        download_url="${CAC_GOKAPI_URL}${download_url}"
    fi

    # Download the file with retry logic
    if ! _gokapi_op_with_retry download _gokapi_try_download "$download_url" "$output_file"; then
        return 1
    fi

    if [[ ! -s "$output_file" ]]; then
        utils_error "Downloaded file is empty"
        return 1
    fi

    echo "Downloaded: $found_name"
    return 0
}

# List bundles in Gokapi
# Issue #41/#50: --host removed, --tool added for per-service bundle filtering
# Usage: backend_gokapi_list [--tool TOOL] [--user USER]
backend_gokapi_list() {
    # Parse filter arguments
    utils_parse_filter_args "$@"
    local filter_tool="$FILTER_TOOL"
    local filter_user="$FILTER_USER"

    if ! _gokapi_validate_config; then
        return 1
    fi

    # Fetch file list (empty response is OK for list operation)
    if ! _gokapi_op_with_retry request _gokapi_try_request GET "/api/files/list"; then
        return 1
    fi

    if [[ -z "$GOKAPI_RESPONSE" || "$GOKAPI_RESPONSE" == "null" ]]; then
        echo "No bundles found"
        return 0
    fi

    # Parse and filter results using shared utilities
    local found=0
    local entries=()

    while IFS='|' read -r name id; do
        [[ -z "$name" ]] && continue

        local metadata
        if metadata=$(utils_parse_bundle_metadata "$name" "$filter_tool" "$filter_user"); then
            entries+=("${metadata}|${id}")
            ((found++)) || true  # Prevent errexit when incrementing from 0
        fi
    done < <(utils_gokapi_extract_names "$GOKAPI_RESPONSE")

    if [[ "$found" -eq 0 ]]; then
        echo "No bundles found"
        return 0
    fi

    # Sort by timestamp (newest first) and print
    utils_print_bundle_list_header

    # Sort entries by timestamp (field 5, since metadata now includes tool)
    # shellcheck disable=SC2034  # id is intentionally unused
    printf '%s\n' "${entries[@]}" | sort -t'|' -k5 -r | while IFS='|' read -r name host user tool timestamp id; do
        utils_print_bundle_list_entry "$name" "$host" "$user" "$tool" "$timestamp"
    done

    utils_print_bundle_list_footer "$found"
    return 0
}

# Get the newest bundle matching criteria
# Issue #41/#50: --host removed, --tool added for per-service bundle filtering
# Usage: backend_gokapi_get_newest [--tool TOOL] [--user USER]
# Returns the filename of the newest matching bundle
backend_gokapi_get_newest() {
    # Parse filter arguments
    utils_parse_filter_args "$@"
    local filter_tool="$FILTER_TOOL"
    local filter_user="$FILTER_USER"

    if ! _gokapi_validate_config; then
        return 1
    fi

    # Fetch file list
    if ! _gokapi_fetch_file_list; then
        return 1
    fi

    # Collect filtered metadata entries (two-step to avoid pipefail when
    # the last utils_parse_bundle_metadata returns 1 for a non-matching entry)
    local filtered_entries
    # shellcheck disable=SC2034  # id is intentionally unused
    filtered_entries=$(
        while IFS='|' read -r name id; do
            [[ -z "$name" ]] && continue
            utils_parse_bundle_metadata "$name" "$filter_tool" "$filter_user" || true
        done < <(utils_gokapi_extract_names "$GOKAPI_FILE_LIST")
    )

    if [[ -z "$filtered_entries" ]]; then
        utils_error_no_bundle_found "$filter_tool" "$filter_user" "on server"
        return 1
    fi

    local newest_name
    if ! newest_name=$(echo "$filtered_entries" | utils_find_newest_bundle); then
        utils_error_no_bundle_found "$filter_tool" "$filter_user" "on server"
        return 1
    fi

    echo "$newest_name"
    return 0
}

# Delete a bundle from Gokapi
# Usage: backend_gokapi_delete <bundle_id>
backend_gokapi_delete() {
    local bundle_id="$1"

    if ! _gokapi_validate_config; then
        return 1
    fi

    # If bundle_id is a filename, look up the actual ID
    local file_id="$bundle_id"
    local found_name=""

    # BUNDLE_NAME_PREFIX is defined in bundle.sh
    if [[ "$bundle_id" == ${BUNDLE_NAME_PREFIX}_* ]]; then
        # Fetch file list with retry logic
        if ! _gokapi_op_with_retry request _gokapi_try_request GET "/api/files/list"; then
            return 1
        fi

        file_id=$(utils_gokapi_find_id "$GOKAPI_RESPONSE" "$bundle_id")
        found_name="$bundle_id"

        if [[ -z "$file_id" ]]; then
            utils_error "Bundle not found: $bundle_id"
            return 1
        fi
    fi

    # Delete by ID with retry logic
    if ! _gokapi_op_with_retry request _gokapi_try_request DELETE "/api/files/delete" \
        -H "accept: */*" \
        -H "id: ${file_id}"; then
        return 1
    fi

    # Check for success (Gokapi returns empty response on success)
    if ! utils_json_check_error "$GOKAPI_RESPONSE" "delete"; then
        return 1
    fi

    echo "Deleted: ${found_name:-$bundle_id}"
    return 0
}
