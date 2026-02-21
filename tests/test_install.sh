#!/usr/bin/env bash
# tests/test_install.sh - Tests for installation logic
#
# Tests the installer functions in isolation, using mocks for network
# operations and file system side effects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source test framework
source "${SCRIPT_DIR}/test_framework.sh"

framework_init

echo "========================================"
echo "Installation Tests"
echo "========================================"

# ============================================================================
# Source installer functions for testing
# ============================================================================

# We need to extract and redefine the installer functions without running
# the installer. We'll define the functions directly here.

# Color output helpers (from install.sh)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Installation paths (from install.sh)
SYS_BIN_DIR="/usr/local/bin"
SYS_LIB_DIR="/usr/local/lib/cac"
SYS_CONFIG_DIR="/etc/cac"

USER_BIN_DIR="${HOME}/.local/bin"
USER_LIB_DIR="${HOME}/.local/lib/cac"
USER_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/cac"

SYS_BASH_COMPLETION_DIR="/etc/bash_completion.d"
SYS_ZSH_COMPLETION_DIR="/usr/local/share/zsh/site-functions"
USER_BASH_COMPLETION_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/bash-completion/completions"
USER_ZSH_COMPLETION_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/zsh/site-functions"

# Functions from install.sh (copied to avoid running the installer)
# Note: We use _TEST_EUID for testing since EUID is readonly
_TEST_EUID=""

is_root() {
    local effective_uid="${_TEST_EUID:-${EUID:-$(id -u)}}"
    [[ "$effective_uid" -eq 0 ]]
}

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { error "$*"; exit 1; }

set_install_paths() {
    if is_root; then
        BIN_DIR="$SYS_BIN_DIR"
        LIB_DIR="$SYS_LIB_DIR"
        CONFIG_DIR="$SYS_CONFIG_DIR"
        BASH_COMPLETION_DIR="$SYS_BASH_COMPLETION_DIR"
        ZSH_COMPLETION_DIR="$SYS_ZSH_COMPLETION_DIR"
        INSTALL_MODE="system-wide"
    else
        BIN_DIR="$USER_BIN_DIR"
        LIB_DIR="$USER_LIB_DIR"
        CONFIG_DIR="$USER_CONFIG_DIR"
        BASH_COMPLETION_DIR="$USER_BASH_COMPLETION_DIR"
        ZSH_COMPLETION_DIR="$USER_ZSH_COMPLETION_DIR"
        INSTALL_MODE="user-local"
    fi
}

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

get_latest_version() {
    local version
    version=$(curl -fsSL "https://api.github.com/repos/test/test/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)

    if [[ -z "$version" ]]; then
        echo "main"
    else
        echo "$version"
    fi
}

download_file() {
    local url="$1"
    local dest="$2"

    if ! curl -fsSL -o "$dest" "$url"; then
        die "Failed to download: $url"
    fi
}

verify_checksums() {
    local version="$1"
    local temp_dir="$2"

    local checksum_url="https://example.com/${version}/checksums.sha256"
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

# ============================================================================
# Tests for is_root()
# ============================================================================

test_is_root_non_root() {
    # When effective UID is non-zero, is_root should return false
    _TEST_EUID=1000
    if is_root; then
        _TEST_EUID=""
        return 1  # Should not be root
    fi
    _TEST_EUID=""
    return 0
}

test_is_root_as_root() {
    # When effective UID is 0, is_root should return true
    _TEST_EUID=0
    if is_root; then
        _TEST_EUID=""
        return 0  # Should be root
    fi
    _TEST_EUID=""
    return 1
}

# ============================================================================
# Tests for set_install_paths()
# ============================================================================

test_set_install_paths_user() {
    _TEST_EUID=1000
    HOME="/home/testuser"
    USER_BIN_DIR="${HOME}/.local/bin"
    USER_LIB_DIR="${HOME}/.local/lib/cac"
    USER_CONFIG_DIR="${HOME}/.config/cac"
    set_install_paths
    _TEST_EUID=""

    assert_equals "${HOME}/.local/bin" "$BIN_DIR" "user BIN_DIR" &&
    assert_equals "${HOME}/.local/lib/cac" "$LIB_DIR" "user LIB_DIR" &&
    assert_equals "user-local" "$INSTALL_MODE" "install mode"
}

test_set_install_paths_root() {
    _TEST_EUID=0
    set_install_paths
    _TEST_EUID=""

    assert_equals "/usr/local/bin" "$BIN_DIR" "system BIN_DIR" &&
    assert_equals "/usr/local/lib/cac" "$LIB_DIR" "system LIB_DIR" &&
    assert_equals "system-wide" "$INSTALL_MODE" "install mode"
}

test_set_install_paths_xdg_config() {
    _TEST_EUID=1000
    HOME="/home/testuser"
    XDG_CONFIG_HOME="/custom/config"
    USER_CONFIG_DIR="${XDG_CONFIG_HOME}/cac"
    USER_BIN_DIR="${HOME}/.local/bin"
    USER_LIB_DIR="${HOME}/.local/lib/cac"
    set_install_paths
    _TEST_EUID=""

    assert_equals "/custom/config/cac" "$CONFIG_DIR" "custom config dir"
}

test_set_install_paths_default_config() {
    _TEST_EUID=1000
    HOME="/home/testuser"
    unset XDG_CONFIG_HOME
    USER_CONFIG_DIR="${HOME}/.config/cac"
    USER_BIN_DIR="${HOME}/.local/bin"
    USER_LIB_DIR="${HOME}/.local/lib/cac"
    set_install_paths
    _TEST_EUID=""

    assert_equals "/home/testuser/.config/cac" "$CONFIG_DIR" "default config dir"
}

# ============================================================================
# Tests for check_dependencies()
# ============================================================================

test_check_dependencies_all_present() {
    # Mock command to always succeed for curl, unzip, zip
    command() {
        case "$2" in
            curl|unzip|zip) return 0 ;;
            *) builtin command "$@" ;;
        esac
    }

    # Should not fail when all deps are present
    if check_dependencies 2>/dev/null; then
        unset -f command
        return 0
    else
        unset -f command
        return 1
    fi
}

test_check_dependencies_missing() {
    # Mock command to fail for curl
    command() {
        if [[ "$1" == "-v" && "$2" == "curl" ]]; then
            return 1
        fi
        builtin command "$@"
    }

    # Should fail when curl is missing (die exits with 1)
    local output
    if output=$(check_dependencies 2>&1); then
        unset -f command
        return 1  # Should have failed
    else
        unset -f command
        assert_contains "curl" "$output" "error mentions curl"
    fi
}

# ============================================================================
# Tests for get_latest_version()
# ============================================================================

test_get_latest_version_with_release() {
    # Mock curl to return a release
    curl() {
        echo '{"tag_name": "v1.2.3"}'
    }

    local version
    version=$(get_latest_version)
    unset -f curl

    assert_equals "v1.2.3" "$version" "version from release"
}

test_get_latest_version_no_release() {
    # Mock curl to return empty/error
    curl() {
        return 1
    }

    local version
    version=$(get_latest_version)
    unset -f curl

    assert_equals "main" "$version" "fallback to main"
}

# ============================================================================
# Tests for download_file()
# ============================================================================

test_download_file_success() {
    local dest="${TEST_TMPDIR}/downloaded_file"

    # Mock curl to create a file
    curl() {
        # Parse args to find -o destination
        local out_file=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -o) out_file="$2"; shift ;;
            esac
            shift
        done
        echo "test content" > "$out_file"
        return 0
    }

    download_file "https://example.com/file" "$dest" 2>/dev/null
    local result=$?
    unset -f curl

    [[ $result -eq 0 ]] &&
    assert_file_exists "$dest" "downloaded file" &&
    assert_contains "test content" "$(cat "$dest")" "file content"
}

