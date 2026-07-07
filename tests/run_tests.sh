#!/usr/bin/env bash
# tests/run_tests.sh - Run all test suites
#
# Usage: ./tests/run_tests.sh [test_name]
#
# Examples:
#   ./tests/run_tests.sh          # Run all tests
#   ./tests/run_tests.sh bundle   # Run only bundle tests
#   ./tests/run_tests.sh security # Run only security tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_PASSED=0
TOTAL_FAILED=0

run_test_suite() {
    local suite_name="$1"
    local script_name="$2"
    local script_path="${SCRIPT_DIR}/${script_name}"

    if [[ ! -x "$script_path" ]]; then
        echo -e "${YELLOW}SKIP${NC}: $suite_name (not found or not executable)"
        return 0
    fi

    echo -e "${BLUE}Running: $suite_name${NC}"
    echo ""

    if "$script_path"; then
        ((TOTAL_PASSED++)) || true
        return 0
    else
        ((TOTAL_FAILED++)) || true
        return 1
    fi
}

main() {
    local filter="${1:-all}"

    echo "========================================"
    echo "CAC Test Suite Runner"
    echo "========================================"
    echo ""

    local run_all=true
    [[ "$filter" != "all" ]] && run_all=false

    local exit_code=0

    # Run platform tests (Windows/cross-platform compatibility)
    if $run_all || [[ "$filter" == "platform" ]]; then
        if ! run_test_suite "Platform Tests" "test_platform.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run bundle tests
    if $run_all || [[ "$filter" == "bundle" ]]; then
        if ! run_test_suite "Bundle Tests" "test_bundle.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run security tests
    if $run_all || [[ "$filter" == "security" ]]; then
        if ! run_test_suite "Security Tests" "test_security.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run utils tests
    if $run_all || [[ "$filter" == "utils" ]]; then
        if ! run_test_suite "Utils Tests" "test_utils.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run integration tests
    if $run_all || [[ "$filter" == "integration" ]]; then
        if ! run_test_suite "Integration Tests" "test_integration.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run install tests
    if $run_all || [[ "$filter" == "install" ]]; then
        if ! run_test_suite "Install Tests" "test_install.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run env tests (Issue #16)
    if $run_all || [[ "$filter" == "env" ]]; then
        if ! run_test_suite "Environment Tests" "test_env.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Gokapi unit tests
    if $run_all || [[ "$filter" == "gokapi_unit" ]] || [[ "$filter" == "gokapi" ]]; then
        if ! run_test_suite "Gokapi Unit Tests" "test_gokapi_unit.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Gokapi e2e tests
    if $run_all || [[ "$filter" == "gokapi_e2e" ]] || [[ "$filter" == "gokapi" ]]; then
        if ! run_test_suite "Gokapi E2E Tests" "test_gokapi_e2e.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run skill tests
    if $run_all || [[ "$filter" == "skill" ]]; then
        if ! run_test_suite "Skill Tests" "test_skill.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run env settings tests (Issues #39, #40)
    if $run_all || [[ "$filter" == "env_settings" ]] || [[ "$filter" == "env" ]]; then
        if ! run_test_suite "Environment Settings Tests" "test_env_settings.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run uninstall tests
    if $run_all || [[ "$filter" == "uninstall" ]]; then
        if ! run_test_suite "Uninstall Tests" "test_uninstall.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run env check/repair tests (Issue #59)
    if $run_all || [[ "$filter" == "env_check" ]] || [[ "$filter" == "env" ]]; then
        if ! run_test_suite "Environment Check/Repair Tests" "test_env_check.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run update tests (Issue #47)
    if $run_all || [[ "$filter" == "update" ]]; then
        if ! run_test_suite "Update Tests" "test_update.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #79 tests (cac env update auto-escalation for system-wide tools)
    if $run_all || [[ "$filter" == "issue_79" ]] || [[ "$filter" == "79" ]]; then
        if ! run_test_suite "Issue #79 Tests" "test_issue_79.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #76 tests (batch push/pull per-tool bundles)
    if $run_all || [[ "$filter" == "issue_76" ]] || [[ "$filter" == "76" ]]; then
        if ! run_test_suite "Issue #76 Tests" "test_issue_76.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #77 tests (version dirty/draft/clean detection)
    if $run_all || [[ "$filter" == "issue_77" ]] || [[ "$filter" == "77" ]]; then
        if ! run_test_suite "Issue #77 Tests" "test_issue_77.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #81 tests (.claude.json cross-user path rewrite)
    if $run_all || [[ "$filter" == "issue_81" ]] || [[ "$filter" == "81" ]]; then
        if ! run_test_suite "Issue #81 Tests" "test_issue_81.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #82 tests (fast codex probe + pull default-off)
    if $run_all || [[ "$filter" == "issue_82" ]] || [[ "$filter" == "82" ]]; then
        if ! run_test_suite "Issue #82 Tests" "test_issue_82.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    echo "========================================"
    echo "Overall Summary"
    echo "========================================"
    echo "Test suites passed: $TOTAL_PASSED"
    echo "Test suites failed: $TOTAL_FAILED"
    echo ""

    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}All test suites passed!${NC}"
    else
        echo -e "${RED}Some test suites failed.${NC}"
    fi

    exit $exit_code
}

main "$@"
