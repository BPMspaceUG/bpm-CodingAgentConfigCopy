#!/usr/bin/env bash
# tests/test_check_args.sh - Tests for the `cac check` argument parser
#
# Issue #93 (bug): cmd_check took "the first token not starting with --" as the
# TOOL, with no knowledge that --user consumes the NEXT token. Consequences:
#   cac check --user bob all    -> tool=bob, user=all  (both wrong)
#   cac check --user bob claude -> tool=bob, user=claude
#   cac check --user bob        -> bare --user reaches utils_parse_user_arg and
#                                 dies with "Option --user requires an argument"
#                                 — and that is the form documented at bin/cac:139.
# Fixed by consuming --user + value as a pair in the pre-parse loop before the
# positional tool is taken. Twin of #91 (cmd_pull), fixed the same way there in
# commit e0753ef.
#
# NOTE: tests/test_issue_84.sh covers `cac check` DISPATCH (which of
# check_all_tools / check_single_tool gets called). This suite covers the
# argument PARSING that decides what those get called with. Cases 93.7/93.8
# double as #84 regression guards.
#
# Strategy: bin/cac is source-safe ((return 0) || main "$@" guard), so we source
# it and drive cmd_check directly. Stubs live inside the command-substitution
# subshell (the tests/test_issue_84.sh convention) so they never leak between
# cases. Every case is an in-process parse assertion: no network, no credential
# probes, no shared /tmp state — safe to run concurrently with other suites.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

# Sourcing bin/cac pulls in all lib modules and (via its own `set -euo pipefail`)
# turns on errexit for this script. Disable it again so glue code is not aborted
# by an expected non-zero (run_test already runs each case with -e off).
# shellcheck source=bin/cac
source "$REPO_DIR/bin/cac" >/dev/null 2>&1
set +e

# cmd_check defaults the target user to $USER (bin/cac:810). Guarantee it is set
# so the no---user cases are deterministic in a bare environment.
: "${USER:=$(id -un)}"

framework_init

# ============================================================================
# Harness
# ============================================================================
# Run cmd_check with the filesystem/user-db/probe layer stubbed out, capturing
# combined output in CHECK_OUT and the exit code in CHECK_RC.
#
# STUB_WHOAMI must be set by the caller to the user the case expects to end up
# targeting: cmd_check (bin/cac:814-820) demands root whenever target_user
# differs from `whoami`, and this suite runs unprivileged. A shell function
# shadows the whoami binary, so no root and no EUID mutation is needed.
#
# The stubs echo BOTH the routing decision and the user they were handed, so a
# case that parses the tool correctly but the user wrongly (the #93 failure
# mode) still fails.
#   check_single_tool <tool> <use_sudo> <target_user> <home_dir>   (bin/cac:833)
#   check_all_tools          <use_sudo> <target_user> <home_dir>   (bin/cac:836)
run_check() {
    CHECK_OUT=$(
        whoami()                     { echo "$STUB_WHOAMI"; }
        security_resolve_user_home() { echo "$TEST_TMPDIR"; }
        check_all_tools()   { echo "ROUTED_ALL user=$2"; return 0; }
        check_single_tool() { echo "ROUTED_SINGLE:$1 user=$3"; return 0; }
        cmd_check "$@" 2>&1
    )
    CHECK_RC=$?
    return 0
}

# Assert the output does NOT contain a needle.
assert_not_contains() {
    local needle="$1" haystack="$2" description="${3:-value}"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "Expected ${description} NOT to contain '$needle', got: '$haystack'" >&2
        return 1
    fi
    return 0
}

# ============================================================================
# #93 — the bug proper
# ============================================================================

# 93.1 [anti-bug]: the exact invocation from the issue. Pre-fix this yielded
# tool=bob / user=all and failed with "Root required to check as another user".
test_93_1_user_then_all() {
    STUB_WHOAMI="bob"
    run_check --user bob all
    assert_equals "0" "$CHECK_RC" "exit code" || return 1
    assert_contains "ROUTED_ALL user=bob" "$CHECK_OUT" "routing+user" || return 1
    assert_contains "for user: bob" "$CHECK_OUT" "banner user" || return 1
    assert_not_contains "ROUTED_SINGLE" "$CHECK_OUT" "output" || return 1
    # The tool must never have been taken from the --user value.
    assert_not_contains "ROUTED_SINGLE:bob" "$CHECK_OUT" "output"
}

# 93.2 [anti-bug]: --user before a real tool. Pre-fix: tool=bob, user=claude.
test_93_2_user_then_tool() {
    STUB_WHOAMI="bob"
    run_check --user bob claude
    assert_equals "0" "$CHECK_RC" "exit code" || return 1
    assert_contains "ROUTED_SINGLE:claude user=bob" "$CHECK_OUT" "routing+user" || return 1
    assert_contains "for user: bob" "$CHECK_OUT" "banner user"
}