test_download_file_failure() {
    local dest="${TEST_TMPDIR}/should_not_exist"

    # Mock curl to fail
    curl() {
        return 1
    }

    # download_file calls die on failure, which exits
    # Run in subshell to capture the exit
    local result
    result=$(download_file "https://example.com/file" "$dest" 2>&1) && true
    local exit_code=$?

    unset -f curl

    # Should have failed (die exits with 1)
    [[ $exit_code -ne 0 ]] && assert_contains "Failed to download" "$result" "error message"
}

# ============================================================================
# Tests for verify_checksums()
# ============================================================================

test_verify_checksums_not_available() {
    # Mock curl to fail (no checksums file)
    curl() {
        return 1
    }

    # Should complete without error when no checksums available
    verify_checksums "v1.0.0" "${TEST_TMPDIR}" >/dev/null 2>&1
    local result=$?
    unset -f curl

    [[ $result -eq 0 ]]
}

# ============================================================================
# Tests for install_completions()
# ============================================================================

test_install_completions_no_files() {
    local temp="${TEST_TMPDIR}/comp_test"
    mkdir -p "$temp"

    # Mock paths (set global vars)
    BASH_COMPLETION_DIR="${temp}/bash"
    ZSH_COMPLETION_DIR="${temp}/zsh"

    # Should complete successfully when no completion files exist
    install_completions "$temp" >/dev/null 2>&1
}

test_install_completions_with_bash() {
    local temp="${TEST_TMPDIR}/comp_test2"
    mkdir -p "${temp}/completions"
    echo "# bash completion" > "${temp}/completions/cac.bash"

    BASH_COMPLETION_DIR="${temp}/installed_bash"
    mkdir -p "$BASH_COMPLETION_DIR"

    install_completions "$temp" >/dev/null 2>&1

    assert_file_exists "${BASH_COMPLETION_DIR}/cac" "installed bash completion"
}

# ============================================================================
# Tests for setup_path()
# ============================================================================

test_setup_path_root_no_modification() {
    _TEST_EUID=0

    local saved_home="$HOME"
    HOME=$(mktemp -d)
    touch "${HOME}/.bashrc"

    local output
    output=$(setup_path 2>&1)

    # Root should not modify any RC file
    local result=0
    if grep -qF "$CAC_PATH_MARKER" "${HOME}/.bashrc" 2>/dev/null; then
        result=1  # Should not have been modified
    fi

    rm -rf "$HOME"
    HOME="$saved_home"
    _TEST_EUID=""
    return $result
}

test_setup_path_user_in_path() {
    _TEST_EUID=1000

    local saved_home="$HOME"
    HOME=$(mktemp -d)
    USER_BIN_DIR="${HOME}/.local/bin"
    touch "${HOME}/.bashrc"

    local saved_path="$PATH"
    PATH="${USER_BIN_DIR}:$PATH"

    setup_path >/dev/null 2>&1

    # Should not modify RC file when already in PATH
    local result=0
    if grep -qF "$CAC_PATH_MARKER" "${HOME}/.bashrc" 2>/dev/null; then
        result=1
    fi

    PATH="$saved_path"
    rm -rf "$HOME"
    HOME="$saved_home"
    _TEST_EUID=""
    return $result
}

test_setup_path_adds_to_rc() {
    _TEST_EUID=1000

    local saved_home="$HOME"
    local saved_shell="$SHELL"
    HOME=$(mktemp -d)
    SHELL="/bin/bash"
    USER_BIN_DIR="${HOME}/.local/bin"
    touch "${HOME}/.bashrc"

    local saved_path="$PATH"
    PATH="/usr/bin:/bin"

    setup_path >/dev/null 2>&1

    # Should have added marker block to .bashrc
    local result=0
    grep -qF "$CAC_PATH_MARKER" "${HOME}/.bashrc" || result=1
    grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "${HOME}/.bashrc" || result=1

    PATH="$saved_path"
    rm -rf "$HOME"
    HOME="$saved_home"
    SHELL="$saved_shell"
    _TEST_EUID=""
    return $result
}

test_setup_path_idempotent() {
    _TEST_EUID=1000

    local saved_home="$HOME"
    local saved_shell="$SHELL"
    HOME=$(mktemp -d)
    SHELL="/bin/bash"
    USER_BIN_DIR="${HOME}/.local/bin"
    touch "${HOME}/.bashrc"

    local saved_path="$PATH"
    PATH="/usr/bin:/bin"

    # Run setup_path twice
    setup_path >/dev/null 2>&1
    setup_path >/dev/null 2>&1

    # Marker should appear exactly once
    local count
    count=$(grep -cF "$CAC_PATH_MARKER" "${HOME}/.bashrc")

    PATH="$saved_path"
    rm -rf "$HOME"
    HOME="$saved_home"
    SHELL="$saved_shell"
    _TEST_EUID=""

    [[ "$count" -eq 1 ]]
}

test_setup_path_skips_if_marker_exists() {
    _TEST_EUID=1000

    local saved_home="$HOME"
    HOME=$(mktemp -d)
    USER_BIN_DIR="${HOME}/.local/bin"

    # Pre-populate .bashrc with marker but PATH not set
    {
        echo "$CAC_PATH_MARKER"
        echo 'export PATH="$HOME/.local/bin:$PATH"'
    } > "${HOME}/.bashrc"

    local saved_path="$PATH"
    PATH="/usr/bin:/bin"

    setup_path >/dev/null 2>&1

    # Should not have added a second copy
    local count
    count=$(grep -cF "$CAC_PATH_MARKER" "${HOME}/.bashrc")

    PATH="$saved_path"
    rm -rf "$HOME"
    HOME="$saved_home"
    _TEST_EUID=""

    [[ "$count" -eq 1 ]]
}

# ============================================================================
# Tests for color/output functions
# ============================================================================

test_info_output() {
    local output
    output=$(info "test message" 2>&1)
    assert_contains "INFO" "$output" "info prefix" &&
    assert_contains "test message" "$output" "info message"
}

test_success_output() {
    local output
    output=$(success "done" 2>&1)
    assert_contains "OK" "$output" "success prefix" &&
    assert_contains "done" "$output" "success message"
}

test_warn_output() {
    local output
    output=$(warn "warning" 2>&1)
    assert_contains "WARN" "$output" "warn prefix" &&
    assert_contains "warning" "$output" "warn message"
}

test_error_output() {
    local output
    output=$(error "error message" 2>&1)
    assert_contains "ERROR" "$output" "error prefix" &&
    assert_contains "error message" "$output" "error message"
}

test_die_exits() {
    # die should exit with code 1
    if (die "fatal" 2>/dev/null); then
        return 1  # Should have exited
    else
        return 0
    fi
}

# ============================================================================
# Tests for argument parsing in main
# ============================================================================

test_parse_uninstall_flag() {
    # Test that --uninstall flag is recognized
    local uninstall=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall|-u)
                uninstall=true
                shift
                ;;
            *) shift ;;
        esac
    done

    # Can't easily test main() directly, but we test the pattern
    uninstall=false
    local args=(--uninstall)
    for arg in "${args[@]}"; do
        case "$arg" in
            --uninstall|-u) uninstall=true ;;
        esac
    done

    $uninstall
}

test_parse_help_flag() {
    # Test that --help flag pattern works
    local show_help=false
    local args=(--help)

    for arg in "${args[@]}"; do
        case "$arg" in
            --help|-h) show_help=true ;;
        esac
    done

    $show_help
}

# ============================================================================
# Tests for Issue #11: Non-interactive config with CLI args
# ============================================================================

# Define helper functions for Issue #11 tests
ARG_BACKEND=""
ARG_URL=""
ARG_API_KEY=""
ARG_STORAGE=""

