#!/usr/bin/env bash
# tests/test_gate_sweep.sh - Tests for the landing sweep (Issue #104)
#
# Run with: ./tests/test_gate_sweep.sh
#
# Every test builds a throwaway git repo and sweeps it. The arms that matter are
# the POSITIVE ones: a sweep that only ever proves "exits 0 on a clean repo"
# would pass just as well if it checked nothing at all. So each negative is
# paired with a control showing the opposite condition produces the opposite
# result.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/test_framework.sh disable=SC1091
source "${SCRIPT_DIR}/test_framework.sh"

framework_require_commands git

GATE_SWEEP="${SCRIPT_DIR}/gate_sweep.sh"

framework_init

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

# A repo whose history contains a landing commit for #1 and a tracked file.
_repo_with_landed_1() {
    local repo="$1"
    _new_repo "$repo"
    echo "content" > "${repo}/tracked.txt"
    git -C "$repo" add tracked.txt
    git -C "$repo" commit -q -m "fix: the thing (#1)"
}

# Run the sweep inside $repo, publishing its output and exit code as globals.
#
# Deliberately NOT `rc=$(_run_sweep ...)`: command substitution runs the helper
# in a subshell, so the output global would never reach the caller and every
# grep against it would match nothing — a negative assertion satisfied by an
# empty string. Same family as the pipe trap this sweep exists to avoid, and it
# bit this file during development.
SWEEP_OUT=""
SWEEP_RC=0
_run_sweep() {
    local repo="$1"; shift
    SWEEP_RC=0
    SWEEP_OUT=$( cd "$repo" && bash "$GATE_SWEEP" "$@" 2>&1 ) || SWEEP_RC=$?
}

# ============================================================================
# Tests
# ============================================================================

# 1: a landed issue on a clean repo sweeps green.
test_clean_repo_passes() {
    local repo="${TEST_TMPDIR}/s1"
    _repo_with_landed_1 "$repo"

    _run_sweep "$repo" --ref HEAD --issues "1"

    [[ "$SWEEP_RC" -eq 0 ]] || { echo "Expected rc 0, got ${SWEEP_RC}: ${SWEEP_OUT}" >&2; return 1; }
    echo "$SWEEP_OUT" | grep -q "#1.*OK" || {
        echo "Expected #1 reported OK: ${SWEEP_OUT}" >&2; return 1
    }
}

# 2: THE CONTROL ARM. A stranded issue must actually be REPORTED, and the
# landed one must not be swept up with it. If the sweep silently lost
# verify_gate's exit code — the pipe trap — this test goes green when it must
# be red, which is the whole reason it exists.
test_stranded_issue_is_reported() {
    local repo="${TEST_TMPDIR}/s2"
    _repo_with_landed_1 "$repo"

    _run_sweep "$repo" --ref HEAD --issues "1 2"

    [[ "$SWEEP_RC" -eq 1 ]] || { echo "Expected rc 1, got ${SWEEP_RC}: ${SWEEP_OUT}" >&2; return 1; }
    echo "$SWEEP_OUT" | grep -q "#2.*STRANDED" || {
        echo "Expected #2 reported STRANDED: ${SWEEP_OUT}" >&2; return 1
    }
    echo "$SWEEP_OUT" | grep -q "#1.*OK" || {
        echo "Expected #1 still reported OK: ${SWEEP_OUT}" >&2; return 1
    }
    echo "$SWEEP_OUT" | grep -q "Stranded (no landing commit): 2" || {
        echo "Expected summary naming 2 as stranded: ${SWEEP_OUT}" >&2; return 1
    }
}

