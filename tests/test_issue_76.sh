#!/usr/bin/env bash
# tests/test_issue_76.sh - Tests for Issue #76
#
# Batch (no --tool) push/pull must interoperate via PER-TOOL bundles:
#  - `cac push` loops per tool, never aborts early, creates zero _all_ bundles,
#    exit 0 iff >=1 pushed and no upload/bundle failure.
#  - `cac pull` loops per tool (folds #70), with a legacy _all_ read-fallback.
#
# Codex-gated conditions baked in:
#  - EXACT exit codes everywhere (0 / 1)
#  - 76.2 asserts the creds-failed tool's bundle is ABSENT (no *_gemini_*)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

USER_NAME=$(whoami)

# ============================================================================
# Harness
# ============================================================================

# Create a sandbox with a local backend + mock getent (resolves home to the
# sandbox, NOT the real home). Optional 2nd arg = shared storage dir.
# Echoes the sandbox path.
new_sandbox() {
    local name="$1" shared="${2:-}"
    local d="$TEST_TMPDIR/$name"
    mkdir -p "$d"/{config,home,tmp,cache,bin}
    local storage
    if [[ -n "$shared" ]]; then
        storage="$shared"
    else
        storage="$d/storage"
        mkdir -p "$storage"
    fi
    cat > "$d/config/.env" <<EOF
CAC_BACKEND=local
CAC_LOCAL_STORAGE=$storage
EOF
    chmod 600 "$d/config/.env"

    cat > "$d/bin/getent" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "passwd" && "\$2" == "$USER_NAME" ]]; then
    echo "$USER_NAME:x:$(id -u):$(id -g):$USER_NAME:$d/home:/bin/bash"; exit 0
fi
$(command -v getent) "\$@"
EOF
    chmod +x "$d/bin/getent"
    echo "$d"
}

run_cac() {
    local d="$1"; shift
    PATH="$d/bin:$PATH" CAC_CONFIG_DIR="$d/config" HOME="$d/home" \
        TMPDIR="$d/tmp" XDG_CACHE_HOME="$d/cache" \
        "$REPO_DIR/bin/cac" "$@"
}

add_config() {
    local d="$1" tool="$2"
    case "$tool" in
        claude)  mkdir -p "$d/home/.claude"; echo '{"marker":"claude"}' > "$d/home/.claude.json"
                 echo '{"t":1}' > "$d/home/.claude/.credentials.json" ;;
        codex)   mkdir -p "$d/home/.codex"; echo '{"marker":"codex"}' > "$d/home/.codex/auth.json" ;;
        gemini)  mkdir -p "$d/home/.gemini"; echo '{"marker":"gemini"}' > "$d/home/.gemini/oauth_creds.json" ;;
        mistral) mkdir -p "$d/home/.vibe"; echo 'MISTRAL_API_KEY=x' > "$d/home/.vibe/.env" ;;
    esac
}

# Add a mock tool binary that makes its credential check pass (ok) or fail (fail).
add_stub() {
    local d="$1" tool="$2" mode="$3"
    local bin="$d/bin/$tool"
    [[ "$tool" == "mistral" ]] && bin="$d/bin/vibe"
    {
        echo '#!/usr/bin/env bash'
        echo '[[ "$1" == "--version" ]] && { echo "1.0.0"; exit 0; }'
        case "$tool:$mode" in
            codex:ok)    echo 'echo "Logged in"; exit 0' ;;
            codex:fail)  echo 'echo "Not logged in"; exit 1' ;;
            claude:ok)   echo 'echo "CLAUDE_OK"; exit 0' ;;
            claude:fail) echo 'echo "NOPE"; exit 1' ;;
            gemini:ok)   echo 'echo "GEMINI_OK"; exit 0' ;;
            gemini:fail) echo 'echo "NOPE"; exit 1' ;;
        esac
    } > "$bin"
    chmod +x "$bin"
}

# Seed a fixture bundle into <storage> with the given relative files.
seed_bundle() {
    local storage="$1" name="$2"; shift 2
    local stage; stage=$(mktemp -d)
    local rel
    for rel in "$@"; do
        mkdir -p "$stage/$(dirname "$rel")"
        echo "{\"marker\":\"${name}:${rel}\"}" > "$stage/$rel"
    done
    ( cd "$stage" && find . -type f -printf '%P\n' | zip -q "$storage/$name" -@ )
    rm -rf "$stage"
}

have_glob() { compgen -G "$1" >/dev/null 2>&1; }

# ============================================================================
# PUSH tests
# ============================================================================

