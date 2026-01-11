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
        ((TOTAL_PASSED++))
        return 0
    else
        ((TOTAL_FAILED++))
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

    # Run integration tests
    if $run_all || [[ "$filter" == "integration" ]]; then
        if ! run_test_suite "Integration Tests" "test_integration.sh"; then
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
