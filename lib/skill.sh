#!/usr/bin/env bash
# lib/skill.sh - Skill library management for Claude global agent skills
#
# Provides functions to install, update, list, and check status of
# skill libraries from Git repositories.

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/logging.sh"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/platform.sh"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Constants
# ============================================================================

# Guard with -v check to allow sourcing from multiple files.
if [[ ! -v SKILL_EXIT_SUCCESS ]]; then
    readonly SKILL_EXIT_SUCCESS=0
    readonly SKILL_EXIT_FAILURE=1
fi

SKILL_USER_DIR="${HOME}/.claude/skills"
SKILL_SYSTEM_DIR="/usr/local/lib/cac/skills"
SKILL_MANIFEST_USER="${XDG_CONFIG_HOME:-${HOME}/.config}/cac/skill-libraries.json"
SKILL_MANIFEST_SYSTEM="/etc/cac/skill-libraries.json"
# Strict regex for repo names — path traversal prevention
SKILL_REPO_NAME_REGEX='^[A-Za-z0-9._-]+$'

# ============================================================================
# Internal helpers
# ============================================================================

# Get the skill directory based on scope
# Usage: _skill_get_dir [global_flag]
_skill_get_dir() {
    local global_flag="${1:-false}"
    if [[ "$global_flag" == "true" ]]; then
        echo "$SKILL_SYSTEM_DIR"
    else
        echo "$SKILL_USER_DIR"
    fi
}

# Get the manifest file path based on scope
# Usage: _skill_manifest_path <global_flag>
_skill_manifest_path() {
    local global_flag="${1:-false}"
    if [[ "$global_flag" == "true" ]]; then
        echo "$SKILL_MANIFEST_SYSTEM"
    else
        echo "$SKILL_MANIFEST_USER"
    fi
}

# Read the manifest JSON (returns empty array if not found)
# Usage: _skill_manifest_read <manifest_path>
_skill_manifest_read() {
    local manifest_path="$1"
    if [[ -f "$manifest_path" ]]; then
        # Strip trailing whitespace/newlines for reliable parsing
        tr -d '\n' < "$manifest_path"
    else
        printf '%s' "[]"
    fi
}

# Write manifest JSON atomically
# Usage: _skill_manifest_write <manifest_path> <json>
_skill_manifest_write() {
    local manifest_path="$1"
    local json="$2"
    local tmp_file="${manifest_path}.tmp.$$"

    printf '%s\n' "$json" > "$tmp_file"
    mv "$tmp_file" "$manifest_path"
}

# Extract repository name from a Git URL
# Supports: https://github.com/org/repo.git, git@github.com:org/repo.git, etc.
# Usage: _skill_repo_name_from_url <url>
_skill_repo_name_from_url() {
    local url="$1"
    local name

    # Reject URLs starting with '-' to prevent git option injection
    if [[ "$url" == -* ]]; then
        utils_error "Invalid repository URL: must not start with '-'"
        return 1
    fi

    # Strip trailing .git
    name="${url%.git}"
    # Strip trailing slash
    name="${name%/}"
    # Get last path component
    name="${name##*/}"
    # For ssh URLs like git@github.com:org/repo — strip everything before last /
    name="${name##*:}"
    name="${name##*/}"

    # Validate: must match strict alphanumeric pattern (path traversal prevention)
    # Also reject . and .. explicitly

    if [[ -z "$name" || "$name" == "." || "$name" == ".." ]] || ! [[ "$name" =~ $SKILL_REPO_NAME_REGEX ]]; then
        utils_error "Invalid repository name '${name}' from URL: $url (must match ${SKILL_REPO_NAME_REGEX})"
        return 1
    fi

    echo "$name"
}

# Check if a library exists in the manifest
# Usage: _skill_manifest_has_entry <manifest_path> <name>
_skill_manifest_has_entry() {
    local manifest_path="$1"
    local name="$2"
    local manifest

    manifest=$(_skill_manifest_read "$manifest_path")
    # Simple grep-based check for the name field
    printf '%s' "$manifest" | grep -q "\"name\":\"${name}\""
}

# Add an entry to the manifest
# Usage: _skill_manifest_add_entry <manifest_path> <name> <url> <sha> <date>
_skill_manifest_add_entry() {
    local manifest_path="$1"
    local name="$2"
    local url="$3"
    local sha="$4"
    local date="$5"
    local manifest new_entry

    manifest=$(_skill_manifest_read "$manifest_path")
    new_entry="{\"name\":\"${name}\",\"url\":\"${url}\",\"sha\":\"${sha}\",\"installed\":\"${date}\"}"

    if [[ "$manifest" == "[]" ]]; then
        _skill_manifest_write "$manifest_path" "[${new_entry}]"
    else
        # Remove trailing ] and add new entry
        manifest="${manifest%]}"
        _skill_manifest_write "$manifest_path" "${manifest},${new_entry}]"
    fi
}

