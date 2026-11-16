#!/usr/bin/env bash
# tests/test_git_date_tz.sh - No timezone-dependent git dates (#151, from #140)
#
# Run with: ./tests/test_git_date_tz.sh
#
# #140 came from two mechanical patterns. This guard fails on either, naming
# file and line:
#
#   CODE     bin/, lib/, install.sh, uninstall.sh: a `--date=format…` must
#            render UTC, i.e. `TZ=UTC … --date=format-local:` on the same line.
#            A plain `--date=format:` uses the committer's own timezone.
#
#   FIXTURE  tests/*.sh: a date-time literal (YYYY-MM-DD[T ]HH:MM…) must carry
#            `Z` or a `±HHMM` / `±HH:MM` offset. Offset-less dates handed to
#            GIT_COMMITTER_DATE / --date= are read in the machine's TZ.
#
# Why every literal in tests/, not only those next to GIT_COMMITTER_DATE: the
# suites pass dates through helpers (`_mk_repo "$repo" "<date>"`), so the
# literal sits at the call site, lines away from the git command. Every date
# literal in tests/ today already carries an offset, so the wider rule costs
# nothing and catches the helper-indirection case.
#
# This file is skipped by the fixture check (passed as a skip argument): its
# own test fixtures contain the offset-less dates it rejects.
#
# KNOWN LIMITATIONS, recorded deliberately. The guard covers the two #140
# patterns and their spellings, not every timezone-dependent date:
#   - Other git date formats (--date=iso/short/rfc, %ci/%cI, %cd with the
#     default format) and `date` without -u are not checked.
#   - Fixture dates are recognised only in ISO shape; an RFC 2822 string such
#     as "Sun, 15 Feb 2026 10:30:00" without offset is not reported.
#   - Lines are checked one at a time: `TZ=UTC \` with git on the next line is
#     reported (safe side; keep the assignment on the git line).
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/test_framework.sh disable=SC1091
source "${SCRIPT_DIR}/test_framework.sh"

framework_init

SELF="$(basename "${BASH_SOURCE[0]}")"

