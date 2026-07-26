#!/usr/bin/env bash
# tests/gate_sweep.sh - Standing landing sweep across test-approved issues (#104)
#
# tests/verify_gate.sh (#90) validates ONE issue at the moment a Team Lead runs
# it, so it is structurally blind to work that already slipped past. This sweep
# runs that same gate across EVERY open issue at milestone `test-approved` and
# reports the stranded ones.
#
# Usage: tests/gate_sweep.sh [--ref <git-ref>] [--issues "<n> <n> ..."]
#
#   --ref     Git ref whose history Invariant A is evaluated against.
#             Defaults to HEAD. The meaningful run names the integration
#             branch, e.g. `--ref main`.
#   --issues  Explicit issue list; skips the GitHub query entirely. Used by the
#             tests, and useful for re-checking a known subset offline.
#
# Exit codes:
#   0  every checked issue passed and the tree is clean
#   1  at least one issue has no landing commit, or tracked files are dirty
#   2  usage / environment error (bad args, no git work tree, gh unavailable or
#      the GitHub query failed)
#
# Exit 2 matters: a sweep that cannot fetch its issue list must NOT exit 0. A
# silent green from a sweep that checked nothing is the same class of failure
# this sweep exists to detect.
#
# Two traps, both learned the hard way during the #98 cleanup:
#
#   1. verify_gate.sh's Invariant B (no uncommitted changes to tracked files) is
#      REPO-GLOBAL. One dirty tracked file fails every issue. Repeating that
#      per-issue turns the report into noise, so it is evaluated once, reported
#      once, and suppressed in the per-issue rows.
#   2. Exit codes are captured by assignment, never through a pipe.
#      `verify_gate.sh N ref | tail -3` reports tail's status and reads as a
#      pass. Every rc below comes from `out=$(...) || rc=$?`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_GATE="${SCRIPT_DIR}/verify_gate.sh"

# The milestone whose issues are swept. Issues here claim their deliverable
# passed every gate, which is exactly the claim this sweep tests.
MILESTONE_TITLE="test-approved"

usage() {
    echo "Usage: $0 [--ref <git-ref>] [--issues \"<n> <n> ...\"]" >&2
}

# Fetch open issue numbers at $MILESTONE_TITLE.
#
# REST only, never `gh issue view` — the single-issue GraphQL render path is
# broken repo-wide by the Projects-classic sunset (#103). gh substitutes
# {owner}/{repo} from the current repository.
fetch_issue_numbers() {
    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: gh not found; cannot determine the ${MILESTONE_TITLE} issue list" >&2
        exit 2
    fi

    local milestone_number
    if ! milestone_number=$(gh api "repos/{owner}/{repo}/milestones?state=all&per_page=100" \
        --jq ".[] | select(.title == \"${MILESTONE_TITLE}\") | .number" 2>/dev/null); then
        echo "ERROR: could not query milestones from GitHub" >&2
        exit 2
    fi
    if [[ -z "$milestone_number" ]]; then
        echo "ERROR: no milestone titled '${MILESTONE_TITLE}' in this repository" >&2
        exit 2
    fi

    # `select(.pull_request == null)`: the REST issues endpoint returns pull
    # requests as issues, and a PR is not a deliverable this gate can check.
    local numbers
    if ! numbers=$(gh api "repos/{owner}/{repo}/issues?milestone=${milestone_number}&state=open&per_page=100" \
        --jq '.[] | select(.pull_request == null) | .number' 2>/dev/null); then
        echo "ERROR: could not query issues from GitHub" >&2
        exit 2
    fi

    echo "$numbers"
}

