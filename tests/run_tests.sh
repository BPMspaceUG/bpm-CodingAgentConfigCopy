#!/usr/bin/env bash
# tests/run_tests.sh - Run all test suites
#
# Usage: ./tests/run_tests.sh [test_name]
#
# Examples:
#   ./tests/run_tests.sh          # Run all tests
#   ./tests/run_tests.sh bundle   # Run only bundle tests
#   ./tests/run_tests.sh security # Run only security tests
#   ./tests/run_tests.sh 141      # Run the suite registered under issue key 141
#
# A filter that selects no registered suite prints "no suite matches '<filter>'"
# and exits 2 (#155).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test lock (#153): <git-dir>/cac-tests.lock holds this run's PID while it runs.
# .claude/hooks/block-git-during-tests.sh reads it and refuses git commands that
# change the working tree (stash, checkout, ...) while a live run holds it, so
# the run cannot end up testing a different tree. Outside a git repo (e.g. a
# copied tree in a container) there is nothing to protect and no lock.
TEST_LOCK=""
_release_test_lock() {
    if [[ -n "$TEST_LOCK" && "$(cat "$TEST_LOCK" 2>/dev/null)" == "$$" ]]; then
        rm -f "$TEST_LOCK"
    fi
}
# A second run started while a live one holds the lock leaves it alone: if it
# took the lock over and ended first, the first run would be unprotected.
_take_test_lock() {
    local lock="$1" holder
    trap _release_test_lock EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ( set -o noclobber; echo "$$" > "$lock" ) 2>/dev/null; then
        TEST_LOCK="$lock"; return 0
    fi
    holder="$(tr -d '[:space:]' < "$lock" 2>/dev/null)"
    if [[ "$holder" =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
        echo "Note: test run PID ${holder} already holds ${lock}; this run does not take it."
        return 0
    fi
    echo "$$" > "$lock"     # stale lock from a dead run
    TEST_LOCK="$lock"
}
if git_dir="$(git -C "$SCRIPT_DIR" rev-parse --absolute-git-dir 2>/dev/null)"; then
    _take_test_lock "${git_dir}/cac-tests.lock"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_PASSED=0
TOTAL_FAILED=0
# Suites the filter selected, counted before they run (#155): a filter that
# selects none is a typo or a stale key, not a passing run.
SUITES_SELECTED=0

run_test_suite() {
    local suite_name="$1"
    local script_name="$2"
    local script_path="${SCRIPT_DIR}/${script_name}"

    ((SUITES_SELECTED++)) || true

    # A suite named here is a contract: it is expected to exist AND to run.
    # Both conditions below used to share one SKIP message that exited 0, which
    # is how tests/test_platform.sh stayed unexecuted for months (#107). They are
    # now reported separately and both FAIL the run.
    if [[ ! -e "$script_path" ]]; then
        echo -e "${RED}MISSING${NC}: $suite_name (${script_path} does not exist)"
        ((TOTAL_FAILED++)) || true
        return 1
    fi

    if [[ ! -x "$script_path" ]]; then
        echo -e "${RED}NOT EXECUTABLE${NC}: $suite_name (chmod +x ${script_path})"
        ((TOTAL_FAILED++)) || true
        return 1
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

    # Run Issue #131 tests (authenticated GitHub API calls, rate-limit message)
    if $run_all || [[ "$filter" == "issue_131" ]] || [[ "$filter" == "131" ]]; then
        if ! run_test_suite "Issue #131 Tests" "test_issue_131.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #132 tests (env-update hint and tool report after cac update)
    if $run_all || [[ "$filter" == "issue_132" ]] || [[ "$filter" == "132" ]]; then
        if ! run_test_suite "Issue #132 Tests" "test_issue_132.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #133 tests (unreachable root copy refused before the installer)
    if $run_all || [[ "$filter" == "issue_133" ]] || [[ "$filter" == "133" ]]; then
        if ! run_test_suite "Issue #133 Tests" "test_issue_133.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #137 tests (failed curl installer is a failed install)
    if $run_all || [[ "$filter" == "issue_137" ]] || [[ "$filter" == "137" ]]; then
        if ! run_test_suite "Issue #137 Tests" "test_issue_137.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #148 tests (a launcher cac does not manage is skipped, not refused)
    if $run_all || [[ "$filter" == "issue_148" ]] || [[ "$filter" == "148" ]]; then
        if ! run_test_suite "Issue #148 Tests" "test_issue_148.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #150 tests (lint is readable as pass/fail: no SC2329 in tests/)
    if $run_all || [[ "$filter" == "issue_150" ]] || [[ "$filter" == "150" ]]; then
        if ! run_test_suite "Issue #150 Tests" "test_issue_150.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #152 tests (install.sh names the suites that extract its functions)
    if $run_all || [[ "$filter" == "issue_152" ]] || [[ "$filter" == "152" ]]; then
        if ! run_test_suite "Issue #152 Tests" "test_issue_152.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #153 tests (git stash/checkout/... blocked while tests run)
    if $run_all || [[ "$filter" == "issue_153" ]] || [[ "$filter" == "153" ]]; then
        if ! run_test_suite "Issue #153 Tests" "test_issue_153.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #155 tests (a filter that matches no suite fails the run)
    if $run_all || [[ "$filter" == "issue_155" ]] || [[ "$filter" == "155" ]]; then
        if ! run_test_suite "Issue #155 Tests" "test_issue_155.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #156 tests (every env root check goes through _env_is_root)
    if $run_all || [[ "$filter" == "issue_156" ]] || [[ "$filter" == "156" ]]; then
        if ! run_test_suite "Issue #156 Tests" "test_issue_156.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #127 tests (trailing slash in CAC_GOKAPI_URL, no // in request URLs)
    if $run_all || [[ "$filter" == "issue_127" ]] || [[ "$filter" == "127" ]]; then
        if ! run_test_suite "Issue #127 Tests" "test_issue_127.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #157 tests (package-owner parser against real dpkg/rpm/apk output)
    if $run_all || [[ "$filter" == "issue_157" ]] || [[ "$filter" == "157" ]]; then
        if ! run_test_suite "Issue #157 Tests" "test_issue_157.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #136 tests (foreign bundle merges .claude.json instead of replacing it)
    if $run_all || [[ "$filter" == "issue_136" ]] || [[ "$filter" == "136" ]]; then
        if ! run_test_suite "Issue #136 Tests" "test_issue_136.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #119 tests (env install --tmux without tmux no longer aborts)
    if $run_all || [[ "$filter" == "issue_119" ]] || [[ "$filter" == "119" ]]; then
        if ! run_test_suite "Issue #119 Tests" "test_issue_119.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #140 tests (version string is the UTC committer date)
    if $run_all || [[ "$filter" == "issue_140" ]] || [[ "$filter" == "140" ]]; then
        if ! run_test_suite "Issue #140 Tests" "test_issue_140.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #141 tests (stale Claude session on pull/check)
    if $run_all || [[ "$filter" == "issue_141" ]] || [[ "$filter" == "141" ]]; then
        if ! run_test_suite "Issue #141 Tests" "test_issue_141.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #142 tests (cac check without a TTY)
    if $run_all || [[ "$filter" == "issue_142" ]] || [[ "$filter" == "142" ]]; then
        if ! run_test_suite "Issue #142 Tests" "test_issue_142.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #143 tests (fail() inside run_test turns the test red)
    if $run_all || [[ "$filter" == "issue_143" ]] || [[ "$filter" == "143" ]]; then
        if ! run_test_suite "Issue #143 Tests" "test_issue_143.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #146 tests (pull --all applies the newest bundle per tool)
    if $run_all || [[ "$filter" == "issue_146" ]] || [[ "$filter" == "146" ]]; then
        if ! run_test_suite "Issue #146 Tests" "test_issue_146.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #80 tests (opencode registry + check wiring)
    if $run_all || [[ "$filter" == "issue_80" ]] || [[ "$filter" == "80" ]]; then
        if ! run_test_suite "Issue #80 Tests" "test_issue_80.sh"; then
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

    # Run Issue #84 tests (cac check all routes to check_all_tools)
    if $run_all || [[ "$filter" == "issue_84" ]] || [[ "$filter" == "84" ]]; then
        if ! run_test_suite "Issue #84 Tests" "test_issue_84.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #6 tests (cac check: cache, timeout, exit codes, CLI integration)
    if $run_all || [[ "$filter" == "issue_6" ]] || [[ "$filter" == "6" ]]; then
        if ! run_test_suite "Issue #6 Tests" "test_issue_6.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #93 tests (cac check --user USER [TOOL] argument parsing)
    if $run_all || [[ "$filter" == "check_args" ]] || [[ "$filter" == "93" ]]; then
        if ! run_test_suite "Issue #93 Tests" "test_check_args.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #85 tests (env repair liveness preflight before rm -rf)
    if $run_all || [[ "$filter" == "issue_85" ]] || [[ "$filter" == "85" ]]; then
        if ! run_test_suite "Issue #85 Tests" "test_issue_85.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #86 tests (env update installs; env repair fixes wrong-target symlink)
    if $run_all || [[ "$filter" == "issue_86" ]] || [[ "$filter" == "86" ]]; then
        if ! run_test_suite "Issue #86 Tests" "test_issue_86.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #94/#95 tests (escalated env update cannot update the on-PATH copy)
    if $run_all || [[ "$filter" == "issue_94_95" ]] || [[ "$filter" == "94" ]] || [[ "$filter" == "95" ]]; then
        if ! run_test_suite "Issue #94/#95 Tests" "test_issue_94_95.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #100 tests (curl post-update verification: false success for
    # an install reachable only by root)
    if $run_all || [[ "$filter" == "issue_100" ]] || [[ "$filter" == "100" ]]; then
        if ! run_test_suite "Issue #100 Tests" "test_issue_100.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # ------------------------------------------------------------------------
    # Suites below were delivered unregistered and never executed until #101.
    # ------------------------------------------------------------------------

    # Run Issue #71 tests (multi-user env update)
    if $run_all || [[ "$filter" == "issue_71" ]] || [[ "$filter" == "71" ]]; then
        if ! run_test_suite "Issue #71 Tests" "test_issue_71.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #72 tests
    if $run_all || [[ "$filter" == "issue_72" ]] || [[ "$filter" == "72" ]]; then
        if ! run_test_suite "Issue #72 Tests" "test_issue_72.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issue #73 tests (env update path)
    if $run_all || [[ "$filter" == "issue_73" ]] || [[ "$filter" == "73" ]]; then
        if ! run_test_suite "Issue #73 Tests" "test_issue_73.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run Issues #7/#8/#9 tests
    if $run_all || [[ "$filter" == "issues_7_8_9" ]] || [[ "$filter" == "7_8_9" ]]; then
        if ! run_test_suite "Issues #7/#8/#9 Tests" "test_issues_7_8_9.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run pull argument-parsing tests (Issue #91)
    if $run_all || [[ "$filter" == "pull_args" ]] || [[ "$filter" == "91" ]]; then
        if ! run_test_suite "Pull Argument Parsing Tests" "test_pull_args.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run suite-registration guard (Issue #101) — fails if any suite file is
    # unregistered or non-executable.
    if $run_all || [[ "$filter" == "suite_registration" ]] || [[ "$filter" == "101" ]]; then
        if ! run_test_suite "Suite Registration Guard" "test_suite_registration.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    # Run timezone-dependent git date guard (Issue #151, from #140)
    if $run_all || [[ "$filter" == "git_date_tz" ]] || [[ "$filter" == "151" ]]; then
        if ! run_test_suite "Git Date Timezone Guard" "test_git_date_tz.sh"; then
            exit_code=1
        fi
        echo ""
    fi

    if [[ $SUITES_SELECTED -eq 0 ]]; then
        echo -e "${RED}no suite matches '${filter}'${NC}" >&2
        exit 2
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
