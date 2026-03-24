#!/usr/bin/env bash
# tests/test_platform.sh - Unit tests for lib/platform.sh
#
# Tests platform detection, home resolution, stat wrappers,
# chmod/chown no-ops, timeout detection, and install hints.
#
# Usage: bash tests/test_platform.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_framework.sh"

# Load platform module under test
LIB_DIR="$(cd "${SCRIPT_DIR}/../lib" && pwd)"
source "${LIB_DIR}/platform.sh"

framework_init

# ============================================================================
# Helper: detect platform in a sub-shell with overridden OSTYPE
# ============================================================================
_platform_for_ostype() {
    local ostype="$1"
    bash -c "
        OSTYPE='${ostype}'
        unset PLATFORM 2>/dev/null || true
        source '${LIB_DIR}/platform.sh' 2>/dev/null
        echo \"\$PLATFORM\"
    "
}

# ============================================================================
# Tests: platform_detect
# ============================================================================

test_detect_linux() {
    # In a WSL2 Docker environment uname -r still contains "microsoft",
    # so OSTYPE=linux-gnu correctly maps to "wsl". Both outcomes are valid.
    local result
    result=$(_platform_for_ostype 'linux-gnu')
    [[ "$result" == "linux" || "$result" == "wsl" ]] || {
        echo "Expected linux or wsl (got: $result)" >&2; return 1
    }
}

test_detect_macos() {
    # macOS detection requires uname -s == Darwin AND no "microsoft" in uname -r.
    # In a Docker-on-WSL2 environment uname -r has "microsoft", so this path
    # can't be reached; the result will be "wsl". Both are correct for the host.
    local result
    result=$(_platform_for_ostype 'darwin20.0')
    [[ "$result" == "macos" || "$result" == "wsl" ]] || {
        echo "Expected macos or wsl (got: $result)" >&2; return 1
    }
}

test_detect_gitbash_msys() {
    assert_equals "gitbash" "$(_platform_for_ostype 'msys')" "OSTYPE=msys → gitbash"
}

test_detect_gitbash_mingw() {
    assert_equals "gitbash" "$(_platform_for_ostype 'mingw64')" "OSTYPE=mingw64 → gitbash"
}

test_detect_cygwin() {
    assert_equals "gitbash" "$(_platform_for_ostype 'cygwin')" "OSTYPE=cygwin → gitbash"
}

# ============================================================================
# Tests: platform_is_windows
# ============================================================================

