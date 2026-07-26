#!/usr/bin/env bash
# tests/test_issue_100.sh - Tests for Issue #100:
#
#   The curl-path post-update verification in env_update_tool asserted
#   ROOT-RESOLVABILITY, not INSTALLABILITY. Under a sudo-escalated update
#   (Issue #79) it printed "<tool> updated: unknown -> X.Y.Z" and exited 0
#   while the binary lived in /root/.local/bin and was unreachable for every
#   non-root user on the host.
#
# The fix, all in lib/env.sh:
#   * _env_verify_check_path   — the post-install probe PATH drops
#     $HOME/.local/bin in root context, where $HOME is /root.
#   * _env_binary_reachable_by_all — the assertion that was missing: reject a
#     real path inside root's private home, or one whose ancestors are not
#     world-traversable, or a file that is not world-executable.
#   * symmetric measurement — the PRE-update version is re-read on the SAME
#     sanitised PATH as the post-update read, after the Issues #94/#95 guard
#     and the Issue #73 pre-flight so a refusal still probes nothing.
#   * new_version == "unknown" is never reported as success; old_version ==
#     "unknown" is reported WITHOUT inventing a transition.
#   * _env_chk_user_reachable — a NEW `cac env check` check (not a widening of
#     _env_chk_binary_location, whose repair route deletes /opt trees).
#
# Network-free, sudo-free, root-free: every layout is built under TEST_TMPDIR,
# curl is never invoked, and the _env_is_root / _env_root_home seams make the
# root-only branches reachable from a normal user.
#
# HARNESS NOTE — why this suite relaxes its own TEST_TMPDIR to 0755:
# framework_init creates it 0700. The property under test is literally "is
# every ancestor directory world-traversable", so a 0700 ancestor would make
# EVERY fixture unreachable, every accept-case vacuous, and every reject-case
# pass for the wrong reason. The fixtures are throwaway fake binaries and the
# tree is removed on exit. Individual "must be rejected" cases create their own
# explicit 0700 directories.
#
# CONTROL ARMS: every case that asserts an absence ("did not fail", "did not
# print X") is paired IN THE SAME FUNCTION with an arm asserting the presence
# under the flipped condition. A negative-only assertion is trivially satisfied
# by a build where the mechanism does not exist — which is how three tests
# passed against broken code earlier in this round.
#
# Test inventory:
#   100.1   _env_verify_check_path: root drops /root/.local/bin
#   100.2   reachable_by_all ACCEPTS a world-reachable payload (positive control)
#   100.3   rejects a real path inside root's home        (+ control)
#   100.4   rejects a non-world-traversable ancestor dir  (+ control)
#   100.5   rejects a non-world-executable file           (+ control)
#   100.6   permissive on unknowns (vanished path)        (+ control)
#   100.7   a rejection does NOT abort a `set -e` caller  (+ control)
#   100.8   E2E: the #100 headline false success is refused (+ control)
#   100.9   E2E: new_version == "unknown" is not success  (+ control)
#   100.10  E2E: old_version == "unknown" reports no bogus transition (+ control)
#   100.11  the symmetric re-read exists and runs AFTER the #94/#95 guard (+ control)
#   100.12  composition: guard refusal pre-empts the new verification (+ control)
#   100.13  a NON-root user-scope update is unchanged     (+ control)
#   100.14  _env_chk_user_reachable verdicts
#   100.15  the repair arm warns and reaches NO destructive route (+ control)
#   100.16  _env_chk_binary_location still accepts what it accepted before
#   100.17  #110: unknown-old never short-circuits refuse-unreadable /
#           refuse-downgrade (3 arms pinning the order of all three outcomes)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "${SCRIPT_DIR}/test_framework.sh"
# shellcheck source=lib/env.sh
source "${REPO_DIR}/lib/env.sh"

framework_init
# See HARNESS NOTE above.
chmod 755 "$TEST_TMPDIR"

# Build a world-traversable scratch dir for one test.
_scratch() {
    local d="${TEST_TMPDIR}/$1"
    mkdir -p "$d"
    chmod 755 "$d"
    echo "$d"
}

# Create an executable, world-readable regular file.
_mkbin() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\nexit 0\n' > "$1"
    chmod 755 "$1"
}

# ----------------------------------------------------------------------------
# 100.1 — the probe PATH drops root's private ~/.local/bin in root context
# ----------------------------------------------------------------------------
test_1_verify_check_path() {
    local T; T=$(_scratch t1)
    export HOME="$T/home"

    local got
    got=$( _env_is_root() { return 1; }; _env_verify_check_path )
    assert_equals "/usr/local/bin:$T/home/.local/bin:/usr/bin:/bin" "$got" \
        "non-root keeps the user's own ~/.local/bin" || return 1

    # The fix: under root, "$HOME" is /root — a 0700 private dir that must not
    # decide whether a SYSTEM-WIDE install succeeded.
    got=$( _env_is_root() { return 0; }; _env_verify_check_path )
    assert_equals "/usr/local/bin:/usr/bin:/bin" "$got" \
        "root context drops \$HOME/.local/bin" || return 1
    return 0
}

