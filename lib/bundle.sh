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
# Issue #41: New format: ${BUNDLE_NAME_PREFIX}_<HOST>_<USER>_<TOOL>_<YYMMDD-HHMMSS>.zip
# Note: Hostnames, usernames, and tool names must not contain underscores,
#       as underscores are used as field delimiters in the bundle naming convention.
# Usage: bundle_generate_filename [user] [tool]
# Returns: 0 on success, 1 if hostname, username, or tool contains underscores
bundle_generate_filename() {
    local host user tool timestamp

    host=$(hostname -s)
    user="${1:-$USER}"
    tool="${2:-all}"

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

    # Validate tool name doesn't contain underscores (field delimiter)
    if [[ "$tool" == *_* ]]; then
        utils_error "Tool name '$tool' contains underscores, which conflicts with bundle naming convention"
        return 1
    fi

    timestamp=$(date +%y%m%d-%H%M%S)

    echo "${BUNDLE_NAME_PREFIX}_${host}_${user}_${tool}_${timestamp}.zip"
}

# Parse bundle filename to extract metadata
# Supports both old and new formats for backward compatibility:
#   Old (4-segment): ${BUNDLE_NAME_PREFIX}_HOST_USER_YYMMDD-HHMMSS  -> tool defaults to "all"
#   New (5-segment): ${BUNDLE_NAME_PREFIX}_HOST_USER_TOOL_YYMMDD-HHMMSS
# Returns: host user tool timestamp (space-separated)
# Note: Hostnames, usernames, and tool names must not contain underscores, as the
#       bundle naming convention uses underscores as field delimiters.
bundle_parse_filename() {
    local filename="$1"
    local bn

    # Strip path and .zip extension
    bn=$(basename "$filename" .zip)

    # Try new 5-segment format first: PREFIX_HOST_USER_TOOL_YYMMDD-HHMMSS
    if [[ "$bn" =~ ^${BUNDLE_NAME_PREFIX}_([^_]+)_([^_]+)_([^_]+)_([0-9]{6}-[0-9]{6})$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[4]}"
        return 0
    fi

    # Fall back to old 4-segment format: PREFIX_HOST_USER_YYMMDD-HHMMSS (tool="all")
    if [[ "$bn" =~ ^${BUNDLE_NAME_PREFIX}_([^_]+)_([^_]+)_([0-9]{6}-[0-9]{6})$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} all ${BASH_REMATCH[3]}"
        return 0
    fi

    return 1
}

# Get specific field from bundle filename by field number
# Usage: _bundle_get_field <filename> <field_num>
# Fields: 1=host, 2=user, 3=tool, 4=timestamp
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
bundle_get_tool() { _bundle_get_field "$1" 3; }
bundle_get_timestamp() { _bundle_get_field "$1" 4; }

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
    done < <(tools_get_files "$tool" "--include-settings")

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
# Settings files (from _SETTINGS_REGISTRY) are only extracted when the bundle's
# hostname+user match the current host+target user. This prevents host-specific
# config (e.g. teammateMode) from being overwritten by bundles from other hosts.
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

    # Determine if settings files should be extracted
    # Only when bundle host+user matches current host+target user
    local bundle_host bundle_user current_host
    bundle_host=$(bundle_get_host "$zip_file")
    bundle_user=$(bundle_get_user "$zip_file")
    current_host=$(hostname -s)

    local extract_settings="false"
    if [[ "$bundle_host" == "$current_host" && "$bundle_user" == "$username" ]]; then
        extract_settings="true"
        utils_verbose "Host+user match — settings files will be extracted"
    else
        utils_verbose "Host+user mismatch (bundle=${bundle_host}/${bundle_user}, current=${current_host}/${username}) — skipping settings files"
    fi

    # Build list of settings file paths for skip check
    local -A settings_files_map
    local sf
    while IFS= read -r sf; do
        [[ -z "$sf" ]] && continue
        settings_files_map["$sf"]=1
    done < <(tools_get_settings_files "all")

    # Create secure temp directory for extraction
    # NOTE: Uses explicit cleanup instead of RETURN trap to avoid overwriting
    # caller's RETURN trap (e.g., utils_download_and_extract).
    local temp_dir
    security_init_temp_dir temp_dir "cac-extract"

    # Extract to temp directory first
    if ! _bundle_extract_to_temp "$zip_file" "$temp_dir"; then
        rm -rf "$temp_dir"
        return 1
    fi

    # Process each file in the archive
    local timestamp
    timestamp=$(date +%y%m%d-%H%M%S)

    local entry
    local extract_failed="false"
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        [[ "$entry" == */ ]] && continue  # Skip directories

        # Skip settings files when host+user don't match
        if [[ "$extract_settings" == "false" && -n "${settings_files_map[$entry]+isset}" ]]; then
            echo "  skipped (host-specific): $entry"
            continue
        fi

        local src_file="${temp_dir}/${entry}"
        local dst_file="${home_dir}/${entry}"

        if ! _bundle_ensure_dir "$(dirname "$dst_file")" "$username"; then
            extract_failed="true"
            break
        fi
        _bundle_backup_file "$dst_file" "$entry" "$timestamp"
        if ! _bundle_install_file "$src_file" "$dst_file" "$username" "$entry"; then
            extract_failed="true"
            break
        fi

    done < <(security_list_zip_entries "$zip_file")

    rm -rf "$temp_dir"
    [[ "$extract_failed" == "true" ]] && return 1
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
