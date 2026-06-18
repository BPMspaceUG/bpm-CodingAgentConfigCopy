#!/usr/bin/env bash
# lib/env.sh - AI coding tool environment installation and management
#
# Provides functions to install, update, and check status of AI coding tools
# (Claude Code, Codex CLI, Gemini CLI, continuous-claude).

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/logging.sh"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/platform.sh"

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
    # Issue #79: a globally-installed tool could not be escalated to (no sudo,
    # unresolved cac path, or already root). Internal signal — not a process
    # exit code; env_cmd_update folds it into the tri-state summary.
    readonly ENV_EXIT_NEEDS_ROOT=5

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
        "playwright|Playwright|command -v playwright|playwright --version|npm|yes"
    )

    # Install URLs for curl-based tools.
    # Issue #73 INVARIANT: each URL listed here MUST resolve to a plain shell
    # installer compatible with download-then-execute. See _ENV_CURL_TARGET_DIR
    # below for the full invariant statement.
    declare -A _ENV_INSTALL_URLS=(
        [claude]="https://claude.ai/install.sh"
        [continuous-claude]="https://raw.githubusercontent.com/AnandChowdhary/continuous-claude/main/install.sh"
        [mistral]="https://mistral.ai/vibe/install.sh"
    )

    # npm package names
    declare -A _ENV_NPM_PACKAGES=(
        [codex]="@openai/codex"
        [gemini]="@google/gemini-cli"
        [playwright]="@playwright/test"
    )

    # Minimum Node.js version required for npm tools
    readonly ENV_MIN_NODE_VERSION="18"

    # npm package names for latest version lookup (Issue #30)
    declare -A _ENV_NPM_LOOKUP=(
        [claude]="@anthropic-ai/claude-code"
        [codex]="@openai/codex"
        [gemini]="@google/gemini-cli"
        [continuous-claude]="continuous-claude"
        [playwright]="@playwright/test"
    )

    # Cache TTL for latest version lookups (seconds) - 5 minutes
    readonly _ENV_LATEST_CACHE_TTL=300

    # Issue #73 — INVARIANT: every curl-installed tool listed in this registry
    # (and every URL in _ENV_INSTALL_URLS) MUST be a plain shell installer that
    # works under download-then-execute, i.e. the semantics of
    #   curl -fsSL "$url" -o foo.sh && bash foo.sh
    # is equivalent to
    #   curl -fsSL "$url" | bash
    # Self-extracting tarballs piped into bash do NOT work under this scheme and
    # MUST NOT be added to either registry. Before adding a new curl tool,
    # verify with `curl -fsSL "$url" | head -50` — the output must be a plain
    # shell script. If a tool requires piped self-extraction, document it as
    # unsupported by `cac env update` until a separate stream-execute path is
    # added.
    #
    # Each entry maps tool -> well-known install target dir, used by
    # _env_diag_preflight_curl for writability + free-space pre-flight checks.
    # Tools not listed here skip the pre-flight (safe default).
    declare -A _ENV_CURL_TARGET_DIR=(
        [continuous-claude]="/opt/continuous-claude"
        [claude]="$HOME/.local/bin"
        [mistral]="$HOME/.vibe"
    )
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
        playwright)        echo "playwright" ;;
        *) return 1 ;;
    esac
}

# Detect whether a system-wide install of a tool exists (Issue #71)
# Used to refuse user-scope updates that would create dual-install drift.
# Returns 0 if global install detected, 1 otherwise.
# Usage: _env_global_install_exists <tool>
_env_global_install_exists() {
    local tool="$1"
    local binary
    binary=$(_env_tool_to_binary "$tool" 2>/dev/null) || return 1

    # Direct check: file or symlink in /usr/local/bin
    if [[ -e "/usr/local/bin/$binary" ]] || [[ -L "/usr/local/bin/$binary" ]]; then
        return 0
    fi

    # Fallback: resolve via PATH stripped of all user-local dirs
    # (catches /opt/* style globals)
    local sanitized_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    local resolved
    resolved=$(PATH="$sanitized_path" command -v "$binary" 2>/dev/null || true)
    [[ -n "$resolved" ]]
}

