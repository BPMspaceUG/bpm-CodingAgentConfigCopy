#!/usr/bin/env bash
# Test script for Issues #7, #8, #9
# Execute: ./tests/test_issues_7_8_9.sh
#
# Revised tests addressing Codex feedback (v11-v14):
# v14 changes (Codex feedback 2026-01-18, fourth review):
# - Issue #7: Added Test 7.5 for negative value (-1) handling with warning assertion
# - Issue #7: Added Test 7.6 to verify _gokapi_validate_ttl is called before upload (downstream usage)
# - Issue #8: Added Test 8.2c to explicitly test default Enter (empty input) behavior
#
# v13 changes (Codex feedback 2026-01-18, third review):
# - Issue #9: Test 9.1 design now explicitly requires exactly one non-empty line per block
# - Issue #8: Test 8.4 now requires BOTH error message AND re-prompt (not just OR)
#
# v12 changes (Codex feedback 2026-01-18, second review):
# - Issue #9: Tests 9.1-9.3 now reject lines with #, ;, &&, || (single command only, no comments)
# - Issue #8: Test 8.1 now uses 'script' command for TTY simulation (like Test 8.6)
# - Issue #8: Added XDG_CONFIG_HOME explicit test (8.2b) to verify CONFIG_DIR respects XDG
# - Issue #8: Tests 8.2/8.4 CONFIG_DIR regex tightened to require ending with /cac (not just containing)
#
# v11 changes (Codex feedback 2026-01-18):
# - Issue #7: Tests 7.1/7.2 now require warning to contain "TTL" or "expiry" keyword (not just non-empty stderr)
# - Issue #8: Test 8.1 requires distinct tokens ("this user"/"~/.local" AND "all users"/"requires root")
#   to avoid false positive from "local" matching "/usr/local"
# - Issue #8: Test 8.2/8.4 CONFIG_DIR check accepts XDG_CONFIG_HOME/cac as valid, not just ~/.config/cac
# - Issue #8: Test 8.6 removed static analysis fallback - runtime TTY test only required
#
# v10 changes (preserved):
# - Issue #8: _get_install_functions strips 'set -euo pipefail' to prevent re-enabling strict flags
# - Issue #8: TTY test adds 'set +e +u +o pipefail' after source for belt-and-suspenders safety
# - Issue #8: Tests run in isolated bash subprocesses to avoid side effects from install.sh
# - Issue #8: TTY test uses timeout guard to prevent hanging
# - Issue #8: Error detection broadened (checks behavior, not just keywords)
# - Issue #9: Loosened regex to accept valid install command variants (| bash, | sh, bash <(), etc.)
# - Issue #9: Heading keywords broadened (user/local/non-root/without-sudo, system/root/sudo/all-users)
# - Issue #9: Relaxed heading proximity (heading anywhere before block, not just within 3 lines)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Test counters
PASSED=0
FAILED=0
TOTAL=0
OPTIONAL_PASSED=0
OPTIONAL_FAILED=0
OPTIONAL_TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((PASSED++)) || true
    ((TOTAL++)) || true
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    echo "       Reason: $2"
    ((FAILED++)) || true
    ((TOTAL++)) || true
}

pass_optional() {
    echo -e "${GREEN}PASS${NC}: $1 (optional)"
    ((OPTIONAL_PASSED++)) || true
    ((OPTIONAL_TOTAL++)) || true
}

fail_optional() {
    echo -e "${YELLOW}SKIP${NC}: $1 (optional)"
    echo "       Reason: $2"
    ((OPTIONAL_FAILED++)) || true
    ((OPTIONAL_TOTAL++)) || true
}

header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

# ============================================
# Issue #7 Tests: TTL Enforcement (Behavioral)
# ============================================