# Update the SHA for an existing entry in the manifest
# Usage: _skill_manifest_update_sha <manifest_path> <name> <new_sha>
_skill_manifest_update_sha() {
    local manifest_path="$1"
    local name="$2"
    local new_sha="$3"
    local manifest

    manifest=$(_skill_manifest_read "$manifest_path")

    # Rebuild manifest replacing SHA for the matching entry
    local result="["
    local first=true
    local entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if [[ "$first" == "true" ]]; then
            first=false
        else
            result="${result},"
        fi
        local entry_name
        entry_name=$(_skill_json_field "$entry" "name")
        if [[ "$entry_name" == "$name" ]]; then
            # Replace sha value using sed with | delimiter to avoid URL conflicts
            entry=$(printf '%s' "$entry" | sed "s|\"sha\":\"[^\"]*\"|\"sha\":\"${new_sha}\"|")
        fi
        result="${result}${entry}"
    done < <(printf '%s\n' "$manifest" | tr -d '[]' | sed 's/},{/}\n{/g')
    result="${result}]"

    _skill_manifest_write "$manifest_path" "$result"
}

# Remove an entry from the manifest by name
# Usage: _skill_manifest_remove_entry <manifest_path> <name>
_skill_manifest_remove_entry() {
    local manifest_path="$1"
    local name="$2"
    local manifest result

    manifest=$(_skill_manifest_read "$manifest_path")

    # Remove the entry matching the name, handling commas
    # This approach: rebuild without the matching entry
    result="["
    local first=true
    local entry
    # Parse entries by splitting on },{ pattern
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if echo "$entry" | grep -q "\"name\":\"${name}\""; then
            continue
        fi
        if [[ "$first" == "true" ]]; then
            first=false
        else
            result="${result},"
        fi
        result="${result}${entry}"
    done < <(printf '%s\n' "$manifest" | tr -d '[]' | sed 's/},{/}\n{/g')

    result="${result}]"
    _skill_manifest_write "$manifest_path" "$result"
}

# List all entries from the manifest
# Usage: _skill_manifest_list_entries <manifest_path>
# Output: one JSON object per line
_skill_manifest_list_entries() {
    local manifest_path="$1"
    local manifest

    manifest=$(_skill_manifest_read "$manifest_path")
    if [[ "$manifest" == "[]" ]]; then
        return 0
    fi

    printf '%s\n' "$manifest" | tr -d '[]' | sed 's/},{/}\n{/g'
}

# Get a specific field from a JSON entry line
# Usage: _skill_json_field <json_line> <field_name>
_skill_json_field() {
    local json="$1"
    local field="$2"

    printf '%s' "$json" | sed "s/.*\"${field}\":\"\([^\"]*\)\".*/\1/"
}

