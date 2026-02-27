#!/usr/bin/env bash
# lib/env.sh - AI coding tool environment installation and management
#
# Provides functions to install, update, and check status of AI coding tools
# (Claude Code, Codex CLI, Gemini CLI, continuous-claude).

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/logging.sh"

# ============================================================================
# Constants
# ============================================================================

# Exit codes
# Guard with -v check to allow sourcing from multiple files.
if [[ ! -v ENV_EXIT_SUCCESS ]]; then
    readonly ENV_EXIT_SUCCESS=0
    readonly ENV_EXIT_PARTIAL=1
    readonly ENV_EXIT_ALL_FAILED=2
    readonly ENV_EXIT_INVALID_ARG=3
    readonly ENV_EXIT_MISSING_DEP=4

    # Tool registry: tool|display_name|detect_cmd|version_cmd|install_type|optional
    # - tool: Internal name (lowercase, used in commands)
    # - display_name: Human-readable name for display
    # - detect_cmd: Command to detect if tool is installed
    # - version_cmd: Command to get version (output parsed with head -1)
    # - install_type: "curl" or "npm"
    # - optional: "yes" if not installed with --all, "no" otherwise
    readonly -a _ENV_REGISTRY=(
        "claude|Claude Code|command -v claude|claude --version|curl|no"
        "codex|Codex CLI|command -v codex|codex --version|npm|no"
        "gemini|Gemini CLI|command -v gemini|gemini --version|npm|no"
        "continuous-claude|continuous-claude|command -v continuous-claude|continuous-claude --version|curl|yes"
        "mistral|Mistral Vibe|command -v vibe|vibe --version|curl|no"
    )

    # Install URLs for curl-based tools
    declare -A _ENV_INSTALL_URLS=(
        [claude]="https://claude.ai/install.sh"
        [continuous-claude]="https://raw.githubusercontent.com/AnandChowdhary/continuous-claude/main/install.sh"
        [mistral]="https://mistral.ai/vibe/install.sh"
    )

    # npm package names
    declare -A _ENV_NPM_PACKAGES=(
        [codex]="@openai/codex"
        [gemini]="@google/gemini-cli"
    )

    # Minimum Node.js version required for npm tools
    readonly ENV_MIN_NODE_VERSION="18"

    # npm package names for latest version lookup (Issue #30)
    declare -A _ENV_NPM_LOOKUP=(
        [claude]="@anthropic-ai/claude-code"
        [codex]="@openai/codex"
        [gemini]="@google/gemini-cli"
        [continuous-claude]="continuous-claude"
    )

    # Cache TTL for latest version lookups (seconds) - 5 minutes
    readonly _ENV_LATEST_CACHE_TTL=300
fi

# ============================================================================
# Registry Access Functions
# ============================================================================

# Get a field from the registry for a tool
# Usage: _env_get_field <tool> <field_index>
# field_index: 0=tool, 1=display_name, 2=detect_cmd, 3=version_cmd, 4=install_type, 5=optional
_env_get_field() {
    local tool="$1"
    local field_index="$2"

    for entry in "${_ENV_REGISTRY[@]}"; do
        local entry_tool="${entry%%|*}"
        if [[ "$entry_tool" == "$tool" ]]; then
            # Split by | and get the field
            IFS='|' read -ra fields <<< "$entry"
            echo "${fields[$field_index]}"
            return 0
        fi
    done
    return 1
}

# Get display name for a tool
# Usage: env_get_display_name <tool>
env_get_display_name() {
    _env_get_field "$1" 1
}

# Get detect command for a tool
# Usage: env_get_detect_cmd <tool>
env_get_detect_cmd() {
    _env_get_field "$1" 2
}

# Get version command for a tool
# Usage: env_get_version_cmd <tool>
env_get_version_cmd() {
    _env_get_field "$1" 3
}

# Get install type for a tool
# Usage: env_get_install_type <tool>
env_get_install_type() {
    _env_get_field "$1" 4
}

# Check if a tool is optional
# Usage: env_is_optional <tool>
# Returns: 0 if optional, 1 if core
env_is_optional() {
    local optional
    optional=$(_env_get_field "$1" 5)
    [[ "$optional" == "yes" ]]
}

# Get all tool names from registry
# Usage: env_get_all_tools
env_get_all_tools() {
    for entry in "${_ENV_REGISTRY[@]}"; do
        echo "${entry%%|*}"
    done
}

# Get core (non-optional) tool names
# Usage: env_get_core_tools
env_get_core_tools() {
    for entry in "${_ENV_REGISTRY[@]}"; do
        IFS='|' read -ra fields <<< "$entry"
        if [[ "${fields[5]}" != "yes" ]]; then
            echo "${fields[0]}"
        fi
    done
}

# ============================================================================
# Validation Functions
# ============================================================================

# Validate tool name against registry
# Usage: env_validate_tool <tool>
# Returns: 0 if valid, 1 if invalid
env_validate_tool() {
    local tool="$1"

    for entry in "${_ENV_REGISTRY[@]}"; do
        if [[ "${entry%%|*}" == "$tool" ]]; then
            return 0
        fi
    done
    return 1
}

# Validate scope flag
# Usage: env_validate_scope <scope>
# Returns: 0 if valid, 1 if invalid
env_validate_scope() {
    local scope="$1"

    case "$scope" in
        user|global|all|"")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================================
# Dependency Checking
# ============================================================================

# Check if Node.js is installed and meets minimum version
# Try 'node' first, fall back to 'nodejs' (Debian/Ubuntu name)
# to handle cases where a wrapper shadows real Node.js.
# Usage: env_check_node
# Returns: 0 if OK, 1 if missing/too old
env_check_node() {
    local version="" node_bin=""

    # Try 'node --version' first.
    # Check exit code separately from sed to catch wrappers that
    # print junk to stdout AND exit non-zero — a pipeline would mask the failure
    # because the exit code of a pipeline is the LAST command (sed), not node.
    local raw=""
    if command -v node &>/dev/null; then
        if raw=$(node --version 2>/dev/null); then
            version="${raw#v}"
            node_bin="node"
        fi
    fi

    # Fall back to 'nodejs' (Debian/Ubuntu binary name) if 'node'
    # failed or returned empty (e.g. wrapper doesn't support --version)
    if [[ -z "$version" ]] && command -v nodejs &>/dev/null; then
        if raw=$(nodejs --version 2>/dev/null); then
            version="${raw#v}"
            node_bin="nodejs"
        fi
    fi

    # No working binary found at all
    if [[ -z "$version" ]]; then
        if command -v node &>/dev/null || command -v nodejs &>/dev/null; then
            utils_error "Node.js version could not be determined"
        else
            utils_error "Node.js not found. Required for npm-based tools."
        fi
        return 1
    fi

    utils_verbose "Node.js detected via '${node_bin}' ($(command -v "$node_bin"))"

    local major
    major="${version%%.*}"

    # Issue #32: Guard against non-numeric major version
    if [[ -z "$major" ]] || [[ ! "$major" =~ ^[0-9]+$ ]]; then
        utils_error "Node.js version could not be determined"
        return 1
    fi

    if [[ "$major" -lt "$ENV_MIN_NODE_VERSION" ]]; then
        utils_error "Node.js version $version is too old. Minimum required: v${ENV_MIN_NODE_VERSION}"
        return 1
    fi

    return 0
}

# Check if npm is installed
# Usage: env_check_npm
# Returns: 0 if OK, 1 if missing
env_check_npm() {
    if ! command -v npm &>/dev/null; then
        utils_error "npm not found. Required for npm-based tools."
        return 1
    fi
    return 0
}

# Check if curl is installed
# Usage: env_check_curl
# Returns: 0 if OK, 1 if missing
env_check_curl() {
    if ! command -v curl &>/dev/null; then
        utils_error "curl not found. Required for curl-based tools."
        return 1
    fi
    return 0
}

