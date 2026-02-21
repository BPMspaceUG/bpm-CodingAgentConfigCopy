#!/usr/bin/env bash
# uninstall.sh - Uninstaller for cac (Coding Agent Config)
# Removes cac CLI and optionally configuration files
#
# Usage:
#   ./uninstall.sh
#   ./uninstall.sh --purge        # Also remove configuration
#   ./uninstall.sh --full-purge   # Remove everything including skills and AI tools

set -euo pipefail

# Installation paths
SYS_BIN_DIR="/usr/local/bin"
SYS_LIB_DIR="/usr/local/lib/cac"
SYS_CONFIG_DIR="/etc/cac"

USER_BIN_DIR="${HOME}/.local/bin"
USER_LIB_DIR="${HOME}/.local/lib/cac"
USER_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/cac"

# Skill library paths
USER_SKILL_DIR="${HOME}/.claude/skills"
SYS_SKILL_DIR="/usr/local/lib/cac/skills"
USER_SKILL_MANIFEST="${XDG_CONFIG_HOME:-${HOME}/.config}/cac/skill-libraries.json"
SYS_SKILL_MANIFEST="/etc/cac/skill-libraries.json"

# AI tool global install paths (from lib/env.sh)
CLAUDE_GLOBAL_DIR="/opt/claude-code"
CLAUDE_GLOBAL_BIN="/usr/local/bin/claude"
CC_GLOBAL_DIR="/opt/continuous-claude"
CC_GLOBAL_BIN="/usr/local/bin/continuous-claude"

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Determine if running as root
is_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

# Determine if running interactively
is_interactive() {
    [[ -t 0 ]]
}

# Marker for PATH lines added by cac installer (2-line block)
CAC_PATH_MARKER="# Added by cac installer — do not edit"

# Remove cac PATH marker block from all RC files
_cleanup_path_entry() {
    local rc_file
    for rc_file in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        if [[ -f "$rc_file" ]] && grep -qF "$CAC_PATH_MARKER" "$rc_file"; then
            # Use temp file + cat to preserve file permissions/metadata
            local tmp_file
            tmp_file=$(mktemp)
            sed "/${CAC_PATH_MARKER//\//\\/}/,+1d" "$rc_file" > "$tmp_file" && \
                cat "$tmp_file" > "$rc_file"
            rm -f "$tmp_file" 2>/dev/null || true
            info "Removed PATH entry from ${rc_file}"
        fi
    done
}

# Remove directory if it exists
remove_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        success "Removed: $dir"
        return 0
    fi
    return 1
}

# Remove file if it exists
remove_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        rm -f "$file"
        success "Removed: $file"
        return 0
    fi
    return 1
}

# Check if a global binary is a cac-managed wrapper script
# Usage: _is_cac_managed_wrapper <binary_path> <marker_string>
# Returns: 0 if the file is a cac wrapper (contains marker), 1 otherwise
_is_cac_managed_wrapper() {
    local bin_path="$1"
    local marker="$2"

    [[ -f "$bin_path" ]] && grep -qF "$marker" "$bin_path" 2>/dev/null
}

# Check if a user-local binary is a cac-managed symlink
# Usage: _is_cac_managed_symlink <symlink_path>
# Returns: 0 if the symlink points to a cac global binary, 1 otherwise
_is_cac_managed_symlink() {
    local bin_path="$1"

    # Must be a symlink
    [[ -L "$bin_path" ]] || return 1

    local target
    target=$(readlink -f "$bin_path" 2>/dev/null) || return 1

    # Check if target points to a cac-managed global binary
    [[ "$target" == "$CLAUDE_GLOBAL_BIN" ]] || \
    [[ "$target" == "$CC_GLOBAL_BIN" ]] || \
    [[ "$target" == "/opt/claude-code/"* ]] || \
    [[ "$target" == "/opt/continuous-claude/"* ]]
}

# Remove skill libraries and manifests
# Usage: remove_skills
# Sets _SKILL_REMOVED to number of items removed
# Only removes skills if the manifest exists (ownership proof that cac installed them)
remove_skills() {
    _SKILL_REMOVED=0

    # User-scope: only remove if manifest exists (ownership proof)
    if [[ -f "$USER_SKILL_MANIFEST" ]]; then
        info "Removing user skill libraries (manifest found)..."
        remove_dir "$USER_SKILL_DIR" && { ((_SKILL_REMOVED++)) || true; }
        remove_file "$USER_SKILL_MANIFEST" && { ((_SKILL_REMOVED++)) || true; }
    elif [[ -d "$USER_SKILL_DIR" ]]; then
        warn "Skill directory exists but no manifest found: ${USER_SKILL_DIR}"
        info "Skipping (not confirmed as cac-managed)"
    fi

    # System-scope: only remove if manifest exists (ownership proof) and running as root
    if is_root; then
        if [[ -f "$SYS_SKILL_MANIFEST" ]]; then
            info "Removing system skill libraries (manifest found)..."
            remove_dir "$SYS_SKILL_DIR" && { ((_SKILL_REMOVED++)) || true; }
            remove_file "$SYS_SKILL_MANIFEST" && { ((_SKILL_REMOVED++)) || true; }
        elif [[ -d "$SYS_SKILL_DIR" ]]; then
            warn "System skill directory exists but no manifest found: ${SYS_SKILL_DIR}"
            info "Skipping (not confirmed as cac-managed)"
        fi
    elif [[ -d "$SYS_SKILL_DIR" ]] || [[ -f "$SYS_SKILL_MANIFEST" ]]; then
        warn "System skill files found but running as non-root"
        info "Run as root to remove system skills"
    fi
}

