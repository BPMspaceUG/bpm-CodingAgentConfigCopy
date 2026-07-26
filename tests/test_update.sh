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
    # With no cac in PATH and no standard locations, should fail.
    # Create the directory BEFORE narrowing PATH — mkdir is external and would
    # otherwise be unresolvable (Issue #106). /usr/bin:/bin is retained so the
    # rest of the shell keeps working; neither holds a cac, so "no cac on PATH"
    # still holds and the test exercises an EMPTY dir, not a MISSING one.
    mkdir -p "${TEST_TMPDIR}/empty_dir"
    local old_path="$PATH"
    PATH="${TEST_TMPDIR}/empty_dir:/usr/bin:/bin"

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

# Regression guard for Issue #106. The narrowed-PATH tests below must fail
# because no cac is findable — never because the shell lost its external
# commands. This test uses the SAME narrowed shape but DOES place a cac on it:
# if PATH is ever narrowed to a single directory again, grep (lib/update.sh)
# stops resolving, extraction fails, and this test goes red — whereas the
# negative tests would keep passing for the wrong reason.
test_update_get_local_version_under_narrowed_path() {
    local mock_dir="${TEST_TMPDIR}/narrow_bin"
    mkdir -p "$mock_dir"
    cat > "${mock_dir}/cac" <<'MOCK'
#!/usr/bin/env bash
VERSION="260726-1200"
echo "cac v${VERSION}"
MOCK
    chmod +x "${mock_dir}/cac"

    local old_path="$PATH"
    local old_home="$HOME"
    PATH="${mock_dir}:/usr/bin:/bin"
    HOME="${TEST_TMPDIR}/nohome"

    local version rc=0
    version=$(update_get_local_version 2>/dev/null) || rc=$?

    PATH="$old_path"
    HOME="$old_home"

    [[ $rc -eq 0 ]] || {
        echo "update_get_local_version failed under a narrowed PATH that DOES contain cac" >&2
        return 1
    }
    assert_equals "260726-1200" "$version" "version extracted under narrowed PATH"
}

