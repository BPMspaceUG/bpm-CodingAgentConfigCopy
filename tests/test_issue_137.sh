#!/usr/bin/env bash
# tests/test_issue_137.sh - Tests for Issue #137
#
# Field report contabo03 2026-09-23: claude.ai/install.sh refused to run under
# sudo, yet `cac env install claude --global` printed SUCCESS. The installer's
# exit status was never read (the global-scope symlink step after the
# `curl | bash` overwrote $?), and the post-install check then found a stale
# binary on the extended PATH. Separately, the legacy-Bun warning told the
# operator to `rm -rf /opt/claude-code` while the launcher on PATH still ran
# from it.
#
# Seams: env_install_tool for a curl tool (curl stubbed on PATH, real detection
# against a fake HOME), and _env_warn_legacy_bun_install.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

# Run "$@" in a child bash that has sourced lib/logging, utils and env.
# Output on stdout+stderr; the caller sets HOME/PATH via env.
in_env_child() {
    bash -c 'source "$1/lib/logging.sh"; source "$1/lib/utils.sh" 2>/dev/null
             source "$1/lib/env.sh"; shift; "$@"' _ "$REPO_DIR" "$@" 2>&1
}

# Run env_install_tool <tool> <scope> in a child bash with a fake HOME, a stub
# curl that serves <installer_body>, and PATH limited to the stub dir plus
# system dirs. A stale binary of the tool sits in $HOME/.local/bin, which the
# post-install check adds to PATH. Sets OUT and RC.
run_install() {
    local name="$1" tool="$2" scope="$3" installer_body="$4" stale_binary="$5"
    local d="$TEST_TMPDIR/$name"
    mkdir -p "$d/home/.local/bin" "$d/stub"
    printf '#!/bin/sh\necho "%s 0.0.1-stale"\n' "$stale_binary" > "$d/home/.local/bin/$stale_binary"
    chmod +x "$d/home/.local/bin/$stale_binary"

    write_curl_stub_serving "$d/stub/curl" "$installer_body"
    OUT=$(HOME="$d/home" PATH="$d/stub:/usr/bin:/bin" in_env_child env_install_tool "$tool" "$scope" --yes)
    RC=$?
}

# curl stub that prints <installer_body> as the downloaded script.
write_curl_stub_serving() {
    printf '#!/bin/sh\ncat <<'"'"'EOS'"'"'\n%s\nEOS\n' "$2" > "$1"
    chmod +x "$1"
}

# 137.1 [anti-bug]: a refused installer is a failed install, even though a
#       stale binary is found on the extended PATH afterwards.
test_137_1_failed_installer_is_failure() {
    run_install 1371 mistral user 'echo "do not run this installer with sudo" >&2; exit 1' vibe

    [[ "$RC" -ne 0 ]] || { echo "rc 0 after failed installer: $OUT" >&2; return 1; }
    if [[ "$OUT" == *"SUCCESS"* ]]; then
        echo "SUCCESS printed after failed installer: $OUT" >&2
        return 1
    fi
    assert_contains "do not run this installer with sudo" "$OUT" "installer message shown" || return 1
    assert_contains "ERROR" "$OUT" "failure reported as error" || return 1
}

# 137.2: a successful installer still reports SUCCESS and returns 0.
test_137_2_successful_installer_unchanged() {
    run_install 1372 mistral user 'echo "installed"; exit 0' vibe

    assert_equals 0 "$RC" "exit code after successful installer" || { echo "$OUT" >&2; return 1; }
    assert_contains "SUCCESS" "$OUT" "success reported" || return 1
}

# 137.3 [anti-bug]: a failed download (curl non-zero) is a failed install,
#       even without pipefail in the caller.
test_137_3_failed_download_is_failure() {
    local d="$TEST_TMPDIR/1373"
    mkdir -p "$d/home" "$d/stub"
    printf '#!/bin/sh\necho "curl: (22) The requested URL returned error: 503" >&2\nexit 22\n' > "$d/stub/curl"
    chmod +x "$d/stub/curl"
    # The child shell runs without pipefail (in_env_child sets none).
    OUT=$(HOME="$d/home" PATH="$d/stub:/usr/bin:/bin" in_env_child env_install_tool mistral user --yes)
    RC=$?

    [[ "$RC" -ne 0 ]] || { echo "rc 0 after failed download: $OUT" >&2; return 1; }
    if [[ "$OUT" == *"SUCCESS"* ]]; then
        echo "SUCCESS printed after failed download: $OUT" >&2
        return 1
    fi
}

# 137.4 [root only]: at global scope a failed installer creates no
#       /usr/local/bin symlink. Runs only as root (e.g. tests/Dockerfile.test).
test_137_4_global_failure_creates_no_symlink() {
    local link="/usr/local/bin/vibe"
    local before; before=$(readlink "$link" 2>/dev/null || echo "<none>")
    run_install 1374 mistral global 'exit 1' vibe
    local after; after=$(readlink "$link" 2>/dev/null || echo "<none>")

    [[ "$RC" -ne 0 ]] || { echo "rc 0 after failed global install: $OUT" >&2; return 1; }
    assert_equals "$before" "$after" "/usr/local/bin/vibe unchanged" || return 1
}