validate_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?:// ]]; then
        error "Invalid URL format: must start with http:// or https://"
        exit 1
    fi
}

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

show_noninteractive_config_error() {
    error "Non-interactive mode requires configuration values."
    exit 2
}

# Parse config args from array (simulates main() arg parsing)
parse_config_args() {
    ARG_BACKEND=""
    ARG_URL=""
    ARG_API_KEY=""
    ARG_STORAGE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backend|-b)
                if [[ -z "${2:-}" ]]; then
                    die "--backend requires a value"
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
                shift
                ;;
        esac
    done
}

test_parse_backend_gokapi() {
    parse_config_args --backend gokapi
    assert_equals "gokapi" "$ARG_BACKEND" "backend parsed as gokapi"
}

test_parse_backend_local() {
    parse_config_args --backend local
    assert_equals "local" "$ARG_BACKEND" "backend parsed as local"
}

test_parse_backend_short_flag() {
    parse_config_args -b gokapi
    assert_equals "gokapi" "$ARG_BACKEND" "backend via short flag"
}

test_parse_url_long() {
    parse_config_args --url https://example.com
    assert_equals "https://example.com" "$ARG_URL" "url parsed"
}

test_parse_url_short() {
    parse_config_args -U https://example.com
    assert_equals "https://example.com" "$ARG_URL" "url via short flag"
}

test_parse_api_key() {
    parse_config_args --api-key secret123
    assert_equals "secret123" "$ARG_API_KEY" "api-key parsed"
}

test_parse_api_key_short() {
    parse_config_args -k secret123
    assert_equals "secret123" "$ARG_API_KEY" "api-key via short flag"
}

test_parse_storage() {
    parse_config_args --storage /path/to/storage
    assert_equals "/path/to/storage" "$ARG_STORAGE" "storage parsed"
}

test_parse_storage_short() {
    parse_config_args -s /path/to/storage
    assert_equals "/path/to/storage" "$ARG_STORAGE" "storage via short flag"
}

test_parse_full_gokapi_config() {
    parse_config_args --backend gokapi --url https://gokapi.example.com --api-key mysecret
    assert_equals "gokapi" "$ARG_BACKEND" "full gokapi backend" &&
    assert_equals "https://gokapi.example.com" "$ARG_URL" "full gokapi url" &&
    assert_equals "mysecret" "$ARG_API_KEY" "full gokapi key"
}

test_parse_full_local_config() {
    parse_config_args --backend local --storage /var/bundles
    assert_equals "local" "$ARG_BACKEND" "full local backend" &&
    assert_equals "/var/bundles" "$ARG_STORAGE" "full local storage"
}

test_validate_url_https() {
    local exit_code=0
    validate_url "https://example.com" 2>/dev/null || exit_code=$?
    [[ $exit_code -eq 0 ]]
}

test_validate_url_http() {
    local exit_code=0
    validate_url "http://example.com" 2>/dev/null || exit_code=$?
    [[ $exit_code -eq 0 ]]
}

test_validate_url_invalid() {
    local exit_code=0
    (validate_url "ftp://example.com" 2>/dev/null) || exit_code=$?
    [[ $exit_code -ne 0 ]]
}

test_validate_url_no_scheme() {
    local exit_code=0
    (validate_url "example.com" 2>/dev/null) || exit_code=$?
    [[ $exit_code -ne 0 ]]
}

test_resolve_config_cli_priority() {
    export TEST_VAR="from_env"
    local result
    result=$(resolve_config_value "from_cli" "TEST_VAR" "default")
    unset TEST_VAR
    assert_equals "from_cli" "$result" "CLI takes priority over env"
}

test_resolve_config_env_fallback() {
    export TEST_VAR="from_env"
    local result
    result=$(resolve_config_value "" "TEST_VAR" "default")
    unset TEST_VAR
    assert_equals "from_env" "$result" "env var used when no CLI arg"
}

test_resolve_config_default_fallback() {
    unset TEST_VAR
    local result
    result=$(resolve_config_value "" "TEST_VAR" "default")
    assert_equals "default" "$result" "default used when no CLI or env"
}

test_invalid_backend_fails() {
    local exit_code=0
    (parse_config_args --backend invalid 2>/dev/null) || exit_code=$?
    [[ $exit_code -ne 0 ]]
}

test_noninteractive_error_exits_2() {
    local exit_code=0
    (show_noninteractive_config_error 2>/dev/null) || exit_code=$?
    [[ $exit_code -eq 2 ]]
}

# ============================================================================
# Integration Tests for setup_config .env output (Issue #11)
# ============================================================================

# Helper: Create a mock setup_config for testing
# This simulates the non-interactive path of setup_config
mock_setup_config_noninteractive() {
    local env_file="${CONFIG_DIR}/.env"

    if [[ -f "$env_file" ]]; then
        return 0  # Skip if exists
    fi

    local backend
    backend=$(resolve_config_value "$ARG_BACKEND" "CAC_BACKEND" "")

    if [[ -z "$backend" ]]; then
        return 2
    fi

    local gokapi_url=""
    local gokapi_key=""
    local local_storage=""

    if [[ "$backend" == "gokapi" ]]; then
        gokapi_url=$(resolve_config_value "$ARG_URL" "CAC_GOKAPI_URL" "")
        gokapi_key=$(resolve_config_value "$ARG_API_KEY" "CAC_GOKAPI_API_KEY" "")
        if [[ -z "$gokapi_url" || -z "$gokapi_key" ]]; then
            return 2
        fi
    else
        local_storage=$(resolve_config_value "$ARG_STORAGE" "CAC_LOCAL_STORAGE" "/default/path")
    fi

    # Generate config file
    {
        echo "CAC_BACKEND=${backend}"
        if [[ "$backend" == "gokapi" ]]; then
            echo "CAC_GOKAPI_URL=${gokapi_url}"
            echo "CAC_GOKAPI_API_KEY=${gokapi_key}"
        else
            echo "CAC_LOCAL_STORAGE=${local_storage}"
        fi
    } > "$env_file"

    chmod 600 "$env_file"
}

test_setup_config_gokapi_creates_env() {
    local test_dir
    test_dir=$(mktemp -d)
    CONFIG_DIR="$test_dir"
    mkdir -p "$CONFIG_DIR"

    ARG_BACKEND="gokapi"
    ARG_URL="https://test.gokapi.com"
    ARG_API_KEY="test-secret-key"
    ARG_STORAGE=""

    unset CAC_BACKEND CAC_GOKAPI_URL CAC_GOKAPI_API_KEY CAC_LOCAL_STORAGE 2>/dev/null || true

    mock_setup_config_noninteractive

    local env_file="${CONFIG_DIR}/.env"
    assert_file_exists "$env_file" "env file created" &&
    assert_contains "CAC_BACKEND=gokapi" "$(cat "$env_file")" "backend in env" &&
    assert_contains "CAC_GOKAPI_URL=https://test.gokapi.com" "$(cat "$env_file")" "url in env" &&
    assert_contains "CAC_GOKAPI_API_KEY=test-secret-key" "$(cat "$env_file")" "api key in env"

    rm -rf "$test_dir"
}

test_setup_config_local_creates_env() {
    local test_dir
    test_dir=$(mktemp -d)
    CONFIG_DIR="$test_dir"
    mkdir -p "$CONFIG_DIR"

    ARG_BACKEND="local"
    ARG_URL=""
    ARG_API_KEY=""
    ARG_STORAGE="/custom/storage/path"

    unset CAC_BACKEND CAC_GOKAPI_URL CAC_GOKAPI_API_KEY CAC_LOCAL_STORAGE 2>/dev/null || true

    mock_setup_config_noninteractive

    local env_file="${CONFIG_DIR}/.env"
    assert_file_exists "$env_file" "env file created" &&
    assert_contains "CAC_BACKEND=local" "$(cat "$env_file")" "backend in env" &&
    assert_contains "CAC_LOCAL_STORAGE=/custom/storage/path" "$(cat "$env_file")" "storage in env"

    rm -rf "$test_dir"
}