# 93.3 [anti-bug]: the DOCUMENTED form (bin/cac:139, `cac check --user bob`).
# Pre-fix this crashed with "Option --user requires an argument" — the #91
# symptom, in the check command.
test_93_3_user_only_no_tool() {
    STUB_WHOAMI="bob"
    run_check --user bob
    assert_not_contains "requires an argument" "$CHECK_OUT" "output" || return 1
    assert_equals "0" "$CHECK_RC" "exit code" || return 1
    assert_contains "ROUTED_ALL user=bob" "$CHECK_OUT" "routing+user"
}

# 93.4 [anti-bug]: alias resolution still applies to the TOOL token and never to
# the --user value (lib/tools.sh:42, vibe -> mistral).
test_93_4_alias_after_user() {
    STUB_WHOAMI="bob"
    run_check --user bob vibe
    assert_equals "0" "$CHECK_RC" "exit code" || return 1
    assert_contains "ROUTED_SINGLE:mistral user=bob" "$CHECK_OUT" "alias resolved, user intact"
}

# ============================================================================
# Regression guards — these were already green before the fix
# ============================================================================

# 93.5: flag AFTER the positional tool (the order that always worked).
test_93_5_tool_then_user() {
    STUB_WHOAMI="bob"
    run_check claude --user bob
    assert_equals "0" "$CHECK_RC" "exit code" || return 1
    assert_contains "ROUTED_SINGLE:claude user=bob" "$CHECK_OUT" "routing+user"
}

# 93.6: a trailing --user with no value must still error cleanly, not consume
# whatever follows. Message is preserved verbatim from lib/utils.sh:114.
test_93_6_user_missing_value() {
    STUB_WHOAMI="$USER"
    run_check --user
    [[ "$CHECK_RC" -ne 0 ]] || { echo "expected non-zero exit for missing --user value" >&2; return 1; }
    assert_contains "requires an argument" "$CHECK_OUT" "error message" || return 1
    assert_not_contains "ROUTED_" "$CHECK_OUT" "output (must not route)"
}

# 93.7 [#84 guard]: the literal "all" still routes to check_all_tools for the
# current user.
test_93_7_all_current_user() {
    STUB_WHOAMI="$USER"
    run_check all
    assert_equals "0" "$CHECK_RC" "exit code" || return 1
    assert_contains "ROUTED_ALL user=$USER" "$CHECK_OUT" "routing+user" || return 1
    assert_not_contains "ROUTED_SINGLE" "$CHECK_OUT" "output"
}

# 93.8 [#84 guard]: no arguments at all -> check every tool for the current user.
# Also exercises the empty-args expansion at bin/cac:807 under `set -u`.
test_93_8_no_args() {
    STUB_WHOAMI="$USER"
    run_check
    assert_equals "0" "$CHECK_RC" "exit code" || return 1
    assert_contains "ROUTED_ALL user=$USER" "$CHECK_OUT" "routing+user"
}

# 93.9: single-dash tokens are flags, not tools (consistent with cmd_push,
# bin/cac:263-266). Both pre- and post-fix this exits non-zero, so the
# discriminating assertion is WHICH token is reported: pre-fix `-u` was silently
# swallowed as the tool and the error named the leftover value ("Unknown option:
# bob"); post-fix the flag itself is reported ("Unknown option: -u").
test_93_9_single_dash_not_a_tool() {
    STUB_WHOAMI="$USER"
    run_check -u bob
    [[ "$CHECK_RC" -ne 0 ]] || { echo "expected non-zero exit for unsupported -u flag" >&2; return 1; }
    assert_contains "Unknown option: -u" "$CHECK_OUT" "error must name the flag, not its value" || return 1
    assert_not_contains "ROUTED_SINGLE:-u" "$CHECK_OUT" "output (must not treat -u as a tool)" || return 1
    assert_not_contains "ROUTED_ALL" "$CHECK_OUT" "output (must not route)"
}

# ============================================================================
# Run
# ============================================================================

echo "=========================================="
echo "Issue #93: 'cac check --user USER [TOOL]' argument parsing"
echo "=========================================="

run_test "93.1 --user USER all -> all tools for USER"        test_93_1_user_then_all
run_test "93.2 --user USER claude -> claude for USER"        test_93_2_user_then_tool
run_test "93.3 --user USER (no tool) does not crash"         test_93_3_user_only_no_tool
run_test "93.4 --user USER vibe -> mistral for USER"         test_93_4_alias_after_user
run_test "93.5 TOOL --user USER still works"                 test_93_5_tool_then_user
run_test "93.6 trailing --user errors cleanly"               test_93_6_user_missing_value
run_test "93.7 'all' routes to check_all_tools (#84 guard)"  test_93_7_all_current_user
run_test "93.8 no args routes to check_all_tools (#84 guard)" test_93_8_no_args
run_test "93.9 -u is a flag, not a tool"                     test_93_9_single_dash_not_a_tool

framework_report
