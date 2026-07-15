#!/usr/bin/env bash
# tests/test_issue_86.sh - Issue #86: npm `env update` must install; `env repair`
# must fix a wrong-target symlink.
#
# Two defects for a tool whose PATH binary resolves outside the managed npm prefix:
#   1. `env update` used `npm update -g`, which never INSTALLS an absent package
#      (exits 0, reports "already at latest" off the stale PATH version).
#   2. `env repair` could only CREATE a missing symlink, so a symlink that exists
#      but points at the wrong (legacy Bun) target was a no-op — and, crucially,
#      that case fails `binary_location` (not `symlink_target`), which routed to a
#      no-op for non-claude tools.
#
# Run with: ./tests/test_issue_86.sh   (or via ./tests/run_tests.sh)
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/test_framework.sh"
source "${PROJECT_ROOT}/lib/env.sh"

# ---------------------------------------------------------------------------
# Helper: load the REAL _env_repair_npm_symlink with /usr/local/bin rewritten to a
# temp dir and the root-EUID guard neutralised.
# ---------------------------------------------------------------------------
_load_real_npm_symlink() {
    local mockusr="$1"
    local body
    body=$(sed -n '/^_env_repair_npm_symlink()/,/^}/p' "${PROJECT_ROOT}/lib/env.sh")
    body=$(echo "$body" | sed -e "s|/usr/local/bin|${mockusr}|g")
    body=$(echo "$body" | sed 's|\[\[ "${EUID:-\$(id -u)}" -eq 0 \]\]|true|')
    eval "$body"
}

# ============================================================================
# Defect 1: env update installs when absent; version read from managed prefix
# ============================================================================

# `npm update -g` never installs an absent package -> command must be `install`.
test_86_update_installs_when_absent() {
    local oldhome="$HOME"
    export HOME="${TEST_TMPDIR}/home-absent"
    mkdir -p "$HOME/.local/lib/node_modules"   # prefix exists, package does not
    local cmd
    cmd=$(_env_npm_update_or_install_cmd "@google/gemini-cli" "user")
    export HOME="$oldhome"
    assert_contains "install -g" "$cmd" "absent package -> npm install" || return 1
    assert_contains "@google/gemini-cli@latest" "$cmd" "install pins @latest"
}

# When the package IS present in the managed prefix, keep using `npm update -g`.
test_86_update_updates_when_present() {
    local oldhome="$HOME"
    export HOME="${TEST_TMPDIR}/home-present"
    local pkgdir="$HOME/.local/lib/node_modules/@google/gemini-cli"
    mkdir -p "$pkgdir"
    printf '{ "version": "0.26.0" }\n' > "$pkgdir/package.json"
    local cmd
    cmd=$(_env_npm_update_or_install_cmd "@google/gemini-cli" "user")
    export HOME="$oldhome"
    assert_contains "update -g" "$cmd" "present package -> npm update" || return 1
    if [[ "$cmd" == *"install -g"* ]]; then
        fail "present package uses update" "used install instead of update: $cmd"
        return 1
    fi
    pass "present package uses npm update -g"
}

# Version is read from the managed prefix package.json, not the PATH binary.
test_86_version_from_managed_prefix() {
    local oldhome="$HOME"
    export HOME="${TEST_TMPDIR}/home-ver"
    local pkgdir="$HOME/.local/lib/node_modules/@google/gemini-cli"
    mkdir -p "$pkgdir"
    printf '{ "name": "x", "version": "0.50.0" }\n' > "$pkgdir/package.json"
    local v absent
    v=$(_env_npm_pkg_installed_version "@google/gemini-cli" "user")
    absent=$(_env_npm_pkg_installed_version "@openai/codex" "user")
    export HOME="$oldhome"
    assert_equals "0.50.0" "$v" "managed version parsed" || return 1
    assert_equals "" "$absent" "absent package yields empty version"
}

# REQUIRED (defect 2 of the pair): when the PATH binary is unmanaged, the update
# report states the split and does NOT print a bogus `updated: <old> -> <new>` line.
test_86_reports_unmanaged_path() {
    local oldhome="$HOME"
    export HOME="${TEST_TMPDIR}/home-unmanaged"
    local pkgdir="$HOME/.local/lib/node_modules/@google/gemini-cli"
    mkdir -p "$pkgdir"
    printf '{ "version": "0.50.0" }\n' > "$pkgdir/package.json"
    local mockbin="${TEST_TMPDIR}/mockbin-unmanaged"
    mkdir -p "$mockbin"
    printf '#!/bin/bash\necho 0.26.0\n' > "$mockbin/gemini"; chmod +x "$mockbin/gemini"
    local out
    out=$(PATH="$mockbin:/usr/bin:/bin" _env_npm_report_update gemini user "0.50.0" 0 2>&1)
    export HOME="$oldhome"
    assert_contains "unmanaged" "$out" "reports unmanaged PATH split" || return 1
    if [[ "$out" == *"updated: 0.26.0"* ]]; then
        fail "no bogus update line" "printed a bogus updated line from the PATH version: $out"
        return 1
    fi
    pass "unmanaged PATH reported without a bogus update line"
}

