#!/usr/bin/env bash
# tests/test_issue_166.sh - Tests for Issue #166
#
# Owner decision (ADR 0001): hosts use the interactive Claude login (what
# Remote Control needs, moved between hosts by cac); containers use the
# long-lived `claude setup-token` token. cac never distributes or expects the
# token, and never advises a host to use it.
#
# Seams: check_single_tool claude (lib/check.sh) with a claude stub that
# answers like Claude Code with a dead session and the wiped-session fixture
# (tests/fixtures/claude-credentials-wiped.json); bundle_create
# (lib/bundle.sh) on a home that holds the token file.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$SCRIPT_DIR/fixtures"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"
# shellcheck source=lib/bundle.sh
source "$REPO_DIR/lib/bundle.sh"
# shellcheck source=lib/check.sh
source "$REPO_DIR/lib/check.sh"

framework_init

# A claude binary that answers like Claude Code with a dead session; its
# --version replays the real capture (tests/fixtures/claude-version.out).
stub_claude_login_expired() {
    mkdir -p "$1"
    cat > "$1/claude" <<EOF
#!/usr/bin/env bash
FIX_DIR="$FIX"
[[ "\${1:-}" == "--version" ]] && { cat "\$FIX_DIR/claude-version.out"; exit 0; }
echo "Login expired · Please run /login"
exit 1
EOF
    chmod +x "$1/claude"
}

# 166.1: the dead-session hint on a host names the host fixes (login move or
# /login), never the container token.
test_166_1_dead_session_hint_has_no_token_advice() {
    local d="$TEST_TMPDIR/1661"
    mkdir -p "$d/home/rob/.claude"
    echo '{}' > "$d/home/rob/.claude.json"
    cp "$FIX/claude-credentials-wiped.json" "$d/home/rob/.claude/.credentials.json"
    stub_claude_login_expired "$d/bin"

    local out
    out=$(PATH="$d/bin:$PATH" XDG_CACHE_HOME="$d/cache" \
        check_single_tool claude false rob "$d/home/rob" 2>&1) && return 1

    assert_contains "is dead" "$out" "dead session explained (out: $out)" || return 1
    assert_contains "Fix: run 'cac push' on the host where Claude works, then 'cac pull' here, or log in again here with 'claude' and /login" \
        "$out" "host fixes, pinned" || return 1
    if [[ "$out" == *"setup-token"* || "$out" == *"CLAUDE_CODE_OAUTH_TOKEN"* ]]; then
        echo "host hint advises the container token: $out" >&2
        return 1
    fi
}

# 166.2: `cac push` (bundle_create for all tools and for claude) never packs
# the token file.
test_166_2_bundle_never_packs_token_file() {
    local home="$TEST_TMPDIR/1662/home"
    mkdir -p "$home/.claude" "$home/.config/claude"
    echo '{}' > "$home/.claude.json"
    cp "$FIX/claude-credentials.json" "$home/.claude/.credentials.json"
    echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE' > "$home/.config/claude/oauth-token.env"
    local zip="$TEST_TMPDIR/1662/bundle.zip"

    local tool contents
    for tool in all claude; do
        rm -f "$zip"
        bundle_create "$home" "$zip" "$tool" >/dev/null 2>&1 || { echo "bundle_create $tool failed" >&2; return 1; }
        contents=$(unzip -Z1 "$zip")
        assert_contains ".claude/.credentials.json" "$contents" "login is bundled ($tool)" || return 1
        if [[ "$contents" == *"oauth-token"* ]]; then
            echo "token file in the $tool bundle: $contents" >&2
            return 1
        fi
    done
}

# 166.3: the README no longer tells anyone to export the token on a host and
# points at the decision (ADR 0001).
test_166_3_readme_states_the_split() {
    local readme
    readme=$(cat "$REPO_DIR/README.md")
    if [[ "$readme" == *"in the environment of each target user"* ]]; then
        echo "README still advises the token on every host" >&2
        return 1
    fi
    assert_contains "docs/adr/0001-hosts-login-containers-token.md" "$readme" "README links the ADR" || return 1
    local flow
    flow=$(sed -n '/^2\. \*\*Hosts log in, containers use the token\*\*/,/^3\. /p' "$REPO_DIR/README.md")
    assert_contains "belongs only in containers" "$flow" "token placed in containers" || return 1
    assert_contains "Never set the token in a host shell" "$flow" "host shells warned off" || return 1
    assert_contains "Remote Control" "$flow" "reason given" || return 1
    [[ -f "$REPO_DIR/docs/adr/0001-hosts-login-containers-token.md" ]] || { echo "ADR missing" >&2; return 1; }
}

run_test "166.1 the dead-session hint gives no token advice" test_166_1_dead_session_hint_has_no_token_advice
run_test "166.2 cac push never bundles the token file" test_166_2_bundle_never_packs_token_file
run_test "166.3 README states the host/container split and links the ADR" test_166_3_readme_states_the_split

framework_report
