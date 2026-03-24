#!/usr/bin/env bash
# lib/platform.sh - Cross-platform detection and compatibility layer
#
# Provides platform-aware wrappers for filesystem, user, and system operations
# so the rest of cac works on Linux, macOS, WSL, and Windows Git Bash (MINGW).
#
# Supported platforms:
#   linux    - Standard Linux (not WSL)
#   macos    - Darwin / macOS
#   wsl      - WSL1 or WSL2 (Linux kernel with Microsoft identifier)
#   gitbash  - Git for Windows / MINGW64 / MSYS2
#   windows  - Cygwin or other Windows POSIX layers
#
# All callers must source this file before using any platform_* functions.
# platform_detect is called automatically on source.

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/logging.sh"

# ============================================================================
# Platform Detection
# ============================================================================

# Guard: only detect once per shell session
if [[ ! -v PLATFORM ]]; then

# Detect the current platform and export PLATFORM variable.
# Sets PLATFORM to one of: linux, macos, wsl, gitbash, windows
platform_detect() {
    # Git Bash / MINGW / MSYS2 on Windows
    if [[ "${OSTYPE:-}" == msys || "${OSTYPE:-}" == mingw* || "${OSTYPE:-}" == cygwin ]]; then
        echo "gitbash"
        return 0
    fi

    # WSL: Linux kernel contains "microsoft" in uname -r
    if uname -r 2>/dev/null | grep -qi microsoft; then
        echo "wsl"
        return 0
    fi

    # macOS
    if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
        echo "macos"
        return 0
    fi

    # Default: standard Linux
    echo "linux"
}

PLATFORM=$(platform_detect)
readonly PLATFORM
export PLATFORM

fi  # end guard

# Returns 0 (true) if running on Windows Git Bash or Cygwin
platform_is_windows() {
    [[ "$PLATFORM" == "gitbash" || "$PLATFORM" == "windows" ]]
}

# ============================================================================
# Home Directory Resolution
# ============================================================================