# 3: the repo-global dirty condition is stated ONCE, not once per issue, and it
# does not disguise itself as a per-issue "no landing commit".
test_dirty_tree_reported_once() {
    local repo="${TEST_TMPDIR}/s3"
    _repo_with_landed_1 "$repo"
    echo "modified" >> "${repo}/tracked.txt"

    _run_sweep "$repo" --ref HEAD --issues "1 2 3"

    [[ "$SWEEP_RC" -eq 1 ]] || { echo "Expected rc 1, got ${SWEEP_RC}: ${SWEEP_OUT}" >&2; return 1; }

    local banner_count
    banner_count=$(echo "$SWEEP_OUT" | grep -c "REPO-GLOBAL" || true)
    [[ "$banner_count" -eq 1 ]] || {
        echo "Expected exactly 1 REPO-GLOBAL banner, got ${banner_count}: ${SWEEP_OUT}" >&2
        return 1
    }

    # #1 has a landing commit; a dirty tree must not reclassify it as stranded.
    echo "$SWEEP_OUT" | grep -q "#1.*OK" || {
        echo "Dirty tree wrongly reclassified #1: ${SWEEP_OUT}" >&2; return 1
    }
    echo "$SWEEP_OUT" | grep -q "#2.*STRANDED" || {
        echo "Expected #2 STRANDED: ${SWEEP_OUT}" >&2; return 1
    }
}

# 3b: control for test 3 — with the tree clean, the banner must be ABSENT.
# Without this, test 3 would also pass against a sweep that always prints it.
test_clean_tree_has_no_banner() {
    local repo="${TEST_TMPDIR}/s3b"
    _repo_with_landed_1 "$repo"

    _run_sweep "$repo" --ref HEAD --issues "1"

    [[ "$SWEEP_RC" -eq 0 ]] || { echo "Expected rc 0, got ${SWEEP_RC}: ${SWEEP_OUT}" >&2; return 1; }
    if echo "$SWEEP_OUT" | grep -q "REPO-GLOBAL"; then
        echo "REPO-GLOBAL banner printed on a clean tree: ${SWEEP_OUT}" >&2
        return 1
    fi
}

# 4: untracked files are not the sweep's business — verify_gate.sh ignores them
# by design so unrelated in-flight work does not false-fail the gate. The sweep
# must not invent a stricter invariant.
test_untracked_file_ignored() {
    local repo="${TEST_TMPDIR}/s4"
    _repo_with_landed_1 "$repo"
    echo "scratch" > "${repo}/untracked.txt"

    _run_sweep "$repo" --ref HEAD --issues "1"

    [[ "$SWEEP_RC" -eq 0 ]] || { echo "Expected rc 0 with untracked file, got ${SWEEP_RC}: ${SWEEP_OUT}" >&2; return 1; }
}

# 5: word-bounded matching is inherited from verify_gate.sh — #1 must not be
# satisfied by a commit mentioning #100.
test_issue_number_not_matched_by_prefix() {
    local repo="${TEST_TMPDIR}/s5"
    _new_repo "$repo"
    git -C "$repo" commit -q --allow-empty -m "feat: unrelated (#100)"

    _run_sweep "$repo" --ref HEAD --issues "1"

    [[ "$SWEEP_RC" -eq 1 ]] || { echo "Expected rc 1, got ${SWEEP_RC}: ${SWEEP_OUT}" >&2; return 1; }
    echo "$SWEEP_OUT" | grep -q "#1.*STRANDED" || {
        echo "Expected #1 STRANDED: ${SWEEP_OUT}" >&2; return 1
    }
}

# 6: a bad issue number is a usage error (rc 2), not a silent clean sweep.
test_bad_issue_number_is_usage_error() {
    local repo="${TEST_TMPDIR}/s6"
    _repo_with_landed_1 "$repo"

    _run_sweep "$repo" --ref HEAD --issues "abc"

    [[ "$SWEEP_RC" -eq 2 ]] || { echo "Expected rc 2, got ${SWEEP_RC}: ${SWEEP_OUT}" >&2; return 1; }
}

# 7: an unresolvable ref is an env error, not a pass.
test_bad_ref_is_env_error() {
    local repo="${TEST_TMPDIR}/s7"
    _repo_with_landed_1 "$repo"

    _run_sweep "$repo" --ref no-such-ref --issues "1"

    [[ "$SWEEP_RC" -eq 2 ]] || { echo "Expected rc 2, got ${SWEEP_RC}: ${SWEEP_OUT}" >&2; return 1; }
}

# 8: the default (no --issues) path queries GitHub. Stubbed so the test is
# hermetic, following the mock-on-PATH precedent in tests/test_env.sh. The real
# PATH is retained: narrowing it to the stub directory alone would break every
# external command the sweep needs (Issue #106).
test_gh_query_path_sweeps_returned_issues() {
    local repo="${TEST_TMPDIR}/s8"
    _repo_with_landed_1 "$repo"

    local stub_dir="${TEST_TMPDIR}/s8_stub"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/gh" <<'STUB'
#!/usr/bin/env bash
# Canned REST responses: milestone lookup, then the issue list.
case "$*" in
    *milestones*) echo "9" ;;
    *issues*)     printf '1\n2\n' ;;
    *)            exit 1 ;;
