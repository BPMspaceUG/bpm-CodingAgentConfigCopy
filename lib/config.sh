#!/usr/bin/env bash
# lib/config.sh - Configuration loading from .env files

# Source dependencies
# Note: security.sh sources logging.sh, which provides utils_error/utils_warn
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/security.sh"

# ============================================================================
# Configuration Variables
# ============================================================================

# Configuration variables (set after loading)
CAC_BACKEND="${CAC_BACKEND:-local}"
CAC_LOCAL_STORAGE="${CAC_LOCAL_STORAGE:-}"
CAC_GOKAPI_URL="${CAC_GOKAPI_URL:-}"
CAC_GOKAPI_API_KEY="${CAC_GOKAPI_API_KEY:-}"
CAC_GOKAPI_EXPIRY_DAYS="${CAC_GOKAPI_EXPIRY_DAYS:-0}"
CAC_GOKAPI_ALLOWED_DOWNLOADS="${CAC_GOKAPI_ALLOWED_DOWNLOADS:-0}"

# Find .env file location following XDG conventions
# Priority: 1) Explicit CAC_CONFIG_DIR, 2) XDG_CONFIG_HOME/cac, 3) ~/.config/cac, 4) /etc/cac
config_find_env_path() {
    if [[ -n "${CAC_CONFIG_DIR:-}" && -f "${CAC_CONFIG_DIR}/.env" ]]; then
        echo "${CAC_CONFIG_DIR}/.env"
        return 0
    fi

    local xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}"
    if [[ -f "${xdg_config}/cac/.env" ]]; then
        echo "${xdg_config}/cac/.env"
        return 0
    fi

    if [[ -f "/etc/cac/.env" ]]; then
        echo "/etc/cac/.env"
        return 0
    fi

    return 1
}

# Validate .env file permissions (must be exactly 600)
# Uses security_check_file_permissions for the core check, but also
# requires the file to exist (security_check_file_permissions skips missing files)
config_check_permissions() {
    local env_path="$1"

    if [[ ! -f "$env_path" ]]; then
        utils_error ".env file not found at: $env_path"
        return 1
    fi

    # Use security module for permission check (max PERM_SECURE_FILE for sensitive files)
    if ! security_check_file_permissions "$env_path" "$PERM_SECURE_FILE"; then
        echo "Fix with: chmod $PERM_SECURE_FILE '$env_path'" >&2
        return 1
    fi

    return 0
}

# Load configuration from .env file
# Returns 1 if .env not found or has insecure permissions
config_load() {
    local env_path

    if ! env_path=$(config_find_env_path); then
        utils_error "No .env file found."
        echo "Expected locations:" >&2
        echo "  - \${XDG_CONFIG_HOME:-~/.config}/cac/.env" >&2
        echo "  - /etc/cac/.env" >&2
        return 1
    fi

    utils_verbose "Loading config from: $env_path"

    if ! config_check_permissions "$env_path"; then
        return 1
    fi

    # Source the .env file
    # shellcheck source=/dev/null
    source "$env_path"

    # Export loaded variables
    export CAC_BACKEND="${CAC_BACKEND:-local}"
    export CAC_LOCAL_STORAGE="${CAC_LOCAL_STORAGE:-}"
    export CAC_GOKAPI_URL="${CAC_GOKAPI_URL:-}"
    export CAC_GOKAPI_API_KEY="${CAC_GOKAPI_API_KEY:-}"
    export CAC_GOKAPI_EXPIRY_DAYS="${CAC_GOKAPI_EXPIRY_DAYS:-0}"
    export CAC_GOKAPI_ALLOWED_DOWNLOADS="${CAC_GOKAPI_ALLOWED_DOWNLOADS:-0}"

    utils_verbose "Backend: $CAC_BACKEND"

    return 0
}

# Validate required configuration for the selected backend
config_validate() {
    case "$CAC_BACKEND" in
        local)
            utils_require_var CAC_LOCAL_STORAGE "CAC_LOCAL_STORAGE not set for local backend" || return 1
            if [[ ! -d "$CAC_LOCAL_STORAGE" ]]; then
                utils_error "Local storage directory does not exist: $CAC_LOCAL_STORAGE"
                return 1
            fi
            ;;
        gokapi)
            utils_require_var CAC_GOKAPI_URL "CAC_GOKAPI_URL not set for gokapi backend" || return 1
            utils_require_var CAC_GOKAPI_API_KEY "CAC_GOKAPI_API_KEY not set for gokapi backend" || return 1
            ;;
        *)
            utils_error "Unknown backend: $CAC_BACKEND"
            echo "Valid backends: local, gokapi" >&2
            return 1
            ;;
    esac

    return 0
}
