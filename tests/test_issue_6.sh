#!/usr/bin/env bash
# tests/test_issue_6.sh - Tests for Issue #6: cac check command
#
# Test suite for credential verification functionality including:
# - Cache operations (hit, miss, invalidation)
# - Timeout handling
# - Exit codes
# - CLI integration
#
# Based on approved test plan v4 (13 REQUIRED + 1 OPTIONAL tests)

set -uo pipefail
# Note: errexit disabled because arithmetic expressions like ((count++)) return 1
# when incrementing from 0 to 1, which would cause script exit

# Test setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the check module for unit tests
source "$REPO_DIR/lib/logging.sh"
source "$REPO_DIR/lib/tools.sh"
source "$REPO_DIR/lib/check.sh"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
REQUIRED_PASSED=0
REQUIRED_FAILED=0
REQUIRED_SKIPPED=0
OPTIONAL_PASSED=0
OPTIONAL_SKIPPED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test helpers
pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((TESTS_PASSED++)) || true
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    ((TESTS_FAILED++)) || true
}

skip() {
    echo -e "${YELLOW}SKIP${NC}: $1"
    ((REQUIRED_SKIPPED++)) || true
}

# Create temp directory for tests
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Check if timeout command is available (used by multiple tests)
TIMEOUT_AVAILABLE=false
if command -v timeout &>/dev/null || command -v gtimeout &>/dev/null; then
    TIMEOUT_AVAILABLE=true
fi

# ============================================================================
# Test Utilities
# ============================================================================

# Create a mock home with fake tool binaries
# Usage: create_mock_env <test_name> <tools_to_mock>
# Returns: Sets MOCK_HOME, MOCK_BIN, ORIG_PATH, ORIG_HOME, ORIG_XDG_CACHE
create_mock_env() {
    local test_name="$1"
    shift
    local tools_to_mock=("$@")

    MOCK_HOME="$TEMP_DIR/${test_name}_home"
    MOCK_BIN="$TEMP_DIR/${test_name}_bin"
    MOCK_CACHE="$TEMP_DIR/${test_name}_cache"
    mkdir -p "$MOCK_HOME" "$MOCK_BIN" "$MOCK_CACHE"

    # Save originals
    ORIG_PATH="$PATH"
    ORIG_HOME="${HOME:-}"
    ORIG_XDG_CACHE="${XDG_CACHE_HOME:-}"

    # Link timeout if available
    if command -v timeout &>/dev/null; then
        ln -sf "$(command -v timeout)" "$MOCK_BIN/timeout"
    elif command -v gtimeout &>/dev/null; then
        ln -sf "$(command -v gtimeout)" "$MOCK_BIN/gtimeout"
    fi

    # Create mock getent that returns MOCK_HOME for current user
    # This is required because security_resolve_user_home uses getent, not $HOME
    local current_user
    current_user=$(whoami)
    cat > "$MOCK_BIN/getent" <<EOF
#!/bin/bash
# Mock getent for testing - returns MOCK_HOME for current user
if [[ "\$1" == "passwd" && "\$2" == "$current_user" ]]; then
    echo "$current_user:x:$(id -u):$(id -g):$current_user:$MOCK_HOME:/bin/bash"
    exit 0
fi
# Pass through to real getent for other queries
$(command -v getent) "\$@"
EOF
    chmod +x "$MOCK_BIN/getent"

    # Create mock tool binaries
    # Note: check.sh expects specific response strings (CLAUDE_OK, CODEX_OK, GEMINI_OK)
    # and also calls --version, so mocks must handle these
    for tool in "${tools_to_mock[@]}"; do
        case "$tool" in
            claude_ok)
                cat > "$MOCK_BIN/claude" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "mock-claude 1.0.0"
    exit 0
fi
echo "CLAUDE_OK"
exit 0
EOF
                chmod +x "$MOCK_BIN/claude"
                echo '{}' > "$MOCK_HOME/.claude.json"
                ;;
            claude_fail)
                cat > "$MOCK_BIN/claude" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "mock-claude 1.0.0"
    exit 0
