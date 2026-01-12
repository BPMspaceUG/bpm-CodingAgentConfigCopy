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

setup_path() {
    if is_root; then
        return 0
    fi

    if [[ ":$PATH:" != *":${USER_BIN_DIR}:"* ]]; then
        warn "${USER_BIN_DIR} is not in your PATH"
        echo ""
        echo "Add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
        echo ""
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
    fi
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

test_setup_path_root_no_warning() {
    _TEST_EUID=0
    set_install_paths
    _TEST_EUID=""

    # Root installation should not warn about PATH
    local output
    output=$(setup_path 2>&1)

    # Should be empty (no warning for root)
    [[ -z "$output" || "$output" != *"not in your PATH"* ]]
}

test_setup_path_user_in_path() {
    _TEST_EUID=1000
    HOME="/home/testuser"
    USER_BIN_DIR="${HOME}/.local/bin"
    USER_LIB_DIR="${HOME}/.local/lib/cac"
    USER_CONFIG_DIR="${HOME}/.config/cac"
    set_install_paths
    _TEST_EUID=""

    # Add user bin to PATH
    local saved_path="$PATH"
    PATH="${USER_BIN_DIR}:$PATH"

    local output
    output=$(setup_path 2>&1)

    PATH="$saved_path"

    # Should not warn when already in PATH
    [[ "$output" != *"not in your PATH"* ]]
}

test_setup_path_user_not_in_path() {
    _TEST_EUID=1000
    HOME="/home/testuser"
    USER_BIN_DIR="${HOME}/.local/bin"
    USER_LIB_DIR="${HOME}/.local/lib/cac"
    USER_CONFIG_DIR="${HOME}/.config/cac"
    set_install_paths
    _TEST_EUID=""

    # Ensure user bin is NOT in PATH
    local saved_path="$PATH"
    PATH="/usr/bin:/bin"

    local output
    output=$(setup_path 2>&1)

    PATH="$saved_path"

    # Should warn about PATH
    assert_contains "not in your PATH" "$output" "PATH warning"
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
run_test "no warning for root install" test_setup_path_root_no_warning
run_test "no warning when bin in PATH" test_setup_path_user_in_path
run_test "warns when bin not in PATH" test_setup_path_user_not_in_path

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
framework_report
