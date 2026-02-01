#!/usr/bin/env bash
# lib/bundle.sh - ZIP bundle creation and extraction logic

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tools.sh
source "${SCRIPT_DIR}/tools.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/security.sh"

# ============================================================================
# Bundle Naming Constants
# ============================================================================

# Bundle filename prefix - single source of truth for bundle name pattern
# Used by: bundle.sh, utils.sh, backend_local.sh, backend_gokapi.sh
# Guard prevents re-declaration errors when sourced multiple times
if [[ -z "${BUNDLE_NAME_PREFIX:-}" ]]; then
    readonly BUNDLE_NAME_PREFIX="CodingAgentConfig"
fi

# Generate bundle filename following naming convention:
# ${BUNDLE_NAME_PREFIX}_<HOST>_<USER>_<YYMMDD-HHMMSS>.zip
# Note: Hostnames and usernames must not contain underscores, as underscores
#       are used as field delimiters in the bundle naming convention.
# Returns: 0 on success, 1 if hostname or username contains underscores
bundle_generate_filename() {
    local host user timestamp

    host=$(hostname -s)
    user="${1:-$USER}"

    # Validate hostname doesn't contain underscores (field delimiter)
    if [[ "$host" == *_* ]]; then
        utils_error "Hostname '$host' contains underscores, which conflicts with bundle naming convention"
        return 1
    fi

    # Validate username doesn't contain underscores (field delimiter)
    if [[ "$user" == *_* ]]; then
        utils_error "Username '$user' contains underscores, which conflicts with bundle naming convention"
        return 1
    fi

    timestamp=$(date +%y%m%d-%H%M%S)

    echo "${BUNDLE_NAME_PREFIX}_${host}_${user}_${timestamp}.zip"
}