# Detect whether a genuine per-user install of a tool exists (Issue #79).
# Layout-agnostic: curl installers land in different places per tool
# (claude -> ~/.local/bin, continuous-claude -> /opt, mistral -> ~/.vibe), so we
# do NOT hardcode a single path. Instead we resolve the binary through the
# user's normal PATH and accept it as a per-user install only when it both:
#   * lives under $HOME (a copy the user owns/can overwrite), and
#   * is not merely a symlink into a global location (/usr/local or /opt) — that
#     is the Issue #71 propagation of the global binary, not a distinct copy.
# Because this uses real PATH resolution, "both installs exist" is reported only
# when the user's PATH actually prefers the HOME copy — i.e. exactly the case
# where escalating the global copy would update the one they are NOT running.
# Returns 0 if a per-user install exists, 1 otherwise.
# Usage: _env_user_install_exists <tool>
_env_user_install_exists() {
    local tool="$1"
    local binary
    binary=$(_env_tool_to_binary "$tool" 2>/dev/null) || return 1

    # type -P is a path-only resolver: it ignores shell aliases/functions, so
    # classification cannot be skewed by an interactive `alias claude=...`.
    local resolved
    resolved=$(type -P "$binary" 2>/dev/null || true)
    [[ -n "$resolved" ]] || return 1

    # Positive test (Codex): the REAL target (after resolving every symlink) must
    # live under $HOME. A link whose target is any non-home location — global or
    # otherwise — is not a per-user copy and must not qualify for the #71 override.
    local real
    real=$(readlink -f "$resolved" 2>/dev/null || true)
    [[ -n "$real" ]] || real="$resolved"
    case "$real" in
        "$HOME"/*) return 0 ;;
        *)         return 1 ;;
    esac
}

# Decide how `cac env update` should update a curl tool for a non-root user
# (Issue #79). The rule follows what the user ACTUALLY runs, via PATH resolution,
# so we never update a copy they are not executing. Echoes exactly one of:
#   local    -> update at user scope, in-process. Either no system-wide install
#               exists, OR the user's PATH resolves to their own per-user copy
#               (~/.local). Updating that copy is correct and needs no root.
#   escalate -> the user runs the system-wide copy (PATH resolves outside $HOME);
#               a sudo re-exec is required to update it.
# Usage: _env_update_action <tool>
_env_update_action() {
    local tool="$1"
    # No system-wide install at all -> a plain user-scope update is always safe.
    if ! _env_global_install_exists "$tool"; then
        echo "local"
        return 0
    fi
    # A system-wide install exists. If the user's PATH still resolves to their
    # own per-user copy, update THAT (the one they run) without root. Otherwise
    # they execute the global copy and we must escalate.
    if _env_user_install_exists "$tool"; then
        echo "local"
    else
        echo "escalate"
    fi
}

# Resolve the absolute path to the running `cac` entrypoint for a safe sudo
# re-exec (Issue #79). For a privilege boundary we never reconstruct the command
# loosely from $0. Preference order:
#   1. $CAC_BIN  (exported by bin/cac as an absolute path)
#   2. command -v cac  (only if it resolves to an absolute, executable path)
# Echoes the path on success; returns 1 (no output) if none is trustworthy.
# Usage: _env_resolve_cac_bin
_env_resolve_cac_bin() {
    local candidate=""
    if [[ -n "${CAC_BIN:-}" ]]; then
        candidate="$CAC_BIN"
    else
        candidate=$(command -v cac 2>/dev/null || true)
    fi

    [[ -n "$candidate" ]] || return 1
    [[ "$candidate" == /* ]] || return 1
    [[ -x "$candidate" ]] || return 1
    echo "$candidate"
}

# Re-exec `cac env update --global <tools>` under sudo as a subprocess
# (Issue #79). NOT `exec` — the parent keeps its aggregation state so mixed
# local/global batches stay coherent. Returns the child's exit code, or a
# dedicated code when escalation is impossible:
#   0/1/2  = child tri-state (success/partial/all-failed)
#   $ENV_EXIT_NEEDS_ROOT = could not escalate (no sudo / unresolved cac path)
# Usage: _env_reexec_sudo_update <tool>...
_env_reexec_sudo_update() {
    local -a tools=("$@")
    [[ ${#tools[@]} -gt 0 ]] || return 0

    # Only meaningful for a non-root caller.
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        return "$ENV_EXIT_NEEDS_ROOT"
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        utils_error "sudo not found — cannot update system-wide tools: ${tools[*]}"
        echo "Remediation: re-run as root (e.g. 'su -' then 'cac env update --global ${tools[*]}')." >&2
        return "$ENV_EXIT_NEEDS_ROOT"
    fi

    local cac_bin
    if ! cac_bin=$(_env_resolve_cac_bin); then
        utils_error "Could not resolve the cac executable path — refusing to escalate."
        echo "Remediation: run 'sudo cac env update --global ${tools[*]}' manually." >&2
        return "$ENV_EXIT_NEEDS_ROOT"
    fi

    echo "${#tools[@]} tool(s) installed system-wide — escalating with sudo: ${tools[*]}"
    # argv array, never eval.
    #
    # Recursion safety (Codex): the LOAD-BEARING guard is the --global flag, not
    # the env sentinel. The child parses --global as an *explicit* scope, so it
    # can never re-enter the auto-escalation branch (gated on implicit scope).
    # And if a broken/mocked sudo runs the child WITHOUT actually elevating, the
    # child sees --global + EUID!=0 and is rejected by _env_parse_scope_args
    # ("Scope --global requires root") — terminating, not looping. This holds
    # regardless of whether the sentinel survives sudo's env reset.
    #
    # --preserve-env makes CAC_ENV_ESCALATED survive sudo as defense-in-depth for
    # any future caller that does NOT pass --global. If a hardened sudoers policy
    # strips it, correctness still holds via the --global guard above.
    CAC_ENV_ESCALATED=1 sudo --preserve-env=CAC_ENV_ESCALATED -- \
        "$cac_bin" env update --global "${tools[@]}"
}

# Iterate candidate user homes for multi-user symlink propagation (Issue #71)
# Yields one path per line: /root and every /home/* that is a directory.
# Used by _env_propagate_user_symlinks.
# Usage: _env_iter_user_homes
_env_iter_user_homes() {
    [[ -d /root ]] && echo /root
    local d
    for d in /home/*/; do
        # Guard against the literal '/home/*/' when /home is empty
        [[ -d "$d" ]] || continue
        echo "${d%/}"
    done
}