main() {
    local target_ref="HEAD"
    local explicit_issues=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ref)
                [[ $# -ge 2 ]] || { echo "ERROR: --ref requires an argument" >&2; usage; exit 2; }
                target_ref="$2"; shift 2 ;;
            --issues)
                [[ $# -ge 2 ]] || { echo "ERROR: --issues requires an argument" >&2; usage; exit 2; }
                explicit_issues="$2"; shift 2 ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                echo "ERROR: unknown argument: '$1'" >&2; usage; exit 2 ;;
        esac
    done

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "ERROR: not inside a git work tree" >&2
        exit 2
    fi
    if ! git rev-parse --verify --quiet "${target_ref}^{commit}" >/dev/null; then
        echo "ERROR: cannot resolve ref: '${target_ref}'" >&2
        exit 2
    fi

    local issues
    if [[ -n "$explicit_issues" ]]; then
        issues="$explicit_issues"
    else
        issues=$(fetch_issue_numbers)
    fi

    # Validate before doing any work, so a typo cannot look like a clean sweep.
    local n
    for n in $issues; do
        if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: not a valid issue number: '${n}'" >&2
            usage
            exit 2
        fi
    done

    if [[ -z "${issues// /}" ]]; then
        echo "No open issues at milestone '${MILESTONE_TITLE}' — nothing to sweep."
        exit 0
    fi

    # --- Invariant B, once for the whole repo --------------------------------
    local tree_dirty=0
    if ! (git diff --quiet && git diff --cached --quiet); then
        tree_dirty=1
    fi

    echo "Landing sweep against ref '${target_ref}' ($(git rev-parse --short "$target_ref"))"
    echo ""

    if [[ $tree_dirty -eq 1 ]]; then
        echo "REPO-GLOBAL: tracked files have uncommitted changes."
        echo "  This fails verify_gate.sh Invariant B for EVERY issue below, so it is"
        echo "  reported here once. Per-issue rows show Invariant A only."
        echo ""
    fi

    # --- Invariant A, per issue ----------------------------------------------
    local stranded=() passed=() env_failed=()

    for n in $issues; do
        local rc=0 out=""
        # Exit code by assignment. Never `| tail`, never `| grep`.
        out=$(bash "$VERIFY_GATE" "$n" "$target_ref" 2>&1) || rc=$?

        if [[ $rc -eq 2 ]]; then
            env_failed+=("$n")
            printf '  #%-5s ENV       %s\n' "$n" "$(echo "$out" | head -1)"
            continue
        fi

        # Classify on Invariant A alone; Invariant B is the global condition
        # already reported above and must not be counted per issue.
        #
        # rc is consulted FIRST and is load-bearing: a gate that exits 0 is a
        # pass, full stop. Deciding purely on message text would keep working if
        # the exit code were ever lost (the pipe trap), and would silently call
        # a future third invariant's failure "OK".
        if [[ $rc -eq 0 ]]; then
            passed+=("$n")
            printf '  #%-5s OK        landing commit present, tree clean\n' "$n"
        elif echo "$out" | grep -q "no commit referencing #${n}"; then
            stranded+=("$n")
            printf '  #%-5s STRANDED  no commit referencing #%s is reachable from %s\n' "$n" "$n" "$target_ref"
        elif [[ $tree_dirty -eq 1 ]]; then
            # Invariant A held; the only failure is the global dirty tree.
            passed+=("$n")
            printf '  #%-5s OK        landing commit present (repo dirty — see above)\n' "$n"
        else
            # verify_gate failed for a reason this sweep does not recognise.
            # Surface it rather than guessing.
            env_failed+=("$n")
            printf '  #%-5s UNKNOWN   gate failed for an unrecognised reason: %s\n' "$n" "$(echo "$out" | tail -1)"
        fi
    done

    echo ""
    echo "========================================"
    echo "Swept ${#passed[@]} OK, ${#stranded[@]} stranded, ${#env_failed[@]} env-error"
    if [[ ${#stranded[@]} -gt 0 ]]; then
        echo "Stranded (no landing commit): ${stranded[*]}"
    fi
    if [[ $tree_dirty -eq 1 ]]; then
        echo "Tracked files are uncommitted (repo-global)."
    fi

    # An env failure means the sweep could not check what it claims to have
    # checked, which is a different thing from a finding — exit 2, per the
    # contract at the top of this file.
    if [[ ${#env_failed[@]} -gt 0 ]]; then
        echo "Env errors on: ${env_failed[*]}" >&2
        exit 2
    fi
    if [[ ${#stranded[@]} -gt 0 || $tree_dirty -eq 1 ]]; then
        exit 1
    fi
    echo "All swept issues have landed."
}

main "$@"