# 76.1 [anti-bug]: no --tool push creates per-tool bundles, zero _all_ bundles.
test_76_1_push_per_tool_no_all() {
    local d; d=$(new_sandbox 761)
    add_config "$d" claude; add_config "$d" codex
    local rc=0; run_cac "$d" push --skip-check >/dev/null 2>&1 || rc=$?
    assert_equals 0 "$rc" "push exit code" || return 1
    have_glob "$d/storage/*_claude_*.zip" || { echo "no claude bundle"; return 1; }
    have_glob "$d/storage/*_codex_*.zip"  || { echo "no codex bundle"; return 1; }
    if have_glob "$d/storage/*_all_*.zip"; then echo "_all_ bundle was created"; return 1; fi
    return 0
}

# 76.2 [anti-bug]: mixed creds — OK tools pushed, FAILED tool skipped WITHOUT a
# bundle, exit 0, summary counts.
test_76_2_mixed_creds() {
    local d; d=$(new_sandbox 762)
    add_config "$d" claude; add_config "$d" codex; add_config "$d" gemini
    add_stub "$d" claude ok; add_stub "$d" codex ok; add_stub "$d" gemini fail
    local out rc=0; out=$(run_cac "$d" push 2>&1) || rc=$?
    assert_equals 0 "$rc" "push exit code" || { echo "$out"; return 1; }
    have_glob "$d/storage/*_claude_*.zip" || { echo "no claude bundle"; return 1; }
    have_glob "$d/storage/*_codex_*.zip"  || { echo "no codex bundle"; return 1; }
    # Codex condition 2: creds-failed tool must NOT have a bundle
    if have_glob "$d/storage/*_gemini_*.zip"; then echo "gemini bundle created despite creds fail"; return 1; fi
    assert_contains "2 pushed" "$out" "pushed count" || return 1
    assert_contains "1 creds-failed" "$out" "creds-failed count"
}

# 76.3: no tool has config -> nothing uploaded, EXACT exit 1.
test_76_3_no_config() {
    local d; d=$(new_sandbox 763)
    local out rc=0; out=$(run_cac "$d" push --skip-check 2>&1) || rc=$?
    assert_equals 1 "$rc" "push exit code" || return 1
    assert_contains "nothing to push" "$out" "nothing-to-push message"
}

# 76.4: all configured tools' creds fail -> nothing uploaded, EXACT exit 1.
test_76_4_all_creds_fail() {
    local d; d=$(new_sandbox 764)
    add_config "$d" claude; add_config "$d" codex
    add_stub "$d" claude fail; add_stub "$d" codex fail
    local rc=0; run_cac "$d" push >/dev/null 2>&1 || rc=$?
    assert_equals 1 "$rc" "push exit code" || return 1
    if have_glob "$d/storage/*.zip"; then echo "bundle created despite all creds fail"; return 1; fi
    return 0
}

# 76.5: --skip-check bypasses the credential check entirely.
test_76_5_skip_check_no_probe() {
    local d; d=$(new_sandbox 765)
    add_config "$d" claude
    local sentinel="$d/claude.called"
    { echo '#!/usr/bin/env bash'; printf 'echo called >> %q\n' "$sentinel"; echo 'echo "CLAUDE_OK"; exit 0'; } > "$d/bin/claude"
    chmod +x "$d/bin/claude"; rm -f "$sentinel"
    local rc=0; run_cac "$d" push --skip-check >/dev/null 2>&1 || rc=$?
    assert_equals 0 "$rc" "push exit code" || return 1
    have_glob "$d/storage/*_claude_*.zip" || { echo "no claude bundle"; return 1; }
    if [[ -f "$sentinel" ]]; then echo "credential check ran despite --skip-check"; return 1; fi
    return 0
}

# 76.6: upload failure (read-only storage) -> EXACT exit 1 + surfaced error.
test_76_6_upload_failure() {
    local d; d=$(new_sandbox 766)
    add_config "$d" claude; add_config "$d" codex
    chmod 555 "$d/storage"
    local out rc=0; out=$(run_cac "$d" push --skip-check 2>&1) || rc=$?
    chmod 755 "$d/storage"
    assert_equals 1 "$rc" "push exit code" || { echo "$out"; return 1; }
    echo "$out" | grep -qi "upload failed" || { echo "no upload-failed message"; return 1; }
    return 0
}