# ----------------------------------------------------------------------------
# 100.2 — POSITIVE CONTROL for 100.3-100.6: a good layout is accepted.
# Without this, a helper that rejected everything would pass all reject cases.
# ----------------------------------------------------------------------------
test_2_accepts_reachable() {
    local T; T=$(_scratch t2)
    _mkbin "$T/usr/local/bin/claude100"
    chmod 755 "$T/usr" "$T/usr/local" "$T/usr/local/bin"

    _env_binary_reachable_by_all "$T/usr/local/bin/claude100" || {
        echo "world-reachable binary must be accepted: $_ENV_VERIFY_REASON" >&2
        return 1
    }
    assert_equals "" "$_ENV_VERIFY_REASON" "no reason set on accept" || return 1
    return 0
}

# ----------------------------------------------------------------------------
# 100.3 — the Issue #57 layout: /usr/local/bin/x -> <root home>/.local/bin/x
# ----------------------------------------------------------------------------
test_3_rejects_root_home() {
    local T; T=$(_scratch t3)
    local rootlike="$T/rootlike"
    _mkbin "$rootlike/.local/bin/claude100"
    mkdir -p "$T/usr/local/bin"
    ln -sf "$rootlike/.local/bin/claude100" "$T/usr/local/bin/claude100"

    local out rc=0
    out=$(
        _env_root_home() { echo "$rootlike"; }
        _env_binary_reachable_by_all "$T/usr/local/bin/claude100" \
            || { echo "$_ENV_VERIFY_REASON"; exit 1; }
    ) || rc=$?
    [[ "$rc" -ne 0 ]] || { echo "root-home payload must be rejected" >&2; return 1; }
    assert_contains "root's private home" "$out" "reason names root's home" || return 1

    # CONTROL ARM — without it this case also passes on a build that rejects
    # every path. Same layout, root's home declared elsewhere: must be ACCEPTED.
    rc=0
    (
        _env_root_home() { echo "$T/somewhere-else"; }
        _env_binary_reachable_by_all "$T/usr/local/bin/claude100"
    ) || rc=$?
    [[ "$rc" -eq 0 ]] || {
        echo "control arm: identical layout outside root's home must be accepted" >&2
        return 1
    }
    return 0
}

# ----------------------------------------------------------------------------
# 100.4 — a non-world-traversable ANCESTOR makes the binary unreachable even
# though the binary itself is 0755. This is why `[[ -x ]]` cannot be used: as
# root it is true for every path here.
# ----------------------------------------------------------------------------
test_4_rejects_private_ancestor() {
    local T; T=$(_scratch t4)
    _mkbin "$T/private/bin/claude100"
    chmod 700 "$T/private"

    local out rc=0
    out=$(
        _env_binary_reachable_by_all "$T/private/bin/claude100" \
            || { echo "$_ENV_VERIFY_REASON"; exit 1; }
    ) || rc=$?
    [[ "$rc" -ne 0 ]] || { echo "0700 ancestor must be rejected" >&2; return 1; }
    assert_contains "not world-traversable" "$out" "reason names traversal" || return 1
    assert_contains "$T/private" "$out" "reason names the offending dir" || return 1

    # CONTROL ARM: loosen the very same directory — must now be accepted.
    chmod 755 "$T/private"
    _env_binary_reachable_by_all "$T/private/bin/claude100" || {
        echo "control arm: 0755 ancestor must be accepted ($_ENV_VERIFY_REASON)" >&2
        return 1
    }
    return 0
}

# ----------------------------------------------------------------------------
# 100.5 — the file's own mode
# ----------------------------------------------------------------------------
test_5_rejects_private_file() {
    local T; T=$(_scratch t5)
    _mkbin "$T/bin/claude100"
    chmod 700 "$T/bin/claude100"

    local out rc=0
    out=$(
        _env_binary_reachable_by_all "$T/bin/claude100" \
            || { echo "$_ENV_VERIFY_REASON"; exit 1; }
    ) || rc=$?
    [[ "$rc" -ne 0 ]] || { echo "0700 file must be rejected" >&2; return 1; }
    assert_contains "not world-executable" "$out" "reason names the file mode" || return 1

    # CONTROL ARM: same file, world-executable.
    chmod 755 "$T/bin/claude100"
    _env_binary_reachable_by_all "$T/bin/claude100" || {
        echo "control arm: 0755 file must be accepted ($_ENV_VERIFY_REASON)" >&2
        return 1
    }
    return 0
}

