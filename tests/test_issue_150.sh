#!/usr/bin/env bash
# tests/test_issue_150.sh - Tests for Issue #150
#
# The lint command must be readable as pass/fail. Shellcheck 0.11.0 flagged
# every test function with SC2329 ("function never invoked", info level): they
# are called indirectly via run_test, which shellcheck cannot follow. Hundreds
# of those notes buried any real finding in a plain `shellcheck tests/*.sh`.
#
# tests/.shellcheckrc disables SC2329 for everything under tests/. This guard
# fails if that stops working (file removed, check renamed), and checks that
# the two documented copies of the lint gate (CLAUDE.md and the README
# "Linting" section) name the same commands. There is no GitHub CI (#162):
# the gate is run locally before each commit.
#
# Seams: shellcheck's output on tests/*.sh; the lint lines of CLAUDE.md and
# README.md.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

HAS_SHELLCHECK=false
framework_has_command shellcheck && HAS_SHELLCHECK=true

test_1_no_sc2329_in_tests() {
    local out
    out="$(cd "$REPO_DIR" && shellcheck -f gcc --include=SC2329 tests/*.sh 2>&1)"
    if [[ -n "$out" ]]; then
        echo "SC2329 still reported ($(printf '%s\n' "$out" | wc -l) lines), first: $(printf '%s\n' "$out" | head -1)" >&2
        return 1
    fi
}

# The `shellcheck --severity` lines of a file, leading whitespace removed.
_lint_lines() {
    grep -E '^[[:space:]]*shellcheck --severity' "$1" | sed -E 's/^[[:space:]]+//'
}

test_2_documented_lint_copies_agree() {
    local doc readme
    doc="$(_lint_lines "$REPO_DIR/CLAUDE.md")"
    readme="$(_lint_lines "$REPO_DIR/README.md")"
    [[ -n "$doc" ]] || { echo "no shellcheck lines found in CLAUDE.md" >&2; return 1; }
    assert_equals "$doc" "$readme" "README.md lint lines differ from CLAUDE.md" || return 1
}

echo "========================================"
echo "Issue #150: lint is readable as pass/fail"
echo "========================================"

run_test_if "$HAS_SHELLCHECK" "150.1  shellcheck reports no SC2329 for tests/" test_1_no_sc2329_in_tests "shellcheck not installed"
run_test "150.2  CLAUDE.md and README.md document the same lint gate" test_2_documented_lint_copies_agree

framework_report