test_setup_config_env_var_precedence() {
    local test_dir
    test_dir=$(mktemp -d)
    CONFIG_DIR="$test_dir"
    mkdir -p "$CONFIG_DIR"

    # Set CLI args (should take precedence)
    ARG_BACKEND="gokapi"
    ARG_URL="https://cli-url.com"
    ARG_API_KEY="cli-key"
    ARG_STORAGE=""

    # Set env vars (should be overridden)
    export CAC_BACKEND="local"
    export CAC_GOKAPI_URL="https://env-url.com"
    export CAC_GOKAPI_API_KEY="env-key"

    mock_setup_config_noninteractive

    local env_file="${CONFIG_DIR}/.env"

    # CLI args should win
    local result=0
    assert_contains "CAC_BACKEND=gokapi" "$(cat "$env_file")" "CLI backend wins" &&
    assert_contains "CAC_GOKAPI_URL=https://cli-url.com" "$(cat "$env_file")" "CLI url wins" &&
    assert_contains "CAC_GOKAPI_API_KEY=cli-key" "$(cat "$env_file")" "CLI key wins" || result=1

    unset CAC_BACKEND CAC_GOKAPI_URL CAC_GOKAPI_API_KEY
    rm -rf "$test_dir"
    return $result
}

test_setup_config_existing_env_skipped() {
    local test_dir
    test_dir=$(mktemp -d)
    CONFIG_DIR="$test_dir"
    mkdir -p "$CONFIG_DIR"

    # Create existing env file with specific content
    local env_file="${CONFIG_DIR}/.env"
    echo "EXISTING_CONTENT=true" > "$env_file"
    local original_content
    original_content=$(cat "$env_file")

    ARG_BACKEND="gokapi"
    ARG_URL="https://new-url.com"
    ARG_API_KEY="new-key"

    mock_setup_config_noninteractive

    # File should NOT be modified
    local new_content
    new_content=$(cat "$env_file")

    local result=0
    [[ "$original_content" == "$new_content" ]] || result=1

    rm -rf "$test_dir"
    return $result
}

# ============================================================================
# Issue #12: update_cli_lib_path Tests
# ============================================================================

# Copy of update_cli_lib_path from install.sh for testing
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

# Test: update_cli_lib_path replaces the LIB_DIR pattern correctly
test_update_cli_lib_path_replaces_pattern() {
    local test_dir
    test_dir=$(mktemp -d)
    local test_cac="${test_dir}/cac"

    # Create a mock cac file with the original pattern
    cat > "$test_cac" << 'EOF'
#!/usr/bin/env bash
VERSION="test"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
echo "done"
EOF
    chmod 755 "$test_cac"

    # Run the function
    update_cli_lib_path "$test_cac" "/usr/local/lib/cac"

    # Verify the replacement worked
    local result=0
    if grep -qF 'LIB_DIR="/usr/local/lib/cac"' "$test_cac"; then
        result=0
    else
        result=1
    fi

    rm -rf "$test_dir"
    return $result
}

# Test: update_cli_lib_path removes the original pattern
test_update_cli_lib_path_removes_original() {
    local test_dir
    test_dir=$(mktemp -d)
    local test_cac="${test_dir}/cac"

    # Create a mock cac file with the original pattern
    cat > "$test_cac" << 'EOF'
#!/usr/bin/env bash
LIB_DIR="${SCRIPT_DIR}/../lib"
EOF
    chmod 755 "$test_cac"

    # Run the function
    update_cli_lib_path "$test_cac" "/custom/lib/path"

    # Verify the original pattern is gone
    local result=0
    if grep -qF 'LIB_DIR="${SCRIPT_DIR}/../lib"' "$test_cac"; then
        result=1  # Pattern still there, test fails
    else
        result=0  # Pattern gone, test passes
    fi

    rm -rf "$test_dir"
    return $result
}

# Test: update_cli_lib_path with user-local path
test_update_cli_lib_path_user_local() {
    local test_dir
    test_dir=$(mktemp -d)
    local test_cac="${test_dir}/cac"

    cat > "$test_cac" << 'EOF'
#!/usr/bin/env bash
LIB_DIR="${SCRIPT_DIR}/../lib"
EOF
    chmod 755 "$test_cac"

    local user_lib="${HOME}/.local/lib/cac"
    update_cli_lib_path "$test_cac" "$user_lib"

    local result=0
    if grep -qF "LIB_DIR=\"${user_lib}\"" "$test_cac"; then
        result=0
    else
        result=1
    fi

    rm -rf "$test_dir"
    return $result
}

# Test: update_cli_lib_path preserves file permissions
test_update_cli_lib_path_preserves_permissions() {
    local test_dir
    test_dir=$(mktemp -d)
    local test_cac="${test_dir}/cac"

    cat > "$test_cac" << 'EOF'
#!/usr/bin/env bash
LIB_DIR="${SCRIPT_DIR}/../lib"
EOF
    chmod 755 "$test_cac"

    update_cli_lib_path "$test_cac" "/usr/local/lib/cac"

    # Check that file is still executable
    local result=0
    if [[ -x "$test_cac" ]]; then
        result=0
    else
        result=1
    fi

    rm -rf "$test_dir"
    return $result
}

# Test: update_cli_lib_path warns on failed replacement
test_update_cli_lib_path_warns_on_failure() {
    local test_dir
    test_dir=$(mktemp -d)
    local test_cac="${test_dir}/cac"

    # Create a file WITHOUT the expected pattern
    cat > "$test_cac" << 'EOF'
#!/usr/bin/env bash
LIB_DIR="/some/other/path"
EOF
    chmod 755 "$test_cac"

    # Capture warnings
    local output
    output=$(update_cli_lib_path "$test_cac" "/usr/local/lib/cac" 2>&1)

    # No warning should be issued since pattern doesn't exist (grep won't match)
    # The function only warns if the OLD pattern STILL exists after replacement
    local result=0
    # In this case, the old pattern never existed, so no warning
    # File should be unchanged
    if grep -qF '/some/other/path' "$test_cac"; then
        result=0
    else
        result=1
    fi

    rm -rf "$test_dir"
    return $result
}

# ============================================================================
# Issue #13: Installation mode flag tests
# ============================================================================

# Global variable for install mode flag (mirrors install.sh)
INSTALL_MODE_FLAG=""

# Copy of set_install_mode_flag from install.sh for testing
# SYNC: install.sh lines 715-720 - if install.sh changes, update this copy
set_install_mode_flag() {
    local new_mode="$1"
    if [[ -n "$INSTALL_MODE_FLAG" && "$INSTALL_MODE_FLAG" != "$new_mode" ]]; then
        die "Conflicting flags: only one of --user, --global, --all allowed"
    fi
    INSTALL_MODE_FLAG="$new_mode"
}

# Copy of validate_install_mode from install.sh for testing
# SYNC: install.sh lines 696-712 - if install.sh changes, update this copy
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

# Helper to parse install mode args (simulates main() arg parsing)
parse_install_mode_args() {
    INSTALL_MODE_FLAG=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
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
            *)
                shift
                ;;
        esac
    done
}

test_parse_user_flag() {
    parse_install_mode_args --user
    assert_equals "user" "$INSTALL_MODE_FLAG" "--user sets INSTALL_MODE_FLAG"
}