# 76.7: dry-run -> per-tool "would push", no upload, no temp leftovers, exit 0.
test_76_7_dry_run() {
    local d; d=$(new_sandbox 767)
    add_config "$d" claude; add_config "$d" codex
    local out rc=0; out=$(run_cac "$d" push --dry-run 2>&1) || rc=$?
    assert_equals 0 "$rc" "push exit code" || return 1
    echo "$out" | grep -qi "would push" || { echo "no would-push line"; return 1; }
    if have_glob "$d/storage/*.zip"; then echo "dry-run uploaded a bundle"; return 1; fi
    if [[ -n "$(find "$d/tmp" -name 'cac-push*' 2>/dev/null)" ]]; then echo "temp leftover after dry-run"; return 1; fi
    return 0
}

# 76.8 [anti-bug]: temp ZIPs cleaned up even when the push fails mid-run.
test_76_8_temp_cleanup_on_failure() {
    local d; d=$(new_sandbox 768)
    add_config "$d" claude
    chmod 555 "$d/storage"
    run_cac "$d" push --skip-check >/dev/null 2>&1 || true
    chmod 755 "$d/storage"
    if [[ -n "$(find "$d/tmp" -name 'cac-push*' 2>/dev/null)" ]]; then echo "temp leftover after failed push"; return 1; fi
    return 0
}

# 76.9 [sentinel]: `push --tool X` unchanged — single bundle, creds-fail aborts.
test_76_9_single_tool_unchanged() {
    local d; d=$(new_sandbox 769)
    add_config "$d" claude; add_config "$d" codex
    add_stub "$d" claude ok
    local rc=0; run_cac "$d" push --tool claude >/dev/null 2>&1 || rc=$?
    assert_equals 0 "$rc" "single-tool push exit code" || return 1
    have_glob "$d/storage/*_claude_*.zip" || { echo "no claude bundle"; return 1; }
    if have_glob "$d/storage/*_codex_*.zip"; then echo "codex bundle on --tool claude"; return 1; fi

    local d2; d2=$(new_sandbox 769b)
    add_config "$d2" claude; add_stub "$d2" claude fail
    local rc2=0; run_cac "$d2" push --tool claude >/dev/null 2>&1 || rc2=$?
    assert_equals 1 "$rc2" "single-tool creds-fail exit code" || return 1
    if have_glob "$d2/storage/*.zip"; then echo "bundle created despite creds fail"; return 1; fi
    return 0
}

# ============================================================================
# PULL tests (folds #70 + legacy fallback)
# ============================================================================

# 76.10 [anti-bug]: round-trip — no-tool push then no-tool pull into a fresh home
# applies every tool's config.
test_76_10_round_trip() {
    local a; a=$(new_sandbox 7610a)
    add_config "$a" claude; add_config "$a" codex
    run_cac "$a" push --skip-check >/dev/null 2>&1 || { echo "push failed"; return 1; }
    local b; b=$(new_sandbox 7610b "$a/storage")
    local rc=0; run_cac "$b" pull >/dev/null 2>&1 || rc=$?
    assert_equals 0 "$rc" "pull exit code" || return 1
    assert_file_exists "$b/home/.claude.json" "claude extracted" || return 1
    assert_file_exists "$b/home/.codex/auth.json" "codex extracted"
}

# 76.11 [anti-bug]: missing tool warns (no bundle) but pull still succeeds.
test_76_11_missing_tool_warns() {
    local d; d=$(new_sandbox 7611)
    seed_bundle "$d/storage" "CodingAgentConfig_HOSTA_${USER_NAME}_claude_260101-100000.zip" \
        ".claude.json" ".claude/.credentials.json"
    local out rc=0; out=$(run_cac "$d" pull 2>&1) || rc=$?
    assert_equals 0 "$rc" "pull exit code" || { echo "$out"; return 1; }
    assert_file_exists "$d/home/.claude.json" "claude extracted" || return 1
    echo "$out" | grep -Eiq 'gemini.*(no bundle|skip|unavailable)' || { echo "no gemini warning line"; return 1; }
    return 0
}

# 76.12 [anti-bug]: legacy _all_ read-fallback supplies each tool's files.
test_76_12_legacy_fallback() {
    local d; d=$(new_sandbox 7612)
    seed_bundle "$d/storage" "CodingAgentConfig_HOSTA_${USER_NAME}_all_260101-100000.zip" \
        ".claude.json" ".codex/auth.json" ".gemini/oauth_creds.json"
    local rc=0; run_cac "$d" pull >/dev/null 2>&1 || rc=$?
    assert_equals 0 "$rc" "pull exit code" || return 1
    assert_file_exists "$d/home/.claude.json" "claude from legacy" || return 1
    assert_file_exists "$d/home/.codex/auth.json" "codex from legacy" || return 1
    assert_file_exists "$d/home/.gemini/oauth_creds.json" "gemini from legacy"
}