# Propagate a global binary into every user's ~/.local/bin via symlink (Issue #71)
# Walks /home/* and /root, creates ~/.local/bin/<binary> -> /usr/local/bin/<binary>
# only where ~/.local/bin already exists (never auto-creates the directory) and
# where no entry is already present (never overwrites).
# Usage: _env_propagate_user_symlinks <binary>
# Returns 0 always (per-home failures are non-fatal).
_env_propagate_user_symlinks() {
    local binary="$1"
    local target="/usr/local/bin/$binary"

    [[ -e "$target" ]] || return 0  # nothing to symlink to

    local home user_local_bin link_path home_owner
    while IFS= read -r home; do
        user_local_bin="$home/.local/bin"
        # Don't auto-create the directory — respect the user's setup.
        [[ -d "$user_local_bin" ]] || continue
        # Skip if we cannot read/write the directory (e.g. chmod 000).
        [[ -r "$user_local_bin" && -w "$user_local_bin" ]] || continue

        link_path="$user_local_bin/$binary"
        # Respect any existing entry (file, symlink, broken symlink).
        if [[ -L "$link_path" || -e "$link_path" ]]; then
            continue
        fi

        if ln -sf "$target" "$link_path" 2>/dev/null; then
            home_owner=$(stat -c '%U:%G' "$home" 2>/dev/null || true)
            if [[ -n "$home_owner" ]]; then
                chown -h "$home_owner" "$link_path" 2>/dev/null || true
            fi
            utils_verbose "Created symlink $link_path -> $target"
        fi
    done < <(_env_iter_user_homes)

    return 0
}

