#!/usr/bin/env bash
# lib/utils.sh - Shared utility functions for cac

# ============================================================================
# Gokapi JSON Field Constants
# ============================================================================
# Standard field names used in Gokapi API responses.
# Use these instead of string literals for clarity and typo prevention.
# Guard with -v check to allow sourcing from multiple files.

if [[ ! -v GOKAPI_FIELD_ID ]]; then
    # File identifier field
    readonly GOKAPI_FIELD_ID="Id"
    export GOKAPI_FIELD_ID

    # File name field
    readonly GOKAPI_FIELD_NAME="Name"
    export GOKAPI_FIELD_NAME

    # Download URL field
    readonly GOKAPI_FIELD_URL="UrlHotlink"
    export GOKAPI_FIELD_URL

    # Error message field
    readonly GOKAPI_FIELD_ERROR="ErrorMessage"
    export GOKAPI_FIELD_ERROR

    # Result status field
    readonly GOKAPI_FIELD_RESULT="Result"
    export GOKAPI_FIELD_RESULT

    # Error status value
    readonly GOKAPI_RESULT_ERROR="error"
    export GOKAPI_RESULT_ERROR

    # Cache jq availability at module load time to avoid repeated command -v calls
    # This is checked once when utils.sh is sourced and reused by all JSON functions
    if command -v jq &>/dev/null; then
        readonly UTILS_HAS_JQ=true
    else
        readonly UTILS_HAS_JQ=false
    fi
    export UTILS_HAS_JQ
fi

# ============================================================================
# Backend Dispatch Utilities
# ============================================================================

# Call a backend function with the current backend type
# Usage: backend_call <operation> [args...]
# Example: backend_call upload "$bundle_path"
#          backend_call get_newest --host "$host" --user "$user"
#
# This eliminates duplicated case statements throughout the codebase.
# The CAC_BACKEND variable must be set before calling.
backend_call() {
    local operation="$1"
    shift

    local func_name="backend_${CAC_BACKEND}_${operation}"

    utils_verbose "Backend call: $func_name $*"

    if ! declare -f "$func_name" &>/dev/null; then
        utils_error "Unknown backend operation: ${CAC_BACKEND}/${operation}"
        return 1
    fi

    "$func_name" "$@"
}

# ============================================================================
# Argument Parsing Utilities
# ============================================================================

# Internal: Generic argument parser supporting multiple option types
# Usage: _utils_parse_args <options_spec> [--strict] "$@"
# options_spec: Space-separated list of options to parse (e.g., "user" or "user dry-run skip-check")
# Sets: PARSED_USER, PARSED_DRY_RUN, PARSED_SKIP_CHECK (depending on options_spec)
# Returns: 0 on success, 1 on error
#
# This is the core implementation; use the wrapper functions below for cleaner API.
_utils_parse_args() {
    local options_spec="$1"
    shift

    local strict=false
    if [[ "${1:-}" == "--strict" ]]; then
        strict=true
        shift
    fi

    # Initialize output variables based on options_spec
    # shellcheck disable=SC2034  # Variables are used by callers
    if [[ "$options_spec" == *"user"* ]]; then
        PARSED_USER=""
    fi
    # shellcheck disable=SC2034  # Variables are used by callers
    if [[ "$options_spec" == *"dry-run"* ]]; then
        PARSED_DRY_RUN="false"
    fi
    # shellcheck disable=SC2034  # Variables are used by callers
    if [[ "$options_spec" == *"skip-check"* ]]; then
        PARSED_SKIP_CHECK="false"
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                if [[ "$options_spec" != *"user"* ]]; then
                    if $strict; then
                        utils_error "Unknown option: $1"
                        return 1
                    fi
                    shift
                    continue
                fi
                if [[ $# -lt 2 ]]; then
                    utils_error "Option --user requires an argument"
                    return 1
                fi
                # shellcheck disable=SC2034  # PARSED_USER is used by callers
                PARSED_USER="$2"
                shift 2
                ;;
            --dry-run)
                if [[ "$options_spec" != *"dry-run"* ]]; then
                    if $strict; then
                        utils_error "Unknown option: $1"
                        return 1
                    fi
                    shift
                    continue
                fi
                # shellcheck disable=SC2034  # PARSED_DRY_RUN is used by callers
                PARSED_DRY_RUN="true"
                shift
                ;;
            --skip-check)
                if [[ "$options_spec" != *"skip-check"* ]]; then
                    if $strict; then
                        utils_error "Unknown option: $1"
                        return 1
                    fi
                    shift
                    continue
                fi
                # shellcheck disable=SC2034  # PARSED_SKIP_CHECK is used by callers
                PARSED_SKIP_CHECK="true"
                shift
                ;;
            *)
                if $strict; then
                    utils_error "Unknown option: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done
    return 0
}

