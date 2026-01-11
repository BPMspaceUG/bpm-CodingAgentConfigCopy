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

    # Find matching file
    # Response is JSON array, we need to find the file by name or ID
    local download_url=""
    local found_name=""

    # Use jq if available, otherwise fall back to grep parsing
    if command -v jq &>/dev/null; then
        # Try exact ID match first
        download_url=$(echo "$response" | jq -r --arg id "$bundle_id" '.[] | select(.Id == $id) | .UrlDownload // empty')
        found_name=$(echo "$response" | jq -r --arg id "$bundle_id" '.[] | select(.Id == $id) | .Name // empty')

        # Try exact filename match
        if [[ -z "$download_url" ]]; then
            download_url=$(echo "$response" | jq -r --arg name "$bundle_id" '.[] | select(.Name == $name) | .UrlDownload // empty')
            found_name=$(echo "$response" | jq -r --arg name "$bundle_id" '.[] | select(.Name == $name) | .Name // empty')
        fi

        # Try partial filename match
        if [[ -z "$download_url" ]]; then
            local matches
            matches=$(echo "$response" | jq -r --arg pat "$bundle_id" '[.[] | select(.Name | contains($pat))] | length')

            if [[ "$matches" -eq 1 ]]; then
                download_url=$(echo "$response" | jq -r --arg pat "$bundle_id" '.[] | select(.Name | contains($pat)) | .UrlDownload')
                found_name=$(echo "$response" | jq -r --arg pat "$bundle_id" '.[] | select(.Name | contains($pat)) | .Name')
            elif [[ "$matches" -gt 1 ]]; then
                utils_error "Multiple bundles match '$bundle_id'. Be more specific:"
                echo "$response" | jq -r --arg pat "$bundle_id" '.[] | select(.Name | contains($pat)) | .Name' >&2
                return 1
            fi
        fi
    else
        # Fallback: basic grep parsing (less reliable)
        # Look for matching Name field in JSON
        if echo "$response" | grep -q "\"Name\":\"${bundle_id}\""; then
            # Extract UrlDownload following this Name
            download_url=$(utils_json_extract_field "$response" "UrlDownload")
            found_name="$bundle_id"
        elif echo "$response" | grep -q "\"Id\":\"${bundle_id}\""; then
            download_url=$(utils_json_extract_field "$response" "UrlDownload")
            found_name="$bundle_id"
        else
            # Try partial match
            local match_count
            match_count=$(echo "$response" | grep -o "\"Name\":\"[^\"]*${bundle_id}[^\"]*\"" | wc -l)
            if [[ "$match_count" -eq 0 ]]; then
                utils_error "No bundle found matching: $bundle_id"
                return 1
            elif [[ "$match_count" -gt 1 ]]; then
                utils_error "Multiple bundles match '$bundle_id'. Be more specific:"
                echo "$response" | grep -o "\"Name\":\"[^\"]*${bundle_id}[^\"]*\"" | cut -d'"' -f4 >&2
                return 1
            fi
            found_name=$(echo "$response" | grep -o "\"Name\":\"[^\"]*${bundle_id}[^\"]*\"" | head -1 | cut -d'"' -f4)
            download_url=$(echo "$response" | grep -B5 "\"Name\":\"${found_name}\"" | grep -o "\"UrlDownload\":\"[^\"]*\"" | cut -d'"' -f4)
        fi
    fi

    if [[ -z "$download_url" ]]; then
        utils_error "No bundle found matching: $bundle_id"
        return 1
    fi

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

    # Parse and filter results
    local found=0
    local entries=()

    if command -v jq &>/dev/null; then
        # Use jq for reliable JSON parsing
        # shellcheck disable=SC2034  # downloads_remaining and expiry_time are intentionally unused placeholders
        while IFS='|' read -r name id downloads_remaining expiry_time; do
            [[ -z "$name" ]] && continue
            # Only process CodingAgentConfig bundles
            [[ "$name" != CodingAgentConfig_* ]] && continue

            local parsed host user timestamp
            if ! parsed=$(bundle_parse_filename "$name"); then
                continue
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

            entries+=("$name|$host|$user|$timestamp|$id")
            ((found++))

        done < <(echo "$response" | jq -r '.[] | "\(.Name)|\(.Id)|\(.DownloadsRemaining)|\(.ExpireAtString)"')
    else
        # Fallback: grep-based parsing
        local names
        names=$(echo "$response" | grep -o '"Name":"[^"]*"' | cut -d'"' -f4)

        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            [[ "$name" != CodingAgentConfig_* ]] && continue

            local parsed host user timestamp
            if ! parsed=$(bundle_parse_filename "$name"); then
                continue
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

            entries+=("$name|$host|$user|$timestamp|")
            ((found++))

        done <<< "$names"
    fi

    if [[ "$found" -eq 0 ]]; then
        echo "No bundles found"
        return 0
    fi

    # Sort by timestamp (newest first) and print
    printf "%-40s %-15s %-15s %s\n" "BUNDLE" "HOST" "USER" "TIMESTAMP"
    printf "%s\n" "--------------------------------------------------------------------------------"

    # Sort entries by timestamp (field 4)
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

    if command -v jq &>/dev/null; then
        # shellcheck disable=SC2034  # timestamp_str is intentionally unused placeholder
        while IFS='|' read -r name timestamp_str; do
            [[ -z "$name" ]] && continue
            [[ "$name" != CodingAgentConfig_* ]] && continue

            local parsed host user timestamp
            if ! parsed=$(bundle_parse_filename "$name"); then
                continue
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

            # Compare timestamps (YYMMDD-HHMMSS format sorts correctly)
            if [[ -z "$newest_timestamp" || "$timestamp" > "$newest_timestamp" ]]; then
                newest_timestamp="$timestamp"
                newest_name="$name"
            fi

        done < <(echo "$response" | jq -r '.[] | "\(.Name)|\(.ExpireAtString)"')
    else
        # Fallback
        local names
        names=$(echo "$response" | grep -o '"Name":"[^"]*"' | cut -d'"' -f4)

        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            [[ "$name" != CodingAgentConfig_* ]] && continue

            local parsed host user timestamp
            if ! parsed=$(bundle_parse_filename "$name"); then
                continue
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

            if [[ -z "$newest_timestamp" || "$timestamp" > "$newest_timestamp" ]]; then
                newest_timestamp="$timestamp"
                newest_name="$name"
            fi

        done <<< "$names"
    fi

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

    # If bundle_id is a filename, we need to find the actual ID
    local file_id="$bundle_id"
    local found_name=""

    if [[ "$bundle_id" == CodingAgentConfig_* ]]; then
        # It's a filename, look up the ID
        local response
        response=$(_gokapi_request GET "/api/files/list")

        if command -v jq &>/dev/null; then
            file_id=$(echo "$response" | jq -r --arg name "$bundle_id" '.[] | select(.Name == $name) | .Id // empty')
            found_name="$bundle_id"
        else
            # Try to extract ID near the matching filename
            if echo "$response" | grep -q "\"Name\":\"${bundle_id}\""; then
                file_id=$(echo "$response" | grep -B10 "\"Name\":\"${bundle_id}\"" | grep -o "\"Id\":\"[^\"]*\"" | tail -1 | cut -d'"' -f4)
                found_name="$bundle_id"
            fi
        fi

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
    # or check for error
    if utils_json_is_error "$response"; then
        utils_error "Gokapi delete failed: $(utils_json_get_error "$response")"
        return 1
    fi

    echo "Deleted: ${found_name:-$bundle_id}"
    return 0
}
