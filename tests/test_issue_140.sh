#!/usr/bin/env bash
# tests/test_issue_140.sh - Tests for Issue #140
#
# Every cac version string is the HEAD commit's committer date in UTC
# (YYMMDD-HHMM), whichever path produced it. Before the fix the git paths used
# the committer's own timezone, so one commit was 260726-1948 on a checkout
# install and 260726-1748 on a download install.
#
# Seams:
#   - `bin/cac --version` run from a git checkout
#   - stamp_version, _resolve_install_version and install_files, extracted from
#     install.sh (as tests/test_issue_77.sh does)
#   - update_get_remote_version and update_check (lib/update.sh)
# The commits API is served from tests/fixtures/github-commits-main.json via
# file:// URLs. No network.
#
# shellcheck disable=SC2317,SC2016  # run_test calls indirectly; bash -c bodies are single-quoted on purpose

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

# Committer date with a +0200 offset: 17:48 UTC, 19:48 local to the committer.
COMMIT_DATE="2026-07-26T19:48:51+0200"
EXPECTED="260726-1748"
FIXTURE="$REPO_DIR/tests/fixtures/github-commits-main.json"
ZONES=(UTC Europe/Berlin America/New_York)

# A git checkout of the current bin/ and lib/ with one pushed commit at
# $COMMIT_DATE (author date differs). Created once. Sets CHECKOUT.
mk_checkout() {
    CHECKOUT="$TEST_TMPDIR/checkout"
    [[ -d "$CHECKOUT/.git" ]] && return 0
    mkdir -p "$CHECKOUT"
    cp -r "$REPO_DIR/bin" "$REPO_DIR/lib" "$CHECKOUT/"
    git -C "$CHECKOUT" init -q -b main
    git -C "$CHECKOUT" config user.email "fixture@example.invalid"
    git -C "$CHECKOUT" config user.name "FIXTURE"
    git -C "$CHECKOUT" add -A
    GIT_COMMITTER_DATE="$COMMIT_DATE" \
        git -C "$CHECKOUT" commit -q -m "fixture" --date="2026-07-25T08:00:00+0200"
    # Pushed state, so the version carries no -draft suffix.
    git -C "$CHECKOUT" remote add origin "$CHECKOUT"
    git -C "$CHECKOUT" fetch -q origin
    git -C "$CHECKOUT" branch -q --set-upstream-to=origin/main main
}

# Load the install.sh functions under test into this shell.
load_install_fns() {
    local f
    for f in stamp_version _resolve_install_version _install_github_api_get \
             install_files update_cli_lib_path install_completions; do
        eval "$(sed -n "/^${f}()/,/^}/p" "$REPO_DIR/install.sh")"
    done
    info() { :; }; success() { :; }; warn() { echo "WARN: $*" >&2; }
    die() { echo "DIE: $*" >&2; return 1; }
}

# 140.1: bin/cac --version from a checkout prints the UTC committer date,
#        whatever TZ the machine running it has.
test_140_1_checkout_version_is_utc() {
    mk_checkout
    local tz out
    for tz in "${ZONES[@]}"; do
        out=$(TZ="$tz" "$CHECKOUT/bin/cac" --version 2>&1)
        assert_equals "cac version $EXPECTED" "$out" "pushed checkout, no suffix (TZ=$tz)" || return 1
    done
}

# 140.2: stamp_version bakes the UTC committer date, for every TZ.
test_140_2_stamp_version_is_utc() {
    mk_checkout
    load_install_fns
    local tz target
    for tz in "${ZONES[@]}"; do
        target="$TEST_TMPDIR/stamp_$RANDOM"
        echo 'VERSION="dev"' > "$target"
        TZ="$tz" stamp_version "$target" "$CHECKOUT"
        assert_equals "VERSION=\"$EXPECTED\"" "$(grep '^VERSION=' "$target")" "stamp with TZ=$tz" || return 1
    done
}

# 140.3: _resolve_install_version takes the committer date, not the author
#        date, from a real-shape commits API response, pretty or compact.
test_140_3_resolve_install_version_committer_date() {
    load_install_fns
    local compact="$TEST_TMPDIR/compact.json" ver
    jq -c . "$FIXTURE" > "$compact"
    ver=$(CAC_INSTALL_API_URL="file://$FIXTURE" _resolve_install_version)
    assert_equals "$EXPECTED" "$ver" "pretty-printed response" || return 1
    ver=$(CAC_INSTALL_API_URL="file://$compact" _resolve_install_version)
    assert_equals "$EXPECTED" "$ver" "single-line response" || return 1
}

