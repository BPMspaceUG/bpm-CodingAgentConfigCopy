#!/usr/bin/env bash
# lib/logging.sh - Core logging utilities
#
# This module must be sourced before any other module that uses
# utils_error or utils_warn. It has no dependencies.

# Verbose mode flag - can be set by CLI via logging_set_verbose
CAC_VERBOSE="${CAC_VERBOSE:-false}"

# Enable verbose mode
# Usage: logging_set_verbose
logging_set_verbose() {
    CAC_VERBOSE=true
}

# Check if verbose mode is enabled
# Usage: if logging_is_verbose; then ...; fi
logging_is_verbose() {
    [[ "$CAC_VERBOSE" == "true" ]]
}

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

# Log a success message to stdout
# Usage: utils_success "message"
utils_success() {
    echo "SUCCESS: $1"
}

# Log a verbose/debug message to stderr (only when verbose mode is enabled)
# Usage: utils_verbose "message"
utils_verbose() {
    if logging_is_verbose; then
        echo "[verbose] $1" >&2
    fi
}

# Log a dry-run message with standard prefix
# Usage: utils_dryrun "message"
utils_dryrun() {
    echo "[DRY-RUN] $1"
}

# Print standard dry-run footer
# Usage: utils_dryrun_footer
utils_dryrun_footer() {
    echo ""
    echo "No changes made (dry-run mode)"
}

# ============================================================================
# Validation Utilities
# ============================================================================

# Check that a variable is set and non-empty, log error if not
# Usage: utils_require_var <var_name> [error_message]
# var_name: Name of the variable to check (without $)
# error_message: Optional custom error message (default: "VAR_NAME not configured")
# Returns: 0 if set and non-empty, 1 otherwise
#
# This consolidates the common validation pattern:
#   if [[ -z "${VAR:-}" ]]; then
#       utils_error "VAR not configured"
#       return 1
#   fi
#
# Examples:
#   utils_require_var CAC_GOKAPI_URL || return 1
#   utils_require_var CAC_LOCAL_STORAGE "Local storage path is required" || return 1
utils_require_var() {
    local var_name="$1"
    local error_msg="${2:-$var_name not configured}"

    # Use indirect expansion to get the variable's value
    local var_value="${!var_name:-}"

    if [[ -z "$var_value" ]]; then
        utils_error "$error_msg"
        return 1
    fi
    return 0
}