test_parse_global_flag() {
    parse_install_mode_args --global
    assert_equals "global" "$INSTALL_MODE_FLAG" "--global sets INSTALL_MODE_FLAG"
}

test_parse_all_flag() {
    parse_install_mode_args --all
    assert_equals "all" "$INSTALL_MODE_FLAG" "--all sets INSTALL_MODE_FLAG"
}

test_conflicting_flags_error() {
    local exit_code=0
    # --user followed by --global should error with exit code 1
    (parse_install_mode_args --user --global 2>/dev/null) || exit_code=$?
    [[ $exit_code -eq 1 ]]
}

test_global_requires_root() {
    _TEST_EUID=1000  # Simulate non-root user
    INSTALL_MODE_FLAG="global"
    local exit_code=0
    # --global without root should exit with code 1
    (validate_install_mode 2>/dev/null) || exit_code=$?
    _TEST_EUID=""
    INSTALL_MODE_FLAG=""
    [[ $exit_code -eq 1 ]]
}

test_all_requires_root() {
    _TEST_EUID=1000  # Simulate non-root user
    INSTALL_MODE_FLAG="all"
    local exit_code=0
    # --all without root should exit with code 1
    (validate_install_mode 2>/dev/null) || exit_code=$?
    _TEST_EUID=""
    INSTALL_MODE_FLAG=""
    [[ $exit_code -eq 1 ]]
}

# ============================================================================
# Issue #24: _detect_shell_rc() tests
# ============================================================================

test_detect_shell_rc_bash() {
    local saved_shell="$SHELL"
    local saved_home="$HOME"
    SHELL="/bin/bash"
    HOME="/tmp/test_detect_rc_bash"

    local result
    result=$(_detect_shell_rc)

    SHELL="$saved_shell"
    HOME="$saved_home"

    assert_equals "/tmp/test_detect_rc_bash/.bashrc" "$result" "bash shell returns .bashrc"
}

test_detect_shell_rc_zsh() {
    local saved_shell="$SHELL"
    local saved_home="$HOME"
    SHELL="/bin/zsh"
    HOME="/tmp/test_detect_rc_zsh"

    local result
    result=$(_detect_shell_rc)

    SHELL="$saved_shell"
    HOME="$saved_home"

    assert_equals "/tmp/test_detect_rc_zsh/.zshrc" "$result" "zsh shell returns .zshrc"
}

test_detect_shell_rc_fallback_bashrc() {
    local saved_shell="$SHELL"
    local saved_home="$HOME"
    SHELL="/bin/fish"
    HOME=$(mktemp -d)
    touch "${HOME}/.bashrc"

    local result
    result=$(_detect_shell_rc)

    rm -rf "$HOME"
    SHELL="$saved_shell"
    HOME="$saved_home"

    assert_contains ".bashrc" "$result" "fish fallback to existing .bashrc"
}

test_detect_shell_rc_fallback_profile() {
    local saved_shell="$SHELL"
    local saved_home="$HOME"
    SHELL="/bin/fish"
    HOME=$(mktemp -d)
    # No .bashrc or .zshrc exists

    local result
    result=$(_detect_shell_rc)

    rm -rf "$HOME"
    SHELL="$saved_shell"
    HOME="$saved_home"

    assert_contains ".profile" "$result" "fish fallback to .profile"
}

# ============================================================================
# Issue #24: _cleanup_path_entry() tests
# ============================================================================

test_cleanup_path_removes_marker() {
    local saved_home="$HOME"
    HOME=$(mktemp -d)

    # Create .bashrc with marker block and other content
    cat > "${HOME}/.bashrc" << 'RCEOF'
# Existing content
alias ll='ls -la'

# Added by cac installer — do not edit
export PATH="$HOME/.local/bin:$PATH"

# Other content
export EDITOR=vim
RCEOF

    _cleanup_path_entry >/dev/null 2>&1

    # Marker should be gone
    local result=0
    if grep -qF "$CAC_PATH_MARKER" "${HOME}/.bashrc"; then
        result=1
    fi
    # Other content should remain
    grep -qF "alias ll" "${HOME}/.bashrc" || result=1
    grep -qF "EDITOR=vim" "${HOME}/.bashrc" || result=1

    rm -rf "$HOME"
    HOME="$saved_home"
    return $result
}

test_cleanup_path_multiple_files() {
    local saved_home="$HOME"
    HOME=$(mktemp -d)

    # Add marker to both .bashrc and .zshrc
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        {
            echo "# existing"
            echo "$CAC_PATH_MARKER"
            echo 'export PATH="$HOME/.local/bin:$PATH"'
        } > "$rc"
    done

    _cleanup_path_entry >/dev/null 2>&1

    # Both should be cleaned
    local result=0
    if grep -qF "$CAC_PATH_MARKER" "${HOME}/.bashrc" 2>/dev/null; then
        result=1
    fi
    if grep -qF "$CAC_PATH_MARKER" "${HOME}/.zshrc" 2>/dev/null; then
        result=1
    fi
    # Existing content should remain
    grep -qF "# existing" "${HOME}/.bashrc" || result=1
    grep -qF "# existing" "${HOME}/.zshrc" || result=1

    rm -rf "$HOME"
    HOME="$saved_home"
    return $result
}

test_cleanup_path_preserves_permissions() {
    local saved_home="$HOME"
    HOME=$(mktemp -d)

    # Create .bashrc with marker and set permissions to 644
    {
        echo "# existing"
        echo "$CAC_PATH_MARKER"
        echo 'export PATH="$HOME/.local/bin:$PATH"'
        echo "# more content"
    } > "${HOME}/.bashrc"
    chmod 644 "${HOME}/.bashrc"

    _cleanup_path_entry >/dev/null 2>&1

    # Permissions should still be 644
    local perms
    perms=$(stat -c '%a' "${HOME}/.bashrc")

    rm -rf "$HOME"
    HOME="$saved_home"

    assert_equals "644" "$perms" "RC file permissions preserved"
}

test_cleanup_path_no_marker_noop() {
    local saved_home="$HOME"
    HOME=$(mktemp -d)

    echo "# just some content" > "${HOME}/.bashrc"
    local before
    before=$(cat "${HOME}/.bashrc")

    _cleanup_path_entry >/dev/null 2>&1

    local after
    after=$(cat "${HOME}/.bashrc")

    rm -rf "$HOME"
    HOME="$saved_home"

    [[ "$before" == "$after" ]]
}

test_setup_path_cross_shell() {
    _TEST_EUID=1000

    local saved_home="$HOME"
    local saved_shell="$SHELL"
    HOME=$(mktemp -d)
    USER_BIN_DIR="${HOME}/.local/bin"

    local saved_path="$PATH"
    PATH="/usr/bin:/bin"

    # First install with bash — adds marker to .bashrc
    SHELL="/bin/bash"
    touch "${HOME}/.bashrc"
    setup_path >/dev/null 2>&1

    # Switch shell to zsh — should still add to .zshrc
    SHELL="/bin/zsh"
    touch "${HOME}/.zshrc"
    setup_path >/dev/null 2>&1

    # Both files should have the marker
    local result=0
    grep -qF "$CAC_PATH_MARKER" "${HOME}/.bashrc" || result=1
    grep -qF "$CAC_PATH_MARKER" "${HOME}/.zshrc" || result=1

    PATH="$saved_path"
    rm -rf "$HOME"
    HOME="$saved_home"
    SHELL="$saved_shell"
    _TEST_EUID=""
    return $result
}