test_issue_7() {
    header "Issue #7: TTL Enforcement Tests (Behavioral)"

    local backend_file="${PROJECT_ROOT}/lib/backend_gokapi.sh"

    # Test 7.1: Value > 7 is capped to 7 with warning (REQUIRED)
    echo ""
    echo "Test 7.1 (REQUIRED): Expiry value > 7 is capped to 7 with warning"

    local final_value stderr_output
    local temp_stderr
    temp_stderr=$(mktemp)

    # Capture both stdout (final value) and stderr (warning)
    final_value=$(
        export CAC_GOKAPI_EXPIRY_DAYS=10
        source "${PROJECT_ROOT}/lib/bundle.sh" 2>/dev/null || true
        source "${PROJECT_ROOT}/lib/utils.sh" 2>/dev/null || true
        source "$backend_file" 2>/dev/null
        _gokapi_validate_ttl 2>"$temp_stderr"
        echo "$CAC_GOKAPI_EXPIRY_DAYS"
    )
    stderr_output=$(cat "$temp_stderr")

    # Verify stderr contains TTL-related warning (must mention "TTL" or "expiry" per Codex v11 feedback)
    if [[ "$final_value" == "7" ]] && echo "$stderr_output" | grep -qiE '(TTL|expiry)'; then
        pass "Test 7.1 - Value 10 capped to 7 with TTL warning"
    elif [[ "$final_value" == "7" ]] && [[ -n "$stderr_output" ]]; then
        fail "Test 7.1 - Value 10 capped to 7 with TTL warning" "Warning exists but missing TTL/expiry keyword: $stderr_output"
    elif [[ "$final_value" == "7" ]]; then
        fail "Test 7.1 - Value 10 capped to 7 with TTL warning" "Value capped but no warning emitted to stderr"
    else
        fail "Test 7.1 - Value 10 capped to 7 with TTL warning" "Final value: $final_value (expected 7)"
    fi

    # Test 7.2: Value 0 (unlimited) is treated as 7 with warning (REQUIRED)
    echo ""
    echo "Test 7.2 (REQUIRED): Expiry value 0 (unlimited) is treated as 7 with warning"

    # Clear temp file before test (per Codex feedback)
    : > "$temp_stderr"

    final_value=$(
        export CAC_GOKAPI_EXPIRY_DAYS=0
        source "${PROJECT_ROOT}/lib/bundle.sh" 2>/dev/null || true
        source "${PROJECT_ROOT}/lib/utils.sh" 2>/dev/null || true
        source "$backend_file" 2>/dev/null
        _gokapi_validate_ttl 2>"$temp_stderr"
        echo "$CAC_GOKAPI_EXPIRY_DAYS"
    )
    stderr_output=$(cat "$temp_stderr")

    # Verify stderr contains TTL-related warning (must mention "TTL" or "expiry" per Codex v11 feedback)
    if [[ "$final_value" == "7" ]] && echo "$stderr_output" | grep -qiE '(TTL|expiry)'; then
        pass "Test 7.2 - Value 0 overridden to 7 with TTL warning"
    elif [[ "$final_value" == "7" ]] && [[ -n "$stderr_output" ]]; then
        fail "Test 7.2 - Value 0 overridden to 7 with TTL warning" "Warning exists but missing TTL/expiry keyword: $stderr_output"
    elif [[ "$final_value" == "7" ]]; then
        fail "Test 7.2 - Value 0 overridden to 7 with TTL warning" "Value overridden but no warning emitted to stderr"
    else
        fail "Test 7.2 - Value 0 overridden to 7 with TTL warning" "Final value: $final_value (expected 7)"
    fi

    # Test 7.3: Valid value (1-7) is preserved with NO warning (REQUIRED)
    # Per Codex feedback: assert stderr is empty (no output allowed)
    echo ""
    echo "Test 7.3 (REQUIRED): Valid expiry value 1-7 is preserved with empty stderr"

    # Clear temp file
    : > "$temp_stderr"

    final_value=$(
        export CAC_GOKAPI_EXPIRY_DAYS=5
        source "${PROJECT_ROOT}/lib/bundle.sh" 2>/dev/null || true
        source "${PROJECT_ROOT}/lib/utils.sh" 2>/dev/null || true
        source "$backend_file" 2>/dev/null
        _gokapi_validate_ttl 2>"$temp_stderr"
        echo "$CAC_GOKAPI_EXPIRY_DAYS"
    )
    stderr_output=$(cat "$temp_stderr")

    # Assert stderr is empty for valid values
    if [[ "$final_value" == "5" ]] && [[ -z "$stderr_output" ]]; then
        pass "Test 7.3 - Valid value 5 preserved with empty stderr"
    elif [[ "$final_value" != "5" ]]; then
        fail "Test 7.3 - Valid value 5 preserved with empty stderr" "Final value: $final_value (expected 5)"
    else
        fail "Test 7.3 - Valid value 5 preserved with empty stderr" "Unexpected stderr output: $stderr_output"
    fi

    rm -f "$temp_stderr"

    # Test 7.4: Non-numeric value handling (OPTIONAL - not required by acceptance criteria)
    echo ""
    echo "Test 7.4 (OPTIONAL): Non-numeric value treated as invalid"

    final_value=$(
        export CAC_GOKAPI_EXPIRY_DAYS="abc"
        source "${PROJECT_ROOT}/lib/bundle.sh" 2>/dev/null || true
        source "${PROJECT_ROOT}/lib/utils.sh" 2>/dev/null || true
        source "$backend_file" 2>/dev/null
        _gokapi_validate_ttl 2>/dev/null
        echo "$CAC_GOKAPI_EXPIRY_DAYS"
    )

    if [[ "$final_value" == "7" ]]; then
        pass_optional "Test 7.4 - Invalid value 'abc' replaced with 7"
    else
        fail_optional "Test 7.4 - Invalid value 'abc' replaced with 7" "Final value: $final_value (implementation-defined)"
    fi

    # Test 7.5: Negative value (-1) is treated as non-numeric with warning (REQUIRED per Codex v14)
    # Per Codex feedback: -1 should be detected as non-numeric (fails ^[0-9]+$) and capped to 7 with warning
    echo ""
    echo "Test 7.5 (REQUIRED): Negative value is treated as invalid with warning"

    temp_stderr=$(mktemp)
    final_value=$(
        export CAC_GOKAPI_EXPIRY_DAYS="-1"
        source "${PROJECT_ROOT}/lib/bundle.sh" 2>/dev/null || true
        source "${PROJECT_ROOT}/lib/utils.sh" 2>/dev/null || true
        source "$backend_file" 2>/dev/null
        _gokapi_validate_ttl 2>"$temp_stderr"
        echo "$CAC_GOKAPI_EXPIRY_DAYS"
    )
    stderr_output=$(cat "$temp_stderr")
    rm -f "$temp_stderr"

    # Verify value is capped to 7 AND warning contains TTL/expiry keyword
    if [[ "$final_value" == "7" ]] && echo "$stderr_output" | grep -qiE '(TTL|expiry)'; then
        pass "Test 7.5 - Negative value -1 replaced with 7 with TTL warning"
    elif [[ "$final_value" == "7" ]] && [[ -n "$stderr_output" ]]; then
        fail "Test 7.5 - Negative value -1 replaced with 7 with TTL warning" "Warning exists but missing TTL/expiry keyword: $stderr_output"
    elif [[ "$final_value" == "7" ]]; then
        fail "Test 7.5 - Negative value -1 replaced with 7 with TTL warning" "Value capped but no warning emitted to stderr"
    else
        fail "Test 7.5 - Negative value -1 replaced with 7 with TTL warning" "Final value: $final_value (expected 7)"
    fi

    # Test 7.6: Verify TTL validation is called in upload flow (REQUIRED per Codex v14)
    # Per Codex feedback: Verify _gokapi_validate_ttl is called before upload to ensure capped value is used
    echo ""
    echo "Test 7.6 (REQUIRED): _gokapi_validate_ttl is invoked in backend_gokapi_upload"

    # Static analysis: Check that backend_gokapi_upload calls _gokapi_validate_ttl before curl
    local upload_function
    upload_function=$(sed -n '/^backend_gokapi_upload()/,/^}/p' "$backend_file")

    # Verify _gokapi_validate_ttl is called in the upload function
    if echo "$upload_function" | grep -q '_gokapi_validate_ttl'; then
        # Verify it's called before the curl/API request (expiryDays usage)
        local ttl_line api_line
        ttl_line=$(echo "$upload_function" | grep -n '_gokapi_validate_ttl' | head -1 | cut -d: -f1)
        api_line=$(echo "$upload_function" | grep -n 'expiryDays=' | head -1 | cut -d: -f1)

        if [[ -n "$ttl_line" && -n "$api_line" && "$ttl_line" -lt "$api_line" ]]; then
            pass "Test 7.6 - _gokapi_validate_ttl called before expiryDays usage in upload"
        else
            fail "Test 7.6 - _gokapi_validate_ttl called before expiryDays usage" "TTL validation at line $ttl_line, expiryDays at line $api_line"
        fi
    else
        fail "Test 7.6 - _gokapi_validate_ttl called in upload" "_gokapi_validate_ttl not found in backend_gokapi_upload"
    fi
}