# Compare two version strings semver-style (Issue #71)
# Returns 0 iff a < b (i.e. "a" is older than "b" -> a regression when a is post).
# Returns 1 if a == b, a > b, or either side cannot be normalised to semver.
# Conservative: equal-after-normalisation (e.g. prerelease tags stripped) is NOT a regression.
# Usage: _env_version_lt <a> <b>
_env_version_lt() {
    local a_norm b_norm
    a_norm=$(_env_normalize_version "$1")
    b_norm=$(_env_normalize_version "$2")

    # Bail out conservatively if either side is non-semver (e.g. "unknown").
    if [[ ! "$a_norm" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || \
       [[ ! "$b_norm" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        return 1
    fi

    [[ "$a_norm" == "$b_norm" ]] && return 1

    local first
    first=$(printf '%s\n%s\n' "$a_norm" "$b_norm" | sort -V | head -1)
    [[ "$first" == "$a_norm" ]]
}

# Post-install symlink for curl-based tools installed as root (Issue #57)
# When curl installers drop binaries into /root/.local/bin/, this creates
# a symlink in /usr/local/bin/ so all users can access the tool.
# Issue #71 extension: after the global symlink is in place, propagate it
# into every user's ~/.local/bin so the tool is reachable for all users.
# Usage: _env_post_install_symlink <tool>
_env_post_install_symlink() {
    local tool="$1"

    # Only relevant when running as root
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 0

    # Map tool name to binary name
    local binary
    binary=$(_env_tool_to_binary "$tool") || return 0

    # Already in /usr/local/bin? Skip the search but still propagate to user homes.
    if [[ -e "/usr/local/bin/$binary" ]]; then
        utils_verbose "$binary already in /usr/local/bin — no symlink needed"
        _env_propagate_user_symlinks "$binary"
        return 0
    fi

    # Search for the binary
    local search_path
    for search_path in "/root/.local/bin/$binary" "${HOME}/.local/bin/$binary"; do
        if [[ -x "$search_path" ]]; then
            ln -sf "$search_path" "/usr/local/bin/$binary"
            utils_verbose "Created symlink /usr/local/bin/$binary -> $search_path"
            _env_propagate_user_symlinks "$binary"
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

        # Post-install hooks must run even on update-redirect (Issue #63)
        # Playwright browsers may be missing even when npm package exists
        if [[ "$tool" == "playwright" ]]; then
            _env_post_install_playwright
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

        # Post-install: install Playwright browser binaries (Issue #63)
        if [[ "$tool" == "playwright" ]]; then
            _env_post_install_playwright
        fi

        return $ENV_EXIT_SUCCESS
    else
        utils_error "Failed to install $display_name"
        return 1
    fi
}

# ============================================================================
# Issue #73 — env update upstream-installer diagnostics
# ============================================================================

# _env_diag_target_dir <tool>
# Echo the pre-flight target directory for a curl tool, or empty if unknown.
_env_diag_target_dir() {
    local tool="$1"
    echo "${_ENV_CURL_TARGET_DIR[$tool]:-}"
}

# _env_diag_preflight_curl <tool>
# Issue #73: writability + free-space pre-flight BEFORE invoking the upstream
# installer. Echoes failure message to stderr and returns 1 on block; returns 0
# if the install may proceed. Returns 0 unconditionally for tools without a
# registered target dir (safe default — never block on unknowns).
_env_diag_preflight_curl() {
    local tool="$1"
    local target
    target=$(_env_diag_target_dir "$tool")
    [[ -n "$target" ]] || return 0

    # Probe the closest existing ancestor of the target.
    local probe_dir="$target"
    while [[ -n "$probe_dir" && ! -d "$probe_dir" ]]; do
        probe_dir="$(dirname "$probe_dir")"
        [[ "$probe_dir" == "/" || "$probe_dir" == "." ]] && break
    done
    [[ -d "$probe_dir" ]] || probe_dir="/"

    # Writability gate: only block when the probe dir is a system path AND we
    # are non-root AND the dir isn't writable. Per-user paths under $HOME skip.
    case "$probe_dir" in
        /opt*|/usr*|/etc*|/var*|/srv*)
            if [[ ! -w "$probe_dir" ]] && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
                utils_error "Target $target is not writable by EUID=$EUID — needs sudo."
                echo "Remediation: sudo cac env update $tool" >&2
                return 1
            fi
            ;;
    esac

    # Free-space gate: < 50 MiB on the target's filesystem -> abort.
    local free_kib
    free_kib=$(df -Pk "$probe_dir" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$free_kib" && "$free_kib" =~ ^[0-9]+$ ]] && [[ "$free_kib" -lt 51200 ]]; then
        utils_error "Low disk space at $probe_dir: $((free_kib / 1024)) MiB free (need >= 50 MiB)."
        echo "Remediation: free disk space on the filesystem holding $probe_dir, then retry." >&2
        return 1
    fi

    return 0
}

# _env_diag_classify_failure <log_file> <stage> <exit_code>
# Issue #73: classify an installer failure based on WHICH stage failed.
#   stage="download" -> curl was the primary actor; classify by curl exit
#   stage="execute"  -> bash script ran and broke; check for *embedded* curl
#                       errors inside the upstream installer (the original #73
#                       repro: upstream's own 'curl: (23)' lives in the log).
# Always exits 0; emits exactly one line on stdout.
_env_diag_classify_failure() {
    local log_file="$1" stage="$2" rc="$3"
    local code=""
    if [[ -f "$log_file" ]]; then
        # Upstream installers that retry internally may emit multiple
        # 'curl: (NN)' lines; the last one is typically the proximate cause.
        code=$(grep -oE 'curl: \([0-9]+\)' "$log_file" 2>/dev/null \
               | tail -1 | grep -oE '[0-9]+' || true)
    fi

    if [[ "$stage" == "download" ]]; then
        # Curl is the primary actor: classify directly by curl exit code.
        case "$code" in
            6|7)  echo "network/DNS — cannot resolve or reach the upstream URL" ;;
            22)   echo "HTTP error from upstream — install URL returned non-2xx (auth or moved)" ;;
            23)   echo "write failure — local disk full or permission denied at install target" ;;
            28)   echo "timeout — upstream slow or unreachable" ;;
            35)   echo "TLS handshake failure — verify certificate / proxy / system clock" ;;
            52)   echo "empty reply from upstream" ;;
            56)   echo "network receive failure mid-transfer" ;;
            60)   echo "TLS certificate problem — check CA bundle / proxy MITM" ;;
            "")   echo "download failed (curl exit $rc); see log excerpt below" ;;
            *)    echo "download failed (curl exit $code); see log excerpt below" ;;
        esac
    else
        # stage == execute: bash script is the primary actor.
        # An embedded 'curl: (NN)' in the log means upstream's own curl failed.
        if [[ -n "$code" ]]; then
            case "$code" in
                23)    echo "installer script: write failure inside upstream installer (curl exit $code) — disk/perm at upstream's target" ;;
                6|7)   echo "installer script: network/DNS failure inside upstream (curl exit $code)" ;;
                22)    echo "installer script: HTTP error inside upstream (curl exit $code)" ;;
                28)    echo "installer script: timeout inside upstream (curl exit $code)" ;;
                35|60) echo "installer script: TLS failure inside upstream (curl exit $code)" ;;
                *)     echo "installer script: failed with embedded curl error (curl exit $code); see log excerpt below" ;;
            esac
        else
            # Pure-script error — never claim "curl exit".
            echo "installer script exited with status $rc (no curl error in log); see log excerpt below"
        fi
    fi
}

# _env_diag_print_log_tail <log_file>
# Print the last 40 lines of the captured installer log to stderr, framed by
# markers. Silent if the log is missing/empty.
_env_diag_print_log_tail() {
    local log_file="$1"
    [[ -s "$log_file" ]] || return 0
    {
        echo "--- upstream installer log (last 40 lines) ---"
        tail -n 40 "$log_file"
        echo "--- end log ---"
    } >&2
}