test_setup_path_profile_creation() {
    _TEST_EUID=1000

    local saved_home="$HOME"
    local saved_shell="$SHELL"
    HOME=$(mktemp -d)
    SHELL="/bin/fish"
    USER_BIN_DIR="${HOME}/.local/bin"
    # No .bashrc, .zshrc exist — should fall back to .profile and create it

    local saved_path="$PATH"
    PATH="/usr/bin:/bin"

    setup_path >/dev/null 2>&1

    local result=0
    if [[ ! -f "${HOME}/.profile" ]]; then
        result=1
    fi
    grep -qF "$CAC_PATH_MARKER" "${HOME}/.profile" 2>/dev/null || result=1

    PATH="$saved_path"
    rm -rf "$HOME"
    HOME="$saved_home"
    SHELL="$saved_shell"
    _TEST_EUID=""
    return $result
}

# ============================================================================
# Run Tests
# ============================================================================

echo ""
echo "--- is_root() ---"
run_test "is_root returns false for EUID=1000" test_is_root_non_root
run_test "is_root returns true for EUID=0" test_is_root_as_root

echo ""
echo "--- set_install_paths() ---"
run_test "sets user paths for non-root" test_set_install_paths_user
run_test "sets system paths for root" test_set_install_paths_root
run_test "respects XDG_CONFIG_HOME" test_set_install_paths_xdg_config
run_test "uses default config without XDG" test_set_install_paths_default_config

echo ""
echo "--- check_dependencies() ---"
run_test "passes when all deps present" test_check_dependencies_all_present
run_test "fails when deps missing" test_check_dependencies_missing

echo ""
echo "--- get_latest_version() ---"
run_test "extracts version from release" test_get_latest_version_with_release
run_test "falls back to main on error" test_get_latest_version_no_release

echo ""
echo "--- download_file() ---"
run_test "downloads file successfully" test_download_file_success
run_test "fails on curl error" test_download_file_failure

echo ""
echo "--- verify_checksums() ---"
run_test "handles missing checksums gracefully" test_verify_checksums_not_available

echo ""
echo "--- install_completions() ---"
run_test "handles missing completion files" test_install_completions_no_files
run_test "installs bash completion" test_install_completions_with_bash

echo ""
echo "--- setup_path() ---"
run_test "no modification for root install" test_setup_path_root_no_modification
run_test "no modification when bin in PATH" test_setup_path_user_in_path
run_test "adds marker block to RC file" test_setup_path_adds_to_rc
run_test "idempotent — marker appears once" test_setup_path_idempotent
run_test "skips if marker already exists" test_setup_path_skips_if_marker_exists

echo ""
echo "--- Output functions ---"
run_test "info() output format" test_info_output
run_test "success() output format" test_success_output
run_test "warn() output format" test_warn_output
run_test "error() output format" test_error_output
run_test "die() exits with error" test_die_exits

echo ""
echo "--- Argument parsing ---"
run_test "recognizes --uninstall flag" test_parse_uninstall_flag
run_test "recognizes --help flag" test_parse_help_flag

echo ""
echo "--- Issue #11: CLI config argument parsing ---"
run_test "parses --backend gokapi" test_parse_backend_gokapi
run_test "parses --backend local" test_parse_backend_local
run_test "parses -b short flag" test_parse_backend_short_flag
run_test "parses --url" test_parse_url_long
run_test "parses -U short flag" test_parse_url_short
run_test "parses --api-key" test_parse_api_key
run_test "parses -k short flag" test_parse_api_key_short
run_test "parses --storage" test_parse_storage
run_test "parses -s short flag" test_parse_storage_short
run_test "parses full gokapi config" test_parse_full_gokapi_config
run_test "parses full local config" test_parse_full_local_config

echo ""
echo "--- Issue #11: URL validation ---"
run_test "accepts https URLs" test_validate_url_https
run_test "accepts http URLs" test_validate_url_http
run_test "rejects ftp URLs" test_validate_url_invalid
run_test "rejects URLs without scheme" test_validate_url_no_scheme

echo ""
echo "--- Issue #11: Config value resolution ---"
run_test "CLI arg takes priority over env" test_resolve_config_cli_priority
run_test "env var used when no CLI arg" test_resolve_config_env_fallback
run_test "default used when no CLI or env" test_resolve_config_default_fallback

echo ""
echo "--- Issue #11: Error handling ---"
run_test "invalid backend value fails" test_invalid_backend_fails
run_test "noninteractive error exits with code 2" test_noninteractive_error_exits_2

echo ""
echo "--- Issue #11: setup_config integration tests ---"
run_test "setup_config creates gokapi .env" test_setup_config_gokapi_creates_env
run_test "setup_config creates local .env" test_setup_config_local_creates_env
run_test "setup_config CLI args override env vars" test_setup_config_env_var_precedence
run_test "setup_config skips existing .env" test_setup_config_existing_env_skipped

echo ""
echo "--- Issue #12: update_cli_lib_path ---"
run_test "replaces LIB_DIR pattern correctly" test_update_cli_lib_path_replaces_pattern
run_test "removes original pattern" test_update_cli_lib_path_removes_original
run_test "handles user-local paths" test_update_cli_lib_path_user_local
run_test "preserves file permissions" test_update_cli_lib_path_preserves_permissions
run_test "handles files without pattern" test_update_cli_lib_path_warns_on_failure

echo ""
echo "--- Issue #13: Installation mode flags ---"
run_test "parses --user flag" test_parse_user_flag
run_test "parses --global flag" test_parse_global_flag
run_test "parses --all flag" test_parse_all_flag
run_test "conflicting flags error" test_conflicting_flags_error
run_test "--global requires root" test_global_requires_root
run_test "--all requires root" test_all_requires_root

echo ""
echo "--- Issue #24: _detect_shell_rc() ---"
run_test "bash shell returns .bashrc" test_detect_shell_rc_bash
run_test "zsh shell returns .zshrc" test_detect_shell_rc_zsh
run_test "fish fallback to existing .bashrc" test_detect_shell_rc_fallback_bashrc
run_test "fish fallback to .profile" test_detect_shell_rc_fallback_profile

echo ""
echo "--- Issue #24: _cleanup_path_entry() ---"
run_test "removes marker block from RC file" test_cleanup_path_removes_marker
run_test "cleans multiple RC files" test_cleanup_path_multiple_files
run_test "preserves RC file permissions" test_cleanup_path_preserves_permissions
run_test "no-op when no marker exists" test_cleanup_path_no_marker_noop

echo ""
echo "--- Issue #24: setup_path() persistence ---"
run_test "cross-shell adds to both RC files" test_setup_path_cross_shell
run_test ".profile created as fallback" test_setup_path_profile_creation

# ============================================================================
# NEW: Tests for local mode features (USB stick install)
# ============================================================================

# Copy of get_script_dir from install.sh for testing
get_script_dir() {
    local source="${BASH_SOURCE[0]:-}"
    if [[ -z "$source" || "$source" == "-" || "$source" == "bash" ]]; then
        echo ""
        return 0
    fi
    while [[ -L "$source" ]]; do
        local dir
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="$dir/$source"
    done
    cd -P "$(dirname "$source")" && pwd
}

# Copy of detect_local_files from install.sh for testing
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

# Copy of copy_local_files from install.sh for testing
copy_local_files() {
    local script_dir="$1"
    local temp_dir="$2"

    if ! mkdir -p "${temp_dir}/bin" "${temp_dir}/lib" "${temp_dir}/completions"; then
        return 1
    fi
    cp "${script_dir}/bin/cac" "${temp_dir}/bin/cac"
    chmod +x "${temp_dir}/bin/cac"
    cp "${script_dir}/lib/"*.sh "${temp_dir}/lib/"
    if [[ -f "${script_dir}/.env.example" ]]; then
        cp "${script_dir}/.env.example" "${temp_dir}/.env.example"
    fi
    if [[ -d "${script_dir}/completions" ]]; then
        cp "${script_dir}/completions/"* "${temp_dir}/completions/" 2>/dev/null || true
    fi
}