# ============================================
# Issue #8 Tests: Install Prompt (Behavioral)
# ============================================

# Helper: Extract install.sh functions without the final main call and without set -euo pipefail
# This allows tests to source the functions without strict shell options causing exits
# Per Codex feedback: strip 'set -euo pipefail' to prevent re-enabling strict flags after source
_get_install_functions() {
    local install_file="$1"
    # Remove:
    # 1. Any line that starts with main (with optional leading whitespace)
    # 2. The 'set -euo pipefail' line that would re-enable strict flags
    sed -E \
        -e '/^[[:space:]]*main([[:space:]]+.*)?([[:space:]]*#.*)?$/d' \
        -e '/^[[:space:]]*set[[:space:]]+-[euo]*[[:space:]]*pipefail/d' \
        -e '/^[[:space:]]*set[[:space:]]+-euo[[:space:]]+pipefail/d' \
        "$install_file"
}

test_issue_8() {
    header "Issue #8: Install Script Prompt Tests (Behavioral)"

    local install_file="${PROJECT_ROOT}/install.sh"
    local temp_install="${PROJECT_ROOT}/.test_install_temp.sh"

    # Create temp script once for all tests (stripped of main call)
    _get_install_functions "$install_file" > "$temp_install" 2>/dev/null

    # Test 8.1: Interactive prompt shows install type options
    # Per Codex v12 feedback: Use 'script' command for TTY simulation (like Test 8.6)
    echo ""
    echo "Test 8.1 (REQUIRED): Install type prompt shown to user"

    local prompt_output
    local tty_timeout=5  # 5 second timeout to prevent hanging

    if ! command -v script &>/dev/null || ! command -v timeout &>/dev/null; then
        fail "Test 8.1 - Install type prompt shows user-local and system-wide options" "Required commands 'script' and 'timeout' not available for TTY test"
    else
        # Use 'script' to simulate TTY like Test 8.6
        prompt_output=$(
            timeout "$tty_timeout" script -q -c "bash -c '
                source \"$temp_install\" 2>/dev/null
                set +e +u +o pipefail
                prompt_install_type
            '" /dev/null <<< "1" 2>&1
        ) || true  # Don't fail on timeout

        # Check that the prompt shows both options (user-local and system-wide)
        # Per Codex v11 feedback: "local" false-positives on "/usr/local", require distinct tokens:
        # - User-local: "this user" or "~/.local" (not just "local")
        # - System-wide: "all users" or "requires root" (not just "system")
        if echo "$prompt_output" | grep -qiE '(this user|~/\.local)' && \
           echo "$prompt_output" | grep -qiE '(all users|requires root|/usr/local)'; then
            pass "Test 8.1 - Install type prompt shows user-local and system-wide options"
        else
            fail "Test 8.1 - Install type prompt shows user-local and system-wide options" "Expected distinct user-local ('this user'/'~/.local') AND system-wide ('all users'/'requires root') tokens"
        fi
    fi

    # Test 8.2: Selection "1" results in user-local paths (all path variables)
    # Runs in isolated subprocess to avoid side effects
    echo ""
    echo "Test 8.2 (REQUIRED): Selection '1' uses user-local paths"

    local paths_after_1
    paths_after_1=$(
        bash -c "
            set +eu
            source '$temp_install' 2>/dev/null
            prompt_install_type
            echo \"BIN_DIR=\${BIN_DIR:-unset}\"
            echo \"LIB_DIR=\${LIB_DIR:-unset}\"
            echo \"CONFIG_DIR=\${CONFIG_DIR:-unset}\"
            echo \"INSTALL_MODE=\${INSTALL_MODE:-unset}\"
        " <<< "1" 2>/dev/null
    )

    # Verify ALL path variables are set to user-local paths
    # Per Codex v11 feedback: Accept XDG_CONFIG_HOME/cac as valid CONFIG_DIR
    # Valid CONFIG_DIR patterns:
    # - ${XDG_CONFIG_HOME}/cac (respects XDG)
    # - ~/.config/cac (default XDG)
    # - /home/<user>/.config/cac (expanded home)
    # Explicitly reject system paths like /etc/cac
    # Per Codex v12 feedback: CONFIG_DIR must END with /cac (not just contain it)
    if echo "$paths_after_1" | grep -q 'BIN_DIR=.*\.local' && \
       echo "$paths_after_1" | grep -q 'LIB_DIR=.*\.local' && \
       echo "$paths_after_1" | grep -qE 'CONFIG_DIR=.*/cac$' && \
       ! echo "$paths_after_1" | grep -q 'CONFIG_DIR=.*/etc' && \
       echo "$paths_after_1" | grep -qi 'INSTALL_MODE=.*user'; then
        pass "Test 8.2 - Selection 1 uses user-local paths (BIN_DIR, LIB_DIR, CONFIG_DIR)"
    else
        fail "Test 8.2 - Selection 1 uses user-local paths" "Got: $paths_after_1"
    fi

    # Test 8.2b (REQUIRED): XDG_CONFIG_HOME is respected when set
    # Per Codex v12 feedback: Explicitly test that CONFIG_DIR equals XDG_CONFIG_HOME/cac
    echo ""
    echo "Test 8.2b (REQUIRED): XDG_CONFIG_HOME is respected for CONFIG_DIR"

    local xdg_temp_dir
    xdg_temp_dir=$(mktemp -d)
    local xdg_config_output
    xdg_config_output=$(
        bash -c "
            set +eu
            export XDG_CONFIG_HOME='$xdg_temp_dir'
            source '$temp_install' 2>/dev/null
            prompt_install_type
            echo \"CONFIG_DIR=\${CONFIG_DIR:-unset}\"
        " <<< "1" 2>/dev/null
    )
    rm -rf "$xdg_temp_dir"

    # Verify CONFIG_DIR is exactly XDG_CONFIG_HOME/cac
    if echo "$xdg_config_output" | grep -q "CONFIG_DIR=${xdg_temp_dir}/cac"; then
        pass "Test 8.2b - CONFIG_DIR respects XDG_CONFIG_HOME (${xdg_temp_dir}/cac)"
    else
        fail "Test 8.2b - CONFIG_DIR respects XDG_CONFIG_HOME" "Expected CONFIG_DIR=${xdg_temp_dir}/cac, got: $xdg_config_output"
    fi

    # Test 8.2c (REQUIRED): Default Enter (empty input) defaults to user-local paths
    # Per Codex v14 feedback: Explicitly test that empty input (just pressing Enter) defaults to "1"
    echo ""
    echo "Test 8.2c (REQUIRED): Default Enter (empty input) defaults to user-local paths"

    local default_enter_output
    default_enter_output=$(
        bash -c "
            set +eu
            source '$temp_install' 2>/dev/null
            prompt_install_type
            echo \"BIN_DIR=\${BIN_DIR:-unset}\"
            echo \"LIB_DIR=\${LIB_DIR:-unset}\"
            echo \"CONFIG_DIR=\${CONFIG_DIR:-unset}\"
            echo \"INSTALL_MODE=\${INSTALL_MODE:-unset}\"
        " <<< "" 2>/dev/null
    )

    # Verify empty input defaults to user-local paths (same as selection "1")
    if echo "$default_enter_output" | grep -q 'BIN_DIR=.*\.local' && \
       echo "$default_enter_output" | grep -q 'LIB_DIR=.*\.local' && \
       echo "$default_enter_output" | grep -qE 'CONFIG_DIR=.*/cac$' && \
       ! echo "$default_enter_output" | grep -q 'CONFIG_DIR=.*/etc' && \
       echo "$default_enter_output" | grep -qi 'INSTALL_MODE=.*user'; then
        pass "Test 8.2c - Default Enter uses user-local paths (same as selection '1')"
    else
        fail "Test 8.2c - Default Enter uses user-local paths" "Got: $default_enter_output"
    fi

    # Test 8.3: Selection "2" as root uses system-wide paths (all path variables)
    # Runs in isolated subprocess with mocked is_root
    echo ""
    echo "Test 8.3 (REQUIRED): Selection '2' as root uses system-wide paths"

    local paths_after_2_root
    paths_after_2_root=$(
        bash -c "
            set +eu
            source '$temp_install' 2>/dev/null
            is_root() { return 0; }  # Mock root
            prompt_install_type
            echo \"BIN_DIR=\${BIN_DIR:-unset}\"
            echo \"LIB_DIR=\${LIB_DIR:-unset}\"
            echo \"CONFIG_DIR=\${CONFIG_DIR:-unset}\"
            echo \"INSTALL_MODE=\${INSTALL_MODE:-unset}\"
        " <<< "2" 2>/dev/null
    )

    # Verify ALL path variables are set to system-wide paths
    if echo "$paths_after_2_root" | grep -q 'BIN_DIR=.*/usr/local' && \
       echo "$paths_after_2_root" | grep -q 'LIB_DIR=.*/usr/local' && \
       echo "$paths_after_2_root" | grep -q 'CONFIG_DIR=.*/etc' && \
       echo "$paths_after_2_root" | grep -qi 'INSTALL_MODE=.*system'; then
        pass "Test 8.3 - Selection 2 as root uses system-wide paths (BIN_DIR, LIB_DIR, CONFIG_DIR)"
    else
        fail "Test 8.3 - Selection 2 as root uses system-wide paths" "Got: $paths_after_2_root"
    fi

    # Test 8.4: Selection "2" as non-root shows error AND subsequent "1" sets user-local paths
    # Also verify system paths were NOT set after failed "2" selection (negative assertions)
    # Runs in isolated subprocess with mocked non-root
    echo ""
    echo "Test 8.4 (REQUIRED): Selection '2' as non-root shows error, then '1' sets user-local paths"

    local combined_output
    combined_output=$(
        bash -c "
            set +eu
            source '$temp_install' 2>/dev/null
            is_root() { return 1; }  # Mock non-root
            prompt_install_type
            echo \"FINAL_BIN_DIR=\${BIN_DIR:-unset}\"
            echo \"FINAL_LIB_DIR=\${LIB_DIR:-unset}\"
            echo \"FINAL_CONFIG_DIR=\${CONFIG_DIR:-unset}\"
            echo \"FINAL_INSTALL_MODE=\${INSTALL_MODE:-unset}\"
        " <<< $'2\n1' 2>&1
    )

    # Verify behavior: prompt looped (selection asked twice) AND final paths are user-local
    # Error detection is behavior-based: if non-root selects option 2 and loop continues,
    # then rejection occurred. We verify:
    # 1. Selection prompt appeared at least twice (indicating rejection and retry)
    # 2. Final paths are user-local (correct fallback behavior)
    # 3. System paths were NOT used (negative assertions per Codex feedback)
    local has_loop=0 has_user_paths=0 no_system_paths=0

    # Check for BOTH error message AND re-prompt (per Codex v13 feedback)
    # 1. Error message must contain root/privilege/sudo/permission keywords
    # 2. Prompt must appear at least twice (indicating re-prompt occurred)
    local prompt_count has_error=0
    prompt_count=$(echo "$combined_output" | grep -ciE '(select.*install|choice|this user.*all users)' || echo 0)
    if echo "$combined_output" | grep -qiE '(root|privilege|sudo|permission|require).*install|system.*require'; then
        has_error=1
    fi
    # Require BOTH error message AND re-prompt (not just one)
    if [[ "$prompt_count" -ge 2 ]] && [[ "$has_error" -eq 1 ]]; then
        has_loop=1
    fi

    # Positive assertions: final paths are user-local
    # Per Codex v11 feedback: Accept XDG_CONFIG_HOME/cac as valid CONFIG_DIR
    # Per Codex v12 feedback: CONFIG_DIR must END with /cac (not just contain it)
    # Explicitly reject system paths like /etc/cac
    if echo "$combined_output" | grep -q 'FINAL_BIN_DIR=.*\.local' && \
       echo "$combined_output" | grep -q 'FINAL_LIB_DIR=.*\.local' && \
       echo "$combined_output" | grep -qE 'FINAL_CONFIG_DIR=.*/cac$' && \
       ! echo "$combined_output" | grep -q 'FINAL_CONFIG_DIR=.*/etc' && \
       echo "$combined_output" | grep -qi 'FINAL_INSTALL_MODE=.*user'; then
        has_user_paths=1
    fi

    # Negative assertions: system paths were NOT used
    if ! echo "$combined_output" | grep -q 'FINAL_BIN_DIR=.*/usr/local' && \
       ! echo "$combined_output" | grep -q 'FINAL_LIB_DIR=.*/usr/local' && \
       ! echo "$combined_output" | grep -q 'FINAL_CONFIG_DIR=.*/etc' && \
       ! echo "$combined_output" | grep -qi 'FINAL_INSTALL_MODE=.*system'; then
        no_system_paths=1
    fi

    if [[ "$has_loop" -eq 1 && "$has_user_paths" -eq 1 && "$no_system_paths" -eq 1 ]]; then
        pass "Test 8.4 - Selection 2 as non-root triggers re-prompt, then '1' sets user-local paths (not system)"
    else
        fail "Test 8.4 - Selection 2 as non-root triggers re-prompt, then '1' sets user-local paths" "Re-prompt: $has_loop, user-paths: $has_user_paths, no-system-paths: $no_system_paths"
    fi

    # Test 8.4b: Invalid input handling - garbage input should re-prompt
    echo ""
    echo "Test 8.4b (REQUIRED): Invalid input triggers re-prompt, then valid '1' sets paths"

    local invalid_input_output
    invalid_input_output=$(
        bash -c "
            set +eu
            source '$temp_install' 2>/dev/null
            is_root() { return 1; }  # Mock non-root
            prompt_install_type
            echo \"FINAL_BIN_DIR=\${BIN_DIR:-unset}\"
            echo \"FINAL_INSTALL_MODE=\${INSTALL_MODE:-unset}\"
        " <<< $'x\n1' 2>&1
    )

    # Check that invalid input triggered re-prompt (prompt appeared twice) and final paths are user-local
    local invalid_reprompt=0 invalid_final_ok=0
    prompt_count=$(echo "$invalid_input_output" | grep -ciE '(select.*install|choice|this user)' || echo 0)
    if [[ "$prompt_count" -ge 2 ]] || echo "$invalid_input_output" | grep -qiE '(invalid|enter 1 or 2)'; then
        invalid_reprompt=1
    fi

    if echo "$invalid_input_output" | grep -q 'FINAL_BIN_DIR=.*\.local' && \
       echo "$invalid_input_output" | grep -qi 'FINAL_INSTALL_MODE=.*user'; then
        invalid_final_ok=1
    fi

    if [[ "$invalid_reprompt" -eq 1 && "$invalid_final_ok" -eq 1 ]]; then
        pass "Test 8.4b - Invalid input 'x' triggers re-prompt, then '1' sets user-local paths"
    else
        fail "Test 8.4b - Invalid input triggers re-prompt" "Re-prompt: $invalid_reprompt, final-ok: $invalid_final_ok"
    fi

    # Test 8.5 (OPTIONAL): Non-interactive mode auto-detects based on root status
    # Runs in isolated subprocess with non-interactive stdin
    echo ""
    echo "Test 8.5 (OPTIONAL): Non-interactive mode auto-detects paths"

    local non_interactive_paths
    non_interactive_paths=$(
        bash -c "
            set +eu
            source '$temp_install' 2>/dev/null
            is_root() { return 1; }  # Mock non-root
            set_install_paths </dev/null
            echo \"INSTALL_MODE=\${INSTALL_MODE:-unset}\"
        " 2>/dev/null
    )

    if echo "$non_interactive_paths" | grep -qi 'INSTALL_MODE=.*user'; then
        pass_optional "Test 8.5 - Non-interactive non-root uses user-local paths"
    else
        fail_optional "Test 8.5 - Non-interactive non-root uses user-local paths" "Got: $non_interactive_paths (backward compatibility)"
    fi

    # Test 8.6: Verify set_install_paths shows prompt in interactive (TTY) mode
    # Per Codex v11 feedback: Removed static analysis fallback - require runtime TTY test only
    # Uses 'script' command with timeout guard to prevent hanging
    echo ""
    echo "Test 8.6 (REQUIRED): set_install_paths invokes prompt in interactive mode"

    local tty_test_output
    local tty_timeout=5  # 5 second timeout to prevent hanging

    # Runtime TTY test required (no static analysis fallback per Codex v11)
    if ! command -v script &>/dev/null || ! command -v timeout &>/dev/null; then
        fail "Test 8.6 - set_install_paths shows prompt in interactive mode" "Required commands 'script' and 'timeout' not available for TTY test"
    else
        # Use 'timeout' to guard against hanging, 'script' to simulate TTY
        # Per Codex feedback: neutralize any strict flags after source
        tty_test_output=$(
            timeout "$tty_timeout" script -q -c "bash -c '
                source \"$temp_install\" 2>/dev/null
                set +e +u +o pipefail
                set_install_paths
            '" /dev/null <<< "1" 2>&1
        ) || true  # Don't fail on timeout

        # Verify prompt appeared (should show install type options with distinct tokens)
        if echo "$tty_test_output" | grep -qiE '(this user|all users)'; then
            pass "Test 8.6 - set_install_paths shows prompt in interactive mode (verified with TTY)"
        else
            fail "Test 8.6 - set_install_paths shows prompt in interactive mode" "TTY test: prompt not detected. Output: $(echo "$tty_test_output" | head -c 200)"
        fi
    fi

    # Clean up temp file
    rm -f "$temp_install" 2>/dev/null
}

