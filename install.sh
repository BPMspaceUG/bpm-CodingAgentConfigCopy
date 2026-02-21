#!/usr/bin/env bash
# install.sh - Bootstrap installer for cac (Coding Agent Config)
# Installs cac CLI for managing AI coding assistant configurations
#
# TWO MODES:
#   LOCAL mode:  sudo bash install.sh
#     - Auto-detects files alongside install.sh (USB stick)
#     - Requires root
#     - Auto-installs deps, copies files, runs full 6-step pipeline
#
#   PIPE mode:   curl -fsSL URL | bash -s -- [OPTIONS]
#     - Downloads from GitHub
#     - Supports --user/--global/--all, --backend, --url, --api-key, --storage
#     - Root/non-root auto-detected based on privileges

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

# Check for required dependencies and auto-install if missing (local mode)
# In local mode we have root and can apt-get install.
# In pipe mode we just check and die if missing.
check_dependencies() {
    local auto_install="$1"  # "true" for local mode, "false" for pipe mode
    local missing=()

    for cmd in curl unzip zip git; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ "$auto_install" == "true" ]]; then
        info "Installing missing dependencies: ${missing[*]}"
        if apt-get update -qq &>/dev/null && apt-get install -y "${missing[@]}" &>/dev/null; then
            success "Installed: ${missing[*]}"
        else
            die "Failed to install dependencies: ${missing[*]}. Install them manually with: apt-get install -y ${missing[*]}"
        fi
    else
        die "Missing required dependencies: ${missing[*]}"
    fi
}