# Remove AI tool installations done by cac env install
# Usage: remove_ai_tools
# Sets _AI_REMOVED to number of items removed
# In interactive mode, prompts for confirmation. In non-interactive mode, skips.
remove_ai_tools() {
    _AI_REMOVED=0

    # In non-interactive mode, skip AI tool removal (safe default)
    if ! is_interactive; then
        info "Non-interactive mode: skipping AI tool removal"
        info "Run interactively with --full-purge to remove AI tools"
        return 0
    fi

    echo ""
    warn "AI tool removal will uninstall tools installed by 'cac env install'."
    echo "  This may include: Claude Code, Codex CLI, Gemini CLI, continuous-claude"
    echo ""
    read -rp "Remove AI tool installations? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        info "Skipping AI tool removal"
        return 0
    fi

    info "Removing AI tool installations..."

    # Global bun-based installs (requires root)
    # Only remove if we can verify cac ownership via wrapper script content
    if is_root; then
        # Claude Code: wrapper must contain /opt/claude-code (cac install marker)
        if _is_cac_managed_wrapper "$CLAUDE_GLOBAL_BIN" "/opt/claude-code"; then
            remove_file "$CLAUDE_GLOBAL_BIN" && { ((_AI_REMOVED++)) || true; }
            remove_dir "$CLAUDE_GLOBAL_DIR" && { ((_AI_REMOVED++)) || true; }
        elif [[ -f "$CLAUDE_GLOBAL_BIN" ]]; then
            warn "Skipping ${CLAUDE_GLOBAL_BIN}: not a cac-managed wrapper"
        fi

        # continuous-claude: wrapper must contain /opt/continuous-claude (cac install marker)
        if _is_cac_managed_wrapper "$CC_GLOBAL_BIN" "/opt/continuous-claude"; then
            remove_file "$CC_GLOBAL_BIN" && { ((_AI_REMOVED++)) || true; }
            remove_dir "$CC_GLOBAL_DIR" && { ((_AI_REMOVED++)) || true; }
        elif [[ -f "$CC_GLOBAL_BIN" ]]; then
            warn "Skipping ${CC_GLOBAL_BIN}: not a cac-managed wrapper"
        fi

        # npm global packages
        # Assumption: npm global codex/gemini packages are always cac-managed in our
        # context, since cac env install is the standard way to install them system-wide.
        if command -v npm &>/dev/null; then
            for pkg in "@openai/codex" "@google/gemini-cli"; do
                if npm list -g "$pkg" &>/dev/null; then
                    info "Removing npm global package: $pkg"
                    npm uninstall -g "$pkg" 2>/dev/null && { ((_AI_REMOVED++)) || true; }
                fi
            done
        fi
    fi

    # User-local symlinks for claude/continuous-claude
    # Only remove if they are symlinks pointing to cac-managed global binaries
    for tool_bin in "${HOME}/.local/bin/claude" "${HOME}/.local/bin/continuous-claude"; do
        if _is_cac_managed_symlink "$tool_bin"; then
            rm -f "$tool_bin"
            success "Removed: $tool_bin"
            ((_AI_REMOVED++)) || true
        elif [[ -e "$tool_bin" ]]; then
            warn "Skipping ${tool_bin}: not a cac-managed symlink"
        fi
    done

    # User-local npm packages
    # Assumption: npm user-local codex/gemini packages are always cac-managed,
    # since cac env install is the standard way to install them per-user.
    if command -v npm &>/dev/null; then
        for pkg in "@openai/codex" "@google/gemini-cli"; do
            if npm list -g --prefix "${HOME}/.local" "$pkg" &>/dev/null 2>&1; then
                info "Removing user npm package: $pkg"
                npm uninstall -g --prefix "${HOME}/.local" "$pkg" 2>/dev/null && { ((_AI_REMOVED++)) || true; }
            fi
        done
    fi
}