# Counterpart: when PATH IS the managed install, print the correct managed update.
test_86_reports_managed_update() {
    local oldhome="$HOME"
    export HOME="${TEST_TMPDIR}/home-managed"
    local pkgdir="$HOME/.local/lib/node_modules/@google/gemini-cli"
    mkdir -p "$pkgdir/bundle"
    printf '{ "version": "0.50.0" }\n' > "$pkgdir/package.json"
    printf '#!/bin/bash\necho 0.50.0\n' > "$pkgdir/bundle/gemini.js"; chmod +x "$pkgdir/bundle/gemini.js"
    local mockbin="${TEST_TMPDIR}/mockbin-managed"
    mkdir -p "$mockbin"
    ln -s "$pkgdir/bundle/gemini.js" "$mockbin/gemini"
    local out
    out=$(PATH="$mockbin:/usr/bin:/bin" _env_npm_report_update gemini user "0.26.0" 0 2>&1)
    export HOME="$oldhome"
    assert_contains "updated: 0.26.0 -> 0.50.0" "$out" "managed install update line"
}

# ============================================================================
# Defect 2: repair routing + relink of a wrong-target symlink
# ============================================================================

# REQUIRED: a VALID-but-wrong-target symlink fails `binary_location` (NOT
# `symlink_target`), and the npm dispatch routes it to the relink — proving the
# original plan's create_symlink path was unreachable for this case.
test_86_dispatch_routes_wrong_target_to_relink() {
    local legacy="${TEST_TMPDIR}/opt-bun-route/dist"
    mkdir -p "$legacy"
    printf '#!/bin/bash\necho 0.26.0\n' > "$legacy/index.js"; chmod +x "$legacy/index.js"
    local mockbin="${TEST_TMPDIR}/mockbin-route"
    mkdir -p "$mockbin"
    ln -s "$legacy/index.js" "$mockbin/gemini"

    # The failing check must be binary_location, and symlink_target must PASS.
    local bp="$mockbin/gemini"
    if _env_chk_binary_location "$bp" gemini; then
        fail "binary_location fails for wrong target" "expected binary_location to FAIL"
        return 1
    fi
    if ! _env_chk_symlink_target "$bp" gemini; then
        fail "symlink_target passes for valid target" "expected symlink_target to PASS"
        return 1
    fi

    # Drive the real dispatch with stubbed leaf repairs; assert relink is chosen.
    _env_repair_create_symlink() { echo "RELINK_CALLED"; }
    _env_repair_remove_bun_opt() { echo "REMOVE_BUN_CALLED"; }
    local out
    out=$(PATH="$mockbin:/usr/bin:/bin" _env_repair_one_tool gemini false 2>&1) || true
    unset -f _env_repair_create_symlink _env_repair_remove_bun_opt

    assert_contains "RELINK_CALLED" "$out" "npm binary_location routes to relink" || return 1
    if [[ "$out" == *"REMOVE_BUN_CALLED"* ]]; then
        fail "npm tool not routed to remove_bun" "gemini wrongly routed to remove_bun_opt"
        return 1
    fi
    pass "wrong-target npm symlink routes to relink (binary_location -> relink)"
}

# REQUIRED regression (Codex): a CURL tool (claude) binary_location must still
# route to _env_repair_remove_bun_opt, not the npm relink.
test_86_curl_binary_location_routes_to_remove_bun() {
    local mockbin="${TEST_TMPDIR}/mockbin-claude"
    mkdir -p "$mockbin"
    local bad="${TEST_TMPDIR}/badloc-claude"
    mkdir -p "$bad"
    printf '#!/bin/bash\necho 1.2.3\n' > "$bad/claude"; chmod +x "$bad/claude"
    ln -s "$bad/claude" "$mockbin/claude"

    _env_repair_create_symlink() { echo "RELINK_CALLED"; }
    _env_repair_remove_bun_opt() { echo "REMOVE_BUN_CALLED"; }
    local out
    out=$(PATH="$mockbin:/usr/bin:/bin" _env_repair_one_tool claude false 2>&1) || true
    unset -f _env_repair_create_symlink _env_repair_remove_bun_opt

    assert_contains "REMOVE_BUN_CALLED" "$out" "curl binary_location routes to remove_bun_opt" || return 1
    if [[ "$out" == *"RELINK_CALLED"* ]]; then
        fail "curl tool not routed to relink" "claude wrongly routed to npm relink"
        return 1
    fi
    pass "curl tool binary_location routes to remove_bun_opt (no regression)"
}

