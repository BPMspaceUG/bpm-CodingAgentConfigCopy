#!/usr/bin/env bash
# lib/tools.sh - Tool-specific file mappings for AI coding assistants

# Credential registry - portable API keys/tokens (same across hosts)
# To add a new tool: add entry with newline-separated file paths
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
    [mistral]='.vibe/.env
.vibe/config.toml'
    [opencode]='.local/share/opencode/auth.json
.config/opencode/opencode.json'
)

# Settings registry - host+user-specific configuration (NOT portable)
# Managed separately: only pull with matching --host and --user
declare -A _SETTINGS_REGISTRY=(
    [claude]='.claude/settings.json'
)

# Derived list of supported tools (excluding 'all')
_TOOLS_SUPPORTED="${!_TOOLS_REGISTRY[*]}"

# Ordered, deterministic list of supported tools — single source of truth for
# the batch push/pull loops (Issue #76). Associative-array key order is not
# stable, so an explicit ordered list keeps per-tool output deterministic.
# Guard prevents re-declaration errors when sourced multiple times.
if [[ -z "${SUPPORTED_TOOLS+isset}" ]]; then
    readonly SUPPORTED_TOOLS=(claude codex gemini mistral opencode)
fi

# Resolve tool alias to canonical name
# Usage: _resolve_tool_alias <name>
# Returns: canonical tool name (e.g., "vibe" -> "mistral")
_resolve_tool_alias() {
    case "$1" in
        vibe) echo "mistral" ;;
        *)    echo "$1" ;;
    esac
}

# Get file mappings for a specific tool
# Usage: tools_get_files <tool> [--include-settings]
# Returns list of relative paths
# By default returns only credentials; --include-settings adds host-specific settings
tools_get_files() {
    local tool="$1"
    local include_settings="false"
    [[ "${2:-}" == "--include-settings" ]] && include_settings="true"

    if [[ "$tool" == "all" ]]; then
        # Return all credential files from all tools
        local t
        for t in "${!_TOOLS_REGISTRY[@]}"; do
            echo "${_TOOLS_REGISTRY[$t]}"
        done
        # Include settings if requested
        if [[ "$include_settings" == "true" ]]; then
            for t in "${!_SETTINGS_REGISTRY[@]}"; do
                echo "${_SETTINGS_REGISTRY[$t]}"
            done
        fi
        return 0
    fi

    # Check if tool exists in either registry
    if [[ -z "${_TOOLS_REGISTRY[$tool]+isset}" && -z "${_SETTINGS_REGISTRY[$tool]+isset}" ]]; then
        utils_error "Unknown tool: $tool"
        echo "Valid tools: $_TOOLS_SUPPORTED all" >&2
        return 1
    fi

    # Credential files
    [[ -n "${_TOOLS_REGISTRY[$tool]+isset}" ]] && echo "${_TOOLS_REGISTRY[$tool]}"

    # Settings files (only when explicitly requested)
    if [[ "$include_settings" == "true" && -n "${_SETTINGS_REGISTRY[$tool]+isset}" ]]; then
        echo "${_SETTINGS_REGISTRY[$tool]}"
    fi
}

# Get only settings files for a tool
# Usage: tools_get_settings_files <tool>
tools_get_settings_files() {
    local tool="$1"

    if [[ "$tool" == "all" ]]; then
        local t
        for t in "${!_SETTINGS_REGISTRY[@]}"; do
            echo "${_SETTINGS_REGISTRY[$t]}"
        done
        return 0
    fi

    if [[ -n "${_SETTINGS_REGISTRY[$tool]+isset}" ]]; then
        echo "${_SETTINGS_REGISTRY[$tool]}"
    fi
}

# Check if a tool is valid (public utility for validation without file retrieval)
# Usage: tools_is_valid <tool>
# Returns: 0 if valid tool, 1 if invalid
tools_is_valid() {
    local tool="$1"

    # 'all' is always valid
    [[ "$tool" == "all" ]] && return 0

    # Check against both registries
    [[ -n "${_TOOLS_REGISTRY[$tool]+isset}" || -n "${_SETTINGS_REGISTRY[$tool]+isset}" ]]
}

# Collect existing files for bundling
# Usage: tools_collect_existing <home_dir> <tool> [--include-settings]
# Returns list of absolute paths that exist
tools_collect_existing() {
    local home_dir="$1"
    local tool="${2:-all}"
    local settings_flag="${3:-}"
    local rel_path

    while IFS= read -r rel_path; do
        [[ -z "$rel_path" ]] && continue

        local abs_path="${home_dir}/${rel_path}"
        if [[ -f "$abs_path" ]]; then
            echo "$abs_path"
        fi
    done < <(tools_get_files "$tool" "$settings_flag")
}

# Count existing files for a tool
tools_count_existing() {
    local home_dir="$1"
    local tool="${2:-all}"
    local settings_flag="${3:-}"

    tools_collect_existing "$home_dir" "$tool" "$settings_flag" | wc -l
}