# ============================================
# Issue #9 Tests: Documentation (Global Search)
# ============================================

test_issue_9() {
    header "Issue #9: Documentation Copyable Commands Tests"

    local readme="${PROJECT_ROOT}/README.md"

    # Test 9.1: At least two separate code blocks exist for install commands,
    # each containing ONLY the install command (no extra lines/comments)
    echo ""
    echo "Test 9.1 (REQUIRED): Separate code blocks for install commands (isolated)"

    # Count distinct code blocks that contain exactly one install command and nothing else
    # A valid install block has: opening fence, single curl-based install line, closing fence
    # Per Codex v12 feedback: Reject lines with #, ;, &&, || (single command only, no comments)
    # Accepts various valid forms:
    #   - curl ... | bash
    #   - curl ... | sh
    #   - curl ... | sudo bash
    #   - curl ... | bash -s --
    #   - bash <(curl ...)
    #   - sh <(curl ...)
    local install_blocks
    install_blocks=$(awk '
        /^```/ {
            if (in_block) {
                # Check if block had exactly one install command and no other non-empty content
                # Also verify no extra operators/comments were present
                if (has_install_cmd && line_count == 1 && !has_extra_content) block_count++
                in_block=0
                has_install_cmd=0
                has_extra_content=0
                line_count=0
            } else {
                in_block=1
                has_install_cmd=0
                has_extra_content=0
                line_count=0
            }
            next
        }
        in_block {
            # Skip empty lines
            if (/^[[:space:]]*$/) next
            line_count++
            # Reject lines with comments (#), semicolons (;), && or || operators
            # These indicate extra content beyond a single command
            if (/#/ || /;/ || /&&/ || /\|\|/) has_extra_content=1
            # Match various valid install command forms
            # Form 1: curl ... | [sudo] bash (or sh) - allow anything between | and bash/sh
            if (/curl.*install\.sh.*\|/ && /(^|[[:space:]])(ba)?sh([[:space:]]|$)/) has_install_cmd=1
            # Form 2: bash <(curl ...) or sh <(curl ...)
            if (/(^|[[:space:]])(ba)?sh[[:space:]]+<\(curl.*install\.sh/) has_install_cmd=1
        }
        END { print block_count }
    ' "$readme")

    if [[ "$install_blocks" -ge 2 ]]; then
        pass "Test 9.1 - At least 2 isolated install command blocks found ($install_blocks)"
    else
        fail "Test 9.1 - At least 2 isolated install command blocks found" "Only $install_blocks isolated block(s)"
    fi

    # Test 9.2: A heading exists before user-local install command (non-sudo)
    # Heading must be OUTSIDE code blocks, precede the code block, and contain "User" or "Local"
    # Relaxed: heading can be anywhere before the block in the same section (until next heading of same or higher level)
    echo ""
    echo "Test 9.2 (REQUIRED): Heading precedes user-local (non-sudo) install command"

    local found_user_local_with_heading
    found_user_local_with_heading=$(awk '
        # Track headings when NOT inside a code block
        # Verify heading text matches user-local pattern
        # Broadened to accept: user, local, non-root, without sudo, no root, rootless
        !in_block && /^#+/ {
            last_heading = NR
            heading_text = tolower($0)
            # Check if heading mentions user/local install type (case-insensitive)
            # Expanded keywords per Codex feedback
            heading_matches_user = (heading_text ~ /user|local|non-root|without sudo|no root|rootless|no-sudo/)
        }
        /^```/ {
            if (in_block) {
                in_block=0
                # Check if this block was user-local (has install cmd, no sudo)
                # Also verify it contains only one non-empty line (isolated)
                # Per Codex v12: Also verify no extra content (#, ;, &&, ||)
                # Ensure a heading was seen (last_heading > 0) and block_start > last_heading
                # Relaxed: no strict line proximity requirement - just needs heading before block
                if (has_install_cmd && !has_sudo && !has_extra_content && line_count == 1 && last_heading > 0 && block_start > last_heading && heading_matches_user) {
                    print "FOUND"
                    exit
                }
                has_install_cmd=0
                has_sudo=0
                has_extra_content=0
                line_count=0
            } else {
                in_block=1
                block_start=NR
                has_install_cmd=0
                has_sudo=0
                has_extra_content=0
                line_count=0
            }
            next
        }
        in_block {
            if (/^[[:space:]]*$/) next
            line_count++
            # Reject lines with comments (#), semicolons (;), && or || operators
            if (/#/ || /;/ || /&&/ || /\|\|/) has_extra_content=1
            # Match various valid install command forms
            # Form 1: curl ... | [sudo] bash/sh
            if (/curl.*install\.sh.*\|/ && /(^|[[:space:]])(ba)?sh([[:space:]]|$)/) has_install_cmd=1
            # Form 2: bash/sh <(curl ...)
            if (/(^|[[:space:]])(ba)?sh[[:space:]]+<\(curl.*install\.sh/) has_install_cmd=1
            if (/sudo/) has_sudo=1
        }
    ' "$readme")

    if [[ "$found_user_local_with_heading" == "FOUND" ]]; then
        pass "Test 9.2 - Heading with 'User'/'Local' precedes isolated user-local install block"
    else
        fail "Test 9.2 - Heading with 'User'/'Local' precedes isolated user-local install block" "No isolated user-local block found with matching heading"
    fi

    # Test 9.3: A heading exists before system-wide install command (with sudo)
    # Heading must contain "System" or "Root" (per Codex feedback)
    # Relaxed: heading can be anywhere before the block in the same section
    echo ""
    echo "Test 9.3 (REQUIRED): Heading precedes system-wide (sudo) install command"

    local found_system_wide_with_heading
    found_system_wide_with_heading=$(awk '
        # Track headings when NOT inside a code block
        # Verify heading text matches system-wide pattern
        # Broadened to accept: system, root, all users, global, sudo, system-wide
        !in_block && /^#+/ {
            last_heading = NR
            heading_text = tolower($0)
            # Check if heading mentions system/root install type (case-insensitive)
            # Expanded keywords per Codex feedback
            heading_matches_system = (heading_text ~ /system|root|all users|global|sudo|system-wide|with sudo/)
        }
        /^```/ {
            if (in_block) {
                in_block=0
                # Check if this block was system-wide (has install cmd + sudo)
                # Also verify it contains only one non-empty line (isolated)
                # Per Codex v12: Also verify no extra content (#, ;, &&, ||)
                # Ensure a heading was seen (last_heading > 0) and block_start > last_heading
                # Relaxed: no strict line proximity requirement - just needs heading before block
                if (has_install_cmd && has_sudo && !has_extra_content && line_count == 1 && last_heading > 0 && block_start > last_heading && heading_matches_system) {
                    print "FOUND"
                    exit
                }
                has_install_cmd=0
                has_sudo=0
                has_extra_content=0
                line_count=0
            } else {
                in_block=1
                block_start=NR
                has_install_cmd=0
                has_sudo=0
                has_extra_content=0
                line_count=0
            }
            next
        }
        in_block {
            if (/^[[:space:]]*$/) next
            line_count++
            # Reject lines with comments (#), semicolons (;), && or || operators
            if (/#/ || /;/ || /&&/ || /\|\|/) has_extra_content=1
            # Match various valid install command forms
            # Form 1: curl ... | [sudo] bash/sh
            if (/curl.*install\.sh.*\|/ && /(^|[[:space:]])(ba)?sh([[:space:]]|$)/) has_install_cmd=1
            # Form 2: bash/sh <(curl ...)
            if (/(^|[[:space:]])(ba)?sh[[:space:]]+<\(curl.*install\.sh/) has_install_cmd=1
            if (/sudo/) has_sudo=1
        }
    ' "$readme")

    if [[ "$found_system_wide_with_heading" == "FOUND" ]]; then
        pass "Test 9.3 - Heading with 'System'/'Root' precedes isolated system-wide install block"
    else
        fail "Test 9.3 - Heading with 'System'/'Root' precedes isolated system-wide install block" "No isolated system-wide block found with matching heading"
    fi
}

# ============================================
# Main
# ============================================

main() {
    echo "============================================"
    echo "Test Execution: Issues #7, #8, #9"
    echo "============================================"
    echo "Date: $(date)"
    echo "Project: ${PROJECT_ROOT}"

    test_issue_7
    test_issue_8
    test_issue_9

    header "Summary"
    echo "REQUIRED: ${PASSED}/${TOTAL} passed, ${FAILED}/${TOTAL} failed"
    echo "OPTIONAL: ${OPTIONAL_PASSED}/${OPTIONAL_TOTAL} passed, ${OPTIONAL_FAILED}/${OPTIONAL_TOTAL} skipped"

    if [[ $FAILED -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}Note: Failed REQUIRED tests indicate missing acceptance criteria${NC}"
    fi

    # Return appropriate exit code (only REQUIRED tests affect exit code)
    if [[ $FAILED -gt 0 ]]; then
        return 1
    fi
    return 0
}

main "$@"