# ----------------------------------------------------------------------------
# 100.6 — unknowns are permissive. A verification whose job is to refuse a
# KNOWN-bad layout must not invent failures out of what it could not measure:
# the false-positive cost here is a refused update.
# ----------------------------------------------------------------------------
test_6_permissive_on_unknown() {
    local T; T=$(_scratch t6)

    _env_binary_reachable_by_all "$T/does-not-exist/claude100" || {
        echo "a vanished path must not be reported as unreachable" >&2
        return 1
    }
    _env_binary_reachable_by_all "" || {
        echo "an empty path must be permissive" >&2
        return 1
    }

    # CONTROL ARM — proves the permissiveness is scoped to unknowns and the
    # helper is not simply always-accept.
    _mkbin "$T/bad/bin/claude100"
    chmod 700 "$T/bad"
    if _env_binary_reachable_by_all "$T/bad/bin/claude100"; then
        echo "control arm: a measurable bad layout must still be rejected" >&2
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
# 100.7 — REGRESSION for a real defect found while implementing this fix.
#
# The first version of _env_binary_reachable_by_all inspected $? after a BARE
# call to _env_mode_has_other_x. lib/env.sh is sourced into `set -euo pipefail`,
# so a "no world-execute bit" result would have ABORTED THE ENTIRE RUN instead
# of returning a reason — a guard that kills the process rather than reporting
# is not a safer failure, it is a different wrong answer. `bash -n` and
# `shellcheck --severity=error` both passed on that code; only executing it
# under `set -e` catches it. Hence this case, and hence `|| rc=$?` at both call
# sites being load-bearing rather than decoration.
#
# This suite runs under `set -uo pipefail` (house style, no -e), so the guard
# must be re-enabled explicitly here or the defect is invisible.
# ----------------------------------------------------------------------------
test_7_set_e_safety() {
    local T; T=$(_scratch t7)
    _mkbin "$T/priv/bin/claude100"
    chmod 700 "$T/priv"
    _mkbin "$T/ok/bin/claude100"

    local out
    out=$(bash -c '
        source "$1/lib/env.sh"
        set -euo pipefail          # production shape, at the call site
        if _env_binary_reachable_by_all "$2"; then echo "ACCEPT"; else echo "REJECT"; fi
        if _env_binary_reachable_by_all "$3"; then echo "ACCEPT"; else echo "REJECT"; fi
        echo "SURVIVED"
    ' _ "$REPO_DIR" "$T/priv/bin/claude100" "$T/ok/bin/claude100" 2>&1)

    assert_contains "SURVIVED" "$out" "rejection must not abort a set -e caller" || return 1
    assert_contains "REJECT" "$out" "the bad layout is still rejected under set -e" || return 1
    # CONTROL ARM: the same set -e run also accepts the good layout, so
    # "SURVIVED" cannot be produced by a helper that never rejects anything.
    assert_contains "ACCEPT" "$out" "the good layout is still accepted under set -e" || return 1
    return 0
}

# ----------------------------------------------------------------------------
# Shared E2E setup, and why it is shaped this way.
#
# _env_verify_check_path is STUBBED in the E2E cases to point at the fixture
# tree — the real one names real system directories, which no test may write.
# Its own logic is covered by 100.1; these cases exercise the verification block
# that consumes it.
#
# EACH E2E CASE ALSO SETS HOME="$T" AND PUTS THE LAUNCHER IN "$T/.local/bin".
# That is not decoration. The PRE-FIX build has no _env_verify_check_path at
# all; it uses a hardcoded "/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin". A
# fixture outside those dirs is invisible to it, so the pre-fix run dies at
# "binary is not on PATH" — a failure that proves nothing, because a build that
# always errored would fail identically. Anchoring the launcher under $HOME
# makes BOTH builds resolve the SAME binary, so the pre-fix run reaches the
# comparison and prints the exact false success Issue #100 documents
# ("updated: unknown -> X.Y.Z", exit 0) while the fixed build refuses it.
# Without this the E2E cases would be the very defect this suite exists to
# catch: an assertion satisfied by something other than the property claimed.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# 100.8 — THE HEADLINE. Pre-fix this printed "updated: 1.0.0 -> 2.0.0" and
# exited 0 with the binary reachable only by root.
# ----------------------------------------------------------------------------
test_8_e2e_unreachable_refused() {
    local T; T=$(_scratch t8)
    local rootlike="$T/rootlike"
    local mark="$T/installed"
    _mkbin "$rootlike/.local/bin/claude100"
    mkdir -p "$T/.local/bin"
    ln -sf "$rootlike/.local/bin/claude100" "$T/.local/bin/claude100"

    local out rc=0
    out=$(
        export HOME="$T"          # see the E2E note above — pre-fix visibility
        export PATH="$T/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_root_home() { echo "$rootlike"; }
        _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { [[ -e "$mark" ]] && echo "2.0.0" || echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_installer_can_update() { return 0; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$mark"; return 0; }
        env_update_tool claude user 2>&1
    ) || rc=$?

    [[ "$rc" -ne 0 ]] || { echo "expected non-zero exit, got 0: $out" >&2; return 1; }
    assert_contains "unreachable for non-root users" "$out" "names the defect" || return 1
    assert_contains "root's private home" "$out" "names the reason" || return 1
    assert_contains "NOT a rollback" "$out" "tells the user the install did change" || return 1
    if [[ "$out" == *"updated:"* ]]; then
        echo "reported a successful update for an unreachable install: $out" >&2
        return 1
    fi

    # CONTROL ARM — the same run with a world-reachable payload MUST succeed and
    # MUST print the transition. Without this, the case above would pass on any
    # build that fails for any reason at all.
    rm -f "$mark"
    _mkbin "$T/shared/bin/claude100"
    ln -sf "$T/shared/bin/claude100" "$T/.local/bin/claude100"
    rc=0
    out=$(
        export HOME="$T"
        export PATH="$T/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_root_home() { echo "$rootlike"; }
        _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { [[ -e "$mark" ]] && echo "2.0.0" || echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_installer_can_update() { return 0; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$mark"; return 0; }
        env_update_tool claude user 2>&1
    ) || rc=$?
    [[ "$rc" -eq 0 ]] || { echo "control arm: reachable install must succeed: $out" >&2; return 1; }
    assert_contains "updated: 1.0.0 -> 2.0.0" "$out" "control arm reports the transition" || return 1
    return 0
}

# ----------------------------------------------------------------------------
# 100.9 — "updated: X.Y.Z -> unknown" was printed with exit 0.
# ----------------------------------------------------------------------------
test_9_e2e_unknown_new_version() {
    local T; T=$(_scratch t9)
    local mark="$T/installed"
    _mkbin "$T/.local/bin/claude100"

    local out rc=0
    out=$(
        export HOME="$T"
        export PATH="$T/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { [[ -e "$mark" ]] && echo "unknown" || echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_installer_can_update() { return 0; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$mark"; return 0; }
        env_update_tool claude user 2>&1
    ) || rc=$?

    [[ "$rc" -ne 0 ]] || { echo "expected non-zero exit, got 0: $out" >&2; return 1; }
    assert_contains "could not be determined" "$out" "names the unreadable version" || return 1
    if [[ "$out" == *"updated:"* ]]; then
        echo "reported success against an unknown version: $out" >&2
        return 1
    fi

    # CONTROL ARM: identical layout, readable version -> success.
    rm -f "$mark"
    rc=0
    out=$(
        export HOME="$T"
        export PATH="$T/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { [[ -e "$mark" ]] && echo "2.0.0" || echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_installer_can_update() { return 0; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$mark"; return 0; }
        env_update_tool claude user 2>&1
    ) || rc=$?
    [[ "$rc" -eq 0 ]] || { echo "control arm: readable version must succeed: $out" >&2; return 1; }
    assert_contains "updated: 1.0.0 -> 2.0.0" "$out" "control arm reports the transition" || return 1
    return 0
}

# ----------------------------------------------------------------------------
# 100.10 — old == unknown is a REAL success (a previously unreadable install
# that now reports a version is exactly what an update should do) but there is
# no measured transition, so none is printed.
# ----------------------------------------------------------------------------
test_10_e2e_unknown_old_version() {
    local T; T=$(_scratch t10)
    local mark="$T/installed"
    _mkbin "$T/.local/bin/claude100"

    local out rc=0
    out=$(
        export HOME="$T"
        export PATH="$T/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { [[ -e "$mark" ]] && echo "2.0.0" || echo "unknown"; }
        _env_global_install_exists() { return 1; }
        _env_installer_can_update() { return 0; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$mark"; return 0; }
        env_update_tool claude user 2>&1
    ) || rc=$?

    [[ "$rc" -eq 0 ]] || { echo "a repaired install must not be a failure: $out" >&2; return 1; }
    assert_contains "is now at 2.0.0" "$out" "reports the new version" || return 1
    if [[ "$out" == *"unknown ->"* ]]; then
        echo "printed a transition it never measured: $out" >&2
        return 1
    fi

    # CONTROL ARM: a measured transition still prints as one.
    rm -f "$mark"
    rc=0
    out=$(
        export HOME="$T"
        export PATH="$T/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { [[ -e "$mark" ]] && echo "2.0.0" || echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_installer_can_update() { return 0; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$mark"; return 0; }
        env_update_tool claude user 2>&1
    ) || rc=$?
    [[ "$rc" -eq 0 ]] || { echo "control arm must succeed: $out" >&2; return 1; }
    assert_contains "updated: 1.0.0 -> 2.0.0" "$out" "measured transition is printed" || return 1
    return 0
}

# ----------------------------------------------------------------------------
# 100.11 — the symmetric re-read EXISTS, and runs AFTER the #94/#95 guard.
#
# Counting version probes is the only way to see both facts at once:
# env_get_version EXECUTES the tool, and Issue #95's requirement (test 94/95.9)
# is that a guard refusal mutates nothing and probes nothing.
# ----------------------------------------------------------------------------
test_11_reread_after_guard() {
    local T; T=$(_scratch t11)
    _mkbin "$T/.local/bin/claude100"
    local cnt="$T/probes"

    # Guard REFUSES -> only the pre-existing top-of-function read may happen.
    : > "$cnt"
    (
        export HOME="$T"
        export PATH="$T/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "probe" >> "$cnt"; echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_installer_can_update() { return 1; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { return 0; }
        env_update_tool claude user
    ) >/dev/null 2>&1 || true
    local refused; refused=$(wc -l < "$cnt")
    assert_equals "0" "${refused// /}" "a refusal probes the tool ZERO times" || return 1

    # CONTROL ARM: guard ALLOWS -> the re-read happens before the installer.
    # Without this arm, a build with no re-read at all would also show "1".
    : > "$cnt"
    (
        export HOME="$T"
        export PATH="$T/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "probe" >> "$cnt"; echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_installer_can_update() { return 0; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { return 1; }   # stop at the installer
        env_update_tool claude user
    ) >/dev/null 2>&1 || true
    local allowed; allowed=$(wc -l < "$cnt")
    assert_equals "1" "${allowed// /}" "the pre-update read runs once the guard passes" || return 1
    return 0
}

# ----------------------------------------------------------------------------
# 100.12 — composition with Issues #94/#95: the guard still pre-empts.
# ----------------------------------------------------------------------------
test_12_guard_preempts() {
    local T; T=$(_scratch t12)
    local rootlike="$T/rootlike"
    local mark="$T/installed"
    _mkbin "$rootlike/.local/bin/claude100"
    mkdir -p "$T/.local/bin"
    ln -sf "$rootlike/.local/bin/claude100" "$T/.local/bin/claude100"

    local out rc=0
    out=$(
        export HOME="$T"
        export PATH="$T/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_root_home() { echo "$rootlike"; }
        _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_installer_can_update() { _ENV_INSTALLER_LAUNCHER_PATH="$T/.local/bin/claude100"; _ENV_INSTALLER_REAL_PATH="$rootlike/.local/bin/claude100"; return 1; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$mark"; return 0; }
        env_update_tool claude user 2>&1
    ) || rc=$?

    [[ "$rc" -ne 0 ]] || { echo "guard refusal must exit non-zero" >&2; return 1; }
    assert_contains "Launcher on PATH:" "$out" "the #94/#95 refusal text" || return 1
    [[ -e "$mark" ]] && { echo "installer ran despite the guard refusal" >&2; return 1; }
    if [[ "$out" == *"unreachable for non-root users"* ]]; then
        echo "the post-update verification ran after a pre-flight refusal" >&2
        return 1
    fi

    # CONTROL ARM: same layout, guard allows -> the NEW verification is what
    # refuses. Proves the absence above is ordering, not a missing mechanism.
    rc=0
    out=$(
        export HOME="$T"
        export PATH="$T/.local/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_root_home() { echo "$rootlike"; }
        _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_installer_can_update() { return 0; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$mark"; return 0; }
        env_update_tool claude user 2>&1
    ) || rc=$?
    [[ "$rc" -ne 0 ]] || { echo "control arm: unreachable install must fail" >&2; return 1; }
    assert_contains "unreachable for non-root users" "$out" "control arm reaches the new check" || return 1
    return 0
}

# ----------------------------------------------------------------------------
# 100.13 — a NON-root user-scope update is untouched. An ordinary user's own
# copy under a private directory is correct by design; refusing it would be a
# new false negative introduced by this fix.
# ----------------------------------------------------------------------------
test_13_non_root_unchanged() {
    local T; T=$(_scratch t13)
    local mark="$T/installed"
    _mkbin "$T/priv/bin/claude100"
    chmod 700 "$T/priv"          # a layout that WOULD be refused under root
    # Launcher under $HOME/.local/bin so the PRE-FIX hardcoded check_path
    # resolves the same binary — see the E2E note above.
    mkdir -p "$T/.local/bin"
    ln -sf "$T/priv/bin/claude100" "$T/.local/bin/claude100"

    local out rc=0
    out=$(
        export HOME="$T"
        export PATH="$T/.local/bin:/bin:/usr/bin"
        _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { [[ -e "$mark" ]] && echo "2.0.0" || echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$mark"; return 0; }
        env_update_tool claude user 2>&1
    ) || rc=$?
    [[ "$rc" -eq 0 ]] || { echo "a non-root user-scope update must still succeed: $out" >&2; return 1; }
    assert_contains "updated: 1.0.0 -> 2.0.0" "$out" "normal success line" || return 1

    # CONTROL ARM: the identical layout under root context IS refused — so the
    # pass above is the root gating, not an absent check.
    rm -f "$mark"
    rc=0
    out=$(
        export HOME="$T"
        export PATH="$T/priv/bin:/bin:/usr/bin"
        _env_is_root() { return 0; }
        _env_verify_check_path() { echo "$T/priv/bin:/bin:/usr/bin"; }
        _env_tool_to_binary() { echo "claude100"; }
        env_is_installed() { return 0; }
        env_get_version() { [[ -e "$mark" ]] && echo "2.0.0" || echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_installer_can_update() { return 0; }
        _env_diag_preflight_curl() { return 0; }
        env_check_curl() { return 0; }
        _env_curl_update_with_capture() { : > "$mark"; return 0; }
        env_update_tool claude user 2>&1
    ) || rc=$?
    [[ "$rc" -ne 0 ]] || { echo "control arm: same layout must be refused under root" >&2; return 1; }
    return 0
}

# ----------------------------------------------------------------------------
# 100.14 — the new health check. `cac env check` used to flag a root-home
# binary for a normal user and BLESS it for root: same command, opposite
# verdicts, and the one that mattered was wrong.
# ----------------------------------------------------------------------------
test_14_chk_user_reachable() {
    local T; T=$(_scratch t14)
    local rootlike="$T/rootlike"
    _mkbin "$rootlike/.local/bin/claude100"
    _mkbin "$T/usr/local/bin/gemini100"

    local rc=0
    (
        _env_is_root() { return 0; }
        _env_root_home() { echo "$rootlike"; }
        _env_chk_user_reachable "$rootlike/.local/bin/claude100" claude
    ) || rc=$?
    [[ "$rc" -ne 0 ]] || { echo "root context must fail a root-home binary" >&2; return 1; }

    local reason
    reason=$(
        _env_is_root() { return 0; }
        _env_root_home() { echo "$rootlike"; }
        _env_chk_user_reachable "$rootlike/.local/bin/claude100" claude >/dev/null 2>&1
        echo "$_CHECK_REASON"
    )
    assert_contains "root's private home" "$reason" "_CHECK_REASON is populated" || return 1

    # CONTROL ARM (a): non-root is a no-op — an ordinary user's own copy is fine.
    (
        _env_is_root() { return 1; }
        _env_root_home() { echo "$rootlike"; }
        _env_chk_user_reachable "$rootlike/.local/bin/claude100" claude
    ) || { echo "control arm: non-root must pass unchanged" >&2; return 1; }

    # CONTROL ARM (b): root context with a world-reachable binary passes.
    (
        _env_is_root() { return 0; }
        _env_root_home() { echo "$rootlike"; }
        _env_chk_user_reachable "$T/usr/local/bin/gemini100" gemini
    ) || { echo "control arm: root + reachable binary must pass" >&2; return 1; }

    # An absent binary is _env_chk_binary_location's finding, not this one's.
    (
        _env_is_root() { return 0; }
        _env_chk_user_reachable "" claude
    ) || { echo "empty binary_path must be a no-op" >&2; return 1; }
    return 0
}

# ----------------------------------------------------------------------------
# 100.15 — the repair arm. TWO properties, both load-bearing:
#   * it reaches NO destructive route. Widening _env_chk_binary_location
#     instead of adding this check would have routed a curl tool into
#     _env_repair_remove_bun_opt, which DELETES /opt trees — unrelated to this
#     defect and a re-creation of Issue #85.
#   * it names THIS check's reason. The collection loop resets _CHECK_REASON
#     before every check, so a naive arm prints the LAST check's reason
#     (node_version) — a Node.js message for a root-home defect. Found while
#     implementing; this case is the regression guard.
# ----------------------------------------------------------------------------
test_15_repair_arm_warns_only() {
    local T; T=$(_scratch t15)
    local rootlike="$T/rootlike"
    _mkbin "$rootlike/.local/bin/claude100"
    mkdir -p "$T/usr/local/bin"
    ln -sf "$rootlike/.local/bin/claude100" "$T/usr/local/bin/claude100"

    local out
    out=$(
        export PATH="$T/usr/local/bin:/bin:/usr/bin"
        _ENV_CHECK_NAMES=(user_reachable)      # isolate this arm
        _env_is_root() { return 0; }
        _env_root_home() { echo "$rootlike"; }
        _env_tool_to_binary() { echo "claude100"; }
        # Any of these firing is a design failure, not a test failure.
        _env_repair_remove_bun_opt() { : > "$T/DESTRUCTIVE_opt"; }
        _env_repair_remove_bun_home() { : > "$T/DESTRUCTIVE_home"; }
        _env_repair_create_symlink() { : > "$T/DESTRUCTIVE_symlink"; }
        _env_repair_reinstall() { : > "$T/DESTRUCTIVE_reinstall"; }
        _env_repair_one_tool claude false 2>&1
    ) || true

    assert_contains "root's private home" "$out" "warn names THIS check's reason" || return 1
    assert_contains "Not repaired automatically" "$out" "warn-only wording" || return 1
    local d
    for d in opt home symlink reinstall; do
        [[ -e "$T/DESTRUCTIVE_$d" ]] && {
            echo "user_reachable reached a destructive repair route: $d" >&2
            return 1
        }
    done

    # CONTROL ARM: a reachable layout produces no finding at all, so the warn
    # above is the check firing rather than an unconditional message.
    ln -sf "$T/usr/local/bin/claude100" "$T/usr/local/bin/gemini100" 2>/dev/null || true
    _mkbin "$T/usr/local/bin/claude100x"
    out=$(
        export PATH="$T/usr/local/bin:/bin:/usr/bin"
        _ENV_CHECK_NAMES=(user_reachable)
        _env_is_root() { return 0; }
        _env_root_home() { echo "$rootlike"; }
        _env_tool_to_binary() { echo "claude100x"; }
        _env_repair_one_tool claude false 2>&1
    ) || true
    assert_contains "No issues found" "$out" "control arm: reachable layout is clean" || return 1
    return 0
}

# ----------------------------------------------------------------------------
# 100.16 — _env_chk_binary_location must stay exactly as it was. It is left
# byte-identical ON PURPOSE: its repair route deletes /opt trees, so widening
# it to cover this defect would have been destructive. This case guards against
# a later "tidy-up" merging the two checks.
# ----------------------------------------------------------------------------
test_16_binary_location_unchanged() {
    local T; T=$(_scratch t16)
    export HOME="$T/home"
    _mkbin "$HOME/.local/bin/claude100"
    _mkbin "$T/usr/local/bin/claude100"

    _env_chk_binary_location "$HOME/.local/bin/claude100" claude \
        || { echo "\$HOME/.local/bin must still be accepted" >&2; return 1; }
    _env_chk_binary_location "/usr/local/bin/claude" claude \
        || { echo "/usr/local/bin must still be accepted" >&2; return 1; }

    # It must NOT have grown the root-home rejection — that belongs to
    # user_reachable, whose repair arm is non-destructive.
    (
        _env_is_root() { return 0; }
        _env_root_home() { echo "$HOME"; }
        _env_chk_binary_location "$HOME/.local/bin/claude100" claude
    ) || {
        echo "binary_location grew a reachability rejection — this re-enables the destructive repair route" >&2
        return 1
    }

    # CONTROL ARM: it still rejects what it always rejected.
    if _env_chk_binary_location "/opt/legacy/claude" claude 2>/dev/null; then
        echo "control arm: /opt must still be rejected" >&2
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
# 100.17 — Issue #110: the unknown-old-version branch MUST NOT short-circuit a
# refusal path.
#
# The first implementation of this fix deferred nothing and added a third
# version probe, which made old_version "unknown" in the scenario
# tests/test_issue_71.sh case 71.5 builds — and an "unknown" old version makes
# the downgrade comparison inexpressible, so a REGRESSION printed SUCCESS and
# exited 0. The hardening against reporting success on an unreadable version
# had created a new way to report success on an unreadable version.
#
# The three arms below pin the ORDER of the three outcomes, which is the
# property that was actually violated: refuse-unreadable, then refuse-downgrade,
# then report. Cases 100.9 and 100.10 test the unknown branches in isolation;
# none of them saw the interaction, which is exactly how this got through.
#
# This assertion also lives in test_issue_71.sh 71.5 — deliberately duplicated
# here because THIS suite is registered in run_tests.sh and, at the time of
# writing, that one is not (#101).
# ----------------------------------------------------------------------------
test_17_unknown_old_vs_regression() {
    local T; T=$(_scratch t17)
    local mark="$T/installed"
    _mkbin "$T/.local/bin/claude100"

    # Runs one update with a caller-supplied pre/post version pair.
    _run_update() {
        # Bind to named locals FIRST: inside the stub, $1/$2 would be
        # env_get_version's own arguments (the tool name), not these.
        local pre="$1" post="$2"
        rm -f "$mark"
        (
            export HOME="$T"
            export PATH="$T/.local/bin:/bin:/usr/bin"
            _env_is_root() { return 0; }
            _env_verify_check_path() { echo "$T/.local/bin:/bin:/usr/bin"; }
            _env_tool_to_binary() { echo "claude100"; }
            env_is_installed() { return 0; }
            env_get_version() { [[ -e "$mark" ]] && echo "$post" || echo "$pre"; }
            _env_global_install_exists() { return 1; }
            _env_installer_can_update() { return 0; }
            _env_diag_preflight_curl() { return 0; }
            env_check_curl() { return 0; }
            _env_curl_update_with_capture() { : > "$mark"; return 0; }
            env_update_tool claude user 2>&1
            echo "EXIT=$?"
        )
    }

    # ARM A — the #110 shape: a genuine downgrade must still be refused.
    local out
    out=$(_run_update "2.1.129" "2.1.128")
    assert_contains "EXIT=1" "$out" "a downgrade exits non-zero" || return 1
    assert_contains "regression" "$out" "the downgrade is named" || return 1
    # Match the AFFIRMATIVE marker only. A bare "SUCCESS" substring is present
    # in the refusal itself ("Refusing to report SUCCESS on a downgrade."), so
    # asserting on that would be satisfied by the very message proving the code
    # is correct — the same false-assertion class this whole issue is about.
    if [[ "$out" == *"SUCCESS: "* ]]; then
        echo "printed an affirmative SUCCESS line on a downgrade: $out" >&2
        return 1
    fi

    # ARM B — CONTROL: the unknown-old branch still reports success, so arm A's
    # refusal is the downgrade check and not a blanket refusal.
    out=$(_run_update "unknown" "2.0.0")
    assert_contains "EXIT=0" "$out" "unknown old + readable new is a success" || return 1
    assert_contains "is now at 2.0.0" "$out" "reports the new version" || return 1

    # ARM C — ORDERING: unreadable on BOTH sides must take the refusal path, not
    # the unknown-old success path. This is the short-circuit itself.
    out=$(_run_update "unknown" "unknown")
    assert_contains "EXIT=1" "$out" "unreadable new version exits non-zero" || return 1
    assert_contains "could not be determined" "$out" "names the unreadable version" || return 1
    if [[ "$out" == *"is now at"* ]]; then
        echo "the unknown-old success branch pre-empted the refusal: $out" >&2
        return 1
    fi
    unset -f _run_update
    return 0
}

# ============================================================================
echo "========================================"
echo "Issue #100 Tests (curl post-update verification)"
echo "========================================"
echo ""

run_test "100.1  probe PATH drops root's ~/.local/bin"      test_1_verify_check_path
run_test "100.2  accepts a world-reachable payload"          test_2_accepts_reachable
run_test "100.3  rejects a payload in root's home"           test_3_rejects_root_home
run_test "100.4  rejects a private ancestor directory"       test_4_rejects_private_ancestor
run_test "100.5  rejects a non-world-executable file"        test_5_rejects_private_file
run_test "100.6  permissive on unmeasurable paths"           test_6_permissive_on_unknown
run_test "100.7  rejection survives set -e"                  test_7_set_e_safety
run_test "100.8  E2E false success is refused"               test_8_e2e_unreachable_refused
run_test "100.9  E2E unknown new version is not success"     test_9_e2e_unknown_new_version
run_test "100.10 E2E unknown old version prints no transition" test_10_e2e_unknown_old_version
run_test "100.11 re-read runs after the #94/#95 guard"       test_11_reread_after_guard
run_test "100.12 guard refusal pre-empts verification"       test_12_guard_preempts
run_test "100.13 non-root update unchanged"                  test_13_non_root_unchanged
run_test "100.14 env check no longer blesses root's home"    test_14_chk_user_reachable
run_test "100.15 repair arm warns, never deletes"            test_15_repair_arm_warns_only
run_test "100.16 binary_location left byte-identical"        test_16_binary_location_unchanged
run_test "100.17 unknown-old never short-circuits a refusal" test_17_unknown_old_vs_regression

framework_report