esac
STUB
    chmod +x "${stub_dir}/gh"

    SWEEP_RC=0
    SWEEP_OUT=$( cd "$repo" && PATH="${stub_dir}:${PATH}" bash "$GATE_SWEEP" --ref HEAD 2>&1 ) || SWEEP_RC=$?

    [[ "$SWEEP_RC" -eq 1 ]] || { echo "Expected rc 1, got ${SWEEP_RC}: ${SWEEP_OUT}" >&2; return 1; }
    echo "$SWEEP_OUT" | grep -q "#1.*OK" || {
        echo "Expected #1 OK from stubbed gh list: ${SWEEP_OUT}" >&2; return 1
    }
    echo "$SWEEP_OUT" | grep -q "#2.*STRANDED" || {
        echo "Expected #2 STRANDED from stubbed gh list: ${SWEEP_OUT}" >&2; return 1
    }
}

# 9: if the GitHub query FAILS, the sweep must not exit 0. A sweep that checked
# nothing and reported success is precisely the failure mode #104 is about.
test_gh_failure_is_not_a_silent_pass() {
    local repo="${TEST_TMPDIR}/s9"
    _repo_with_landed_1 "$repo"

    local stub_dir="${TEST_TMPDIR}/s9_stub"
    mkdir -p "$stub_dir"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/gh"
    chmod +x "${stub_dir}/gh"

    SWEEP_RC=0
    SWEEP_OUT=$( cd "$repo" && PATH="${stub_dir}:${PATH}" bash "$GATE_SWEEP" --ref HEAD 2>&1 ) || SWEEP_RC=$?

    [[ "$SWEEP_RC" -eq 2 ]] || { echo "Expected rc 2 on gh failure, got ${SWEEP_RC}: ${SWEEP_OUT}" >&2; return 1; }
}

# 10: an empty milestone is a legitimate clean result, distinct from a failure.
test_empty_issue_list_is_a_clean_result() {
    local repo="${TEST_TMPDIR}/s10"
    _repo_with_landed_1 "$repo"

    local stub_dir="${TEST_TMPDIR}/s10_stub"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *milestones*) echo "9" ;;
    *issues*)     : ;;
    *)            exit 1 ;;
esac
STUB
    chmod +x "${stub_dir}/gh"

    SWEEP_RC=0
    SWEEP_OUT=$( cd "$repo" && PATH="${stub_dir}:${PATH}" bash "$GATE_SWEEP" --ref HEAD 2>&1 ) || SWEEP_RC=$?

    [[ "$SWEEP_RC" -eq 0 ]] || { echo "Expected rc 0 on empty list, got ${SWEEP_RC}: ${SWEEP_OUT}" >&2; return 1; }
    echo "$SWEEP_OUT" | grep -q "nothing to sweep" || {
        echo "Expected 'nothing to sweep': ${SWEEP_OUT}" >&2; return 1
    }
}

# ============================================================================
# Run all tests
# ============================================================================

echo "=========================================="
echo "Issue #104 tests: landing sweep"
echo "=========================================="

run_test "clean repo, landed issue passes"        test_clean_repo_passes
run_test "stranded issue is REPORTED"             test_stranded_issue_is_reported
run_test "dirty tree reported exactly once"       test_dirty_tree_reported_once
run_test "clean tree prints no dirty banner"      test_clean_tree_has_no_banner
run_test "untracked file does not fail the sweep" test_untracked_file_ignored
run_test "#1 not satisfied by a #100 commit"      test_issue_number_not_matched_by_prefix
run_test "bad issue number is a usage error"      test_bad_issue_number_is_usage_error
run_test "unresolvable ref is an env error"       test_bad_ref_is_env_error
run_test "gh query path sweeps returned issues"   test_gh_query_path_sweeps_returned_issues
run_test "gh failure is not a silent pass"        test_gh_failure_is_not_a_silent_pass
run_test "empty milestone is a clean result"      test_empty_issue_list_is_a_clean_result

framework_report