# REQUIRED core case: repair re-points a wrong-target symlink to the managed
# install, and leaves the legacy tree untouched.
test_86_relink_wrong_target_symlink() {
    local oldhome="$HOME"
    export HOME="${TEST_TMPDIR}/home-relink"
    # NB: use MOCK_*-named vars in the npm stub — the function under test declares
    # locals named `prefix`/`pkgdir`, which would shadow same-named test vars under
    # bash dynamic scoping and make the stub read empty values.
    local MOCK_PREFIX="${TEST_TMPDIR}/npmprefix-relink"
    local MOCK_PKGDIR="$MOCK_PREFIX/lib/node_modules/@google/gemini-cli"
    mkdir -p "$MOCK_PKGDIR/bundle"
    printf '#!/bin/bash\necho 0.50.0\n' > "$MOCK_PKGDIR/bundle/gemini.js"; chmod +x "$MOCK_PKGDIR/bundle/gemini.js"
    local legacy="${TEST_TMPDIR}/opt-bun-relink/node_modules/@google/gemini-cli/dist"
    mkdir -p "$legacy"
    printf '#!/bin/bash\necho 0.26.0\n' > "$legacy/index.js"; chmod +x "$legacy/index.js"
    local MOCK_USR="${TEST_TMPDIR}/usrbin-relink"
    mkdir -p "$MOCK_USR"
    ln -s "$legacy/index.js" "$MOCK_USR/gemini"

    # Stub npm: report the mock prefix; on install, (re)create the correct link.
    npm() {
        case "${1:-}" in
            prefix) echo "$MOCK_PREFIX" ;;
            install) ln -sf "$MOCK_PKGDIR/bundle/gemini.js" "$MOCK_USR/gemini" ;;
        esac
        return 0
    }
    _load_real_npm_symlink "$MOCK_USR"
    _env_repair_npm_symlink gemini gemini >/dev/null 2>&1 || true
    unset -f npm
    export HOME="$oldhome"

    local tgt
    tgt=$(readlink -f "$MOCK_USR/gemini" 2>/dev/null || true)
    assert_equals "$MOCK_PKGDIR/bundle/gemini.js" "$tgt" "symlink re-pointed to managed install" || return 1
    if [[ -f "$legacy/index.js" ]]; then
        pass "legacy tree left untouched during relink"
    else
        fail "legacy tree untouched" "relink removed the legacy tree"
        return 1
    fi
}

# Declines (returns non-zero) when no managed install can be produced, without
# touching the wrong symlink or the legacy tree.
test_86_relink_declines_without_managed_install() {
    local MOCK_PREFIX="${TEST_TMPDIR}/npmprefix-decline"
    mkdir -p "$MOCK_PREFIX/lib/node_modules"   # prefix exists, no package present
    local legacy="${TEST_TMPDIR}/opt-bun-decline/dist"
    mkdir -p "$legacy"
    printf 'x\n' > "$legacy/index.js"
    local MOCK_USR="${TEST_TMPDIR}/usrbin-decline"
    mkdir -p "$MOCK_USR"
    ln -s "$legacy/index.js" "$MOCK_USR/gemini"

    # npm install stub does NOT create the package dir -> no managed install.
    npm() { case "${1:-}" in prefix) echo "$MOCK_PREFIX" ;; install) : ;; esac; return 0; }
    _load_real_npm_symlink "$MOCK_USR"
    local rc=0
    _env_repair_npm_symlink gemini gemini >/dev/null 2>&1 || rc=$?
    unset -f npm

    if [[ $rc -eq 0 ]]; then
        fail "relink declines without managed install" "expected non-zero decline, got 0"
        return 1
    fi
    # The wrong symlink must be left intact (not removed before a valid target exists).
    assert_equals "$legacy/index.js" "$(readlink "$MOCK_USR/gemini" 2>/dev/null || true)" \
        "wrong symlink left intact on decline" || return 1
    assert_file_exists "$legacy/index.js" "legacy tree left intact on decline"
}

# Bun is BANNED: the new npm functions must introduce no `bun` command/path.
test_86_no_bun_command_introduced() {
    local fn code
    for fn in _env_repair_npm_symlink _env_npm_update_or_install_cmd \
              _env_npm_report_update _env_npm_pkg_installed_version _env_npm_managed_prefix; do
        code=$(sed -n "/^${fn}()/,/^}/p" "${PROJECT_ROOT}/lib/env.sh" | grep -v '^[[:space:]]*#')
        if echo "$code" | grep -iqw bun; then
            fail "no bun command introduced" "function $fn references a bun command/path"
            return 1
        fi
    done
    pass "new npm functions introduce no bun command/path"
}

# ============================================================================
# Test registration
# ============================================================================

framework_init
run_test "update installs when package absent from prefix" test_86_update_installs_when_absent
run_test "update updates when package present" test_86_update_updates_when_present
run_test "version read from managed prefix" test_86_version_from_managed_prefix
run_test "update report flags unmanaged PATH (no bogus line)" test_86_reports_unmanaged_path
run_test "update report correct for managed install" test_86_reports_managed_update
run_test "dispatch routes wrong-target npm symlink to relink" test_86_dispatch_routes_wrong_target_to_relink
run_test "curl binary_location routes to remove_bun_opt" test_86_curl_binary_location_routes_to_remove_bun
run_test "repair relinks wrong-target symlink" test_86_relink_wrong_target_symlink
run_test "repair declines without a managed install" test_86_relink_declines_without_managed_install
run_test "new npm functions introduce no bun" test_86_no_bun_command_introduced
framework_report
