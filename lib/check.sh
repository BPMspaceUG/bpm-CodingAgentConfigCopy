#!/usr/bin/env bash
# lib/check.sh - Credential verification for AI coding assistants
#
# Provides functions to verify credentials work by making real API calls.
# Includes caching, timeout handling, and support for checking specific tools.

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/logging.sh"
# shellcheck source=lib/tools.sh
source "${SCRIPT_DIR}/tools.sh"

# ============================================================================
# Constants
# ============================================================================

# Guard with -v check to allow sourcing from multiple files.
if [[ ! -v CHECK_TIMEOUT ]]; then
    # Timeout for each check (seconds) - CLI responses can take up to 30s
    readonly CHECK_TIMEOUT=30

    # Cache TTL (seconds) - 5 minutes
    readonly CHECK_CACHE_TTL=300

    # Exit codes (per approved plan v4)
    readonly CHECK_EXIT_SUCCESS=0
    readonly CHECK_EXIT_AUTH_FAIL=1
    readonly CHECK_EXIT_UNKNOWN_TOOL=2
    readonly CHECK_EXIT_TIMEOUT=3
    readonly CHECK_EXIT_MISSING_DEP=4
fi

# ============================================================================
# Cache Utilities
# ============================================================================

# Get cache directory path (XDG compliant)
# Usage: _check_get_cache_dir
# Returns: Cache directory path
_check_get_cache_dir() {
    echo "${XDG_CACHE_HOME:-$HOME/.cache}/cac"
}

# Get cache file path
# Usage: _check_get_cache_file
# Returns: Cache file path
_check_get_cache_file() {
    echo "$(_check_get_cache_dir)/check_results"
}

# Generate cache key for a tool
# Usage: _check_generate_cache_key <tool> <user> <home_dir>
# Returns: Hash-based cache key
_check_generate_cache_key() {
    local tool="$1"
    local user="$2"
    local home_dir="$3"

    # Get tool version (or "unknown")
    local version
    version=$(_check_get_tool_version "$tool" 2>/dev/null || echo "unknown")

    # Get credential file path and mtime
    local cred_path cred_mtime
    cred_path=$(_check_get_primary_cred_file "$tool" "$home_dir")
    if [[ -f "$cred_path" ]]; then
        cred_mtime=$(stat -c "%Y" "$cred_path" 2>/dev/null || stat -f "%m" "$cred_path" 2>/dev/null || echo "0")
    else
        cred_mtime="0"
    fi

    # Generate hash of all components
    local key_data="${tool}:${user}:${version}:${cred_path}:${cred_mtime}"
    echo "$key_data" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "$key_data" | md5 2>/dev/null | cut -d' ' -f1 || echo "$key_data"
}

# Get cached result for a tool
# Usage: _check_cache_get <tool> <cache_key>
# Returns: Cached result ("OK" or "FAIL:reason") if fresh, empty if expired/missing
_check_cache_get() {
    local tool="$1"
    local cache_key="$2"
    local cache_file
    cache_file=$(_check_get_cache_file)

    [[ ! -f "$cache_file" ]] && return 0

    local now line_tool line_key line_timestamp line_result
    now=$(date +%s)

    while IFS=: read -r line_tool line_key line_timestamp line_result; do
        if [[ "$line_tool" == "$tool" && "$line_key" == "$cache_key" ]]; then
            local age=$((now - line_timestamp))
            if [[ $age -lt $CHECK_CACHE_TTL ]]; then
                echo "$line_result"
                return 0
            fi
        fi
    done < "$cache_file"

    return 0
}