# Check dependencies for a tool's install type
# Usage: env_check_dependencies <tool>
# Returns: 0 if all deps met, 1 otherwise
env_check_dependencies() {
    local tool="$1"
    local install_type
    install_type=$(env_get_install_type "$tool")

    case "$install_type" in
        npm)
            env_check_node && env_check_npm
            ;;
        curl)
            env_check_curl
            ;;
        *)
            utils_error "Unknown install type: $install_type"
            return 1
            ;;
    esac
}

# ============================================================================
# Detection Functions
# ============================================================================

# Check if a tool is installed
# Usage: env_is_installed <tool>
# Returns: 0 if installed, 1 if not
env_is_installed() {
    local tool="$1"
    local detect_cmd

    if ! detect_cmd=$(env_get_detect_cmd "$tool"); then
        return 1
    fi

    eval "$detect_cmd" &>/dev/null
}

# Get version of an installed tool
# Usage: env_get_version <tool>
# Returns: Version string or "unknown"
env_get_version() {
    local tool="$1"
    local version_cmd

    if ! version_cmd=$(env_get_version_cmd "$tool"); then
        echo "unknown"
        return 1
    fi

    local version
    version=$(eval "$version_cmd" 2>/dev/null | head -1)
    echo "${version:-unknown}"
}

# ============================================================================
# Legacy Bun Install Detection
# ============================================================================

# Warn if legacy Bun-based installs exist in /opt directories.
# Warning-only — does not block or modify other output.
# Usage: _env_warn_legacy_bun_install [claude_dir] [cc_dir]
# Returns: 0 if legacy dirs found, 1 if clean
# shellcheck disable=SC2120
_env_warn_legacy_bun_install() {
    local claude_dir="${1:-/opt/claude-code}"
    local cc_dir="${2:-/opt/continuous-claude}"
    local found=false

    if [[ -d "$claude_dir" ]]; then
        utils_warn "Legacy Bun-based Claude Code install found at $claude_dir"
        utils_warn "Remove with: sudo rm -rf $claude_dir"
        found=true
    fi

    if [[ -d "$cc_dir" ]]; then
        utils_warn "Legacy Bun-based continuous-claude install found at $cc_dir"
        utils_warn "Remove with: sudo rm -rf $cc_dir"
        found=true
    fi

    $found
}

# ============================================================================
# Installation Functions
# ============================================================================

# Build npm install command for scope
# Usage: _env_npm_install_cmd <package> <scope>
_env_npm_install_cmd() {
    local package="$1"
    local scope="$2"

    case "$scope" in
        user)
            echo "npm install -g --prefix \"\$HOME/.local\" -- \"$package\""
            ;;
        global|all)
            echo "npm install -g -- \"$package\""
            ;;
        *)
            echo "npm install -g --prefix \"\$HOME/.local\" -- \"$package\""
            ;;
    esac
}

# Build npm update command for scope
# Usage: _env_npm_update_cmd <package> <scope>
_env_npm_update_cmd() {
    local package="$1"
    local scope="$2"

    case "$scope" in
        user)
            echo "npm update -g --prefix \"\$HOME/.local\" -- \"$package\""
            ;;
        global|all)
            echo "npm update -g -- \"$package\""
            ;;
        *)
            echo "npm update -g --prefix \"\$HOME/.local\" -- \"$package\""
            ;;
    esac
}

# Map tool name to its installed binary name
# Usage: _env_tool_to_binary <tool>
# Returns: binary name on stdout; returns 1 if unknown tool
_env_tool_to_binary() {
    case "$1" in
        claude)            echo "claude" ;;
        codex)             echo "codex" ;;
        gemini)            echo "gemini" ;;
        continuous-claude) echo "continuous-claude" ;;
        mistral)           echo "vibe" ;;
        *) return 1 ;;
    esac
}

# Post-install symlink for curl-based tools installed as root (Issue #57)
# When curl installers drop binaries into /root/.local/bin/, this creates
# a symlink in /usr/local/bin/ so all users can access the tool.
# Usage: _env_post_install_symlink <tool>
_env_post_install_symlink() {
    local tool="$1"

    # Only relevant when running as root
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 0

    # Map tool name to binary name
    local binary
    binary=$(_env_tool_to_binary "$tool") || return 0

    # Already in /usr/local/bin? Done.
    if [[ -e "/usr/local/bin/$binary" ]]; then
        utils_verbose "$binary already in /usr/local/bin — no symlink needed"
        return 0
    fi

    # Search for the binary
    local search_path
    for search_path in "/root/.local/bin/$binary" "${HOME}/.local/bin/$binary"; do
        if [[ -x "$search_path" ]]; then
            ln -sf "$search_path" "/usr/local/bin/$binary"
            utils_verbose "Created symlink /usr/local/bin/$binary -> $search_path"
            return 0
        fi
    done

    utils_verbose "Could not find $binary in expected paths — no symlink created"
    return 0
}

# Install a single tool
# Usage: env_install_tool <tool> <scope> [--yes]
# Returns: 0 on success, 1 on failure
env_install_tool() {
    local tool="$1"
    local scope="${2:-user}"
    local auto_yes="false"
    local tmux_flag="false"

    # Parse optional flags (--yes, --tmux) from remaining args
    shift 2 || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) auto_yes="true" ;;
            --tmux) tmux_flag="true" ;;
        esac
        shift
    done

    # Validate tool
    if ! env_validate_tool "$tool"; then
        utils_error "Unknown tool: $tool"
        echo "Valid tools: $(env_get_all_tools | tr '\n' ' ')" >&2
        return $ENV_EXIT_INVALID_ARG
    fi

    local display_name
    display_name=$(env_get_display_name "$tool")

    # Check if already installed — if so, attempt update (Issue #49)
    if env_is_installed "$tool"; then
        local version
        version=$(env_get_version "$tool")
        echo "$display_name already installed (version: $version) — updating..."
        if ! env_update_tool "$tool" "$scope"; then
            utils_warn "Update failed, but $display_name is still installed (version: $version)"
        fi
        return $ENV_EXIT_SUCCESS
    fi

    local install_type
    install_type=$(env_get_install_type "$tool")

    echo "Installing $display_name..."

    case "$install_type" in
        curl)
            local url="${_ENV_INSTALL_URLS[$tool]}"
            if [[ -z "$url" ]]; then
                utils_error "No install URL configured for $tool"
                return 1
            fi

            if ! env_check_curl; then
                return $ENV_EXIT_MISSING_DEP
            fi

            # Global scope requires root
            if [[ "$scope" == "global" || "$scope" == "all" ]]; then
                if [[ "$EUID" -ne 0 ]]; then
                    utils_error "Global installation requires root. Run with sudo."
                    return 1
                fi
            fi

            # Security: Confirm before running remote script
            echo "This will download and execute: $url"
            if [[ "$auto_yes" != "true" && -t 0 ]]; then
                read -rp "Continue? [y/N]: " confirm
                if [[ "${confirm,,}" != "y" ]]; then
                    echo "Installation cancelled."
                    return 1
                fi
            fi

            curl -fsSL "$url" | bash

            # Issue #57: Symlink curl-installed binary into /usr/local/bin for global scope
            if [[ "$scope" == "global" || "$scope" == "all" ]]; then
                _env_post_install_symlink "$tool"
            fi
            ;;

        npm)
            # Check npm/node dependencies for all npm scopes
            if ! env_check_dependencies "$tool"; then
                return $ENV_EXIT_MISSING_DEP
            fi
            local package="${_ENV_NPM_PACKAGES[$tool]}"
            if [[ -z "$package" ]]; then
                utils_error "No npm package configured for $tool"
                return 1
            fi

            local cmd
            cmd=$(_env_npm_install_cmd "$package" "$scope")

            # Check root for global
            if [[ "$scope" == "global" || "$scope" == "all" ]]; then
                if [[ "$EUID" -ne 0 ]]; then
                    utils_error "Global installation requires root. Run with sudo."
                    return 1
                fi
            fi

            utils_verbose "Running: $cmd"
            eval "$cmd"
            ;;
    esac

    local exit_code=$?

    # Rehash to find newly installed binaries
    hash -r

    # Extend PATH for post-install check (installers may place binaries here)
    local check_path="$PATH"
    [[ -d "$HOME/.local/bin" ]] && check_path="$HOME/.local/bin:$check_path"
    [[ -d "/usr/local/bin" ]] && check_path="/usr/local/bin:$check_path"

    if [[ $exit_code -eq 0 ]] && PATH="$check_path" env_is_installed "$tool"; then
        local version
        version=$(PATH="$check_path" env_get_version "$tool")
        utils_success "$display_name installed successfully (version: $version)"

        # Post-install: configure Claude Code settings.json (Issues #39, #40)
        if [[ "$tool" == "claude" ]]; then
            _env_configure_claude_settings "$tmux_flag"
        fi

        return $ENV_EXIT_SUCCESS
    else
        utils_error "Failed to install $display_name"
        return 1
    fi
}

