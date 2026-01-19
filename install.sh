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
    local libs=(config.sh security.sh tools.sh bundle.sh backend_local.sh backend_gokapi.sh utils.sh logging.sh)
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
    chmod 700 "$CONFIG_DIR"

    # Copy main CLI
    cp "${temp_dir}/bin/cac" "${BIN_DIR}/cac"
    chmod 755 "${BIN_DIR}/cac"

    # Copy library files
    for lib_file in "${temp_dir}/lib/"*; do
        cp "$lib_file" "${LIB_DIR}/"
    done
    chmod 644 "${LIB_DIR}/"*

    # Update CLI to use correct library path
    # The CLI auto-detects lib path relative to its location, but for system-wide
    # we need to ensure the lib path is correct
    sed -i "s|LIB_DIR=\"\${SCRIPT_DIR}/../lib\"|LIB_DIR=\"${LIB_DIR}\"|" "${BIN_DIR}/cac" 2>/dev/null || true

    success "Installed cac to ${BIN_DIR}/cac"
    success "Installed libraries to ${LIB_DIR}/"

    # Install shell completions (optional)
    install_completions "$temp_dir"
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
        # Non-interactive: create example config
        info "Non-interactive mode: creating example configuration"
        cp "${temp_dir}/.env.example" "$env_file"
        chmod 600 "$env_file"
        warn "Please edit ${env_file} with your configuration"
        return 0
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

    chmod 600 "$env_file"
    success "Created configuration: ${env_file}"
}

# Add user bin to PATH if needed
setup_path() {
    if is_root; then
        # System-wide installation, /usr/local/bin is usually in PATH
        return 0
    fi

    # Check if user bin is in PATH
    if [[ ":$PATH:" != *":${USER_BIN_DIR}:"* ]]; then
        warn "${USER_BIN_DIR} is not in your PATH"
        echo ""
        echo "Add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
        echo ""
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
    fi
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
        ((removed++))
    fi

    # Remove library directory
    if [[ -d "$LIB_DIR" ]]; then
        rm -rf "$LIB_DIR"
        success "Removed ${LIB_DIR}"
        ((removed++))
    fi

    # Remove shell completions
    if [[ -f "${BASH_COMPLETION_DIR}/cac" ]]; then
        rm -f "${BASH_COMPLETION_DIR}/cac"
        success "Removed bash completion"
        ((removed++))
    fi
    if [[ -f "${ZSH_COMPLETION_DIR}/_cac" ]]; then
        rm -f "${ZSH_COMPLETION_DIR}/_cac"
        success "Removed zsh completion"
        ((removed++))
    fi

    # Ask about config directory
    if [[ -d "$CONFIG_DIR" ]]; then
        if [[ -t 0 ]]; then
            read -rp "Remove configuration directory ${CONFIG_DIR}? [y/N]: " remove_config
            if [[ "${remove_config,,}" == "y" ]]; then
                rm -rf "$CONFIG_DIR"
                success "Removed ${CONFIG_DIR}"
                ((removed++))
            else
                info "Kept configuration directory"
            fi
        else
            warn "Configuration directory preserved: ${CONFIG_DIR}"
            info "Remove manually if desired: rm -rf ${CONFIG_DIR}"
        fi
    fi

    if [[ "$removed" -eq 0 ]]; then
        info "Nothing to uninstall"
    else
        success "Uninstallation complete"
    fi
}

# Perform installation
do_install() {
    set_install_paths
    check_dependencies

    echo ""
    echo "==================================="
    echo "   cac - Coding Agent Config"
    echo "   Bootstrap Installer"
    echo "==================================="
    echo ""
    info "Installation mode: ${INSTALL_MODE}"
    echo ""

    # Get version to install
    local version
    version=$(get_latest_version)
    info "Latest version: ${version}"

    # Create temp directory
    local temp_dir
    temp_dir=$(mktemp -d -t cac-install.XXXXXXXXXX)
    trap 'rm -rf "$temp_dir"' EXIT

    # Download project files
    download_project "$version" "$temp_dir"

    # Verify checksums
    verify_checksums "$version" "$temp_dir"

    # Install files
    install_files "$temp_dir"

    # Setup configuration
    setup_config "$temp_dir"

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
    echo "Configuration: ${CONFIG_DIR}/.env"
    echo ""
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
                echo "Usage: install.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --uninstall, -u    Remove cac installation"
                echo "  --help, -h         Show this help message"
                echo ""
                echo "Installation modes:"
                echo "  Root:     Installs to /usr/local/bin + /etc/cac/"
                echo "  Non-root: Installs to ~/.local/bin + ~/.config/cac/"
                exit 0
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
