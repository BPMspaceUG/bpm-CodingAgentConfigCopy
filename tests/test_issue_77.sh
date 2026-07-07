#!/usr/bin/env bash
# tests/test_issue_77.sh - Tests for Issue #77
#
# Version dirty/draft/clean detection at install time.
#
# Root cause: install.sh always downloads the pushed release from GitHub, so the
# install-time source dir is never a git checkout. An installed cac therefore
# represents the CLEAN pushed release. Direction A ("installed = clean"):
#   - stamp_version bakes the clean HEAD commit date (YYMMDD-HHMM), never a suffix.
#   - -dirty / -draft are runtime-checkout-only concepts (handled by bin/cac).
#   - When there is no .git, _resolve_install_version supplies the GitHub API
#     commit date, or the defined "dev" sentinel when offline.
#
# Covers the four source states from the issue's acceptance criteria plus the
# `cac update` suffix round-trip (criterion 5).
#
# Run with: ./tests/test_issue_77.sh
# Or:       ./tests/run_tests.sh issue_77
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/test_framework.sh"

# lib/update.sh provides the version comparison helpers used by `cac update`.
source "${PROJECT_ROOT}/lib/update.sh"

# Extract the REAL install-time functions from install.sh so we can test them in
# isolation. install.sh calls main "$@" at the bottom, so we cannot source it.
_load_install_fns() {
    local install_sh="${PROJECT_ROOT}/install.sh"
    eval "$(sed -n '/^stamp_version()/,/^}/p' "$install_sh")"
    eval "$(sed -n '/^_resolve_install_version()/,/^}/p' "$install_sh")"
    # stamp_version references warn() on an error path
    warn() { echo "WARN: $*" >&2; }
}

# Helper: create a git repo with a single commit at a fixed date
_mk_repo() {
    local repo="$1"
    local commit_date="$2"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    echo "hello" > "$repo/file.txt"
    git -C "$repo" add file.txt
    GIT_COMMITTER_DATE="$commit_date" git -C "$repo" commit -q -m "initial" --date="$commit_date"
}

# Helper: give the repo an upstream so it is "pushed" (clean state)
_mk_upstream() {
    local repo="$1"
    git -C "$repo" remote add origin "$repo" 2>/dev/null || true
    git -C "$repo" fetch -q origin 2>/dev/null || true
    git -C "$repo" branch --set-upstream-to=origin/main main 2>/dev/null || true
}

# ============================================================================
# Install-time stamping — the four source states (Direction A: always clean)
# ============================================================================

# State 1: source has uncommitted changes -> clean commit date, NO -dirty
test_issue77_dirty_source_bakes_clean() {
    _load_install_fns
    local repo="${TEST_TMPDIR}/i77_dirty_repo"
    _mk_repo "$repo" "2026-03-24T13:04:00"
    echo "uncommitted change" > "$repo/file.txt"

    local target="${TEST_TMPDIR}/i77_dirty_target"
    echo 'VERSION="dev"' > "$target"
    stamp_version "$target" "$repo"

    local stamped
    stamped=$(grep '^VERSION=' "$target" | head -1)
    # Exact match: a wall-clock or author-date impl, or any -dirty/-draft suffix, must fail here.
    assert_equals 'VERSION="260324-1304"' "$stamped" "dirty source bakes exact clean committer date (no suffix)"
}

# State 2: committed-but-unpushed source -> clean commit date, NO -draft
test_issue77_unpushed_source_bakes_clean() {
    _load_install_fns
    local repo="${TEST_TMPDIR}/i77_draft_repo"
    _mk_repo "$repo" "2026-04-20T16:15:00"
    # No upstream configured => "draft" at runtime, but install bakes clean.

    local target="${TEST_TMPDIR}/i77_draft_target"
    echo 'VERSION="dev"' > "$target"
    stamp_version "$target" "$repo"

    local stamped
    stamped=$(grep '^VERSION=' "$target" | head -1)
    # Exact match: a wall-clock or author-date impl, or any -dirty/-draft suffix, must fail here.
    assert_equals 'VERSION="260420-1615"' "$stamped" "unpushed source bakes exact clean commit date (no suffix)"
}

# State 3: clean + pushed source -> plain YYMMDD-HHMM
test_issue77_clean_pushed_source_bakes_clean() {
    _load_install_fns
    local repo="${TEST_TMPDIR}/i77_clean_repo"
    _mk_repo "$repo" "2026-02-15T10:30:00"
    _mk_upstream "$repo"

    local target="${TEST_TMPDIR}/i77_clean_target"
    echo 'VERSION="dev"' > "$target"
    stamp_version "$target" "$repo"

    local stamped
    stamped=$(grep '^VERSION=' "$target" | head -1)
    assert_match '^VERSION="260215-1030"$' "$stamped" "clean pushed source bakes plain YYMMDD-HHMM"
}

# State 4a: no .git, GitHub API reachable -> API commit date (mocked via file://)
test_issue77_no_git_uses_api_commit_date() {
    _load_install_fns
    local fixture="${TEST_TMPDIR}/i77_api.json"
    cat > "$fixture" <<'JSON'
{
  "commit": {
    "author":    { "date": "2026-03-24T12:00:00Z" },
    "committer": { "date": "2026-03-24T13:04:00Z" }
  }
}
JSON

    local ver
    ver=$(CAC_INSTALL_API_URL="file://${fixture}" _resolve_install_version)
    assert_equals "260324-1304" "$ver" "no-git install uses API committer date"
}