# Parse --user argument from command line
# Usage: utils_parse_user_arg [--strict] "$@"
# Sets: PARSED_USER (set to value after --user, or empty if not found)
# Returns: 0 on success, 1 on error (only in strict mode for unknown options)
#
# Options:
#   --strict: Return error on unknown options (use for push/pull/test)
#             Without --strict, unknown options are ignored (use for get)
#
# Example:
#   if ! utils_parse_user_arg --strict "$@"; then
#       return 1
#   fi
#   local target_user="${PARSED_USER:-$USER}"
utils_parse_user_arg() {
    _utils_parse_args "user" "$@"
}

# Parse command arguments including --user and --dry-run
# Usage: utils_parse_command_args [--strict] "$@"
# Sets: PARSED_USER (set to value after --user, or empty if not found)
#       PARSED_DRY_RUN (set to "true" if --dry-run present, "false" otherwise)
# Returns: 0 on success, 1 on error (only in strict mode for unknown options)
#
# Options:
#   --strict: Return error on unknown options (use for push/pull/test)
#             Without --strict, unknown options are ignored (use for get)
#
# Example:
#   if ! utils_parse_command_args --strict "$@"; then
#       return 1
#   fi
#   local target_user="${PARSED_USER:-$USER}"
#   local dry_run="$PARSED_DRY_RUN"
utils_parse_command_args() {
    _utils_parse_args "user dry-run" "$@"
}

# Parse push command arguments including --user, --dry-run, and --skip-check
# Usage: utils_parse_push_args [--strict] "$@"
# Sets: PARSED_USER, PARSED_DRY_RUN, PARSED_SKIP_CHECK
# Returns: 0 on success, 1 on error
utils_parse_push_args() {
    _utils_parse_args "user dry-run skip-check" "$@"
}

# Initialize command context: parse args, validate user, resolve home
# Usage: utils_init_command_context [--strict] "$@"
# Sets: PARSED_TARGET_USER, PARSED_DRY_RUN, PARSED_HOME_DIR
# Returns: 0 on success, 1 on error
#
# This consolidates the common pattern in cmd_push, cmd_pull, cmd_get:
#   1. Parse --user and --dry-run arguments
#   2. Default target_user to current user
#   3. Validate user access and resolve home directory
#
# Example:
#   if ! utils_init_command_context --strict "$@"; then
#       return 1
#   fi
#   local target_user="$PARSED_TARGET_USER"
#   local dry_run="$PARSED_DRY_RUN"
#   local home_dir="$PARSED_HOME_DIR"
utils_init_command_context() {
    local strict=""
    if [[ "${1:-}" == "--strict" ]]; then
        strict="--strict"
        shift
    fi

    # Parse command arguments (--user, --dry-run)
    if ! utils_parse_command_args $strict "$@"; then
        return 1
    fi

    # Default target user to current user
    # shellcheck disable=SC2034  # PARSED_TARGET_USER is used by callers
    PARSED_TARGET_USER="${PARSED_USER:-$USER}"

    # Validate user access
    if ! security_check_user_access "$PARSED_TARGET_USER"; then
        return 1
    fi

    # Resolve home directory
    # shellcheck disable=SC2034  # PARSED_HOME_DIR is used by callers
    if ! PARSED_HOME_DIR=$(security_resolve_user_home "$PARSED_TARGET_USER"); then
        return 1
    fi

    return 0
}

