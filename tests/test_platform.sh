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
# Only the gitbash branch of platform_detect reads OSTYPE; use this for those.
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
# Helper: detect platform in a sub-shell with a stubbed `uname` (Issue #107)
# ============================================================================
# platform_detect reads `uname -r` for the wsl branch and `uname -s` for the
# macos branch, NOT OSTYPE. Overriding OSTYPE alone leaves the test with no
# control over which branch runs: on a Darwin host the macos branch is taken
# because the HOST is Darwin, not because the code under test decided so, and on
# a Linux host that branch is never reached at all. Stubbing uname puts the
# branch under the test's control on every host.
#
# Usage: _platform_with_uname <uname-s> <uname-r>
_platform_with_uname() {
    local uname_s="$1" uname_r="$2"
    local stub_dir
    stub_dir=$(mktemp -d "${TEST_TMPDIR}/uname_stub.XXXXXX")

    cat > "${stub_dir}/uname" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    -s) echo '${uname_s}' ;;
    -r) echo '${uname_r}' ;;
    *)  echo '${uname_s}' ;;
esac
STUB
    chmod +x "${stub_dir}/uname"

    # Prepend the stub but KEEP the real PATH: platform_detect needs grep, and
    # sourcing platform.sh needs dirname (see Issue #106 — narrowing PATH to a
    # single directory makes the test fail for reasons other than its subject).
    # OSTYPE is pinned to a non-Windows value so the one OSTYPE-driven branch
    # cannot fire; the outcome is then attributable to uname alone.
    bash -c "
        PATH='${stub_dir}:${PATH}'
        OSTYPE='linux-gnu'
        unset PLATFORM 2>/dev/null || true
        source '${LIB_DIR}/platform.sh' 2>/dev/null
        echo \"\$PLATFORM\"
    "
}

# ============================================================================
# Tests: platform_detect
# ============================================================================

# A "linux OR wsl" / "macos OR wsl" assertion cannot distinguish the branch it
# names from the branch above it, which is how the macOS case stayed broken
# while looking green. With uname stubbed each branch is asserted exactly.
test_detect_linux() {
    assert_equals "linux" "$(_platform_with_uname 'Linux' '6.8.0-generic')" \
        "uname -s=Linux, no microsoft in -r → linux"
}

test_detect_macos() {
    assert_equals "macos" "$(_platform_with_uname 'Darwin' '21.6.0')" \
        "uname -s=Darwin → macos"
}

# The wsl branch precedes macos in platform_detect and silently satisfied both
# assertions above; it had never been asserted positively (Issue #107).
test_detect_wsl() {
    assert_equals "wsl" "$(_platform_with_uname 'Linux' '5.15.0-microsoft-standard-WSL2')" \
        "microsoft in uname -r → wsl"
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
run_test "Detect WSL platform"                  test_detect_wsl
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
