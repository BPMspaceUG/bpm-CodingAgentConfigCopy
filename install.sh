#!/usr/bin/env bash
# install.sh - Bootstrap installer for cac (Coding Agent Config)
# Installs cac CLI for managing AI coding assistant configurations
#
# Usage:
#   curl -fsSL URL | bash -s -- [OPTIONS]
#
# For USB stick provisioning, use provision.sh instead.
# Options: --user/--global/--all, --backend, --url, --api-key, --storage

set -euo pipefail

# Configuration
REPO_OWNER="BPMspaceUG"
REPO_NAME="bpm-CodingAgentConfigCopy"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}"
GITHUB_API_BASE="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"

# Inline platform detection (lib/platform.sh is not available at install time)
_detect_install_platform() {
    if [[ "${OSTYPE:-}" == msys || "${OSTYPE:-}" == mingw* || "${OSTYPE:-}" == cygwin ]]; then
        echo "gitbash"
    elif uname -r 2>/dev/null | grep -qi microsoft; then
        echo "wsl"
    elif [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
        echo "macos"
    else
        echo "linux"
    fi
}
_INSTALL_PLATFORM=$(_detect_install_platform)

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

# Determine if running as root
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
    if [[ "$_INSTALL_PLATFORM" == "gitbash" ]]; then
        die "System-wide installation is not supported on Windows Git Bash. Use --user instead."
    fi
    BIN_DIR="$SYS_BIN_DIR"
    LIB_DIR="$SYS_LIB_DIR"
    CONFIG_DIR="$SYS_CONFIG_DIR"
    BASH_COMPLETION_DIR="$SYS_BASH_COMPLETION_DIR"
    ZSH_COMPLETION_DIR="$SYS_ZSH_COMPLETION_DIR"
    INSTALL_MODE="system-wide"
}

# Prompt user for install type (interactive pipe mode only)
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
                fi
                ;;
            *)
                echo ""
                warn "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
}

# Set installation directories based on privilege level (pipe mode auto-detect)
set_install_paths() {
    if [[ -t 0 ]]; then
        prompt_install_type
        return 0
    fi

    if is_root; then
        set_system_wide_paths
    else
        set_user_local_paths
    fi
}

# Check for required dependencies
check_dependencies() {
    local missing=()

    for cmd in curl unzip zip git; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}"
        case "$_INSTALL_PLATFORM" in
            gitbash|windows)
                echo "On Windows Git Bash, install missing tools via:" >&2
                echo "  winget install Git.Git     # includes curl, zip, unzip" >&2
                echo "  winget install GnuWin32.Zip" >&2
                ;;
            macos)
                echo "On macOS, install with: brew install ${missing[*]}" >&2
                ;;
            *)
                echo "On Debian/Ubuntu: sudo apt-get install ${missing[*]}" >&2
                ;;
        esac
        exit 1
    fi
}

