#!/usr/bin/env bash
# lib/tools.sh - Tool-specific file mappings for AI coding assistants

# Define file mappings for each supported tool
# Each function returns a list of relative paths (from home directory) that should be bundled

# Claude Code file mappings
tools_claude_files() {
    cat <<'EOF'
.claude.json
.claude/.credentials.json
EOF
}

# Codex CLI file mappings
tools_codex_files() {
    cat <<'EOF'
.codex/auth.json
EOF
}

# Gemini CLI file mappings
tools_gemini_files() {
    cat <<'EOF'
.gemini/oauth_creds.json
.gemini/google_accounts.json
.gemini/settings.json
.gemini/state.json
.gemini/installation_id
.config/gcloud/application_default_credentials.json
EOF
}

# Get all file mappings for all tools
tools_all_files() {
    tools_claude_files
    tools_codex_files
    tools_gemini_files
}

# Get file mappings for a specific tool
# Usage: tools_get_files <tool>
# Returns list of relative paths
tools_get_files() {
    local tool="$1"

    case "$tool" in
        claude)
            tools_claude_files
            ;;
        codex)
            tools_codex_files
            ;;
        gemini)
            tools_gemini_files
            ;;
        all)
            tools_all_files
            ;;
        *)
            echo "ERROR: Unknown tool: $tool" >&2
            echo "Valid tools: claude, codex, gemini, all" >&2
            return 1
            ;;
    esac
}

# Check if a tool is valid
tools_is_valid() {
    local tool="$1"

    case "$tool" in
        claude|codex|gemini|all)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Get list of all supported tools (excluding 'all')
tools_list() {
    echo "claude"
    echo "codex"
    echo "gemini"
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