# _env_curl_update_with_capture <tool> <url> <display_name>
# Issue #73: download upstream installer to a tempfile, execute it, capture
# all output to a log tempfile, and on failure surface a stage-classified
# cause plus log tail. Returns:
#   0  installer ran cleanly (post-install verification still done by caller)
#   1  curl download failed OR installer exited non-zero
# Cleans up both tempfiles on every return path (no trap chaining).
#
# Caller contract: stash the cause one-liner into ENV_DIAG_CAUSE_FILE if set
# (used by env_update_all for the batch summary).
_env_curl_update_with_capture() {
    local tool="$1"
    local url="$2"
    local display_name="$3"

    local _installer _diag_log

    _installer=$(mktemp -t "cac-env-update-${tool}-installer-XXXXXX.sh") \
        || { utils_error "Failed to allocate temp file for installer"; return 1; }

    _diag_log=$(mktemp -t "cac-env-update-${tool}-XXXXXX.log") \
        || { rm -f "$_installer"; utils_error "Failed to allocate temp log"; return 1; }

    # ----- Stage 1: download -----
    # Capture curl's stderr (where 'curl: (NN)' lives) into the diag log.
    # Explicit exit-code check — no pipefail reliance.
    local _curl_rc=0
    if ! curl -fsSL "$url" -o "$_installer" 2>"$_diag_log"; then
        _curl_rc=$?
        local _cause
        _cause=$(_env_diag_classify_failure "$_diag_log" "download" "$_curl_rc")
        utils_error "Failed to update $display_name: $_cause"
        _env_diag_print_log_tail "$_diag_log"
        if [[ -n "${ENV_DIAG_CAUSE_FILE:-}" ]]; then
            printf '%s\n' "$_cause" > "$ENV_DIAG_CAUSE_FILE" 2>/dev/null || true
        fi
        rm -f "$_installer" "$_diag_log"
        return 1
    fi

    # ----- Stage 2: execute -----
    # Live output via tee; capture bash's exit via PIPESTATUS[0].
    # tee -a appends so stage-1 curl-stderr (already in log) is preserved.
    bash "$_installer" 2>&1 | tee -a "$_diag_log"
    local _bash_rc=${PIPESTATUS[0]}

    if [[ "$_bash_rc" -ne 0 ]]; then
        local _cause
        _cause=$(_env_diag_classify_failure "$_diag_log" "execute" "$_bash_rc")
        utils_error "Failed to update $display_name: $_cause"
        _env_diag_print_log_tail "$_diag_log"
        if [[ -n "${ENV_DIAG_CAUSE_FILE:-}" ]]; then
            printf '%s\n' "$_cause" > "$ENV_DIAG_CAUSE_FILE" 2>/dev/null || true
        fi
        rm -f "$_installer" "$_diag_log"
        return 1
    fi

    # Success path: clean up and return 0. Caller handles post-install verify.
    rm -f "$_installer" "$_diag_log"
    return 0
}

