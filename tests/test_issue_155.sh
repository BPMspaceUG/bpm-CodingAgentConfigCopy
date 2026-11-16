#!/usr/bin/env bash
# tests/test_issue_155.sh - Tests for Issue #155
#
# `run_tests.sh <filter>` with a filter that matches no registered suite used to
# run nothing and still print "All test suites passed!" with exit 0. It now
# prints "no suite matches '<filter>'" and exits non-zero.
#
# Seam: the runner's command line (exit code and output). The runner is copied
# into a fixture directory outside any git repo, where every suite it registers
# is an `exit 0` stub, so the real suites never run.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

FIXTURE="${TEST_TMPDIR}/tests"
mkdir -p "$FIXTURE"
cp "$SCRIPT_DIR/run_tests.sh" "$FIXTURE/run_tests.sh"
REGISTERED=0
while IFS= read -r suite; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/$suite"
    chmod +x "$FIXTURE/$suite"
    ((REGISTERED++)) || true
done < <(grep -oE 'run_test_suite "[^"]+" "test_[A-Za-z0-9_]+\.sh"' "$SCRIPT_DIR/run_tests.sh" \
         | grep -oE 'test_[A-Za-z0-9_]+\.sh"$' | tr -d '"')

OUT=""
RC=0
_run() { RC=0; OUT="$("$FIXTURE/run_tests.sh" "$@" 2>&1)" || RC=$?; }

test_1_unknown_filter_fails_with_message() {
    # Not a number: an issue key like 54 could be registered one day.
    _run no_such_suite
    [[ $RC -ne 0 ]] || { echo "unknown filter exited 0: $OUT" >&2; return 1; }
    grep -qF "no suite matches 'no_such_suite'" <<<"$OUT" || { echo "message missing: $OUT" >&2; return 1; }
    if grep -qF "All test suites passed!" <<<"$OUT"; then
        echo "unknown filter still reports success: $OUT" >&2; return 1
    fi
}

test_2_known_filter_runs_one_suite() {
    _run bundle
    [[ $RC -eq 0 ]] || { echo "known filter exited $RC: $OUT" >&2; return 1; }
    grep -qF "Test suites passed: 1" <<<"$OUT" || { echo "expected 1 suite: $OUT" >&2; return 1; }
    if grep -qF "no suite matches" <<<"$OUT"; then
        echo "known filter reported as unknown: $OUT" >&2; return 1
    fi
}

test_3_no_filter_runs_every_suite() {
    # Floor well below today's 48: catches the regex above silently matching
    # few or no registrations, which would make this test vacuous.
    [[ $REGISTERED -gt 40 ]] || { echo "fixture found only $REGISTERED suites" >&2; return 1; }
    _run
    [[ $RC -eq 0 ]] || { echo "no filter exited $RC: $OUT" >&2; return 1; }
    grep -qF "Test suites passed: $REGISTERED" <<<"$OUT" || {
        echo "expected $REGISTERED suites: $(tail -5 <<<"$OUT")" >&2; return 1; }
    grep -qF "All test suites passed!" <<<"$OUT" || { echo "no success line: $OUT" >&2; return 1; }
}

echo "=========================================="
echo "Issue #155 tests: unknown filter fails"
echo "=========================================="

run_test "unknown filter: non-zero exit and message" test_1_unknown_filter_fails_with_message
run_test "known filter: one suite, exit 0"           test_2_known_filter_runs_one_suite
run_test "no filter: every suite, exit 0"            test_3_no_filter_runs_every_suite

framework_report
