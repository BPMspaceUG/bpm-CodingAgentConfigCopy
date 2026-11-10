#!/usr/bin/env bash
# tests/test_issue_141.sh - Tests for Issue #141
#
# A Claude OAuth session copied by cac goes stale as soon as any copy refreshes:
# the refresh token is single-use, so the copy that refreshes first invalidates
# every other copy's refresh token. cac must say so instead of applying a stale
# session silently, and must never replace a working local login with one.
#
# Seams: bundle_extract (a .claude/.credentials.json entry) and
# check_single_tool claude (failure path, claude binary stubbed on PATH).
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"
# shellcheck source=lib/bundle.sh
source "$REPO_DIR/lib/bundle.sh"
# shellcheck source=lib/check.sh
source "$REPO_DIR/lib/check.sh"

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

# Claude credentials JSON (one line, as Claude Code writes it).
# Usage: creds <accessToken> <refreshToken> <expiresAt-ms>
creds() {
    printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s","expiresAt":%s,"scopes":["user:inference"],"subscriptionType":"max"}}' \
        "$1" "$2" "$3"
}

future_ms() { echo $(( ($(date +%s) + 4 * 3600) * 1000 )); }
past_ms()   { echo $(( ($(date +%s) - 24 * 3600) * 1000 )); }

BUNDLE_NAME="CodingAgentConfig_SRCHOST_rob_claude_261108-082828.zip"
CRED=".claude/.credentials.json"

# ============================================================================
# bundle_extract
# ============================================================================

# 141.1 [anti-bug]: a bundle whose session holds no tokens (source logged out)
#       never replaces the local credentials, and cac says why.
test_141_1_empty_bundle_session_skipped() {
    local d="$TEST_TMPDIR/1411"; mkdir -p "$d/home/rob/.claude"
    creds "local-at" "local-rt" "$(future_ms)" > "$d/home/rob/$CRED"
    local zip="$d/$BUNDLE_NAME"
    build_bundle "$zip" "$CRED" "$(creds "" "" 0)"

    local out
    out=$(bundle_extract "$zip" "$d/home/rob" "rob" 2>&1) || return 1

    assert_contains "local-rt" "$(cat "$d/home/rob/$CRED")" "local login kept" || return 1
    assert_contains "no Claude session" "$out" "reason named" || return 1
}

# 141.2 [anti-bug]: a bundle whose access token already expired is stale (the
#       source has most likely refreshed since). A working local login is kept.
test_141_2_stale_bundle_keeps_working_local() {
    local d="$TEST_TMPDIR/1412"; mkdir -p "$d/home/rob/.claude"
    creds "local-at" "local-rt" "$(future_ms)" > "$d/home/rob/$CRED"
    local zip="$d/$BUNDLE_NAME"
    build_bundle "$zip" "$CRED" "$(creds "bundle-at" "bundle-rt" "$(past_ms)")"

    local out
    out=$(bundle_extract "$zip" "$d/home/rob" "rob" 2>&1) || return 1

    assert_contains "local-rt" "$(cat "$d/home/rob/$CRED")" "local login kept" || return 1
    assert_contains "stale" "$out" "stale named" || return 1
}

# 141.3: stale bundle, no working local login -> applied (it may still work if
#        the source has not refreshed), but with a clear warning naming the
#        source host and the fix.
test_141_3_stale_bundle_applied_with_warning() {
    local d="$TEST_TMPDIR/1413"; mkdir -p "$d/home/rob/.claude"
    creds "" "" 0 > "$d/home/rob/$CRED"
    local zip="$d/$BUNDLE_NAME"
    build_bundle "$zip" "$CRED" "$(creds "bundle-at" "bundle-rt" "$(past_ms)")"

    local out
    out=$(bundle_extract "$zip" "$d/home/rob" "rob" 2>&1) || return 1

    assert_contains "bundle-rt" "$(cat "$d/home/rob/$CRED")" "bundle applied" || return 1
    assert_contains "stale" "$out" "stale named" || return 1
    assert_contains "cac push" "$out" "fix named" || return 1
    assert_contains "SRCHOST" "$out" "source host named" || return 1
}

# 141.4: a fresh bundle is applied without a stale warning.
test_141_4_fresh_bundle_applied() {
    local d="$TEST_TMPDIR/1414"; mkdir -p "$d/home/rob/.claude"
    local zip="$d/$BUNDLE_NAME"
    build_bundle "$zip" "$CRED" "$(creds "bundle-at" "bundle-rt" "$(future_ms)")"

    local out
    out=$(bundle_extract "$zip" "$d/home/rob" "rob" 2>&1) || return 1

    assert_contains "bundle-rt" "$(cat "$d/home/rob/$CRED")" "bundle applied" || return 1
    if [[ "$out" == *stale* ]]; then
        echo "FAIL: fresh bundle reported as stale: $out" >&2
        return 1
    fi
}

# ============================================================================
# check_single_tool claude
# ============================================================================

# Stub a claude binary that answers like Claude Code with a dead session.
stub_claude_login_expired() {
    local bin="$1"; mkdir -p "$bin"
    cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "2.1.322 (Claude Code)"; exit 0; }
echo "Login expired · Please run /login"
exit 1
EOF
    chmod +x "$bin/claude"
}

# 141.5 [anti-bug]: a failed check on a home whose Claude tokens were wiped
#       (what Claude Code does after a rejected refresh) explains the cause
#       and the fix instead of a bare FAILED.
test_141_5_check_explains_dead_session() {
    local d="$TEST_TMPDIR/1415"; mkdir -p "$d/home/rob/.claude"
    echo '{}' > "$d/home/rob/.claude.json"
    creds "" "" 0 > "$d/home/rob/$CRED"
    stub_claude_login_expired "$d/bin"

    local out
    out=$(PATH="$d/bin:$PATH" XDG_CACHE_HOME="$d/cache" \
        check_single_tool claude false rob "$d/home/rob" 2>&1) && return 1

    assert_contains "FAILED" "$out" "still fails" || return 1
    assert_contains "cac push" "$out" "fix named" || return 1
}

# ============================================================================
# Run
# ============================================================================

run_test "141.1 empty bundle session never replaces local login" test_141_1_empty_bundle_session_skipped
run_test "141.2 stale bundle keeps a working local login"        test_141_2_stale_bundle_keeps_working_local
run_test "141.3 stale bundle applied with warning + fix"         test_141_3_stale_bundle_applied_with_warning
run_test "141.4 fresh bundle applied without warning"            test_141_4_fresh_bundle_applied
run_test "141.5 check explains a wiped Claude session"           test_141_5_check_explains_dead_session

framework_report
