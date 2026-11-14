#!/usr/bin/env bash
# tests/test_issue_131.sh - Tests for Issue #131
#
# `cac update` / `cac update --check` and install.sh called the GitHub commits
# API unauthenticated. Once the 60 req/h per-IP quota was used up they failed
# with a generic "Failed to fetch remote version from GitHub API", although a
# token (GH_TOKEN, GITHUB_TOKEN, `gh auth token`) would have lifted the limit to
# 5,000 req/h.
#
# Seams: update_get_remote_version (lib/update.sh), and _resolve_install_version
# / get_latest_version extracted from install.sh (as tests/test_issue_77.sh
# does). curl and gh are stub scripts on PATH that record what they receive and
# serve a canned status, headers and body. No network.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

TOKEN="ghp_FIXTURE131token"
API="https://api.github.com/repos/BPMspaceUG/bpm-CodingAgentConfigCopy/commits/main"
COMMIT_JSON='{"sha":"abc","commit":{"author":{"date":"2026-03-01T15:00:33Z"},"committer":{"date":"2026-03-01T15:00:33Z"}}}'

# Stub dir with curl and gh. curl records argv and any -H value (resolving
# @file) into $STUB_LOG, writes "HTTP/2 $STUB_STATUS" plus $STUB_HEADERS to the
# -D file, and prints $STUB_BODY. gh prints $STUB_GH_TOKEN for `gh auth token`
# or fails when it is empty.
make_stubs() {
    STUB="$TEST_TMPDIR/$1"
    STUB_LOG="$STUB/log"
    mkdir -p "$STUB/bin"
    : > "$STUB_LOG"
    cat > "$STUB/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'ARGV:%s\n' "$*" >> "$STUB_LOG"
hdr=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -D) hdr="$2"; shift 2 ;;
        -H) if [[ "$2" == @* ]]; then printf 'HDR:%s\n' "$(cat "${2#@}")" >> "$STUB_LOG"
            else printf 'HDR:%s\n' "$2" >> "$STUB_LOG"; fi
            shift 2 ;;
        -o|--max-time|-w) shift 2 ;;
        -*) shift ;;
        *) printf 'URL:%s\n' "$1" >> "$STUB_LOG"; shift ;;
    esac
done
if [[ -n "$hdr" ]]; then
    printf 'HTTP/2 %s\r\n%b\r\n' "${STUB_STATUS:-200}" "${STUB_HEADERS:-}" > "$hdr"
fi
printf '%s' "${STUB_BODY:-}"
EOF
    cat > "$STUB/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "auth token" && -n "${STUB_GH_TOKEN:-}" ]] || exit 1
printf '%s\n' "$STUB_GH_TOKEN"
EOF
    chmod +x "$STUB/bin/curl" "$STUB/bin/gh"
}

