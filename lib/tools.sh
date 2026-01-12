#!/usr/bin/env bash
# lib/tools.sh - Tool-specific file mappings for AI coding assistants

# Tool registry using associative array - single source of truth
# To add a new tool: add entry to _TOOLS_REGISTRY with newline-separated file paths
declare -A _TOOLS_REGISTRY=(
    [claude]='.claude.json
.claude/.credentials.json'
    [codex]='.codex/auth.json'
    [gemini]='.gemini/oauth_creds.json
.gemini/google_accounts.json
.gemini/settings.json
.gemini/state.json
.gemini/installation_id
.config/gcloud/application_default_credentials.json'
)

# Derived list of supported tools (excluding 'all')
_TOOLS_SUPPORTED="${!_TOOLS_REGISTRY[*]}"

# Get file mappings for a specific tool
# Usage: tools_get_files <tool>
# Returns list of relative paths
tools_get_files() {
    local tool="$1"

    if [[ "$tool" == "all" ]]; then
        # Return all files from all tools
        local t
        for t in "${!_TOOLS_REGISTRY[@]}"; do
            echo "${_TOOLS_REGISTRY[$t]}"
        done
        return 0
    fi

    # Check if tool exists in registry
    if [[ -z "${_TOOLS_REGISTRY[$tool]+isset}" ]]; then
        utils_error "Unknown tool: $tool"
        echo "Valid tools: $_TOOLS_SUPPORTED all" >&2
        return 1
    fi

    echo "${_TOOLS_REGISTRY[$tool]}"
}

# Check if a tool is valid (public utility for validation without file retrieval)
# Usage: tools_is_valid <tool>
# Returns: 0 if valid tool, 1 if invalid
tools_is_valid() {
    local tool="$1"

    # 'all' is always valid
    [[ "$tool" == "all" ]] && return 0

    # Check against registry
    [[ -n "${_TOOLS_REGISTRY[$tool]+isset}" ]]
}

# Collect existing files for bundling
# Usage: tools_collect_files <home_dir> <tool>
# Returns list of absolute paths that exist
tools_collect_existing() {
    local home_dir="$1"
    local tool="${2:-all}"
    local rel_path

    while IFS= read -r rel_path; do
        [[ -z "$rel_path" ]] && continue

        local abs_path="${home_dir}/${rel_path}"
        if [[ -f "$abs_path" ]]; then
            echo "$abs_path"
        fi
    done < <(tools_get_files "$tool")
}

# Count existing files for a tool
tools_count_existing() {
    local home_dir="$1"
    local tool="${2:-all}"

    tools_collect_existing "$home_dir" "$tool" | wc -l
}