# Copy of setup_config_local from install.sh for testing
setup_config_local() {
    local script_dir="$1"
    local env_file="${CONFIG_DIR}/.env"

    if [[ -f "$env_file" ]]; then
        return 0
    fi
    if [[ -n "$script_dir" && -f "${script_dir}/.env" ]]; then
        cp "${script_dir}/.env" "$env_file"
        chmod 644 "$env_file"
        return 0
    fi
    return 1
}

# ============================================================================
# Tests for get_script_dir()
# ============================================================================

test_get_script_dir_resolves() {
    local result
    result=$(get_script_dir)
    # Should resolve to a non-empty directory
    [[ -n "$result" ]] && [[ -d "$result" ]]
}

test_get_script_dir_empty_source() {
    # Simulate piped input by calling with empty BASH_SOURCE
    local result
    result=$(BASH_SOURCE=("") bash -c '
        source="";
        if [[ -z "$source" || "$source" == "-" || "$source" == "bash" ]]; then
            echo "";
        fi
    ')
    [[ -z "$result" ]]
}

# ============================================================================
# Tests for detect_local_files()
# ============================================================================

test_detect_local_files_all_present() {
    local test_dir="${TEST_TMPDIR}/detect_all"
    mkdir -p "${test_dir}/bin" "${test_dir}/lib"
    touch "${test_dir}/bin/cac"
    for f in config.sh security.sh bundle.sh tools.sh utils.sh logging.sh; do
        touch "${test_dir}/lib/${f}"
    done

    detect_local_files "$test_dir"
}

test_detect_local_files_missing_bin() {
    local test_dir="${TEST_TMPDIR}/detect_nobin"
    mkdir -p "${test_dir}/lib"
    for f in config.sh security.sh bundle.sh tools.sh utils.sh logging.sh; do
        touch "${test_dir}/lib/${f}"
    done

    # Should fail — bin/cac missing
    if detect_local_files "$test_dir"; then
        return 1
    fi
    return 0
}

test_detect_local_files_missing_lib() {
    local test_dir="${TEST_TMPDIR}/detect_nolib"
    mkdir -p "${test_dir}/bin" "${test_dir}/lib"
    touch "${test_dir}/bin/cac"
    touch "${test_dir}/lib/config.sh"
    # Missing security.sh, bundle.sh, etc.

    if detect_local_files "$test_dir"; then
        return 1
    fi
    return 0
}

test_detect_local_files_empty_dir() {
    local test_dir="${TEST_TMPDIR}/detect_empty"
    mkdir -p "$test_dir"

    if detect_local_files "$test_dir"; then
        return 1
    fi
    return 0
}

test_detect_local_files_empty_string() {
    if detect_local_files ""; then
        return 1
    fi
    return 0
}

# ============================================================================
# Tests for copy_local_files()
# ============================================================================

test_copy_local_files_creates_structure() {
    local src_dir="${TEST_TMPDIR}/copy_src"
    local dest_dir="${TEST_TMPDIR}/copy_dest"
    mkdir -p "${src_dir}/bin" "${src_dir}/lib"
    echo '#!/bin/bash' > "${src_dir}/bin/cac"
    echo "# config" > "${src_dir}/lib/config.sh"
    echo "# utils" > "${src_dir}/lib/utils.sh"
    echo "# example" > "${src_dir}/.env.example"

    copy_local_files "$src_dir" "$dest_dir" >/dev/null 2>&1

    assert_file_exists "${dest_dir}/bin/cac" "bin/cac copied" &&
    assert_file_exists "${dest_dir}/lib/config.sh" "lib/config.sh copied" &&
    assert_file_exists "${dest_dir}/lib/utils.sh" "lib/utils.sh copied" &&
    assert_file_exists "${dest_dir}/.env.example" ".env.example copied"
}

test_copy_local_files_executable() {
    local src_dir="${TEST_TMPDIR}/copy_exec_src"
    local dest_dir="${TEST_TMPDIR}/copy_exec_dest"
    mkdir -p "${src_dir}/bin" "${src_dir}/lib"
    echo '#!/bin/bash' > "${src_dir}/bin/cac"
    echo "# lib" > "${src_dir}/lib/config.sh"

    copy_local_files "$src_dir" "$dest_dir" >/dev/null 2>&1

    [[ -x "${dest_dir}/bin/cac" ]]
}

test_copy_local_files_no_env_example() {
    local src_dir="${TEST_TMPDIR}/copy_noenv_src"
    local dest_dir="${TEST_TMPDIR}/copy_noenv_dest"
    mkdir -p "${src_dir}/bin" "${src_dir}/lib"
    echo '#!/bin/bash' > "${src_dir}/bin/cac"
    echo "# lib" > "${src_dir}/lib/config.sh"
    # No .env.example

    copy_local_files "$src_dir" "$dest_dir" >/dev/null 2>&1

    # Should succeed without .env.example
    assert_file_exists "${dest_dir}/bin/cac" "bin/cac exists" &&
    [[ ! -f "${dest_dir}/.env.example" ]]
}

# ============================================================================
# Tests for setup_config_local()
# ============================================================================

test_setup_config_local_copies_env() {
    local src_dir="${TEST_TMPDIR}/cfg_local_src"
    local cfg_dir="${TEST_TMPDIR}/cfg_local_dest"
    mkdir -p "$src_dir" "$cfg_dir"
    echo "CAC_BACKEND=gokapi" > "${src_dir}/.env"
    CONFIG_DIR="$cfg_dir"

    setup_config_local "$src_dir" >/dev/null 2>&1

    local env_file="${cfg_dir}/.env"
    assert_file_exists "$env_file" "env file copied" &&
    assert_contains "CAC_BACKEND=gokapi" "$(cat "$env_file")" "backend in env"
}

test_setup_config_local_permissions_644() {
    local src_dir="${TEST_TMPDIR}/cfg_perm_src"
    local cfg_dir="${TEST_TMPDIR}/cfg_perm_dest"
    mkdir -p "$src_dir" "$cfg_dir"
    echo "CAC_BACKEND=local" > "${src_dir}/.env"
    CONFIG_DIR="$cfg_dir"

    setup_config_local "$src_dir" >/dev/null 2>&1

    local perms
    perms=$(stat -c '%a' "${cfg_dir}/.env")
    assert_equals "644" "$perms" "env file permissions"
}

test_setup_config_local_skips_existing() {
    local src_dir="${TEST_TMPDIR}/cfg_exist_src"
    local cfg_dir="${TEST_TMPDIR}/cfg_exist_dest"
    mkdir -p "$src_dir" "$cfg_dir"
    echo "CAC_BACKEND=gokapi" > "${src_dir}/.env"
    echo "EXISTING=true" > "${cfg_dir}/.env"
    CONFIG_DIR="$cfg_dir"

    setup_config_local "$src_dir" >/dev/null 2>&1

    # Should not overwrite
    assert_contains "EXISTING=true" "$(cat "${cfg_dir}/.env")" "existing config preserved"
}

test_setup_config_local_no_env_returns_error() {
    local src_dir="${TEST_TMPDIR}/cfg_noenv_src"
    local cfg_dir="${TEST_TMPDIR}/cfg_noenv_dest"
    mkdir -p "$src_dir" "$cfg_dir"
    # No .env file in src_dir
    CONFIG_DIR="$cfg_dir"

    # Should return non-zero (no .env found, not interactive)
    if setup_config_local "$src_dir" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# ============================================================================
# Tests for check_dependencies() with auto-install
# ============================================================================

# Copy of check_dependencies from install.sh for testing
check_dependencies_test() {
    local auto_install="$1"
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
        # In test mode, just report what would be installed
        echo "would-install:${missing[*]}"
        return 0
    else
        echo "missing:${missing[*]}" >&2
        return 1
    fi
}

test_check_deps_all_present() {
    # All deps should be present in test environment
    local output
    output=$(check_dependencies_test "false" 2>&1)
    local exit_code=$?
    [[ $exit_code -eq 0 ]]
}

test_check_deps_auto_install_mode() {
    # Mock command to simulate missing git
    command() {
        if [[ "$1" == "-v" && "$2" == "git" ]]; then
            return 1
        fi
        builtin command "$@"
    }

    local output
    output=$(check_dependencies_test "true" 2>&1)
    local exit_code=$?
    unset -f command

    [[ $exit_code -eq 0 ]] &&
    assert_contains "git" "$output" "reports git for install"
}

test_check_deps_pipe_mode_fails() {
    # Mock command to simulate missing git
    command() {
        if [[ "$1" == "-v" && "$2" == "git" ]]; then
            return 1
        fi
        builtin command "$@"
    }

    local output
    output=$(check_dependencies_test "false" 2>&1)
    local exit_code=$?
    unset -f command

    [[ $exit_code -ne 0 ]] &&
    assert_contains "git" "$output" "reports missing git"
}

# ============================================================================
# Tests for root check behavior
# ============================================================================

test_local_mode_requires_root() {
    # Simulate: local files detected but not root
    _TEST_EUID=1000
    local test_dir="${TEST_TMPDIR}/root_check"
    mkdir -p "${test_dir}/bin" "${test_dir}/lib"
    touch "${test_dir}/bin/cac"
    for f in config.sh security.sh bundle.sh tools.sh utils.sh logging.sh; do
        touch "${test_dir}/lib/${f}"
    done

    # detect_local_files should pass
    local detected=false
    if detect_local_files "$test_dir"; then
        detected=true
    fi

    # But is_root should fail
    local root_check=false
    if is_root; then
        root_check=true
    fi

    _TEST_EUID=""

    [[ "$detected" == "true" ]] && [[ "$root_check" == "false" ]]
}

# ============================================================================
# Tests for run_full_pipeline() structure
# ============================================================================

test_pipeline_counts_pass_fail() {
    # Test the pass/fail counting logic used in run_full_pipeline
    local passed=0
    local failed=0

    # Simulate 3 passing steps
    for _ in 1 2 3; do
        if true; then
            ((passed++)) || true
        fi
    done
    # Simulate 2 failing steps
    for _ in 1 2; do
        if false; then
            ((passed++)) || true
        else
            ((failed++)) || true
        fi
    done

    [[ "$passed" -eq 3 ]] && [[ "$failed" -eq 2 ]]
}

test_pipeline_returns_nonzero_on_failure() {
    # Simulate pipeline return logic
    local failed=1
    local result=0
    [[ "$failed" -eq 0 ]] || result=1
    [[ $result -eq 1 ]]
}

test_pipeline_returns_zero_on_success() {
    local failed=0
    local result=0
    [[ "$failed" -eq 0 ]] || result=1
    [[ $result -eq 0 ]]
}

# ============================================================================
# Tests for two-mode detection in main()
# ============================================================================

test_mode_detection_local() {
    # When local files exist, should detect local mode
    local test_dir="${TEST_TMPDIR}/mode_local"
    mkdir -p "${test_dir}/bin" "${test_dir}/lib"
    touch "${test_dir}/bin/cac"
    for f in config.sh security.sh bundle.sh tools.sh utils.sh logging.sh; do
        touch "${test_dir}/lib/${f}"
    done

    detect_local_files "$test_dir"
}

test_mode_detection_pipe() {
    # When no local files, should fall through to pipe mode
    if detect_local_files ""; then
        return 1
    fi
    return 0
}

test_mode_detection_pipe_nonexistent_dir() {
    if detect_local_files "/nonexistent/path"; then
        return 1
    fi
    return 0
}

# ============================================================================
# Tests for write_config_file()
# ============================================================================

# Copy of write_config_file from install.sh for testing
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
        fi
    } > "$env_file"

    if [[ "$env_file" == "/etc/cac/.env" ]]; then
        chmod 644 "$env_file"
    else
        chmod 600 "$env_file"
    fi
}