# Store result in cache
# Usage: _check_cache_set <tool> <cache_key> <result>
_check_cache_set() {
    local tool="$1"
    local cache_key="$2"
    local result="$3"
    local cache_dir cache_file timestamp

    cache_dir=$(_check_get_cache_dir)
    cache_file=$(_check_get_cache_file)
    timestamp=$(date +%s)

    # Create cache directory if needed
    if [[ ! -d "$cache_dir" ]]; then
        mkdir -p "$cache_dir"
        chmod 700 "$cache_dir"
    fi

    # Remove old entries for this tool and add new one
    if [[ -f "$cache_file" ]]; then
        local temp_file="${cache_file}.tmp"
        grep -v "^${tool}:" "$cache_file" > "$temp_file" 2>/dev/null || true
        echo "${tool}:${cache_key}:${timestamp}:${result}" >> "$temp_file"
        mv "$temp_file" "$cache_file"
    else
        echo "${tool}:${cache_key}:${timestamp}:${result}" > "$cache_file"
    fi

    chmod 600 "$cache_file"
}

# ============================================================================
# Timeout Utilities
# ============================================================================

# Detect timeout command (GNU timeout or gtimeout on macOS)
# Usage: _check_get_timeout_cmd
# Returns: Path to timeout command, or exits with code 4 if not found
_check_get_timeout_cmd() {
    if command -v timeout &>/dev/null; then
        echo "timeout"
    elif command -v gtimeout &>/dev/null; then
        echo "gtimeout"
    else
        utils_error "Required command 'timeout' not found. On macOS, install with: brew install coreutils"
        return $CHECK_EXIT_MISSING_DEP
    fi
}

# Show spinning animation while a background process runs
# Usage: _check_spinner <pid>
# Writes directly to /dev/tty to avoid capture by $()
_check_spinner() {
    local pid="$1"
    local frames=('|' '/' '-' '\')
    local i=0

    # Only show spinner if terminal is available
    [[ -c /dev/tty ]] || return 0

    while kill -0 "$pid" 2>/dev/null; do
        printf '%s\b' "${frames[i]}" > /dev/tty
        i=$(( (i + 1) % 4 ))
        sleep 0.2
    done

    # Clear spinner character
    printf ' \b' > /dev/tty
}

# Run command with timeout and spinner
# Usage: _check_with_timeout <seconds> <command...>
# Returns: 0 on success, CHECK_EXIT_TIMEOUT on timeout, command exit code otherwise
_check_with_timeout() {
    local seconds="$1"
    shift

    local timeout_cmd
    if ! timeout_cmd=$(_check_get_timeout_cmd); then
        return $CHECK_EXIT_MISSING_DEP
    fi

    # Create temp files for output and exit code with secure permissions
    local tmpfile exitfile
    tmpfile=$(mktemp)
    exitfile=$(mktemp)
    chmod 600 "$tmpfile" "$exitfile"

    # Run command in subshell, save exit code (capture before echo overwrites $?)
    (
        "$timeout_cmd" "$seconds" "$@" > "$tmpfile" 2>&1
        cmd_exit=$?
        echo "$cmd_exit" > "$exitfile"
    ) &
    local pid=$!

    # Show spinner while waiting (writes to /dev/tty directly)
    _check_spinner "$pid"

    # Wait for completion
    wait "$pid" 2>/dev/null

    # Get the actual command exit code
    local exit_code
    exit_code=$(cat "$exitfile")

    # Output the captured result
    cat "$tmpfile"

    # Cleanup
    rm -f "$tmpfile" "$exitfile"

    # Translate timeout exit codes to our standard
    if [[ $exit_code -eq 124 || $exit_code -eq 137 ]]; then
        return $CHECK_EXIT_TIMEOUT
    fi

    return "$exit_code"
}

# ============================================================================
# Tool Utilities
# ============================================================================

# Get primary credential file for a tool
# Usage: _check_get_primary_cred_file <tool> <home_dir>
# Returns: Path to primary credential file
_check_get_primary_cred_file() {
    local tool="$1"
    local home_dir="$2"

    case "$tool" in
        claude)
            echo "${home_dir}/.claude.json"
            ;;
        codex)
            echo "${home_dir}/.codex/auth.json"
            ;;
        gemini)
            echo "${home_dir}/.gemini/oauth_creds.json"
            ;;
        mistral)
            echo "${home_dir}/.vibe/.env"
            ;;
    esac
}

