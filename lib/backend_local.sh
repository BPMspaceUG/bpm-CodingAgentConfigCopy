#!/usr/bin/env bash
# lib/backend_local.sh - Local filesystem backend for bundle storage

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bundle.sh
source "${SCRIPT_DIR}/bundle.sh"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/utils.sh"

# Upload (store) a bundle to local storage
# Usage: backend_local_upload <bundle_file>
backend_local_upload() {
    local bundle_file="$1"
    local storage_dir="${CAC_LOCAL_STORAGE}"

    if [[ -z "$storage_dir" ]]; then
        echo "ERROR: CAC_LOCAL_STORAGE not configured" >&2
        return 1
    fi

    if [[ ! -d "$storage_dir" ]]; then
        echo "ERROR: Storage directory does not exist: $storage_dir" >&2
        return 1
    fi

    local filename
    filename=$(basename "$bundle_file")
    local dest="${storage_dir}/${filename}"

    if ! utils_safe_copy "$bundle_file" "$dest"; then
        return 1
    fi

    if ! utils_safe_chmod 600 "$dest"; then
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
    local storage_dir="${CAC_LOCAL_STORAGE}"

    if [[ -z "$storage_dir" ]]; then
        echo "ERROR: CAC_LOCAL_STORAGE not configured" >&2
        return 1
    fi

    local source_file

    # Check if it's an exact filename
    if [[ -f "${storage_dir}/${bundle_id}" ]]; then
        source_file="${storage_dir}/${bundle_id}"
    elif [[ -f "${storage_dir}/${bundle_id}.zip" ]]; then
        source_file="${storage_dir}/${bundle_id}.zip"
    else
        # Try to find a matching file
        local matches
        matches=$(find "$storage_dir" -maxdepth 1 -name "*${bundle_id}*.zip" -type f 2>/dev/null)
        local count
        count=$(echo "$matches" | grep -c .)

        if [[ "$count" -eq 0 ]]; then
            echo "ERROR: No bundle found matching: $bundle_id" >&2
            return 1
        elif [[ "$count" -gt 1 ]]; then
            echo "ERROR: Multiple bundles match '$bundle_id'. Be more specific:" >&2
            echo "$matches" | while read -r f; do basename "$f"; done >&2
            return 1
        fi

        source_file="$matches"
    fi

    cp "$source_file" "$output_file"
    echo "Downloaded: $(basename "$source_file")"
    return 0
}

# List bundles in local storage
# Usage: backend_local_list [--host HOST] [--user USER]
backend_local_list() {
    local storage_dir="${CAC_LOCAL_STORAGE}"

    # Parse filter arguments
    utils_parse_filter_args "$@"
    local filter_host="$FILTER_HOST"
    local filter_user="$FILTER_USER"

    if [[ -z "$storage_dir" ]]; then
        echo "ERROR: CAC_LOCAL_STORAGE not configured" >&2
        return 1
    fi

    if [[ ! -d "$storage_dir" ]]; then
        echo "No bundles found (storage directory does not exist)" >&2
        return 0
    fi

    # Find all ZIP files and parse their metadata
    local found=0

    # Sort by modification time (newest first)
    while IFS= read -r zip_file; do
        [[ -z "$zip_file" ]] && continue

        local filename
        filename=$(basename "$zip_file")

        local parsed host user timestamp
        if ! parsed=$(bundle_parse_filename "$filename"); then
            continue  # Skip files that don't match naming convention
        fi

        host=$(utils_bundle_get_host "$parsed")
        user=$(utils_bundle_get_user "$parsed")
        timestamp=$(utils_bundle_get_timestamp "$parsed")

        # Apply filters
        if [[ -n "$filter_host" && "$host" != "$filter_host" ]]; then
            continue
        fi
        if [[ -n "$filter_user" && "$user" != "$filter_user" ]]; then
            continue
        fi

        if [[ "$found" -eq 0 ]]; then
            printf "%-40s %-15s %-15s %s\n" "BUNDLE" "HOST" "USER" "TIMESTAMP"
            printf "%s\n" "--------------------------------------------------------------------------------"
        fi

        printf "%-40s %-15s %-15s %s\n" "$filename" "$host" "$user" "$timestamp"
        ((found++))

    done < <(find "$storage_dir" -maxdepth 1 -name "CodingAgentConfig_*.zip" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

    if [[ "$found" -eq 0 ]]; then
        echo "No bundles found"
    else
        echo ""
        echo "Total: $found bundle(s)"
    fi

    return 0
}

# Get the newest bundle matching criteria
# Usage: backend_local_get_newest [--host HOST] [--user USER]
# Returns the filename of the newest matching bundle
backend_local_get_newest() {
    local storage_dir="${CAC_LOCAL_STORAGE}"

    # Parse filter arguments
    utils_parse_filter_args "$@"
    local filter_host="$FILTER_HOST"
    local filter_user="$FILTER_USER"

    if [[ -z "$storage_dir" ]]; then
        utils_error "CAC_LOCAL_STORAGE not configured"
        return 1
    fi

    if [[ ! -d "$storage_dir" ]]; then
        utils_error "Storage directory does not exist: $storage_dir"
        return 1
    fi

    # Find newest matching bundle
    while IFS= read -r zip_file; do
        [[ -z "$zip_file" ]] && continue

        local filename
        filename=$(basename "$zip_file")

        local parsed host user
        if ! parsed=$(bundle_parse_filename "$filename"); then
            continue
        fi

        host=$(utils_bundle_get_host "$parsed")
        user=$(utils_bundle_get_user "$parsed")

        # Apply filters
        if [[ -n "$filter_host" && "$host" != "$filter_host" ]]; then
            continue
        fi
        if [[ -n "$filter_user" && "$user" != "$filter_user" ]]; then
            continue
        fi

        # Return the first match (newest due to sort)
        echo "$filename"
        return 0

    done < <(find "$storage_dir" -maxdepth 1 -name "CodingAgentConfig_*.zip" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

    utils_error "No matching bundle found"
    return 1
}

# Delete a bundle from local storage
# Usage: backend_local_delete <bundle_id>
backend_local_delete() {
    local bundle_id="$1"
    local storage_dir="${CAC_LOCAL_STORAGE}"

    if [[ -z "$storage_dir" ]]; then
        echo "ERROR: CAC_LOCAL_STORAGE not configured" >&2
        return 1
    fi

    local target

    if [[ -f "${storage_dir}/${bundle_id}" ]]; then
        target="${storage_dir}/${bundle_id}"
    elif [[ -f "${storage_dir}/${bundle_id}.zip" ]]; then
        target="${storage_dir}/${bundle_id}.zip"
    else
        echo "ERROR: Bundle not found: $bundle_id" >&2
        return 1
    fi

    rm -f "$target"
    echo "Deleted: $(basename "$target")"
    return 0
}