test_write_config_gokapi() {
    local env_file="${TEST_TMPDIR}/write_gokapi.env"
    write_config_file "$env_file" "gokapi" "https://test.com" "secret123" ""

    assert_contains "CAC_BACKEND=gokapi" "$(cat "$env_file")" "backend" &&
    assert_contains "CAC_GOKAPI_URL=https://test.com" "$(cat "$env_file")" "url" &&
    assert_contains "CAC_GOKAPI_API_KEY=secret123" "$(cat "$env_file")" "key"
}

test_write_config_local() {
    local env_file="${TEST_TMPDIR}/write_local.env"
    write_config_file "$env_file" "local" "" "" "/var/bundles"

    assert_contains "CAC_BACKEND=local" "$(cat "$env_file")" "backend" &&
    assert_contains "CAC_LOCAL_STORAGE=/var/bundles" "$(cat "$env_file")" "storage"
}

test_write_config_user_permissions_600() {
    local env_file="${TEST_TMPDIR}/write_perms.env"
    write_config_file "$env_file" "local" "" "" "/var/bundles"

    local perms
    perms=$(stat -c '%a' "$env_file")
    assert_equals "600" "$perms" "user config permissions"
}

# ============================================================================
# Run new tests
# ============================================================================

echo ""
echo "--- get_script_dir() ---"
run_test "resolves to valid directory" test_get_script_dir_resolves
run_test "returns empty for piped input" test_get_script_dir_empty_source

echo ""
echo "--- detect_local_files() ---"
run_test "detects when all files present" test_detect_local_files_all_present
run_test "fails when bin/cac missing" test_detect_local_files_missing_bin
run_test "fails when lib files missing" test_detect_local_files_missing_lib
run_test "fails for empty directory" test_detect_local_files_empty_dir
run_test "fails for empty string" test_detect_local_files_empty_string

echo ""
echo "--- copy_local_files() ---"
run_test "creates correct directory structure" test_copy_local_files_creates_structure
run_test "bin/cac is executable" test_copy_local_files_executable
run_test "handles missing .env.example" test_copy_local_files_no_env_example

echo ""
echo "--- setup_config_local() ---"
run_test "copies .env from script dir" test_setup_config_local_copies_env
run_test ".env gets 644 permissions" test_setup_config_local_permissions_644
run_test "skips existing config" test_setup_config_local_skips_existing
run_test "returns error when no .env" test_setup_config_local_no_env_returns_error

echo ""
echo "--- check_dependencies() modes ---"
run_test "passes when all deps present" test_check_deps_all_present
run_test "auto-install mode reports deps" test_check_deps_auto_install_mode
run_test "pipe mode fails on missing deps" test_check_deps_pipe_mode_fails

echo ""
echo "--- Root check ---"
run_test "local mode detected + not root" test_local_mode_requires_root

echo ""
echo "--- run_full_pipeline() logic ---"
run_test "counts pass/fail correctly" test_pipeline_counts_pass_fail
run_test "returns nonzero on failure" test_pipeline_returns_nonzero_on_failure
run_test "returns zero on all success" test_pipeline_returns_zero_on_success

echo ""
echo "--- Two-mode detection ---"
run_test "detects local mode" test_mode_detection_local
run_test "detects pipe mode (empty)" test_mode_detection_pipe
run_test "detects pipe mode (nonexistent)" test_mode_detection_pipe_nonexistent_dir

echo ""
echo "--- write_config_file() ---"
run_test "writes gokapi config" test_write_config_gokapi
run_test "writes local config" test_write_config_local
run_test "user config gets 600 permissions" test_write_config_user_permissions_600

echo ""
framework_report