# Resolve a user's home directory in a platform-aware way.
# Usage: platform_resolve_home <username>
# Returns: Absolute POSIX path to home directory
platform_resolve_home() {
    local username="$1"

    if platform_is_windows; then
        # On Git Bash: current user maps to $USERPROFILE (or $HOME)
        local current_user
        current_user="${USERNAME:-$(whoami 2>/dev/null)}"

        if [[ "$username" == "$current_user" ]]; then
            # Convert Windows path to POSIX if cygpath available
            if command -v cygpath &>/dev/null; then
                cygpath -u "${USERPROFILE:-$HOME}" 2>/dev/null || echo "${HOME}"
            else
                # $HOME in Git Bash is already POSIX-style (/c/Users/name)
                echo "${HOME}"
            fi
            return 0
        fi

        # Other user: construct /c/Users/<name> and verify
        local win_home
        # Try SYSTEMDRIVE-based path
        local sys_drive="${SYSTEMDRIVE:-C:}"
        if command -v cygpath &>/dev/null; then
            local drive_posix
            drive_posix=$(cygpath -u "$sys_drive" 2>/dev/null || echo "/c")
            win_home="${drive_posix}/Users/${username}"
        else
            # Git Bash maps C: to /c
            local drive_letter="${sys_drive%%:*}"
            win_home="/${drive_letter,,}/Users/${username}"
        fi

        if [[ -d "$win_home" ]]; then
            echo "$win_home"
            return 0
        fi

        utils_error "Cannot resolve home directory for user '$username' on Windows"
        return 1
    fi

    # Linux / macOS / WSL: use getent (Linux) or dscl (macOS)
    local home_dir

    if command -v getent &>/dev/null; then
        home_dir=$(getent passwd "$username" 2>/dev/null | cut -d: -f6)
    elif command -v dscl &>/dev/null; then
        home_dir=$(dscl . -read "/Users/$username" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    fi

    if [[ -z "$home_dir" ]]; then
        # Final fallback: eval tilde expansion
        home_dir=$(eval echo "~${username}" 2>/dev/null) || true
    fi

    if [[ -z "$home_dir" ]]; then
        utils_error "User '$username' does not exist"
        return 1
    fi

    echo "$home_dir"
}

# ============================================================================
# File Stat Wrappers
# ============================================================================

# Get file permissions in octal format (cross-platform)
# Usage: platform_get_file_perms <path>
# Returns: Octal permissions string (e.g., "600") or "600" sentinel on Windows
platform_get_file_perms() {
    local path="$1"

    if platform_is_windows; then
        # NTFS does not use POSIX octal permissions; return sentinel
        # chmod is a no-op on NTFS but won't abort — just skip enforcement
        echo "600"
        return 0
    fi

    # GNU stat (Linux/WSL)
    stat -c "%a" "$path" 2>/dev/null && return 0
    # BSD stat (macOS)
    stat -f "%Lp" "$path" 2>/dev/null && return 0
    echo "600"  # safe fallback
}

# Get file size in bytes (cross-platform)
# Usage: platform_get_file_size <path>
# Returns: File size in bytes
platform_get_file_size() {
    local path="$1"

    # GNU stat
    stat -c "%s" "$path" 2>/dev/null && return 0
    # BSD stat (macOS)
    stat -f "%z" "$path" 2>/dev/null && return 0
    # Git Bash fallback: wc -c
    wc -c < "$path" 2>/dev/null | tr -d ' ' && return 0
    echo "0"
}

# Get file modification time as epoch seconds (cross-platform)
# Usage: platform_get_file_mtime <path>
# Returns: Epoch seconds
platform_get_file_mtime() {
    local path="$1"

    # GNU stat
    stat -c "%Y" "$path" 2>/dev/null && return 0
    # BSD stat (macOS)
    stat -f "%m" "$path" 2>/dev/null && return 0
    # Git Bash: date -r
    date -r "$path" +%s 2>/dev/null && return 0
    echo "0"
}

# ============================================================================
# Conditional chmod / chown
# ============================================================================

# Set file/directory permissions — no-op on Windows NTFS
# Usage: platform_chmod <mode> <path...>
platform_chmod() {
    local mode="$1"
    shift

    if platform_is_windows; then
        # chmod on NTFS is a no-op; swallow any errors to avoid aborting
        chmod "$mode" "$@" 2>/dev/null || true
        return 0
    fi

    chmod "$mode" "$@"
}

# Set file/directory ownership — no-op on Windows NTFS
# Usage: platform_chown <owner> <path...>
platform_chown() {
    local owner="$1"
    shift

    if platform_is_windows; then
        return 0  # chown is not meaningful on NTFS
    fi

    chown "$owner" "$@"
}

# ============================================================================
# Timeout Command
# ============================================================================

# Detect available timeout command (cross-platform)
# Usage: platform_get_timeout_cmd
# Returns: "timeout", "gtimeout", or empty string with error on Windows-missing
platform_get_timeout_cmd() {
    if command -v timeout &>/dev/null; then
        echo "timeout"
        return 0
    fi

    if command -v gtimeout &>/dev/null; then
        echo "gtimeout"
        return 0
    fi

    if platform_is_windows; then
        utils_error "Required command 'timeout' not found."
        utils_error "On Windows Git Bash, upgrade Git for Windows (>=2.44 bundles GNU coreutils):"
        utils_error "  winget install Git.Git"
        utils_error "Or install GnuWin32 coreutils: winget install GnuWin32.CoreUtils"
    else
        utils_error "Required command 'timeout' not found."
        utils_error "On macOS, install with: brew install coreutils"
    fi

    return 1
}

# ============================================================================
# Package Manager Install Hints
# ============================================================================

# Return a platform-appropriate install hint for a package
# Usage: platform_install_hint <package>
# Returns: Human-readable install command string
platform_install_hint() {
    local package="$1"

    case "$PLATFORM" in
        linux)
            echo "sudo apt-get install ${package}"
            ;;
        macos)
            echo "brew install ${package}"
            ;;
        wsl)
            echo "sudo apt-get install ${package}  # (WSL)"
            ;;
        gitbash|windows)
            echo "winget install ${package}  # or: choco install ${package} / scoop install ${package}"
            ;;
        *)
            echo "Install ${package} using your system package manager"
            ;;
    esac
}

# ============================================================================
# User Home Enumeration
# ============================================================================

# List all user home directories on the system (cross-platform)
# Usage: platform_list_user_homes
# Returns: One absolute POSIX path per line
platform_list_user_homes() {
    if platform_is_windows; then
        # Git Bash: users live under /c/Users (or equivalent drive)
        local sys_drive="${SYSTEMDRIVE:-C:}"
        local users_root
        if command -v cygpath &>/dev/null; then
            users_root=$(cygpath -u "${sys_drive}/Users" 2>/dev/null)
        else
            local drive_letter="${sys_drive%%:*}"
            users_root="/${drive_letter,,}/Users"
        fi

        if [[ -d "$users_root" ]]; then
            local dir
            for dir in "${users_root}"/*/; do
                [[ -d "$dir" ]] || continue
                local name
                name=$(basename "$dir")
                # Skip well-known non-user directories
                case "$name" in
                    "Public"|"Default"|"Default User"|"All Users"|"desktop.ini") continue ;;
                esac
                echo "${dir%/}"
            done
        fi
        return 0
    fi

    # Linux / WSL / macOS
    local dir
    for dir in /home/*/; do
        [[ -d "$dir" ]] && echo "${dir%/}"
    done

    # Also include root
    [[ -d "/root" ]] && echo "/root"
}
