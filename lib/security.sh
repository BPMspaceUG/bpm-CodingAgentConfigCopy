#!/usr/bin/env bash
# lib/security.sh - Security validations, permission checks, zip-slip protection

# Maximum allowed ZIP file size (100MB)
SECURITY_MAX_ZIP_SIZE=${SECURITY_MAX_ZIP_SIZE:-104857600}

# Maximum number of files allowed in a ZIP
SECURITY_MAX_ZIP_FILES=${SECURITY_MAX_ZIP_FILES:-100}

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
        echo "ERROR: Root privileges required to operate on user '$target_user'" >&2
        return 1
    fi

    return 0
}

# Validate that a user exists and return their home directory
security_resolve_user_home() {
    local username="$1"
    local home_dir

    home_dir=$(getent passwd "$username" 2>/dev/null | cut -d: -f6)

    if [[ -z "$home_dir" ]]; then
        echo "ERROR: User '$username' does not exist" >&2
        return 1
    fi

    if [[ ! -d "$home_dir" ]]; then
        echo "ERROR: Home directory for user '$username' does not exist: $home_dir" >&2
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

    local perms
    perms=$(stat -c "%a" "$file" 2>/dev/null || stat -f "%Lp" "$file" 2>/dev/null)

    # Convert to numeric for comparison
    local file_mode=$((8#$perms))
    local max_mode=$((8#$max_perms))

    # Check if any bits beyond max_perms are set
    if [[ $((file_mode & ~max_mode)) -ne 0 ]]; then
        echo "ERROR: File '$file' has insecure permissions ($perms). Maximum allowed: $max_perms" >&2
        return 1
    fi

    return 0
}

# Validate a path within a ZIP is safe (no zip-slip)
# Returns 0 if safe, 1 if path traversal detected
security_validate_zip_path() {
    local zip_entry="$1"
    local target_dir="$2"

    # Reject absolute paths
    if [[ "$zip_entry" == /* ]]; then
        echo "ERROR: Absolute path in ZIP rejected: $zip_entry" >&2
        return 1
    fi

    # Reject path traversal
    if [[ "$zip_entry" == *".."* ]]; then
        echo "ERROR: Path traversal in ZIP rejected: $zip_entry" >&2
        return 1
    fi

    # Normalize and verify the resolved path stays within target
    local resolved_path
    resolved_path=$(realpath -m "${target_dir}/${zip_entry}" 2>/dev/null)

    if [[ "$resolved_path" != "${target_dir}"* ]]; then
        echo "ERROR: ZIP entry escapes target directory: $zip_entry" >&2
        return 1
    fi

    return 0
}

# Validate all entries in a ZIP file before extraction
# Returns 0 if all entries are safe, 1 if any are dangerous
security_validate_zip() {
    local zip_file="$1"
    local target_dir="$2"

    if [[ ! -f "$zip_file" ]]; then
        echo "ERROR: ZIP file does not exist: $zip_file" >&2
        return 1
    fi

    # Check file size
    local zip_size
    zip_size=$(stat -c "%s" "$zip_file" 2>/dev/null || stat -f "%z" "$zip_file" 2>/dev/null)

    if [[ "$zip_size" -gt "$SECURITY_MAX_ZIP_SIZE" ]]; then
        echo "ERROR: ZIP file exceeds maximum size ($zip_size > $SECURITY_MAX_ZIP_SIZE bytes)" >&2
        return 1
    fi

    # List ZIP contents and validate each entry
    local entry_count=0
    local entry

    while IFS= read -r entry; do
        # Skip empty lines and directory entries (ending in /)
        [[ -z "$entry" ]] && continue
        [[ "$entry" == */ ]] && continue

        ((entry_count++))

        if [[ "$entry_count" -gt "$SECURITY_MAX_ZIP_FILES" ]]; then
            echo "ERROR: ZIP contains too many files (> $SECURITY_MAX_ZIP_FILES)" >&2
            return 1
        fi

        if ! security_validate_zip_path "$entry" "$target_dir"; then
            return 1
        fi
    done < <(unzip -Z1 "$zip_file" 2>/dev/null)

    return 0
}

# Create a secure temporary directory
security_mktemp_dir() {
    local prefix="${1:-cac}"
    local tmpdir

    tmpdir=$(mktemp -d -t "${prefix}.XXXXXXXXXX")
    chmod 700 "$tmpdir"

    echo "$tmpdir"
}

# Set secure permissions on a file (600) and correct ownership
security_secure_file() {
    local file="$1"
    local owner="$2"

    chmod 600 "$file"

    if [[ -n "$owner" && "$EUID" -eq 0 ]]; then
        chown "$owner:$owner" "$file"
    fi
}

# Set secure permissions on a directory (700) and correct ownership
security_secure_dir() {
    local dir="$1"
    local owner="$2"

    chmod 700 "$dir"

    if [[ -n "$owner" && "$EUID" -eq 0 ]]; then
        chown "$owner:$owner" "$dir"
    fi
}