# Update a single tool
# Usage: env_update_tool <tool> <scope> [allow_user_override_global]
# The optional 3rd arg, when set to "1", bypasses the Issue #71 user-scope
# refusal (Issue #79). It is a FUNCTION PARAMETER on purpose: unlike an
# environment variable it cannot be forged by the caller's environment, so the
# bypass is strictly internal to env_update_with_escalation.
# Returns: 0 on success, 1 on failure
env_update_tool() {
    local tool="$1"
    local scope="${2:-user}"
    local allow_user_override_global="${3:-}"

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

            # Issue #71: Pre-existing global install + non-root user-scope update -> hard refuse
            # Extends Issue #29's exclusivity rule from install to update.
            #
            # Issue #79 override: env_update_with_escalation passes the 3rd arg
            # "1" ONLY after confirming, via PATH resolution, that the user
            # actually runs their own per-user copy (~/.local). Updating the copy
            # they execute is correct and needs no root, so the refusal is
            # bypassed for that narrow, verified case. The flag is a function
            # parameter (not an env var), so a caller cannot forge it via the
            # environment — every other path (incl. explicit `cac env update
            # --user`) passes no 3rd arg and still hits the Issue #71 refusal.
            if [[ "$scope" == "user" ]] && [[ "$EUID" -ne 0 ]] \
               && [[ "$allow_user_override_global" != "1" ]] \
               && _env_global_install_exists "$tool"; then
                utils_error "$display_name has a system-wide install. User-scope update is refused to prevent dual-install drift."
                echo "Remediation: run with sudo for a global update, or remove the global install first if you really want a per-user version." >&2
                return 1
            fi

            # Global scope requires root
            if [[ "$scope" == "global" || "$scope" == "all" ]]; then
                if [[ "$EUID" -ne 0 ]]; then
                    utils_error "Global update requires root. Run with sudo."
                    return 1
                fi
            fi

            # Issue #73: ordering is load-bearing.
            # 1. Issue #71 user-scope refusal already fired ABOVE this point.
            #    No mutating side effects, no tempfiles, no probes have run.
            # 2. Issue #73 pre-flight: writability + disk-space.
            if ! _env_diag_preflight_curl "$tool"; then
                return 1
            fi

            if ! env_check_curl; then
                return $ENV_EXIT_MISSING_DEP
            fi

            echo "Re-running installer from: $url"

            # 3+4+5. Download + execute via capture helper (mktemp, curl,
            # bash via PIPESTATUS). Stage-classified diagnostics on failure.
            if ! _env_curl_update_with_capture "$tool" "$url" "$display_name"; then
                exit_code=1
            fi

            # 6. Issue #71: Refresh bash hash so subsequent same-process probes
            # don't return a stale path (parity with env_install_tool).
            hash -r 2>/dev/null || true

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

    # Issue #71: Curl-path post-install verification.
    # Use a sanitised PATH so we don't probe via stale bash hash or shadowed dirs.
    if [[ "$install_type" == "curl" ]]; then
        if [[ $exit_code -ne 0 ]]; then
            # Issue #73: stage-classified message + log tail already emitted by
            # _env_curl_update_with_capture. Avoid double-printing the generic
            # "Failed to update" line here.
            return 1
        fi

        local check_path="/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin"
        local binary
        binary=$(_env_tool_to_binary "$tool" 2>/dev/null || true)

        # Binary must be reachable on a clean PATH after install.
        if [[ -n "$binary" ]]; then
            local resolved
            resolved=$(PATH="$check_path" command -v "$binary" 2>/dev/null || true)
            if [[ -z "$resolved" ]]; then
                utils_error "$display_name update reported success but binary '$binary' is not on PATH after install."
                echo "Old version: $old_version. Investigate the upstream installer." >&2
                return 1
            fi
        fi

        local new_version
        new_version=$(PATH="$check_path" env_get_version "$tool")

        # Regression detection: refuse to print SUCCESS on a downgrade.
        if [[ "$old_version" != "unknown" ]] && [[ "$new_version" != "unknown" ]] \
           && _env_version_lt "$new_version" "$old_version"; then
            utils_error "$display_name update produced a version regression: $old_version -> $new_version"
            echo "Refusing to report SUCCESS on a downgrade." >&2
            return 1
        fi

        if [[ "$old_version" != "$new_version" ]]; then
            utils_success "$display_name updated: $old_version -> $new_version"
        else
            echo "$display_name is already at latest version ($new_version)"
        fi
        return $ENV_EXIT_SUCCESS
    fi

    # npm path: behaviour unchanged from pre-#71 (Issue #71 scope: do not touch npm).
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

    # Issue #73: per-iteration cause stash for the batch summary one-liner.
    # mktemp may fail (e.g. read-only TMPDIR); fall back gracefully to no-cause.
    local _cause_file=""
    _cause_file=$(mktemp -t "cac-env-update-cause-XXXXXX") 2>/dev/null || _cause_file=""

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

        # Issue #73: clear stash file so a previous tool's cause doesn't leak.
        [[ -n "$_cause_file" ]] && : > "$_cause_file"

        if ENV_DIAG_CAUSE_FILE="$_cause_file" env_update_tool "$tool" "$scope"; then
            ((success++)) || true
        else
            ((failed++)) || true
            local display_name cause=""
            display_name=$(env_get_display_name "$tool")
            if [[ -n "$_cause_file" && -s "$_cause_file" ]]; then
                cause=$(head -1 "$_cause_file")
            fi
            if [[ -n "$cause" ]]; then
                failed_tools+=("$display_name ($cause)")
            else
                failed_tools+=("$display_name")
            fi
        fi
        echo ""
    done < <(env_get_all_tools)

    # Issue #73: explicit cleanup — no trap chaining.
    [[ -n "$_cause_file" ]] && rm -f "$_cause_file"

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
    local _timeout_cmd
    _timeout_cmd=$(platform_get_timeout_cmd 2>/dev/null) || _timeout_cmd=""
    if [[ -n "$_timeout_cmd" ]]; then
        latest=$("$_timeout_cmd" 10 npm view "$package" version 2>/dev/null) || latest=""
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
    # Ownership check is Linux/macOS only — not meaningful on Windows NTFS
    if platform_is_windows; then return 0; fi
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

    local _tc
    _tc=$(platform_get_timeout_cmd 2>/dev/null) || _tc=""
    local _run_cmd="${_tc:+$_tc 10 }$version_cmd"
    if ! eval "$_run_cmd" &>/dev/null; then
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

# Post-install hook for Playwright: install browser binaries (Issue #63)
# Runs 'playwright install --with-deps chromium' to install Chromium and its system deps.
# Augments PATH to find freshly installed playwright binary (npm global bin may not
# be on the current shell's PATH yet).
# Usage: _env_post_install_playwright
_env_post_install_playwright() {
    echo "Installing Playwright browser binaries (Chromium)..."

    # Augment PATH to find freshly installed playwright binary
    local pw_path="$PATH"
    [[ -d "$HOME/.local/bin" ]] && pw_path="$HOME/.local/bin:$pw_path"
    [[ -d "/usr/local/bin" ]] && pw_path="/usr/local/bin:$pw_path"
    local npm_global_bin
    npm_global_bin=$(npm bin -g 2>/dev/null) || true
    [[ -n "$npm_global_bin" && -d "$npm_global_bin" ]] && pw_path="$npm_global_bin:$pw_path"

    # Clear bash command cache so freshly installed binaries are found
    hash -r

    if PATH="$pw_path" playwright install --with-deps chromium; then
        utils_success "Playwright Chromium browser installed successfully"
    else
        utils_warn "Playwright browser install failed — you may need to run: sudo playwright install --with-deps chromium"
    fi
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
            log_warn "Install with: $(platform_install_hint tmux)"
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
    # Issue #79: distinguish an explicitly requested scope (--user/--global/--all)
    # from the defaulted "user" scope. Auto-escalation only kicks in for the
    # implicit default; an explicit --user must still hard-refuse (Issue #71).
    ENV_PARSED_SCOPE_EXPLICIT="false"
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
                ENV_PARSED_SCOPE_EXPLICIT="true"
                shift
                ;;
            --global)
                if [[ -n "$ENV_PARSED_SCOPE" ]]; then
                    utils_error "Only one scope flag allowed (--user, --global, --all)"
                    return 1
                fi
                ENV_PARSED_SCOPE="global"
                ENV_PARSED_SCOPE_EXPLICIT="true"
                shift
                ;;
            --all)
                if [[ -n "$ENV_PARSED_SCOPE" ]]; then
                    utils_error "Only one scope flag allowed (--user, --global, --all)"
                    return 1
                fi
                ENV_PARSED_SCOPE="all"
                ENV_PARSED_SCOPE_EXPLICIT="true"
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