# Find my-* prefixed items in a library directory
# Usage: _skill_find_my_prefixed <lib_dir>
_skill_find_my_prefixed() {
    local lib_dir="$1"
    local found=()

    if [[ ! -d "$lib_dir" ]]; then
        return 0
    fi

    local item
    for item in "${lib_dir}"/my-*; do
        [[ -e "$item" ]] || continue
        found+=("$(basename "$item")")
    done

    if [[ ${#found[@]} -gt 0 ]]; then
        printf '%s\n' "${found[@]}"
    fi
}

# ============================================================================
# Public functions
# ============================================================================

# Install a skill library from a Git URL
# Usage: skill_install <url> [--global] [--yes]
skill_install() {
    local url=""
    local global_flag="false"
    local yes_flag="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) global_flag="true"; shift ;;
            --yes|-y) yes_flag="true"; shift ;;
            -*) utils_error "Unknown option: $1"; return "$SKILL_EXIT_FAILURE" ;;
            *) url="$1"; shift ;;
        esac
    done

    if [[ -z "$url" ]]; then
        utils_error "Usage: cac skill install <URL> [--global] [--yes]"
        return "$SKILL_EXIT_FAILURE"
    fi

    # Check git is installed
    if ! command -v git &>/dev/null; then
        utils_error "git is not installed. Install it with: $(platform_install_hint git)"
        return "$SKILL_EXIT_FAILURE"
    fi

    # Check root for --global
    if [[ "$global_flag" == "true" && "$(id -u)" -ne 0 ]]; then
        utils_error "System-wide install (--global) requires root privileges"
        return "$SKILL_EXIT_FAILURE"
    fi

    # Extract repo name
    local name
    if ! name=$(_skill_repo_name_from_url "$url"); then
        return "$SKILL_EXIT_FAILURE"
    fi

    local skill_dir
    skill_dir=$(_skill_get_dir "$global_flag")
    local manifest_path
    manifest_path=$(_skill_manifest_path "$global_flag")
    local lib_path="${skill_dir}/${name}"

    # Check if already installed
    if [[ -d "$lib_path" ]]; then
        utils_error "Library '${name}' is already installed at ${lib_path}"
        echo "Use 'cac skill update ${name}' to update it." >&2
        return "$SKILL_EXIT_FAILURE"
    fi

    # Create skill directory and manifest parent dir if needed
    mkdir -p "$skill_dir"
    mkdir -p "$(dirname "$manifest_path")"

    utils_verbose "Installing skill library '${name}' from ${url}"
    utils_verbose "Target directory: ${lib_path}"

    # Clone the repository
    local clone_output
    if ! clone_output=$(git clone -- "$url" "$lib_path" 2>&1); then
        utils_error "Failed to clone repository: ${url}"
        echo "$clone_output" >&2
        return "$SKILL_EXIT_FAILURE"
    fi

    # Get current commit SHA
    local sha
    sha=$(git -C "$lib_path" rev-parse HEAD 2>/dev/null || echo "unknown")

    # Get current date in ISO 8601
    local install_date
    install_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Update manifest
    _skill_manifest_add_entry "$manifest_path" "$name" "$url" "$sha" "$install_date"

    local short_sha="${sha:0:8}"
    utils_success "Installed skill library '${name}' (${short_sha})"
    echo "  Location: ${lib_path}"

    return "$SKILL_EXIT_SUCCESS"
}

