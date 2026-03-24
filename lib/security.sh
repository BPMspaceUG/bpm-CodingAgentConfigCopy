#!/usr/bin/env bash
# lib/security.sh - Security validations, permission checks, zip-slip protection

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/logging.sh"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/platform.sh"

# Maximum allowed ZIP file size (100MB = 100 * 1024 * 1024 = 104857600 bytes)
SECURITY_MAX_ZIP_SIZE=${SECURITY_MAX_ZIP_SIZE:-104857600}

# Maximum number of files allowed in a ZIP
SECURITY_MAX_ZIP_FILES=${SECURITY_MAX_ZIP_FILES:-100}

# ============================================================================
# Permission Constants
# ============================================================================
# Standard permission modes for security-sensitive operations.
# Use these instead of raw numeric values for clarity and consistency.
# Exported for use by scripts that source this module.
# Guard with -v check to allow sourcing from multiple files.

if [[ ! -v PERM_SECURE_FILE ]]; then
    # Secure file permissions (rw-------): owner read/write only
    readonly PERM_SECURE_FILE="600"
    export PERM_SECURE_FILE

    # Secure directory permissions (rwx------): owner full access only
    readonly PERM_SECURE_DIR="700"
    export PERM_SECURE_DIR

    # Executable file permissions (rwxr-xr-x): world executable
    readonly PERM_EXECUTABLE="755"
    export PERM_EXECUTABLE

    # Readable file permissions (rw-r--r--): world readable
    readonly PERM_READABLE="644"
    export PERM_READABLE
fi

# ============================================================================
# Cross-Platform Stat Utilities
# ============================================================================

# Get file permissions in octal format (cross-platform)
# Usage: security_get_file_perms <path>
# Returns: Permissions in octal (e.g., "600", "755")
# Works on both Linux (stat -c) and macOS (stat -f)
security_get_file_perms() {
    local path="$1"
    platform_get_file_perms "$path"
}

# Get file size in bytes (cross-platform)
# Usage: security_get_file_size <path>
# Returns: File size in bytes
# Works on Linux (stat -c), macOS (stat -f), and Windows Git Bash
security_get_file_size() {
    local path="$1"
    platform_get_file_size "$path"
}

# ============================================================================
# User Access Checks
# ============================================================================

# Check if current user can operate on target user's files
# Returns 0 if allowed, 1 if not
security_check_user_access() {
    local target_user="$1"
    local current_user
    current_user=$(whoami)

    # Same user - always allowed
    if [[ "$target_user" == "$current_user" ]]; then
        return 0
    fi

    # Different user - requires root
    if [[ "$EUID" -ne 0 ]]; then
        utils_error "Root privileges required to operate on user '$target_user'"
        return 1
    fi

    return 0
}

# Validate that a user exists and return their home directory
security_resolve_user_home() {
    local username="$1"
    local home_dir

    home_dir=$(platform_resolve_home "$username") || return 1

    if [[ ! -d "$home_dir" ]]; then
        utils_error "Home directory for user '$username' does not exist: $home_dir"
        return 1
    fi

    echo "$home_dir"
    return 0
}

