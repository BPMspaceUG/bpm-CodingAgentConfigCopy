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
)

# Install URLs for curl-based tools
declare -A _ENV_INSTALL_URLS=(
    [claude]="https://claude.ai/install.sh"
    [continuous-claude]="https://raw.githubusercontent.com/AnandChowdhary/continuous-claude/main/install.sh"
)

# npm package names
declare -A _ENV_NPM_PACKAGES=(
    [codex]="@openai/codex"
    [gemini]="@google/gemini-cli"
)

# Minimum Node.js version required for npm tools
readonly ENV_MIN_NODE_VERSION="18"

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
# Usage: env_check_node
# Returns: 0 if OK, 1 if missing/too old
env_check_node() {
    if ! command -v node &>/dev/null; then
        utils_error "Node.js not found. Required for npm-based tools."
        return 1
    fi

    local version
    version=$(node --version 2>/dev/null | sed 's/^v//')
    local major
    major="${version%%.*}"

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

# Install a single tool
# Usage: env_install_tool <tool> <scope> [--yes]
# Returns: 0 on success, 1 on failure
env_install_tool() {
    local tool="$1"
    local scope="${2:-user}"
    local auto_yes="false"

    if [[ "${3:-}" == "--yes" ]]; then
        auto_yes="true"
    fi

    # Validate tool
    if ! env_validate_tool "$tool"; then
        utils_error "Unknown tool: $tool"
        echo "Valid tools: $(env_get_all_tools | tr '\n' ' ')" >&2
        return $ENV_EXIT_INVALID_ARG
    fi

    local display_name
    display_name=$(env_get_display_name "$tool")

    # Check if already installed
    if env_is_installed "$tool"; then
        local version
        version=$(env_get_version "$tool")
        echo "$display_name is already installed (version: $version)"
        echo "Use 'cac env update $tool' to update."
        return $ENV_EXIT_SUCCESS
    fi

    # Check dependencies
    if ! env_check_dependencies "$tool"; then
        return $ENV_EXIT_MISSING_DEP
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

            # Security: Confirm before running remote script
            echo "This will download and execute: $url"
            if [[ "$auto_yes" != "true" && -t 0 ]]; then
                read -rp "Continue? [y/N]: " confirm
                if [[ "${confirm,,}" != "y" ]]; then
                    echo "Installation cancelled."
                    return 1
                fi
            fi

            # Execute installer
            if [[ "$scope" == "global" || "$scope" == "all" ]]; then
                if [[ "$EUID" -ne 0 ]]; then
                    utils_error "Global installation requires root. Run with sudo."
                    return 1
                fi
                curl -fsSL "$url" | bash
            else
                curl -fsSL "$url" | bash
            fi
            ;;

        npm)
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

    if [[ $exit_code -eq 0 ]] && env_is_installed "$tool"; then
        local version
        version=$(env_get_version "$tool")
        utils_success "$display_name installed successfully (version: $version)"
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

    # Check dependencies
    if ! env_check_dependencies "$tool"; then
        return $ENV_EXIT_MISSING_DEP
    fi

    local install_type
    install_type=$(env_get_install_type "$tool")

    echo "Updating $display_name..."

    case "$install_type" in
        curl)
            # Re-run installer for curl-based tools
            local url="${_ENV_INSTALL_URLS[$tool]}"

            echo "Re-running installer from: $url"

            if [[ "$scope" == "global" || "$scope" == "all" ]]; then
                if [[ "$EUID" -ne 0 ]]; then
                    utils_error "Global update requires root. Run with sudo."
                    return 1
                fi
                curl -fsSL "$url" | bash
            else
                curl -fsSL "$url" | bash
            fi
            ;;

        npm)
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
            eval "$cmd"
            ;;
    esac

    local exit_code=$?
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
# Usage: env_install_all <scope> [--yes]
# Returns: 0 all succeeded, 1 partial, 2 all failed
env_install_all() {
    local scope="${1:-user}"
    local auto_yes="${2:-}"
    local success=0
    local failed=0
    local skipped=0

    echo "Installing all core AI tools..."
    echo ""

    while IFS= read -r tool; do
        if env_is_installed "$tool"; then
            local display_name version
            display_name=$(env_get_display_name "$tool")
            version=$(env_get_version "$tool")
            echo "Skipping $display_name (already installed: $version)"
            ((skipped++))
            continue
        fi

        if env_install_tool "$tool" "$scope" "$auto_yes"; then
            ((success++))
        else
            ((failed++))
        fi
        echo ""
    done < <(env_get_core_tools)

    echo "=== Installation Summary ==="
    echo "Installed: $success"
    echo "Skipped (already installed): $skipped"
    echo "Failed: $failed"

    if [[ $failed -eq 0 ]]; then
        return $ENV_EXIT_SUCCESS
    elif [[ $success -gt 0 ]]; then
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

    echo "Updating all installed AI tools..."
    echo ""

    while IFS= read -r tool; do
        if ! env_is_installed "$tool"; then
            ((skipped++))
            continue
        fi

        if env_update_tool "$tool" "$scope"; then
            ((success++))
        else
            ((failed++))
        fi
        echo ""
    done < <(env_get_all_tools)

    echo "=== Update Summary ==="
    echo "Updated: $success"
    echo "Skipped (not installed): $skipped"
    echo "Failed: $failed"

    if [[ $failed -eq 0 ]]; then
        return $ENV_EXIT_SUCCESS
    elif [[ $success -gt 0 ]]; then
        return $ENV_EXIT_PARTIAL
    else
        return $ENV_EXIT_ALL_FAILED
    fi
}