# Serve the fixture as <base>/commits/main. Sets API_BASE.
mk_api_base() {
    API_BASE="$TEST_TMPDIR/api_$1"
    mkdir -p "$API_BASE/commits"
    if [[ "$1" == compact ]]; then
        jq -c . "$FIXTURE" > "$API_BASE/commits/main"
    else
        cp "$FIXTURE" "$API_BASE/commits/main"
    fi
}

# Run update_get_remote_version (or another lib/update.sh function) in a
# clean child. Sets OUT, RC.
run_update_fn() {
    local fn="$1"; shift
    RC=0
    OUT=$(env -u GH_TOKEN -u GITHUB_TOKEN "$@" \
        bash -c 'source "$1/lib/logging.sh"; source "$1/lib/utils.sh" 2>/dev/null
                 source "$1/lib/update.sh"; "$2"' _ "$REPO_DIR" "$fn" 2>&1) || RC=$?
}

# 140.4: update_get_remote_version takes the committer date, pretty or compact.
test_140_4_remote_version_committer_date() {
    local shape
    for shape in pretty compact; do
        mk_api_base "$shape"
        run_update_fn update_get_remote_version UPDATE_GITHUB_API_BASE="file://$API_BASE"
        assert_equals 0 "$RC" "exit code ($shape)" || { echo "$OUT" >&2; return 1; }
        assert_equals "$EXPECTED" "$OUT" "remote version ($shape)" || return 1
    done
}

# install_files from source dir $1 into $2 (a fake user-scope prefix).
install_from() {
    local src="$1" prefix="$2"
    BIN_DIR="$prefix/bin" LIB_DIR="$prefix/lib/cac" CONFIG_DIR="$prefix/config" \
    BASH_COMPLETION_DIR="$prefix/bc" ZSH_COMPLETION_DIR="$prefix/zc" INSTALL_MODE="user-local" \
        install_files "$src"
}

# 140.5: a checkout install and a download install of the same commit report
#        the same `cac --version`, in a non-UTC TZ.
test_140_5_checkout_and_download_install_agree() {
    mk_checkout
    load_install_fns
    local download="$TEST_TMPDIR/download"
    mkdir -p "$download"
    cp -r "$REPO_DIR/bin" "$REPO_DIR/lib" "$download/"   # no .git, like a download

    local a b
    TZ=Europe/Berlin CAC_INSTALL_API_URL="file://$FIXTURE" install_from "$CHECKOUT" "$TEST_TMPDIR/p_checkout" || return 1
    TZ=Europe/Berlin CAC_INSTALL_API_URL="file://$FIXTURE" install_from "$download" "$TEST_TMPDIR/p_download" || return 1
    a=$(TZ=Europe/Berlin "$TEST_TMPDIR/p_checkout/bin/cac" --version 2>&1)
    b=$(TZ=Europe/Berlin "$TEST_TMPDIR/p_download/bin/cac" --version 2>&1)
    assert_contains "$EXPECTED" "$a" "checkout install" || return 1
    assert_equals "$a" "$b" "checkout and download install agree" || return 1
}

# 140.6: cac update --check on a checkout install reports "up to date" when
#        the remote is that same commit.
test_140_6_update_check_up_to_date() {
    mk_checkout
    load_install_fns
    local prefix="$TEST_TMPDIR/p_check"
    TZ=Europe/Berlin CAC_INSTALL_API_URL="file:///nonexistent" install_from "$CHECKOUT" "$prefix" || return 1
    mk_api_base pretty
    run_update_fn update_check TZ=Europe/Berlin PATH="$prefix/bin:$PATH" \
        UPDATE_GITHUB_API_BASE="file://$API_BASE"
    assert_contains "Installed version: $EXPECTED" "$OUT" "installed version" || return 1
    assert_contains "Already up to date." "$OUT" "up to date" || return 1
    assert_equals 1 "$RC" "update_check rc (1 = up to date)" || return 1
}

run_test "140.1 bin/cac --version from a checkout is the UTC committer date" test_140_1_checkout_version_is_utc
run_test "140.2 stamp_version stamps the UTC committer date" test_140_2_stamp_version_is_utc
run_test "140.3 _resolve_install_version uses the committer date" test_140_3_resolve_install_version_committer_date
run_test "140.4 update_get_remote_version uses the committer date" test_140_4_remote_version_committer_date
run_test "140.5 checkout and download install report the same version" test_140_5_checkout_and_download_install_agree
run_test "140.6 update --check on a checkout install of the remote commit is up to date" test_140_6_update_check_up_to_date

framework_report
