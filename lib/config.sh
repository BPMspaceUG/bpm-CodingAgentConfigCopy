#!/usr/bin/env bash
# lib/config.sh - Configuration loading from .env files

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

# Get the expected config directory for the current installation mode
config_get_dir() {
    if [[ -n "${CAC_CONFIG_DIR:-}" ]]; then
        echo "${CAC_CONFIG_DIR}"
        return 0
    fi

    local xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}"
    echo "${xdg_config}/cac"
}

# Validate .env file permissions (must be 600)
config_check_permissions() {
    local env_path="$1"

    if [[ ! -f "$env_path" ]]; then
        echo "ERROR: .env file not found at: $env_path" >&2
        return 1
    fi

    local perms
    perms=$(stat -c "%a" "$env_path" 2>/dev/null || stat -f "%Lp" "$env_path" 2>/dev/null)

    if [[ "$perms" != "600" ]]; then
        echo "ERROR: .env file has insecure permissions ($perms). Must be 600." >&2
        echo "Fix with: chmod 600 '$env_path'" >&2
        return 1
    fi

    return 0
}

# Load configuration from .env file
# Returns 1 if .env not found or has insecure permissions
config_load() {
    local env_path

    if ! env_path=$(config_find_env_path); then
        echo "ERROR: No .env file found." >&2
        echo "Expected locations:" >&2
        echo "  - \${XDG_CONFIG_HOME:-~/.config}/cac/.env" >&2
        echo "  - /etc/cac/.env" >&2
        return 1
    fi

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

    return 0
}

# Validate required configuration for the selected backend
config_validate() {
    case "$CAC_BACKEND" in
        local)
            if [[ -z "$CAC_LOCAL_STORAGE" ]]; then
                echo "ERROR: CAC_LOCAL_STORAGE not set for local backend" >&2
                return 1
            fi
            if [[ ! -d "$CAC_LOCAL_STORAGE" ]]; then
                echo "ERROR: Local storage directory does not exist: $CAC_LOCAL_STORAGE" >&2
                return 1
            fi
            ;;
        gokapi)
            if [[ -z "$CAC_GOKAPI_URL" ]]; then
                echo "ERROR: CAC_GOKAPI_URL not set for gokapi backend" >&2
                return 1
            fi
            if [[ -z "$CAC_GOKAPI_API_KEY" ]]; then
                echo "ERROR: CAC_GOKAPI_API_KEY not set for gokapi backend" >&2
                return 1
            fi
            ;;
        *)
            echo "ERROR: Unknown backend: $CAC_BACKEND" >&2
            echo "Valid backends: local, gokapi" >&2
            return 1
            ;;
    esac

    return 0
}
