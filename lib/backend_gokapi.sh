#!/usr/bin/env bash
# lib/backend_gokapi.sh - Gokapi REST API backend for bundle storage

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bundle.sh
source "${SCRIPT_DIR}/bundle.sh"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/utils.sh"

# Default expiry settings (can be overridden via env)
CAC_GOKAPI_EXPIRY_DAYS="${CAC_GOKAPI_EXPIRY_DAYS:-0}"
CAC_GOKAPI_ALLOWED_DOWNLOADS="${CAC_GOKAPI_ALLOWED_DOWNLOADS:-0}"

# Internal: Validate Gokapi configuration
# Usage: _gokapi_validate_config
# Returns: 0 if valid, 1 if not (with error message)
_gokapi_validate_config() {
    if [[ -z "${CAC_GOKAPI_URL:-}" ]]; then
        utils_error "CAC_GOKAPI_URL not configured"
        return 1
    fi

    if [[ -z "${CAC_GOKAPI_API_KEY:-}" ]]; then
        utils_error "CAC_GOKAPI_API_KEY not configured"
        return 1
    fi

    return 0
}

# Internal: Make API request to Gokapi
# Usage: _gokapi_request <method> <endpoint> [curl_options...]
_gokapi_request() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local url="${CAC_GOKAPI_URL}${endpoint}"

    curl -s -X "$method" \
        -H "accept: application/json" \
        -H "apikey: ${CAC_GOKAPI_API_KEY}" \
        "$@" \
        "$url"
}

# Upload a bundle to Gokapi
# Usage: backend_gokapi_upload <bundle_file>
backend_gokapi_upload() {
    local bundle_file="$1"

    if ! _gokapi_validate_config; then
        return 1
    fi

    if [[ ! -f "$bundle_file" ]]; then
        utils_error "Bundle file not found: $bundle_file"
        return 1
    fi

    local filename
    filename=$(basename "$bundle_file")

    local response
    response=$(_gokapi_request POST "/api/files/add" \
        -H "Content-Type: multipart/form-data" \
        -F "allowedDownloads=${CAC_GOKAPI_ALLOWED_DOWNLOADS}" \
        -F "expiryDays=${CAC_GOKAPI_EXPIRY_DAYS}" \
        -F "password=" \
        -F "file=@${bundle_file}")

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        utils_error "Failed to connect to Gokapi server"
        return 1
    fi

    # Check for error in response
    if utils_json_is_error "$response"; then
        utils_error "Gokapi upload failed: $(utils_json_get_error "$response")"
        return 1
    fi

    # Extract file ID from response
    local file_id
    file_id=$(utils_json_extract_field "$response" "Id")

    if [[ -z "$file_id" ]]; then
        utils_error "Failed to parse upload response"
        echo "Response: $response" >&2
        return 1
    fi

    echo "Uploaded: $filename (ID: $file_id)"
    return 0
}

