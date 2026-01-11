#!/usr/bin/env bash
# uninstall.sh - Uninstaller for cac (Coding Agent Config)
# Removes cac CLI and optionally configuration files
#
# Usage:
#   ./uninstall.sh
#   ./uninstall.sh --purge   # Also remove configuration

set -euo pipefail

# Installation paths
SYS_BIN_DIR="/usr/local/bin"
SYS_LIB_DIR="/usr/local/lib/cac"
SYS_CONFIG_DIR="/etc/cac"

USER_BIN_DIR="${HOME}/.local/bin"
USER_LIB_DIR="${HOME}/.local/lib/cac"
USER_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/cac"

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

# Determine if running as root
is_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

# Remove directory if it exists
remove_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        success "Removed: $dir"
        return 0
    fi
    return 1
}

# Remove file if it exists
remove_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        rm -f "$file"
        success "Removed: $file"
        return 0
    fi
    return 1
}

# Uninstall from system-wide location
uninstall_system() {
    local removed=0

    remove_file "${SYS_BIN_DIR}/cac" && ((removed++))
    remove_dir "$SYS_LIB_DIR" && ((removed++))

    if $PURGE; then
        remove_dir "$SYS_CONFIG_DIR" && ((removed++))
    elif [[ -d "$SYS_CONFIG_DIR" ]]; then
        warn "Configuration preserved: ${SYS_CONFIG_DIR}"
        info "Use --purge to remove, or: rm -rf ${SYS_CONFIG_DIR}"
    fi

    echo "$removed"
}

# Uninstall from user-local location
uninstall_user() {
    local removed=0

    remove_file "${USER_BIN_DIR}/cac" && ((removed++))
    remove_dir "$USER_LIB_DIR" && ((removed++))

    if $PURGE; then
        remove_dir "$USER_CONFIG_DIR" && ((removed++))
    elif [[ -d "$USER_CONFIG_DIR" ]]; then
        warn "Configuration preserved: ${USER_CONFIG_DIR}"
        info "Use --purge to remove, or: rm -rf ${USER_CONFIG_DIR}"
    fi

    echo "$removed"
}

# Main uninstall logic
do_uninstall() {
    echo ""
    echo "==================================="
    echo "   cac - Coding Agent Config"
    echo "   Uninstaller"
    echo "==================================="
    echo ""

    local total_removed=0
    local locations_checked=0

    # Check system-wide installation (if root or files are readable)
    if is_root || [[ -f "${SYS_BIN_DIR}/cac" ]] || [[ -d "$SYS_LIB_DIR" ]]; then
        if is_root; then
            info "Checking system-wide installation..."
            local sys_removed
            sys_removed=$(uninstall_system)
            total_removed=$((total_removed + sys_removed))
            ((locations_checked++))
        elif [[ -f "${SYS_BIN_DIR}/cac" ]] || [[ -d "$SYS_LIB_DIR" ]]; then
            warn "System-wide installation found but running as non-root"
            info "Run as root to remove: sudo ./uninstall.sh"
        fi
    fi

    # Check user-local installation
    if [[ -f "${USER_BIN_DIR}/cac" ]] || [[ -d "$USER_LIB_DIR" ]] || [[ -d "$USER_CONFIG_DIR" ]]; then
        info "Checking user-local installation..."
        local user_removed
        user_removed=$(uninstall_user)
        total_removed=$((total_removed + user_removed))
        ((locations_checked++))
    fi

    echo ""

    if [[ "$total_removed" -eq 0 ]]; then
        if [[ "$locations_checked" -eq 0 ]]; then
            info "No cac installation found"
        else
            info "Nothing to remove"
        fi
    else
        echo "==================================="
        success "Uninstallation complete!"
        echo "==================================="
    fi
}

# Show usage
show_help() {
    echo "Usage: uninstall.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --purge, -p    Also remove configuration files"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "Locations checked:"
    echo "  System-wide (requires root):"
    echo "    Binary: ${SYS_BIN_DIR}/cac"
    echo "    Libraries: ${SYS_LIB_DIR}/"
    echo "    Config: ${SYS_CONFIG_DIR}/"
    echo ""
    echo "  User-local:"
    echo "    Binary: ${USER_BIN_DIR}/cac"
    echo "    Libraries: ${USER_LIB_DIR}/"
    echo "    Config: ${USER_CONFIG_DIR}/"
}

# Global options
PURGE=false

# Main entry point
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge|-p)
                PURGE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    do_uninstall
}

main "$@"