# Get tool version
# Usage: _check_get_tool_version <tool>
# Returns: Version string or "unknown"
_check_get_tool_version() {
    local tool="$1"

    case "$tool" in
        claude)
            claude --version 2>/dev/null | head -1 || echo "unknown"
            ;;
        codex)
            codex --version 2>/dev/null | head -1 || echo "unknown"
            ;;
        gemini)
            gemini --version 2>/dev/null | head -1 || echo "unknown"
            ;;
        mistral)
            vibe --version 2>/dev/null | head -1 || echo "unknown"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Check if tool binary exists
# Usage: _check_tool_binary_exists <tool>
# Returns: 0 if exists, 1 if not
_check_tool_binary_exists() {
    local tool="$1"

    case "$tool" in
        claude)
            command -v claude &>/dev/null
            ;;
        codex)
            command -v codex &>/dev/null
            ;;
        gemini)
            command -v gemini &>/dev/null
            ;;
        mistral)
            command -v vibe &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# Get display name for tool
# Usage: _check_get_tool_display_name <tool>
_check_get_tool_display_name() {
    local tool="$1"

    case "$tool" in
        claude) echo "Claude" ;;
        codex) echo "Codex" ;;
        gemini) echo "Gemini" ;;
        mistral) echo "Mistral Vibe" ;;
        *) echo "$tool" ;;
    esac
}

# ============================================================================
# Check Functions
# ============================================================================

# Check Claude credentials
# Usage: check_tool_claude <use_sudo> <target_user>
# Returns: 0 on success, 1 on auth fail, 3 on timeout, 4 on missing binary
check_tool_claude() {
    local use_sudo="$1"
    local target_user="$2"
    local output exit_code

    if ! _check_tool_binary_exists "claude"; then
        utils_error "Claude binary not found"
        return $CHECK_EXIT_MISSING_DEP
    fi

    local cmd
    if [[ "$use_sudo" == "true" ]]; then
        cmd=(sudo -u "$target_user" claude -p "Respond only with: CLAUDE_OK" --dangerously-skip-permissions)
    else
        cmd=(claude -p "Respond only with: CLAUDE_OK" --dangerously-skip-permissions)
    fi

    utils_verbose "Running: ${cmd[*]}"

    output=$(_check_with_timeout $CHECK_TIMEOUT "${cmd[@]}" 2>&1)
    exit_code=$?

    if [[ $exit_code -eq $CHECK_EXIT_TIMEOUT ]]; then
        return $CHECK_EXIT_TIMEOUT
    fi

    if echo "$output" | grep -q "CLAUDE_OK"; then
        return $CHECK_EXIT_SUCCESS
    else
        utils_verbose "Claude response: $output"
        return $CHECK_EXIT_AUTH_FAIL
    fi
}

# Check Codex credentials
# Usage: check_tool_codex <use_sudo> <target_user>
# Returns: 0 on success, 1 on auth fail, 3 on timeout, 4 on missing binary
check_tool_codex() {
    local use_sudo="$1"
    local target_user="$2"
    local output exit_code

    if ! _check_tool_binary_exists "codex"; then
        utils_error "Codex binary not found"
        return $CHECK_EXIT_MISSING_DEP
    fi

    local cmd
    if [[ "$use_sudo" == "true" ]]; then
        cmd=(sudo -u "$target_user" codex exec "Respond only with the text: CODEX_OK" --skip-git-repo-check)
    else
        cmd=(codex exec "Respond only with the text: CODEX_OK" --skip-git-repo-check)
    fi

    utils_verbose "Running: ${cmd[*]}"

    output=$(_check_with_timeout $CHECK_TIMEOUT "${cmd[@]}" 2>&1)
    exit_code=$?

    if [[ $exit_code -eq $CHECK_EXIT_TIMEOUT ]]; then
        return $CHECK_EXIT_TIMEOUT
    fi

    if echo "$output" | grep -q "CODEX_OK"; then
        return $CHECK_EXIT_SUCCESS
    else
        utils_verbose "Codex response: $output"
        return $CHECK_EXIT_AUTH_FAIL
    fi
}