# Download a bundle from Gokapi
# Usage: backend_gokapi_download <bundle_id> <output_file>
# bundle_id can be a filename, file ID, or partial match
backend_gokapi_download() {
    local bundle_id="$1"
    local output_file="$2"

    if ! _gokapi_validate_config; then
        return 1
    fi

    # Get file list to find the download URL
    local response
    response=$(_gokapi_request GET "/api/files/list")

    if [[ -z "$response" ]] || [[ "$response" == "null" ]]; then
        utils_error "Failed to retrieve file list from Gokapi"
        return 1
    fi

    # Find matching file using shared utility
    local result download_url found_name
    local find_status
    result=$(utils_gokapi_find_file "$response" "$bundle_id")
    find_status=$?

    if [[ $find_status -eq 1 ]]; then
        utils_error "No bundle found matching: $bundle_id"
        return 1
    elif [[ $find_status -eq 2 ]]; then
        # Error message already printed by utility
        return 1
    fi

    # Parse result "url|name"
    IFS='|' read -r download_url found_name <<< "$result"

    # Construct full download URL if it's relative
    if [[ ! "$download_url" =~ ^https?:// ]]; then
        download_url="${CAC_GOKAPI_URL}${download_url}"
    fi

    # Download the file
    if ! curl -s -o "$output_file" "$download_url"; then
        utils_error "Failed to download bundle"
        return 1
    fi

    if [[ ! -s "$output_file" ]]; then
        utils_error "Downloaded file is empty"
        return 1
    fi

    echo "Downloaded: $found_name"
    return 0
}

# List bundles in Gokapi
# Usage: backend_gokapi_list [--host HOST] [--user USER]
backend_gokapi_list() {
    # Parse filter arguments
    utils_parse_filter_args "$@"
    local filter_host="$FILTER_HOST"
    local filter_user="$FILTER_USER"

    if ! _gokapi_validate_config; then
        return 1
    fi

    local response
    response=$(_gokapi_request GET "/api/files/list")

    if [[ -z "$response" ]] || [[ "$response" == "null" ]]; then
        echo "No bundles found"
        return 0
    fi

    # Parse and filter results using shared utilities
    local found=0
    local entries=()

    while IFS='|' read -r name id; do
        [[ -z "$name" ]] && continue

        local metadata
        if metadata=$(utils_parse_bundle_metadata "$name" "$filter_host" "$filter_user"); then
            entries+=("${metadata}|${id}")
            ((found++))
        fi
    done < <(utils_gokapi_extract_names "$response")

    if [[ "$found" -eq 0 ]]; then
        echo "No bundles found"
        return 0
    fi

    # Sort by timestamp (newest first) and print
    printf "%-40s %-15s %-15s %s\n" "BUNDLE" "HOST" "USER" "TIMESTAMP"
    printf "%s\n" "--------------------------------------------------------------------------------"

    # Sort entries by timestamp (field 4)
    # shellcheck disable=SC2034  # id is intentionally unused
    printf '%s\n' "${entries[@]}" | sort -t'|' -k4 -r | while IFS='|' read -r name host user timestamp id; do
        printf "%-40s %-15s %-15s %s\n" "$name" "$host" "$user" "$timestamp"
    done

    echo ""
    echo "Total: $found bundle(s)"
    return 0
}

# Get the newest bundle matching criteria
# Usage: backend_gokapi_get_newest [--host HOST] [--user USER]
# Returns the filename of the newest matching bundle
backend_gokapi_get_newest() {
    # Parse filter arguments
    utils_parse_filter_args "$@"
    local filter_host="$FILTER_HOST"
    local filter_user="$FILTER_USER"

    if ! _gokapi_validate_config; then
        return 1
    fi

    local response
    response=$(_gokapi_request GET "/api/files/list")

    if [[ -z "$response" ]] || [[ "$response" == "null" ]]; then
        return 1
    fi

    local newest_name=""
    local newest_timestamp=""

    # Parse and filter results using shared utilities
    # shellcheck disable=SC2034  # id is intentionally unused
    while IFS='|' read -r name id; do
        [[ -z "$name" ]] && continue

        local metadata
        if metadata=$(utils_parse_bundle_metadata "$name" "$filter_host" "$filter_user"); then
            # metadata format: "name|host|user|timestamp"
            local timestamp
            timestamp=$(echo "$metadata" | cut -d'|' -f4)

            # Compare timestamps (YYMMDD-HHMMSS format sorts correctly)
            if [[ -z "$newest_timestamp" || "$timestamp" > "$newest_timestamp" ]]; then
                newest_timestamp="$timestamp"
                newest_name="$name"
            fi
        fi
    done < <(utils_gokapi_extract_names "$response")

    if [[ -z "$newest_name" ]]; then
        return 1
    fi

    echo "$newest_name"
    return 0
}

# Delete a bundle from Gokapi
# Usage: backend_gokapi_delete <bundle_id>
backend_gokapi_delete() {
    local bundle_id="$1"

    if ! _gokapi_validate_config; then
        return 1
    fi

    # If bundle_id is a filename, look up the actual ID
    local file_id="$bundle_id"
    local found_name=""

    if [[ "$bundle_id" == CodingAgentConfig_* ]]; then
        local response
        response=$(_gokapi_request GET "/api/files/list")

        file_id=$(utils_gokapi_find_id "$response" "$bundle_id")
        found_name="$bundle_id"

        if [[ -z "$file_id" ]]; then
            utils_error "Bundle not found: $bundle_id"
            return 1
        fi
    fi

    # Delete by ID
    local response
    response=$(curl -s -X DELETE "${CAC_GOKAPI_URL}/api/files/delete" \
        -H "accept: */*" \
        -H "id: ${file_id}" \
        -H "apikey: ${CAC_GOKAPI_API_KEY}")

    # Check for success (Gokapi returns empty response on success)
    if utils_json_is_error "$response"; then
        utils_error "Gokapi delete failed: $(utils_json_get_error "$response")"
        return 1
    fi

    echo "Deleted: ${found_name:-$bundle_id}"
    return 0
}