# ============================================================================
# Status Display Functions
# ============================================================================

# Show status of all tools (human-readable table)
# Usage: env_show_status
env_show_status() {
    printf "%-20s %-12s %-20s %-10s\n" "Tool" "Status" "Version" "Optional"
    printf "%-20s %-12s %-20s %-10s\n" "----" "------" "-------" "--------"

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

        printf "%-20s %-12s %-20s %-10s\n" "$display_name" "$status" "$version" "$opt_str"
    done
}

# Show status in parseable format (tab-separated)
# Usage: env_show_status_parseable
# Output: TOOL\tSTATUS\tVERSION per line
env_show_status_parseable() {
    for entry in "${_ENV_REGISTRY[@]}"; do
        local tool="${entry%%|*}"
        local status version

        if env_is_installed "$tool"; then
            status="installed"
            version=$(env_get_version "$tool")
        else
            status="not_found"
            version="-"
        fi

        printf "%s\t%s\t%s\n" "$tool" "$status" "$version"
    done
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
        ((i++))
    done < <(env_get_all_tools)

    echo "  [A] All core tools"
    echo "  [Q] Quit"
    echo ""

    read -rp "Enter selection (comma-separated for multiple, e.g., 1,2): " selection

    case "${selection^^}" in
        Q)
            echo "Installation cancelled."
            return 0
            ;;
        A)
            env_install_all "$scope" "--yes"
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

            for tool in "${selected_tools[@]}"; do
                if env_install_tool "$tool" "$scope" "--yes"; then
                    ((success++))
                else
                    ((failed++))
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
    local auto_yes=""
    [[ "$ENV_PARSED_YES" == "true" ]] && auto_yes="--yes"

    # No tools specified
    if [[ ${#ENV_PARSED_TOOLS[@]} -eq 0 ]]; then
        # Interactive mode
        if [[ -t 0 ]]; then
            env_interactive_install "$scope"
            return $?
        else
            # Non-interactive: install all core tools
            echo "Non-interactive mode: installing all core tools"
            env_install_all "$scope" "$auto_yes"
            return $?
        fi
    fi

    # Install specified tools
    local success=0
    local failed=0

    for tool in "${ENV_PARSED_TOOLS[@]}"; do
        if env_install_tool "$tool" "$scope" "$auto_yes"; then
            ((success++))
        else
            ((failed++))
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
            ((success++))
        else
            ((failed++))
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
        env_show_status_parseable
    else
        env_show_status
    fi

    return $ENV_EXIT_SUCCESS
}