# Initialize push command context: parse args including --skip-check, validate user, resolve home
# Usage: utils_init_push_context [--strict] "$@"
# Sets: PARSED_TARGET_USER, PARSED_DRY_RUN, PARSED_SKIP_CHECK, PARSED_HOME_DIR
# Returns: 0 on success, 1 on error
utils_init_push_context() {
    local strict=""
    if [[ "${1:-}" == "--strict" ]]; then
        strict="--strict"
        shift
    fi

    # Parse push arguments (--user, --dry-run, --skip-check)
    if ! utils_parse_push_args $strict "$@"; then
        return 1
    fi

    # Default target user to current user
    # shellcheck disable=SC2034  # PARSED_TARGET_USER is used by callers
    PARSED_TARGET_USER="${PARSED_USER:-$USER}"

    # Validate user access
    if ! security_check_user_access "$PARSED_TARGET_USER"; then
        return 1
    fi

    # Resolve home directory
    # shellcheck disable=SC2034  # PARSED_HOME_DIR is used by callers
    if ! PARSED_HOME_DIR=$(security_resolve_user_home "$PARSED_TARGET_USER"); then
        return 1
    fi

    return 0
}

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

# Build a human-readable filter description from host/user filters
# Usage: utils_build_filter_description <host> <user>
# Returns: Description string like "host=myhost, user=bob" or empty if no filters
#
# Example:
#   desc=$(utils_build_filter_description "$filter_host" "$filter_user")
#   [[ -n "$desc" ]] && echo "Filtering by: $desc"
utils_build_filter_description() {
    local filter_host="${1:-}"
    local filter_user="${2:-}"
    local desc=""

    [[ -n "$filter_host" ]] && desc="host=$filter_host"
    [[ -n "$filter_user" ]] && desc="${desc:+$desc, }user=$filter_user"

    echo "$desc"
}

# Report "no bundle found" error with appropriate filter context
# Usage: utils_error_no_bundle_found <filter_host> <filter_user> <location>
# location: Human-readable storage location (e.g., "in storage", "on server")
#
# Example:
#   utils_error_no_bundle_found "$filter_host" "$filter_user" "in storage"
utils_error_no_bundle_found() {
    local filter_host="${1:-}"
    local filter_user="${2:-}"
    local location="${3:-}"
    local filter_desc

    filter_desc=$(utils_build_filter_description "$filter_host" "$filter_user")
    if [[ -n "$filter_desc" ]]; then
        utils_error "No bundle found matching: $filter_desc"
    else
        utils_error "No bundles found ${location}"
    fi
}

# ============================================================================
# JSON Parsing Utilities
# ============================================================================

# Escape regex metacharacters in a string for safe use in grep patterns
# Usage: utils_escape_regex <string>
# Returns: String with all regex metacharacters backslash-escaped
#
# This is essential for safe grep pattern construction when variables
# may contain regex metacharacters like . * [ ] \ ^ $ etc.
utils_escape_regex() {
    local str="$1"
    # Escape all basic regex metacharacters
    # Order matters: escape backslash first to avoid double-escaping
    printf '%s' "$str" | sed 's/[[\.*^$()+?{|\\]/\\&/g'
}

# Extract a field value from JSON string using grep/cut fallback
# Usage: utils_json_extract_field <json_string> <field_name>
# Returns: The field value, or empty if not found
#
# Note: This is a fallback for when jq is not available.
# For complex JSON, prefer jq when available.
utils_json_extract_field() {
    local json="$1"
    local field="$2"
    local result

    # Escape field name for safe use in grep pattern (security fix)
    local escaped_field
    escaped_field=$(utils_escape_regex "$field")

    result=$(echo "$json" | grep -o "\"${escaped_field}\":\"[^\"]*\"" | head -1 | cut -d'"' -f4)

    if [[ -z "$result" ]]; then
        utils_verbose "JSON field '$field' not found or empty in response"
    fi

    echo "$result"
}