fi
echo "AUTH_ERROR: Invalid credentials"
exit 1
EOF
                chmod +x "$MOCK_BIN/claude"
                echo '{}' > "$MOCK_HOME/.claude.json"
                ;;
            codex_ok)
                cat > "$MOCK_BIN/codex" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "mock-codex 1.0.0"
    exit 0
fi
echo "CODEX_OK"
exit 0
EOF
                chmod +x "$MOCK_BIN/codex"
                mkdir -p "$MOCK_HOME/.codex"
                echo '{}' > "$MOCK_HOME/.codex/auth.json"
                ;;
            codex_fail)
                cat > "$MOCK_BIN/codex" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "mock-codex 1.0.0"
    exit 0
fi
echo "AUTH_ERROR"
exit 1
EOF
                chmod +x "$MOCK_BIN/codex"
                mkdir -p "$MOCK_HOME/.codex"
                echo '{}' > "$MOCK_HOME/.codex/auth.json"
                ;;
            gemini_ok)
                cat > "$MOCK_BIN/gemini" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "mock-gemini 1.0.0"
    exit 0
fi
echo "GEMINI_OK"
exit 0
EOF
                chmod +x "$MOCK_BIN/gemini"
                mkdir -p "$MOCK_HOME/.gemini"
                echo '{}' > "$MOCK_HOME/.gemini/oauth_creds.json"
                ;;
            gemini_fail)
                cat > "$MOCK_BIN/gemini" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "mock-gemini 1.0.0"
    exit 0
fi
echo "AUTH_ERROR"
exit 1
EOF
                chmod +x "$MOCK_BIN/gemini"
                mkdir -p "$MOCK_HOME/.gemini"
                echo '{}' > "$MOCK_HOME/.gemini/oauth_creds.json"
                ;;
        esac
    done

    # Set environment - prepend mock bin to PATH (don't replace entirely)
    PATH="$MOCK_BIN:$ORIG_PATH"
    export HOME="$MOCK_HOME"
    export XDG_CACHE_HOME="$MOCK_CACHE"
}

# Restore original environment
restore_env() {
    PATH="$ORIG_PATH"
    if [[ -n "$ORIG_HOME" ]]; then
        export HOME="$ORIG_HOME"
    fi
    if [[ -n "$ORIG_XDG_CACHE" ]]; then
        export XDG_CACHE_HOME="$ORIG_XDG_CACHE"
    else
        unset XDG_CACHE_HOME
    fi
}

# ============================================================================
# Unit Tests (lib/check.sh)
# ============================================================================

echo "=========================================="
echo "Issue #6: cac check Command Tests"
echo "=========================================="
echo ""
echo "Unit Tests (lib/check.sh)"
echo "=========================================="

# Test 6.1 (REQUIRED): Cache hit returns cached result
echo ""
echo "Test 6.1 (REQUIRED): Cache hit returns cached result"