# Update installed skill libraries
# Usage: skill_update [library_name] [--yes] [--global]
skill_update() {
    local library_name=""
    local global_flag="false"
    local yes_flag="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) global_flag="true"; shift ;;
            --yes|-y) yes_flag="true"; shift ;;
            -*) utils_error "Unknown option: $1"; return "$SKILL_EXIT_FAILURE" ;;
            *) library_name="$1"; shift ;;
        esac
    done

    # Check git is installed
    if ! command -v git &>/dev/null; then
        utils_error "git is not installed. Install it with: $(platform_install_hint git)"
        return "$SKILL_EXIT_FAILURE"
    fi

    # Check root for --global
    if [[ "$global_flag" == "true" && "$(id -u)" -ne 0 ]]; then
        utils_error "System-wide update (--global) requires root privileges"
        return "$SKILL_EXIT_FAILURE"
    fi

    local skill_dir
    skill_dir=$(_skill_get_dir "$global_flag")
    local manifest_path
    manifest_path=$(_skill_manifest_path "$global_flag")

    if [[ ! -f "$manifest_path" ]]; then
        utils_warn "No skill libraries installed. Use 'cac skill install <URL>' to install one."
        return "$SKILL_EXIT_SUCCESS"
    fi

    local updated=0
    local failed=0
    local skipped=0

    # Process entries
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        local name url
        name=$(_skill_json_field "$entry" "name")
        url=$(_skill_json_field "$entry" "url")

        # Validate manifest name before building path (path traversal prevention)
        if [[ -z "$name" || "$name" == "." || "$name" == ".." ]] || ! [[ "$name" =~ $SKILL_REPO_NAME_REGEX ]]; then
            utils_warn "Manifest contains invalid library name '${name}'. Skipping."
            ((skipped++)) || true
            continue
        fi

        # If specific library requested, skip others
        if [[ -n "$library_name" && "$name" != "$library_name" ]]; then
            continue
        fi

        local lib_path="${skill_dir}/${name}"
        if [[ ! -d "$lib_path/.git" ]]; then
            utils_warn "Library '${name}' directory missing or not a git repo. Skipping."
            ((skipped++)) || true
            continue
        fi

        # Check for dirty working tree before any update
        local porcelain_output
        porcelain_output=$(git -C "$lib_path" status --porcelain 2>/dev/null || echo "")
        if [[ -n "$porcelain_output" ]]; then
            utils_warn "Library '${name}' has uncommitted changes. Skipping update."
            utils_verbose "Dirty files: ${porcelain_output}"
            ((skipped++)) || true
            continue
        fi

        utils_verbose "Checking for updates: ${name}"

        # Fetch remote changes
        local fetch_output
        if ! fetch_output=$(git -C "$lib_path" fetch origin 2>&1); then
            utils_error "Failed to fetch updates for '${name}': ${fetch_output}"
            ((failed++)) || true
            continue
        fi

        # Check if there are changes
        local local_sha remote_sha
        local_sha=$(git -C "$lib_path" rev-parse HEAD 2>/dev/null || echo "unknown")

        # Get the default branch name
        local default_branch
        default_branch=$(git -C "$lib_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")

        remote_sha=$(git -C "$lib_path" rev-parse "origin/${default_branch}" 2>/dev/null || echo "unknown")

        if [[ "$local_sha" == "$remote_sha" ]]; then
            echo "  ${name}: already up to date (${local_sha:0:8})"
            ((skipped++)) || true
            continue
        fi

        # Show what would change
        echo "  ${name}: update available"
        echo "    Current: ${local_sha:0:8}"
        echo "    Remote:  ${remote_sha:0:8}"

        local log_output
        log_output=$(git -C "$lib_path" log --oneline "HEAD..origin/${default_branch}" 2>/dev/null || echo "")
        if [[ -n "$log_output" ]]; then
            echo "    Changes:"
            while IFS= read -r log_line; do
                echo "      ${log_line}"
            done <<< "$log_output"
        fi

        # Check for my-* prefixed items in the skill root dir (NOT inside library subdirs).
        # User-customised my-* skills live directly in the skills dir and must never be
        # touched by library updates.
        local my_items
        my_items=$(_skill_find_my_prefixed "$skill_dir")
        if [[ -n "$my_items" ]]; then
            utils_verbose "User-customised my-* items in ${skill_dir} (protected): ${my_items}"
        fi

        # Confirm unless --yes
        if [[ "$yes_flag" != "true" ]]; then
            echo ""
            read -r -p "    Apply update for '${name}'? [y/N] " confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo "    Skipped."
                ((skipped++)) || true
                continue
            fi
        fi

        # Apply update
        local pull_output
        if ! pull_output=$(git -C "$lib_path" pull 2>&1); then
            utils_error "Failed to update '${name}': ${pull_output}"
            ((failed++)) || true
            continue
        fi

        # Update manifest SHA
        local new_sha
        new_sha=$(git -C "$lib_path" rev-parse HEAD 2>/dev/null || echo "unknown")
        _skill_manifest_update_sha "$manifest_path" "$name" "$new_sha"

        utils_success "Updated '${name}' to ${new_sha:0:8}"
        ((updated++)) || true

    done < <(_skill_manifest_list_entries "$manifest_path")

    # Check if specific library was not found
    if [[ -n "$library_name" && $updated -eq 0 && $failed -eq 0 && $skipped -eq 0 ]]; then
        utils_error "Library '${library_name}' not found. Use 'cac skill list' to see installed libraries."
        return "$SKILL_EXIT_FAILURE"
    fi

    echo ""
    echo "Update summary: ${updated} updated, ${skipped} skipped, ${failed} failed"

    if [[ $failed -gt 0 ]]; then
        return "$SKILL_EXIT_FAILURE"
    fi
    return "$SKILL_EXIT_SUCCESS"
}

# List installed skill libraries
# Usage: skill_list [--global]
skill_list() {
    local global_flag="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) global_flag="true"; shift ;;
            -*) utils_error "Unknown option: $1"; return "$SKILL_EXIT_FAILURE" ;;
            *) shift ;;
        esac
    done

    local skill_dir
    skill_dir=$(_skill_get_dir "$global_flag")
    local manifest_path
    manifest_path=$(_skill_manifest_path "$global_flag")

    if [[ ! -f "$manifest_path" ]]; then
        echo "No skill libraries installed."
        echo ""
        echo "Install one with: cac skill install <URL>"
        echo ""
        echo "Known repositories:"
        echo "  https://github.com/BPMspaceUG/bpm-claude-global-agent-skill-library.git"
        echo "  https://github.com/International-Certification-Org/ico-claude-global-agent-skill-library.git"
        return "$SKILL_EXIT_SUCCESS"
    fi

    local count=0
    echo "Installed skill libraries (${skill_dir}):"
    echo ""
    printf "  %-45s %-10s %s\n" "LIBRARY" "SHA" "INSTALLED"
    printf "  %-45s %-10s %s\n" "-------" "---" "---------"

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        local name sha installed
        name=$(_skill_json_field "$entry" "name")
        sha=$(_skill_json_field "$entry" "sha")
        installed=$(_skill_json_field "$entry" "installed")

        printf "  %-45s %-10s %s\n" "$name" "${sha:0:8}" "${installed}"
        ((count++)) || true
    done < <(_skill_manifest_list_entries "$manifest_path")

    echo ""
    echo "Total: ${count} libraries"

    return "$SKILL_EXIT_SUCCESS"
}