# 137.5 [anti-bug]: no rm -rf advice for a legacy dir the launcher on PATH
#       still execs into; the launcher is named instead.
test_137_5_live_legacy_dir_no_rm_advice() {
    local d="$TEST_TMPDIR/1375"
    mkdir -p "$d/opt/claude-code/node_modules/.bin" "$d/bin"
    printf '#!/bin/sh\nexec %s/opt/claude-code/node_modules/.bin/claude "$@"\n' "$d" > "$d/bin/claude"
    chmod +x "$d/bin/claude"

    local out
    out=$(PATH="$d/bin:/usr/bin:/bin" in_env_child _env_warn_legacy_bun_install "$d/opt/claude-code" "$d/opt/nonexistent-cc")

    if [[ "$out" == *"rm -rf"* ]]; then
        echo "rm -rf advised for a live install: $out" >&2
        return 1
    fi
    assert_contains "$d/bin/claude" "$out" "launcher named" || return 1
    assert_contains "Legacy Bun-based" "$out" "legacy dir still reported" || return 1
}

# 137.7: a launcher that is a SYMLINK into the legacy dir is named by its path.
test_137_7_symlinked_launcher_named() {
    local d="$TEST_TMPDIR/1377"
    mkdir -p "$d/opt/claude-code/node_modules/.bin" "$d/bin"
    printf '#!/bin/sh\necho claude\n' > "$d/opt/claude-code/node_modules/.bin/claude"
    chmod +x "$d/opt/claude-code/node_modules/.bin/claude"
    ln -s "$d/opt/claude-code/node_modules/.bin/claude" "$d/bin/claude"

    local out
    out=$(PATH="$d/bin:/usr/bin:/bin" in_env_child _env_warn_legacy_bun_install "$d/opt/claude-code" "$d/opt/nonexistent-cc")

    if [[ "$out" == *"rm -rf"* ]]; then
        echo "rm -rf advised for a live install: $out" >&2
        return 1
    fi
    assert_contains "$d/bin/claude" "$out" "symlinked launcher named by path"
}

# 137.8: when liveness cannot be verified, no removal advice and no claim
#        that the dir is in use.
test_137_8_unverifiable_is_not_called_in_use() {
    local d="$TEST_TMPDIR/1378"
    mkdir -p "$d/opt/claude-code" "$d/bin"
    printf '#!/bin/sh\nexit 1\n' > "$d/bin/ps"; chmod +x "$d/bin/ps"

    local out
    out=$(PATH="$d/bin:/usr/bin:/bin" _ENV_PROC_ROOT="$d/noproc" \
        in_env_child _env_warn_legacy_bun_install "$d/opt/claude-code" "$d/opt/nonexistent-cc")

    if [[ "$out" == *"rm -rf"* ]]; then
        echo "rm -rf advised although liveness is unknown: $out" >&2
        return 1
    fi
    if [[ "$out" == *"still in use"* ]]; then
        echo "claims use that was not shown: $out" >&2
        return 1
    fi
    assert_contains "cannot verify" "$out" "reason shown" || return 1
}

# 137.9: `env status` shows the legacy warning instead of discarding it.
test_137_9_env_status_shows_warning() {
    local d="$TEST_TMPDIR/1379"
    mkdir -p "$d/opt/claude-code"
    local out
    out=$(in_env_child bash -c 'source "$0/lib/logging.sh"; source "$0/lib/utils.sh" 2>/dev/null; source "$0/lib/env.sh"
        _env_warn_legacy_bun_install() { utils_warn "LEGACY-WARNING-SEEN"; return 0; }
        env_show_status' "$REPO_DIR")
    assert_contains "LEGACY-WARNING-SEEN" "$out" "warning reaches the operator"
}

# 137.6: an unused legacy dir keeps the existing removal advice.
test_137_6_unused_legacy_dir_keeps_advice() {
    local d="$TEST_TMPDIR/1376"
    mkdir -p "$d/opt/claude-code"

    local out
    out=$(PATH="/usr/bin:/bin" in_env_child _env_warn_legacy_bun_install "$d/opt/claude-code" "$d/opt/nonexistent-cc")

    assert_contains "Remove with: sudo rm -rf $d/opt/claude-code" "$out" "removal advice kept"
}

echo "========================================"
echo "Issue #137: failed installer is a failed install; no rm -rf on a live dir"
echo "========================================"

IS_ROOT=false; [[ "$EUID" -eq 0 ]] && IS_ROOT=true

run_test "137.1 refused installer: no SUCCESS, non-zero exit" test_137_1_failed_installer_is_failure
run_test "137.2 successful installer: SUCCESS, exit 0" test_137_2_successful_installer_unchanged
run_test "137.3 failed download: no SUCCESS, non-zero exit" test_137_3_failed_download_is_failure
run_test_if "$IS_ROOT" "137.4 global failure creates no /usr/local/bin symlink" \
    test_137_4_global_failure_creates_no_symlink "needs root"
run_test "137.5 live legacy dir: no rm -rf advice, launcher named" test_137_5_live_legacy_dir_no_rm_advice
run_test "137.6 unused legacy dir: removal advice kept" test_137_6_unused_legacy_dir_keeps_advice
run_test "137.7 symlinked launcher into legacy dir is named" test_137_7_symlinked_launcher_named
run_test "137.8 unverifiable liveness: no advice, not called in use" test_137_8_unverifiable_is_not_called_in_use
run_test "137.9 env status shows the legacy warning" test_137_9_env_status_shows_warning

framework_report