# Validate file permissions are not too open
# Usage: security_check_file_permissions <file> <max_perms>
# Example: security_check_file_permissions ~/.env 600
security_check_file_permissions() {
    local file="$1"
    local max_perms="$2"

    if [[ ! -f "$file" ]]; then
        return 0  # File doesn't exist, nothing to check
    fi

    # NTFS does not enforce POSIX permissions; skip enforcement on Windows
    if platform_is_windows; then
        return 0
    fi

    local perms
    perms=$(security_get_file_perms "$file")

    # Convert to numeric for comparison
    local file_mode=$((8#$perms))
    local max_mode=$((8#$max_perms))

    # Check if any bits beyond max_perms are set
    if [[ $((file_mode & ~max_mode)) -ne 0 ]]; then
        utils_error "File '$file' has insecure permissions ($perms). Maximum allowed: $max_perms"
        return 1
    fi

    return 0
}

# List entries in a ZIP file (one per line)
# Usage: security_list_zip_entries <zip_file>
# Returns: One entry per line (files and directories)
# Exit code: 0 on success, 1 if zip file doesn't exist or unzip fails
#
# This consolidates the common `unzip -Z1` pattern used for iterating over
# ZIP contents. Output includes both files and directory entries (ending in /).
# Callers typically filter directory entries with: [[ "$entry" == */ ]] && continue
#
# Example:
#   while IFS= read -r entry; do
#       [[ -z "$entry" ]] && continue
#       [[ "$entry" == */ ]] && continue  # Skip directories
#       process_file "$entry"
#   done < <(security_list_zip_entries "$zip_file")
security_list_zip_entries() {
    local zip_file="$1"

    if [[ ! -f "$zip_file" ]]; then
        return 1
    fi

    unzip -Z1 "$zip_file" 2>/dev/null
}

# Validate a path within a ZIP is safe (no zip-slip)
# Returns 0 if safe, 1 if path traversal detected
security_validate_zip_path() {
    local zip_entry="$1"
    local target_dir="$2"

    # Reject absolute paths
    if [[ "$zip_entry" == /* ]]; then
        utils_error "Absolute path in ZIP rejected: $zip_entry"
        return 1
    fi

    # Reject path traversal
    if [[ "$zip_entry" == *".."* ]]; then
        utils_error "Path traversal in ZIP rejected: $zip_entry"
        return 1
    fi

    # Normalize and verify the resolved path stays within target
    local resolved_path
    resolved_path=$(realpath -m "${target_dir}/${zip_entry}" 2>/dev/null)

    # Use trailing slash to prevent /home/user123 matching /home/user prefix
    if [[ "$resolved_path" != "${target_dir}/"* && "$resolved_path" != "${target_dir}" ]]; then
        utils_error "ZIP entry escapes target directory: $zip_entry"
        return 1
    fi

    return 0
}

# Validate all entries in a ZIP file before extraction
# Returns 0 if all entries are safe, 1 if any are dangerous
security_validate_zip() {
    local zip_file="$1"
    local target_dir="$2"

    utils_verbose "Validating ZIP: $zip_file"

    if [[ ! -f "$zip_file" ]]; then
        utils_error "ZIP file does not exist: $zip_file"
        return 1
    fi

    # Check file size
    local zip_size
    zip_size=$(security_get_file_size "$zip_file")

    utils_verbose "ZIP size: $zip_size bytes (max: $SECURITY_MAX_ZIP_SIZE)"

    if [[ "$zip_size" -gt "$SECURITY_MAX_ZIP_SIZE" ]]; then
        utils_error "ZIP file exceeds maximum size ($zip_size > $SECURITY_MAX_ZIP_SIZE bytes)"
        return 1
    fi

    # List ZIP contents and validate each entry
    local entry_count=0
    local entry

    while IFS= read -r entry; do
        # Skip empty lines and directory entries (ending in /)
        [[ -z "$entry" ]] && continue
        [[ "$entry" == */ ]] && continue

        ((entry_count++)) || true

        if [[ "$entry_count" -gt "$SECURITY_MAX_ZIP_FILES" ]]; then
            utils_error "ZIP contains too many files (> $SECURITY_MAX_ZIP_FILES)"
            return 1
        fi

        if ! security_validate_zip_path "$entry" "$target_dir"; then
            return 1
        fi
    done < <(security_list_zip_entries "$zip_file")

    return 0
}

# Create a secure temporary directory
security_mktemp_dir() {
    local prefix="${1:-cac}"
    local tmpdir

    if ! tmpdir=$(mktemp -d -t "${prefix}.XXXXXXXXXX"); then
        return 1
    fi
    if ! platform_chmod "$PERM_SECURE_DIR" "$tmpdir"; then
        rm -rf "$tmpdir" 2>/dev/null
        return 1
    fi

    echo "$tmpdir"
}

# Set secure permissions and ownership on a path
# Usage: security_secure_path <path> <owner> <mode>
# Example: security_secure_path "$file" "root" "600"
#          security_secure_path "$dir" "alice" "700"
#
# This is the core function for setting secure permissions.
# The mode parameter must be specified (common values: 600 for files, 700 for dirs).
# Ownership is only changed when running as root and owner is non-empty.
# Returns: 0 on success, 1 if chmod or chown fails
security_secure_path() {
    local path="$1"
    local owner="$2"
    local mode="$3"

    if ! platform_chmod "$mode" "$path"; then
        return 1
    fi

    if [[ -n "$owner" && "$EUID" -eq 0 ]]; then
        if ! platform_chown "$owner:$owner" "$path"; then
            return 1
        fi
    fi
}

# Set secure permissions on a file and correct ownership
# Usage: security_secure_file <file> <owner>
security_secure_file() {
    local file="$1"
    local owner="$2"

    security_secure_path "$file" "$owner" "$PERM_SECURE_FILE"
}

# Set secure permissions on a directory and correct ownership
# Usage: security_secure_dir <dir> <owner>
security_secure_dir() {
    local dir="$1"
    local owner="$2"

    security_secure_path "$dir" "$owner" "$PERM_SECURE_DIR"
}

# ============================================================================
# Cleanup Trap Utilities
# ============================================================================

# Set up a RETURN trap to clean up a temp directory variable
# Usage: security_setup_cleanup_trap <var_name>
# Example: security_setup_cleanup_trap temp_dir
#
# This centralizes the common pattern:
#   trap '[[ -n "${temp_dir:-}" ]] && rm -rf "$temp_dir"' RETURN
#
# The variable name must be provided (not the value) so the trap can
# evaluate it at cleanup time, not at setup time.
#
# Note: Uses RETURN signal, suitable for function-scoped cleanup.
# For script-level cleanup, use EXIT directly.
security_setup_cleanup_trap() {
    local var_name="$1"

    # shellcheck disable=SC2064  # Intentional: var_name captured at setup, value evaluated at cleanup
    trap "[[ -n \"\${${var_name}:-}\" ]] && rm -rf \"\$${var_name}\"" RETURN
}

# Create a secure temp directory (caller must set up cleanup trap)
# Usage: security_init_temp_dir <var_name> <prefix>
# Example:
#   security_init_temp_dir temp_dir "cac-push"
#   trap '[[ -n "${temp_dir:-}" ]] && rm -rf "$temp_dir"' RETURN
#
# IMPORTANT: The caller MUST set the RETURN trap itself. Setting the trap
# inside a helper function causes it to fire when the helper returns,
# deleting the temp directory before the caller can use it.
#
# Note: Uses nameref to set the caller's variable.
security_init_temp_dir() {
    local -n _temp_dir_ref="$1"
    local prefix="$2"

    _temp_dir_ref=$(security_mktemp_dir "$prefix")
}
