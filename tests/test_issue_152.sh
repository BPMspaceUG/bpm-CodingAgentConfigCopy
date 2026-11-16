#!/usr/bin/env bash
# tests/test_issue_152.sh - Tests for Issue #152
#
# install.sh runs `main "$@"` at the bottom, so suites cannot source it. Some
# extract single functions by name (`sed -n '/^name()/,/^}/p' install.sh`).
# A new helper called from an extracted function breaks those suites although
# nothing in install.sh says so. The header of install.sh therefore names
# every such suite; this guard keeps that list complete and free of stale names.
#
# Seams: the "TESTS EXTRACT FUNCTIONS" block of install.sh's header comment;
# the contents of tests/*.sh.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

# Suites (basenames) that extract install.sh functions by name: a line holding
# the `/,/^}/p` range and naming install.sh (literally or as $install_sh).
_extracting_suites() {
    local f
    for f in "$REPO_DIR"/tests/*.sh; do
        [[ "$(basename "$f")" == "test_issue_152.sh" ]] && continue
        grep -E '/,/\^\}/p' "$f" | grep -qE 'install(\.sh|_sh)' && basename "$f"
    done
}

# Suite basenames named in install.sh's header comment (lines before `set -e…`).
_named_suites() {
    sed -n '1,/^set -euo pipefail/p' "$REPO_DIR/install.sh" \
        | grep -oE 'tests/test_[A-Za-z0-9_]+\.sh' | sed 's#^tests/##' | sort -u
}

# Suites on the header's "Other" lines (they depend on install.sh differently).
_other_suites() {
    sed -n '1,/^set -euo pipefail/p' "$REPO_DIR/install.sh" \
        | sed -n '/Other suites/,/^$/p' \
        | grep -oE 'tests/test_[A-Za-z0-9_]+\.sh' | sed 's#^tests/##' | sort -u
}

test_1_every_extracting_suite_is_named() {
    local named missing="" s
    named="$(_named_suites)"
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        grep -qxF "$s" <<<"$named" || missing+=" $s"
    done < <(_extracting_suites)
    [[ -z "$missing" ]] || { echo "not named in install.sh header:$missing" >&2; return 1; }
}

test_2_no_stale_names() {
    local extracting stale="" s
    extracting="$(_extracting_suites)"
    [[ -n "$extracting" ]] || { echo "detection found no extracting suite at all" >&2; return 1; }
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        # Suites the header names for another reason (whole-file load, copies)
        # are listed after "Other" and are not checked here.
        grep -qxF "$s" <<<"$extracting" && continue
        _other_suites | grep -qxF "$s" || stale+=" $s"
    done < <(_named_suites)
    [[ -z "$stale" ]] || { echo "named in install.sh header but do not extract by name:$stale" >&2; return 1; }
}

echo "========================================"
echo "Issue #152: install.sh names the suites that extract its functions"
echo "========================================"

run_test "152.1  every suite extracting install.sh functions is named in its header" test_1_every_extracting_suite_is_named
run_test "152.2  every suite named there still extracts (no stale names)" test_2_no_stale_names

framework_report
