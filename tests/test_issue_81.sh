#!/usr/bin/env bash
# tests/test_issue_81.sh - Tests for Issue #81
#
# Cross-user `cac pull` of Claude config must rewrite the source user's
# absolute /home/<sourceuser> paths inside .claude.json (hooks, MCP binaries,
# per-project keys) to the target user's home. Otherwise hooks/MCP break and the
# session reads "Not logged in".
#
# Unit-level on bundle_extract / _bundle_rewrite_home_paths (no CLI / no getent),
# so the real home is never touched.
#
# Codex-gated condition baked in: after rewrite, .claude.json must still be
# VALID JSON (parse check), in addition to content markers.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"
# shellcheck source=lib/bundle.sh
source "$REPO_DIR/lib/bundle.sh"

framework_init

# ============================================================================
# Helpers
# ============================================================================

# Build a bundle zip <storage>/<name> whose entries are <relpath>=<file-with-content>.
# Usage: build_bundle <out_zip> <relpath1> <content1> [<relpath2> <content2> ...]
build_bundle() {
    local out_zip="$1"; shift
    local stage; stage=$(mktemp -d)
    while [[ $# -ge 2 ]]; do
        local rel="$1" content="$2"; shift 2
        mkdir -p "$stage/$(dirname "$rel")"
        printf '%s' "$content" > "$stage/$rel"
    done
    rm -f "$out_zip"
    # Add every file (incl. dotfiles) by explicit relative path via zip -@
    ( cd "$stage" && find . -type f -printf '%P\n' | zip -q "$out_zip" -@ )
    rm -rf "$stage"
}

# Parse-check: is <file> valid JSON? (jq -> python3 -> minimal structural fallback)
is_valid_json() {
    local f="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$f" >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1
    else
        # Fallback: balanced braces and no obviously-truncated content
        grep -q '^{' "$f" && grep -q '}$' "$f"
    fi
}

# A .claude.json fixture referencing <src_home> in every non-portable slot,
# plus a same-prefix decoy and a portable auth field.
claude_json_fixture() {
    local src_home="$1"
    cat <<EOF
{
  "hookCommand": "${src_home}/.claude/hooks/x.sh",
  "mcpBinary": "${src_home}/.local/bin/github-mcp-server",
  "bareHome": "${src_home}",
  "decoyPath": "/home/robert/y",
  "oauthAccount": "tok-unchanged",
  "projects": { "${src_home}/proj": { "n": 1 } }
}
EOF
}

# ============================================================================
# Tests
# ============================================================================

# 81.1 [anti-bug]: cross-user extract rewrites all /home/rob refs -> target home,
#      leaves valid JSON.
test_81_1_rewrite_cross_user() {
    local d="$TEST_TMPDIR/811"; mkdir -p "$d/home/moe"
    local zip="$d/CodingAgentConfig_HOSTA_rob_claude_260101-100000.zip"
    build_bundle "$zip" ".claude.json" "$(claude_json_fixture /home/rob)"

    bundle_extract "$zip" "$d/home/moe" "moe" >/dev/null 2>&1 || return 1

    local out="$d/home/moe/.claude.json"
    assert_file_exists "$out" "extracted .claude.json" || return 1

    # Zero boundary-anchored /home/rob refs remain (decoy /home/robert excluded)
    if grep -Eq '/home/rob(/|")' "$out"; then
        echo "FAIL: /home/rob path still present after rewrite:" >&2
        grep -En '/home/rob(/|")' "$out" >&2
        return 1
    fi
    # Target home present in each rewritten slot
    assert_contains "$d/home/moe/.claude/hooks/x.sh" "$(cat "$out")" "hook path repointed" || return 1
    assert_contains "$d/home/moe/.local/bin/github-mcp-server" "$(cat "$out")" "mcp path repointed" || return 1
    assert_contains "$d/home/moe/proj" "$(cat "$out")" "project key repointed" || return 1
    # Still valid JSON (Codex condition 3)
    if ! is_valid_json "$out"; then
        echo "FAIL: .claude.json is not valid JSON after rewrite" >&2
        return 1
    fi
    return 0
}

# 81.2 [anti-bug]: same-prefix decoy /home/robert is NOT corrupted.
test_81_2_boundary_safety() {
    local d="$TEST_TMPDIR/812"; mkdir -p "$d/home/moe"
    local zip="$d/CodingAgentConfig_HOSTA_rob_claude_260101-100000.zip"
    build_bundle "$zip" ".claude.json" "$(claude_json_fixture /home/rob)"
    bundle_extract "$zip" "$d/home/moe" "moe" >/dev/null 2>&1 || return 1
    assert_contains "/home/robert/y" "$(cat "$d/home/moe/.claude.json")" "decoy /home/robert untouched"
}

# 81.3: portable auth field is untouched by the rewrite.
test_81_3_auth_preserved() {
    local d="$TEST_TMPDIR/813"; mkdir -p "$d/home/moe"
    local zip="$d/CodingAgentConfig_HOSTA_rob_claude_260101-100000.zip"
    build_bundle "$zip" ".claude.json" "$(claude_json_fixture /home/rob)"
    bundle_extract "$zip" "$d/home/moe" "moe" >/dev/null 2>&1 || return 1
    assert_contains "tok-unchanged" "$(cat "$d/home/moe/.claude.json")" "oauthAccount preserved"
}

# 81.4 [anti-bug]: root source (/root/...) rewrites to target home.
test_81_4_root_source() {
    local d="$TEST_TMPDIR/814"; mkdir -p "$d/home/moe"
    local zip="$d/CodingAgentConfig_HOSTA_root_claude_260101-100000.zip"
    build_bundle "$zip" ".claude.json" "$(claude_json_fixture /root)"
    bundle_extract "$zip" "$d/home/moe" "moe" >/dev/null 2>&1 || return 1

    local out="$d/home/moe/.claude.json"
    if grep -Eq '/root(/|")' "$out"; then
        echo "FAIL: /root path still present after rewrite" >&2
        return 1
    fi
    assert_contains "$d/home/moe/proj" "$(cat "$out")" "root project key repointed" || return 1
    is_valid_json "$out"
}

# 81.5 [sentinel]: no-op guard — src_home == dst_home leaves file byte-identical.
test_81_5_noop_same_home() {
    local d="$TEST_TMPDIR/815"; mkdir -p "$d"
    local f="$d/.claude.json"
    claude_json_fixture /home/rob > "$f"
    local before; before=$(md5sum "$f" | cut -d' ' -f1)
    _bundle_rewrite_home_paths "$f" "/home/rob" "/home/rob" "rob"
    local after; after=$(md5sum "$f" | cut -d' ' -f1)
    assert_equals "$before" "$after" "no-op rewrite leaves file unchanged"
}

# 81.6 [sentinel]: only .claude.json is rewritten — a non-claude entry in the
#      same bundle keeps its /home/rob paths.
test_81_6_only_claude_rewritten() {
    local d="$TEST_TMPDIR/816"; mkdir -p "$d/home/moe"
    local zip="$d/CodingAgentConfig_HOSTA_rob_claude_260101-100000.zip"
    build_bundle "$zip" \
        ".claude.json" "$(claude_json_fixture /home/rob)" \
        ".codex/auth.json" '{"path":"/home/rob/.codex/keep"}'
    bundle_extract "$zip" "$d/home/moe" "moe" >/dev/null 2>&1 || return 1
    assert_contains "/home/rob/.codex/keep" "$(cat "$d/home/moe/.codex/auth.json")" ".codex not rewritten"
}

# ============================================================================
# Run
# ============================================================================

echo "=========================================="
echo "Issue #81: .claude.json cross-user path rewrite"
echo "=========================================="

run_test "81.1 cross-user rewrite -> target home, valid JSON" test_81_1_rewrite_cross_user
run_test "81.2 boundary safety (/home/robert untouched)" test_81_2_boundary_safety
run_test "81.3 portable auth field preserved" test_81_3_auth_preserved
run_test "81.4 root source (/root) rewritten" test_81_4_root_source
run_test "81.5 no-op when src == dst home" test_81_5_noop_same_home
run_test "81.6 only .claude.json rewritten (codex untouched)" test_81_6_only_claude_rewritten

framework_report
