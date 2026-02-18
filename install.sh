#!/usr/bin/env bash
# install.sh - Bootstrap installer for cac (Coding Agent Config)
# Installs cac CLI for managing AI coding assistant configurations
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/BPMspaceUG/bpm-CodingAgentConfigCopy/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --uninstall
#
# Installation modes:
#   Root:     /usr/local/bin/cac + /etc/cac/
#   Non-root: ~/.local/bin/cac + ~/.config/cac/

set -euo pipefail

# Configuration
REPO_OWNER="BPMspaceUG"
REPO_NAME="bpm-CodingAgentConfigCopy"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}"
GITHUB_API_BASE="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"

# Installation paths
SYS_BIN_DIR="/usr/local/bin"
SYS_LIB_DIR="/usr/local/lib/cac"
SYS_CONFIG_DIR="/etc/cac"

USER_BIN_DIR="${HOME}/.local/bin"
USER_LIB_DIR="${HOME}/.local/lib/cac"
USER_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/cac"

# Shell completion paths
SYS_BASH_COMPLETION_DIR="/etc/bash_completion.d"
SYS_ZSH_COMPLETION_DIR="/usr/local/share/zsh/site-functions"
USER_BASH_COMPLETION_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/bash-completion/completions"
USER_ZSH_COMPLETION_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/zsh/site-functions"

# Determine installation mode based on privileges
is_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { error "$*"; exit 1; }

# Set installation directories for user-local install
set_user_local_paths() {
    BIN_DIR="$USER_BIN_DIR"
    LIB_DIR="$USER_LIB_DIR"
    CONFIG_DIR="$USER_CONFIG_DIR"
    BASH_COMPLETION_DIR="$USER_BASH_COMPLETION_DIR"
    ZSH_COMPLETION_DIR="$USER_ZSH_COMPLETION_DIR"
    INSTALL_MODE="user-local"
}

# Set installation directories for system-wide install
set_system_wide_paths() {
    BIN_DIR="$SYS_BIN_DIR"
    LIB_DIR="$SYS_LIB_DIR"
    CONFIG_DIR="$SYS_CONFIG_DIR"
    BASH_COMPLETION_DIR="$SYS_BASH_COMPLETION_DIR"
    ZSH_COMPLETION_DIR="$SYS_ZSH_COMPLETION_DIR"
    INSTALL_MODE="system-wide"
}

# Prompt user for install type (interactive mode only)
# Returns: Sets install paths based on user choice
prompt_install_type() {
    while true; do
        echo ""
        echo "Select installation type:"
        echo "  1) This user only (~/.local/bin/cac)"
        echo "  2) All users (/usr/local/bin/cac) - requires root"
        echo ""
        read -rp "Choice [1]: " install_choice

        case "${install_choice:-1}" in
            1)
                set_user_local_paths
                return 0
                ;;
            2)
                if is_root; then
                    set_system_wide_paths
                    return 0
                else
                    echo ""
                    error "System-wide installation requires root privileges."
                    echo "Please run with sudo, or choose option 1 for user-local install."
                    echo ""
                    # Re-prompt
                fi
                ;;
            *)
                echo ""
                warn "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
}

# Set installation directories based on privilege level (auto-detect for non-interactive)
set_install_paths() {
    # Interactive mode: prompt user for install type
    if [[ -t 0 ]]; then
        prompt_install_type
        return 0
    fi

    # Non-interactive mode: auto-detect based on privileges (backward compatible)
    if is_root; then
        set_system_wide_paths
    else
        set_user_local_paths
    fi
}

# Check for required dependencies
check_dependencies() {
    local missing=()

    for cmd in curl unzip zip; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required dependencies: ${missing[*]}"
    fi
}

