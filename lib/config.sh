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
# Warns if user config overrides existing system config
config_find_env_path() {
    local user_config=""
    # System config path only applies on Linux/macOS/WSL — not on Windows
    local system_config=""
    if ! platform_is_windows; then
        system_config="/etc/cac/.env"
    fi

    # Check explicit CAC_CONFIG_DIR first
    if [[ -n "${CAC_CONFIG_DIR:-}" && -f "${CAC_CONFIG_DIR}/.env" ]]; then
        user_config="${CAC_CONFIG_DIR}/.env"
    fi

    # Check XDG config location
    if [[ -z "$user_config" ]]; then
        local xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}"
        if [[ -f "${xdg_config}/cac/.env" ]]; then
            user_config="${xdg_config}/cac/.env"
        fi
    fi

    # If user config found, warn if system config also exists
    if [[ -n "$user_config" ]]; then
        if [[ -f "$system_config" ]]; then
            echo "ATTENTION: User config overrides central system config!" >&2
            echo "  Using:    $user_config" >&2
            echo "  Ignoring: $system_config" >&2
        fi
        echo "$user_config"
        return 0
    fi

    # Fall back to system config
    if [[ -f "$system_config" ]]; then
        echo "$system_config"
        return 0
    fi

    return 1
}

# Validate .env file permissions
# User config: must be 600 (contains user-specific settings)
# System config: allows 644 (readable by all users)
config_check_permissions() {
    local env_path="$1"

    if [[ ! -f "$env_path" ]]; then
        utils_error ".env file not found at: $env_path"
        return 1
    fi

    # Skip permission enforcement on Windows NTFS (chmod is a no-op)
    if platform_is_windows; then
        return 0
    fi

    # System config (/etc/cac/.env) allows 644 for shared access
    if [[ "$env_path" == "/etc/cac/.env" ]]; then
        local perms
        perms=$(platform_get_file_perms "$env_path")
        if [[ "$perms" != "600" && "$perms" != "644" ]]; then
            utils_error "System config '$env_path' has invalid permissions ($perms). Use 600 or 644."
            return 1
        fi
        return 0
    fi

    # User config: strict 600 permissions required
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

# ============================================================================
# Sync Marker Functions (Issue #41: Per-tool change detection)
# ============================================================================

# Get the path to a tool's sync marker file
# Usage: config_get_sync_marker_path <tool>
# Returns: Absolute path to the marker file
config_get_sync_marker_path() {
    local tool="$1"
    local config_dir="${CAC_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/cac}"
    echo "${config_dir}/.last_sync_${tool}"
}

# Update (touch) a tool's sync marker
# Usage: config_update_sync_marker <tool>
# Creates the marker file if it doesn't exist, updates mtime if it does
config_update_sync_marker() {
    local tool="$1"
    local marker_path
    marker_path=$(config_get_sync_marker_path "$tool")

    local marker_dir
    marker_dir=$(dirname "$marker_path")
    [[ -d "$marker_dir" ]] || mkdir -p "$marker_dir"

    touch "$marker_path"
}

# Get a tool's sync marker time as epoch seconds
# Usage: config_get_sync_marker_time <tool>
# Returns: Epoch seconds of marker mtime, or 0 if marker doesn't exist
config_get_sync_marker_time() {
    local tool="$1"
    local marker_path
    marker_path=$(config_get_sync_marker_path "$tool")

    if [[ -f "$marker_path" ]]; then
        platform_get_file_mtime "$marker_path"
    else
        echo "0"
    fi
}

# Check if a tool needs syncing (credentials newer than last sync)
# Usage: config_needs_sync <tool> <home_dir>
# Returns: "true" if sync needed, "false" if not
# Note: Requires tools.sh to be sourced (for tools_get_files)
config_needs_sync() {
    local tool="$1"
    local home_dir="$2"

    local marker_time
    marker_time=$(config_get_sync_marker_time "$tool")

    # If no marker exists (time=0), always needs sync
    if [[ "$marker_time" -eq 0 ]]; then
        echo "true"
        return 0
    fi

    # Check if any credential file for this tool is newer than the marker
    local rel_path
    while IFS= read -r rel_path; do
        [[ -z "$rel_path" ]] && continue
        local abs_path="${home_dir}/${rel_path}"
        if [[ -f "$abs_path" ]]; then
            local file_time
            file_time=$(platform_get_file_mtime "$abs_path")
            if [[ "$file_time" -gt "$marker_time" ]]; then
                echo "true"
                return 0
            fi
        fi
    done < <(tools_get_files "$tool")

    echo "false"
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