# Update a single tool
# Usage: env_update_tool <tool> <scope>
# Returns: 0 on success, 1 on failure
env_update_tool() {
    local tool="$1"
    local scope="${2:-user}"

    # Validate tool
    if ! env_validate_tool "$tool"; then
        utils_error "Unknown tool: $tool"
        return $ENV_EXIT_INVALID_ARG
    fi

    local display_name
    display_name=$(env_get_display_name "$tool")

    # Check if installed
    if ! env_is_installed "$tool"; then
        utils_warn "$display_name is not installed. Use 'cac env install $tool' first."
        return 1
    fi

    local old_version
    old_version=$(env_get_version "$tool")

    local install_type
    install_type=$(env_get_install_type "$tool")

    echo "Updating $display_name..."

    # Issue #31: Declare exit_code before case block so update command
    # failures are captured instead of killing the script under set -e.
    local exit_code=0

    case "$install_type" in
        curl)
            local url="${_ENV_INSTALL_URLS[$tool]}"

            # Global scope requires root
            if [[ "$scope" == "global" || "$scope" == "all" ]]; then
                if [[ "$EUID" -ne 0 ]]; then
                    utils_error "Global update requires root. Run with sudo."
                    return 1
                fi
            fi

            if ! env_check_curl; then
                return $ENV_EXIT_MISSING_DEP
            fi

            echo "Re-running installer from: $url"
            curl -fsSL "$url" | bash || exit_code=$?

            # Issue #57: Symlink curl-installed binary into /usr/local/bin for global scope
            if [[ $exit_code -eq 0 ]] && [[ "$scope" == "global" || "$scope" == "all" ]]; then
                _env_post_install_symlink "$tool"
            fi
            ;;

        npm)
            # Check npm/node dependencies for all npm scopes
            if ! env_check_dependencies "$tool"; then
                return $ENV_EXIT_MISSING_DEP
            fi
            local package="${_ENV_NPM_PACKAGES[$tool]}"
            local cmd
            cmd=$(_env_npm_update_cmd "$package" "$scope")

            if [[ "$scope" == "global" || "$scope" == "all" ]]; then
                if [[ "$EUID" -ne 0 ]]; then
                    utils_error "Global update requires root. Run with sudo."
                    return 1
                fi
            fi

            utils_verbose "Running: $cmd"
            eval "$cmd" || exit_code=$?
            ;;
    esac
    local new_version
    new_version=$(env_get_version "$tool")

    if [[ $exit_code -eq 0 ]]; then
        if [[ "$old_version" != "$new_version" ]]; then
            utils_success "$display_name updated: $old_version -> $new_version"
        else
            echo "$display_name is already at latest version ($new_version)"
        fi
        return $ENV_EXIT_SUCCESS
    else
        utils_error "Failed to update $display_name"
        return 1
    fi
}

# Install all core tools
# Usage: env_install_all <scope> [flags...]
# Returns: 0 all succeeded, 1 partial, 2 all failed
env_install_all() {
    local scope="${1:-user}"
    shift || true
    local -a extra_flags=("$@")
    local success=0
    local updated=0
    local failed=0

    echo "Installing all core AI tools..."
    echo ""

    while IFS= read -r tool; do
        # Issue #49: installed tools get updated via env_install_tool
        if env_is_installed "$tool"; then
            if env_install_tool "$tool" "$scope" "${extra_flags[@]+"${extra_flags[@]}"}"; then
                ((updated++)) || true
            else
                ((failed++)) || true
            fi
        else
            if env_install_tool "$tool" "$scope" "${extra_flags[@]+"${extra_flags[@]}"}"; then
                ((success++)) || true
            else
                ((failed++)) || true
            fi
        fi
        echo ""
    done < <(env_get_core_tools)

    echo "=== Installation Summary ==="
    echo "Installed: $success"
    echo "Updated: $updated"
    echo "Failed: $failed"

    if [[ $failed -eq 0 ]]; then
        return $ENV_EXIT_SUCCESS
    elif [[ $((success + updated)) -gt 0 ]]; then
        return $ENV_EXIT_PARTIAL
    else
        return $ENV_EXIT_ALL_FAILED
    fi
}