# Parse bundle filename to extract metadata
# Returns: host user timestamp (space-separated)
# Note: Hostnames and usernames must not contain underscores, as the
#       bundle naming convention uses underscores as field delimiters.
bundle_parse_filename() {
    local filename="$1"
    local basename

    # Strip path and .zip extension
    basename=$(basename "$filename" .zip)

    # Expected format: ${BUNDLE_NAME_PREFIX}_HOST_USER_YYMMDD-HHMMSS
    if [[ "$basename" =~ ^${BUNDLE_NAME_PREFIX}_([^_]+)_([^_]+)_([0-9]{6}-[0-9]{6})$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
        return 0
    fi

    return 1
}

# Get specific field from bundle filename by field number
# Usage: _bundle_get_field <filename> <field_num>
# Fields: 1=host, 2=user, 3=timestamp
_bundle_get_field() {
    local filename="$1"
    local field_num="$2"
    local parsed
    if parsed=$(bundle_parse_filename "$filename"); then
        echo "$parsed" | cut -d' ' -f"$field_num"
    fi
}

bundle_get_host() { _bundle_get_field "$1" 1; }
bundle_get_user() { _bundle_get_field "$1" 2; }
bundle_get_timestamp() { _bundle_get_field "$1" 3; }

# Create a bundle ZIP from user's configuration files
# Usage: bundle_create <home_dir> <output_file> [tool]
# Returns: 0 on success, 1 on failure
bundle_create() {
    local home_dir="$1"
    local output_file="$2"
    local tool="${3:-all}"

    # Validate home directory exists
    if [[ ! -d "$home_dir" ]]; then
        utils_error "Home directory not found: $home_dir"
        return 1
    fi

    utils_verbose "Creating bundle from: $home_dir"
    utils_verbose "Tool filter: $tool"

    # Collect files that exist
    local files=()
    local rel_path

    while IFS= read -r rel_path; do
        [[ -z "$rel_path" ]] && continue

        local abs_path="${home_dir}/${rel_path}"
        if [[ -f "$abs_path" ]]; then
            files+=("$rel_path")
            utils_verbose "Including file: $rel_path"
        fi
    done < <(tools_get_files "$tool")

    if [[ ${#files[@]} -eq 0 ]]; then
        utils_error "No configuration files found to bundle"
        return 1
    fi

    # Create ZIP from home directory
    local output_dir
    output_dir=$(dirname "$output_file")
    if ! mkdir -p "$output_dir"; then
        utils_error "Failed to create output directory: $output_dir"
        return 1
    fi

    # Change to home dir and create ZIP with relative paths
    local zip_output
    if ! zip_output=$(cd "$home_dir" && zip -q "$output_file" "${files[@]}" 2>&1); then
        utils_error "Failed to create bundle: zip command failed"
        [[ -n "$zip_output" ]] && utils_error "$zip_output"
        return 1
    fi

    if [[ ! -f "$output_file" ]]; then
        utils_error "Failed to create bundle: output file not created"
        return 1
    fi

    echo "Created bundle: $output_file (${#files[@]} files)"
    return 0
}

# Backup an existing file before overwriting
# Usage: _bundle_backup_file <dst_file> <entry> <timestamp>
# Internal helper for bundle_extract
_bundle_backup_file() {
    local dst_file="$1"
    local entry="$2"
    local timestamp="$3"

    if [[ -f "$dst_file" ]]; then
        local backup="${dst_file}.backup${timestamp}"
        if cp -a "$dst_file" "$backup"; then
            echo "  backup: ${entry} -> ${entry}.backup${timestamp}"
        else
            utils_warn "Failed to backup $entry - continuing without backup"
        fi
    fi
}

# Install a file from temp directory to destination with proper permissions
# Usage: _bundle_install_file <src_file> <dst_file> <username> <entry>
# Returns: 0 on success, 1 on failure
# Internal helper for bundle_extract
_bundle_install_file() {
    local src_file="$1"
    local dst_file="$2"
    local username="$3"
    local entry="$4"

    if ! mv "$src_file" "$dst_file"; then
        utils_error "Failed to install file: $entry"
        return 1
    fi
    security_secure_file "$dst_file" "$username"
    echo "  extracted: $entry"
    return 0
}

# Ensure destination directory exists with secure permissions
# Usage: _bundle_ensure_dir <dst_dir> <username>
# Returns: 0 on success, 1 on failure
# Internal helper for bundle_extract
_bundle_ensure_dir() {
    local dst_dir="$1"
    local username="$2"

    if [[ ! -d "$dst_dir" ]]; then
        if ! mkdir -p "$dst_dir"; then
            utils_error "Failed to create directory: $dst_dir"
            return 1
        fi
        security_secure_dir "$dst_dir" "$username"
    fi
    return 0
}

# Extract ZIP to temp directory
# Usage: _bundle_extract_to_temp <zip_file> <temp_dir>
# Returns: 0 on success, 1 on failure
_bundle_extract_to_temp() {
    local zip_file="$1"
    local temp_dir="$2"

    if ! unzip -q -o "$zip_file" -d "$temp_dir"; then
        utils_error "Failed to extract ZIP: $zip_file"
        return 1
    fi
    return 0
}

# Extract a bundle ZIP to user's home directory
# Usage: bundle_extract <zip_file> <home_dir> <username>
bundle_extract() {
    local zip_file="$1"
    local home_dir="$2"
    local username="$3"

    utils_verbose "Extracting bundle: $zip_file"
    utils_verbose "Target directory: $home_dir"
    utils_verbose "Target user: $username"

    # Validate ZIP security
    if ! security_validate_zip "$zip_file" "$home_dir"; then
        return 1
    fi

    # Create secure temp directory for extraction (cleaned on return)
    local temp_dir
    security_init_temp_dir temp_dir "cac-extract"
    trap '[[ -n "${temp_dir:-}" ]] && rm -rf "$temp_dir"' RETURN

    # Extract to temp directory first
    if ! _bundle_extract_to_temp "$zip_file" "$temp_dir"; then
        return 1
    fi

    # Process each file in the archive
    local timestamp
    timestamp=$(date +%y%m%d-%H%M%S)

    local entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        [[ "$entry" == */ ]] && continue  # Skip directories

        local src_file="${temp_dir}/${entry}"
        local dst_file="${home_dir}/${entry}"

        if ! _bundle_ensure_dir "$(dirname "$dst_file")" "$username"; then
            return 1
        fi
        _bundle_backup_file "$dst_file" "$entry" "$timestamp"
        if ! _bundle_install_file "$src_file" "$dst_file" "$username" "$entry"; then
            return 1
        fi

    done < <(security_list_zip_entries "$zip_file")

    return 0
}

# List contents of a bundle without extracting
bundle_list_contents() {
    local zip_file="$1"

    if [[ ! -f "$zip_file" ]]; then
        utils_error "Bundle not found: $zip_file"
        return 1
    fi

    unzip -l "$zip_file"
}
