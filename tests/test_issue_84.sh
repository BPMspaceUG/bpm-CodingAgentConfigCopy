#!/usr/bin/env bash
# tests/test_issue_84.sh - Tests for Issue #84
#
# Bug: `cac check all` printed "WARNING: Skipping all: no credentials found ()"
# and exited 100 instead of checking every tool. Root cause: cmd_check routed on
# whether a tool arg was GIVEN, not on its value, so the literal "all" hit
# check_single_tool "all" -> _check_get_primary_cred_file "all" returns "" ->
# [[ ! -f "" ]] -> return 100 (skip sentinel). It never reached check_all_tools.
#
# Fix: cmd_check routes "all" (and the no-arg default) to check_all_tools, and
# check_single_tool rejects the pseudo-tool "all" (UNKNOWN_TOOL, not 100).
#
# NOTE: test_env_check.sh tests lib/env.sh's `env check` — a different module.
# This suite targets the `cac check` dispatch (bin/cac cmd_check) + check.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# bin/cac is source-safe (guarded by `(return 0 2>/dev/null) || main` at its
# tail); sourcing it loads logging/tools/check and defines cmd_check without
# running main. Suppress its startup noise.
# shellcheck source=bin/cac
source "$REPO_DIR/bin/cac" >/dev/null 2>&1

framework_init

# ============================================================================
# Routing tests. Overrides live inside the command-substitution subshell so the
# stubs never leak to the parent shell or other tests.
# ============================================================================

# 84.1 [anti-bug]: `cac check all` routes to check_all_tools, NOT
# check_single_tool "all"; no "Skipping all" warning; exit code is NOT 100.
# The stub returns a distinctive non-zero (3) to prove the assertion targets
# routing + not-100, NOT a magic pass value of 0 (check_all_tools legitimately
# returns the highest CHECK_EXIT_* across configured tools).
test_84_1_all_routes_to_check_all() {
    local out rc=0
    out=$(
        check_all_tools()   { echo "ROUTED_ALL"; return 3; }
        check_single_tool() { echo "ROUTED_SINGLE:$1"; return 0; }
        cmd_check all 2>&1
    ) || rc=$?

    if ! echo "$out" | grep -q "ROUTED_ALL"; then
        echo "FAIL: 'all' did not route to check_all_tools" >&2; return 1
    fi
    if echo "$out" | grep -q "ROUTED_SINGLE:all"; then
        echo "FAIL: 'all' wrongly routed to check_single_tool" >&2; return 1
    fi
    if echo "$out" | grep -q "Skipping all"; then
        echo "FAIL: emitted the empty-cred-path skip for 'all'" >&2; return 1
    fi
    if [[ "$rc" -eq 100 ]]; then
        echo "FAIL: 'cac check all' returned the 100 skip sentinel" >&2; return 1
    fi
    pass "84_1_all_routes_to_check_all"
}

# 84.2 [regression]: no-arg `cac check` still routes to check_all_tools.
test_84_2_noarg_routes_to_check_all() {
    local out
    out=$(
        check_all_tools()   { echo "ROUTED_ALL"; return 0; }
        check_single_tool() { echo "ROUTED_SINGLE:$1"; return 0; }
        cmd_check 2>&1
    )
    if ! echo "$out" | grep -q "ROUTED_ALL"; then
        echo "FAIL: no-arg default did not route to check_all_tools" >&2; return 1
    fi
    if echo "$out" | grep -q "ROUTED_SINGLE:"; then
        echo "FAIL: no-arg default wrongly routed to check_single_tool" >&2; return 1
    fi
    pass "84_2_noarg_routes_to_check_all"
}

# 84.3 [regression]: a real tool still routes to check_single_tool.
test_84_3_realtool_routes_to_single() {
    local out
    out=$(
        check_all_tools()   { echo "ROUTED_ALL"; return 0; }
        check_single_tool() { echo "ROUTED_SINGLE:$1"; return 0; }
        cmd_check claude 2>&1
    )
    if ! echo "$out" | grep -q "ROUTED_SINGLE:claude"; then
        echo "FAIL: real tool 'claude' did not route to check_single_tool" >&2; return 1
    fi
    if echo "$out" | grep -q "ROUTED_ALL"; then
        echo "FAIL: real tool wrongly routed to check_all_tools" >&2; return 1
    fi
    pass "84_3_realtool_routes_to_single"
}

# 84.4 [guard]: the REAL check_single_tool rejects the pseudo-tool "all" with
# UNKNOWN_TOOL (2), not the misleading empty-path skip (100), and no "Skipping".
test_84_4_guard_rejects_all() {
    local out rc=0
    out=$(check_single_tool "all" "false" "$(whoami)" "$HOME" 2>&1) || rc=$?
    assert_equals "$CHECK_EXIT_UNKNOWN_TOOL" "$rc" "check_single_tool 'all' -> UNKNOWN_TOOL" || return 1
    if echo "$out" | grep -q "Skipping all"; then
        echo "FAIL: guard still emitted the empty-cred-path skip for 'all'" >&2; return 1
    fi
    pass "84_4_guard_rejects_all"
}

# ============================================================================
# Run
# ============================================================================

echo "=========================================="
echo "Issue #84: 'cac check all' checks all tools (no empty-path exit 100)"
echo "=========================================="

run_test "84.1 'all' routes to check_all_tools (no skip, not 100)" test_84_1_all_routes_to_check_all
run_test "84.2 no-arg default routes to check_all_tools" test_84_2_noarg_routes_to_check_all
run_test "84.3 real tool routes to check_single_tool" test_84_3_realtool_routes_to_single
run_test "84.4 check_single_tool 'all' guard -> UNKNOWN_TOOL, not 100" test_84_4_guard_rejects_all

framework_report
