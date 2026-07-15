#!/usr/bin/env bash
# tests/verify_gate.sh - Mechanical SoD landing-gate check (Issue #90)
#
# Verifies the LANDING invariant before a milestone is advanced (mandatory
# before `test-approved`): the deliverable for an issue has actually landed as a
# commit, not stranded as uncommitted / untracked work in an abandoned worktree
# (the #78 failure, where ci.yml was `test-approved` but never committed).
#
# Usage: tests/verify_gate.sh <issue-number> [<target-ref>]
#
#   <issue-number>  Positive integer - the GitHub issue the gate is checking.
#   <target-ref>    Git ref whose history Invariant A is evaluated against.
#                   Defaults to HEAD. The authoritative run at `test-approved`
#                   time must name the integration branch once the fix is on it,
#                   e.g.  `verify_gate.sh 90 main`. Naming the correct merge
#                   branch is an irreducible MANUAL / auditable step.
#
# Exit codes:
#   0  GATE PASSED  - both invariants hold.
#   1  GATE FAILED  - a landing invariant failed (no referencing commit, or
#                     tracked files have uncommitted changes).
#   2  USAGE/ENV    - bad args, not a git work tree, unresolvable <target-ref>,
#                     or a detached HEAD with no explicit <target-ref> (an
#                     ambiguous range = abandoned-worktree smell).
#
# Invariant A (landing commit): >=1 commit reachable from <target-ref> has a
#   message referencing #<issue>, word-bounded so #90 does NOT match #900.
#   Matched against the full commit message (subject + body), which is the
#   `git log --grep` default.
# Invariant B (clean tracked state): no uncommitted changes to TRACKED files
#   (staged or unstaged). Untracked files are intentionally ignored so unrelated
#   in-flight work on a shared branch does not false-fail the gate.
#
# By design <target-ref> is a single explicit ref, NOT `git log --all`: a commit
# stranded on an abandoned branch must not satisfy the gate.

set -euo pipefail

usage() {
    echo "Usage: $0 <issue-number> [<target-ref>]" >&2
}

main() {
    local issue="${1:-}"
    local target_ref="${2:-}"

    # --- Argument validation -------------------------------------------------
    if [[ -z "$issue" ]]; then
        usage
        exit 2
    fi
    if ! [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: issue number must be a positive integer, got: '$issue'" >&2
        usage
        exit 2
    fi

    # --- Environment ---------------------------------------------------------
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "ERROR: not inside a git work tree" >&2
        exit 2
    fi

    # --- Target-ref resolution ----------------------------------------------
    # Default to HEAD, but refuse an ambiguous detached HEAD unless the caller
    # named a ref explicitly.
    if [[ -z "$target_ref" ]]; then
        if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
            echo "ERROR: HEAD is detached and no <target-ref> was given - refusing ambiguous range" >&2
            exit 2
        fi
        target_ref="HEAD"
    fi
    if ! git rev-parse --verify --quiet "${target_ref}^{commit}" >/dev/null; then
        echo "ERROR: cannot resolve <target-ref>: '$target_ref'" >&2
        exit 2
    fi

    # --- Provenance: record exactly which range was evaluated ----------------
    local ref_name ref_sha
    ref_name=$(git rev-parse --abbrev-ref "$target_ref" 2>/dev/null || echo "$target_ref")
    ref_sha=$(git rev-parse --short "$target_ref")
    echo "Evaluating #${issue} against ref '${ref_name}' (${ref_sha})"

    local failed=0

    # --- Invariant A: a commit referencing #<issue> is reachable -------------
    if git log -E --grep="#${issue}([^0-9]|\$)" --format='%H' "$target_ref" 2>/dev/null | grep -q .; then
        echo "PASS: commit referencing #${issue} is reachable from '${ref_name}'"
    else
        echo "FAIL: no commit referencing #${issue} is reachable from '${ref_name}'" >&2
        failed=1
    fi

    # --- Invariant B: no uncommitted changes to tracked files ----------------
    if git diff --quiet && git diff --cached --quiet; then
        echo "PASS: no uncommitted changes to tracked files"
    else
        echo "FAIL: tracked files have uncommitted changes (deliverable not committed)" >&2
        failed=1
    fi

    if [[ "$failed" -ne 0 ]]; then
        echo "GATE FAILED for #${issue}: deliverable has not landed." >&2
        exit 1
    fi
    echo "GATE PASSED for #${issue}"
}

main "$@"
