#!/usr/bin/env bash
# tests/test_issue_80.sh - Tests for Issue #80 (OpenCode as a fifth managed tool)
#
# Scope covered here: registry registration + `cac check opencode`.
# `cac env install/update opencode` is NOT covered — still open on #80.
#
# Regression guarded:
#  - opencode was present in _TOOLS_REGISTRY but absent from every case block in
#    check.sh. _check_get_primary_cred_file returned "", so check_single_tool hit
#    `[[ ! -f "" ]]` and silently reported "no credentials found ()" — the tool was
#    never actually checked.
#  - check_single_tool's dispatch case had no default branch. Any tool that passes
#    tools_is_valid but has no probe (opencode, and the literal "all") left
#    exit_code unset, so `return $exit_code` aborted with
#    "return: : numeric argument required".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"
# shellcheck source=lib/tools.sh
source "$REPO_DIR/lib/tools.sh"
# shellcheck source=lib/check.sh
source "$REPO_DIR/lib/check.sh"

framework_init

# ============================================================================
# Helpers
# ============================================================================

# Create a mock `opencode` binary on PATH.
make_opencode_stub() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/opencode" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "0.4.2"; exit 0; }
exit 0
STUB
    chmod +x "$bindir/opencode"
}

# Build a fake home with an opencode auth.json holding <content>.
make_fake_home() {
    local home_dir="$1" content="$2"
    mkdir -p "$home_dir/.local/share/opencode"
    printf '%s' "$content" > "$home_dir/.local/share/opencode/auth.json"
}

# ============================================================================
# 80.1 — registry registration
# ============================================================================

test_opencode_in_supported_tools() {
    local found=1
    for t in "${SUPPORTED_TOOLS[@]}"; do
        [[ "$t" == "opencode" ]] && found=0
    done
    assert_equals 0 "$found" "opencode must be in SUPPORTED_TOOLS"
}

test_opencode_is_valid_tool() {
    tools_is_valid "opencode"
}

test_opencode_files_are_registered() {
    local files
    files=$(tools_get_files "opencode")
    assert_contains ".local/share/opencode/auth.json" "$files" \
        "opencode auth.json must be bundled" || return 1
    assert_contains ".config/opencode/opencode.json" "$files" \
        "opencode.json must be bundled"
}

# ============================================================================
# 80.2 — check.sh knows opencode (the actual regression)
# ============================================================================

test_primary_cred_file_resolves() {
    local got
    got=$(_check_get_primary_cred_file "opencode" "/fake/home")
    assert_equals "/fake/home/.local/share/opencode/auth.json" "$got" \
        "opencode cred file path"
}

test_display_name_resolves() {
    local got
    got=$(_check_get_tool_display_name "opencode")
    assert_equals "OpenCode" "$got" "opencode display name"
}

# ============================================================================
# 80.3 — check_tool_opencode exit codes (EXACT, per Codex gate on #82)
# ============================================================================

test_missing_binary_returns_missing_dep() {
    local tmp home_dir exit_code
    tmp=$(mktemp -d); home_dir="$tmp/home"
    make_fake_home "$home_dir" '{"anthropic":{"type":"api"}}'

    # Empty PATH -> no opencode binary
    ( PATH="/nonexistent"; check_tool_opencode "false" "$USER" "$home_dir" ) \
        && exit_code=0 || exit_code=$?
    rm -rf "$tmp"

    assert_equals "$CHECK_EXIT_MISSING_DEP" "$exit_code" "missing binary exit code"
}

test_valid_auth_returns_success() {
    local tmp home_dir bindir exit_code
    tmp=$(mktemp -d); home_dir="$tmp/home"; bindir="$tmp/bin"
    make_fake_home "$home_dir" '{"openrouter":{"type":"api","key":"sk-or-xxx"}}'
    make_opencode_stub "$bindir"

    ( PATH="$bindir:$PATH"; check_tool_opencode "false" "$USER" "$home_dir" ) \
        && exit_code=0 || exit_code=$?
    rm -rf "$tmp"

    assert_equals "$CHECK_EXIT_SUCCESS" "$exit_code" "valid auth.json exit code"
}

test_empty_auth_returns_auth_fail() {
    local tmp home_dir bindir exit_code
    tmp=$(mktemp -d); home_dir="$tmp/home"; bindir="$tmp/bin"
    make_fake_home "$home_dir" ''
    make_opencode_stub "$bindir"

    ( PATH="$bindir:$PATH"; check_tool_opencode "false" "$USER" "$home_dir" ) \
        && exit_code=0 || exit_code=$?
    rm -rf "$tmp"

    assert_equals "$CHECK_EXIT_AUTH_FAIL" "$exit_code" "empty auth.json exit code"
}

test_providerless_auth_returns_auth_fail() {
    local tmp home_dir bindir exit_code
    tmp=$(mktemp -d); home_dir="$tmp/home"; bindir="$tmp/bin"
    make_fake_home "$home_dir" '{}'
    make_opencode_stub "$bindir"

    ( PATH="$bindir:$PATH"; check_tool_opencode "false" "$USER" "$home_dir" ) \
        && exit_code=0 || exit_code=$?
    rm -rf "$tmp"

    assert_equals "$CHECK_EXIT_AUTH_FAIL" "$exit_code" "empty JSON object exit code"
}

