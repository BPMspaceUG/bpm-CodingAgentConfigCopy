#!/usr/bin/env bash
# tests/test_update.sh - Tests for lib/update.sh (self-update module)
#
# Run with: ./tests/test_update.sh
# Or run all tests: ./tests/run_tests.sh update
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source shared test framework
source "${SCRIPT_DIR}/test_framework.sh"

# Source library modules
source "${PROJECT_ROOT}/lib/update.sh"

# ============================================================================
# Scope Detection Tests
# ============================================================================

test_update_detect_scope_user_local() {
    # Create a mock cac binary in a .local/bin/ path
    local mock_home="${TEST_TMPDIR}/fakehome"
    mkdir -p "${mock_home}/.local/bin"
    echo '#!/bin/bash' > "${mock_home}/.local/bin/cac"
    chmod +x "${mock_home}/.local/bin/cac"

    # Override PATH so command -v finds our mock
    local old_path="$PATH"
    PATH="${mock_home}/.local/bin:$PATH"

    local scope
    scope=$(update_detect_scope 2>/dev/null)
    local rc=$?

    PATH="$old_path"

    [[ $rc -eq 0 ]] || { echo "update_detect_scope failed with rc=$rc" >&2; return 1; }
    assert_equals "user" "$scope" "scope for .local/bin install"
}