# Fetch the latest release tag from GitHub
get_latest_version() {
    local version
    version=$(curl -fsSL "${GITHUB_API_BASE}/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)

    if [[ -z "$version" ]]; then
        # Fallback to main branch if no releases yet
        echo "main"
    else
        echo "$version"
    fi
}

# Download and verify a file
download_file() {
    local url="$1"
    local dest="$2"

    if ! curl -fsSL -o "$dest" "$url"; then
        die "Failed to download: $url"
    fi
}

# Download all project files
download_project() {
    local version="$1"
    local temp_dir="$2"

    local base_url="${GITHUB_RAW_BASE}/${version}"

    info "Downloading cac v${version}..."

    # Create directory structure
    if ! mkdir -p "${temp_dir}/bin" "${temp_dir}/lib" "${temp_dir}/completions"; then
        die "Failed to create temporary directories"
    fi

    # Download main CLI
    download_file "${base_url}/bin/cac" "${temp_dir}/bin/cac"
    chmod +x "${temp_dir}/bin/cac"

    # Download library modules
    local libs=(config.sh security.sh tools.sh bundle.sh backend_local.sh backend_gokapi.sh utils.sh logging.sh check.sh env.sh)
    for lib in "${libs[@]}"; do
        download_file "${base_url}/lib/${lib}" "${temp_dir}/lib/${lib}"
    done

    # Verify all library files were downloaded
    local missing_libs=()
    for lib in "${libs[@]}"; do
        if [[ ! -f "${temp_dir}/lib/${lib}" ]]; then
            missing_libs+=("$lib")
        fi
    done
    if [[ ${#missing_libs[@]} -gt 0 ]]; then
        die "Failed to download required libraries: ${missing_libs[*]}"
    fi

    # Download example config
    download_file "${base_url}/.env.example" "${temp_dir}/.env.example"

    # Download shell completion files (optional, don't fail if missing)
    if curl -fsSL -o "${temp_dir}/completions/cac.bash" "${base_url}/completions/cac.bash" 2>/dev/null; then
        curl -fsSL -o "${temp_dir}/completions/_cac" "${base_url}/completions/_cac" 2>/dev/null || true
    fi

    success "Downloaded all files"
}

# Verify checksums if available
verify_checksums() {
    local version="$1"
    local temp_dir="$2"

    local checksum_url="${GITHUB_RAW_BASE}/${version}/checksums.sha256"
    local checksum_file="${temp_dir}/checksums.sha256"

    # Try to download checksums file (optional, may not exist)
    if curl -fsSL -o "$checksum_file" "$checksum_url" 2>/dev/null; then
        info "Verifying file checksums..."

        # Change to temp_dir and verify
        if (cd "$temp_dir" && sha256sum -c checksums.sha256 --quiet 2>/dev/null); then
            success "Checksums verified"
        else
            warn "Checksum verification failed or not available"
        fi
    else
        info "No checksums file available (optional)"
    fi
}

# Update the CLI binary to use the correct library path
# Cross-platform: works on Linux (GNU sed) and macOS (BSD sed)
# Args: $1 = path to cac binary, $2 = library directory path
update_cli_lib_path() {
    local cac_file="$1"
    local lib_path="$2"
    local pattern='LIB_DIR="${SCRIPT_DIR}/../lib"'
    local replacement="LIB_DIR=\"${lib_path}\""

    # Try GNU sed first (Linux)
    if sed -i "s|${pattern}|${replacement}|" "$cac_file" 2>/dev/null; then
        : # Success
    # Try BSD sed (macOS) - requires empty extension for in-place edit
    elif sed -i '' "s|${pattern}|${replacement}|" "$cac_file" 2>/dev/null; then
        : # Success
    else
        # Fallback: use temp file approach (works everywhere)
        local temp_file
        temp_file=$(mktemp)
        if sed "s|${pattern}|${replacement}|" "$cac_file" > "$temp_file" && \
           mv "$temp_file" "$cac_file" && \
           chmod 755 "$cac_file"; then
            : # Success
        else
            rm -f "$temp_file" 2>/dev/null || true
            warn "Failed to update library path using sed"
        fi
    fi

    # Verify the replacement worked
    if grep -qF 'LIB_DIR="${SCRIPT_DIR}/../lib"' "$cac_file" 2>/dev/null; then
        warn "Library path was not updated in CLI binary"
        warn "Manual fix required: Edit ${cac_file} line 11"
        warn "Change: LIB_DIR=\"\${SCRIPT_DIR}/../lib\""
        warn "    To: LIB_DIR=\"${lib_path}\""
    fi
}

# Install shell completion files
install_completions() {
    local temp_dir="$1"
    local bash_comp="${temp_dir}/completions/cac.bash"
    local zsh_comp="${temp_dir}/completions/_cac"

    # Skip if completion files weren't downloaded
    if [[ ! -f "$bash_comp" ]]; then
        info "Shell completions not available (optional)"
        return 0
    fi

    # Install bash completion
    if [[ -d "$BASH_COMPLETION_DIR" ]] || mkdir -p "$BASH_COMPLETION_DIR" 2>/dev/null; then
        cp "$bash_comp" "${BASH_COMPLETION_DIR}/cac"
        chmod 644 "${BASH_COMPLETION_DIR}/cac"
        success "Installed bash completion to ${BASH_COMPLETION_DIR}/cac"
    else
        info "Skipping bash completion (directory not writable)"
    fi

    # Install zsh completion
    if [[ -f "$zsh_comp" ]]; then
        if [[ -d "$ZSH_COMPLETION_DIR" ]] || mkdir -p "$ZSH_COMPLETION_DIR" 2>/dev/null; then
            cp "$zsh_comp" "${ZSH_COMPLETION_DIR}/_cac"
            chmod 644 "${ZSH_COMPLETION_DIR}/_cac"
            success "Installed zsh completion to ${ZSH_COMPLETION_DIR}/_cac"
        else
            info "Skipping zsh completion (directory not writable)"
        fi
    fi
}

# Install files to final locations
install_files() {
    local temp_dir="$1"

    info "Installing to ${BIN_DIR} (${INSTALL_MODE})..."

    # Create directories with error checking
    if ! mkdir -p "$BIN_DIR" "$LIB_DIR" "$CONFIG_DIR"; then
        die "Failed to create installation directories"
    fi

    # Set permissions for config directory
    # System config (/etc/cac) needs 755 so all users can access it
    # User config (~/.config/cac) stays 700 (private)
    if [[ "$CONFIG_DIR" == "/etc/cac" ]]; then
        chmod 755 "$CONFIG_DIR"
    else
        chmod 700 "$CONFIG_DIR"
    fi

    # Copy main CLI
    cp "${temp_dir}/bin/cac" "${BIN_DIR}/cac"
    chmod 755 "${BIN_DIR}/cac"

    # Copy library files
    for lib_file in "${temp_dir}/lib/"*; do
        cp "$lib_file" "${LIB_DIR}/"
    done
    chmod 644 "${LIB_DIR}/"*

    # Update CLI to use correct library path
    # The CLI auto-detects lib path relative to its location, but for installed version
    # we need to use the absolute path where libraries are installed
    update_cli_lib_path "${BIN_DIR}/cac" "${LIB_DIR}"

    success "Installed cac to ${BIN_DIR}/cac"
    success "Installed libraries to ${LIB_DIR}/"

    # Install shell completions (optional)
    install_completions "$temp_dir"
}

# Show error message for missing config in non-interactive mode
show_noninteractive_config_error() {
    error "Non-interactive mode requires configuration values."
    echo ""
    echo "Provide configuration via CLI arguments:"
    echo ""
    echo "  For Gokapi backend:"
    echo "    curl -fsSL URL | bash -s -- --backend gokapi --url https://your-server.com --api-key YOUR_KEY"
    echo ""
    echo "  For local backend:"
    echo "    curl -fsSL URL | bash -s -- --backend local [--storage /path/to/bundles]"
    echo ""
    echo "Or set environment variables before running:"
    echo "    export CAC_BACKEND=gokapi"
    echo "    export CAC_GOKAPI_URL=https://your-server.com"
    echo "    export CAC_GOKAPI_API_KEY=YOUR_KEY"
    echo "    curl -fsSL URL | bash"
    echo ""
    exit 2
}

# Resolve config value from CLI arg, env var, or default
# Usage: resolve_config_value "ARG_VALUE" "ENV_VAR_NAME" "DEFAULT"
resolve_config_value() {
    local arg_value="$1"
    local env_var_name="$2"
    local default_value="${3:-}"

    if [[ -n "$arg_value" ]]; then
        echo "$arg_value"
    elif [[ -n "${!env_var_name:-}" ]]; then
        echo "${!env_var_name}"
    else
        echo "$default_value"
    fi
}

# Setup or prompt for configuration
setup_config() {
    local temp_dir="$1"
    local env_file="${CONFIG_DIR}/.env"

    if [[ -f "$env_file" ]]; then
        info "Existing configuration found at: $env_file"
        return 0
    fi

    echo ""
    info "Setting up cac configuration..."
    echo ""

    # Interactive or default setup
    local backend=""
    local gokapi_url=""
    local gokapi_key=""
    local local_storage=""

    # Check if running interactively
    if [[ -t 0 ]]; then
        echo "Select storage backend:"
        echo "  1) local  - Store bundles on local filesystem"
        echo "  2) gokapi - Store bundles on Gokapi server"
        echo ""
        read -rp "Choice [1]: " backend_choice

        case "${backend_choice:-1}" in
            2|gokapi)
                backend="gokapi"
                read -rp "Gokapi URL (e.g., https://gokapi.example.com): " gokapi_url
                read -rsp "Gokapi API Key: " gokapi_key
                echo ""
                ;;
            *)
                backend="local"
                local default_storage
                if is_root; then
                    default_storage="/var/lib/cac/bundles"
                else
                    default_storage="${HOME}/.local/share/cac/bundles"
                fi
                read -rp "Storage directory [${default_storage}]: " local_storage
                local_storage="${local_storage:-$default_storage}"
                ;;
        esac
    else
        # Non-interactive mode: use CLI args or environment variables
        backend=$(resolve_config_value "$ARG_BACKEND" "CAC_BACKEND" "")

        if [[ -z "$backend" ]]; then
            show_noninteractive_config_error
        fi

        if [[ "$backend" != "gokapi" && "$backend" != "local" ]]; then
            error "Invalid backend: '$backend'. Must be 'gokapi' or 'local'."
            exit 2
        fi

        if [[ "$backend" == "gokapi" ]]; then
            gokapi_url=$(resolve_config_value "$ARG_URL" "CAC_GOKAPI_URL" "")
            gokapi_key=$(resolve_config_value "$ARG_API_KEY" "CAC_GOKAPI_API_KEY" "")

            if [[ -z "$gokapi_url" || -z "$gokapi_key" ]]; then
                error "Gokapi backend requires both URL and API key."
                echo ""
                echo "Provide via CLI: --backend gokapi --url URL --api-key KEY"
                echo "Or via env vars: CAC_GOKAPI_URL and CAC_GOKAPI_API_KEY"
                exit 2
            fi

            # Validate URL format
            if [[ ! "$gokapi_url" =~ ^https?:// ]]; then
                error "Invalid URL format: must start with http:// or https://"
                exit 2
            fi
        else
            # Local backend
            local default_storage
            if is_root; then
                default_storage="/var/lib/cac/bundles"
            else
                default_storage="${HOME}/.local/share/cac/bundles"
            fi
            local_storage=$(resolve_config_value "$ARG_STORAGE" "CAC_LOCAL_STORAGE" "$default_storage")
        fi

        info "Non-interactive mode: using provided configuration"
    fi

    # Generate config file
    {
        echo "# cac configuration"
        echo "# Generated by installer on $(date)"
        echo ""
        echo "CAC_BACKEND=${backend}"
        echo ""
        if [[ "$backend" == "gokapi" ]]; then
            echo "CAC_GOKAPI_URL=${gokapi_url}"
            echo "CAC_GOKAPI_API_KEY=${gokapi_key}"
            echo ""
            echo "# Gokapi expiry settings"
            echo "CAC_GOKAPI_EXPIRY_DAYS=7        # 1-7 days (0 or >7 defaults to 7 for security)"
            echo "CAC_GOKAPI_ALLOWED_DOWNLOADS=0  # 0 = unlimited downloads"
        else
            echo "CAC_LOCAL_STORAGE=${local_storage}"

            # Create local storage directory if it doesn't exist
            if [[ ! -d "$local_storage" ]]; then
                if mkdir -p "$local_storage" && chmod 700 "$local_storage"; then
                    success "Created storage directory: ${local_storage}"
                else
                    warn "Could not create storage directory: ${local_storage}"
                    warn "Please create it manually and ensure it has 700 permissions"
                fi
            fi
        fi
    } > "$env_file"

    # System config (/etc/cac/.env) needs 644 so all users can read it
    # User config (~/.config/cac/.env) stays 600 (private)
    if [[ "$env_file" == "/etc/cac/.env" ]]; then
        chmod 644 "$env_file"
    else
        chmod 600 "$env_file"
    fi
    success "Created configuration: ${env_file}"
}

# Marker for PATH lines added by cac installer (2-line block)
CAC_PATH_MARKER="# Added by cac installer — do not edit"

# Detect the user's shell RC file
# Returns: path to RC file (always a single file)
_detect_shell_rc() {
    local shell_name
    shell_name="$(basename "${SHELL:-}")"

    case "$shell_name" in
        bash) echo "${HOME}/.bashrc"; return 0 ;;
        zsh)  echo "${HOME}/.zshrc"; return 0 ;;
    esac

    # Fallback: check for existing RC files
    if [[ -f "${HOME}/.bashrc" ]]; then
        echo "${HOME}/.bashrc"
    elif [[ -f "${HOME}/.zshrc" ]]; then
        echo "${HOME}/.zshrc"
    else
        echo "${HOME}/.profile"
    fi
}

# Remove cac PATH marker block from all RC files
_cleanup_path_entry() {
    local rc_file
    for rc_file in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        if [[ -f "$rc_file" ]] && grep -qF "$CAC_PATH_MARKER" "$rc_file"; then
            # Remove the marker line and the immediately following export PATH line
            # Use temp file + cat to preserve file permissions/metadata
            local tmp_file
            tmp_file=$(mktemp)
            sed "/${CAC_PATH_MARKER//\//\\/}/,+1d" "$rc_file" > "$tmp_file" && \
                cat "$tmp_file" > "$rc_file"
            rm -f "$tmp_file" 2>/dev/null || true
            info "Removed PATH entry from ${rc_file}"
        fi
    done
}

# Add user bin to PATH if needed (persisted to shell RC file)
setup_path() {
    if is_root; then
        # System-wide installation, /usr/local/bin is usually in PATH
        return 0
    fi

    # Detect target RC file for the user's current shell
    local target_rc
    target_rc="$(_detect_shell_rc)"

    # If marker already exists in the target RC file, do nothing (idempotent)
    if [[ -f "$target_rc" ]] && grep -qF "$CAC_PATH_MARKER" "$target_rc"; then
        return 0
    fi

    # If USER_BIN_DIR is already in PATH (e.g. set by distro), skip
    if [[ ":$PATH:" == *":${USER_BIN_DIR}:"* ]]; then
        return 0
    fi

    # Create the RC file if it doesn't exist (e.g. .profile fallback)
    touch "$target_rc"

    {
        echo ""
        echo "$CAC_PATH_MARKER"
        echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
    } >> "$target_rc"

    success "Added PATH to ${target_rc}"
    echo "  Run 'source ${target_rc}' or open a new terminal to use cac."
}

# Perform uninstallation
do_uninstall() {
    set_install_paths

    info "Uninstalling cac (${INSTALL_MODE})..."

    local removed=0

    # Remove CLI binary
    if [[ -f "${BIN_DIR}/cac" ]]; then
        rm -f "${BIN_DIR}/cac"
        success "Removed ${BIN_DIR}/cac"
        ((removed++)) || true
    fi

    # Remove library directory
    if [[ -d "$LIB_DIR" ]]; then
        rm -rf "$LIB_DIR"
        success "Removed ${LIB_DIR}"
        ((removed++)) || true
    fi

    # Remove shell completions
    if [[ -f "${BASH_COMPLETION_DIR}/cac" ]]; then
        rm -f "${BASH_COMPLETION_DIR}/cac"
        success "Removed bash completion"
        ((removed++)) || true
    fi
    if [[ -f "${ZSH_COMPLETION_DIR}/_cac" ]]; then
        rm -f "${ZSH_COMPLETION_DIR}/_cac"
        success "Removed zsh completion"
        ((removed++)) || true
    fi

    # Ask about config directory
    if [[ -d "$CONFIG_DIR" ]]; then
        if [[ -t 0 ]]; then
            read -rp "Remove configuration directory ${CONFIG_DIR}? [y/N]: " remove_config
            if [[ "${remove_config,,}" == "y" ]]; then
                rm -rf "$CONFIG_DIR"
                success "Removed ${CONFIG_DIR}"
                ((removed++)) || true
            else
                info "Kept configuration directory"
            fi
        else
            warn "Configuration directory preserved: ${CONFIG_DIR}"
            info "Remove manually if desired: rm -rf ${CONFIG_DIR}"
        fi
    fi

    # Remove PATH entry from shell RC files
    if ! is_root; then
        _cleanup_path_entry
    fi

    if [[ "$removed" -eq 0 ]]; then
        info "Nothing to uninstall"
    else
        success "Uninstallation complete"
    fi
}

# Perform single installation to current paths
do_single_install() {
    local temp_dir="$1"

    # Install files
    install_files "$temp_dir"

    # Setup configuration
    setup_config "$temp_dir"
}

# Perform installation
do_install() {
    # Validate mode first (checks root requirements)
    validate_install_mode

    check_dependencies

    echo ""
    echo "==================================="
    echo "   cac - Coding Agent Config"
    echo "   Bootstrap Installer"
    echo "==================================="
    echo ""

    # Get version to install
    local version
    version=$(get_latest_version)
    info "Latest version: ${version}"

    # Create temp directory with safe trap
    local temp_dir=""
    trap '[[ -n "${temp_dir:-}" ]] && rm -rf "$temp_dir"' EXIT
    temp_dir=$(mktemp -d -t cac-install.XXXXXXXXXX)

    # Download project files
    download_project "$version" "$temp_dir"

    # Verify checksums
    verify_checksums "$version" "$temp_dir"

    # Install based on mode
    case "$INSTALL_MODE_FLAG" in
        user)
            set_user_local_paths
            info "Installation mode: user-local (--user)"
            echo ""
            do_single_install "$temp_dir"
            ;;
        global)
            set_system_wide_paths
            info "Installation mode: system-wide (--global)"
            echo ""
            do_single_install "$temp_dir"
            ;;
        all)
            info "Installation mode: both locations (--all)"
            echo ""
            # Install to user-local first
            set_user_local_paths
            info "Installing to user-local location..."
            do_single_install "$temp_dir"
            echo ""
            # Then install to system-wide
            set_system_wide_paths
            info "Installing to system-wide location..."
            do_single_install "$temp_dir"
            ;;
        "")
            # Auto-detect: use existing behavior (prompt or EUID-based)
            set_install_paths
            info "Installation mode: ${INSTALL_MODE}"
            echo ""
            do_single_install "$temp_dir"
            ;;
    esac

    # Setup PATH for user installation
    setup_path

    echo ""
    echo "==================================="
    success "Installation complete!"
    echo "==================================="
    echo ""
    echo "Usage:"
    echo "  cac push          - Bundle and upload your config"
    echo "  cac pull          - Download and apply newest config"
    echo "  cac list          - List available bundles"
    echo "  cac test          - Test AI tool connectivity"
    echo "  cac --help        - Show all commands"
    echo ""
    if [[ "$INSTALL_MODE_FLAG" == "all" ]]; then
        echo "Configuration: ${USER_CONFIG_DIR}/.env (user) and ${SYS_CONFIG_DIR}/.env (system)"
    else
        echo "Configuration: ${CONFIG_DIR}/.env"
    fi
    echo ""

    # Check for CAC_ENV_INSTALL environment variable for AI tool installation
    if [[ -n "${CAC_ENV_INSTALL:-}" ]]; then
        echo ""
        echo "==================================="
        echo "   Installing AI Tool Environments"
        echo "==================================="
        echo ""

        case "$CAC_ENV_INSTALL" in
            global)
                if is_root; then
                    info "Installing AI tools system-wide (CAC_ENV_INSTALL=global)..."
                    "${BIN_DIR}/cac" env install --global --yes
                else
                    warn "CAC_ENV_INSTALL=global requires root privileges. Skipping AI tool installation."
                fi
                ;;
            user)
                info "Installing AI tools for current user (CAC_ENV_INSTALL=user)..."
                "${BIN_DIR}/cac" env install --user --yes
                ;;
            *)
                warn "Unknown CAC_ENV_INSTALL value: $CAC_ENV_INSTALL"
                warn "Valid values: 'user' or 'global'"
                ;;
        esac
    fi
}