test_non_json_auth_returns_auth_fail() {
    local tmp home_dir bindir exit_code
    tmp=$(mktemp -d); home_dir="$tmp/home"; bindir="$tmp/bin"
    make_fake_home "$home_dir" 'not json at all'
    make_opencode_stub "$bindir"

    ( PATH="$bindir:$PATH"; check_tool_opencode "false" "$USER" "$home_dir" ) \
        && exit_code=0 || exit_code=$?
    rm -rf "$tmp"

    assert_equals "$CHECK_EXIT_AUTH_FAIL" "$exit_code" "non-JSON auth.json exit code"
}

# ============================================================================
# 80.4 — check_single_tool routes opencode instead of silently skipping
# ============================================================================

test_single_tool_skips_when_no_creds() {
    local tmp exit_code
    tmp=$(mktemp -d)
    # No auth.json at all -> documented "skipped" sentinel, not a crash.
    ( XDG_CACHE_HOME="$tmp/cache" \
        check_single_tool "opencode" "false" "$USER" "$tmp" ) >/dev/null 2>&1 \
        && exit_code=0 || exit_code=$?
    rm -rf "$tmp"
    assert_equals 100 "$exit_code" "skip sentinel when opencode unconfigured"
}

test_single_tool_reaches_probe_when_creds_exist() {
    local tmp home_dir bindir exit_code
    tmp=$(mktemp -d); home_dir="$tmp/home"; bindir="$tmp/bin"
    make_fake_home "$home_dir" '{"openrouter":{"type":"api","key":"sk-or-xxx"}}'
    make_opencode_stub "$bindir"

    # Before the fix this returned 100 ("no credentials found ()") because the
    # cred-file lookup fell through to an empty string.
    # XDG_CACHE_HOME redirect: check_single_tool writes results via _check_cache_set,
    # which would otherwise poison the developer's real ~/.cache/cac/check_results.
    ( PATH="$bindir:$PATH"; XDG_CACHE_HOME="$tmp/cache" \
        check_single_tool "opencode" "false" "$USER" "$home_dir" ) >/dev/null 2>&1 \
        && exit_code=0 || exit_code=$?
    rm -rf "$tmp"

    assert_equals "$CHECK_EXIT_SUCCESS" "$exit_code" "opencode probe must actually run"
}

# ============================================================================
# 80.5 — dispatch default branch: never leave exit_code unset
# ============================================================================

test_unprobed_valid_tool_does_not_crash() {
    local tmp home_dir output exit_code
    tmp=$(mktemp -d); home_dir="$tmp/home"
    mkdir -p "$home_dir"
    printf '{}' > "$home_dir/faketool-creds"

    # Simulate the next tool someone registers: present in the registry and with a
    # credential file on disk, but no dispatch branch in check_single_tool. That is
    # the exact shape opencode had. Without the *) default, exit_code stays unset
    # and `return $exit_code` aborts with "numeric argument required".
    output=$(
        _TOOLS_REGISTRY[faketool]='faketool-creds'
        _check_get_primary_cred_file() { echo "$2/faketool-creds"; }
        XDG_CACHE_HOME="$tmp/cache"
        check_single_tool "faketool" "false" "$USER" "$home_dir" 2>&1
    ) && exit_code=0 || exit_code=$?
    rm -rf "$tmp"

    assert_equals "$CHECK_EXIT_UNKNOWN_TOOL" "$exit_code" "unprobed tool exit code" || return 1
    assert_fails "must not emit a bash numeric-argument error" \
        grep -q "numeric argument required" <<< "$output"
}

# ============================================================================
# 80.6 — check_all_tools is registry-driven
# ============================================================================

test_check_all_tools_is_registry_driven() {
    # The hardcoded list was the root cause: a tool could sit in SUPPORTED_TOOLS
    # and never be visited by `cac check`.
    assert_fails "check_all_tools must not hardcode the tool list" \
        grep -qE 'local tools=\("claude" "codex"' "$REPO_DIR/lib/check.sh" || return 1
    grep -qE 'local tools=\("\$\{SUPPORTED_TOOLS\[@\]\}"\)' "$REPO_DIR/lib/check.sh"
}

test_valid_tools_message_is_registry_driven() {
    assert_fails "error message must not hardcode the tool list" \
        grep -q 'Valid tools: claude codex gemini mistral' "$REPO_DIR/lib/check.sh"
}

# ============================================================================
# Run
# ============================================================================

run_test "80.1 opencode is in SUPPORTED_TOOLS" test_opencode_in_supported_tools
run_test "80.1 opencode passes tools_is_valid" test_opencode_is_valid_tool
run_test "80.1 opencode config files registered" test_opencode_files_are_registered

run_test "80.2 primary cred file resolves" test_primary_cred_file_resolves
run_test "80.2 display name resolves" test_display_name_resolves

run_test "80.3 missing binary -> MISSING_DEP" test_missing_binary_returns_missing_dep
run_test "80.3 valid auth.json -> SUCCESS" test_valid_auth_returns_success
run_test "80.3 empty auth.json -> AUTH_FAIL" test_empty_auth_returns_auth_fail
run_test "80.3 providerless auth.json -> AUTH_FAIL" test_providerless_auth_returns_auth_fail
run_test "80.3 non-JSON auth.json -> AUTH_FAIL" test_non_json_auth_returns_auth_fail

run_test "80.4 skip sentinel when unconfigured" test_single_tool_skips_when_no_creds
run_test "80.4 probe runs when creds exist" test_single_tool_reaches_probe_when_creds_exist

run_test "80.5 unprobed valid tool does not crash" test_unprobed_valid_tool_does_not_crash

run_test "80.6 check_all_tools registry-driven" test_check_all_tools_is_registry_driven
run_test "80.6 valid-tools message registry-driven" test_valid_tools_message_is_registry_driven

framework_report