# Fetch the latest release tag from GitHub
get_latest_version() {
    local version
    version=$(curl -fsSL "${GITHUB_API_BASE}/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)

    if [[ -z "$version" ]]; then
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

# Download all project files from GitHub
download_project() {
    local version="$1"
    local temp_dir="$2"

    local base_url="${GITHUB_RAW_BASE}/${version}"

    info "Downloading cac v${version}..."

    if ! mkdir -p "${temp_dir}/bin" "${temp_dir}/lib" "${temp_dir}/completions"; then
        die "Failed to create temporary directories"
    fi

    # Download main CLI
    download_file "${base_url}/bin/cac" "${temp_dir}/bin/cac"
    chmod +x "${temp_dir}/bin/cac"

    # Download library modules
    local libs=(config.sh security.sh platform.sh tools.sh bundle.sh backend_local.sh backend_gokapi.sh utils.sh logging.sh check.sh env.sh skill.sh update.sh)
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

    if curl -fsSL -o "$checksum_file" "$checksum_url" 2>/dev/null; then
        info "Verifying file checksums..."
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
# Args: $1 = path to cac binary, $2 = library directory path
update_cli_lib_path() {
    local cac_file="$1"
    local lib_path="$2"
    local pattern='LIB_DIR="${SCRIPT_DIR}/../lib"'
    local replacement="LIB_DIR=\"${lib_path}\""

    if sed -i "s|${pattern}|${replacement}|" "$cac_file" 2>/dev/null; then
        : # GNU sed success
    elif sed -i '' "s|${pattern}|${replacement}|" "$cac_file" 2>/dev/null; then
        : # BSD sed success
    else
        local temp_file
        temp_file=$(mktemp)
        if sed "s|${pattern}|${replacement}|" "$cac_file" > "$temp_file" && \
           mv "$temp_file" "$cac_file" && \
           chmod 755 "$cac_file"; then
            : # Fallback success
        else
            rm -f "$temp_file" 2>/dev/null || true
            warn "Failed to update library path using sed"
        fi
    fi

    if grep -qF 'LIB_DIR="${SCRIPT_DIR}/../lib"' "$cac_file" 2>/dev/null; then
        warn "Library path was not updated in CLI binary"
        warn "Manual fix required: Edit ${cac_file} line 11"
        warn "Change: LIB_DIR=\"\${SCRIPT_DIR}/../lib\""
        warn "    To: LIB_DIR=\"${lib_path}\""
    fi
}

# Stamp version into installed cac binary (bakes in the version at install time)
# Uses git state of the SOURCE directory to determine version:
#   dirty (uncommitted changes) → current date + "-dirty"
#   draft (committed, not pushed) → commit date + "-draft"
#   clean (committed + pushed) → commit date (no suffix)
# Args: $1 = target file (installed copy), $2 = source directory (for git detection)
stamp_version() {
    local target="$1"
    local src_dir="${2:-}"
    local ver="" suffix=""
    if [[ -n "$src_dir" ]] && git -C "$src_dir" rev-parse --git-dir &>/dev/null; then
        if ! git -C "$src_dir" diff --quiet HEAD 2>/dev/null || ! git -C "$src_dir" diff --cached --quiet HEAD 2>/dev/null; then
            ver=$(git -C "$src_dir" log -1 --format='%cd' --date=format:'%y%m%d-%H%M' HEAD 2>/dev/null || date '+%y%m%d-%H%M')
            suffix="-dirty"
        elif ! git -C "$src_dir" diff --quiet HEAD "@{upstream}" 2>/dev/null; then
            ver=$(git -C "$src_dir" log -1 --format='%cd' --date=format:'%y%m%d-%H%M' HEAD 2>/dev/null || echo "")
            suffix="-draft"
        else
            ver=$(git -C "$src_dir" log -1 --format='%cd' --date=format:'%y%m%d-%H%M' HEAD 2>/dev/null || echo "")
        fi
    fi
    if [[ -n "$ver" ]]; then
        if sed -i "0,/^VERSION=/{s/^VERSION=.*/VERSION=\"${ver}${suffix}\"/}" "$target" 2>/dev/null; then
            : # GNU sed success
        elif sed -i '' "s/^VERSION=\"dev\"/VERSION=\"${ver}${suffix}\"/" "$target" 2>/dev/null; then
            : # BSD sed success (no 0,/addr/ support, use simple replace)
        else
            local temp_file
            temp_file=$(mktemp)
            if sed "s/^VERSION=\"dev\"/VERSION=\"${ver}${suffix}\"/" "$target" > "$temp_file" && \
               mv "$temp_file" "$target"; then
                : # Fallback success
            else
                rm -f "$temp_file" 2>/dev/null || true
                warn "Failed to stamp version using sed"
            fi
        fi
    fi
}

# Install shell completion files
install_completions() {
    local temp_dir="$1"
    local bash_comp="${temp_dir}/completions/cac.bash"
    local zsh_comp="${temp_dir}/completions/_cac"

    if [[ ! -f "$bash_comp" ]]; then
        info "Shell completions not available (optional)"
        return 0
    fi

    if [[ -d "$BASH_COMPLETION_DIR" ]] || mkdir -p "$BASH_COMPLETION_DIR" 2>/dev/null; then
        cp "$bash_comp" "${BASH_COMPLETION_DIR}/cac"
        chmod 644 "${BASH_COMPLETION_DIR}/cac"
        success "Installed bash completion to ${BASH_COMPLETION_DIR}/cac"
    else
        info "Skipping bash completion (directory not writable)"
    fi

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

    if ! mkdir -p "$BIN_DIR" "$LIB_DIR" "$CONFIG_DIR"; then
        die "Failed to create installation directories"
    fi

    # System config (/etc/cac) needs 755 so all users can access it
    # User config (~/.config/cac) stays 700 (private)
    # On Windows NTFS chmod is a no-op — swallow errors
    if [[ "$CONFIG_DIR" == "/etc/cac" ]]; then
        chmod 755 "$CONFIG_DIR" 2>/dev/null || true
    else
        chmod 700 "$CONFIG_DIR" 2>/dev/null || true
    fi

    cp "${temp_dir}/bin/cac" "${BIN_DIR}/cac"
    chmod 755 "${BIN_DIR}/cac" 2>/dev/null || true

    for lib_file in "${temp_dir}/lib/"*; do
        cp "$lib_file" "${LIB_DIR}/"
    done
    chmod 644 "${LIB_DIR}/"* 2>/dev/null || true

    update_cli_lib_path "${BIN_DIR}/cac" "${LIB_DIR}"

    # Stamp version into installed binary (uses source dir git state)
    stamp_version "${BIN_DIR}/cac" "${temp_dir}"

    # Fallback: if VERSION is still "dev" (curl|bash with no git repo), use commit date from GitHub API
    if grep -q '^VERSION="dev"' "${BIN_DIR}/cac" 2>/dev/null; then
        local fallback_ver=""
        # Try GitHub API to get commit date (matches update_get_remote_version format)
        local api_url="https://api.github.com/repos/BPMspaceUG/bpm-CodingAgentConfigCopy/commits/main"
        local api_response=""
        if api_response=$(curl -fsSL --max-time 10 "$api_url" 2>/dev/null); then
            local commit_date=""
            commit_date=$(echo "$api_response" | grep '"date"' | tail -1 | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}' | head -1) || true
            if [[ -n "$commit_date" ]]; then
                fallback_ver=$(echo "$commit_date" | sed 's/^20\([0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\)T\([0-9][0-9]\):\([0-9][0-9]\)/\1\2\3-\4\5/')
            fi
        fi
        # Last resort: use current date (better than "dev")
        if [[ -z "$fallback_ver" ]]; then
            fallback_ver=$(date '+%y%m%d-%H%M')
        fi
        if sed -i "0,/^VERSION=/{s/^VERSION=.*/VERSION=\"${fallback_ver}\"/}" "${BIN_DIR}/cac" 2>/dev/null; then
            : # GNU sed
        elif sed -i '' "s/^VERSION=\"dev\"/VERSION=\"${fallback_ver}\"/" "${BIN_DIR}/cac" 2>/dev/null; then
            : # BSD sed
        fi
    fi

    success "Installed cac to ${BIN_DIR}/cac"
    success "Installed libraries to ${LIB_DIR}/"

    install_completions "$temp_dir"
}

# Show error message for missing config in non-interactive pipe mode
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

# Setup configuration — use CLI args, env vars, or prompt
setup_config() {
    local env_file="${CONFIG_DIR}/.env"

    if [[ -f "$env_file" ]]; then
        info "Existing configuration found at: $env_file"
        return 0
    fi

    echo ""
    info "Setting up cac configuration..."
    echo ""

    if [[ -t 0 ]]; then
        setup_config_interactive "$env_file"
    else
        # Non-interactive: use CLI args or env vars
        local backend
        backend=$(resolve_config_value "$ARG_BACKEND" "CAC_BACKEND" "")

        if [[ -z "$backend" ]]; then
            show_noninteractive_config_error
        fi

        if [[ "$backend" != "gokapi" && "$backend" != "local" ]]; then
            error "Invalid backend: '$backend'. Must be 'gokapi' or 'local'."
            exit 2
        fi

        local gokapi_url=""
        local gokapi_key=""
        local local_storage=""

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

            if [[ ! "$gokapi_url" =~ ^https?:// ]]; then
                error "Invalid URL format: must start with http:// or https://"
                exit 2
            fi
        else
            local default_storage
            if is_root; then
                default_storage="/var/lib/cac/bundles"
            else
                default_storage="${HOME}/.local/share/cac/bundles"
            fi
            local_storage=$(resolve_config_value "$ARG_STORAGE" "CAC_LOCAL_STORAGE" "$default_storage")
        fi

        info "Non-interactive mode: using provided configuration"
        write_config_file "$env_file" "$backend" "$gokapi_url" "$gokapi_key" "$local_storage"
    fi
}

# Interactive config prompts (shared by local and pipe modes)
setup_config_interactive() {
    local env_file="$1"
    local backend=""
    local gokapi_url=""
    local gokapi_key=""
    local local_storage=""

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

    write_config_file "$env_file" "$backend" "$gokapi_url" "$gokapi_key" "$local_storage"
}

# Write the .env config file
write_config_file() {
    local env_file="$1"
    local backend="$2"
    local gokapi_url="$3"
    local gokapi_key="$4"
    local local_storage="$5"

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

            if [[ -n "$local_storage" && ! -d "$local_storage" ]]; then
                if mkdir -p "$local_storage" && chmod 700 "$local_storage"; then
                    success "Created storage directory: ${local_storage}"
                else
                    warn "Could not create storage directory: ${local_storage}"
                    warn "Please create it manually and ensure it has 700 permissions"
                fi
            fi
        fi
    } > "$env_file"

    # System config (/etc/cac/.env) needs 644 so non-root users can read it
    # to run cac commands. The Gokapi API key is a shared upload/download
    # token, not a user-private secret. See lib/config.sh:config_check_permissions().
    # User config (~/.config/cac/.env) stays 600 (private).
    if [[ "$env_file" == "/etc/cac/.env" ]]; then
        chmod 644 "$env_file" 2>/dev/null || true
    else
        chmod 600 "$env_file" 2>/dev/null || true
    fi
    success "Created configuration: ${env_file}"
}

# Marker for PATH lines added by cac installer (2-line block)
CAC_PATH_MARKER="# Added by cac installer — do not edit"

# Detect the user's shell RC file
_detect_shell_rc() {
    local shell_name
    shell_name="$(basename "${SHELL:-}")"

    case "$shell_name" in
        bash) echo "${HOME}/.bashrc"; return 0 ;;
        zsh)  echo "${HOME}/.zshrc"; return 0 ;;
    esac

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
            local tmp_file
            tmp_file=$(mktemp)
            sed "/${CAC_PATH_MARKER//\//\\/}/,+1d" "$rc_file" > "$tmp_file" && \
                cat "$tmp_file" > "$rc_file"
            rm -f "$tmp_file" 2>/dev/null || true
            info "Removed PATH entry from ${rc_file}"
        fi
    done
}

# Add user bin to PATH if needed (pipe mode user-local installs only)
setup_path() {
    if is_root; then
        return 0
    fi

    local target_rc
    target_rc="$(_detect_shell_rc)"

    if [[ -f "$target_rc" ]] && grep -qF "$CAC_PATH_MARKER" "$target_rc"; then
        return 0
    fi

    if [[ ":$PATH:" == *":${USER_BIN_DIR}:"* ]]; then
        return 0
    fi

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

    if [[ -f "${BIN_DIR}/cac" ]]; then
        rm -f "${BIN_DIR}/cac"
        success "Removed ${BIN_DIR}/cac"
        ((removed++)) || true
    fi

    if [[ -d "$LIB_DIR" ]]; then
        rm -rf "$LIB_DIR"
        success "Removed ${LIB_DIR}"
        ((removed++)) || true
    fi

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

    install_files "$temp_dir"
    setup_config
}

# Install cac: download from GitHub and install
do_install() {
    # Validate mode first (checks root requirements for --global/--all)
    validate_install_mode

    check_dependencies

    echo ""
    echo "==================================="
    echo "   cac - Coding Agent Config"
    echo "   Bootstrap Installer"
    echo "==================================="
    echo ""

    local branch
    branch=$(get_latest_version)

    local temp_dir=""
    trap '[[ -n "${temp_dir:-}" ]] && rm -rf "$temp_dir"' EXIT
    temp_dir=$(mktemp -d -t cac-install.XXXXXXXXXX)

    download_project "$branch" "$temp_dir"
    verify_checksums "$branch" "$temp_dir"

    info "Installing cac from ${branch}..."

    # Install based on mode flag
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
            set_user_local_paths
            info "Installing to user-local location..."
            do_single_install "$temp_dir"
            echo ""
            set_system_wide_paths
            info "Installing to system-wide location..."
            do_single_install "$temp_dir"
            ;;
        "")
            set_install_paths
            info "Installation mode: ${INSTALL_MODE}"
            echo ""
            do_single_install "$temp_dir"
            ;;
    esac

    # Setup PATH for user installation
    setup_path

    # Extract stamped version from installed binary for display
    local version
    version=$(grep -m1 '^VERSION=' "${BIN_DIR}/cac" 2>/dev/null | cut -d'"' -f2) || version="unknown"

    echo ""
    echo "==================================="
    success "Installation complete! (cac v${version})"
    echo "==================================="
    echo ""
    echo "Usage:"
    echo "  cac push          - Bundle and upload your config"
    echo "  cac pull          - Download and apply newest config"
    echo "  cac list          - List available bundles"
    echo "  cac update        - Update cac to latest version"
    echo "  cac test          - Test AI tool connectivity"
    echo "  cac --help        - Show all commands"
    echo ""
    if [[ "$INSTALL_MODE_FLAG" == "all" ]]; then
        echo "Configuration: ${USER_CONFIG_DIR}/.env (user) and ${SYS_CONFIG_DIR}/.env (system)"
    else
        echo "Configuration: ${CONFIG_DIR}/.env"
    fi
    echo ""

    # Check for CAC_ENV_INSTALL env var (pipe mode AI tool install)
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

# Global config variables for CLI args (used by pipe mode setup_config)
ARG_BACKEND=""
ARG_URL=""
ARG_API_KEY=""
ARG_STORAGE=""

# Installation mode: "" (auto), "user", "global", "all" (pipe mode only)
INSTALL_MODE_FLAG=""

# Validate URL format
validate_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?:// ]]; then
        error "Invalid URL format: must start with http:// or https://"
        exit 1
    fi
}

# Validate installation mode flag (pipe mode only)
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
            ;;
    esac
}

# Set install mode flag with conflict detection (pipe mode only)
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

  Pipe installer for cac. Downloads from GitHub and installs.
  For USB stick provisioning, use provision.sh instead.

Options:
  --uninstall, -u        Remove cac installation
  --help, -h             Show this help message
  --user                 Install to ~/.local/bin only
  --global               Install to /usr/local/bin only (requires root)
  --all                  Install to both locations (requires root)
  --backend, -b TYPE     Backend type: 'gokapi' or 'local'
  --url, -U URL          Gokapi server URL
  --api-key, -k KEY      Gokapi API key
  --storage, -s PATH     Local storage path

Examples:
  # USB stick provisioning (install deps + cac + AI tools + skills + Tailscale)
  sudo bash /mnt/usb/provision.sh

  # Remote install with Gokapi backend
  curl -fsSL URL | bash -s -- --global --backend gokapi --url URL --api-key KEY

  # Remote user-local install
  curl -fsSL URL | bash -s -- --user --backend local --storage /path/to/bundles
EOF
}

# Main entry point
main() {
    local uninstall=false

    # Parse arguments first (allow --help without root)
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
            # Pipe mode backward compat flags
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
        return
    fi

    do_install
}

main "$@"