# Global config variables for CLI args (used by setup_config)
ARG_BACKEND=""
ARG_URL=""
ARG_API_KEY=""
ARG_STORAGE=""

# Installation mode: "" (auto), "user", "global", "all"
INSTALL_MODE_FLAG=""

# Validate URL format (must start with http:// or https://)
validate_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?:// ]]; then
        error "Invalid URL format: must start with http:// or https://"
        exit 1
    fi
}

# Validate installation mode flag (check for conflicts and root requirements)
validate_install_mode() {
    case "$INSTALL_MODE_FLAG" in
        global)
            if ! is_root; then
                die "--global requires root privileges"
            fi
            ;;
        all)
            if ! is_root; then
                die "--all requires root privileges"
            fi
            ;;
        user|"")
            # No root required
            ;;
    esac
}

# Set install mode flag with conflict detection
set_install_mode_flag() {
    local new_mode="$1"
    if [[ -n "$INSTALL_MODE_FLAG" && "$INSTALL_MODE_FLAG" != "$new_mode" ]]; then
        die "Conflicting flags: only one of --user, --global, --all allowed"
    fi
    INSTALL_MODE_FLAG="$new_mode"
}

# Show help text
show_help() {
    cat << 'EOF'
Usage: install.sh [OPTIONS]

Options:
  --uninstall, -u        Remove cac installation
  --help, -h             Show this help message

Installation location options:
  --user                 Install to ~/.local/bin only (user-local)
  --global               Install to /usr/local/bin only (requires root)
  --all                  Install to both locations (requires root)
  (no flag)              Auto-detect: root→global, non-root→user

Configuration options (for non-interactive installation):
  --backend, -b TYPE     Backend type: 'gokapi' or 'local'
  --url, -U URL          Gokapi server URL (required for gokapi backend)
  --api-key, -k KEY      Gokapi API key (required for gokapi backend)
  --storage, -s PATH     Local storage path (optional for local backend)

Examples:
  # Interactive installation (prompts for install type)
  ./install.sh

  # User-local installation (even as root)
  sudo ./install.sh --user

  # System-wide installation
  sudo ./install.sh --global

  # Install to both locations
  sudo ./install.sh --all

  # Non-interactive with Gokapi backend
  curl -fsSL URL | bash -s -- --backend gokapi --url https://gokapi.example.com --api-key SECRET

  # Non-interactive user-local with local backend
  curl -fsSL URL | bash -s -- --user --backend local --storage /path/to/bundles

  # Using environment variables
  export CAC_BACKEND=gokapi CAC_GOKAPI_URL=https://... CAC_GOKAPI_API_KEY=...
  curl -fsSL URL | bash

Environment Variables:
  CAC_BACKEND          Backend type ('gokapi' or 'local')
  CAC_GOKAPI_URL       Gokapi server URL
  CAC_GOKAPI_API_KEY   Gokapi API key
  CAC_LOCAL_STORAGE    Local storage path
  CAC_ENV_INSTALL      Install AI tools after cac ('user' or 'global')

AI Tool Installation:
  Set CAC_ENV_INSTALL to automatically install AI tools after cac:

  # Install cac + AI tools for current user
  curl -fsSL URL | CAC_ENV_INSTALL=user bash

  # Install cac + AI tools system-wide (requires root)
  curl -fsSL URL | CAC_ENV_INSTALL=global sudo bash
EOF
}

# Main entry point
main() {
    local uninstall=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall|-u)
                uninstall=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --user)
                set_install_mode_flag "user"
                shift
                ;;
            --global)
                set_install_mode_flag "global"
                shift
                ;;
            --all)
                set_install_mode_flag "all"
                shift
                ;;
            --backend|-b)
                if [[ -z "${2:-}" ]]; then
                    die "--backend requires a value (gokapi or local)"
                fi
                if [[ "$2" != "gokapi" && "$2" != "local" ]]; then
                    die "--backend must be 'gokapi' or 'local'"
                fi
                ARG_BACKEND="$2"
                shift 2
                ;;
            --url|-U)
                if [[ -z "${2:-}" ]]; then
                    die "--url requires a value"
                fi
                validate_url "$2"
                ARG_URL="$2"
                shift 2
                ;;
            --api-key|-k)
                if [[ -z "${2:-}" ]]; then
                    die "--api-key requires a value"
                fi
                ARG_API_KEY="$2"
                shift 2
                ;;
            --storage|-s)
                if [[ -z "${2:-}" ]]; then
                    die "--storage requires a value"
                fi
                ARG_STORAGE="$2"
                shift 2
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    if $uninstall; then
        do_uninstall
    else
        do_install
    fi
}

main "$@"
