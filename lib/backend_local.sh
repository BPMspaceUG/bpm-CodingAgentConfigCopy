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
        utils_error "CAC_LOCAL_STORAGE not configured"
        return 1
    fi

    if [[ ! -d "$storage_dir" ]]; then
        utils_error "Storage directory does not exist: $storage_dir"
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
        utils_error "CAC_LOCAL_STORAGE not configured"
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
            utils_error "No bundle found matching: $bundle_id"
            return 1
        elif [[ "$count" -gt 1 ]]; then
            utils_error "Multiple bundles match '$bundle_id'. Be more specific:"
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
        utils_error "CAC_LOCAL_STORAGE not configured"
        return 1
    fi

    if [[ ! -d "$storage_dir" ]]; then
        echo "No bundles found (storage directory does not exist)"
        return 0
    fi

    # Find all ZIP files and parse their metadata
    local found=0

    # Sort by modification time (newest first)
    while IFS= read -r zip_file; do
        [[ -z "$zip_file" ]] && continue

        local filename
        filename=$(basename "$zip_file")

        local metadata
        if ! metadata=$(utils_parse_bundle_metadata "$filename" "$filter_host" "$filter_user"); then
            continue  # Skip files that don't match or are filtered out
        fi

        # metadata format: "name|host|user|timestamp"
        local host user timestamp
        IFS='|' read -r _ host user timestamp <<< "$metadata"

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

        # Use shared utility for parsing and filtering
        if utils_parse_bundle_metadata "$filename" "$filter_host" "$filter_user" >/dev/null; then
            # Return the first match (newest due to sort)
            echo "$filename"
            return 0
        fi

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
        utils_error "CAC_LOCAL_STORAGE not configured"
        return 1
    fi

    local target

    if [[ -f "${storage_dir}/${bundle_id}" ]]; then
        target="${storage_dir}/${bundle_id}"
    elif [[ -f "${storage_dir}/${bundle_id}.zip" ]]; then
        target="${storage_dir}/${bundle_id}.zip"
    else
        utils_error "Bundle not found: $bundle_id"
        return 1
    fi

    rm -f "$target"
    echo "Deleted: $(basename "$target")"
    return 0
}
