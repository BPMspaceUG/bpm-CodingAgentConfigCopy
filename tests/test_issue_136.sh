#!/usr/bin/env bash
# tests/test_issue_136.sh - Tests for Issue #136
#
# `cac pull` of a bundle from another host (or user) used to move the bundled
# ~/.claude.json over the local one, dropping the target's mcpServers, projects,
# machineID and userID. Now a foreign bundle only contributes the login identity
# (top-level `oauthAccount`); every other key stays local. A same-host+same-user
# bundle and a target without a local file behave as before.
#
# Seam: bundle_extract. Fixtures: tests/fixtures/claude-json-*.json (real shape).
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"
# shellcheck source=lib/bundle.sh
source "$REPO_DIR/lib/bundle.sh"

framework_init

# The merge and most assertions need jq; 136.2 and 136.4 do not.
HAS_JQ=false
framework_has_command jq && HAS_JQ=true

# ============================================================================
# Helpers
# ============================================================================

# Build a bundle zip from <relpath> <source-file> pairs.
build_bundle() {
    local out_zip="$1"; shift
    local stage; stage=$(mktemp -d)
    while [[ $# -ge 2 ]]; do
        local rel="$1" src="$2"; shift 2
        mkdir -p "$stage/$(dirname "$rel")"
        cp "$src" "$stage/$rel"
    done
    rm -f "$out_zip"
    ( cd "$stage" && find . -type f -printf '%P\n' | zip -q "$out_zip" -@ )
    rm -rf "$stage"
}

# A PATH directory holding every /usr/bin and /usr/sbin tool except jq.
make_nojq_path() {
    local dir="$1" f
    mkdir -p "$dir"
    for f in /usr/bin/* /usr/sbin/* /bin/* /sbin/*; do
        [[ -x "$f" ]] || continue
        [[ "$(basename "$f")" == "jq" ]] && continue
        [[ -e "$dir/$(basename "$f")" ]] || ln -s "$f" "$dir/$(basename "$f")"
    done
}

jqf() { jq -c "$1" "$2"; }

LOCAL_FIX="$FIXTURES/claude-json-local.json"
BUNDLE_FIX="$FIXTURES/claude-json-bundle.json"
CJ=".claude.json"
CRED=".claude/.credentials.json"
FOREIGN_ZIP_NAME="CodingAgentConfig_SRCHOST_target_claude_261116-100000.zip"

# Sandbox <id>: home/target with the local fixture, plus a foreign bundle that
# carries the bundle fixture and a credentials file.
new_sandbox() {
    local d="$TEST_TMPDIR/$1"
    mkdir -p "$d/home/target/.claude"
    cp "$LOCAL_FIX" "$d/home/target/$CJ"
    build_bundle "$d/$FOREIGN_ZIP_NAME" "$CJ" "$BUNDLE_FIX" "$CRED" "$FIXTURES/claude-credentials.json"
    echo "$d"
}

# ============================================================================
# Tests
# ============================================================================

# 136.1 [anti-bug]: foreign bundle keeps local mcpServers, projects, machineID,
#       userID and every other key; only oauthAccount comes from the bundle.
test_136_1_foreign_bundle_merges() {
    local d; d=$(new_sandbox 1361)
    local live="$d/home/target/$CJ" out
    out=$(bundle_extract "$d/$FOREIGN_ZIP_NAME" "$d/home/target" "target" 2>&1) || { echo "$out"; return 1; }

    assert_equals "$(jqf 'del(.oauthAccount)' "$LOCAL_FIX")" "$(jqf 'del(.oauthAccount)' "$live")" \
        "all non-login keys stay local" || return 1
    assert_equals "$(jqf '.oauthAccount' "$BUNDLE_FIX")" "$(jqf '.oauthAccount' "$live")" \
        "oauthAccount from the bundle" || return 1
    assert_equals '"github"' "$(jqf '.mcpServers | keys[0]' "$live")" "local MCP server survives" || return 1
    assert_contains "merged" "$out" "merge reported" || return 1
    assert_file_exists "$d/home/target/$CRED" "credentials still installed" || return 1
    local backups; backups=$(find "$d/home/target" -maxdepth 1 -name "$CJ.backup*" | wc -l)
    assert_equals 1 "$backups" "one backup written" || return 1
    assert_equals "600" "$(stat -c '%a' "$live")" "mode 600"
}

# 136.2: same host + same user replaces the file, as before.
test_136_2_same_origin_replaces() {
    local d; d=$(new_sandbox 1362)
    local zip; zip="$d/CodingAgentConfig_$(hostname -s)_target_claude_261116-100000.zip"
    build_bundle "$zip" "$CJ" "$BUNDLE_FIX"
    bundle_extract "$zip" "$d/home/target" "target" >/dev/null 2>&1 || return 1
    assert_equals "$(cat "$BUNDLE_FIX")" "$(cat "$d/home/target/$CJ")" "file equals the bundle's"
}

# 136.3: no local file -> the bundle's file is installed (with #81 rewrite).
test_136_3_no_local_file_installs() {
    local d; d=$(new_sandbox 1363)
    rm -f "$d/home/target/$CJ"
    local zip="$d/CodingAgentConfig_SRCHOST_source_claude_261116-100000.zip"
    build_bundle "$zip" "$CJ" "$BUNDLE_FIX"
    bundle_extract "$zip" "$d/home/target" "target" >/dev/null 2>&1 || return 1
    local live="$d/home/target/$CJ"
    assert_equals "$(jqf '.machineID' "$BUNDLE_FIX")" "$(jqf '.machineID' "$live")" "bundle file installed" || return 1
    if grep -q '/home/source' "$live"; then echo "source home not rewritten"; return 1; fi
    assert_contains "$d/home/target/proj-FIXTURE" "$(cat "$live")" "home paths rewritten"
}

# 136.4 [anti-bug]: without jq a foreign bundle never replaces the local file.
test_136_4_no_jq_keeps_local() {
    local d; d=$(new_sandbox 1364)
    make_nojq_path "$d/bin"
    local out rc=0
    out=$(PATH="$d/bin" bundle_extract "$d/$FOREIGN_ZIP_NAME" "$d/home/target" "target" 2>&1) || rc=$?
    assert_equals 0 "$rc" "extract exit status" || { echo "$out"; return 1; }
    assert_equals "$(cat "$LOCAL_FIX")" "$(cat "$d/home/target/$CJ")" "local file unchanged" || return 1
    assert_contains "jq" "$out" "reason names jq" || return 1
    assert_contains "$CJ" "$out" "message names the file" || return 1
    assert_file_exists "$d/home/target/$CRED" "credentials still installed"
}

# 136.5 [anti-bug]: corrupt local JSON is left alone, with a message.
test_136_5_corrupt_local_kept() {
    local d; d=$(new_sandbox 1365)
    printf '{"mcpServers": {"github": ' > "$d/home/target/$CJ"
    local before; before=$(cat "$d/home/target/$CJ")
    local out
    out=$(bundle_extract "$d/$FOREIGN_ZIP_NAME" "$d/home/target" "target" 2>&1) || return 1
    assert_equals "$before" "$(cat "$d/home/target/$CJ")" "local file unchanged" || return 1
    assert_contains "not valid JSON" "$out" "reason named"
}

# 136.6: a foreign bundle from the same host but another user is foreign too.
test_136_6_other_user_same_host_merges() {
    local d; d=$(new_sandbox 1366)
    local zip; zip="$d/CodingAgentConfig_$(hostname -s)_source_claude_261116-100000.zip"
    build_bundle "$zip" "$CJ" "$BUNDLE_FIX"
    bundle_extract "$zip" "$d/home/target" "target" >/dev/null 2>&1 || return 1
    assert_equals "$(jqf '.machineID' "$LOCAL_FIX")" "$(jqf '.machineID' "$d/home/target/$CJ")" "machineID stays local"
}

# 136.7 [anti-bug]: keys only the bundle has are not added to the local file.
test_136_7_bundle_only_keys_not_added() {
    local d; d=$(new_sandbox 1367)
    jq '. + {bundleOnlyKeyFIXTURE: true}' "$BUNDLE_FIX" > "$d/bundle-extra.json"
    build_bundle "$d/$FOREIGN_ZIP_NAME" "$CJ" "$d/bundle-extra.json"
    bundle_extract "$d/$FOREIGN_ZIP_NAME" "$d/home/target" "target" >/dev/null 2>&1 || return 1
    assert_equals "false" "$(jqf 'has("bundleOnlyKeyFIXTURE")' "$d/home/target/$CJ")" "bundle-only key not added"
}

# 136.8 [anti-bug]: a corrupt bundled file leaves the local file alone.
test_136_8_corrupt_bundle_kept_local() {
    local d; d=$(new_sandbox 1368)
    printf '{"oauthAccount": ' > "$d/bundle-corrupt.json"
    build_bundle "$d/$FOREIGN_ZIP_NAME" "$CJ" "$d/bundle-corrupt.json"
    local out
    out=$(bundle_extract "$d/$FOREIGN_ZIP_NAME" "$d/home/target" "target" 2>&1) || return 1
    assert_equals "$(cat "$LOCAL_FIX")" "$(cat "$d/home/target/$CJ")" "local file unchanged" || return 1
    assert_contains "not valid JSON" "$out" "reason named"
}

run_test_if "$HAS_JQ" "136.1 foreign bundle merges, local state kept"         test_136_1_foreign_bundle_merges "jq not installed"
run_test "136.2 same host+user replaces as before"               test_136_2_same_origin_replaces
run_test_if "$HAS_JQ" "136.3 no local file installs bundle (+#81 rewrite)"    test_136_3_no_local_file_installs "jq not installed"
run_test "136.4 no jq: foreign bundle leaves local file alone"   test_136_4_no_jq_keeps_local
run_test_if "$HAS_JQ" "136.5 corrupt local JSON left alone"                   test_136_5_corrupt_local_kept "jq not installed"
run_test_if "$HAS_JQ" "136.6 same host, other user counts as foreign"         test_136_6_other_user_same_host_merges "jq not installed"

run_test_if "$HAS_JQ" "136.7 bundle-only keys are not added"                 test_136_7_bundle_only_keys_not_added "jq not installed"
run_test_if "$HAS_JQ" "136.8 corrupt bundled JSON keeps the local file"      test_136_8_corrupt_bundle_kept_local "jq not installed"

framework_report