# Show status of installed skill libraries with update availability
# Usage: skill_status [--global]
skill_status() {
    local global_flag="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) global_flag="true"; shift ;;
            -*) utils_error "Unknown option: $1"; return "$SKILL_EXIT_FAILURE" ;;
            *) shift ;;
        esac
    done

    # Check git is installed
    if ! command -v git &>/dev/null; then
        utils_error "git is not installed. Install it with: $(platform_install_hint git)"
        return "$SKILL_EXIT_FAILURE"
    fi

    local skill_dir
    skill_dir=$(_skill_get_dir "$global_flag")
    local manifest_path
    manifest_path=$(_skill_manifest_path "$global_flag")

    if [[ ! -f "$manifest_path" ]]; then
        echo "No skill libraries installed."
        echo "Install one with: cac skill install <URL>"
        return "$SKILL_EXIT_SUCCESS"
    fi

    echo "Skill library status (${skill_dir}):"
    echo ""
    printf "  %-45s %-10s %s\n" "LIBRARY" "SHA" "STATUS"
    printf "  %-45s %-10s %s\n" "-------" "---" "------"

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        local name sha
        name=$(_skill_json_field "$entry" "name")
        sha=$(_skill_json_field "$entry" "sha")

        # Validate manifest name before building path (path traversal prevention)
        if [[ -z "$name" || "$name" == "." || "$name" == ".." ]] || ! [[ "$name" =~ $SKILL_REPO_NAME_REGEX ]]; then
            printf "  %-45s %-10s %s\n" "${name:-<empty>}" "n/a" "invalid-name"
            continue
        fi

        local lib_path="${skill_dir}/${name}"
        local status="unknown"

        if [[ ! -d "$lib_path/.git" ]]; then
            status="missing"
        else
            # Try to fetch and compare
            local fetch_ok="true"
            git -C "$lib_path" fetch origin &>/dev/null || fetch_ok="false"

            if [[ "$fetch_ok" == "true" ]]; then
                local default_branch
                default_branch=$(git -C "$lib_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")

                local remote_sha
                remote_sha=$(git -C "$lib_path" rev-parse "origin/${default_branch}" 2>/dev/null || echo "unknown")
                local local_sha
                local_sha=$(git -C "$lib_path" rev-parse HEAD 2>/dev/null || echo "unknown")

                if [[ "$local_sha" == "$remote_sha" ]]; then
                    status="up-to-date"
                else
                    status="update-available"
                fi
            else
                status="fetch-failed"
            fi
        fi

        printf "  %-45s %-10s %s\n" "$name" "${sha:0:8}" "$status"
    done < <(_skill_manifest_list_entries "$manifest_path")

    echo ""
    return "$SKILL_EXIT_SUCCESS"
}

# ============================================================================
# Subcommand router
# ============================================================================

# Show skill subcommand help
_skill_show_help() {
    cat <<EOF
cac skill - Manage Claude global agent skill libraries

USAGE:
    cac skill <subcommand> [options]

SUBCOMMANDS:
    install <URL> [--global] [--yes]  Install a skill library from Git
    update [LIBRARY] [--global] [--yes]  Update installed skill libraries
    list [--global]                   List installed skill libraries
    status [--global]                 Show libraries with update availability

OPTIONS:
    --global          Use system-wide directory (requires root)
    --yes, -y         Skip confirmation prompts

KNOWN REPOSITORIES:
    BPMspaceUG:
      https://github.com/BPMspaceUG/bpm-claude-global-agent-skill-library.git
    International-Certification-Org:
      https://github.com/International-Certification-Org/ico-claude-global-agent-skill-library.git

EXAMPLES:
    cac skill install https://github.com/BPMspaceUG/bpm-claude-global-agent-skill-library.git
    cac skill list                    List installed skill libraries
    cac skill update                  Update all installed libraries
    cac skill update my-lib --yes     Update specific library without prompt
    cac skill status                  Show libraries with update availability

EOF
}

# Main subcommand router (called from bin/cac)
# Usage: skill_cmd_main <subcommand> [args...]
skill_cmd_main() {
    local subcommand="${1:-list}"
    shift || true

    case "$subcommand" in
        install)
            skill_install "$@"
            ;;
        update)
            skill_update "$@"
            ;;
        list)
            skill_list "$@"
            ;;
        status)
            skill_status "$@"
            ;;
        --help|-h)
            _skill_show_help
            ;;
        *)
            utils_error "Unknown skill subcommand: $subcommand"
            echo "Run 'cac skill --help' for usage information." >&2
            return 1
            ;;
    esac
}