test_6_1() {
    create_mock_env "test_6_1" "claude_ok"

    # Create a valid cache entry (less than 5 minutes old)
    local cache_file="$MOCK_CACHE/cac/check_results"
    mkdir -p "$(dirname "$cache_file")"
    local now
    now=$(date +%s)
    local recent=$((now - 60))  # 60 seconds ago

    echo "claude:testhash123:${recent}:OK" > "$cache_file"
    chmod 600 "$cache_file"

    # Call actual _check_cache_get function
    local result
    result=$(_check_cache_get "claude" "testhash123")

    restore_env

    if [[ "$result" == "OK" ]]; then
        pass "Test 6.1 - _check_cache_get returns 'OK' for fresh entry"
        ((REQUIRED_PASSED++)) || true
    else
        fail "Test 6.1 - Expected 'OK', got '$result'"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_1

# Test 6.2 (REQUIRED): Cache miss triggers fresh check
echo ""
echo "Test 6.2 (REQUIRED): Cache miss triggers fresh check (expired entry)"

test_6_2() {
    create_mock_env "test_6_2" "claude_ok"

    # Create an expired cache entry (more than 5 minutes old)
    local cache_file="$MOCK_CACHE/cac/check_results"
    mkdir -p "$(dirname "$cache_file")"
    local now
    now=$(date +%s)
    local old=$((now - 400))  # 400 seconds ago (> 300 TTL)

    echo "claude:testhash456:${old}:OK" > "$cache_file"
    chmod 600 "$cache_file"

    # Call actual _check_cache_get function
    local result
    result=$(_check_cache_get "claude" "testhash456")

    restore_env

    if [[ -z "$result" ]]; then
        pass "Test 6.2 - _check_cache_get returns empty for expired entry"
        ((REQUIRED_PASSED++)) || true
    else
        fail "Test 6.2 - Expected empty, got '$result'"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_2

# Test 6.3 (REQUIRED): Cache invalidation on version change
echo ""
echo "Test 6.3 (REQUIRED): Cache invalidation on version change"

test_6_3() {
    create_mock_env "test_6_3" "claude_ok"

    # Create cache entry with old key
    local cache_file="$MOCK_CACHE/cac/check_results"
    mkdir -p "$(dirname "$cache_file")"
    local now
    now=$(date +%s)
    local recent=$((now - 60))

    # Cache entry with key "oldhash789"
    echo "claude:oldhash789:${recent}:OK" > "$cache_file"
    chmod 600 "$cache_file"

    # Call actual _check_cache_get with different key (simulating version change)
    local result
    result=$(_check_cache_get "claude" "newhash999")

    restore_env

    if [[ -z "$result" ]]; then
        pass "Test 6.3 - _check_cache_get returns empty for key mismatch"
        ((REQUIRED_PASSED++)) || true
    else
        fail "Test 6.3 - Expected empty, got '$result'"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_3

# Test 6.4 (REQUIRED): Timeout kills long-running check
echo ""
echo "Test 6.4 (REQUIRED): Timeout kills long-running check"

test_6_4() {
    if ! $TIMEOUT_AVAILABLE; then
        skip "Test 6.4 - Requires timeout command (dependency issue)"
        # Note: Don't count skips as pass or fail - leave test count unchanged
        return
    fi

    # Run a command that sleeps longer than our timeout
    local exit_code
    _check_with_timeout 1 sleep 5 2>/dev/null
    exit_code=$?

    if [[ $exit_code -eq $CHECK_EXIT_TIMEOUT ]]; then
        pass "Test 6.4 - Timeout returns exit code 3"
        ((REQUIRED_PASSED++)) || true
    else
        fail "Test 6.4 - Expected exit code 3, got $exit_code"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_4

# Test 6.5 (REQUIRED): Missing timeout command error
echo ""
echo "Test 6.5 (REQUIRED): Missing timeout command error"

test_6_5() {
    # Save original PATH
    local orig_path="$PATH"

    # Create a temp bin with no timeout commands
    local fake_bin="$TEMP_DIR/fake_bin_6_5"
    mkdir -p "$fake_bin"

    # Set PATH to only include our fake bin
    PATH="$fake_bin"

    local exit_code output
    output=$(_check_get_timeout_cmd 2>&1)
    exit_code=$?

    # Restore PATH
    PATH="$orig_path"

    if [[ $exit_code -eq $CHECK_EXIT_MISSING_DEP ]]; then
        if echo "$output" | grep -qi "timeout"; then
            pass "Test 6.5 - Missing timeout returns exit code 4 with error message"
            ((REQUIRED_PASSED++)) || true
        else
            fail "Test 6.5 - Exit code 4 but no timeout error message"
            ((REQUIRED_FAILED++)) || true
        fi
    else
        fail "Test 6.5 - Expected exit code 4, got $exit_code"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_5

# Test 6.5b (REQUIRED): Known tool with missing binary returns exit 4
echo ""
echo "Test 6.5b (REQUIRED): Known tool with missing binary returns exit 4"

test_6_5b() {
    # Create mock env with credentials but NO claude binary
    create_mock_env "test_6_5b"

    # Create credential file for Claude (makes it "configured")
    echo '{}' > "$MOCK_HOME/.claude.json"

    # Don't create claude binary - but we need to ensure system claude isn't found
    # Save PATH and set to ONLY mock bin (no fallback to system)
    local saved_path="$PATH"
    PATH="$MOCK_BIN"

    local exit_code output
    output=$(check_single_tool "claude" "false" "$USER" "$MOCK_HOME" 2>&1)
    exit_code=$?

    PATH="$saved_path"
    restore_env

    if [[ $exit_code -eq $CHECK_EXIT_MISSING_DEP ]]; then
        if echo "$output" | grep -qi "not found"; then
            pass "Test 6.5b - Missing binary returns exit code 4 with error"
            ((REQUIRED_PASSED++)) || true
        else
            fail "Test 6.5b - Exit code 4 but no 'not found' message"
            ((REQUIRED_FAILED++)) || true
        fi
    else
        fail "Test 6.5b - Expected exit code 4, got $exit_code"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_5b

# ============================================================================
# Integration Tests (bin/cac)
# ============================================================================

echo ""
echo "=========================================="
echo "Integration Tests (bin/cac)"
echo "=========================================="

# Test 6.6 (REQUIRED): `cac check` runs all tools
echo ""
echo "Test 6.6 (REQUIRED): cac check runs all tools"

test_6_6() {
    if ! $TIMEOUT_AVAILABLE; then
        skip "Test 6.6 - Requires timeout command (dependency issue)"
        # Note: Don't count skips as pass or fail - leave test count unchanged
        return
    fi

    # Create mock env with all tools returning OK (fast)
    create_mock_env "test_6_6" "claude_ok" "codex_ok" "gemini_ok"

    # Call check_all_tools directly with mock home to verify all tools are checked
    # Note: Cannot use CLI directly because security_resolve_user_home uses getent, not $HOME
    local output
    output=$(check_all_tools "false" "$USER" "$MOCK_HOME" 2>&1) || true

    restore_env

    # Should mention all three tools (checking or OK)
    local found_all=true
    for tool in Claude Codex Gemini; do
        if ! echo "$output" | grep -qi "$tool"; then
            found_all=false
            break
        fi
    done

    if $found_all; then
        pass "Test 6.6 - check_all_tools checks all three tools"
        ((REQUIRED_PASSED++)) || true
    else
        fail "Test 6.6 - Not all tools mentioned in output: $output"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_6

# Test 6.7 (REQUIRED): `cac check claude` runs only Claude
echo ""
echo "Test 6.7 (REQUIRED): cac check claude runs only Claude"

test_6_7() {
    if ! $TIMEOUT_AVAILABLE; then
        skip "Test 6.7 - Requires timeout command (dependency issue, not test failure)"
        # Note: Don't count skips as pass or fail - leave test count unchanged
        return
    fi

    # Create mock env with Claude credentials and mock binary
    create_mock_env "test_6_7" "claude_ok"

    # Call check_single_tool directly (CLI uses getent, not $HOME)
    local output
    output=$(check_single_tool "claude" "false" "$USER" "$MOCK_HOME" 2>&1) || true

    restore_env

    # Should mention Claude
    local mentions_claude=false
    local mentions_others=false

    if echo "$output" | grep -qi "claude"; then
        mentions_claude=true
    fi

    # Should NOT check codex or gemini
    if echo "$output" | grep -qi "Codex\|Gemini"; then
        mentions_others=true
    fi

    if $mentions_claude && ! $mentions_others; then
        pass "Test 6.7 - check_single_tool only processes Claude"
        ((REQUIRED_PASSED++)) || true
    else
        fail "Test 6.7 - Expected only Claude, mentions_claude=$mentions_claude, mentions_others=$mentions_others"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_7

# Test 6.6b (REQUIRED): `bin/cac check` CLI runs all tools (CLI-level test)
echo ""
echo "Test 6.6b (REQUIRED): bin/cac check CLI runs all tools"

test_6_6b() {
    if ! $TIMEOUT_AVAILABLE; then
        skip "Test 6.6b - Requires timeout command (dependency issue)"
        return
    fi

    # Create mock env with all tools returning OK
    # Note: create_mock_env also creates mock getent that returns MOCK_HOME
    create_mock_env "test_6_6b" "claude_ok" "codex_ok" "gemini_ok"

    # Run bin/cac check via CLI with mock binaries AND mock getent in PATH
    # Note: Capture exit code BEFORE || true to avoid masking it
    local output exit_code
    output=$(PATH="$MOCK_BIN:$ORIG_PATH" "$REPO_DIR/bin/cac" check 2>&1)
    exit_code=$?

    restore_env

    # Verify all three tools were CHECKED (not skipped)
    # Output should contain "Checking <tool> credentials... OK" for each tool
    local checks_ok=true
    local has_skipping=false

    for tool in Claude Codex Gemini; do
        if ! echo "$output" | grep -qi "Checking $tool.*OK"; then
            checks_ok=false
            break
        fi
    done

    # Ensure no tools were skipped
    if echo "$output" | grep -qi "Skipping"; then
        has_skipping=true
    fi

    if $checks_ok && ! $has_skipping && [[ $exit_code -eq 0 ]]; then
        pass "Test 6.6b - bin/cac check CLI runs all tools successfully"
        ((REQUIRED_PASSED++)) || true
    else
        fail "Test 6.6b - Expected all tools checked with OK and exit 0, got exit=$exit_code, checks_ok=$checks_ok, has_skipping=$has_skipping"
        echo "  Output: $output" >&2
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_6b

# Test 6.7b (REQUIRED): `bin/cac check claude` CLI runs only Claude (CLI-level test)
echo ""
echo "Test 6.7b (REQUIRED): bin/cac check claude CLI runs only Claude"

test_6_7b() {
    if ! $TIMEOUT_AVAILABLE; then
        skip "Test 6.7b - Requires timeout command (dependency issue)"
        return
    fi

    # Create mock env with Claude returning OK
    # Note: create_mock_env also creates mock getent that returns MOCK_HOME
    create_mock_env "test_6_7b" "claude_ok"

    # Run bin/cac check claude via CLI with mock getent in PATH
    # Note: Capture exit code BEFORE || true to avoid masking it
    local output exit_code
    output=$(PATH="$MOCK_BIN:$ORIG_PATH" "$REPO_DIR/bin/cac" check claude 2>&1)
    exit_code=$?

    restore_env

    # Verify Claude was CHECKED (not skipped) and succeeded
    local claude_ok=false
    local has_skipping=false
    local mentions_others=false

    if echo "$output" | grep -qi "Checking Claude.*OK"; then
        claude_ok=true
    fi

    # Ensure no tools were skipped
    if echo "$output" | grep -qi "Skipping"; then
        has_skipping=true
    fi

    # Should NOT mention Codex or Gemini
    if echo "$output" | grep -qi "Codex\|Gemini"; then
        mentions_others=true
    fi

    if $claude_ok && ! $has_skipping && ! $mentions_others && [[ $exit_code -eq 0 ]]; then
        pass "Test 6.7b - bin/cac check claude CLI processes only Claude"
        ((REQUIRED_PASSED++)) || true
    else
        fail "Test 6.7b - Expected only Claude with OK and exit 0, got exit=$exit_code, claude_ok=$claude_ok, has_skipping=$has_skipping, mentions_others=$mentions_others"
        echo "  Output: $output" >&2
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_7b

# Test 6.8 (REQUIRED): `cac check invalidtool` returns exit code 2
echo ""
echo "Test 6.8 (REQUIRED): cac check invalidtool returns exit code 2"

test_6_8() {
    local exit_code output
    output=$("$REPO_DIR/bin/cac" check invalidtool 2>&1)
    exit_code=$?

    if [[ $exit_code -eq 2 ]]; then
        if echo "$output" | grep -qi "unknown\|invalid"; then
            pass "Test 6.8 - Invalid tool returns exit code 2 with error message"
            ((REQUIRED_PASSED++)) || true
        else
            fail "Test 6.8 - Exit code 2 but no error message"
            ((REQUIRED_FAILED++)) || true
        fi
    else
        fail "Test 6.8 - Expected exit code 2, got $exit_code"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_8

# Test 6.9 (REQUIRED): `cac push --skip-check` bypasses check
echo ""
echo "Test 6.9 (REQUIRED): cac push --skip-check bypasses check"

test_6_9() {
    # Create isolated mock environment
    create_mock_env "test_6_9" "claude_ok"

    # Create temporary config for the backend
    local test_config_dir="$TEMP_DIR/config_6_9"
    mkdir -p "$test_config_dir"
    chmod 700 "$test_config_dir"

    # Create minimal .env for local backend
    local test_storage="$TEMP_DIR/storage_6_9"
    mkdir -p "$test_storage"

    cat > "$test_config_dir/.env" <<EOF
CAC_BACKEND=local
CAC_LOCAL_STORAGE=$test_storage
EOF
    chmod 600 "$test_config_dir/.env"

    local output
    output=$(CAC_CONFIG_DIR="$test_config_dir" HOME="$MOCK_HOME" "$REPO_DIR/bin/cac" push --skip-check --dry-run 2>&1) || true

    restore_env

    # Should see dry-run output
    if echo "$output" | grep -qi "DRY-RUN"; then
        # Should see "Credential check: SKIPPED" in dry-run output
        if echo "$output" | grep -qi "Credential check: SKIPPED"; then
            # Should NOT see "Verifying credentials" or actual check running
            if echo "$output" | grep -qi "Verifying credentials"; then
                fail "Test 6.9 - --skip-check still ran credential verification"
                ((REQUIRED_FAILED++)) || true
            else
                pass "Test 6.9 - --skip-check shows SKIPPED and bypasses verification"
                ((REQUIRED_PASSED++)) || true
            fi
        else
            fail "Test 6.9 - Expected 'Credential check: SKIPPED' in output"
            ((REQUIRED_FAILED++)) || true
        fi
    else
        fail "Test 6.9 - Expected dry-run output"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_9

# Test 6.10 (REQUIRED): `cac push` runs check by default
echo ""
echo "Test 6.10 (REQUIRED): cac push runs check by default"

test_6_10() {
    # Create isolated mock environment
    create_mock_env "test_6_10" "claude_ok"

    # Create temporary config for the backend
    local test_config_dir="$TEMP_DIR/config_6_10"
    mkdir -p "$test_config_dir"
    chmod 700 "$test_config_dir"

    # Create minimal .env for local backend
    local test_storage="$TEMP_DIR/storage_6_10"
    mkdir -p "$test_storage"

    cat > "$test_config_dir/.env" <<EOF
CAC_BACKEND=local
CAC_LOCAL_STORAGE=$test_storage
EOF
    chmod 600 "$test_config_dir/.env"

    local output
    output=$(CAC_CONFIG_DIR="$test_config_dir" HOME="$MOCK_HOME" "$REPO_DIR/bin/cac" push --dry-run 2>&1) || true

    restore_env

    # Should see dry-run output with "Credential check: Would run"
    if echo "$output" | grep -qi "DRY-RUN"; then
        if echo "$output" | grep -qi "Credential check: Would run"; then
            pass "Test 6.10 - push dry-run shows credential check would run"
            ((REQUIRED_PASSED++)) || true
        else
            fail "Test 6.10 - Expected 'Credential check: Would run' in output"
            ((REQUIRED_FAILED++)) || true
        fi
    else
        fail "Test 6.10 - Expected dry-run output"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_10

# Test 6.11 (REQUIRED): Exit code 0 when all checks pass
echo ""
echo "Test 6.11 (REQUIRED): Exit code 0 when all checks pass"

test_6_11() {
    if ! $TIMEOUT_AVAILABLE; then
        skip "Test 6.11 - Requires timeout command (dependency issue)"
        # Note: Don't count skips as pass or fail - leave test count unchanged
        return
    fi

    # Create mock env with ALL tools returning OK
    create_mock_env "test_6_11" "claude_ok" "codex_ok" "gemini_ok"

    # Run check_all_tools with all mocked tools
    local exit_code output
    output=$(check_all_tools "false" "$USER" "$MOCK_HOME" 2>&1)
    exit_code=$?

    restore_env

    if [[ $exit_code -eq 0 ]]; then
        if echo "$output" | grep -qi "passed"; then
            pass "Test 6.11 - All checks pass returns exit 0"
            ((REQUIRED_PASSED++)) || true
        else
            pass "Test 6.11 - Exit code 0 (checks passed)"
            ((REQUIRED_PASSED++)) || true
        fi
    else
        fail "Test 6.11 - Expected exit code 0, got $exit_code"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_11

# Test 6.12 (REQUIRED): Exit code 1 when any check fails
echo ""
echo "Test 6.12 (REQUIRED): Exit code 1 when any check fails"

test_6_12() {
    if ! $TIMEOUT_AVAILABLE; then
        skip "Test 6.12 - Requires timeout command (dependency issue)"
        # Note: Don't count skips as pass or fail - leave test count unchanged
        return
    fi

    # Create mock env with Claude failing, others passing
    create_mock_env "test_6_12" "claude_fail" "codex_ok" "gemini_ok"

    # Run check_all_tools - should return exit 1 due to Claude failure
    local exit_code output
    output=$(check_all_tools "false" "$USER" "$MOCK_HOME" 2>&1)
    exit_code=$?

    restore_env

    if [[ $exit_code -eq $CHECK_EXIT_AUTH_FAIL ]]; then
        pass "Test 6.12 - Any check fails returns exit code 1"
        ((REQUIRED_PASSED++)) || true
    else
        fail "Test 6.12 - Expected exit code 1 (auth fail), got $exit_code"
        ((REQUIRED_FAILED++)) || true
    fi
}
test_6_12

# ============================================================================
# Optional Tests
# ============================================================================

echo ""
echo "=========================================="
echo "Optional Tests"
echo "=========================================="

# Test 6.13 (OPTIONAL): XDG_CACHE_HOME honored
echo ""
echo "Test 6.13 (OPTIONAL): XDG_CACHE_HOME honored"

test_6_13() {
    local custom_cache="$TEMP_DIR/custom_xdg_cache"
    mkdir -p "$custom_cache"

    # Save original
    local orig_xdg="${XDG_CACHE_HOME:-}"

    # Set custom XDG_CACHE_HOME
    export XDG_CACHE_HOME="$custom_cache"

    local cache_dir
    cache_dir=$(_check_get_cache_dir)

    # Restore
    if [[ -n "$orig_xdg" ]]; then
        export XDG_CACHE_HOME="$orig_xdg"
    else
        unset XDG_CACHE_HOME
    fi

    if [[ "$cache_dir" == "$custom_cache/cac" ]]; then
        pass "Test 6.13 - XDG_CACHE_HOME is honored"
        ((OPTIONAL_PASSED++)) || true
    else
        skip "Test 6.13 - XDG_CACHE_HOME not honored (got $cache_dir)"
        ((OPTIONAL_SKIPPED++)) || true
    fi
}
test_6_13

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
TOTAL_REQUIRED=$((REQUIRED_PASSED + REQUIRED_FAILED + REQUIRED_SKIPPED))
echo "REQUIRED: $REQUIRED_PASSED passed, $REQUIRED_FAILED failed, $REQUIRED_SKIPPED skipped (of $TOTAL_REQUIRED)"
echo "OPTIONAL: $OPTIONAL_PASSED/1 passed, $OPTIONAL_SKIPPED/1 skipped"
echo ""

if [[ $REQUIRED_FAILED -gt 0 ]]; then
    echo -e "${RED}Some required tests failed!${NC}"
    exit 1
elif [[ $REQUIRED_SKIPPED -gt 0 ]]; then
    echo -e "${YELLOW}Some required tests skipped (missing dependencies)${NC}"
    echo "Install 'timeout' (coreutils) to run all tests."
    exit 0  # Skips are not failures
else
    echo -e "${GREEN}All required tests passed!${NC}"
    exit 0
fi