# Check if JSON response indicates an error (Gokapi format)
# Usage: utils_json_is_error <json_string>
# Returns: 0 if error, 1 if not
utils_json_is_error() {
    local json="$1"

    echo "$json" | grep -q "\"${GOKAPI_FIELD_RESULT}\":\"${GOKAPI_RESULT_ERROR}\""
}

# Extract error message from Gokapi JSON response
# Usage: utils_json_get_error <json_string>
# Returns: Error message or "unknown error"
utils_json_get_error() {
    local json="$1"
    local msg

    msg=$(utils_json_extract_field "$json" "$GOKAPI_FIELD_ERROR")
    echo "${msg:-unknown error}"
}

# Check JSON response for error and report with context
# Usage: utils_json_check_error <json_string> <operation_name>
# Returns: 0 if no error, 1 if error (with error message logged)
#
# This consolidates the common pattern:
#   if utils_json_is_error "$response"; then
#       utils_error "Gokapi <operation> failed: $(utils_json_get_error "$response")"
#       return 1
#   fi
#
# Example:
#   if ! utils_json_check_error "$response" "upload"; then
#       return 1
#   fi
utils_json_check_error() {
    local json="$1"
    local operation="$2"

    if utils_json_is_error "$json"; then
        utils_error "Gokapi $operation failed: $(utils_json_get_error "$json")"
        return 1
    fi
    return 0
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
#   1. Checking if name matches ${BUNDLE_NAME_PREFIX}_* pattern
#   2. Parsing the filename to extract metadata (single parse for efficiency)
#   3. Applying host/user filters
utils_parse_bundle_metadata() {
    local name="$1"
    local filter_host="${2:-}"
    local filter_user="${3:-}"

    # Only process bundles matching our naming convention
    # BUNDLE_NAME_PREFIX is defined in bundle.sh
    [[ "$name" != ${BUNDLE_NAME_PREFIX}_* ]] && return 1

    # Parse once using bundle_parse_filename (returns "host user timestamp")
    local parsed host user timestamp
    if ! parsed=$(bundle_parse_filename "$name"); then
        return 1
    fi

    # Split parsed result (space-separated)
    read -r host user timestamp <<< "$parsed"

    # Apply filters (before allocating output string)
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

    if $UTILS_HAS_JQ; then
        echo "$response" | jq -r ".[] | \"\\(.${GOKAPI_FIELD_NAME})|\\(.${GOKAPI_FIELD_ID})\"" 2>/dev/null
    else
        # Fallback: grep-based parsing
        echo "$response" | grep -o "\"${GOKAPI_FIELD_NAME}\":\"[^\"]*\"" | cut -d'"' -f4 | while read -r name; do
            echo "${name}|"
        done
    fi
}

# ============================================================================
# Bundle List Display Utilities
# ============================================================================

# Print standard bundle list header
# Usage: utils_print_bundle_list_header
# Outputs: Formatted header line and separator for bundle listings
#
# This centralizes the header formatting used by both local and gokapi backends.
utils_print_bundle_list_header() {
    printf "%-40s %-15s %-15s %s\n" "BUNDLE" "HOST" "USER" "TIMESTAMP"
    printf "%s\n" "--------------------------------------------------------------------------------"
}

# Print a bundle entry in the standard list format
# Usage: utils_print_bundle_list_entry <name> <host> <user> <timestamp>
# Outputs: Formatted bundle entry line
utils_print_bundle_list_entry() {
    local name="$1"
    local host="$2"
    local user="$3"
    local timestamp="$4"

    printf "%-40s %-15s %-15s %s\n" "$name" "$host" "$user" "$timestamp"
}

# Print bundle list footer with total count
# Usage: utils_print_bundle_list_footer <count>
# Outputs: Formatted footer with bundle count
utils_print_bundle_list_footer() {
    local count="$1"

    echo ""
    echo "Total: $count bundle(s)"
}

# ============================================================================
# Gokapi File Matching Utilities
# ============================================================================

# Find a file in Gokapi response by ID, exact name, or partial match
# Usage: utils_gokapi_find_file <response> <bundle_id>
# Returns: "url|name" on success, empty on failure
# Exit code: 0 if found (unique match), 1 if not found, 2 if multiple matches
#
# The function tries matching in this order:
#   1. Exact ID match
#   2. Exact filename match
#   3. Partial filename match (fails if multiple matches)
#
# When multiple matches are found (exit code 2), error message with matches is written to stderr
utils_gokapi_find_file() {
    local response="$1"
    local bundle_id="$2"

    if $UTILS_HAS_JQ; then
        _gokapi_find_file_jq "$response" "$bundle_id"
    else
        _gokapi_find_file_grep "$response" "$bundle_id"
    fi
}

# Internal: jq-based file finder
_gokapi_find_file_jq() {
    local response="$1"
    local bundle_id="$2"
    local result

    # Try exact ID match first (single jq call returns "url|name")
    result=$(echo "$response" | jq -r --arg id "$bundle_id" \
        --arg fid "$GOKAPI_FIELD_ID" --arg furl "$GOKAPI_FIELD_URL" --arg fname "$GOKAPI_FIELD_NAME" \
        '.[] | select(.[$fid] == $id) | "\(.[$furl])|\(.[$fname])"' 2>/dev/null | head -1)
    if [[ -n "$result" && "$result" != "|" ]]; then
        echo "$result"
        return 0
    fi

    # Try exact filename match (single jq call)
    result=$(echo "$response" | jq -r --arg name "$bundle_id" \
        --arg fname "$GOKAPI_FIELD_NAME" --arg furl "$GOKAPI_FIELD_URL" \
        '.[] | select(.[$fname] == $name) | "\(.[$furl])|\(.[$fname])"' 2>/dev/null | head -1)
    if [[ -n "$result" && "$result" != "|" ]]; then
        echo "$result"
        return 0
    fi

    # Try partial filename match - get all matches in one call
    local matches_data
    matches_data=$(echo "$response" | jq -r --arg pat "$bundle_id" \
        --arg fname "$GOKAPI_FIELD_NAME" --arg furl "$GOKAPI_FIELD_URL" \
        '[.[] | select(.[$fname] | contains($pat))] |
         if length == 0 then "0"
         elif length == 1 then "1|\(.[0][$furl])|\(.[0][$fname])"
         else "\(length)|\(.[][$fname])"
         end' 2>/dev/null)

    local match_count
    match_count="${matches_data%%|*}"

    case "$match_count" in
        0)
            return 1
            ;;
        1)
            # Format is "1|url|name" - extract url|name
            echo "${matches_data#1|}"
            return 0
            ;;
        *)
            # Multiple matches - report error with names
            utils_error "Multiple bundles match '$bundle_id'. Be more specific:"
            # Names are after the count, one per line
            echo "${matches_data#*|}" | tr '|' '\n' >&2
            return 2
            ;;
    esac
}