# Resolve the directory where install.sh lives
# Returns empty string if resolution fails (e.g. piped input).
get_script_dir() {
    local source="${BASH_SOURCE[0]:-}"

    # Piped input: cannot resolve
    case "$source" in
        ""|"-"|"bash"|"/dev/stdin") echo ""; return 0 ;;
    esac

    # readlink -f resolves symlinks, relative paths, and paths with spaces
    local resolved
    resolved="$(readlink -f "$source" 2>/dev/null)" || true

    if [[ -n "$resolved" && -f "$resolved" ]]; then
        dirname "$resolved"
        return 0
    fi

    # Fallback: resolve manually
    [[ "$source" != /* ]] && source="${PWD}/${source}"
    dirname "$source"
}

# Check if local project files exist alongside install.sh
# Strict: BOTH bin/cac AND core lib/*.sh must exist
detect_local_files() {
    local script_dir="$1"
    [[ -n "$script_dir" ]] && \
    [[ -f "${script_dir}/bin/cac" ]] && \
    [[ -f "${script_dir}/lib/config.sh" ]] && \
    [[ -f "${script_dir}/lib/security.sh" ]] && \
    [[ -f "${script_dir}/lib/bundle.sh" ]] && \
    [[ -f "${script_dir}/lib/tools.sh" ]] && \
    [[ -f "${script_dir}/lib/utils.sh" ]] && \
    [[ -f "${script_dir}/lib/logging.sh" ]]
}

# Copy local files to temp directory (mirrors download_project structure)
copy_local_files() {
    local script_dir="$1"
    local temp_dir="$2"

    info "Local files detected -- using local installation"

    if ! mkdir -p "${temp_dir}/bin" "${temp_dir}/lib" "${temp_dir}/completions"; then
        die "Failed to create temporary directories"
    fi

    # Copy main CLI
    cp "${script_dir}/bin/cac" "${temp_dir}/bin/cac"
    chmod +x "${temp_dir}/bin/cac"

    # Copy library files
    cp "${script_dir}/lib/"*.sh "${temp_dir}/lib/"

    # Copy example config (optional)
    if [[ -f "${script_dir}/.env.example" ]]; then
        cp "${script_dir}/.env.example" "${temp_dir}/.env.example"
    fi

    # Copy completions (optional)
    if [[ -d "${script_dir}/completions" ]]; then
        cp "${script_dir}/completions/"* "${temp_dir}/completions/" 2>/dev/null || true
    fi

    success "Copied local files"
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
    local libs=(config.sh security.sh tools.sh bundle.sh backend_local.sh backend_gokapi.sh utils.sh logging.sh check.sh env.sh skill.sh)
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
    if [[ "$CONFIG_DIR" == "/etc/cac" ]]; then
        chmod 755 "$CONFIG_DIR"
    else
        chmod 700 "$CONFIG_DIR"
    fi

    cp "${temp_dir}/bin/cac" "${BIN_DIR}/cac"
    chmod 755 "${BIN_DIR}/cac"

    for lib_file in "${temp_dir}/lib/"*; do
        cp "$lib_file" "${LIB_DIR}/"
    done
    chmod 644 "${LIB_DIR}/"*

    update_cli_lib_path "${BIN_DIR}/cac" "${LIB_DIR}"

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

# Setup configuration for LOCAL mode — auto-detect .env from script directory
setup_config_local() {
    local script_dir="$1"
    local env_file="${CONFIG_DIR}/.env"

    if [[ -f "$env_file" ]]; then
        info "Existing configuration found at: $env_file"
        return 0
    fi

    if [[ -n "$script_dir" && -f "${script_dir}/.env" ]]; then
        cp "${script_dir}/.env" "$env_file"
        # 644: non-root users must read /etc/cac/.env to run cac commands.
        # API keys are acceptable here because the Gokapi key is a shared
        # upload/download token, not a user-private secret.
        # See lib/config.sh:config_check_permissions() for validation.
        chmod 644 "$env_file"
        success "Copied configuration from ${script_dir}/.env to ${env_file}"
        return 0
    fi

    # No .env on USB — prompt interactively if possible
    if [[ -t 0 ]]; then
        setup_config_interactive "$env_file"
    else
        warn "No .env file found alongside install.sh."
        warn "Create ${env_file} manually before using cac."
    fi
}

# Setup configuration for PIPE mode — use CLI args, env vars, or prompt
setup_config_pipe() {
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
        chmod 644 "$env_file"
    else
        chmod 600 "$env_file"
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

# Run the full post-install pipeline (steps 2-7, local mode only)
# Each step is non-fatal — warn and continue on failure.
# Returns: 0 if all passed, 1 if any failed.
run_full_pipeline() {
    local cac_bin="${BIN_DIR}/cac"
    local total_steps=6
    local passed=0
    local failed=0

    # Step 2/7: Install AI tool environments
    echo ""
    echo "-----------------------------------"
    info "[Step 2/7] Installing AI tool environments..."
    echo "-----------------------------------"
    if "$cac_bin" env install --global --yes; then
        success "[Step 2/7] AI tool environments installed"
        ((passed++)) || true
    else
        warn "[Step 2/7] AI tool environment installation had issues (continuing)"
        ((failed++)) || true
    fi

    # Step 3/7: Pull latest config bundle
    echo ""
    echo "-----------------------------------"
    info "[Step 3/7] Pulling latest configuration bundle..."
    echo "-----------------------------------"
    if "$cac_bin" pull; then
        success "[Step 3/7] Configuration pulled"
        ((passed++)) || true
    else
        warn "[Step 3/7] Pull failed (may not have bundles yet)"
        ((failed++)) || true
    fi

    # Step 4/7: Test AI tool connectivity
    echo ""
    echo "-----------------------------------"
    info "[Step 4/7] Testing AI tool connectivity..."
    echo "-----------------------------------"
    if "$cac_bin" test; then
        success "[Step 4/7] AI tool tests passed"
        ((passed++)) || true
    else
        warn "[Step 4/7] Some AI tool tests failed (non-critical)"
        ((failed++)) || true
    fi

    # Step 5/7: Install BPM skill library
    echo ""
    echo "-----------------------------------"
    info "[Step 5/7] Installing BPM skill library..."
    echo "-----------------------------------"
    if "$cac_bin" skill install https://github.com/BPMspaceUG/bpm-claude-global-agent-skill-library.git --global --yes; then
        success "[Step 5/7] BPM skill library installed"
        ((passed++)) || true
    else
        warn "[Step 5/7] BPM skill library installation failed (continuing)"
        ((failed++)) || true
    fi

    # Step 6/7: Install ICO skill library
    echo ""
    echo "-----------------------------------"
    info "[Step 6/7] Installing ICO skill library..."
    echo "-----------------------------------"
    if "$cac_bin" skill install https://github.com/International-Certification-Org/ico-claude-global-agent-skill-library.git --global --yes; then
        success "[Step 6/7] ICO skill library installed"
        ((passed++)) || true
    else
        warn "[Step 6/7] ICO skill library installation failed (continuing)"
        ((failed++)) || true
    fi

    # Step 7/7: Install Tailscale
    echo ""
    echo "-----------------------------------"
    info "[Step 7/7] Installing Tailscale..."
    echo "-----------------------------------"
    if curl -fsSL https://tailscale.com/install.sh | sh; then
        success "[Step 7/7] Tailscale installed"
        ((passed++)) || true
    else
        warn "[Step 7/7] Tailscale installation failed (continuing)"
        ((failed++)) || true
    fi

    echo ""
    echo "-----------------------------------"
    if [[ "$failed" -eq 0 ]]; then
        success "Pipeline complete: ${passed}/${total_steps} steps passed"
    else
        warn "Pipeline complete: ${passed} passed, ${failed} failed"
    fi
    echo "-----------------------------------"

    [[ "$failed" -eq 0 ]]
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

# Perform single installation to current paths (pipe mode helper)
do_single_install() {
    local temp_dir="$1"

    install_files "$temp_dir"
    setup_config_pipe
}

# LOCAL mode installation: auto-detect everything, run full pipeline
do_install_local() {
    local script_dir="$1"

    set_system_wide_paths

    check_dependencies "true"

    echo ""
    echo "==================================="
    echo "   cac - Coding Agent Config"
    echo "   Local Installation (USB)"
    echo "==================================="
    echo ""

    # Create temp directory with safe trap
    local temp_dir=""
    trap '[[ -n "${temp_dir:-}" ]] && rm -rf "$temp_dir"' EXIT
    temp_dir=$(mktemp -d -t cac-install.XXXXXXXXXX)

    # Copy local files from USB to temp dir
    copy_local_files "$script_dir" "$temp_dir"

    # Install files to /usr/local/
    install_files "$temp_dir"

    # Setup config (auto-detect .env from script dir)
    setup_config_local "$script_dir"

    echo ""
    success "[Step 1/7] cac installed to ${BIN_DIR}/cac"

    # Run full 6-step pipeline
    local pipeline_exit=0
    run_full_pipeline || pipeline_exit=$?

    echo ""
    echo "==================================="
    if [[ "$pipeline_exit" -eq 0 ]]; then
        success "Installation complete! All steps passed."
    else
        warn "Installation complete with some failures."
    fi
    echo "==================================="
    echo ""
    echo "Configuration: ${CONFIG_DIR}/.env"
    echo ""

    return "$pipeline_exit"
}

# PIPE mode installation: download from GitHub, existing behavior
do_install_pipe() {
    # Validate mode first (checks root requirements for --global/--all)
    validate_install_mode

    check_dependencies "false"

    echo ""
    echo "==================================="
    echo "   cac - Coding Agent Config"
    echo "   Bootstrap Installer"
    echo "==================================="
    echo ""

    local version
    version=$(get_latest_version)
    info "Latest version: ${version}"

    local temp_dir=""
    trap '[[ -n "${temp_dir:-}" ]] && rm -rf "$temp_dir"' EXIT
    temp_dir=$(mktemp -d -t cac-install.XXXXXXXXXX)

    download_project "$version" "$temp_dir"
    verify_checksums "$version" "$temp_dir"

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

Options:
  --uninstall, -u        Remove cac installation
  --help, -h             Show this help message

LOCAL MODE (USB stick — auto-detects everything):
  sudo bash install.sh

  Auto-detects files alongside install.sh:
    bin/cac, lib/*.sh    Copied to /usr/local/bin and /usr/local/lib/cac/
    .env                 Copied to /etc/cac/.env
    completions/         Copied to system completion dirs

  After installation, automatically runs:
    1. cac env install --global --yes   (install AI tool environments)
    2. cac pull                         (download newest config bundle)
    3. cac test                         (verify all credentials)
    4. cac skill install <BPM-URL>      (install BPM skill library)
    5. cac skill install <ICO-URL>      (install ICO skill library)
    6. curl tailscale.com/install.sh    (install Tailscale VPN)

PIPE MODE (GitHub — backward compatible):
  curl -fsSL URL | bash -s -- [OPTIONS]

  Installation location options (pipe mode only):
    --user                 Install to ~/.local/bin only
    --global               Install to /usr/local/bin only (requires root)
    --all                  Install to both locations (requires root)
    (no flag)              Auto-detect: root→global, non-root→user

  Configuration options (pipe mode only):
    --backend, -b TYPE     Backend type: 'gokapi' or 'local'
    --url, -U URL          Gokapi server URL
    --api-key, -k KEY      Gokapi API key
    --storage, -s PATH     Local storage path

  Environment Variables:
    CAC_BACKEND          Backend type ('gokapi' or 'local')
    CAC_GOKAPI_URL       Gokapi server URL
    CAC_GOKAPI_API_KEY   Gokapi API key
    CAC_LOCAL_STORAGE    Local storage path
    CAC_ENV_INSTALL      Install AI tools after cac ('user' or 'global')

Examples:
  # Local install from USB stick (auto-detects everything)
  sudo bash /mnt/usb/install.sh

  # Remote install with Gokapi backend
  curl -fsSL URL | bash -s -- --backend gokapi --url https://gokapi.example.com --api-key SECRET

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

    # Detect mode: LOCAL (files alongside install.sh) vs PIPE (download from GitHub)
    local script_dir=""
    script_dir="$(get_script_dir 2>/dev/null || echo "")"

    if detect_local_files "$script_dir"; then
        # LOCAL mode: requires root
        if ! is_root; then
            die "Root privileges required. Run with: sudo bash install.sh"
        fi
        do_install_local "$script_dir"
    else
        # PIPE mode: existing behavior (root optional depending on --global/--all)
        do_install_pipe
    fi
}

main "$@"