# Check Gemini credentials
# Usage: check_tool_gemini <use_sudo> <target_user>
# Returns: 0 on success, 1 on auth fail, 3 on timeout, 4 on missing binary
check_tool_gemini() {
    local use_sudo="$1"
    local target_user="$2"
    local output exit_code

    if ! _check_tool_binary_exists "gemini"; then
        utils_error "Gemini binary not found"
        return $CHECK_EXIT_MISSING_DEP
    fi

    local cmd
    if [[ "$use_sudo" == "true" ]]; then
        cmd=(sudo -u "$target_user" gemini -p "Respond only with: GEMINI_OK")
    else
        cmd=(gemini -p "Respond only with: GEMINI_OK")
    fi

    utils_verbose "Running: ${cmd[*]}"

    output=$(_check_with_timeout $CHECK_TIMEOUT "${cmd[@]}" 2>&1)
    exit_code=$?

    if [[ $exit_code -eq $CHECK_EXIT_TIMEOUT ]]; then
        return $CHECK_EXIT_TIMEOUT
    fi

    if echo "$output" | grep -q "GEMINI_OK"; then
        return $CHECK_EXIT_SUCCESS
    else
        utils_verbose "Gemini response: $output"
        return $CHECK_EXIT_AUTH_FAIL
    fi
}

# Check Mistral credentials
# Usage: check_tool_mistral <use_sudo> <target_user> <home_dir>
# Returns: 0 on success, 1 on auth fail, 3 on timeout, 4 on missing binary
check_tool_mistral() {
    local use_sudo="$1"
    local target_user="$2"
    local home_dir="$3"
    local output exit_code

    if ! _check_tool_binary_exists "mistral"; then
        utils_error "Vibe binary not found"
        return $CHECK_EXIT_MISSING_DEP
    fi

    # Read MISTRAL_API_KEY from ~/.vibe/.env
    local env_file="${home_dir}/.vibe/.env"
    if [[ ! -f "$env_file" ]]; then
        utils_error "Mistral env file not found: $env_file"
        return $CHECK_EXIT_AUTH_FAIL
    fi

    local api_key
    if [[ "$use_sudo" == "true" ]]; then
        api_key=$(sudo -u "$target_user" bash -c "grep -E '^MISTRAL_API_KEY=' '$env_file' | cut -d= -f2-" 2>/dev/null)
    else
        api_key=$(grep -E '^MISTRAL_API_KEY=' "$env_file" | cut -d= -f2- 2>/dev/null)
    fi

    # Strip surrounding quotes if present
    api_key="${api_key%\"}"
    api_key="${api_key#\"}"
    api_key="${api_key%\'}"
    api_key="${api_key#\'}"

    if [[ -z "$api_key" ]]; then
        utils_error "MISTRAL_API_KEY not found in $env_file"
        return $CHECK_EXIT_AUTH_FAIL
    fi

    utils_verbose "Testing Mistral API key via /v1/models endpoint"

    output=$(_check_with_timeout 10 curl -s --max-time 10 \
        -H "Authorization: Bearer ${api_key}" \
        "https://api.mistral.ai/v1/models" 2>&1)
    exit_code=$?

    if [[ $exit_code -eq $CHECK_EXIT_TIMEOUT ]]; then
        return $CHECK_EXIT_TIMEOUT
    fi

    if echo "$output" | grep -q '"id"'; then
        return $CHECK_EXIT_SUCCESS
    else
        utils_verbose "Mistral API response: $output"
        return $CHECK_EXIT_AUTH_FAIL
    fi
}