# Internal: grep-based file finder (fallback when jq unavailable)
_gokapi_find_file_grep() {
    local response="$1"
    local bundle_id="$2"

    # Escape regex metacharacters for safe pattern matching
    local escaped_id
    escaped_id=$(utils_escape_regex "$bundle_id")

    # Look for exact Name match
    if echo "$response" | grep -q "\"${GOKAPI_FIELD_NAME}\":\"${escaped_id}\""; then
        local url
        url=$(utils_json_extract_field "$response" "$GOKAPI_FIELD_URL")
        echo "${url}|${bundle_id}"
        return 0
    fi

    # Look for exact ID match
    if echo "$response" | grep -q "\"${GOKAPI_FIELD_ID}\":\"${escaped_id}\""; then
        local url
        url=$(utils_json_extract_field "$response" "$GOKAPI_FIELD_URL")
        echo "${url}|${bundle_id}"
        return 0
    fi

    # Try partial match
    local match_count
    match_count=$(echo "$response" | grep -o "\"${GOKAPI_FIELD_NAME}\":\"[^\"]*${escaped_id}[^\"]*\"" | wc -l)

    if [[ "$match_count" -eq 0 ]]; then
        return 1
    elif [[ "$match_count" -eq 1 ]]; then
        local name url
        name=$(echo "$response" | grep -o "\"${GOKAPI_FIELD_NAME}\":\"[^\"]*${escaped_id}[^\"]*\"" | head -1 | cut -d'"' -f4)
        # Use utils_json_extract_field_near to robustly find UrlDownload for the matched Name
        url=$(_gokapi_extract_url_for_name "$response" "$name")
        echo "${url}|${name}"
        return 0
    else
        # Multiple matches
        utils_error "Multiple bundles match '$bundle_id'. Be more specific:"
        echo "$response" | grep -o "\"${GOKAPI_FIELD_NAME}\":\"[^\"]*${escaped_id}[^\"]*\"" | cut -d'"' -f4 >&2
        return 2
    fi
}