# Run update_get_remote_version in a clean child with the stubs first on PATH.
# Extra env assignments come as arguments. Sets OUT, RC.
run_remote_version() {
    RC=0
    OUT=$(env -u GH_TOKEN -u GITHUB_TOKEN PATH="$STUB/bin:/usr/bin:/bin" STUB_LOG="$STUB_LOG" "$@" \
        bash -c 'source "$1/lib/logging.sh"; source "$1/lib/utils.sh" 2>/dev/null
                 source "$1/lib/update.sh"; update_get_remote_version' _ "$REPO_DIR" 2>&1) || RC=$?
}

# Run an install.sh function extracted on its own. stdout (what the caller
# captures) goes to OUT, stderr to ERR. warn() writes to STDOUT, exactly like
# install.sh's own, so a warning that would be swallowed into the captured
# value shows up in OUT. Sets OUT, ERR, RC.
run_install_fn() {
    local fn="$1"; shift
    RC=0
    OUT=$(env -u GH_TOKEN -u GITHUB_TOKEN PATH="$STUB/bin:/usr/bin:/bin" STUB_LOG="$STUB_LOG" "$@" \
        bash -c 'GITHUB_API_BASE="https://api.github.com/repos/BPMspaceUG/bpm-CodingAgentConfigCopy"
                 warn() { echo "[WARN] $*"; }
                 for f in _install_github_api_get "$2"; do
                     eval "$(sed -n "/^${f}()/,/^}/p" "$1/install.sh")"
                 done
                 "$2"' _ "$REPO_DIR" "$fn" 2>"$STUB/err") || RC=$?
    ERR=$(cat "$STUB/err")
}

# 131.1 [anti-bug]: GH_TOKEN is sent as a bearer header to api.github.com, and
#       the token never appears in curl's argv.
test_131_1_token_sent_not_in_argv() {
    make_stubs 1311
    run_remote_version GH_TOKEN="$TOKEN" STUB_BODY="$COMMIT_JSON"

    assert_equals 0 "$RC" "exit code" || { echo "$OUT" >&2; return 1; }
    assert_equals "260301-1500" "$OUT" "remote version" || return 1
    assert_contains "HDR:Authorization: Bearer $TOKEN" "$(cat "$STUB_LOG")" "bearer header sent" || return 1
    if grep '^ARGV:' "$STUB_LOG" | grep -q "$TOKEN"; then
        echo "token visible in curl argv: $(cat "$STUB_LOG")" >&2
        return 1
    fi
}

# 131.2: GITHUB_TOKEN is used when GH_TOKEN is unset.
test_131_2_github_token_fallback() {
    make_stubs 1312
    run_remote_version GITHUB_TOKEN="$TOKEN" STUB_BODY="$COMMIT_JSON"

    assert_contains "HDR:Authorization: Bearer $TOKEN" "$(cat "$STUB_LOG")" "GITHUB_TOKEN used" || return 1
}

# 131.3: an overridden API base on another host never receives the token.
test_131_3_no_token_to_other_host() {
    make_stubs 1313
    run_remote_version GH_TOKEN="$TOKEN" STUB_GH_TOKEN="$TOKEN" STUB_BODY="$COMMIT_JSON" \
        UPDATE_GITHUB_API_BASE="https://mirror.example/repos/x"

    assert_contains "URL:https://mirror.example/repos/x/commits/main" "$(cat "$STUB_LOG")" "override used" || return 1
    if grep -q "$TOKEN" "$STUB_LOG"; then
        echo "token sent to another host: $(cat "$STUB_LOG")" >&2
        return 1
    fi
}

# 131.4: no env token, `gh auth token` succeeds: its token is used.
test_131_4_gh_auth_token() {
    make_stubs 1314
    run_remote_version STUB_GH_TOKEN="$TOKEN" STUB_BODY="$COMMIT_JSON"

    assert_contains "HDR:Authorization: Bearer $TOKEN" "$(cat "$STUB_LOG")" "gh token used" || return 1
}

# 131.5 [control]: no token anywhere: unauthenticated call, still works.
test_131_5_no_token_unauthenticated() {
    make_stubs 1315
    run_remote_version STUB_BODY="$COMMIT_JSON"

    assert_equals 0 "$RC" "exit code" || { echo "$OUT" >&2; return 1; }
    assert_equals "260301-1500" "$OUT" "remote version" || return 1
    if grep -q '^HDR:Authorization' "$STUB_LOG"; then
        echo "authorization header without a token: $(cat "$STUB_LOG")" >&2
        return 1
    fi
}

# 131.6 [anti-bug]: rate limited: the message names the limit and the reset
#       time, and how to lift it.
test_131_6_rate_limit_message() {
    make_stubs 1316
    local reset=1794677447
    run_remote_version STUB_STATUS=403 STUB_BODY='{"message":"API rate limit exceeded"}' \
        STUB_HEADERS="x-ratelimit-remaining: 0\r\nx-ratelimit-reset: $reset"

    [[ "$RC" -ne 0 ]] || { echo "rc 0 when rate limited: $OUT" >&2; return 1; }
    assert_contains "rate limit" "$OUT" "limit named" || return 1
    assert_contains "$(date -d "@$reset" '+%H:%M')" "$OUT" "reset time named" || return 1
    assert_contains "GH_TOKEN" "$OUT" "how to lift it" || return 1
}

# 131.7: any other HTTP error keeps the generic message.
test_131_7_other_error_generic() {
    make_stubs 1317
    run_remote_version STUB_STATUS=500 STUB_BODY='oops'

    [[ "$RC" -ne 0 ]] || { echo "rc 0 on HTTP 500: $OUT" >&2; return 1; }
    assert_contains "Failed to fetch remote version from GitHub API" "$OUT" "generic message" || return 1
}

# 131.8: install.sh _resolve_install_version sends the token and names the
#        rate limit while keeping the "dev" fallback.
test_131_8_install_resolve_version() {
    make_stubs 1318
    run_install_fn _resolve_install_version GH_TOKEN="$TOKEN" STUB_BODY="$COMMIT_JSON"
    assert_equals "260301-1500" "$OUT" "version from API" || return 1
    assert_contains "HDR:Authorization: Bearer $TOKEN" "$(cat "$STUB_LOG")" "token sent" || return 1

    make_stubs 1318b
    run_install_fn _resolve_install_version STUB_STATUS=403 \
        STUB_HEADERS="x-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1794677447"
    assert_contains "rate limit" "$ERR" "rate limit warned on stderr" || return 1
    assert_equals "dev" "$OUT" "dev fallback kept, nothing else captured" || return 1
}

# 131.9: install.sh get_latest_version sends the token and names the rate
#        limit while keeping the "main" fallback.
test_131_9_install_latest_version() {
    make_stubs 1319
    run_install_fn get_latest_version GH_TOKEN="$TOKEN" STUB_BODY='{"tag_name":"v9.9.9"}'
    assert_equals "v9.9.9" "$OUT" "release tag" || return 1
    assert_contains "HDR:Authorization: Bearer $TOKEN" "$(cat "$STUB_LOG")" "token sent" || return 1

    make_stubs 1319b
    run_install_fn get_latest_version STUB_STATUS=403 \
        STUB_HEADERS="x-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1794677447"
    assert_contains "rate limit" "$ERR" "rate limit warned on stderr" || return 1
    assert_equals "main" "$OUT" "main fallback kept, nothing else captured" || return 1
}

echo "========================================"
echo "Issue #131: authenticated GitHub API calls, rate-limit message"
echo "========================================"

run_test "131.1 GH_TOKEN sent as bearer header, not in argv" test_131_1_token_sent_not_in_argv
run_test "131.2 GITHUB_TOKEN used when GH_TOKEN is unset" test_131_2_github_token_fallback
run_test "131.3 overridden API host never receives the token" test_131_3_no_token_to_other_host
run_test "131.4 gh auth token used when no env token" test_131_4_gh_auth_token
run_test "131.5 no token: unauthenticated call still works" test_131_5_no_token_unauthenticated
run_test "131.6 rate limited: limit, reset time and remedy named" test_131_6_rate_limit_message
run_test "131.7 other HTTP error keeps the generic message" test_131_7_other_error_generic
run_test "131.8 install.sh _resolve_install_version: token, rate limit, dev" test_131_8_install_resolve_version
run_test "131.9 install.sh get_latest_version: token, rate limit, main" test_131_9_install_latest_version

framework_report