# Check a single tool
# Usage: check_single_tool <tool> <use_sudo> <target_user> <home_dir>
# Returns: 0=success, 1=auth fail, 2=unknown tool, 3=timeout, 4=missing dep
check_single_tool() {
    local tool="$1"
    local use_sudo="$2"
    local target_user="$3"
    local home_dir="$4"
    local display_name cache_key cached_result result exit_code

    # Validate tool name
    if ! tools_is_valid "$tool"; then
        utils_error "Unknown tool: $tool"
        echo "Valid tools: claude codex gemini mistral" >&2
        return $CHECK_EXIT_UNKNOWN_TOOL
    fi

    display_name=$(_check_get_tool_display_name "$tool")

    # Check if configured (credential file exists)
    local cred_file
    cred_file=$(_check_get_primary_cred_file "$tool" "$home_dir")
    if [[ ! -f "$cred_file" ]]; then
        utils_warn "Skipping $display_name: no credentials found ($cred_file)"
        # Return special value to indicate skipped (not pass or fail)
        return 100
    fi

    echo -n "Checking $display_name credentials... "

    # Check cache
    cache_key=$(_check_generate_cache_key "$tool" "$target_user" "$home_dir")
    cached_result=$(_check_cache_get "$tool" "$cache_key")

    if [[ -n "$cached_result" ]]; then
        if [[ "$cached_result" == "OK" ]]; then
            echo "OK (cached)"
            return $CHECK_EXIT_SUCCESS
        else
            echo "FAILED (cached)"
            return $CHECK_EXIT_AUTH_FAIL
        fi
    fi

    # Run actual check
    case "$tool" in
        claude)
            check_tool_claude "$use_sudo" "$target_user"
            exit_code=$?
            ;;
        codex)
            check_tool_codex "$use_sudo" "$target_user"
            exit_code=$?
            ;;
        gemini)
            check_tool_gemini "$use_sudo" "$target_user"
            exit_code=$?
            ;;
        mistral)
            check_tool_mistral "$use_sudo" "$target_user" "$home_dir"
            exit_code=$?
            ;;
    esac

    # Update cache and display result
    case $exit_code in
        "$CHECK_EXIT_SUCCESS")
            echo "OK"
            _check_cache_set "$tool" "$cache_key" "OK"
            ;;
        "$CHECK_EXIT_AUTH_FAIL")
            echo "FAILED"
            _check_cache_set "$tool" "$cache_key" "FAIL"
            ;;
        "$CHECK_EXIT_TIMEOUT")
            echo "TIMEOUT"
            ;;
        "$CHECK_EXIT_MISSING_DEP")
            echo "MISSING"
            ;;
    esac

    return $exit_code
}

# Check all configured tools
# Usage: check_all_tools <use_sudo> <target_user> <home_dir>
# Returns: Highest priority exit code (4 > 3 > 2 > 1 > 0)
check_all_tools() {
    local use_sudo="$1"
    local target_user="$2"
    local home_dir="$3"

    local tools=("claude" "codex" "gemini" "mistral")
    local highest_exit=0
    local passed=0 failed=0 skipped=0 total=0
    local exit_code

    for tool in "${tools[@]}"; do
        check_single_tool "$tool" "$use_sudo" "$target_user" "$home_dir"
        exit_code=$?

        case $exit_code in
            100)
                # Skipped (not configured)
                ((skipped++)) || true
                ;;
            "$CHECK_EXIT_SUCCESS")
                ((passed++)) || true
                ((total++)) || true
                ;;
            *)
                ((failed++)) || true
                ((total++)) || true
                # Track highest priority exit code
                if [[ $exit_code -gt $highest_exit ]]; then
                    highest_exit=$exit_code
                fi
                ;;
        esac
    done

    echo ""

    if [[ $total -eq 0 ]]; then
        utils_warn "No tools configured"
        return $CHECK_EXIT_SUCCESS
    fi

    if [[ $failed -eq 0 ]]; then
        echo "$passed of $total checks passed."
    else
        echo "$failed of $total checks failed. Run 'cac check --verbose' for details."
    fi

    return $highest_exit
}