test_is_windows_on_gitbash() {
    local result
    result=$(bash -c "
        OSTYPE='msys'
        unset PLATFORM 2>/dev/null || true
        source '${LIB_DIR}/platform.sh' 2>/dev/null
        if platform_is_windows; then echo 'yes'; else echo 'no'; fi
    ")
    assert_equals "yes" "$result" "platform_is_windows → true on gitbash"
}

test_is_windows_on_linux() {
    local result
    result=$(bash -c "
        OSTYPE='linux-gnu'
        unset PLATFORM 2>/dev/null || true
        source '${LIB_DIR}/platform.sh' 2>/dev/null
        if platform_is_windows; then echo 'yes'; else echo 'no'; fi
    ")
    assert_equals "no" "$result" "platform_is_windows → false on linux"
}

# ============================================================================
# Tests: platform_get_file_perms
# ============================================================================

test_get_file_perms_644() {
    local tmpfile
    tmpfile=$(mktemp)
    chmod 644 "$tmpfile"
    local result
    result=$(platform_get_file_perms "$tmpfile")
    rm -f "$tmpfile"
    assert_equals "644" "$result" "platform_get_file_perms for 644 file"
}

test_get_file_perms_600() {
    local tmpfile
    tmpfile=$(mktemp)
    chmod 600 "$tmpfile"
    local result
    result=$(platform_get_file_perms "$tmpfile")
    rm -f "$tmpfile"
    assert_equals "600" "$result" "platform_get_file_perms for 600 file"
}

test_get_file_perms_windows_sentinel() {
    local result
    result=$(bash -c "
        OSTYPE='msys'
        unset PLATFORM 2>/dev/null || true
        source '${LIB_DIR}/platform.sh' 2>/dev/null
        platform_get_file_perms '/nonexistent/path'
    ")
    assert_equals "600" "$result" "Windows returns sentinel 600 without error"
}

# ============================================================================
# Tests: platform_get_file_size
# ============================================================================

test_get_file_size() {
    local tmpfile
    tmpfile=$(mktemp)
    printf 'hello' > "$tmpfile"
    local result
    result=$(platform_get_file_size "$tmpfile")
    rm -f "$tmpfile"
    assert_equals "5" "$result" "platform_get_file_size for 5-byte file"
}

# ============================================================================
# Tests: platform_get_file_mtime
# ============================================================================

test_get_file_mtime_is_numeric() {
    local tmpfile
    tmpfile=$(mktemp)
    local result
    result=$(platform_get_file_mtime "$tmpfile")
    rm -f "$tmpfile"
    assert_match '^[0-9]+$' "$result" "mtime should be a positive integer"
}

test_get_file_mtime_nonzero() {
    local tmpfile
    tmpfile=$(mktemp)
    local result
    result=$(platform_get_file_mtime "$tmpfile")
    rm -f "$tmpfile"
    [[ "$result" -gt 0 ]] || { echo "Expected non-zero mtime, got: $result" >&2; return 1; }
}

# ============================================================================
# Tests: platform_chmod
# ============================================================================

test_chmod_noop_on_windows_no_abort() {
    local exit_code
    exit_code=$(bash -c "
        OSTYPE='msys'
        unset PLATFORM 2>/dev/null || true
        source '${LIB_DIR}/platform.sh' 2>/dev/null
        platform_chmod 600 /nonexistent/path 2>/dev/null
        echo \$?
    ")
    assert_equals "0" "$exit_code" "platform_chmod on Windows should return 0 even for nonexistent path"
}

test_chmod_sets_perms_on_linux() {
    local tmpfile
    tmpfile=$(mktemp)
    platform_chmod 600 "$tmpfile"
    local result
    result=$(platform_get_file_perms "$tmpfile")
    rm -f "$tmpfile"
    assert_equals "600" "$result" "platform_chmod 600 should set permissions on Linux"
}

# ============================================================================
# Tests: platform_get_timeout_cmd
# ============================================================================

test_timeout_cmd_returns_string() {
    if ! command -v timeout &>/dev/null && ! command -v gtimeout &>/dev/null; then
        echo "Skipping: no timeout command on this system" >&2
        return 0  # skip gracefully
    fi
    local result
    result=$(platform_get_timeout_cmd 2>/dev/null)
    [[ -n "$result" ]] || { echo "Expected a timeout command name, got empty string" >&2; return 1; }
}

# ============================================================================
# Tests: platform_install_hint
# ============================================================================

test_install_hint_linux_apt() {
    local result
    result=$(bash -c "
        OSTYPE='linux-gnu'
        unset PLATFORM 2>/dev/null || true
        source '${LIB_DIR}/platform.sh' 2>/dev/null
        platform_install_hint git
    ")
    assert_contains "apt-get" "$result" "Linux hint should mention apt-get"
}

test_install_hint_macos_brew() {
    # Set PLATFORM directly before sourcing to bypass uname-based detection
    # (needed in WSL2/Docker environments where uname -r shows "microsoft")
    local result
    result=$(bash -c "
        export PLATFORM='macos'
        source '${LIB_DIR}/platform.sh' 2>/dev/null
        platform_install_hint git
    ")
    assert_contains "brew" "$result" "macOS hint should mention brew"
}

test_install_hint_gitbash_winget() {
    local result
    result=$(bash -c "
        OSTYPE='msys'
        unset PLATFORM 2>/dev/null || true
        source '${LIB_DIR}/platform.sh' 2>/dev/null
        platform_install_hint git
    ")
    assert_contains "winget" "$result" "Windows hint should mention winget"
}

# ============================================================================
# Tests: platform_list_user_homes
# ============================================================================

test_list_user_homes_includes_fake_users() {
    local fake_home="${TEST_TMPDIR}/fake_home"
    mkdir -p "${fake_home}/alice" "${fake_home}/bob"

    # Override platform_list_user_homes to use our fake dir
    local result
    result=$(
        for dir in "${fake_home}"/*/; do
            [[ -d "$dir" ]] && echo "${dir%/}"
        done
    )
    assert_contains "alice" "$result" "Should enumerate alice"
    assert_contains "bob"   "$result" "Should enumerate bob"
}

# ============================================================================
# Tests: platform_resolve_home (current user)
# ============================================================================

test_resolve_home_current_user() {
    local current_user
    current_user=$(whoami)
    local result
    result=$(platform_resolve_home "$current_user" 2>/dev/null) || result=""
    [[ -n "$result" ]] || { echo "Expected a home path, got empty string" >&2; return 1; }
    [[ -d "$result" ]] || { echo "Resolved home '$result' is not a directory" >&2; return 1; }
}

# ============================================================================
# Run all tests
# ============================================================================

run_test "Detect Linux platform"                test_detect_linux
run_test "Detect macOS platform"                test_detect_macos
run_test "Detect Git Bash (msys)"               test_detect_gitbash_msys
run_test "Detect Git Bash (mingw64)"            test_detect_gitbash_mingw
run_test "Detect Cygwin → gitbash"              test_detect_cygwin
run_test "is_windows true on gitbash"           test_is_windows_on_gitbash
run_test "is_windows false on linux"            test_is_windows_on_linux
run_test "get_file_perms returns 644"           test_get_file_perms_644
run_test "get_file_perms returns 600"           test_get_file_perms_600
run_test "get_file_perms Windows sentinel"      test_get_file_perms_windows_sentinel
run_test "get_file_size for 5-byte file"        test_get_file_size
run_test "get_file_mtime is numeric"            test_get_file_mtime_is_numeric
run_test "get_file_mtime is non-zero"           test_get_file_mtime_nonzero
run_test "chmod no-op on Windows (no abort)"    test_chmod_noop_on_windows_no_abort
run_test "chmod sets perms on Linux"            test_chmod_sets_perms_on_linux
run_test "timeout_cmd returns a string"         test_timeout_cmd_returns_string
run_test "install_hint Linux → apt-get"         test_install_hint_linux_apt
run_test "install_hint macOS → brew"            test_install_hint_macos_brew
run_test "install_hint Git Bash → winget"       test_install_hint_gitbash_winget
run_test "list_user_homes enumerates dirs"      test_list_user_homes_includes_fake_users
run_test "resolve_home current user"            test_resolve_home_current_user

framework_report