# ============================================================================
# Core check
# ============================================================================
# Report every timezone-dependent git date under <root> (a repo-shaped tree).
#
# Usage: _tz_date_report <root> [<tests-file-to-skip> ...]
# Prints one "<path>:<line>: <reason>" per offender; returns 1 if any.
_tz_date_report() {
    local root="$1"
    shift
    local -a skip=("$@")
    local found=0 file rel n line s skipped

    # --date=format:, --date='format:, --date "format-local: … (git takes all).
    local date_opt='--date[= ]["'"'"']?format(-local)?:'
    # TZ=UTC as the assignment directly in front of git, not anywhere on the line.
    local tz_utc_git='(^|[^[:alnum:]_])TZ=UTC[[:space:]]+git[[:space:]]'

    local -a code_files=()
    [[ -d "${root}/bin" ]] && while IFS= read -r file; do code_files+=("$file"); done \
        < <(find "${root}/bin" -type f | sort)
    [[ -d "${root}/lib" ]] && while IFS= read -r file; do code_files+=("$file"); done \
        < <(find "${root}/lib" -type f -name '*.sh' | sort)
    for file in "${root}/install.sh" "${root}/uninstall.sh"; do
        [[ -f "$file" ]] && code_files+=("$file")
    done

    for file in ${code_files[@]+"${code_files[@]}"}; do
        rel="${file#"${root}"/}"
        n=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            n=$((n + 1))
            [[ "$line" =~ $date_opt ]] || continue
            if [[ -z "${BASH_REMATCH[1]}" ]]; then
                echo "${rel}:${n}: --date=format: renders the committer's timezone; use TZ=UTC … --date=format-local:"
                found=1
            elif ! [[ "$line" =~ $tz_utc_git ]]; then
                echo "${rel}:${n}: --date=format-local: without TZ=UTC renders the machine's timezone"
                found=1
            fi
        done < "$file"
    done

    # A date-time literal, then optionally seconds/fraction, then an offset.
    local dt='[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?'
    local dt_with_offset="${dt} ?(Z|[+-][0-9]{2}:?[0-9]{2})"
    local stripped
    for file in "${root}"/tests/*.sh; do
        [[ -f "$file" ]] || continue
        skipped=0
        for s in ${skip[@]+"${skip[@]}"}; do
            [[ "$(basename "$file")" == "$s" ]] && skipped=1
        done
        [[ $skipped -eq 1 ]] && continue
        rel="${file#"${root}"/}"
        n=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            n=$((n + 1))
            [[ "$line" =~ $dt ]] || continue
            # Remove every well-formed literal; anything date-shaped left over
            # has no offset.
            stripped=$(printf '%s\n' "$line" | sed -E "s/${dt_with_offset}//g")
            if [[ "$stripped" =~ $dt ]]; then
                echo "${rel}:${n}: date '${BASH_REMATCH[0]}' has no Z or ±HHMM offset; git reads it in the machine's TZ"
                found=1
            fi
        done < "$file"
    done

    return $(( found ))
}

# Copy the code half of the real repo into <dir>.
_copy_tree() {
    local dir="$1"
    mkdir -p "$dir"
    cp -r "${REPO_DIR}/bin" "${REPO_DIR}/lib" "${REPO_DIR}/install.sh" "${REPO_DIR}/uninstall.sh" "$dir/"
}

# ============================================================================
# Tests
# ============================================================================

# 1: THE REAL TREE is clean.
test_real_tree_is_clean() {
    local report
    report=$(_tz_date_report "$REPO_DIR" "$SELF") || {
        echo "Timezone-dependent git dates:" >&2
        echo "$report" >&2
        return 1
    }
    [[ -z "$report" ]] || { echo "Unexpected report: ${report}" >&2; return 1; }
}

# 2: the #140 code shape, reintroduced in a copy of bin/cac, is reported with
# file and line.
test_plain_date_format_in_code_is_reported() {
    local dir="${TEST_TMPDIR}/code_plain"
    _copy_tree "$dir"
    sed -i 's/TZ=UTC git/git/; s/--date=format-local:/--date=format:/' "${dir}/bin/cac"
    local lineno
    lineno=$(grep -n -- '--date=format:' "${dir}/bin/cac" | cut -d: -f1)
    [[ -n "$lineno" ]] || { echo "fixture edit did not apply" >&2; return 1; }

    local report rc=0
    report=$(_tz_date_report "$dir") || rc=$?
    [[ $rc -eq 1 ]] || { echo "Expected rc 1, got ${rc}" >&2; return 1; }
    echo "$report" | grep -q "^bin/cac:${lineno}: --date=format:" || {
        echo "Expected bin/cac:${lineno} reported: ${report}" >&2; return 1
    }
}

# 3: format-local alone is not enough — without TZ=UTC it renders the
# machine's timezone.
test_format_local_without_tz_utc_is_reported() {
    local dir="${TEST_TMPDIR}/code_local"
    _copy_tree "$dir"
    sed -i 's/TZ=UTC git/git/' "${dir}/install.sh"
    local lineno
    lineno=$(grep -n -- '--date=format-local:' "${dir}/install.sh" | cut -d: -f1)
    [[ -n "$lineno" ]] || { echo "fixture edit did not apply" >&2; return 1; }

    local report rc=0
    report=$(_tz_date_report "$dir") || rc=$?
    [[ $rc -eq 1 ]] || { echo "Expected rc 1, got ${rc}" >&2; return 1; }
    echo "$report" | grep -q "^install.sh:${lineno}: --date=format-local: without TZ=UTC" || {
        echo "Expected install.sh:${lineno} reported: ${report}" >&2; return 1
    }
}

# 4: quoted and space-separated spellings git accepts are reported too, and
# TZ=UTC only counts as the assignment in front of the git command.
test_other_date_spellings_are_reported() {
    local dir="${TEST_TMPDIR}/code_spellings"
    mkdir -p "${dir}/lib"
    cat > "${dir}/lib/forms.sh" <<'FORMS'
a=$(git log -1 --format=%cd --date='format:%y%m%d' HEAD)
b=$(git log -1 --format=%cd --date="format-local:%y%m%d" HEAD)
c=$(git log -1 --format=%cd --date format:%y%m%d HEAD)
d=$(git log -1 --format=%cd --date=format-local:%y%m%d HEAD) # TZ=UTC
e=$(TZ=UTC git log -1 --format=%cd --date="format-local:%y%m%d" HEAD)
FORMS
    local report rc=0
    report=$(_tz_date_report "$dir") || rc=$?
    [[ $rc -eq 1 ]] || { echo "Expected rc 1, got ${rc}" >&2; return 1; }
    local got
    got=$(echo "$report" | cut -d: -f2 | tr '\n' ' ')
    [[ "$got" == "1 2 3 4 " ]] || {
        echo "Expected lines 1-4 reported, got: ${report}" >&2; return 1
    }
}

# 5: the #140 fixture shape — an offset-less committer date in a test suite,
# here at a helper call site as test_issue_77.sh had it.
test_offsetless_fixture_date_is_reported() {
    local dir="${TEST_TMPDIR}/fixture_plain"
    mkdir -p "${dir}/tests"
    cp "${SCRIPT_DIR}/test_issue_77.sh" "${SCRIPT_DIR}/test_update.sh" "${dir}/tests/"
    sed -i 's/"2026-02-15T10:30:00+0000"/"2026-02-15T10:30:00"/' "${dir}/tests/test_issue_77.sh"
    local lineno
    lineno=$(grep -n '"2026-02-15T10:30:00"' "${dir}/tests/test_issue_77.sh" | cut -d: -f1)
    [[ -n "$lineno" ]] || { echo "fixture edit did not apply" >&2; return 1; }

    local report rc=0
    report=$(_tz_date_report "$dir") || rc=$?
    [[ $rc -eq 1 ]] || { echo "Expected rc 1, got ${rc}" >&2; return 1; }
    echo "$report" | grep -q "^tests/test_issue_77.sh:${lineno}: " || {
        echo "Expected tests/test_issue_77.sh:${lineno} reported: ${report}" >&2; return 1
    }
    # The untouched suite stays clean.
    if echo "$report" | grep -q "^tests/test_update.sh:"; then
        echo "Untouched test_update.sh wrongly reported: ${report}" >&2; return 1
    fi
}

# 6: every accepted offset form passes; only the offset-less one is reported.
test_offset_forms_are_accepted() {
    local dir="${TEST_TMPDIR}/fixture_forms"
    mkdir -p "${dir}/tests"
    cat > "${dir}/tests/test_forms.sh" <<'FORMS'
a="2026-01-01T00:00:00Z"
b="2026-01-01T00:00:00+0000"
c="2026-01-01T00:00:00-0500"
d="2026-01-01T00:00:00+02:00"
e="2026-01-01 00:00:00 +0200"
f="2026-01-01T00:00"
FORMS
    local report rc=0
    report=$(_tz_date_report "$dir") || rc=$?
    [[ $rc -eq 1 ]] || { echo "Expected rc 1, got ${rc}: ${report}" >&2; return 1; }
    [[ "$report" == "tests/test_forms.sh:6: "* && $(echo "$report" | wc -l) -eq 1 ]] || {
        echo "Expected only line 6 reported, got: ${report}" >&2; return 1
    }
}

# ============================================================================
# Run all tests
# ============================================================================

echo "=========================================="
echo "Issue #151 tests: timezone-dependent git dates guard"
echo "=========================================="

run_test "real tree: no timezone-dependent git dates"      test_real_tree_is_clean
run_test "plain --date=format: in code IS reported"        test_plain_date_format_in_code_is_reported
run_test "format-local without TZ=UTC IS reported"         test_format_local_without_tz_utc_is_reported
run_test "quoted / spaced --date forms ARE reported"     test_other_date_spellings_are_reported
run_test "offset-less fixture date IS reported"            test_offsetless_fixture_date_is_reported
run_test "Z / +HHMM / +HH:MM offsets accepted"             test_offset_forms_are_accepted

framework_report
