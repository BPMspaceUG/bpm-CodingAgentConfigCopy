#!/usr/bin/env bash
# lib/backend_local.sh - Local filesystem backend for bundle storage

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bundle.sh
source "${SCRIPT_DIR}/bundle.sh"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/utils.sh"

# Internal: List all bundle files sorted by modification time (newest first)
# Usage: _local_list_bundle_files <storage_dir>
# Outputs: One file path per line, sorted newest first
_local_list_bundle_files() {
    local storage_dir="$1"
    # BUNDLE_NAME_PREFIX is defined in bundle.sh
    find "$storage_dir" -maxdepth 1 -name "${BUNDLE_NAME_PREFIX}_*.zip" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-
}

# Internal: Find a bundle file by ID (exact or partial match)
# Usage: _local_find_bundle_file <storage_dir> <bundle_id>
# Outputs: Full path to matching file
# Returns: 0 if found, 1 if not found, 2 if multiple matches
_local_find_bundle_file() {
    local storage_dir="$1"
    local bundle_id="$2"

    # Check for exact filename match (with or without .zip)
    if [[ -f "${storage_dir}/${bundle_id}" ]]; then
        echo "${storage_dir}/${bundle_id}"
        return 0
    elif [[ -f "${storage_dir}/${bundle_id}.zip" ]]; then
        echo "${storage_dir}/${bundle_id}.zip"
        return 0
    fi

    # Try partial match
    local matches
    matches=$(find "$storage_dir" -maxdepth 1 -name "*${bundle_id}*.zip" -type f 2>/dev/null)

    if [[ -z "$matches" ]]; then
        return 1  # Not found
    fi

    local count
    count=$(echo "$matches" | wc -l)

    if [[ "$count" -eq 1 ]]; then
        echo "$matches"
        return 0
    else
        # Multiple matches - output them for error reporting
        echo "$matches"
        return 2
    fi
}

# Internal: Validate local storage configuration
# Usage: _local_validate_storage
# Returns: 0 if valid, 1 if not (with error message)
# Sets: LOCAL_STORAGE_DIR (for use by caller)
_local_validate_storage() {
    utils_require_var CAC_LOCAL_STORAGE || return 1

    # shellcheck disable=SC2034  # LOCAL_STORAGE_DIR is used by callers
    LOCAL_STORAGE_DIR="${CAC_LOCAL_STORAGE}"

    if [[ ! -d "$LOCAL_STORAGE_DIR" ]]; then
        utils_error "Storage directory does not exist: $LOCAL_STORAGE_DIR"
        return 1
    fi

    return 0
}

# Upload (store) a bundle to local storage
# Usage: backend_local_upload <bundle_file>
backend_local_upload() {
    local bundle_file="$1"

    if ! _local_validate_storage; then
        return 1
    fi
    local storage_dir="$LOCAL_STORAGE_DIR"

    local filename
    filename=$(basename "$bundle_file")
    local dest="${storage_dir}/${filename}"

    if ! utils_safe_copy "$bundle_file" "$dest"; then
        return 1
    fi

    if ! utils_safe_chmod "$PERM_SECURE_FILE" "$dest"; then
        return 1
    fi

    echo "Uploaded: $filename"
    return 0
}

# Download a bundle from local storage
# Usage: backend_local_download <bundle_id> <output_file>
# bundle_id can be a filename or partial match
backend_local_download() {
    local bundle_id="$1"
    local output_file="$2"

    if ! _local_validate_storage; then
        return 1
    fi
    local storage_dir="$LOCAL_STORAGE_DIR"

    local source_file find_result
    source_file=$(_local_find_bundle_file "$storage_dir" "$bundle_id")
    find_result=$?

    # Format output for error display (basenames only)
    local formatted_matches=""
    if [[ $find_result -eq 2 ]]; then
        formatted_matches=$(echo "$source_file" | while read -r f; do basename "$f"; done)
    fi

    if ! utils_handle_find_result "$find_result" "$bundle_id" "$formatted_matches"; then
        return 1
    fi

    if ! utils_safe_copy "$source_file" "$output_file"; then
        return 1
    fi

    echo "Downloaded: $(basename "$source_file")"
    return 0
}

# List bundles in local storage
# Issue #41/#50: --host removed, --tool added for per-service bundle filtering
# Usage: backend_local_list [--tool TOOL] [--user USER]
backend_local_list() {
    # Parse filter arguments
    utils_parse_filter_args "$@"
    local filter_tool="$FILTER_TOOL"
    local filter_user="$FILTER_USER"

    if ! _local_validate_storage; then
        # For list, missing storage is not an error, just empty result
        echo "No bundles found"
        return 0
    fi
    local storage_dir="$LOCAL_STORAGE_DIR"

    # Find all ZIP files and parse their metadata
    local found=0

    # Sort by modification time (newest first)
    while IFS= read -r zip_file; do
        [[ -z "$zip_file" ]] && continue

        local filename
        filename=$(basename "$zip_file")

        local metadata
        if ! metadata=$(utils_parse_bundle_metadata "$filename" "$filter_tool" "$filter_user"); then
            continue  # Skip files that don't match or are filtered out
        fi

        # metadata format: "name|host|user|tool|timestamp"
        local host user tool timestamp
        IFS='|' read -r _ host user tool timestamp <<< "$metadata"

        if [[ "$found" -eq 0 ]]; then
            utils_print_bundle_list_header
        fi

        utils_print_bundle_list_entry "$filename" "$host" "$user" "$tool" "$timestamp"
        ((found++)) || true  # Prevent errexit when incrementing from 0

    done < <(_local_list_bundle_files "$storage_dir")

    if [[ "$found" -eq 0 ]]; then
        echo "No bundles found"
    else
        utils_print_bundle_list_footer "$found"
    fi

    return 0
}

# Get the newest bundle matching criteria
# Issue #41/#50: --host removed, --tool added for per-service bundle filtering
# Usage: backend_local_get_newest [--tool TOOL] [--user USER]
# Returns the filename of the newest matching bundle
backend_local_get_newest() {
    # Parse filter arguments
    utils_parse_filter_args "$@"
    local filter_tool="$FILTER_TOOL"
    local filter_user="$FILTER_USER"

    if ! _local_validate_storage; then
        return 1
    fi
    local storage_dir="$LOCAL_STORAGE_DIR"

    # Find newest matching bundle
    while IFS= read -r zip_file; do
        [[ -z "$zip_file" ]] && continue

        local filename
        filename=$(basename "$zip_file")

        # Use shared utility for parsing and filtering
        if utils_parse_bundle_metadata "$filename" "$filter_tool" "$filter_user" >/dev/null; then
            # Return the first match (newest due to sort)
            echo "$filename"
            return 0
        fi

    done < <(_local_list_bundle_files "$storage_dir")

    utils_error_no_bundle_found "$filter_tool" "$filter_user" "in storage"
    return 1
}

# Delete a bundle from local storage
# Usage: backend_local_delete <bundle_id>
backend_local_delete() {
    local bundle_id="$1"

    if ! _local_validate_storage; then
        return 1
    fi
    local storage_dir="$LOCAL_STORAGE_DIR"

    local target find_result
    target=$(_local_find_bundle_file "$storage_dir" "$bundle_id")
    find_result=$?

    if ! utils_handle_find_result "$find_result" "$bundle_id" "$target"; then
        return 1
    fi

    rm -f "$target"
    echo "Deleted: $(basename "$target")"
    return 0
}
