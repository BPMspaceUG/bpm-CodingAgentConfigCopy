#!/usr/bin/env bash
# lib/utils.sh - Shared utility functions for cac

# ============================================================================
# Argument Parsing Utilities
# ============================================================================

# Parse common filter arguments (--host and --user)
# Usage: utils_parse_filter_args "$@"
# Sets: FILTER_HOST, FILTER_USER (used by callers)
# Returns: Remaining arguments should be captured via shift
#
# Example:
#   utils_parse_filter_args "$@"
#   local filter_host="$FILTER_HOST"
#   local filter_user="$FILTER_USER"
utils_parse_filter_args() {
    # shellcheck disable=SC2034  # Variables are used by callers
    FILTER_HOST=""
    # shellcheck disable=SC2034  # Variables are used by callers
    FILTER_USER=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                # shellcheck disable=SC2034  # Variables are used by callers
                FILTER_HOST="$2"
                shift 2
                ;;
            --user)
                # shellcheck disable=SC2034  # Variables are used by callers
                FILTER_USER="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
}

# ============================================================================
# JSON Parsing Utilities
# ============================================================================

# Extract a field value from JSON string using grep/cut fallback
# Usage: utils_json_extract_field <json_string> <field_name>
# Returns: The field value, or empty if not found
#
# Note: This is a fallback for when jq is not available.
# For complex JSON, prefer jq when available.
utils_json_extract_field() {
    local json="$1"
    local field="$2"

    echo "$json" | grep -o "\"${field}\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

# Check if JSON response indicates an error (Gokapi format)
# Usage: utils_json_is_error <json_string>
# Returns: 0 if error, 1 if not
utils_json_is_error() {
    local json="$1"

    echo "$json" | grep -q '"Result":"error"'
}

# Extract error message from Gokapi JSON response
# Usage: utils_json_get_error <json_string>
# Returns: Error message or "unknown error"
utils_json_get_error() {
    local json="$1"
    local msg

    msg=$(utils_json_extract_field "$json" "ErrorMessage")
    echo "${msg:-unknown error}"
}

# ============================================================================
# Bundle Metadata Utilities
# ============================================================================

# Extract host, user, timestamp from parsed bundle filename output
# Usage: read host user timestamp <<< "$(utils_bundle_split_parsed "$parsed")"
# Input: Space-separated "HOST USER TIMESTAMP" string from bundle_parse_filename
utils_bundle_get_host() {
    echo "$1" | cut -d' ' -f1
}

utils_bundle_get_user() {
    echo "$1" | cut -d' ' -f2
}

utils_bundle_get_timestamp() {
    echo "$1" | cut -d' ' -f3
}

# ============================================================================
# Bundle Name Parsing Pipeline
# ============================================================================

# Parse and filter a bundle name, extracting metadata
# Usage: utils_parse_bundle_metadata <name> <filter_host> <filter_user>
# Returns: "name|host|user|timestamp" or empty if filtered out
# Exit code: 0 if bundle passes filters, 1 if filtered out or invalid
#
# This function consolidates the common pattern of:
#   1. Checking if name matches CodingAgentConfig_* pattern
#   2. Parsing the filename to extract metadata
#   3. Applying host/user filters
utils_parse_bundle_metadata() {
    local name="$1"
    local filter_host="${2:-}"
    local filter_user="${3:-}"

    # Only process CodingAgentConfig bundles
    [[ "$name" != CodingAgentConfig_* ]] && return 1

    local parsed host user timestamp
    if ! parsed=$(bundle_parse_filename "$name"); then
        return 1
    fi

    host=$(utils_bundle_get_host "$parsed")
    user=$(utils_bundle_get_user "$parsed")
    timestamp=$(utils_bundle_get_timestamp "$parsed")

    # Apply filters
    if [[ -n "$filter_host" && "$host" != "$filter_host" ]]; then
        return 1
    fi
    if [[ -n "$filter_user" && "$user" != "$filter_user" ]]; then
        return 1
    fi

    echo "${name}|${host}|${user}|${timestamp}"
    return 0
}

# Extract bundle names from Gokapi API response
# Usage: utils_gokapi_extract_names <response>
# Returns: Newline-separated list of bundle names with optional IDs
#
# Uses jq if available, falls back to grep parsing
# Output format with jq: "name|id" per line
# Output format with grep: "name|" per line
utils_gokapi_extract_names() {
    local response="$1"

    if command -v jq &>/dev/null; then
        echo "$response" | jq -r '.[] | "\(.Name)|\(.Id)"' 2>/dev/null
    else
        # Fallback: grep-based parsing
        echo "$response" | grep -o '"Name":"[^"]*"' | cut -d'"' -f4 | while read -r name; do
            echo "${name}|"
        done
    fi
}

# ============================================================================
# Logging Utilities
# ============================================================================

# Log an error message to stderr
# Usage: utils_error "message"
utils_error() {
    echo "ERROR: $1" >&2
}

# Log a warning message to stderr
# Usage: utils_warn "message"
utils_warn() {
    echo "WARNING: $1" >&2
}

# ============================================================================
# File Operation Utilities
# ============================================================================

# Copy file with error checking
# Usage: utils_safe_copy <source> <destination>
# Returns: 0 on success, 1 on failure with error message
utils_safe_copy() {
    local src="$1"
    local dst="$2"

    if ! cp "$src" "$dst"; then
        utils_error "Failed to copy '$src' to '$dst'"
        return 1
    fi
    return 0
}

# Set file permissions with error checking
# Usage: utils_safe_chmod <mode> <file>
# Returns: 0 on success, 1 on failure with error message
utils_safe_chmod() {
    local mode="$1"
    local file="$2"

    if ! chmod "$mode" "$file"; then
        utils_error "Failed to set permissions $mode on '$file'"
        return 1
    fi
    return 0
}