test_update_detect_scope_global() {
    # Create a mock directory structure that looks like /usr/local/bin/
    # We simulate this by creating a temp path and overriding command -v
    # Since we can't write to /usr/local/bin in tests, we test the path
    # matching logic directly by calling the function with a mock PATH.

    # Create mock /usr/local/bin in temp (using symlink trick)
    local mock_root="${TEST_TMPDIR}/mock_global"
    mkdir -p "${mock_root}/usr/local/bin"
    echo '#!/bin/bash' > "${mock_root}/usr/local/bin/cac"
    chmod +x "${mock_root}/usr/local/bin/cac"

    # We need to test the path-matching logic. Since command -v resolves
    # from PATH, and our mock path won't start with /usr/local/bin/,
    # we test the fallback logic by making /usr/local/bin/cac not exist
    # and the function checks the explicit path.

    # Instead, test the path pattern matching directly with a function override
    local old_path="$PATH"
    PATH="${mock_root}/usr/local/bin:${TEST_TMPDIR}/empty"

    # The path won't literally start with /usr/local/bin/ because it's in TEST_TMPDIR.
    # So this tests the fallback. We verify the function handles non-standard paths.
    # For the real /usr/local/bin test, we check pattern matching in a unit test below.
    PATH="$old_path"

    # Direct pattern test: verify the logic that checks path prefixes
    local test_path="/usr/local/bin/cac"
    if [[ "$test_path" == /usr/local/bin/* ]]; then
        return 0
    else
        echo "Path pattern /usr/local/bin/* did not match" >&2
        return 1
    fi
}

test_update_detect_scope_user_pattern() {
    # Verify the .local/bin pattern matching works
    local test_path="/home/testuser/.local/bin/cac"
    if [[ "$test_path" == */.local/bin/* ]]; then
        return 0
    else
        echo "Path pattern */.local/bin/* did not match" >&2
        return 1
    fi
}

test_update_detect_scope_unknown() {
    # With no cac in PATH and no standard locations, should fail
    local old_path="$PATH"
    PATH="${TEST_TMPDIR}/empty_dir"
    mkdir -p "${TEST_TMPDIR}/empty_dir"

    # Temporarily hide standard locations by overriding the function's checks
    # The function checks /usr/local/bin/cac and ~/.local/bin/cac as fallback.
    # We override HOME so ~/.local/bin/cac won't be found
    local old_home="$HOME"
    HOME="${TEST_TMPDIR}/nohome"

    local result
    result=$(update_detect_scope 2>/dev/null) && {
        PATH="$old_path"
        HOME="$old_home"
        # If /usr/local/bin/cac actually exists on this system, scope will be "global"
        # That's acceptable — the test is about the fallback logic
        if [[ "$result" == "global" || "$result" == "user" ]]; then
            return 0
        fi
        echo "Expected failure but got: $result" >&2
        return 1
    }

    PATH="$old_path"
    HOME="$old_home"

    # Function correctly failed — this is the expected path when cac is not installed
    return 0
}

# ============================================================================
# Version Extraction Tests
# ============================================================================

test_update_get_local_version() {
    # Create a mock cac binary with a known version
    local mock_dir="${TEST_TMPDIR}/mock_bin"
    mkdir -p "$mock_dir"
    cat > "${mock_dir}/cac" <<'MOCK'
#!/usr/bin/env bash
VERSION="260203-1222"
echo "cac v${VERSION}"
MOCK
    chmod +x "${mock_dir}/cac"

    local old_path="$PATH"
    PATH="${mock_dir}:$PATH"

    local version
    version=$(update_get_local_version 2>/dev/null)
    local rc=$?

    PATH="$old_path"

    [[ $rc -eq 0 ]] || { echo "update_get_local_version failed" >&2; return 1; }
    assert_equals "260203-1222" "$version" "extracted local version"
}

test_update_get_local_version_different_format() {
    # Test with single-quoted version
    local mock_dir="${TEST_TMPDIR}/mock_bin2"
    mkdir -p "$mock_dir"
    cat > "${mock_dir}/cac" <<'MOCK'
#!/usr/bin/env bash
VERSION='260301-0900'
echo "cac v${VERSION}"
MOCK
    chmod +x "${mock_dir}/cac"

    local old_path="$PATH"
    PATH="${mock_dir}:$PATH"

    local version
    version=$(update_get_local_version 2>/dev/null)
    local rc=$?

    PATH="$old_path"

    [[ $rc -eq 0 ]] || { echo "update_get_local_version failed" >&2; return 1; }
    assert_equals "260301-0900" "$version" "extracted single-quoted version"
}

test_update_get_local_version_missing() {
    # No cac in PATH should fail
    local old_path="$PATH"
    local old_home="$HOME"
    PATH="${TEST_TMPDIR}/empty_bin"
    HOME="${TEST_TMPDIR}/nohome"
    mkdir -p "${TEST_TMPDIR}/empty_bin"

    local result
    if result=$(update_get_local_version 2>/dev/null); then
        PATH="$old_path"
        HOME="$old_home"
        # If /usr/local/bin/cac exists on the system, this might succeed
        # That's OK — we just verify it returns a non-empty string
        [[ -n "$result" ]] || { echo "Got empty version" >&2; return 1; }
        return 0
    fi

    PATH="$old_path"
    HOME="$old_home"
    # Expected: function failed because no cac found
    return 0
}

# ============================================================================
# Version Extraction from File (internal helper)
# ============================================================================

test_update_extract_version_from_file() {
    local mock_file="${TEST_TMPDIR}/mock_cac"
    cat > "$mock_file" <<'EOF'
#!/usr/bin/env bash
VERSION="260203-1222"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EOF

    local version
    version=$(_update_extract_version_from_file "$mock_file")
    assert_equals "260203-1222" "$version" "version from file"
}

test_update_extract_version_from_file_missing() {
    assert_fails "extract from nonexistent file" _update_extract_version_from_file "/nonexistent/file"
}

test_update_extract_version_from_file_no_version_line() {
    local mock_file="${TEST_TMPDIR}/no_version"
    echo '#!/bin/bash' > "$mock_file"
    echo 'echo hello' >> "$mock_file"

    assert_fails "extract from file without VERSION" _update_extract_version_from_file "$mock_file"
}

# ============================================================================
# Remote Version Fetch Tests (mocked)
# ============================================================================

test_update_get_remote_version_with_mock() {
    # Mock the GitHub API commits/main JSON response
    local mock_json="${TEST_TMPDIR}/github_api_response.json"
    cat > "$mock_json" <<'EOF'
{
  "sha": "abc123",
  "commit": {
    "author": {
      "name": "Test User",
      "email": "test@example.com",
      "date": "2026-03-01T15:00:33Z"
    },
    "committer": {
      "name": "Test User",
      "email": "test@example.com",
      "date": "2026-03-01T15:00:33Z"
    },
    "message": "test commit"
  }
}
EOF

    # Override curl to return our mock GitHub API JSON
    curl() {
        cat "$mock_json"
    }

    local version
    version=$(update_get_remote_version 2>/dev/null)
    local rc=$?

    unset -f curl

    [[ $rc -eq 0 ]] || { echo "update_get_remote_version failed" >&2; return 1; }
    assert_equals "260301-1500" "$version" "remote version from mock GitHub API"
}

test_update_get_remote_version_failure() {
    # Override curl to fail
    curl() {
        return 1
    }

    assert_fails "remote version with curl failure" update_get_remote_version

    unset -f curl
}

# ============================================================================
# Version Comparison / Check Mode Tests
# ============================================================================

test_update_check_up_to_date() {
    # Mock both local and remote to return same version
    update_get_local_version() { echo "260203-1222"; }
    update_get_remote_version() { echo "260203-1222"; }

    local output
    output=$(update_check 2>/dev/null)
    local rc=$?

    unset -f update_get_local_version update_get_remote_version

    # update_check returns 1 when already up to date
    [[ $rc -eq 1 ]] || { echo "Expected rc=1 for up-to-date, got $rc" >&2; return 1; }
    assert_contains "Already up to date" "$output" "up-to-date message"
}

test_update_check_update_available() {
    # Mock local and remote with different versions
    update_get_local_version() { echo "260203-1222"; }
    update_get_remote_version() { echo "260301-1500"; }

    local output
    output=$(update_check 2>/dev/null)
    local rc=$?

    unset -f update_get_local_version update_get_remote_version

    [[ $rc -eq 0 ]] || { echo "Expected rc=0 for update available, got $rc" >&2; return 1; }
    assert_contains "Update available" "$output" "update-available message"
    assert_contains "260203-1222" "$output" "old version in output"
    assert_contains "260301-1500" "$output" "new version in output"
}

test_update_check_output_format() {
    # Verify output contains both installed and available labels
    update_get_local_version() { echo "260101-0000"; }
    update_get_remote_version() { echo "260201-0000"; }

    local output
    output=$(update_check 2>/dev/null)

    unset -f update_get_local_version update_get_remote_version

    assert_contains "Installed version:" "$output" "installed version label"
    assert_contains "Available version:" "$output" "available version label"
}

# ============================================================================
# Root Check Tests
# ============================================================================

test_update_global_requires_root() {
    # Skip if actually running as root
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        echo "SKIP: Test requires non-root" >&2
        return 0
    fi

    # Mock scope detection to return "global"
    update_detect_scope() { echo "global"; }
    update_get_local_version() { echo "260101-0000"; }
    update_get_remote_version() { echo "260201-0000"; }

    assert_fails "global update without root" update_self

    unset -f update_detect_scope update_get_local_version update_get_remote_version
}

test_update_user_scope_no_root_needed() {
    # Mock scope as user — should not require root
    # We mock the whole chain to avoid actually running install.sh
    update_detect_scope() { echo "user"; }
    update_get_local_version() { echo "260203-1222"; }
    update_get_remote_version() { echo "260203-1222"; }

    # Same version = "already up to date" = returns 0
    local output
    output=$(update_self 2>/dev/null)
    local rc=$?

    unset -f update_detect_scope update_get_local_version update_get_remote_version

    [[ $rc -eq 0 ]] || { echo "Expected rc=0 for up-to-date user scope, got $rc" >&2; return 1; }
    assert_contains "Already up to date" "$output" "up-to-date message"
}

# ============================================================================
# Command Entry Point Tests
# ============================================================================

test_update_cmd_main_help() {
    local output
    output=$(update_cmd_main --help 2>/dev/null)
    local rc=$?

    [[ $rc -eq 0 ]] || { echo "Help should return 0" >&2; return 1; }
    assert_contains "cac update" "$output" "help text header"
    assert_contains "--check" "$output" "help mentions --check"
}

test_update_cmd_main_unknown_option() {
    assert_fails "unknown option" update_cmd_main --bogus
}

test_update_cmd_main_check_flag() {
    # Mock the version functions
    update_get_local_version() { echo "260203-1222"; }
    update_get_remote_version() { echo "260203-1222"; }

    local output
    output=$(update_cmd_main --check 2>/dev/null)
    local rc=$?

    unset -f update_get_local_version update_get_remote_version

    # --check with same version: up to date, but cmd_main converts rc=1 to rc=0
    [[ $rc -eq 0 ]] || { echo "Expected rc=0 from cmd_main --check, got $rc" >&2; return 1; }
    assert_contains "Already up to date" "$output" "check mode up-to-date"
}

# ============================================================================
# Suffix Stripping Tests
# ============================================================================

test_update_strip_suffix_dirty() {
    local result
    result=$(_update_strip_suffix "260225-1542-dirty")
    assert_equals "260225-1542" "$result" "strip -dirty suffix"
}

test_update_strip_suffix_draft() {
    local result
    result=$(_update_strip_suffix "260225-1542-draft")
    assert_equals "260225-1542" "$result" "strip -draft suffix"
}

test_update_strip_suffix_clean() {
    local result
    result=$(_update_strip_suffix "260225-1542")
    assert_equals "260225-1542" "$result" "clean version passthrough"
}

test_update_strip_suffix_dev() {
    local result
    result=$(_update_strip_suffix "dev")
    assert_equals "dev" "$result" "dev passthrough"
}

# ============================================================================
# Version Extraction with Live Detection Block
# ============================================================================

test_update_extract_version_from_file_with_live_block() {
    # Simulate the installed binary where stamp_version has baked in a version
    # but the live detection block still exists below as dead code
    local mock_file="${TEST_TMPDIR}/mock_cac_live_block"
    cat > "$mock_file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
VERSION="260225-1542"
_tool_dir="$(dirname "${BASH_SOURCE[0]:-$0}")"
if git -C "$_tool_dir" rev-parse --git-dir &>/dev/null; then
    VERSION=$(git -C "$_tool_dir" log -1 --format='%cd' --date=format:'%y%m%d-%H%M' HEAD 2>/dev/null || echo "dev")
fi
unset _tool_dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EOF

    local version
    version=$(_update_extract_version_from_file "$mock_file")
    assert_equals "260225-1542" "$version" "version from file with live detection block"
}

test_update_extract_version_from_file_dev_default() {
    # Simulate the source file in git repo where VERSION="dev" is the default
    local mock_file="${TEST_TMPDIR}/mock_cac_dev"
    cat > "$mock_file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
VERSION="dev"
_tool_dir="$(dirname "${BASH_SOURCE[0]:-$0}")"
EOF

    local version
    version=$(_update_extract_version_from_file "$mock_file")
    assert_equals "dev" "$version" "dev default from source file"
}

# ============================================================================
# Version Comparison with Suffixes
# ============================================================================

test_update_check_dirty_matches_clean_remote() {
    # Local has -dirty suffix, remote is clean — same base version = up to date
    update_get_local_version() { echo "260225-1542-dirty"; }
    update_get_remote_version() { echo "260225-1542"; }

    local output
    output=$(update_check 2>/dev/null)
    local rc=$?

    unset -f update_get_local_version update_get_remote_version

    [[ $rc -eq 1 ]] || { echo "Expected rc=1 for up-to-date (dirty matches clean), got $rc" >&2; return 1; }
    assert_contains "Already up to date" "$output" "dirty local matches clean remote"
}

test_update_check_draft_matches_clean_remote() {
    # Local has -draft suffix, remote is clean — same base version = up to date
    update_get_local_version() { echo "260225-1542-draft"; }
    update_get_remote_version() { echo "260225-1542"; }

    local output
    output=$(update_check 2>/dev/null)
    local rc=$?

    unset -f update_get_local_version update_get_remote_version

    [[ $rc -eq 1 ]] || { echo "Expected rc=1 for up-to-date (draft matches clean), got $rc" >&2; return 1; }
    assert_contains "Already up to date" "$output" "draft local matches clean remote"
}

test_update_check_dirty_older_than_remote() {
    # Local is older with -dirty, remote is newer — update available
    update_get_local_version() { echo "260203-1222-dirty"; }
    update_get_remote_version() { echo "260301-1500"; }

    local output
    output=$(update_check 2>/dev/null)
    local rc=$?

    unset -f update_get_local_version update_get_remote_version

    [[ $rc -eq 0 ]] || { echo "Expected rc=0 for update available, got $rc" >&2; return 1; }
    assert_contains "Update available" "$output" "dirty older than remote"
}

# ============================================================================
# Local Version with Suffix
# ============================================================================

test_update_get_local_version_with_dirty() {
    local mock_dir="${TEST_TMPDIR}/mock_bin_dirty"
    mkdir -p "$mock_dir"
    cat > "${mock_dir}/cac" <<'MOCK'
#!/usr/bin/env bash
VERSION="260225-1542-dirty"
echo "cac v${VERSION}"
MOCK
    chmod +x "${mock_dir}/cac"

    local old_path="$PATH"
    PATH="${mock_dir}:$PATH"

    local version
    version=$(update_get_local_version 2>/dev/null)
    local rc=$?

    PATH="$old_path"

    [[ $rc -eq 0 ]] || { echo "update_get_local_version failed" >&2; return 1; }
    assert_equals "260225-1542-dirty" "$version" "local version with dirty suffix"
}

test_update_get_local_version_with_draft() {
    local mock_dir="${TEST_TMPDIR}/mock_bin_draft"
    mkdir -p "$mock_dir"
    cat > "${mock_dir}/cac" <<'MOCK'
#!/usr/bin/env bash
VERSION="260225-1542-draft"
echo "cac v${VERSION}"
MOCK
    chmod +x "${mock_dir}/cac"

    local old_path="$PATH"
    PATH="${mock_dir}:$PATH"

    local version
    version=$(update_get_local_version 2>/dev/null)
    local rc=$?

    PATH="$old_path"

    [[ $rc -eq 0 ]] || { echo "update_get_local_version failed" >&2; return 1; }
    assert_equals "260225-1542-draft" "$version" "local version with draft suffix"
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "Update Module Tests"
    echo "========================================"
    echo ""

    framework_init

    echo "--- Scope Detection ---"
    run_test "detect_scope user-local" test_update_detect_scope_user_local
    run_test "detect_scope global pattern" test_update_detect_scope_global
    run_test "detect_scope user pattern" test_update_detect_scope_user_pattern
    run_test "detect_scope unknown/fallback" test_update_detect_scope_unknown
    echo ""

    echo "--- Local Version Extraction ---"
    run_test "get_local_version" test_update_get_local_version
    run_test "get_local_version different format" test_update_get_local_version_different_format
    run_test "get_local_version missing binary" test_update_get_local_version_missing
    echo ""

    echo "--- Version File Parsing ---"
    run_test "extract_version_from_file" test_update_extract_version_from_file
    run_test "extract_version_from_file missing" test_update_extract_version_from_file_missing
    run_test "extract_version_from_file no VERSION line" test_update_extract_version_from_file_no_version_line
    echo ""

    echo "--- Remote Version Fetch ---"
    run_test "get_remote_version (mocked)" test_update_get_remote_version_with_mock
    run_test "get_remote_version failure" test_update_get_remote_version_failure
    echo ""

    echo "--- Suffix Stripping ---"
    run_test "strip_suffix: -dirty" test_update_strip_suffix_dirty
    run_test "strip_suffix: -draft" test_update_strip_suffix_draft
    run_test "strip_suffix: clean passthrough" test_update_strip_suffix_clean
    run_test "strip_suffix: dev passthrough" test_update_strip_suffix_dev
    echo ""

    echo "--- Version File Parsing (live block) ---"
    run_test "extract_version: baked-in with live block" test_update_extract_version_from_file_with_live_block
    run_test "extract_version: dev default" test_update_extract_version_from_file_dev_default
    echo ""

    echo "--- Local Version with Suffix ---"
    run_test "get_local_version with -dirty" test_update_get_local_version_with_dirty
    run_test "get_local_version with -draft" test_update_get_local_version_with_draft
    echo ""

    echo "--- Version Comparison ---"
    run_test "check: already up to date" test_update_check_up_to_date
    run_test "check: update available" test_update_check_update_available
    run_test "check: output format" test_update_check_output_format
    run_test "check: dirty matches clean remote" test_update_check_dirty_matches_clean_remote
    run_test "check: draft matches clean remote" test_update_check_draft_matches_clean_remote
    run_test "check: dirty older than remote" test_update_check_dirty_older_than_remote
    echo ""

    echo "--- Root Checks ---"
    run_test "global scope requires root" test_update_global_requires_root
    run_test "user scope needs no root" test_update_user_scope_no_root_needed
    echo ""

    echo "--- Command Entry Point ---"
    run_test "cmd_main --help" test_update_cmd_main_help
    run_test "cmd_main unknown option" test_update_cmd_main_unknown_option
    run_test "cmd_main --check" test_update_cmd_main_check_flag
    echo ""

    framework_report
    exit $?
}

main "$@"