# Uninstall from system-wide location
uninstall_system() {
    local removed=0

    remove_file "${SYS_BIN_DIR}/cac" && { ((removed++)) || true; }
    remove_dir "$SYS_LIB_DIR" && { ((removed++)) || true; }

    if $PURGE; then
        remove_dir "$SYS_CONFIG_DIR" && { ((removed++)) || true; }
    elif [[ -d "$SYS_CONFIG_DIR" ]]; then
        warn "Configuration preserved: ${SYS_CONFIG_DIR}"
        info "Use --purge to remove, or: rm -rf ${SYS_CONFIG_DIR}"
    fi

    echo "$removed"
}

# Uninstall from user-local location
uninstall_user() {
    local removed=0

    remove_file "${USER_BIN_DIR}/cac" && { ((removed++)) || true; }
    remove_dir "$USER_LIB_DIR" && { ((removed++)) || true; }

    if $PURGE; then
        remove_dir "$USER_CONFIG_DIR" && { ((removed++)) || true; }
    elif [[ -d "$USER_CONFIG_DIR" ]]; then
        warn "Configuration preserved: ${USER_CONFIG_DIR}"
        info "Use --purge to remove, or: rm -rf ${USER_CONFIG_DIR}"
    fi

    echo "$removed"
}

# Main uninstall logic
do_uninstall() {
    echo ""
    echo "==================================="
    echo "   cac - Coding Agent Config"
    echo "   Uninstaller"
    echo "==================================="
    echo ""

    local total_removed=0
    local locations_checked=0

    # Check system-wide installation (if root or files are readable)
    if is_root || [[ -f "${SYS_BIN_DIR}/cac" ]] || [[ -d "$SYS_LIB_DIR" ]]; then
        if is_root; then
            info "Checking system-wide installation..."
            local sys_removed
            sys_removed=$(uninstall_system)
            total_removed=$((total_removed + sys_removed))
            ((locations_checked++)) || true
        elif [[ -f "${SYS_BIN_DIR}/cac" ]] || [[ -d "$SYS_LIB_DIR" ]]; then
            warn "System-wide installation found but running as non-root"
            info "Run as root to remove: sudo ./uninstall.sh"
        fi
    fi

    # Check user-local installation
    if [[ -f "${USER_BIN_DIR}/cac" ]] || [[ -d "$USER_LIB_DIR" ]] || [[ -d "$USER_CONFIG_DIR" ]]; then
        info "Checking user-local installation..."
        local user_removed
        user_removed=$(uninstall_user)
        total_removed=$((total_removed + user_removed))
        ((locations_checked++)) || true
    fi

    # Full purge: remove skills and AI tools
    if $FULL_PURGE; then
        echo ""
        remove_skills
        total_removed=$((total_removed + _SKILL_REMOVED))

        remove_ai_tools
        total_removed=$((total_removed + _AI_REMOVED))
    fi

    # Remove PATH entry from shell RC files
    if ! is_root; then
        _cleanup_path_entry
    fi

    echo ""

    if [[ "$total_removed" -eq 0 ]]; then
        if [[ "$locations_checked" -eq 0 ]]; then
            info "No cac installation found"
        else
            info "Nothing to remove"
        fi
    else
        echo "==================================="
        success "Uninstallation complete!"
        echo "==================================="
    fi
}

# Show usage
show_help() {
    echo "Usage: uninstall.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --purge, -p       Also remove configuration files"
    echo "  --full-purge      Remove everything: config, skills, and AI tools"
    echo "  --help, -h        Show this help message"
    echo ""
    echo "Modes:"
    echo "  (default)         Remove cac binary and libraries only"
    echo "  --purge           Also remove configuration directories"
    echo "  --full-purge      All of --purge plus:"
    echo "                      - Skill libraries and manifests"
    echo "                      - AI tool installations (interactive prompt)"
    echo ""
    echo "Locations checked:"
    echo "  System-wide (requires root):"
    echo "    Binary:    ${SYS_BIN_DIR}/cac"
    echo "    Libraries: ${SYS_LIB_DIR}/"
    echo "    Config:    ${SYS_CONFIG_DIR}/"
    echo "    Skills:    ${SYS_SKILL_DIR}/"
    echo "    Manifest:  ${SYS_SKILL_MANIFEST}"
    echo ""
    echo "  User-local:"
    echo "    Binary:    ${USER_BIN_DIR}/cac"
    echo "    Libraries: ${USER_LIB_DIR}/"
    echo "    Config:    ${USER_CONFIG_DIR}/"
    echo "    Skills:    ${USER_SKILL_DIR}/"
    echo "    Manifest:  ${USER_SKILL_MANIFEST}"
    echo ""
    echo "Non-interactive mode:"
    echo "  AI tool removal is skipped in non-interactive mode (safe default)."
    echo "  Run interactively with --full-purge to remove AI tools."
}

# Global options
PURGE=false
FULL_PURGE=false

# Main entry point
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge|-p)
                PURGE=true
                shift
                ;;
            --full-purge)
                FULL_PURGE=true
                PURGE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    do_uninstall
}

main "$@"
