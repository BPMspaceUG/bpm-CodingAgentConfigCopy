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
#          backend_call get_newest --tool "$tool" --user "$user"
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

# Parse common filter arguments (--tool and --user)
# Issue #41/#50: --host removed, --tool added for per-service bundle filtering
# Usage: utils_parse_filter_args "$@"
# Sets: FILTER_TOOL, FILTER_USER (used by callers)
# Returns: Remaining arguments should be captured via shift
#
# Example:
#   utils_parse_filter_args "$@"
#   local filter_tool="$FILTER_TOOL"
#   local filter_user="$FILTER_USER"
utils_parse_filter_args() {
    # shellcheck disable=SC2034  # Variables are used by callers
    FILTER_TOOL=""
    # shellcheck disable=SC2034  # Variables are used by callers
    FILTER_USER=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool)
                # shellcheck disable=SC2034  # Variables are used by callers
                FILTER_TOOL="$2"
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

# Build a human-readable filter description from tool/user filters
# Issue #41/#50: Changed from host/user to tool/user
# Usage: utils_build_filter_description <tool> <user>
# Returns: Description string like "tool=claude, user=bob" or empty if no filters
#
# Example:
#   desc=$(utils_build_filter_description "$filter_tool" "$filter_user")
#   [[ -n "$desc" ]] && echo "Filtering by: $desc"
utils_build_filter_description() {
    local filter_tool="${1:-}"
    local filter_user="${2:-}"
    local desc=""

    [[ -n "$filter_tool" ]] && desc="tool=$filter_tool"
    [[ -n "$filter_user" ]] && desc="${desc:+$desc, }user=$filter_user"

    echo "$desc"
}

# Report "no bundle found" error with appropriate filter context
# Issue #41/#50: Changed from host/user to tool/user
# Usage: utils_error_no_bundle_found <filter_tool> <filter_user> <location>
# location: Human-readable storage location (e.g., "in storage", "on server")
#
# Example:
#   utils_error_no_bundle_found "$filter_tool" "$filter_user" "in storage"
utils_error_no_bundle_found() {
    local filter_tool="${1:-}"
    local filter_user="${2:-}"
    local location="${3:-}"
    local filter_desc

    filter_desc=$(utils_build_filter_description "$filter_tool" "$filter_user")
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
# Issue #41/#50: Changed from host/user filters to tool/user filters
# Usage: utils_parse_bundle_metadata <name> <filter_tool> <filter_user>
# Returns: "name|host|user|tool|timestamp" or empty if filtered out
# Exit code: 0 if bundle passes filters, 1 if filtered out or invalid
#
# This function consolidates the common pattern of:
#   1. Checking if name matches ${BUNDLE_NAME_PREFIX}_* pattern
#   2. Parsing the filename to extract metadata (single parse for efficiency)
#   3. Applying tool/user filters
# Supports both old (4-segment) and new (5-segment) bundle naming formats.
utils_parse_bundle_metadata() {
    local name="$1"
    local filter_tool="${2:-}"
    local filter_user="${3:-}"

    # Only process bundles matching our naming convention
    # BUNDLE_NAME_PREFIX is defined in bundle.sh
    [[ "$name" != ${BUNDLE_NAME_PREFIX}_* ]] && return 1

    # Parse once using bundle_parse_filename (returns "host user tool timestamp")
    local parsed host user tool timestamp
    if ! parsed=$(bundle_parse_filename "$name"); then
        return 1
    fi

    # Split parsed result (space-separated: host user tool timestamp)
    read -r host user tool timestamp <<< "$parsed"

    # Apply filters (before allocating output string)
    if [[ -n "$filter_tool" && "$tool" != "$filter_tool" ]]; then
        return 1
    fi
    if [[ -n "$filter_user" && "$user" != "$filter_user" ]]; then
        return 1
    fi

    echo "${name}|${host}|${user}|${tool}|${timestamp}"
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
# Issue #41: Added TOOL column
# Usage: utils_print_bundle_list_header
# Outputs: Formatted header line and separator for bundle listings
#
# This centralizes the header formatting used by both local and gokapi backends.
utils_print_bundle_list_header() {
    printf "%-50s %-15s %-12s %-10s %s\n" "BUNDLE" "HOST" "USER" "TOOL" "TIMESTAMP"
    printf "%s\n" "----------------------------------------------------------------------------------------------------"
}

# Print a bundle entry in the standard list format
# Issue #41: Added tool parameter
# Usage: utils_print_bundle_list_entry <name> <host> <user> <tool> <timestamp>
# Outputs: Formatted bundle entry line
utils_print_bundle_list_entry() {
    local name="$1"
    local host="$2"
    local user="$3"
    local tool="$4"
    local timestamp="$5"

    printf "%-50s %-15s %-12s %-10s %s\n" "$name" "$host" "$user" "$tool" "$timestamp"
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
         else "\(length)|\([.[][$fname]] | join("|"))"
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

# Internal: print the Gokapi file list one file object per line (#159).
# The real /api/files/list answer is a single line, so any line-based lookup
# on it reads fields of the first object. Splitting at "},{" puts every
# object on its own line; field lookups then stay inside one object.
_gokapi_objects_per_line() {
    printf '%s' "$1" | tr -d '\n' | awk '{ gsub(/\}[ \t]*,[ \t]*\{/, "}\n{"); print }'
}

# Internal: read a string field of one file object into a variable
# Usage: _gokapi_object_field <var_name> <object_line> <field>
# Sets <var_name> to the value, or to empty if the field is missing. The
# leading quote in the pattern keeps "Id" from matching "HotlinkId" etc.
_gokapi_object_field() {
    local re="\"$3\":\"([^\"]*)\""
    if [[ "$2" =~ $re ]]; then
        printf -v "$1" '%s' "${BASH_REMATCH[1]}"
    else
        printf -v "$1" '%s' ""
    fi
}

# Internal: grep-based file finder (fallback when jq unavailable)
# Same order as _gokapi_find_file_jq: exact ID, exact name, unique partial name.
_gokapi_find_file_grep() {
    local response="$1"
    local bundle_id="$2"

    local obj id name url exact="" partial_names=() partial_urls=()
    while IFS= read -r obj; do
        _gokapi_object_field id "$obj" "$GOKAPI_FIELD_ID"
        _gokapi_object_field name "$obj" "$GOKAPI_FIELD_NAME"
        _gokapi_object_field url "$obj" "$GOKAPI_FIELD_URL"
        if [[ -n "$id" && "$id" == "$bundle_id" ]]; then
            echo "${url}|${name}"
            return 0
        fi
        [[ -z "$name" ]] && continue
        if [[ -z "$exact" && "$name" == "$bundle_id" ]]; then
            exact="${url}|${name}"
        fi
        if [[ "$name" == *"$bundle_id"* ]]; then
            partial_names+=("$name")
            partial_urls+=("$url")
        fi
    done < <(_gokapi_objects_per_line "$response")

    if [[ -n "$exact" ]]; then
        echo "$exact"
        return 0
    fi

    case "${#partial_names[@]}" in
        0)
            return 1
            ;;
        1)
            echo "${partial_urls[0]}|${partial_names[0]}"
            return 0
            ;;
        *)
            utils_error "Multiple bundles match '$bundle_id'. Be more specific:"
            printf '%s\n' "${partial_names[@]}" >&2
            return 2
            ;;
    esac
}

