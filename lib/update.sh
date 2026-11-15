#!/usr/bin/env bash
# lib/update.sh - Self-update logic for cac CLI
#
# Provides functions to detect installation scope, check for updates,
# and re-run install.sh with the correct scope flags.
#
# Dependencies: logging.sh, security.sh (sourced via dependency chain)

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/security.sh"

# GitHub raw URL base for fetching remote files
UPDATE_GITHUB_RAW_BASE="${UPDATE_GITHUB_RAW_BASE:-https://raw.githubusercontent.com/BPMspaceUG/bpm-CodingAgentConfigCopy/main}"

# ============================================================================
# Scope Detection
# ============================================================================

# Detect the installation scope of the currently running cac binary.
# Returns "global" if installed in /usr/local/bin/, "user" if in ~/.local/bin/.
# Usage: update_detect_scope
# Returns: scope string on stdout ("global" or "user"), 1 if cannot determine
update_detect_scope() {
    local cac_path

    # Try to find the cac binary path
    if cac_path=$(command -v cac 2>/dev/null); then
        # Resolve symlinks to get the real path
        if command -v realpath &>/dev/null; then
            cac_path=$(realpath "$cac_path" 2>/dev/null) || true
        fi
    fi

    # Fallback: check common locations directly
    if [[ -z "${cac_path:-}" ]]; then
        if [[ -x "/usr/local/bin/cac" ]]; then
            cac_path="/usr/local/bin/cac"
        elif [[ -x "${HOME}/.local/bin/cac" ]]; then
            cac_path="${HOME}/.local/bin/cac"
        fi
    fi

    if [[ -z "${cac_path:-}" ]]; then
        utils_error "Cannot find cac binary in PATH or standard locations"
        return 1
    fi

    if [[ "$cac_path" == /usr/local/bin/* ]]; then
        echo "global"
        return 0
    fi

    if [[ "$cac_path" == */.local/bin/* ]]; then
        echo "user"
        return 0
    fi

    utils_error "Cannot determine installation scope from path: $cac_path"
    return 1
}

# ============================================================================
# Version Extraction
# ============================================================================

# Extract version from a cac binary file by parsing the VERSION= line.
# Usage: _update_extract_version <file_content_or_path>
# Internal helper — operates on file content passed via stdin or a file path.
_update_extract_version_from_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    local version_line
    version_line=$(grep -m1 '^VERSION=' "$file" 2>/dev/null) || return 1

    # Strip VERSION= prefix and quotes
    local version="${version_line#VERSION=}"
    version="${version//\"/}"
    version="${version//\'/}"

    if [[ -z "$version" ]]; then
        return 1
    fi

    echo "$version"
}

# Strip -dirty or -draft suffix from version for comparison.
# Usage: _update_strip_suffix "260225-1542-dirty" → "260225-1542"
_update_strip_suffix() {
    local version="$1"
    version="${version%-dirty}"
    version="${version%-draft}"
    echo "$version"
}

# Normalize a version string for comparison:
#   1. Strip -dirty / -draft suffixes
#   2. Truncate to YYMMDD-HHMM (11 chars) to handle old HHMMSS installs
#   3. Pass through "dev" unchanged
# Usage: _update_normalize_version "260225-154233" → "260225-1542"
_update_normalize_version() {
    local version="$1"

    # "dev" is a special sentinel — pass through unchanged
    if [[ "$version" == "dev" ]]; then
        echo "dev"
        return 0
    fi

    # Strip suffixes first
    version=$(_update_strip_suffix "$version")

    # Truncate to 11 chars (YYMMDD-HHMM) to normalize HHMMSS → HHMM
    if [[ ${#version} -gt 11 ]]; then
        version="${version:0:11}"
    fi

    echo "$version"
}

# Check if local version is >= remote version (lexicographic comparison).
# YYMMDD-HHMM format sorts correctly with string comparison.
# Special cases:
#   - "dev" local is never >= a real version (always needs update)
#   - any real version is >= "dev" remote (never downgrade to dev)
# Usage: _update_version_ge "260301-1500" "260225-1542" → returns 0 (true)
# Returns: 0 if local >= remote, 1 otherwise
_update_version_ge() {
    local local_ver="$1"
    local remote_ver="$2"

    # dev local is never >= a real version
    if [[ "$local_ver" == "dev" && "$remote_ver" != "dev" ]]; then
        return 1
    fi

    # Any real version is >= dev remote
    if [[ "$local_ver" != "dev" && "$remote_ver" == "dev" ]]; then
        return 0
    fi

    # Both dev — equal
    if [[ "$local_ver" == "dev" && "$remote_ver" == "dev" ]]; then
        return 0
    fi

    # Lexicographic comparison (works for YYMMDD-HHMM)
    [[ ! "$local_ver" < "$remote_ver" ]]
}

# Path of the installed cac binary: the one on PATH, else a standard location.
# Usage: _update_local_cac_path
# Returns: path on stdout, 1 if none is found
_update_local_cac_path() {
    local cac_path
    cac_path=$(command -v cac 2>/dev/null) || true
    if [[ -z "${cac_path:-}" ]]; then
        if [[ -x "/usr/local/bin/cac" ]]; then
            cac_path="/usr/local/bin/cac"
        elif [[ -x "${HOME}/.local/bin/cac" ]]; then
            cac_path="${HOME}/.local/bin/cac"
        fi
    fi
    [[ -n "${cac_path:-}" ]] || return 1
    echo "$cac_path"
}

# Get the version of the locally installed cac binary.
# Usage: update_get_local_version
# Returns: version string on stdout, 1 on failure
update_get_local_version() {
    local cac_path

    if ! cac_path=$(_update_local_cac_path); then
        utils_error "Cannot find local cac binary"
        return 1
    fi

    local version
    if ! version=$(_update_extract_version_from_file "$cac_path"); then
        utils_error "Cannot extract version from $cac_path"
        return 1
    fi

    echo "$version"
}

# _update_github_api_get <url> <max_time>
# Issue #131: GET a GitHub API URL, authenticated when a token is available.
#
# Unauthenticated calls share GitHub's 60 req/h per-IP quota; a token lifts it
# to 5,000 req/h. Token source, first hit wins: GH_TOKEN, GITHUB_TOKEN,
# `gh auth token`. The token is sent ONLY to https://api.github.com/ — an
# overridden base URL (UPDATE_GITHUB_API_BASE, used by tests and mirrors) on any
# other host never receives it. It reaches curl through `-H @<(printf …)`, so
# it is neither written to disk nor visible on any argv (ps).
#
# install.sh carries a copy (_install_github_api_get): it runs standalone and
# cannot source lib/. Keep the two in step.
#
# Prints the response body on stdout. Returns 0 on success, 2 when rate-limited
# (message with the reset time already on stderr), 1 on any other failure.
_update_github_api_get() {
    local url="$1" max_time="$2"
    local token="" hdr rc=0 body status remaining reset

    if [[ "$url" == https://api.github.com/* ]]; then
        token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
        if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
            token=$(gh auth token 2>/dev/null) || token=""
        fi
    fi

    # Only the response headers touch the disk; the token never does.
    hdr=$(umask 077; mktemp) || return 1
    if [[ -n "$token" ]]; then
        # Process substitution: curl reads the header from a pipe, printf is a
        # builtin, so the token is neither on disk nor on any argv.
        body=$(curl -sSL --max-time "$max_time" -D "$hdr" \
            -H @<(printf 'Authorization: Bearer %s\n' "$token") "$url" 2>/dev/null) || rc=$?
    else
        body=$(curl -sSL --max-time "$max_time" -D "$hdr" "$url" 2>/dev/null) || rc=$?
    fi

    # One pass over the headers. Last status line wins (-L may follow
    # redirects); no headers at all (a file:// URL in tests) counts as success
    # when curl itself succeeded.
    read -r status remaining reset < <(tr -d '\r' < "$hdr" 2>/dev/null | awk -F': *' '
        /^HTTP\//                              { split($0, a, " "); s = a[2] }
        tolower($1) == "x-ratelimit-remaining" { r = $2 }
        tolower($1) == "x-ratelimit-reset"     { t = $2 }
        END { print (s == "" ? "-" : s), (r == "" ? "-" : r), (t == "" ? "-" : t) }')
    rm -f "$hdr"

    if [[ $rc -eq 0 ]] && [[ "$status" == "-" || "$status" == 2* ]]; then
        printf '%s\n' "$body"
        return 0
    fi

    if [[ "$status" == "403" || "$status" == "429" ]] && [[ "$remaining" == "0" ]]; then
        local when="unknown" remedy
        if [[ "$reset" =~ ^[0-9]+$ ]]; then
            when=$(date -d "@$reset" '+%H:%M %Z' 2>/dev/null || date -r "$reset" '+%H:%M %Z' 2>/dev/null || echo "epoch $reset")
        fi
        if [[ -n "$token" ]]; then
            remedy="The token in use has hit its limit too; wait for the reset."
        else
            remedy="Set GH_TOKEN or log in with 'gh auth login' to lift the limit (60 -> 5,000 requests per hour)."
        fi
        utils_error "GitHub API rate limit reached (resets at $when). $remedy"
        return 2
    fi
    return 1
}

# Fetch the version of the latest cac from GitHub using the commit date.
# Uses the GitHub API to get the latest commit on main and extracts the
# committer date, formatting it as YYMMDD-HHMM to match stamp_version().
# Usage: update_get_remote_version
# Returns: version string on stdout, 1 on failure
update_get_remote_version() {
    local api_url="${UPDATE_GITHUB_API_BASE:-https://api.github.com/repos/BPMspaceUG/bpm-CodingAgentConfigCopy}/commits/main"
    local response rc=0

    response=$(_update_github_api_get "$api_url" 15) || rc=$?
    if [[ $rc -eq 2 ]]; then
        return 1                      # rate-limit message already printed
    elif [[ $rc -ne 0 ]]; then
        utils_error "Failed to fetch remote version from GitHub API"
        return 1
    fi

    # Extract committer date from JSON response.
    # The GitHub commits API returns "commit.committer.date" in ISO 8601 format:
    #   "date": "2026-02-25T15:42:33Z"
    # We grab the last "date" field (committer date, after author date).
    local commit_date
    commit_date=$(echo "$response" | grep '"date"' | tail -1 | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}' | head -1) || {
        utils_error "Cannot parse commit date from GitHub API response"
        return 1
    }

    # Convert 2026-02-25T15:42 to 260225-1542
    local version
    version=$(echo "$commit_date" | sed 's/^20\([0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\)T\([0-9][0-9]\):\([0-9][0-9]\)/\1\2\3-\4\5/')

    if [[ -z "$version" || "$version" == "$commit_date" ]]; then
        utils_error "Failed to format remote version from commit date"
        return 1
    fi

    echo "$version"
}

# ============================================================================
# Update Check
# ============================================================================

# Check if an update is available without installing.
# Strips -dirty/-draft suffixes before comparing so that a local
# "260225-1542-dirty" matches a remote "260225-1542" as up-to-date.
# Usage: update_check
# Returns: 0 if update available, 1 if already up to date, 2 on error
update_check() {
    local local_version remote_version

    if ! local_version=$(update_get_local_version); then
        return 2
    fi

    if ! remote_version=$(update_get_remote_version); then
        return 2
    fi

    local local_clean remote_clean
    local_clean=$(_update_normalize_version "$local_version")
    remote_clean=$(_update_normalize_version "$remote_version")

    echo "Installed version: $local_version"
    echo "Available version: $remote_version"

    if _update_version_ge "$local_clean" "$remote_clean"; then
        echo ""
        echo "Already up to date."
        return 1
    fi

    echo ""
    echo "Update available: $local_version -> $remote_version"
    return 0
}

# ============================================================================
# Self-Update
# ============================================================================

# Download install.sh and re-run it with the correct scope.
# Usage: update_self
# Returns: 0 on success, 1 on error
update_self() {
    local scope

    if ! scope=$(update_detect_scope); then
        return 1
    fi

    utils_verbose "Detected installation scope: $scope"

    # System-wide update requires root
    if [[ "$scope" == "global" && "${EUID:-$(id -u)}" -ne 0 ]]; then
        utils_error "Root privileges required for system-wide update"
        echo "Run with: sudo cac update" >&2
        return 1
    fi

    # Get current version
    local old_version
    if ! old_version=$(update_get_local_version); then
        return 1
    fi

    # Get remote version and check if update is needed
    local remote_version
    if ! remote_version=$(update_get_remote_version); then
        return 1
    fi

    local old_clean remote_clean
    old_clean=$(_update_normalize_version "$old_version")
    remote_clean=$(_update_normalize_version "$remote_version")

    if _update_version_ge "$old_clean" "$remote_clean"; then
        echo "Already up to date (version: $old_version)."
        _update_print_env_hints
        _update_print_tool_report
        return 0
    fi

    echo "Updating cac: $old_version -> $remote_version"
    echo "Installation scope: $scope"
    echo ""

    # Create secure temp dir for install.sh download
    local temp_dir=""
    temp_dir=$(security_mktemp_dir "cac-update")
    trap '[[ -n "${temp_dir:-}" ]] && rm -rf "$temp_dir"' RETURN

    local install_script="${temp_dir}/install.sh"
    local install_url="${UPDATE_GITHUB_RAW_BASE}/install.sh"

    utils_verbose "Downloading install.sh from $install_url"

    if ! curl -fsSL --max-time 30 -o "$install_script" "$install_url"; then
        utils_error "Failed to download install.sh"
        return 1
    fi

    # Run install.sh with the correct scope flag (non-interactive pipe mode)
    utils_verbose "Running: bash $install_script --$scope"

    if ! bash "$install_script" "--${scope}"; then
        utils_error "install.sh failed"
        return 1
    fi

    # Get the new version after update
    local new_version
    new_version=$(update_get_local_version 2>/dev/null) || new_version="unknown"

    echo ""
    echo "Update complete: $old_version -> $new_version"

    # install.sh already printed the env hint lines in its usage summary.
    _update_print_tool_report
    return 0
}

# Issue #132: the two hint lines after `cac update`. install.sh's
# print_usage_summary carries the same two lines (it cannot source lib/);
# tests/test_issue_132.sh keeps the copies identical.
_update_print_env_hints() {
    echo ""
    echo "  cac env update    - Update all installed AI tools (sudo for global installs)"
    echo "  cac env status --check-updates - Show which AI tools have updates"
}

# Issue #132: print `cac env status --check-updates` from the installed cac.
# After a real update this process still runs the old libraries, so the report
# always comes from the installed binary (the same one when up to date). It
# runs in its own process so a hung version lookup is cut off after
# UPDATE_REPORT_TIMEOUT seconds (default 60). Informational only: a failing,
# empty or timed-out report never changes the exit code of `cac update`.
_update_print_tool_report() {
    local cac_bin
    cac_bin=$(_update_local_cac_path) || return 0
    echo ""
    if command -v timeout >/dev/null 2>&1; then
        timeout "${UPDATE_REPORT_TIMEOUT:-60}" "$cac_bin" env status --check-updates || true
    else
        "$cac_bin" env status --check-updates || true
    fi
}

# ============================================================================
# Command Entry Point
# ============================================================================

# Main entry point for the update command, called from bin/cac.
# Usage: update_cmd_main [--check]
update_cmd_main() {
    local check_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)
                check_only=true
                shift
                ;;
            --help|-h)
                cat <<EOF
cac update - Self-update the cac CLI

USAGE:
    cac update [--check]

OPTIONS:
    --check     Show available version without installing

DESCRIPTION:
    Downloads the latest install.sh from GitHub and re-runs it
    with the same scope (--user or --global) as the current install.

    System-wide updates require root privileges.

EXAMPLES:
    cac update              Update cac to the latest version
    cac update --check      Check if an update is available
    sudo cac update         Update system-wide installation

EOF
                return 0
                ;;
            *)
                utils_error "Unknown option: $1"
                echo "Run 'cac update --help' for usage information." >&2
                return 1
                ;;
        esac
    done

    if $check_only; then
        update_check
        # update_check returns 1 for "up to date" which is not an error
        local rc=$?
        if [[ $rc -eq 2 ]]; then
            return 1
        fi
        return 0
    fi

    update_self
}