# Internal: Extract a field value associated with a specific Name from JSON response
# Usage: _gokapi_extract_field_for_name <response> <name> <target_field> [reset_on_new_object]
# response: JSON response containing array of file objects
# name: The Name value to search for
# target_field: The field to extract (e.g., "UrlDownload" or "Id")
# reset_on_new_object: If "true", reset tracked value when new object starts (default: false)
#
# This uses awk to scan JSON line-by-line, tracking the most recent value of
# target_field seen before finding the matching Name. More robust than grep -B
# because it doesn't depend on exact line counts between fields.
#
# When reset_on_new_object is true, the tracked value is cleared when a new
# Id field is encountered (indicating a new JSON object has started).
_gokapi_extract_field_for_name() {
    local response="$1"
    local name="$2"
    local target_field="$3"
    local reset_on_new="${4:-false}"

    local result
    result=$(echo "$response" | awk -v name="$name" \
        -v target="$target_field" -v fname="$GOKAPI_FIELD_NAME" \
        -v fid="$GOKAPI_FIELD_ID" -v do_reset="$reset_on_new" '
        BEGIN { value = ""; found = 0 }
        $0 ~ ("\"" target "\":\"[^\"]*\"") {
            # Extract field value - pattern is "field":"value"
            match($0, "\"" target "\":\"[^\"]*\"")
            # Skip field name + ":"" (length of target + 4), extract value
            value = substr($0, RSTART + length(target) + 4, RLENGTH - length(target) - 5)
        }
        $0 ~ ("\"" fname "\":") && index($0, "\"" fname "\":\"" name "\"") {
            found = 1
            exit
        }
        do_reset == "true" && $0 ~ ("\"" fid "\":") && value != "" {
            # New object starting, reset if we have not found our name yet
            value = ""
        }
        END { if (found) print value }
    ')

    echo "$result"
}

# Internal: Extract a field value with grep fallback
# Usage: _gokapi_extract_field_with_fallback <response> <name> <target_field> [reset_on_new_object]
#
# Tries awk-based extraction first, falls back to grep -B20 context search.
# This consolidates the common awk+grep fallback pattern.
_gokapi_extract_field_with_fallback() {
    local response="$1"
    local name="$2"
    local target_field="$3"
    local reset_on_new="${4:-false}"

    # Try awk approach first
    local result
    result=$(_gokapi_extract_field_for_name "$response" "$name" "$target_field" "$reset_on_new")

    # Fallback: grep with larger context window
    if [[ -z "$result" ]]; then
        local escaped_name
        escaped_name=$(utils_escape_regex "$name")
        result=$(echo "$response" | grep -B20 "\"${GOKAPI_FIELD_NAME}\":\"${escaped_name}\"" 2>/dev/null | \
                 grep -o "\"${target_field}\":\"[^\"]*\"" | tail -1 | cut -d'"' -f4)
    fi

    echo "$result"
}

# Internal: Extract UrlDownload for a specific Name from JSON response
# This replaces fragile grep -B5 approach by scanning for complete objects
_gokapi_extract_url_for_name() {
    local response="$1"
    local name="$2"

    # Use shared extraction with reset_on_new_object=true for URL extraction
    # (URL should be from the same object as Name)
    _gokapi_extract_field_with_fallback "$response" "$name" "$GOKAPI_FIELD_URL" "true"
}

# Find a file ID by name in Gokapi response
# Usage: utils_gokapi_find_id <response> <filename>
# Returns: File ID on success, empty on failure
# Exit code: 0 if found, 1 if not found
utils_gokapi_find_id() {
    local response="$1"
    local filename="$2"

    if $UTILS_HAS_JQ; then
        echo "$response" | jq -r --arg name "$filename" \
            --arg fname "$GOKAPI_FIELD_NAME" --arg fid "$GOKAPI_FIELD_ID" \
            '.[] | select(.[$fname] == $name) | .[$fid] // empty'
    else
        # Escape the filename for regex matching
        local escaped_name
        escaped_name=$(utils_escape_regex "$filename")

        # Try to extract ID associated with the matching filename
        if echo "$response" | grep -q "\"${GOKAPI_FIELD_NAME}\":\"${escaped_name}\""; then
            # Use shared field extraction helper (no reset on new object for ID)
            _gokapi_extract_field_with_fallback "$response" "$filename" "$GOKAPI_FIELD_ID"
        fi
    fi
}

# ============================================================================
# Bundle Finding Utilities
# ============================================================================

# Find the newest bundle from a list of parsed metadata entries
# Usage: utils_find_newest_bundle <<< "metadata entries"
# Input: One metadata entry per line in format "name|host|user|timestamp"
# Returns: Name of the newest bundle (by timestamp in filename)
# Exit code: 0 if found, 1 if no entries
#
# This extracts the common pattern used by backend_*_get_newest functions
# for finding the newest bundle by comparing timestamp fields in filenames.
utils_find_newest_bundle() {
    local newest_name=""
    local newest_timestamp=""

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Parse metadata format: "name|host|user|timestamp"
        local name timestamp
        name="${line%%|*}"
        timestamp="${line##*|}"

        # Compare timestamps (YYMMDD-HHMMSS format sorts correctly)
        if [[ -z "$newest_timestamp" || "$timestamp" > "$newest_timestamp" ]]; then
            newest_timestamp="$timestamp"
            newest_name="$name"
        fi
    done

    if [[ -z "$newest_name" ]]; then
        return 1
    fi

    echo "$newest_name"
    return 0
}

# ============================================================================
# Download and Extract Utilities
# ============================================================================

# Preview bundle extraction (dry-run mode)
# Usage: utils_preview_extraction <bundle_id> <home_dir>
# Downloads the bundle to a temp directory and shows what would be extracted.
# Returns: 0 on success, 1 if bundle download failed
#
# Output format shows each file with "(would overwrite existing)" or "(new file)"
# This consolidates the common dry-run preview pattern used by cmd_pull and cmd_get.
utils_preview_extraction() {
    local bundle_id="$1"
    local home_dir="$2"

    echo "Bundle contents that would be extracted:"

    # Create temp download to show contents (cleaned on return)
    local temp_dir
    security_init_temp_dir temp_dir "cac-dryrun"
    trap '[[ -n "${temp_dir:-}" ]] && rm -rf "$temp_dir"' RETURN

    local download_path="${temp_dir}/$(basename "$bundle_id")"

    if ! backend_call download "$bundle_id" "$download_path" 2>/dev/null; then
        echo "  (unable to preview bundle contents)"
        return 1
    fi

    # Show what would be extracted
    bundle_list_contents "$download_path" 2>/dev/null | while IFS= read -r file; do
        # Skip header lines from unzip -l output
        [[ "$file" =~ ^[[:space:]]*Length|^[[:space:]]*------|^[[:space:]]*[0-9]+[[:space:]]+files?$ ]] && continue
        # Skip empty lines
        [[ -z "${file// }" ]] && continue

        # Extract just the filename from unzip -l output format (last field)
        local filename
        filename=$(echo "$file" | awk '{print $NF}')
        [[ -z "$filename" || "$filename" == "Name" ]] && continue

        local target_file="${home_dir}/${filename}"
        if [[ -f "$target_file" ]]; then
            echo "  - $filename (would overwrite existing)"
        else
            echo "  - $filename (new file)"
        fi
    done

    return 0
}

# Download a bundle and extract it to user's home directory
# Usage: utils_download_and_extract <bundle_id> <home_dir> <target_user>
# Returns: 0 on success, 1 on failure
#
# This consolidates the common pattern in cmd_pull and cmd_get:
#   1. Create temp directory
#   2. Download bundle
#   3. Extract to home directory
#   4. Clean up temp directory
#
# The temp directory is automatically cleaned up on return.
utils_download_and_extract() {
    local bundle_id="$1"
    local home_dir="$2"
    local target_user="$3"

    # Create temp directory for download (cleaned on return)
    local temp_dir
    security_init_temp_dir temp_dir "cac-download"
    trap '[[ -n "${temp_dir:-}" ]] && rm -rf "$temp_dir"' RETURN

    local download_path="${temp_dir}/$(basename "$bundle_id")"

    if ! backend_call download "$bundle_id" "$download_path"; then
        return 1
    fi

    echo ""
    echo "Extracting to: $home_dir"
    if ! bundle_extract "$download_path" "$home_dir" "$target_user"; then
        return 1
    fi

    return 0
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

# ============================================================================
# Find Result Handling Utilities
# ============================================================================

# Handle find operation result with standardized error reporting
# Usage: utils_handle_find_result <exit_code> <bundle_id> [match_output]
# exit_code: 0=found, 1=not found, 2=multiple matches (error already printed)
# bundle_id: The search term used (for error messages)
# match_output: Optional output from find operation (filenames for code 2)
#              If provided and non-empty, will print "Multiple bundles" error + list
#              If empty/omitted, assumes error was already printed (for code 2)
# Returns: Same as exit_code (pass-through on success, 1 on any error)
#
# This consolidates the common pattern of checking find exit codes
# and printing appropriate error messages. Used by both backend_local
# and backend_gokapi for download/delete operations.
#
# Example:
#   result=$(find_something "$id")
#   status=$?
#   if ! utils_handle_find_result "$status" "$id" "$result"; then
#       return 1
#   fi
#   # Use $result...
utils_handle_find_result() {
    local exit_code="$1"
    local bundle_id="$2"
    local match_output="${3:-}"

    case "$exit_code" in
        0)
            return 0
            ;;
        1)
            utils_error "No bundle found matching: $bundle_id"
            return 1
            ;;
        2)
            # Only print error if match_output is provided (not already printed)
            if [[ -n "$match_output" ]]; then
                utils_error "Multiple bundles match '$bundle_id'. Be more specific:"
                echo "$match_output" >&2
            fi
            # Error was already printed by caller or utility
            return 1
            ;;
        *)
            utils_error "Unexpected find error (code $exit_code)"
            return 1
            ;;
    esac
}

