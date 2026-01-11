#!/usr/bin/env bash
# lib/bundle.sh - ZIP bundle creation and extraction logic

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tools.sh
source "${SCRIPT_DIR}/tools.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/security.sh"

# Generate bundle filename following naming convention:
# CodingAgentConfig_<HOST>_<USER>_<YYMMDD-HHMMSS>.zip
bundle_generate_filename() {
    local host user timestamp

    host=$(hostname -s)
    user="${1:-$USER}"
    timestamp=$(date +%y%m%d-%H%M%S)

    echo "CodingAgentConfig_${host}_${user}_${timestamp}.zip"
}

# Parse bundle filename to extract metadata
# Returns: host user timestamp (space-separated)
bundle_parse_filename() {
    local filename="$1"
    local basename

    # Strip path and .zip extension
    basename=$(basename "$filename" .zip)

    # Expected format: CodingAgentConfig_HOST_USER_YYMMDD-HHMMSS
    if [[ "$basename" =~ ^CodingAgentConfig_([^_]+)_([^_]+)_([0-9]{6}-[0-9]{6})$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
        return 0
    fi

    return 1
}

# Get specific field from bundle filename
bundle_get_host() {
    local parsed
    if parsed=$(bundle_parse_filename "$1"); then
        echo "$parsed" | cut -d' ' -f1
    fi
}

bundle_get_user() {
    local parsed
    if parsed=$(bundle_parse_filename "$1"); then
        echo "$parsed" | cut -d' ' -f2
    fi
}

bundle_get_timestamp() {
    local parsed
    if parsed=$(bundle_parse_filename "$1"); then
        echo "$parsed" | cut -d' ' -f3
    fi
}

# Create a bundle ZIP from user's configuration files
# Usage: bundle_create <home_dir> <output_file> [tool]
bundle_create() {
    local home_dir="$1"
    local output_file="$2"
    local tool="${3:-all}"

    # Collect files that exist
    local files=()
    local rel_path

    while IFS= read -r rel_path; do
        [[ -z "$rel_path" ]] && continue

        local abs_path="${home_dir}/${rel_path}"
        if [[ -f "$abs_path" ]]; then
            files+=("$rel_path")
        fi
    done < <(tools_get_files "$tool")

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "ERROR: No configuration files found to bundle" >&2
        return 1
    fi

    # Create ZIP from home directory
    local output_dir
    output_dir=$(dirname "$output_file")
    mkdir -p "$output_dir"

    # Change to home dir and create ZIP with relative paths
    (
        cd "$home_dir" || exit 1
        zip -q "$output_file" "${files[@]}"
    )

    if [[ ! -f "$output_file" ]]; then
        echo "ERROR: Failed to create bundle: $output_file" >&2
        return 1
    fi

    echo "Created bundle: $output_file (${#files[@]} files)"
    return 0
}

# Extract a bundle ZIP to user's home directory
# Usage: bundle_extract <zip_file> <home_dir> <username>
bundle_extract() {
    local zip_file="$1"
    local home_dir="$2"
    local username="$3"

    # Validate ZIP security
    if ! security_validate_zip "$zip_file" "$home_dir"; then
        return 1
    fi

    # Create secure temp directory for extraction
    local temp_dir
    temp_dir=$(security_mktemp_dir "cac-extract")
    # Use ${temp_dir:-} to handle case where trap is inherited by calling function
    trap '[[ -n "${temp_dir:-}" ]] && rm -rf "$temp_dir"' RETURN

    # Extract to temp directory first
    if ! unzip -q -o "$zip_file" -d "$temp_dir"; then
        echo "ERROR: Failed to extract ZIP: $zip_file" >&2
        return 1
    fi

    # Backup existing files and move new ones
    local timestamp
    timestamp=$(date +%y%m%d-%H%M%S)

    local entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        [[ "$entry" == */ ]] && continue  # Skip directories

        local src_file="${temp_dir}/${entry}"
        local dst_file="${home_dir}/${entry}"
        local dst_dir
        dst_dir=$(dirname "$dst_file")

        # Create destination directory if needed
        if [[ ! -d "$dst_dir" ]]; then
            mkdir -p "$dst_dir"
            security_secure_dir "$dst_dir" "$username"
        fi

        # Backup existing file
        if [[ -f "$dst_file" ]]; then
            local backup="${dst_file}.backup${timestamp}"
            cp -a "$dst_file" "$backup"
            echo "  backup: ${entry} -> ${entry}.backup${timestamp}"
        fi

        # Move file from temp to destination
        mv "$src_file" "$dst_file"
        security_secure_file "$dst_file" "$username"
        echo "  extracted: $entry"

    done < <(unzip -Z1 "$zip_file" 2>/dev/null)

    return 0
}

# List contents of a bundle without extracting
bundle_list_contents() {
    local zip_file="$1"

    if [[ ! -f "$zip_file" ]]; then
        echo "ERROR: Bundle not found: $zip_file" >&2
        return 1
    fi

    unzip -l "$zip_file"
}
