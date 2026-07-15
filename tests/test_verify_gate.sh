#!/usr/bin/env bash
# tests/test_verify_gate.sh - Tests for the SoD landing-gate check (Issue #90)
#
# Run with: ./tests/test_verify_gate.sh
#
# NOTE: intentionally NOT wired into tests/run_tests.sh - that file is owned
# elsewhere and outside the Issue #90 change scope. Run this suite standalone.
# (Known rot risk: since it is not in the aggregator it will not run in a normal
# ./tests/run_tests.sh invocation; a follow-up issue should wire it in.)
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/test_framework.sh disable=SC1091
source "${SCRIPT_DIR}/test_framework.sh"

framework_require_commands git

VERIFY_GATE="${SCRIPT_DIR}/verify_gate.sh"

# ============================================================================
# Helpers
# ============================================================================

# Create a fresh git repo at $1 with a deterministic identity and no signing.
_new_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "cac test"
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" config advice.detachedHead false
}

# Run the gate inside $repo with the remaining args; echo its exit code.
# Never aborts the caller (errexit is off inside run_test's subshell anyway).
_run_gate() {
    local repo="$1"; shift
    local rc=0
    ( cd "$repo" && bash "$VERIFY_GATE" "$@" ) >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# ============================================================================
# Tests
# ============================================================================

# 1: no commit references the issue -> gate fails (the core #78/#90 catch).
test_fail_without_landing_commit() {
    local repo="${TEST_TMPDIR}/r1"
    _new_repo "$repo"
    git -C "$repo" commit -q --allow-empty -m "initial commit"
    assert_equals "1" "$(_run_gate "$repo" 90)" "no #90 commit -> gate fails"
}

# 2: a referencing commit on a clean tree -> gate passes.
test_pass_with_landing_commit() {
    local repo="${TEST_TMPDIR}/r2"
    _new_repo "$repo"
    git -C "$repo" commit -q --allow-empty -m "close #90"
    assert_equals "0" "$(_run_gate "$repo" 90)" "#90 commit + clean tree -> gate passes"
}

# 3: a modified TRACKED file (uncommitted) -> Invariant B fails.
test_fail_dirty_tracked_file() {
    local repo="${TEST_TMPDIR}/r3"
    _new_repo "$repo"
    echo "v1" > "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -q -m "close #90 add file"
    echo "v2-uncommitted" > "$repo/file.txt"
    assert_equals "1" "$(_run_gate "$repo" 90)" "dirty tracked file -> gate fails"
}

# 4: an unrelated UNTRACKED file must NOT fail the gate (tracked-only scoping).
test_pass_with_untracked_file() {
    local repo="${TEST_TMPDIR}/r4"
    _new_repo "$repo"
    git -C "$repo" commit -q --allow-empty -m "close #90"
    echo "scratch" > "$repo/untracked.txt"
    assert_equals "0" "$(_run_gate "$repo" 90)" "untracked file ignored -> gate passes"
}

# 5: #900 must not satisfy a check for #90 (word boundary).
test_no_false_prefix_match() {
    local repo="${TEST_TMPDIR}/r5"
    _new_repo "$repo"
    git -C "$repo" commit -q --allow-empty -m "close #900"
    assert_equals "1" "$(_run_gate "$repo" 90)" "#900 must not satisfy #90"
}

# 6: positive matches - (#90), '#90,', EOL, two refs.
test_positive_boundary_matches() {
    local base="${TEST_TMPDIR}/r6"

    local r_paren="${base}_paren"
    _new_repo "$r_paren"
    git -C "$r_paren" commit -q --allow-empty -m "fix bug (#90)"
    assert_equals "0" "$(_run_gate "$r_paren" 90)" "(#90) matches" || return 1

    local r_comma="${base}_comma"
    _new_repo "$r_comma"
    git -C "$r_comma" commit -q --allow-empty -m "fixes #90, and more"
    assert_equals "0" "$(_run_gate "$r_comma" 90)" "#90, matches" || return 1

    local r_eol="${base}_eol"
    _new_repo "$r_eol"
    git -C "$r_eol" commit -q --allow-empty -m "resolves #90"
    assert_equals "0" "$(_run_gate "$r_eol" 90)" "#90 at EOL matches" || return 1

    local r_two="${base}_two"
    _new_repo "$r_two"
    git -C "$r_two" commit -q --allow-empty -m "refs #12 and #90"
    assert_equals "0" "$(_run_gate "$r_two" 90)" "two refs matches"
}

# 7: a reference only in the commit BODY still matches (full-message grep).
test_body_only_reference_matches() {
    local repo="${TEST_TMPDIR}/r7"
    _new_repo "$repo"
    git -C "$repo" commit -q --allow-empty -m "initial subject" -m "body mentions #90 here"
    assert_equals "0" "$(_run_gate "$repo" 90)" "body-only #90 matches (full message)"
}

# 8: bad issue arg (non-numeric / missing) -> exit 2.
test_rejects_bad_arg() {
    local repo="${TEST_TMPDIR}/r8"
    _new_repo "$repo"
    git -C "$repo" commit -q --allow-empty -m "close #90"
    assert_equals "2" "$(_run_gate "$repo" abc)" "non-numeric issue -> exit 2" || return 1
    assert_equals "2" "$(_run_gate "$repo" 0)" "issue 0 not a positive integer -> exit 2" || return 1
    assert_equals "2" "$(_run_gate "$repo")" "missing issue -> exit 2"
}

# 9: run outside a git work tree -> exit 2.
test_exit2_outside_worktree() {
    local nonrepo="${TEST_TMPDIR}/not_a_repo"
    mkdir -p "$nonrepo"
    local rc=0
    ( cd "$nonrepo" && GIT_CEILING_DIRECTORIES="${TEST_TMPDIR}" bash "$VERIFY_GATE" 90 ) >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "outside a git work tree -> exit 2"
}

# 10: detached HEAD + no explicit target-ref -> refuse (exit 2).
test_detached_head_refused() {
    local repo="${TEST_TMPDIR}/r10"
    _new_repo "$repo"
    git -C "$repo" commit -q --allow-empty -m "close #90"
    git -C "$repo" checkout -q --detach
    assert_equals "2" "$(_run_gate "$repo" 90)" "detached HEAD + no target-ref -> exit 2"
}

# 11: an explicit target-ref is evaluated against THAT ref, not HEAD.
test_explicit_target_ref() {
    local repo="${TEST_TMPDIR}/r11"
    _new_repo "$repo"
    git -C "$repo" commit -q --allow-empty -m "initial"
    git -C "$repo" checkout -q -b feat
    git -C "$repo" commit -q --allow-empty -m "close #90"
    git -C "$repo" checkout -q -
    # HEAD (default branch) lacks #90; ref 'feat' has it.
    assert_equals "0" "$(_run_gate "$repo" 90 feat)" "explicit target-ref evaluated -> pass" || return 1
    assert_equals "1" "$(_run_gate "$repo" 90)" "default HEAD lacks #90 -> fail"
}

# 12 (nice-to-have): an unresolvable target-ref -> exit 2.
test_invalid_ref_rejected() {
    local repo="${TEST_TMPDIR}/r12"
    _new_repo "$repo"
    git -C "$repo" commit -q --allow-empty -m "close #90"
    assert_equals "2" "$(_run_gate "$repo" 90 nonexistent)" "unresolvable target-ref -> exit 2"
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "verify_gate.sh Tests (Issue #90)"
    echo "========================================"
    echo ""

    framework_init

    run_test "fails without landing commit" test_fail_without_landing_commit
    run_test "passes with landing commit" test_pass_with_landing_commit
    run_test "fails on dirty tracked file" test_fail_dirty_tracked_file
    run_test "untracked file does not fail" test_pass_with_untracked_file
    run_test "no false prefix match (#900 vs #90)" test_no_false_prefix_match
    run_test "positive boundary matches" test_positive_boundary_matches
    run_test "body-only reference matches" test_body_only_reference_matches
    run_test "rejects bad arg" test_rejects_bad_arg
    run_test "exit 2 outside git worktree" test_exit2_outside_worktree
    run_test "detached HEAD refused" test_detached_head_refused
    run_test "explicit target-ref evaluated" test_explicit_target_ref
    run_test "invalid ref rejected" test_invalid_ref_rejected
    echo ""

    framework_report
    exit $?
}

main "$@"