# Update all installed tools
# Usage: env_update_all <scope>
# Returns: 0 all succeeded, 1 partial, 2 all failed
env_update_all() {
    local scope="${1:-user}"
    local success=0
    local failed=0
    local skipped=0
    # Issue #32: Track failed tool names for error reporting
    local -a failed_tools=()
    # Issue #54: Track skipped tool names for user clarity
    local -a skipped_tools=()

    echo "Updating all installed AI tools..."
    echo ""

    while IFS= read -r tool; do
        if ! env_is_installed "$tool"; then
            ((skipped++)) || true
            local skip_name
            skip_name=$(env_get_display_name "$tool")
            skipped_tools+=("$skip_name")
            continue
        fi

        if env_update_tool "$tool" "$scope"; then
            ((success++)) || true
        else
            ((failed++)) || true
            local display_name
            display_name=$(env_get_display_name "$tool")
            failed_tools+=("$display_name")
        fi
        echo ""
    done < <(env_get_all_tools)

    echo "=== Update Summary ==="
    echo "Updated: $success"
    if [[ ${#skipped_tools[@]} -gt 0 ]]; then
        echo "Skipped (not installed): ${skipped_tools[*]}"
    else
        echo "Skipped (not installed): 0"
    fi
    echo "Failed: $failed"
    if [[ ${#failed_tools[@]} -gt 0 ]]; then
        echo "Failed tools: ${failed_tools[*]}"
    fi

    if [[ $failed -eq 0 ]]; then
        return $ENV_EXIT_SUCCESS
    elif [[ $success -gt 0 ]]; then
        return $ENV_EXIT_PARTIAL
    else
        return $ENV_EXIT_ALL_FAILED
    fi
}

# ============================================================================
# Latest Version Cache (Issue #30)
# ============================================================================

# Extract semver (X.Y.Z) from raw version string
# Handles formats like "codex-cli 0.94.0", "2.1.49 (Claude Code)", "0.26.0"
# Usage: _env_normalize_version <raw_version_string>
# Returns: First semver pattern found, or the input unchanged
_env_normalize_version() {
    local raw="$1"
    local semver
    semver=$(echo "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo "${semver:-$raw}"
}

# Get cache file path for latest version lookups
# Uses XDG cache dir (same pattern as check.sh) to avoid symlink attacks in /tmp
# Usage: _env_cache_file
_env_cache_file() {
    echo "${XDG_CACHE_HOME:-$HOME/.cache}/cac/latest_versions"
}

# Read a cached latest version for a tool
# Usage: _env_cache_get_latest <tool>
# Returns: Version string if cache is fresh, empty if expired/missing
_env_cache_get_latest() {
    local tool="$1"
    local cache_file
    cache_file=$(_env_cache_file)

    [[ -f "$cache_file" ]] || return 0

    local now
    now=$(date +%s)

    local line_tool line_version line_timestamp
    while IFS=: read -r line_tool line_version line_timestamp; do
        if [[ "$line_tool" == "$tool" ]]; then
            local age=$(( now - line_timestamp ))
            if [[ $age -lt $_ENV_LATEST_CACHE_TTL ]]; then
                echo "$line_version"
                return 0
            fi
        fi
    done < "$cache_file"

    return 0
}

# Store a latest version in the cache
# Usage: _env_cache_set_latest <tool> <version>
_env_cache_set_latest() {
    local tool="$1"
    local version="$2"
    local cache_file cache_dir timestamp
    cache_file=$(_env_cache_file)
    cache_dir=$(dirname "$cache_file")
    timestamp=$(date +%s)

    # Create cache directory if needed (secure permissions)
    if [[ ! -d "$cache_dir" ]]; then
        mkdir -p "$cache_dir"
        chmod 700 "$cache_dir"
    fi

    if [[ -f "$cache_file" ]]; then
        local temp_file
        temp_file=$(mktemp "${cache_dir}/latest_versions.XXXXXX")
        chmod 600 "$temp_file"
        grep -v "^${tool}:" "$cache_file" > "$temp_file" 2>/dev/null || true
        echo "${tool}:${version}:${timestamp}" >> "$temp_file"
        mv "$temp_file" "$cache_file"
    else
        echo "${tool}:${version}:${timestamp}" > "$cache_file"
        chmod 600 "$cache_file"
    fi
}

# Get the latest published version for a tool from npm registry
# Usage: env_get_latest_version <tool>
# Returns: Version string or "?" if unavailable
env_get_latest_version() {
    local tool="$1"

    # Check cache first
    local cached
    cached=$(_env_cache_get_latest "$tool")
    if [[ -n "$cached" ]]; then
        echo "$cached"
        return 0
    fi

    # Look up npm package name
    local package="${_ENV_NPM_LOOKUP[$tool]:-}"
    if [[ -z "$package" ]]; then
        echo "?"
        return 0
    fi

    # Require npm
    if ! command -v npm &>/dev/null; then
        echo "?"
        return 0
    fi

    # Query npm registry with timeout
    local latest
    if command -v timeout &>/dev/null; then
        latest=$(timeout 10 npm view "$package" version 2>/dev/null) || latest=""
    elif command -v gtimeout &>/dev/null; then
        latest=$(gtimeout 10 npm view "$package" version 2>/dev/null) || latest=""
    else
        latest=$(npm view "$package" version 2>/dev/null) || latest=""
    fi

    if [[ -n "$latest" ]]; then
        _env_cache_set_latest "$tool" "$latest"
        echo "$latest"
    else
        echo "?"
    fi
}

# ============================================================================
# Status Display Functions
# ============================================================================

# Show status of all tools (human-readable table)
# Usage: env_show_status [check_updates]
# Args: check_updates - if "true", fetch and display latest available versions
env_show_status() {
    local check_updates="${1:-false}"

    # Check for legacy Bun-based installations (non-fatal warning)
    _env_warn_legacy_bun_install 2>/dev/null || true

    if [[ "$check_updates" == "true" ]]; then
        printf "%-20s %-12s %-20s %-20s %-10s\n" "Tool" "Status" "Version" "Latest" "Optional"
        printf "%-20s %-12s %-20s %-20s %-10s\n" "----" "------" "-------" "------" "--------"
    else
        printf "%-20s %-12s %-20s %-10s\n" "Tool" "Status" "Version" "Optional"
        printf "%-20s %-12s %-20s %-10s\n" "----" "------" "-------" "--------"
    fi

    for entry in "${_ENV_REGISTRY[@]}"; do
        IFS='|' read -ra fields <<< "$entry"
        local tool="${fields[0]}"
        local display_name="${fields[1]}"
        local optional="${fields[5]}"

        local status version opt_str
        if env_is_installed "$tool"; then
            status="Installed"
            version=$(env_get_version "$tool")
        else
            status="Not found"
            version="-"
        fi

        if [[ "$optional" == "yes" ]]; then
            opt_str="Yes"
        else
            opt_str="No"
        fi

        if [[ "$check_updates" == "true" ]]; then
            local latest indicator
            if [[ "$status" == "Installed" ]]; then
                latest=$(env_get_latest_version "$tool")
                local norm_version norm_latest
                norm_version=$(_env_normalize_version "$version")
                norm_latest=$(_env_normalize_version "$latest")
                if [[ "$latest" == "?" ]]; then
                    indicator=""
                elif [[ "$norm_latest" == "$norm_version" ]]; then
                    indicator=" ✓"
                else
                    indicator=" ⬆"
                fi
                printf "%-20s %-12s %-20s %-20s %-10s\n" "$display_name" "$status" "$version" "${latest}${indicator}" "$opt_str"
            else
                printf "%-20s %-12s %-20s %-20s %-10s\n" "$display_name" "$status" "$version" "-" "$opt_str"
            fi
        else
            printf "%-20s %-12s %-20s %-10s\n" "$display_name" "$status" "$version" "$opt_str"
        fi
    done
}

# Show status in parseable format (tab-separated)
# Usage: env_show_status_parseable [check_updates]
# Output: TOOL\tSTATUS\tVERSION[\tLATEST] per line
env_show_status_parseable() {
    local check_updates="${1:-false}"

    for entry in "${_ENV_REGISTRY[@]}"; do
        local tool="${entry%%|*}"
        local status version

        if env_is_installed "$tool"; then
            status="installed"
            version=$(env_get_version "$tool")
            version=$(_env_normalize_version "$version")
        else
            status="not_found"
            version="-"
        fi

        if [[ "$check_updates" == "true" ]]; then
            local latest
            if [[ "$status" == "installed" ]]; then
                latest=$(env_get_latest_version "$tool")
                latest=$(_env_normalize_version "$latest")
            else
                latest="-"
            fi
            printf "%s\t%s\t%s\t%s\n" "$tool" "$status" "$version" "$latest"
        else
            printf "%s\t%s\t%s\n" "$tool" "$status" "$version"
        fi
    done
}

# ============================================================================
# Health Check Functions (Issue #59: env check / env repair)
# ============================================================================

# Internal variable set by check helpers to describe failure reason
_CHECK_REASON=""

# Check: binary is in /usr/local/bin/ or ~/.local/bin/, not /opt/ or other
# Usage: _env_chk_binary_location <binary_path> <tool>
# Returns: 0=pass, 1=fail (sets _CHECK_REASON)
_env_chk_binary_location() {
    local binary_path="$1"
    # shellcheck disable=SC2034
    local tool="$2"

    if [[ -z "$binary_path" ]]; then
        _CHECK_REASON="binary not found in PATH"
        return 1
    fi

    # Resolve symlinks to get the real path for location check
    local real_path
    real_path=$(readlink -f "$binary_path" 2>/dev/null) || real_path="$binary_path"

    case "$real_path" in
        /usr/local/bin/*) return 0 ;;
        "$HOME"/.local/bin/*) return 0 ;;
        "$HOME"/.local/lib/*) return 0 ;;  # npm tools install libs here
        /usr/local/lib/*) return 0 ;;      # npm global libs
        /usr/lib/*) return 0 ;;            # system packages
        /opt/*)
            _CHECK_REASON="binary at $real_path (legacy /opt/ location)"
            return 1
            ;;
        *)
            # Accept if the symlink itself is in an approved dir
            case "$binary_path" in
                /usr/local/bin/*|"$HOME"/.local/bin/*) return 0 ;;
            esac
            _CHECK_REASON="binary at $real_path (unexpected location)"
            return 1
            ;;
    esac
}

# Check: no legacy Bun-based installations
# Usage: _env_chk_no_bun <binary_path> <tool>
# Returns: 0=pass, 1=fail
_env_chk_no_bun() {
    # shellcheck disable=SC2034
    local binary_path="$1"
    local tool="$2"

    local dirs_to_check=()
    case "$tool" in
        claude)
            dirs_to_check=("/opt/claude-code" "$HOME/.bun")
            ;;
        continuous-claude)
            dirs_to_check=("/opt/continuous-claude" "$HOME/.bun")
            ;;
        *)
            # Other tools were never installed via Bun
            return 0
            ;;
    esac

    for dir in "${dirs_to_check[@]}"; do
        if [[ -d "$dir" ]]; then
            _CHECK_REASON="$dir exists (legacy Bun install)"
            return 1
        fi
    done
    return 0
}

# Check: if binary is a symlink, target exists and is executable
# Usage: _env_chk_symlink_target <binary_path> <tool>
# Returns: 0=pass, 1=fail
_env_chk_symlink_target() {
    local binary_path="$1"
    # shellcheck disable=SC2034
    local tool="$2"

    if [[ -z "$binary_path" ]]; then
        _CHECK_REASON="binary not found"
        return 1
    fi

    # Not a symlink — pass
    if [[ ! -L "$binary_path" ]]; then
        return 0
    fi

    local target
    target=$(readlink -f "$binary_path" 2>/dev/null) || true

    if [[ -z "$target" || ! -e "$target" ]]; then
        _CHECK_REASON="symlink $binary_path points to non-existent target"
        return 1
    fi

    if [[ ! -x "$target" ]]; then
        _CHECK_REASON="symlink target $target is not executable"
        return 1
    fi

    return 0
}

# Check: system-wide binaries in /usr/local/bin/ owned by root:root
# Usage: _env_chk_ownership <binary_path> <tool>
# Returns: 0=pass, 1=fail
_env_chk_ownership() {
    local binary_path="$1"
    # shellcheck disable=SC2034
    local tool="$2"

    if [[ -z "$binary_path" ]]; then
        return 0  # No binary to check
    fi

    # Only check ownership for /usr/local/bin/ binaries
    case "$binary_path" in
        /usr/local/bin/*) ;;
        *) return 0 ;;  # Not a system binary, skip
    esac

    # Check ownership of the target (GNU stat dereferences symlinks by default)
    local owner
    owner=$(stat -c '%U:%G' "$binary_path" 2>/dev/null) || return 0

    if [[ "$owner" != "root:root" ]]; then
        _CHECK_REASON="$binary_path owned by $owner (expected root:root)"
        return 1
    fi

    return 0
}

# Check: binary is executable
# Usage: _env_chk_permissions <binary_path> <tool>
# Returns: 0=pass, 1=fail
_env_chk_permissions() {
    local binary_path="$1"
    # shellcheck disable=SC2034
    local tool="$2"

    if [[ -z "$binary_path" ]]; then
        _CHECK_REASON="binary not found"
        return 1
    fi

    if [[ ! -x "$binary_path" ]]; then
        _CHECK_REASON="$binary_path is not executable"
        return 1
    fi

    return 0
}

# Check: tool --version exits 0
# Usage: _env_chk_runs <binary_path> <tool>
# Returns: 0=pass, 1=fail
_env_chk_runs() {
    # shellcheck disable=SC2034
    local binary_path="$1"
    local tool="$2"

    local version_cmd
    version_cmd=$(env_get_version_cmd "$tool") || {
        _CHECK_REASON="no version command registered"
        return 1
    }

    if ! eval "timeout 10 $version_cmd" &>/dev/null; then
        _CHECK_REASON="'$version_cmd' failed or timed out"
        return 1
    fi

    return 0
}

# Check: no stale PATH entries pointing to removed Bun installations
# Usage: _env_chk_stale_path <binary_path> <tool>
# Returns: 0=pass, 1=fail
_env_chk_stale_path() {
    # shellcheck disable=SC2034
    local binary_path="$1"
    # shellcheck disable=SC2034
    local tool="$2"

    local IFS=':'
    local stale_entries=()
    for dir in $PATH; do
        case "$dir" in
            /opt/claude-code*|/opt/continuous-claude*|*/.bun/*)
                if [[ ! -d "$dir" ]]; then
                    stale_entries+=("$dir")
                else
                    # Dir exists but is Bun-related — also flag it
                    stale_entries+=("$dir")
                fi
                ;;
        esac
    done

    if [[ ${#stale_entries[@]} -gt 0 ]]; then
        _CHECK_REASON="PATH contains Bun-related entries: ${stale_entries[*]}"
        return 1
    fi

    return 0
}

# Check: npm tools have correct npm global prefix
# Usage: _env_chk_npm_prefix <binary_path> <tool>
# Returns: 0=pass, 1=fail
_env_chk_npm_prefix() {
    # shellcheck disable=SC2034
    local binary_path="$1"
    local tool="$2"

    local install_type
    install_type=$(env_get_install_type "$tool") || return 0

    # Only relevant for npm tools
    [[ "$install_type" == "npm" ]] || return 0

    if ! command -v npm &>/dev/null; then
        _CHECK_REASON="npm not found"
        return 1
    fi

    local prefix
    prefix=$(npm prefix -g 2>/dev/null) || {
        _CHECK_REASON="npm prefix -g failed"
        return 1
    }

    case "$prefix" in
        /usr/local|/usr|"$HOME/.local"|"$HOME"/.local)
            return 0
            ;;
        *)
            _CHECK_REASON="npm global prefix is $prefix (expected /usr/local or ~/.local)"
            return 1
            ;;
    esac
}

# Check: Node.js >= 18 for npm tools
# Usage: _env_chk_node_version <binary_path> <tool>
# Returns: 0=pass, 1=fail
_env_chk_node_version() {
    # shellcheck disable=SC2034
    local binary_path="$1"
    local tool="$2"

    local install_type
    install_type=$(env_get_install_type "$tool") || return 0

    # Only relevant for npm tools
    [[ "$install_type" == "npm" ]] || return 0

    if ! env_check_node 2>/dev/null; then
        _CHECK_REASON="Node.js >= 18 required for npm tools"
        return 1
    fi

    return 0
}

# List of all check names in order
_ENV_CHECK_NAMES=(
    binary_location
    no_bun
    symlink_target
    ownership
    permissions
    runs
    stale_path
    npm_prefix
    node_version
)

# Run all health checks for one installed tool
# Usage: _env_check_one_tool <tool> <parseable>
# Returns: 0 if all pass, 1 if any fail
# Output: check results to stdout
_env_check_one_tool() {
    local tool="$1"
    local parseable="${2:-false}"

    local binary
    binary=$(_env_tool_to_binary "$tool") || binary=""

    local binary_path=""
    if [[ -n "$binary" ]]; then
        binary_path=$(type -P "$binary" 2>/dev/null) || true
    fi

    local display_name
    display_name=$(env_get_display_name "$tool")

    local total=0 passed=0 failed_count=0
    local -a failed_checks=()

    if [[ "$parseable" == "false" ]]; then
        echo "${display_name}:"
    fi

    for check_name in "${_ENV_CHECK_NAMES[@]}"; do
        _CHECK_REASON=""
        local check_fn="_env_chk_${check_name}"
        ((total++)) || true

        if "$check_fn" "$binary_path" "$tool" 2>/dev/null; then
            ((passed++)) || true
            if [[ "$parseable" == "true" ]]; then
                printf "%s\t%s\tpass\t\n" "$tool" "$check_name"
            else
                echo "  [PASS] $check_name"
            fi
        else
            ((failed_count++)) || true
            failed_checks+=("$check_name")
            if [[ "$parseable" == "true" ]]; then
                printf "%s\t%s\tfail\t%s\n" "$tool" "$check_name" "$_CHECK_REASON"
            else
                echo "  [FAIL] $check_name: $_CHECK_REASON"
            fi
        fi
    done

    if [[ "$parseable" == "false" ]]; then
        if [[ $failed_count -eq 0 ]]; then
            echo "  ✅ ${display_name}: PASS (${passed}/${total})"
        else
            echo "  ❌ ${display_name}: FAIL (${passed}/${total}) — failed: ${failed_checks[*]}"
        fi
        echo ""
    fi

    [[ $failed_count -eq 0 ]]
}

# Handle 'cac env check' command
# Usage: env_cmd_check "$@"
env_cmd_check() {
    if ! _env_parse_scope_args "$@"; then
        return 1
    fi

    local parseable="$ENV_PARSED_PARSEABLE"
    local pass=0 fail=0 skipped=0

    if [[ ${#ENV_PARSED_TOOLS[@]} -gt 0 ]]; then
        for tool in "${ENV_PARSED_TOOLS[@]}"; do
            if ! env_validate_tool "$tool"; then
                utils_error "Unknown tool: $tool"
                return $ENV_EXIT_INVALID_ARG
            fi
            if ! env_is_installed "$tool"; then
                ((skipped++)) || true
                [[ "$parseable" == "false" ]] && echo "SKIP $(env_get_display_name "$tool"): not installed"
                continue
            fi
            if _env_check_one_tool "$tool" "$parseable"; then
                ((pass++)) || true
            else
                ((fail++)) || true
            fi
        done
    else
        while IFS= read -r tool; do
            if ! env_is_installed "$tool"; then
                ((skipped++)) || true
                continue
            fi
            if _env_check_one_tool "$tool" "$parseable"; then
                ((pass++)) || true
            else
                ((fail++)) || true
            fi
        done < <(env_get_all_tools)
    fi

    if [[ "$parseable" == "false" ]]; then
        echo "=== Check Summary ==="
        echo "Passed: $pass  Failed: $fail  Skipped: $skipped"
    fi

    if [[ $fail -eq 0 ]]; then
        return $ENV_EXIT_SUCCESS
    elif [[ $pass -gt 0 ]]; then
        return $ENV_EXIT_PARTIAL
    else
        return $ENV_EXIT_ALL_FAILED
    fi
}

# ============================================================================
# Repair Functions (Issue #59)
# ============================================================================

# Repair: remove legacy Bun directories in /opt/
# Usage: _env_repair_remove_bun_opt <tool> <auto_yes>
_env_repair_remove_bun_opt() {
    local tool="$1"
    local auto_yes="${2:-false}"

    local dirs_to_remove=()
    case "$tool" in
        claude) dirs_to_remove=("/opt/claude-code") ;;
        continuous-claude) dirs_to_remove=("/opt/continuous-claude") ;;
        *) return 0 ;;
    esac

    for dir in "${dirs_to_remove[@]}"; do
        if [[ -d "$dir" ]]; then
            if [[ "$auto_yes" != "true" ]]; then
                echo -n "  Remove legacy Bun directory $dir? [y/N]: "
                local reply
                read -r reply
                [[ "$reply" =~ ^[Yy]$ ]] || { echo "  Skipped removal of $dir"; continue; }
            fi
            if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                rm -rf "$dir"
                echo "  Removed $dir"
            else
                echo "  Run: sudo rm -rf $dir"
                utils_warn "Requires root — skipping removal of $dir"
            fi
        fi
    done
}

# Repair: remove ~/.bun directory
# Usage: _env_repair_remove_bun_home <auto_yes>
_env_repair_remove_bun_home() {
    local auto_yes="${1:-false}"

    if [[ -d "$HOME/.bun" ]]; then
        if [[ "$auto_yes" != "true" ]]; then
            echo -n "  Remove legacy ~/.bun directory? [y/N]: "
            local reply
            read -r reply
            [[ "$reply" =~ ^[Yy]$ ]] || { echo "  Skipped removal of ~/.bun"; return 0; }
        fi
        rm -rf "$HOME/.bun"
        echo "  Removed $HOME/.bun"
    fi
}

# Repair: create missing symlink in /usr/local/bin/
# Usage: _env_repair_create_symlink <tool>
_env_repair_create_symlink() {
    local tool="$1"

    local binary
    binary=$(_env_tool_to_binary "$tool") || return 1

    if [[ -e "/usr/local/bin/$binary" ]]; then
        return 0  # Already exists
    fi

    # Find binary in user paths
    local search_path
    for search_path in "$HOME/.local/bin/$binary" "/root/.local/bin/$binary"; do
        if [[ -x "$search_path" ]]; then
            if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                ln -sf "$search_path" "/usr/local/bin/$binary"
                echo "  Created symlink /usr/local/bin/$binary -> $search_path"
                return 0
            else
                utils_warn "Requires root to create /usr/local/bin/$binary symlink"
                return 1
            fi
        fi
    done

    utils_warn "Could not find $binary to create symlink"
    return 1
}

# Repair: fix ownership of system binary
# Usage: _env_repair_fix_ownership <binary_path>
_env_repair_fix_ownership() {
    local binary_path="$1"

    case "$binary_path" in
        /usr/local/bin/*) ;;
        *) return 0 ;;  # Not system binary
    esac

    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        chown root:root "$binary_path"
        echo "  Fixed ownership: chown root:root $binary_path"
    else
        utils_warn "Requires root to fix ownership of $binary_path"
    fi
}

# Repair: fix permissions on binary
# Usage: _env_repair_fix_permissions <binary_path>
_env_repair_fix_permissions() {
    local binary_path="$1"

    if [[ -n "$binary_path" && ! -x "$binary_path" ]]; then
        chmod +x "$binary_path"
        echo "  Fixed permissions: chmod +x $binary_path"
    fi
}

# Repair: reinstall a broken tool
# Usage: _env_repair_reinstall <tool> <auto_yes>
_env_repair_reinstall() {
    local tool="$1"
    local auto_yes="${2:-false}"

    echo "  Re-installing $(env_get_display_name "$tool")..."
    local install_args=("$tool" "user")
    [[ "$auto_yes" == "true" ]] && install_args+=("--yes")

    if env_install_tool "${install_args[@]}" 2>&1 | sed 's/^/    /'; then
        echo "  Re-install completed."
    else
        utils_warn "Re-install of $tool failed"
        return 1
    fi
}

# Run repair for one tool based on check failures
# Usage: _env_repair_one_tool <tool> <auto_yes>
# Returns: 0 if all resolved, 1 if issues remain
_env_repair_one_tool() {
    local tool="$1"
    local auto_yes="${2:-false}"

    local display_name
    display_name=$(env_get_display_name "$tool")

    local binary
    binary=$(_env_tool_to_binary "$tool") || binary=""

    local binary_path=""
    if [[ -n "$binary" ]]; then
        binary_path=$(type -P "$binary" 2>/dev/null) || true
    fi

    echo "--- Checking: ${display_name} ---"

    # Collect failures
    local -a failures=()
    for check_name in "${_ENV_CHECK_NAMES[@]}"; do
        _CHECK_REASON=""
        local check_fn="_env_chk_${check_name}"
        if ! "$check_fn" "$binary_path" "$tool" 2>/dev/null; then
            failures+=("$check_name")
        fi
    done

    if [[ ${#failures[@]} -eq 0 ]]; then
        echo "  No issues found."
        echo ""
        return 0
    fi

    echo "  Found ${#failures[@]} issue(s): ${failures[*]}"
    echo "  Repairing..."

    # Apply repairs based on failure type
    local -A repaired=()
    for failure in "${failures[@]}"; do
        case "$failure" in
            no_bun)
                if [[ -z "${repaired[bun_opt]:-}" ]]; then
                    _env_repair_remove_bun_opt "$tool" "$auto_yes"
                    _env_repair_remove_bun_home "$auto_yes"
                    repaired[bun_opt]=1
                fi
                ;;
            binary_location)
                if [[ -z "${repaired[bun_opt]:-}" ]]; then
                    _env_repair_remove_bun_opt "$tool" "$auto_yes"
                    repaired[bun_opt]=1
                fi
                ;;
            symlink_target)
                _env_repair_create_symlink "$tool"
                ;;
            ownership)
                _env_repair_fix_ownership "$binary_path"
                ;;
            permissions)
                _env_repair_fix_permissions "$binary_path"
                ;;
            runs)
                if [[ -z "${repaired[reinstall]:-}" ]]; then
                    _env_repair_reinstall "$tool" "$auto_yes"
                    repaired[reinstall]=1
                fi
                ;;
            stale_path)
                utils_warn "Stale Bun PATH entries detected — remove them from your shell profile (~/.bashrc, ~/.zshrc, /etc/profile.d/)"
                ;;
            npm_prefix)
                utils_warn "npm global prefix mismatch — consider reinstalling npm tools with 'cac env install $tool'"
                ;;
            node_version)
                utils_warn "Node.js >= 18 required — upgrade Node.js (see https://nodejs.org)"
                ;;
        esac
    done

    # Re-check
    echo ""
    echo "  Verifying repairs..."
    # Re-resolve binary path after repairs
    binary_path=""
    if [[ -n "$binary" ]]; then
        hash -r 2>/dev/null || true
        binary_path=$(type -P "$binary" 2>/dev/null) || true
    fi

    local still_failing=0
    for check_name in "${_ENV_CHECK_NAMES[@]}"; do
        _CHECK_REASON=""
        local check_fn="_env_chk_${check_name}"
        if ! "$check_fn" "$binary_path" "$tool" 2>/dev/null; then
            ((still_failing++)) || true
        fi
    done

    if [[ $still_failing -eq 0 ]]; then
        echo "  ✅ ${display_name}: all issues resolved"
    else
        echo "  ❌ ${display_name}: $still_failing issue(s) remain"
    fi
    echo ""

    [[ $still_failing -eq 0 ]]
}

# Handle 'cac env repair' command
# Usage: env_cmd_repair "$@"
env_cmd_repair() {
    if ! _env_parse_scope_args "$@"; then
        return 1
    fi

    local auto_yes="$ENV_PARSED_YES"
    local pass=0 fail=0 skipped=0

    if [[ ${#ENV_PARSED_TOOLS[@]} -gt 0 ]]; then
        for tool in "${ENV_PARSED_TOOLS[@]}"; do
            if ! env_validate_tool "$tool"; then
                utils_error "Unknown tool: $tool"
                return $ENV_EXIT_INVALID_ARG
            fi
            if ! env_is_installed "$tool"; then
                ((skipped++)) || true
                echo "SKIP $(env_get_display_name "$tool"): not installed"
                continue
            fi
            if _env_repair_one_tool "$tool" "$auto_yes"; then
                ((pass++)) || true
            else
                ((fail++)) || true
            fi
        done
    else
        while IFS= read -r tool; do
            if ! env_is_installed "$tool"; then
                ((skipped++)) || true
                continue
            fi
            if _env_repair_one_tool "$tool" "$auto_yes"; then
                ((pass++)) || true
            else
                ((fail++)) || true
            fi
        done < <(env_get_all_tools)
    fi

    echo "=== Repair Summary ==="
    echo "Resolved: $pass  Still failing: $fail  Skipped: $skipped"

    if [[ $fail -eq 0 ]]; then
        return $ENV_EXIT_SUCCESS
    elif [[ $pass -gt 0 ]]; then
        return $ENV_EXIT_PARTIAL
    else
        return $ENV_EXIT_ALL_FAILED
    fi
}

# ============================================================================
# Interactive Functions
# ============================================================================

# Prompt user to select tools for installation
# Usage: env_interactive_install <scope>
# Returns: Exit code based on installation results
env_interactive_install() {
    local scope="${1:-user}"

    echo "=== AI Tool Environment Installation ==="
    echo ""
    env_show_status
    echo ""

    # Build menu options
    local tools=()
    local i=1

    echo "Select tools to install:"
    while IFS= read -r tool; do
        local display_name
        display_name=$(env_get_display_name "$tool")

        if env_is_installed "$tool"; then
            echo "  [$i] $display_name (already installed)"
        else
            echo "  [$i] $display_name"
        fi
        tools+=("$tool")
        ((i++)) || true
    done < <(env_get_all_tools)

    echo "  [A] All core tools"
    echo "  [Q] Quit"
    echo ""

    read -rp "Enter selection (comma-separated for multiple, e.g., 1,2): " selection

    case "${selection^^}" in
        Q|QUIT)
            echo "Installation cancelled."
            return 0
            ;;
        A|ALL)
            local -a all_flags=("--yes")
            [[ "${ENV_PARSED_TMUX:-false}" == "true" ]] && all_flags+=("--tmux")
            env_install_all "$scope" "${all_flags[@]}"
            return $?
            ;;
        *)
            # Parse comma-separated selections
            local selected_tools=()
            IFS=',' read -ra selections <<< "$selection"

            for sel in "${selections[@]}"; do
                sel="${sel// /}"  # Trim whitespace
                if [[ "$sel" =~ ^[0-9]+$ ]] && [[ $sel -ge 1 ]] && [[ $sel -le ${#tools[@]} ]]; then
                    selected_tools+=("${tools[$((sel-1))]}")
                else
                    utils_warn "Invalid selection: $sel"
                fi
            done

            if [[ ${#selected_tools[@]} -eq 0 ]]; then
                utils_error "No valid tools selected."
                return 1
            fi

            # Install selected tools
            local success=0
            local failed=0

            local -a sel_flags=("--yes")
            [[ "${ENV_PARSED_TMUX:-false}" == "true" ]] && sel_flags+=("--tmux")
            for tool in "${selected_tools[@]}"; do
                if env_install_tool "$tool" "$scope" "${sel_flags[@]}"; then
                    ((success++)) || true
                else
                    ((failed++)) || true
                fi
                echo ""
            done

            if [[ $failed -eq 0 ]]; then
                return $ENV_EXIT_SUCCESS
            elif [[ $success -gt 0 ]]; then
                return $ENV_EXIT_PARTIAL
            else
                return $ENV_EXIT_ALL_FAILED
            fi
            ;;
    esac
}

# ============================================================================
# Claude Code Settings Configuration (Issues #39, #40)
# ============================================================================

# Merge a JSON snippet into a settings.json file using deep merge
# Usage: _env_write_claude_settings <json_snippet> [settings_file]
# Requires: python3
# Returns: 0 on success, 1 on failure
#
# Edge cases handled:
#   - File does not exist: create with snippet, chmod 600
#   - Invalid JSON in existing file: warn and skip (do NOT overwrite)
#   - Non-object root in existing file: warn and recreate
#   - Arrays in snippet: replace (not concatenate)
#   - Atomicity: writes to temp file + mv (atomic rename)
#   - python3 missing: warn and return 1
_env_write_claude_settings() {
    local snippet="$1"
    local settings_file="${2:-${HOME}/.claude/settings.json}"
    local settings_dir
    settings_dir="$(dirname "$settings_file")"

    # Require python3
    if ! command -v python3 &>/dev/null; then
        utils_warn "python3 not available — cannot write settings.json"
        return 1
    fi

    mkdir -p "$settings_dir"

    if [[ ! -f "$settings_file" ]]; then
        # New file: write snippet atomically
        local temp_new
        temp_new=$(mktemp "${settings_dir}/settings.XXXXXX")
        chmod 600 "$temp_new"
        echo "$snippet" > "$temp_new"
        mv "$temp_new" "$settings_file"
        return 0
    fi

    # Merge using python3 with full edge-case handling
    # Writes to temp file, then atomic mv
    local temp_merge
    temp_merge=$(mktemp "${settings_dir}/settings.XXXXXX")
    chmod 600 "$temp_merge"

    local py_exit=0
    python3 -c "
import json, sys, os

settings_file = sys.argv[1]
snippet_str = sys.argv[2]
temp_file = sys.argv[3]

# Parse snippet (must be valid)
snippet = json.loads(snippet_str)

# Read existing file
try:
    with open(settings_file) as f:
        existing = json.load(f)
except json.JSONDecodeError:
    print('ERROR: Invalid JSON in existing settings.json — skipping merge', file=sys.stderr)
    sys.exit(2)

# Validate root is a dict
if not isinstance(existing, dict):
    print('WARNING: settings.json root is not an object — recreating', file=sys.stderr)
    existing = {}

# Deep merge: dicts merge recursively, everything else (including arrays) replaces
def deep_merge(base, override):
    for k, v in override.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            deep_merge(base[k], v)
        else:
            base[k] = v

deep_merge(existing, snippet)

with open(temp_file, 'w') as f:
    json.dump(existing, f, indent=2)
    f.write('\n')
" "$settings_file" "$snippet" "$temp_merge" || py_exit=$?

    if [[ $py_exit -ne 0 ]]; then
        rm -f "$temp_merge"
        if [[ $py_exit -eq 2 ]]; then
            utils_warn "Invalid JSON in $settings_file — merge skipped to preserve file"
        else
            utils_warn "Failed to merge settings.json"
        fi
        return 1
    fi

    # Atomic rename
    mv "$temp_merge" "$settings_file"
    return 0
}

# Configure Claude Code settings.json after install
# Always enables CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS (Issue #40)
# Optionally sets teammateMode to "tmux" if --tmux flag and tmux binary present (Issue #39)
# Usage: _env_configure_claude_settings <tmux_flag>
_env_configure_claude_settings() {
    local tmux_flag="${1:-false}"
    local snippet='{"env":{"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS":"1"}}'

    if [[ "$tmux_flag" == "true" ]]; then
        if command -v tmux &>/dev/null; then
            snippet='{"env":{"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS":"1"},"teammateMode":"tmux"}'
        else
            log_warn "tmux is not installed — skipping teammateMode configuration"
            log_warn "Install with: sudo apt install tmux"
        fi
    fi

    echo "Configuring Claude Code settings..."
    if _env_write_claude_settings "$snippet"; then
        utils_success "Claude Code settings.json updated"
    else
        utils_warn "Could not update Claude Code settings.json"
    fi
}

# ============================================================================
# Main Command Functions (called from bin/cac)
# ============================================================================

# Parse scope flags from arguments
# Usage: _env_parse_scope_args "$@"
# Sets: ENV_PARSED_SCOPE, ENV_PARSED_TOOLS
_env_parse_scope_args() {
    ENV_PARSED_SCOPE=""
    ENV_PARSED_TOOLS=()
    ENV_PARSED_YES="false"
    ENV_PARSED_PARSEABLE="false"
    ENV_PARSED_CHECK_UPDATES="false"
    ENV_PARSED_TMUX="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                if [[ -n "$ENV_PARSED_SCOPE" ]]; then
                    utils_error "Only one scope flag allowed (--user, --global, --all)"
                    return 1
                fi
                ENV_PARSED_SCOPE="user"
                shift
                ;;
            --global)
                if [[ -n "$ENV_PARSED_SCOPE" ]]; then
                    utils_error "Only one scope flag allowed (--user, --global, --all)"
                    return 1
                fi
                ENV_PARSED_SCOPE="global"
                shift
                ;;
            --all)
                if [[ -n "$ENV_PARSED_SCOPE" ]]; then
                    utils_error "Only one scope flag allowed (--user, --global, --all)"
                    return 1
                fi
                ENV_PARSED_SCOPE="all"
                shift
                ;;
            --yes|-y)
                ENV_PARSED_YES="true"
                shift
                ;;
            --parseable)
                ENV_PARSED_PARSEABLE="true"
                shift
                ;;
            --check-updates)
                ENV_PARSED_CHECK_UPDATES="true"
                shift
                ;;
            --tmux)
                ENV_PARSED_TMUX="true"
                shift
                ;;
            -*)
                utils_error "Unknown option: $1"
                return 1
                ;;
            *)
                ENV_PARSED_TOOLS+=("$1")
                shift
                ;;
        esac
    done

    # Default scope
    [[ -z "$ENV_PARSED_SCOPE" ]] && ENV_PARSED_SCOPE="user"

    # Validate scope requires root
    if [[ "$ENV_PARSED_SCOPE" == "global" || "$ENV_PARSED_SCOPE" == "all" ]]; then
        if [[ "$EUID" -ne 0 ]]; then
            utils_error "Scope --${ENV_PARSED_SCOPE} requires root privileges."
            return 1
        fi
    fi

    return 0
}

# Handle 'cac env install' command
# Usage: env_cmd_install "$@"
env_cmd_install() {
    if ! _env_parse_scope_args "$@"; then
        return 1
    fi

    local scope="$ENV_PARSED_SCOPE"
    local -a extra_flags=()
    [[ "$ENV_PARSED_YES" == "true" ]] && extra_flags+=("--yes")
    [[ "$ENV_PARSED_TMUX" == "true" ]] && extra_flags+=("--tmux")

    # No tools specified
    if [[ ${#ENV_PARSED_TOOLS[@]} -eq 0 ]]; then
        if [[ "${ENV_PARSED_YES}" == "true" ]]; then
            # --yes flag: skip interactive menu, install all core tools
            env_install_all "$scope" "${extra_flags[@]+"${extra_flags[@]}"}"
            return $?
        elif [[ -t 0 ]]; then
            # Interactive terminal: show selection menu
            env_interactive_install "$scope"
            return $?
        else
            # Non-interactive (piped): install all core tools
            echo "Non-interactive mode: installing all core tools"
            env_install_all "$scope" "${extra_flags[@]+"${extra_flags[@]}"}"
            return $?
        fi
    fi

    # Install specified tools
    local success=0
    local failed=0

    for tool in "${ENV_PARSED_TOOLS[@]}"; do
        if env_install_tool "$tool" "$scope" "${extra_flags[@]+"${extra_flags[@]}"}"; then
            ((success++)) || true
        else
            ((failed++)) || true
        fi
        [[ ${#ENV_PARSED_TOOLS[@]} -gt 1 ]] && echo ""
    done

    if [[ $failed -eq 0 ]]; then
        return $ENV_EXIT_SUCCESS
    elif [[ $success -gt 0 ]]; then
        return $ENV_EXIT_PARTIAL
    else
        return $ENV_EXIT_ALL_FAILED
    fi
}

# Handle 'cac env update' command
# Usage: env_cmd_update "$@"
env_cmd_update() {
    if ! _env_parse_scope_args "$@"; then
        return 1
    fi

    local scope="$ENV_PARSED_SCOPE"

    # No tools specified: update all installed
    if [[ ${#ENV_PARSED_TOOLS[@]} -eq 0 ]]; then
        env_update_all "$scope"
        return $?
    fi

    # Update specified tools
    local success=0
    local failed=0

    for tool in "${ENV_PARSED_TOOLS[@]}"; do
        if env_update_tool "$tool" "$scope"; then
            ((success++)) || true
        else
            ((failed++)) || true
        fi
        [[ ${#ENV_PARSED_TOOLS[@]} -gt 1 ]] && echo ""
    done

    if [[ $failed -eq 0 ]]; then
        return $ENV_EXIT_SUCCESS
    elif [[ $success -gt 0 ]]; then
        return $ENV_EXIT_PARTIAL
    else
        return $ENV_EXIT_ALL_FAILED
    fi
}

# Handle 'cac env status' command
# Usage: env_cmd_status "$@"
env_cmd_status() {
    if ! _env_parse_scope_args "$@"; then
        return 1
    fi

    if [[ "$ENV_PARSED_PARSEABLE" == "true" ]]; then
        env_show_status_parseable "$ENV_PARSED_CHECK_UPDATES"
    else
        env_show_status "$ENV_PARSED_CHECK_UPDATES"
    fi

    return $ENV_EXIT_SUCCESS
}