# 76.13 [anti-bug]: a fresher per-tool bundle is NOT clobbered by legacy fallback.
test_76_13_no_clobber() {
    local d; d=$(new_sandbox 7613)
    seed_bundle "$d/storage" "CodingAgentConfig_HOSTA_${USER_NAME}_all_260101-100000.zip" \
        ".claude.json" ".codex/auth.json"
    seed_bundle "$d/storage" "CodingAgentConfig_HOSTB_${USER_NAME}_claude_260202-100000.zip" \
        ".claude.json"
    local rc=0; run_cac "$d" pull >/dev/null 2>&1 || rc=$?
    assert_equals 0 "$rc" "pull exit code" || return 1
    local content; content=$(cat "$d/home/.claude.json")
    assert_contains "_claude_" "$content" "per-tool claude won" || return 1
    if [[ "$content" == *"_all_"* ]]; then echo "legacy bundle clobbered per-tool claude"; return 1; fi
    assert_file_exists "$d/home/.codex/auth.json" "codex from legacy fallback"
}

# 76.14: zero bundles -> EXACT exit 1 + clear message.
test_76_14_zero_bundles() {
    local d; d=$(new_sandbox 7614)
    local out rc=0; out=$(run_cac "$d" pull 2>&1) || rc=$?
    assert_equals 1 "$rc" "pull exit code" || return 1
    assert_contains "No bundles were extracted" "$out" "no-bundles message"
}

# 76.15 [sentinel]: `pull --tool X` and `pull BUNDLE_ID` unchanged (single extract).
test_76_15_single_and_explicit_unchanged() {
    local d; d=$(new_sandbox 7615)
    seed_bundle "$d/storage" "CodingAgentConfig_HOSTA_${USER_NAME}_claude_260101-100000.zip" ".claude.json"
    seed_bundle "$d/storage" "CodingAgentConfig_HOSTA_${USER_NAME}_codex_260102-100000.zip" ".codex/auth.json"
    run_cac "$d" pull --tool claude >/dev/null 2>&1 || { echo "pull --tool claude failed"; return 1; }
    assert_file_exists "$d/home/.claude.json" "claude extracted via --tool" || return 1
    if [[ -f "$d/home/.codex/auth.json" ]]; then echo "codex leaked on --tool claude"; return 1; fi

    local d2; d2=$(new_sandbox 7615b "$d/storage")
    run_cac "$d2" pull "CodingAgentConfig_HOSTA_${USER_NAME}_codex_260102-100000.zip" >/dev/null 2>&1 \
        || { echo "explicit bundle pull failed"; return 1; }
    assert_file_exists "$d2/home/.codex/auth.json" "codex extracted via explicit id" || return 1
    if [[ -f "$d2/home/.claude.json" ]]; then echo "claude leaked on explicit codex bundle"; return 1; fi
    return 0
}

# ============================================================================
# Run
# ============================================================================

echo "=========================================="
echo "Issue #76: batch push/pull per-tool"
echo "=========================================="

run_test "76.1  push per-tool, no _all_ bundle" test_76_1_push_per_tool_no_all
run_test "76.2  mixed creds: OK pushed, failed skipped (no bundle)" test_76_2_mixed_creds
run_test "76.3  no config -> exit 1, nothing to push" test_76_3_no_config
run_test "76.4  all creds fail -> exit 1, nothing uploaded" test_76_4_all_creds_fail
run_test "76.5  --skip-check bypasses credential check" test_76_5_skip_check_no_probe
run_test "76.6  upload failure -> exit 1 + error surfaced" test_76_6_upload_failure
run_test "76.7  dry-run: would-push, no upload, no temp leftover" test_76_7_dry_run
run_test "76.8  temp cleanup on mid-run failure" test_76_8_temp_cleanup_on_failure
run_test "76.9  push --tool X unchanged (single + creds-fail abort)" test_76_9_single_tool_unchanged
run_test "76.10 round-trip no-tool push -> no-tool pull" test_76_10_round_trip
run_test "76.11 missing tool warns, pull still succeeds" test_76_11_missing_tool_warns
run_test "76.12 legacy _all_ read-fallback" test_76_12_legacy_fallback
run_test "76.13 fresher per-tool bundle not clobbered" test_76_13_no_clobber
run_test "76.14 zero bundles -> exit 1" test_76_14_zero_bundles
run_test "76.15 pull --tool / BUNDLE_ID unchanged" test_76_15_single_and_explicit_unchanged

framework_report