# ============================================================================
# Retry Utilities
# ============================================================================

# Execute a command with exponential backoff retry
# Usage: utils_retry <max_attempts> <base_delay> <operation_name> <command> [args...]
# max_attempts: Maximum number of attempts (e.g., 3)
# base_delay: Base delay in seconds for exponential backoff (e.g., 2 -> 2s, 4s, 8s)
# operation_name: Human-readable name for logging (e.g., "Network request")
# command: The command to execute
# args: Arguments to pass to the command
# Returns: 0 on success, 1 on failure after all retries exhausted
#
# The delay doubles after each failed attempt: delay = base_delay * 2^(attempt-1)
# Verbose mode shows retry progress.
#
# Example:
#   utils_retry 3 2 "API request" curl -s -o /tmp/out http://example.com
#   utils_retry 5 1 "Download" wget -q http://example.com/file.zip
utils_retry() {
    local max_attempts="$1"
    local base_delay="$2"
    local operation_name="$3"
    shift 3

    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        # Execute the command
        if "$@"; then
            return 0
        fi

        ((attempt++)) || true

        # Log and sleep if not exhausted
        if [[ $attempt -lt $max_attempts ]]; then
            local delay=$((base_delay * (1 << (attempt - 1))))
            utils_verbose "$operation_name failed, retrying in ${delay}s (attempt $attempt/$max_attempts)"
            sleep "$delay"
        fi
    done

    return 1
}
