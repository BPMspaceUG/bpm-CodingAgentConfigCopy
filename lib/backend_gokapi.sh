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
_gokapi_try_request() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local response
    response=$(_gokapi_request "$method" "$endpoint" "$@")

    if [[ $? -eq 0 && -n "$response" ]]; then
        # shellcheck disable=SC2034  # GOKAPI_RESPONSE is used by callers
        GOKAPI_RESPONSE="$response"
        return 0
    fi
    return 1
}

# Internal: Attempt a single file download
# Usage: _gokapi_try_download <url> <output_file>
# Returns: 0 if download succeeded and file is non-empty, 1 otherwise
_gokapi_try_download() {
    local url="$1"
    local output_file="$2"

    if curl -s -o "$output_file" "$url" && [[ -s "$output_file" ]]; then
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
_gokapi_request() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local url="${CAC_GOKAPI_URL}${endpoint}"

    curl -s -X "$method" \
        -H "accept: application/json" \
        -H "apikey: ${CAC_GOKAPI_API_KEY}" \
        "$@" \
        "$url"
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
# Usage: backend_gokapi_list [--host HOST] [--user USER]
backend_gokapi_list() {
    # Parse filter arguments
    utils_parse_filter_args "$@"
    local filter_host="$FILTER_HOST"
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
        if metadata=$(utils_parse_bundle_metadata "$name" "$filter_host" "$filter_user"); then
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

    # Sort entries by timestamp (field 4)
    # shellcheck disable=SC2034  # id is intentionally unused
    printf '%s\n' "${entries[@]}" | sort -t'|' -k4 -r | while IFS='|' read -r name host user timestamp id; do
        utils_print_bundle_list_entry "$name" "$host" "$user" "$timestamp"
    done

    utils_print_bundle_list_footer "$found"
    return 0
}

# Get the newest bundle matching criteria
# Usage: backend_gokapi_get_newest [--host HOST] [--user USER]
# Returns the filename of the newest matching bundle
backend_gokapi_get_newest() {
    # Parse filter arguments
    utils_parse_filter_args "$@"
    local filter_host="$FILTER_HOST"
    local filter_user="$FILTER_USER"

    if ! _gokapi_validate_config; then
        return 1
    fi

    # Fetch file list
    if ! _gokapi_fetch_file_list; then
        return 1
    fi

    # Collect filtered metadata entries and find newest
    local newest_name
    # shellcheck disable=SC2034  # id is intentionally unused
    if ! newest_name=$(
        while IFS='|' read -r name id; do
            [[ -z "$name" ]] && continue
            utils_parse_bundle_metadata "$name" "$filter_host" "$filter_user"
        done < <(utils_gokapi_extract_names "$GOKAPI_FILE_LIST") | utils_find_newest_bundle
    ); then
        utils_error_no_bundle_found "$filter_host" "$filter_user" "on server"
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