# Internal: value of <target_field> of the file object whose Name is <name>
# Usage: _gokapi_extract_field_for_name <response> <name> <target_field>
# Prints the value of the first object with that exact Name, or nothing.
_gokapi_extract_field_for_name() {
    local response="$1"
    local name="$2"
    local target_field="$3"

    local obj obj_name value
    while IFS= read -r obj; do
        _gokapi_object_field obj_name "$obj" "$GOKAPI_FIELD_NAME"
        if [[ -n "$obj_name" && "$obj_name" == "$name" ]]; then
            _gokapi_object_field value "$obj" "$target_field"
            echo "$value"
            return 0
        fi
    done < <(_gokapi_objects_per_line "$response")
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
        _gokapi_extract_field_for_name "$response" "$filename" "$GOKAPI_FIELD_ID"
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
# While <command> runs, UTILS_RETRY_ATTEMPT (1-based) and UTILS_RETRY_MAX are
# set for it (function-local, so unset outside any retry). The command can ask
# utils_retry_has_next_attempt whether a failure now will be retried, and
# utils_retry_progress for the "X/Y" counter (#128).
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
    local UTILS_RETRY_ATTEMPT UTILS_RETRY_MAX="$max_attempts"

    while [[ $attempt -lt $max_attempts ]]; do
        UTILS_RETRY_ATTEMPT=$((attempt + 1))
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

# True while the command running inside utils_retry is on a non-final attempt,
# i.e. a failure now will be retried. False outside any utils_retry (#128).
# Usage: utils_retry_has_next_attempt
utils_retry_has_next_attempt() {
    [[ -n "${UTILS_RETRY_ATTEMPT:-}" && -n "${UTILS_RETRY_MAX:-}" ]] &&
        [[ "$UTILS_RETRY_ATTEMPT" -lt "$UTILS_RETRY_MAX" ]]
}

# Print the current utils_retry attempt as "X/Y" (empty outside any retry).
# Usage: utils_retry_progress
utils_retry_progress() {
    [[ -n "${UTILS_RETRY_ATTEMPT:-}" ]] || return 0
    printf '%s/%s' "$UTILS_RETRY_ATTEMPT" "$UTILS_RETRY_MAX"
}