# State 4b: no .git and API unreachable -> defined "dev" sentinel (offline)
test_issue77_no_git_offline_uses_dev_sentinel() {
    _load_install_fns
    local ver
    ver=$(CAC_INSTALL_API_URL="file://${TEST_TMPDIR}/does_not_exist.json" _resolve_install_version)
    assert_equals "dev" "$ver" "offline no-git install falls back to defined 'dev' sentinel"
}

# End-to-end: VERSION="dev" line is replaced (first occurrence) with clean version
test_issue77_stamp_replaces_version_line() {
    _load_install_fns
    local repo="${TEST_TMPDIR}/i77_e2e_repo"
    _mk_repo "$repo" "2026-05-09T09:14:00"
    _mk_upstream "$repo"

    # Two VERSION= lines: only the FIRST must be replaced (first-occurrence semantics).
    local target="${TEST_TMPDIR}/i77_e2e_target"
    cat > "$target" <<'EOF'
#!/usr/bin/env bash
VERSION="dev"
echo "cac v${VERSION}"
VERSION="dev"
EOF
    stamp_version "$target" "$repo"

    local first second
    first=$(grep '^VERSION=' "$target" | sed -n '1p')
    second=$(grep '^VERSION=' "$target" | sed -n '2p')
    assert_equals 'VERSION="260509-0914"' "$first" "first VERSION line replaced with clean version"
    assert_equals 'VERSION="dev"' "$second" "later VERSION line left unchanged (first-occurrence only)"
}

# ============================================================================
# cac update suffix round-trip (acceptance criterion 5)
# No spurious downgrade/upgrade across -dirty / -draft / clean.
# ============================================================================

# dirty / draft / clean of the same base normalize to the same value
test_issue77_normalize_collapses_suffixes() {
    local base clean dirty draft
    base="260225-1542"
    clean=$(_update_normalize_version "$base")
    dirty=$(_update_normalize_version "${base}-dirty")
    draft=$(_update_normalize_version "${base}-draft")
    assert_equals "$base" "$clean" "clean normalizes to base"
    assert_equals "$base" "$dirty" "dirty normalizes to base"
    assert_equals "$base" "$draft" "draft normalizes to base"
}

# Same base with a suffix must compare as up-to-date in both directions
test_issue77_suffix_same_base_is_up_to_date() {
    local base="260225-1542"
    local local_clean remote_clean
    local_clean=$(_update_normalize_version "${base}-dirty")
    remote_clean=$(_update_normalize_version "$base")
    _update_version_ge "$local_clean" "$remote_clean" \
        || { echo "dirty local vs clean remote should be up-to-date" >&2; return 1; }

    local_clean=$(_update_normalize_version "$base")
    remote_clean=$(_update_normalize_version "${base}-draft")
    _update_version_ge "$local_clean" "$remote_clean" \
        || { echo "clean local vs draft remote should be up-to-date" >&2; return 1; }
}

# The "dev" sentinel (offline install) must always offer an update, never stick
test_issue77_dev_sentinel_offers_update() {
    local local_clean remote_clean
    local_clean=$(_update_normalize_version "dev")
    remote_clean=$(_update_normalize_version "260301-1500")
    if _update_version_ge "$local_clean" "$remote_clean"; then
        echo "dev local vs real remote must NOT be up-to-date (update expected)" >&2
        return 1
    fi
}

# Older suffixed local vs newer clean remote -> update available (no false up-to-date)
test_issue77_older_dirty_needs_update() {
    local local_clean remote_clean
    local_clean=$(_update_normalize_version "260203-1222-dirty")
    remote_clean=$(_update_normalize_version "260301-1500")
    if _update_version_ge "$local_clean" "$remote_clean"; then
        echo "older dirty local vs newer remote must NOT be up-to-date" >&2
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo "========================================"
    echo "Issue #77 Tests (install-time versioning)"
    echo "========================================"
    echo ""

    framework_init

    echo "--- Install-time stamping: four source states ---"
    run_test "dirty source bakes clean version" test_issue77_dirty_source_bakes_clean
    run_test "unpushed source bakes clean version" test_issue77_unpushed_source_bakes_clean
    run_test "clean+pushed source bakes plain version" test_issue77_clean_pushed_source_bakes_clean
    run_test "no-git uses API commit date" test_issue77_no_git_uses_api_commit_date
    run_test "no-git offline uses dev sentinel" test_issue77_no_git_offline_uses_dev_sentinel
    run_test "stamp replaces VERSION line" test_issue77_stamp_replaces_version_line
    echo ""

    echo "--- cac update suffix round-trip ---"
    run_test "normalize collapses suffixes" test_issue77_normalize_collapses_suffixes
    run_test "suffix same base is up-to-date" test_issue77_suffix_same_base_is_up_to_date
    run_test "dev sentinel offers update" test_issue77_dev_sentinel_offers_update
    run_test "older dirty needs update" test_issue77_older_dirty_needs_update
    echo ""

    framework_report
    exit $?
}

main "$@"
