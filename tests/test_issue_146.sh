#!/usr/bin/env bash
# tests/test_issue_146.sh - Tests for Issue #146
#
# `cac pull --all` called get_newest once per user with no --tool, so a user
# whose bundles are split per tool (…_<user>_<tool>_<ts>.zip) received only the
# tool whose bundle happened to be newest; every other tool was skipped.
# Plain `cac pull` already picks the newest bundle per tool. --all must too,
# and it must offer a way to apply one uploader's bundles to every local user
# (--all --user UPLOADER), since all host users are the same person.
#
# Seam: _pull_all_user, the per-user step of cmd_pull_all (cmd_pull_all itself
# refuses to run without root), against the REAL local backend and the REAL
# bundle_extract, so the #141 stale-session guard is exercised end to end.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=bin/cac
source "$REPO_DIR/bin/cac"
set +e

framework_init

# ============================================================================
# Helpers
# ============================================================================

# Build a bundle zip whose entries are <relpath>=<content> pairs.
build_bundle() {
    local out_zip="$1"; shift
    local stage; stage=$(mktemp -d)
    while [[ $# -ge 2 ]]; do
        local rel="$1" content="$2"; shift 2
        mkdir -p "$stage/$(dirname "$rel")"
        printf '%s' "$content" > "$stage/$rel"
    done
    rm -f "$out_zip"
    ( cd "$stage" && find . -type f -printf '%P\n' | zip -q "$out_zip" -@ )
    rm -rf "$stage"
}

creds() {
    printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s","expiresAt":%s,"scopes":["user:inference"],"subscriptionType":"max"}}' \
        "$1" "$2" "$3"
}
future_ms() { echo $(( ($(date +%s) + 4 * 3600) * 1000 )); }
past_ms()   { echo $(( ($(date +%s) - 24 * 3600) * 1000 )); }

CRED=".claude/.credentials.json"

# Fresh local store + target home per test; points the real local backend at
# the store. Sets: store, home (callers declare them local).
new_fixture() {
    local d="$TEST_TMPDIR/$1"
    store="$d/store" home="$d/home"
    mkdir -p "$store" "$home"
    chmod 700 "$store"
    # shellcheck disable=SC2034  # read by lib/backend_local.sh
    CAC_BACKEND=local CAC_LOCAL_STORAGE="$store"
}

# Rob's three per-tool bundles, a second apart; codex is not the newest.
store_rob_per_tool() {
    local store="$1" claude_creds="$2"
    build_bundle "$store/CodingAgentConfig_SRCHOST_rob_claude_261110-065831.zip" \
        "$CRED" "$claude_creds"
    build_bundle "$store/CodingAgentConfig_SRCHOST_rob_codex_261110-065832.zip" \
        ".codex/auth.json" '{"tokens":"rob-codex"}'
    build_bundle "$store/CodingAgentConfig_SRCHOST_rob_gemini_261110-065833.zip" \
        ".gemini/oauth_creds.json" '{"token":"rob-gemini"}'
}

# ============================================================================
# Tests
# ============================================================================

# 146.1 [anti-bug]: every per-tool bundle of the user is applied, not just the
#       newest one across tools.
test_146_1_all_tools_applied() {
    local store home; new_fixture 1461
    store_rob_per_tool "$store" "$(creds "rob-at" "rob-rt" "$(future_ms)")"

    local out
    out=$(_pull_all_user false rob "$home" rob 2>&1) || { echo "$out" >&2; return 1; }

    assert_contains "rob-rt" "$(cat "$home/$CRED" 2>/dev/null)" "claude applied" || return 1
    assert_contains "rob-codex" "$(cat "$home/.codex/auth.json" 2>/dev/null)" "codex applied" || return 1
    assert_contains "rob-gemini" "$(cat "$home/.gemini/oauth_creds.json" 2>/dev/null)" "gemini applied" || return 1
}

# 146.2: --all --user UPLOADER applies that uploader's bundles to a local user
#        who has no uploads of their own.
test_146_2_uploader_mapped_to_other_user() {
    local store home; new_fixture 1462
    store_rob_per_tool "$store" "$(creds "rob-at" "rob-rt" "$(future_ms)")"

    local out
    out=$(_pull_all_user false matt "$home" rob 2>&1) || { echo "$out" >&2; return 1; }

    assert_contains "rob-codex" "$(cat "$home/.codex/auth.json" 2>/dev/null)" "codex applied to matt" || return 1
    assert_contains "rob-rt" "$(cat "$home/$CRED" 2>/dev/null)" "claude applied to matt" || return 1
}

# 146.3: without a mapping, a user with no own uploads gets nothing and the
#        step says so instead of failing.
test_146_3_no_own_uploads_skipped() {
    local store home; new_fixture 1463
    store_rob_per_tool "$store" "$(creds "rob-at" "rob-rt" "$(future_ms)")"

    local out rc=0
    out=$(_pull_all_user false matt "$home" matt 2>&1) || rc=$?

    assert_equals 0 "$rc" "exit code for a user without bundles" || return 1
    [[ ! -e "$home/.codex/auth.json" ]] || { echo "codex was applied to matt" >&2; return 1; }
    assert_contains "No bundle found for matt" "$out" "skip reason" || return 1
}

# 146.4 [#141 on this path]: a stale Claude session in the bundle never
#       replaces a working local login; the other tools still apply.
test_146_4_stale_claude_guard() {
    local store home; new_fixture 1464
    store_rob_per_tool "$store" "$(creds "old-at" "old-rt" "$(past_ms)")"
    mkdir -p "$home/.claude"
    creds "local-at" "local-rt" "$(future_ms)" > "$home/$CRED"

    local out
    out=$(_pull_all_user false rob "$home" rob 2>&1)

    assert_contains "local-rt" "$(cat "$home/$CRED")" "local login kept" || return 1
    assert_contains "rob-codex" "$(cat "$home/.codex/auth.json" 2>/dev/null)" "codex still applied" || return 1
}

# 146.5: dry-run names every per-tool bundle and writes nothing.
test_146_5_dry_run_lists_every_tool() {
    local store home; new_fixture 1465
    store_rob_per_tool "$store" "$(creds "rob-at" "rob-rt" "$(future_ms)")"

    local out
    out=$(_pull_all_user true rob "$home" rob 2>&1)

    assert_contains "rob_claude_" "$out" "claude named" || return 1
    assert_contains "rob_codex_" "$out" "codex named" || return 1
    assert_contains "rob_gemini_" "$out" "gemini named" || return 1
    [[ ! -e "$home/.codex/auth.json" ]] || { echo "dry-run wrote files" >&2; return 1; }
}

# 146.6: help states which bundles --all picks and how to map an uploader.
test_146_6_help_text() {
    local out; out=$(show_help)
    assert_contains "newest bundle per tool" "$out" "per-tool wording" || return 1
    assert_contains "--all --user" "$out" "uploader mapping documented" || return 1
}

echo "========================================"
echo "Issue #146: cac pull --all applies every tool's newest bundle"
echo "========================================"

run_test "146.1 all per-tool bundles of the user are applied" test_146_1_all_tools_applied
run_test "146.2 --all --user maps one uploader to another local user" test_146_2_uploader_mapped_to_other_user
run_test "146.3 a user without own uploads is skipped, not failed" test_146_3_no_own_uploads_skipped
run_test "146.4 #141 stale-session guard holds on the --all path" test_146_4_stale_claude_guard
run_test "146.5 dry-run names every tool's bundle and writes nothing" test_146_5_dry_run_lists_every_tool
run_test "146.6 help text documents --all bundle selection" test_146_6_help_text

framework_report
