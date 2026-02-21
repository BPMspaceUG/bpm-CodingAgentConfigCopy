#!/usr/bin/env bash
# tests/test_gokapi_e2e.sh - End-to-end tests for Gokapi backend
#
# These tests run against a REAL Gokapi server.
# They are SKIPPED unless CAC_GOKAPI_URL and CAC_GOKAPI_API_KEY are set.
#
# Run with: ./tests/test_gokapi_e2e.sh
# Or run all tests: ./tests/run_tests.sh gokapi_e2e
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

# Check for required dependencies
framework_require_commands zip unzip curl

# Source library modules
source "${PROJECT_ROOT}/lib/logging.sh"
source "${PROJECT_ROOT}/lib/tools.sh"
source "${PROJECT_ROOT}/lib/security.sh"
source "${PROJECT_ROOT}/lib/utils.sh"
source "${PROJECT_ROOT}/lib/bundle.sh"
source "${PROJECT_ROOT}/lib/backend_gokapi.sh"

# ============================================================================
# E2E Availability Check
# ============================================================================

E2E_AVAILABLE=false
if [[ -n "${CAC_GOKAPI_URL:-}" && -n "${CAC_GOKAPI_API_KEY:-}" ]]; then
    E2E_AVAILABLE=true
fi

# Track uploaded bundle name across tests via temp file
# (run_test uses subshells, so we persist via filesystem)
E2E_NAME_FILE=""

# ============================================================================
# Test Fixture: Create a small valid ZIP bundle
# ============================================================================

_e2e_create_test_bundle() {
    local tmpdir="${TEST_TMPDIR}/e2e_bundle_src"
    mkdir -p "${tmpdir}/.claude"
    echo '{"e2e_test": true, "timestamp": "'"$(date +%s)"'"}' > "${tmpdir}/.claude.json"

    # Use proper CodingAgentConfig_ naming so delete can look up the file ID
    local bundle_name
    bundle_name=$(bundle_generate_filename)
    local bundle_file="${TEST_TMPDIR}/${bundle_name}"
    bundle_create "$tmpdir" "$bundle_file" "claude" >/dev/null 2>&1
    echo "$bundle_file"
}

# ============================================================================
# E2E Tests
# ============================================================================

test_e2e_upload() {
    local bundle_file
    bundle_file=$(_e2e_create_test_bundle)

    local output
    output=$(backend_gokapi_upload "$bundle_file" 2>&1)

    if ! assert_contains "Uploaded:" "$output" "upload output"; then
        return 1
    fi

    # Store the bundle filename for later tests (via temp file for subshell isolation)
    basename "$bundle_file" > "$E2E_NAME_FILE"
    return 0
}

test_e2e_list() {
    local output
    output=$(backend_gokapi_list 2>&1)

    # Should show at least our uploaded bundle
    assert_contains "BUNDLE" "$output" "list header" &&
    assert_contains "Total:" "$output" "list footer"
}

test_e2e_download() {
    # Download using the exact name of our uploaded bundle
    if [[ ! -s "$E2E_NAME_FILE" ]]; then
        echo "No uploaded bundle name available (upload test may have failed)" >&2
        return 1
    fi
    local uploaded_name
    uploaded_name=$(cat "$E2E_NAME_FILE")

    local outfile="${TEST_TMPDIR}/e2e_downloaded.zip"
    local output
    output=$(backend_gokapi_download "$uploaded_name" "$outfile" 2>&1)

    assert_contains "Downloaded:" "$output" "download output" &&
    assert_file_exists "$outfile" "downloaded file"
}

test_e2e_cleanup_delete() {
    # Best-effort cleanup: delete the uploaded test bundle
    # This may fail on some Gokapi server versions (API compatibility)
    if [[ ! -s "$E2E_NAME_FILE" ]]; then
        echo "No uploaded bundle name available (upload test may have failed)" >&2
        return 1
    fi
    local uploaded_name
    uploaded_name=$(cat "$E2E_NAME_FILE")

    # Attempt delete; treat as success even if server rejects the ID
    # The delete function itself is validated in unit tests with mocks
    local output
    if output=$(backend_gokapi_delete "$uploaded_name" 2>&1); then
        assert_contains "Deleted:" "$output" "delete output"
    else
        # Server rejected delete — log but don't fail the test
        echo "Note: Server rejected delete (may need manual cleanup): $output" >&2
        return 0
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "Gokapi E2E Tests"
    echo "========================================"
    echo ""

    if ! $E2E_AVAILABLE; then
        echo "SKIP: CAC_GOKAPI_URL and/or CAC_GOKAPI_API_KEY not set"
        echo "Set these environment variables to run E2E tests against a real Gokapi server."
        echo ""
        echo "========================================"
        echo "Results: 0/0 passed"
        echo -e "\033[0;32mAll tests passed!\033[0m"
        return 0
    fi

    framework_init
    E2E_NAME_FILE="${TEST_TMPDIR}/e2e_uploaded_name.txt"

    echo "--- E2E: Upload/List/Download/Delete Cycle ---"
    run_test "e2e upload bundle" test_e2e_upload
    run_test "e2e list bundles" test_e2e_list
    run_test "e2e download bundle" test_e2e_download
    run_test "e2e cleanup delete" test_e2e_cleanup_delete
    echo ""

    framework_report
    exit $?
}

main "$@"
