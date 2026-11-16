#!/usr/bin/env bash
# tests/test_issue_119.sh - Tests for Issue #119
#
# `cac env install claude --tmux` on a host without tmux died with exit 127:
# the missing-tmux branch of _env_configure_claude_settings called log_warn,
# a function that never existed. The branch meant to degrade gracefully
# aborted the install before the agent-teams setting was written.
#
# Seam 1: _env_configure_claude_settings <tmux_flag>, run in a fresh bash under
# `set -euo pipefail` as bin/cac runs it (set -e is ignored inside a `||`
# context in this process, so the crash would not show here). HOME is a
# tmpdir; PATH is a copy of the real PATH with tmux removed, or replaced by a
# stub for the control arm, so the host's own tmux never decides the result.
#
# Seam 2: every *_warn/_error/_info/_success/_verbose name called in lib/*.sh
# and bin/cac is defined once the libraries are sourced. shellcheck cannot see
# this class: the definitions live in other sourced files.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

# make_path <with_tmux:true|false>: a bin dir linking every command on the
# real PATH except tmux; with_tmux=true adds a stub tmux. Sets STUB_PATH.
make_path() {
    local with_tmux="$1" dir d f name
    dir="$TEST_TMPDIR/bin-$RANDOM"
    mkdir -p "$dir"
    local IFS=:
    for d in $PATH; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*; do
            name="${f##*/}"
            [[ "$name" == "tmux" || -e "$dir/$name" || ! -x "$f" ]] && continue
            ln -s "$f" "$dir/$name"
        done
    done
    if [[ "$with_tmux" == "true" ]]; then
        printf '#!/bin/sh\nexit 0\n' > "$dir/tmux"
        chmod 755 "$dir/tmux"
    fi
    STUB_PATH="$dir"
}

# configure <tmux_flag>: run the seam in a fresh strict-mode bash on STUB_PATH
# Sets OUT, RC, SETTINGS (the settings.json path).
configure() {
    local home="$TEST_TMPDIR/home-$RANDOM"
    mkdir -p "$home"
    SETTINGS="$home/.claude/settings.json"
    RC=0
    OUT=$(HOME="$home" PATH="$STUB_PATH" bash -c '
        set -euo pipefail
        source "$1/lib/env.sh"
        _env_configure_claude_settings "$2"
    ' _ "$REPO_DIR" "$1" 2>&1) || RC=$?
}

# refute_contains <needle> <haystack> <description>
refute_contains() {
    [[ "$2" != *"$1"* ]] && return 0
    _assertion_failed "Expected $3 not to contain '$1', got: '$2'"
}

test_1_missing_tmux_does_not_abort() {
    make_path false
    configure true
    assert_equals 0 "$RC" "exit code (output: $OUT)"
}

# The second warning line never ran before the fix; fixing only the first
# line still crashes on it, so this asserts the hint line specifically.
test_2_missing_tmux_prints_both_warnings() {
    make_path false
    configure true
    assert_contains "WARNING: tmux is not installed" "$OUT" "first warning" || return 1
    # Every platform_install_hint variant names "install tmux" / "Install tmux".
    assert_match "WARNING: Install with: [^$'\n']*[Ii]nstall tmux" "$OUT" "install-hint warning"
}

test_3_missing_tmux_still_writes_agent_teams_without_teammate_mode() {
    make_path false
    configure true
    assert_file_exists "$SETTINGS" "settings.json" || return 1
    local content
    content=$(cat "$SETTINGS")
    assert_contains '"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS":"1"' "$content" "agent teams" || return 1
    refute_contains "teammateMode" "$content" "settings.json"
}

test_4_tmux_present_writes_teammate_mode() {
    make_path true
    configure true
    assert_equals 0 "$RC" "exit code (output: $OUT)" || return 1
    refute_contains "WARNING" "$OUT" "output" || return 1
    assert_contains '"teammateMode":"tmux"' "$(cat "$SETTINGS")" "settings.json"
}

test_5_every_called_log_function_is_defined() {
    local defined called missing
    defined=$(bash -c 'set -u; for f in "$1"/lib/*.sh; do source "$f"; done; declare -F' _ "$REPO_DIR" 2>/dev/null \
        | awk '{print $3}' | sort -u)
    called=$(grep -ohE '[a-z][a-z0-9_]*_(warn|error|info|success|verbose)\b' "$REPO_DIR"/lib/*.sh "$REPO_DIR/bin/cac" \
        | sort -u)
    # A name used only as a word (in a string or a variable) is not a call;
    # keep only names that appear in command position somewhere.
    missing=""
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        grep -qx "$name" <<< "$defined" && continue
        if grep -qE "(^|[;&|({\`]|\\\$\\(|then|do|else)[[:space:]]*${name}([[:space:]]|$)" "$REPO_DIR"/lib/*.sh "$REPO_DIR/bin/cac"; then
            missing+="$name "
        fi
    done <<< "$called"
    assert_equals "" "$missing" "called but undefined"
}

echo "========================================"
echo "Issue #119 Tests"
echo "========================================"

run_test "119.1 --tmux without tmux: settings step exits 0 under set -e" test_1_missing_tmux_does_not_abort
run_test "119.2 --tmux without tmux: both warnings, including the install hint" test_2_missing_tmux_prints_both_warnings
run_test "119.3 --tmux without tmux: agent teams written, teammateMode not" test_3_missing_tmux_still_writes_agent_teams_without_teammate_mode
run_test "119.4 --tmux with tmux: teammateMode tmux written" test_4_tmux_present_writes_teammate_mode
run_test "119.5 every called *_warn/_error/_info/_success/_verbose is defined" test_5_every_called_log_function_is_defined

framework_report