# Issue #79: implicit-scope, non-root update path. Updates user-scope (and npm)
# tools in-process and auto-escalates system-wide curl tools via a single sudo
# re-exec, instead of reporting them as hard failures. Returns the tri-state
# 0/1/2 (SUCCESS/PARTIAL/ALL_FAILED) per the env_cmd_update contract.
# Usage: env_update_with_escalation
env_update_with_escalation() {
    # Build the target set: an explicit tool list, or every installed tool.
    local -a targets=()
    if [[ ${#ENV_PARSED_TOOLS[@]} -gt 0 ]]; then
        targets=("${ENV_PARSED_TOOLS[@]}")
    else
        local _t
        while IFS= read -r _t; do
            env_is_installed "$_t" && targets+=("$_t")
        done < <(env_get_all_tools)
    fi

    # Empty target set (e.g. no tools installed) is not a failure — mirror the
    # existing env_update_all "nothing failed" contract (Codex required change).
    if [[ ${#targets[@]} -eq 0 ]]; then
        echo "No installed AI tools to update."
        return $ENV_EXIT_SUCCESS
    fi

    local -a local_tools=() global_tools=() bad_tools=()
    local t
    for t in "${targets[@]}"; do
        # Arg safety (Codex): validate + installed BEFORE classification/escalation
        # so nothing untrusted is ever forwarded into a root command.
        if ! env_validate_tool "$t"; then
            utils_error "Unknown tool: $t"
            bad_tools+=("$t")
            continue
        fi
        if ! env_is_installed "$t"; then
            utils_warn "$(env_get_display_name "$t") is not installed. Use 'cac env install $t' first."
            bad_tools+=("$t")
            continue
        fi

        # Only curl-installed tools carry the Issue #71 global refusal; npm tools
        # update fine at user scope and are never escalated — no behavior change.
        if [[ "$(env_get_install_type "$t")" != "curl" ]]; then
            local_tools+=("$t")
            continue
        fi

        # Curl tool: follow what the user actually runs (PATH resolution).
        #   local    -> their own per-user copy (or no global) -> user-scope update
        #   escalate -> they run the system-wide copy -> sudo re-exec
        case "$(_env_update_action "$t")" in
            escalate) global_tools+=("$t") ;;
            *)        local_tools+=("$t") ;;
        esac
    done

    local success=0 failed=0 needs_root=0
    local -a failed_names=() needs_root_names=()

    # 1. Local updates, in-process at user scope. The 3rd arg ("1") tells
    # env_update_tool to bypass the Issue #71 refusal ONLY here, where we have
    # already confirmed (via _env_update_action) that the user runs their own
    # per-user copy — so updating it without root is correct, not drift.
    #
    # Codex hardening: passing this as a positional PARAMETER (not an env/shell
    # variable) makes the override unforgeable from the caller's environment and
    # impossible to leak into the curl-installer subprocess.
    for t in "${local_tools[@]+"${local_tools[@]}"}"; do
        if env_update_tool "$t" "user" "1"; then
            ((success++)) || true
        else
            ((failed++)) || true
            failed_names+=("$(env_get_display_name "$t")")
        fi
        echo ""
    done

    # 2. Global curl tools the user actually runs: escalate PER TOOL so each
    # outcome is unambiguous (Codex fix: a single batch child returning PARTIAL
    # could not be attributed correctly). sudo caches credentials, so the user
    # still sees at most one password prompt for the whole batch.
    for t in "${global_tools[@]+"${global_tools[@]}"}"; do
        local rc=0
        _env_reexec_sudo_update "$t" || rc=$?
        case "$rc" in
            0)
                ((success++)) || true
                ;;
            "$ENV_EXIT_NEEDS_ROOT")
                ((needs_root++)) || true
                needs_root_names+=("$(env_get_display_name "$t")")
                ;;
            *)
                ((failed++)) || true
                failed_names+=("$(env_get_display_name "$t")")
                ;;
        esac
        echo ""
    done

    # Invalid / not-installed requested tools count as failures.
    if [[ ${#bad_tools[@]} -gt 0 ]]; then
        ((failed += ${#bad_tools[@]})) || true
        for t in "${bad_tools[@]}"; do failed_names+=("$t"); done
    fi

    echo "=== Update Summary ==="
    echo "Updated: $success"
    echo "Failed: $failed"
    [[ ${#failed_names[@]} -gt 0 ]] && echo "Failed tools: ${failed_names[*]}"
    if [[ $needs_root -gt 0 ]]; then
        echo "Needs root: $needs_root"
        echo "Needs root tools: ${needs_root_names[*]}"
        echo "Hint: run 'sudo cac env update' to update system-wide tools."
    fi

    # Tri-state per the contract. "problems" spans failed + needs-root.
    # Distinguish "nothing was targetable" (handled above -> SUCCESS) from
    # "everything targetable failed" (-> ALL_FAILED).
    local problems=$((failed + needs_root))
    if [[ $problems -eq 0 ]]; then
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

    # Issue #79: implicit (default) scope + non-root + not already a re-exec'd
    # child -> auto-escalate system-wide tools. Explicit --user/--global/--all,
    # root callers, and re-exec'd children all fall through to the original
    # behavior, preserving the Issue #71 refusal for explicit --user.
    if [[ "$ENV_PARSED_SCOPE_EXPLICIT" != "true" ]] \
       && [[ "${EUID:-$(id -u)}" -ne 0 ]] \
       && [[ -z "${CAC_ENV_ESCALATED:-}" ]]; then
        env_update_with_escalation
        return $?
    fi

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

# ============================================================================
# Predefined Skills Installation
# ============================================================================

# Predefined Claude Code skills installed via 'npx skills add'
# Format: skills_id|display_name|description
# skills_id = owner/repo@skill as used by 'npx skills add'
if [[ ! -v _ENV_SKILLS_REGISTRY ]]; then
readonly -a _ENV_SKILLS_REGISTRY=(
    "aktsmm/agent-skills@skill-finder|Skill Finder|Discover and install agent skills"
    "askyourpdf/ai-pdf-filler@ai-pdf-filler-cli|PDF Filler|Fill, read, merge, split, and OCR PDF files"
    "willem4130/claude-code-skills@elite-powerpoint-designer|PowerPoint|Create and edit PowerPoint presentations"
    "aktsmm/agent-skills@powerpoint-automation|PowerPoint Auto|Automate PowerPoint slide creation"
    "dnvriend/pdf-to-pptx-tool@skill-pdf-to-pptx-tool|PDF-to-PPTX|Convert PDF files to PowerPoint"
    "promptadvisers/claude-code-polished-documents-skills@docx|DOCX|Create and edit Word documents"
    "promptadvisers/claude-code-polished-documents-skills@document-polisher|Doc Polisher|Polish and format documents"
)
fi

# Check if a skill is already installed
# Usage: _env_skill_is_installed <skills_id>
_env_skill_is_installed() {
    local skills_id="$1"
    local skill_name="${skills_id##*@}"
    [[ -d "${HOME}/.claude/skills/${skill_name}" ]] || \
    [[ -d "${HOME}/.claude/commands/${skill_name}" ]]
}

# Handle 'cac env skills' command
# Usage: env_cmd_skills "$@"
env_cmd_skills() {
    local yes_flag="false"
    local list_only="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) yes_flag="true"; shift ;;
            --list) list_only="true"; shift ;;
            --help|-h)
                echo "cac env skills - Install predefined Claude Code skills"
                echo ""
                echo "USAGE: cac env skills [--yes] [--list]"
                echo ""
                echo "OPTIONS:"
                echo "    --yes, -y   Skip confirmation prompt"
                echo "    --list      Show predefined skills without installing"
                echo ""
                echo "PREDEFINED SKILLS (via 'npx skills add'):"
                local entry
                for entry in "${_ENV_SKILLS_REGISTRY[@]}"; do
                    local pkg disp desc
                    IFS='|' read -r pkg disp desc <<< "$entry"
                    printf "    %-16s  %s\n" "$disp" "$desc"
                done
                return 0
                ;;
            *)
                utils_error "Unknown option: $1"
                echo "Run 'cac env skills --help' for usage." >&2
                return 1
                ;;
        esac
    done

    if ! command -v npx &>/dev/null; then
        utils_error "npx is not installed. Install Node.js first: cac env install claude"
        return $ENV_EXIT_MISSING_DEP
    fi

    echo "Predefined Claude Code skills:"
    echo ""

    local entry pkg disp desc
    for entry in "${_ENV_SKILLS_REGISTRY[@]}"; do
        IFS='|' read -r pkg disp desc <<< "$entry"
        local status="not installed"
        _env_skill_is_installed "$pkg" && status="installed"
        printf "  %-16s  %-45s  [%s]\n" "$disp" "$desc" "$status"
    done
    echo ""

    [[ "$list_only" == "true" ]] && return 0

    if [[ "$yes_flag" != "true" && -t 0 ]]; then
        read -r -p "Install missing skills? [y/N] " confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Skipped."; return 0; }
    fi

    echo ""
    local installed=0 skipped=0 failed=0

    for entry in "${_ENV_SKILLS_REGISTRY[@]}"; do
        IFS='|' read -r pkg disp desc <<< "$entry"
        if _env_skill_is_installed "$pkg"; then
            echo "  [skip] $disp — already installed"
            ((skipped++)) || true
        else
            echo "  Installing $disp ($pkg)..."
            if npx skills add "$pkg" -g -y 2>&1 | tail -3; then
                ((installed++)) || true
            else
                utils_error "  Failed to install $disp"
                ((failed++)) || true
            fi
        fi
    done

    echo ""
    echo "Skills: $installed installed, $skipped already present, $failed failed"
    [[ $failed -gt 0 ]] && return $ENV_EXIT_PARTIAL
    return $ENV_EXIT_SUCCESS
}