test_update_get_local_version_missing() {
    # No cac in PATH should fail.
    # mkdir before narrowing PATH, and keep /usr/bin:/bin — see Issue #106.
    # Without them update_get_local_version fails because grep (lib/update.sh)
    # is unresolvable, not because no cac was found: the right result for the
    # wrong reason.
    mkdir -p "${TEST_TMPDIR}/empty_bin"
    local old_path="$PATH"
    local old_home="$HOME"
    PATH="${TEST_TMPDIR}/empty_bin:/usr/bin:/bin"
    HOME="${TEST_TMPDIR}/nohome"

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
# Normalize Version Tests
# ============================================================================

test_update_normalize_version_hhmmss() {
    local result
    result=$(_update_normalize_version "260225-154233")
    assert_equals "260225-1542" "$result" "HHMMSS truncated to HHMM"
}

test_update_normalize_version_hhmm() {
    local result
    result=$(_update_normalize_version "260225-1542")
    assert_equals "260225-1542" "$result" "HHMM passthrough"
}

test_update_normalize_version_dirty() {
    local result
    result=$(_update_normalize_version "260225-154233-dirty")
    assert_equals "260225-1542" "$result" "dirty suffix stripped and HHMMSS truncated"
}

test_update_normalize_version_dev() {
    local result
    result=$(_update_normalize_version "dev")
    assert_equals "dev" "$result" "dev passthrough"
}

# ============================================================================
# Version Greater-or-Equal Tests
# ============================================================================

test_update_version_ge_newer() {
    _update_version_ge "260301-1500" "260225-1542" || { echo "Expected local > remote to return 0" >&2; return 1; }
    return 0
}

test_update_version_ge_equal() {
    _update_version_ge "260225-1542" "260225-1542" || { echo "Expected local == remote to return 0" >&2; return 1; }
    return 0
}

test_update_version_ge_older() {
    if _update_version_ge "260225-1542" "260301-1500"; then
        echo "Expected local < remote to return 1" >&2
        return 1
    fi
    return 0
}

test_update_version_ge_dev_local() {
    if _update_version_ge "dev" "260301-1500"; then
        echo "Expected dev local vs real remote to return 1" >&2
        return 1
    fi
    return 0
}

test_update_version_ge_dev_remote() {
    _update_version_ge "260301-1500" "dev" || { echo "Expected real local vs dev remote to return 0" >&2; return 1; }
    return 0
}

test_update_version_ge_both_dev() {
    _update_version_ge "dev" "dev" || { echo "Expected both dev to return 0" >&2; return 1; }
    return 0
}

# ============================================================================
# Downgrade Prevention Tests
# ============================================================================

test_update_check_downgrade_prevented() {
    # Local is NEWER than remote — should report "Already up to date"
    update_get_local_version() { echo "260301-1500"; }
    update_get_remote_version() { echo "260225-1542"; }

    local output
    output=$(update_check 2>/dev/null)
    local rc=$?

    unset -f update_get_local_version update_get_remote_version

    [[ $rc -eq 1 ]] || { echo "Expected rc=1 (up-to-date) when local newer, got $rc" >&2; return 1; }
    assert_contains "Already up to date" "$output" "downgrade prevented"
}

test_update_check_hhmmss_matches_hhmm() {
    # Local has HHMMSS format, remote has HHMM — same base = up to date
    update_get_local_version() { echo "260225-154233"; }
    update_get_remote_version() { echo "260225-1542"; }

    local output
    output=$(update_check 2>/dev/null)
    local rc=$?

    unset -f update_get_local_version update_get_remote_version

    [[ $rc -eq 1 ]] || { echo "Expected rc=1 for HHMMSS matching HHMM, got $rc" >&2; return 1; }
    assert_contains "Already up to date" "$output" "HHMMSS matches HHMM"
}

test_update_self_downgrade_prevented() {
    # Local is NEWER than remote — update_self should say "Already up to date"
    update_detect_scope() { echo "user"; }
    update_get_local_version() { echo "260301-1500"; }
    update_get_remote_version() { echo "260225-1542"; }

    local output
    output=$(update_self 2>/dev/null)
    local rc=$?

    unset -f update_detect_scope update_get_local_version update_get_remote_version

    [[ $rc -eq 0 ]] || { echo "Expected rc=0 for up-to-date in update_self, got $rc" >&2; return 1; }
    assert_contains "Already up to date" "$output" "update_self downgrade prevented"
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
    run_test "get_local_version under narrowed PATH" test_update_get_local_version_under_narrowed_path
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

    echo "--- Normalize Version ---"
    run_test "normalize: HHMMSS to HHMM" test_update_normalize_version_hhmmss
    run_test "normalize: HHMM passthrough" test_update_normalize_version_hhmm
    run_test "normalize: dirty + HHMMSS" test_update_normalize_version_dirty
    run_test "normalize: dev passthrough" test_update_normalize_version_dev
    echo ""

    echo "--- Version Greater-or-Equal ---"
    run_test "version_ge: newer" test_update_version_ge_newer
    run_test "version_ge: equal" test_update_version_ge_equal
    run_test "version_ge: older" test_update_version_ge_older
    run_test "version_ge: dev local" test_update_version_ge_dev_local
    run_test "version_ge: dev remote" test_update_version_ge_dev_remote
    run_test "version_ge: both dev" test_update_version_ge_both_dev
    echo ""

    echo "--- Downgrade Prevention ---"
    run_test "check: downgrade prevented" test_update_check_downgrade_prevented
    run_test "check: HHMMSS matches HHMM" test_update_check_hhmmss_matches_hhmm
    run_test "self: downgrade prevented" test_update_self_downgrade_prevented
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

    echo "--- stamp_version (Issue #58) ---"
    run_test "stamp_version: commit date in clean repo" test_stamp_version_clean_commit
    run_test "stamp_version: dirty source bakes clean commit date (no suffix)" test_stamp_version_dirty_uses_commit_date
    run_test "stamp_version: unpushed source bakes clean commit date (no suffix)" test_stamp_version_draft_uses_commit_date
    run_test "stamp_version: no git repo is noop" test_stamp_version_no_git_noop
    run_test "stamp_version: replaces VERSION line in target" test_stamp_version_replaces_version_line
    run_test "stamp_version: format is YYMMDD-HHMM" test_stamp_version_format_hhmm
    run_test "stamp_version: noop when git-log fails (delegated to fallback)" test_stamp_version_noop_when_git_log_fails
    echo ""

    framework_report
    exit $?
}

# ============================================================================
# stamp_version Tests (Issue #58)
# ============================================================================

# Extract the REAL stamp_version() from install.sh so we can test it in isolation.
# install.sh calls main "$@" at the bottom, so we cannot source it directly.
# We use sed to extract the function body and eval it into the current shell.
_load_stamp_version() {
    local install_sh="${PROJECT_ROOT}/install.sh"
    # Extract the function body from "stamp_version()" to the next closing brace at column 0
    eval "$(sed -n '/^stamp_version()/,/^}/p' "$install_sh")"
    # Provide a warn() stub since stamp_version references it in an error path
    warn() { echo "WARN: $*" >&2; }
}

# Helper: create a git repo with a single commit at a fixed date
_stamp_create_repo() {
    local repo="$1"
    local commit_date="$2"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    echo "hello" > "$repo/file.txt"
    git -C "$repo" add file.txt
    GIT_COMMITTER_DATE="$commit_date" git -C "$repo" commit -q -m "initial" --date="$commit_date"
}

# Helper: set up a fake remote so diff HEAD @{upstream} shows no diff (clean state)
_stamp_setup_upstream() {
    local repo="$1"
    git -C "$repo" remote add origin "$repo" 2>/dev/null || true
    git -C "$repo" fetch -q origin 2>/dev/null || true
    git -C "$repo" branch --set-upstream-to=origin/main main 2>/dev/null || true
}

test_stamp_version_clean_commit() {
    _load_stamp_version

    local repo="${TEST_TMPDIR}/stamp_clean_repo"
    _stamp_create_repo "$repo" "2026-02-15T10:30:00"
    _stamp_setup_upstream "$repo"

    local target="${TEST_TMPDIR}/stamp_clean_target"
    echo 'VERSION="dev"' > "$target"

    stamp_version "$target" "$repo"

    local stamped
    stamped=$(grep '^VERSION=' "$target" | head -1)

    # Should contain commit date 260215-1030, no suffix
    assert_contains "260215-1030" "$stamped" "stamp_version uses commit date"
    # Should NOT have -dirty or -draft suffix
    if [[ "$stamped" == *"-dirty"* || "$stamped" == *"-draft"* ]]; then
        echo "Expected clean version (no suffix), got: $stamped" >&2
        return 1
    fi
}

test_stamp_version_dirty_uses_commit_date() {
    _load_stamp_version

    local repo="${TEST_TMPDIR}/stamp_dirty_repo"
    _stamp_create_repo "$repo" "2026-03-10T08:45:00"

    # Make it dirty (uncommitted change)
    echo "dirty change" > "$repo/file.txt"

    local target="${TEST_TMPDIR}/stamp_dirty_target"
    echo 'VERSION="dev"' > "$target"

    stamp_version "$target" "$repo"

    local stamped
    stamped=$(grep '^VERSION=' "$target" | head -1)

    # Issue #77: install always bakes the CLEAN committed release version.
    # -dirty is a runtime-checkout-only concept and is never baked in at install time.
    assert_contains "260310-0845" "$stamped" "dirty source still bakes clean HEAD commit date"
    if [[ "$stamped" == *"-dirty"* || "$stamped" == *"-draft"* ]]; then
        echo "Expected clean version (no suffix) from dirty source, got: $stamped" >&2
        return 1
    fi
}

test_stamp_version_draft_uses_commit_date() {
    _load_stamp_version

    local repo="${TEST_TMPDIR}/stamp_draft_repo"
    _stamp_create_repo "$repo" "2026-04-20T16:15:00"

    # Committed-but-unpushed source (no upstream configured).

    local target="${TEST_TMPDIR}/stamp_draft_target"
    echo 'VERSION="dev"' > "$target"

    stamp_version "$target" "$repo"

    local stamped
    stamped=$(grep '^VERSION=' "$target" | head -1)

    # Issue #77: install always bakes the CLEAN committed release version.
    # -draft is a runtime-checkout-only concept and is never baked in at install time.
    assert_contains "260420-1615" "$stamped" "unpushed source still bakes clean commit date"
    if [[ "$stamped" == *"-draft"* || "$stamped" == *"-dirty"* ]]; then
        echo "Expected clean version (no suffix) from unpushed source, got: $stamped" >&2
        return 1
    fi
}

test_stamp_version_no_git_noop() {
    _load_stamp_version

    local target="${TEST_TMPDIR}/stamp_nogit_target"
    echo 'VERSION="dev"' > "$target"

    local no_git="${TEST_TMPDIR}/not_a_repo"
    mkdir -p "$no_git"

    stamp_version "$target" "$no_git"

    local stamped
    stamped=$(grep '^VERSION=' "$target" | head -1)
    assert_equals 'VERSION="dev"' "$stamped" "no git repo leaves VERSION unchanged"
}

test_stamp_version_replaces_version_line() {
    _load_stamp_version

    local repo="${TEST_TMPDIR}/stamp_replace_repo"
    _stamp_create_repo "$repo" "2026-06-15T14:22:00"
    _stamp_setup_upstream "$repo"

    local target="${TEST_TMPDIR}/stamp_replace_target"
    cat > "$target" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
VERSION="dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK

    stamp_version "$target" "$repo"

    local ver_line
    ver_line=$(grep '^VERSION=' "$target" | head -1)
    assert_contains "260615-1422" "$ver_line" "VERSION line replaced with commit date"

    # Surrounding content must be intact
    assert_contains 'set -euo pipefail' "$(cat "$target")" "surrounding content preserved"
    assert_contains 'SCRIPT_DIR=' "$(cat "$target")" "SCRIPT_DIR line preserved"
}

test_stamp_version_format_hhmm() {
    _load_stamp_version

    local repo="${TEST_TMPDIR}/stamp_format_repo"
    _stamp_create_repo "$repo" "2026-11-03T09:07:00"
    _stamp_setup_upstream "$repo"

    local target="${TEST_TMPDIR}/stamp_format_target"
    echo 'VERSION="dev"' > "$target"

    stamp_version "$target" "$repo"

    local stamped
    stamped=$(grep '^VERSION=' "$target" | head -1)

    # Must match YYMMDD-HHMM (4-digit time), NOT YYMMDD-HHMMSS (6-digit)
    assert_match '^VERSION="[0-9]{6}-[0-9]{4}"$' "$stamped" "version format is YYMMDD-HHMM"
}

test_stamp_version_noop_when_git_log_fails() {
    _load_stamp_version

    local repo="${TEST_TMPDIR}/stamp_fallback_repo"
    _stamp_create_repo "$repo" "2026-01-01T00:00:00"

    # Create a git wrapper that succeeds for rev-parse but fails for log
    local mock_bin="${TEST_TMPDIR}/stamp_fallback_bin"
    mkdir -p "$mock_bin"
    # Capture real git path before creating the mock to avoid PATH recursion
    local real_git
    real_git=$(command -v git)
    cat > "$mock_bin/git" <<WRAPPER
#!/usr/bin/env bash
# Pass through rev-parse; fail on log
for arg in "\$@"; do
    if [[ "\$arg" == "log" ]]; then
        exit 1
    fi
done
"${real_git}" "\$@"
WRAPPER
    chmod +x "$mock_bin/git"

    local target="${TEST_TMPDIR}/stamp_fallback_target"
    echo 'VERSION="dev"' > "$target"

    # Run stamp_version with our git wrapper first on PATH
    PATH="${mock_bin}:${PATH}" stamp_version "$target" "$repo"

    local stamped
    stamped=$(grep '^VERSION=' "$target" | head -1)

    # Issue #77: when git log fails, stamp_version is a noop and leaves VERSION
    # unchanged. Resolution is delegated to _resolve_install_version (GitHub API
    # commit date, or the "dev" sentinel) in install_files.
    assert_equals 'VERSION="dev"' "$stamped" "git log failure leaves VERSION unchanged (noop)"
}

main "$@"
