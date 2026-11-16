#!/usr/bin/env bash
# tests/test_issue_153.sh - Tests for Issue #153
#
# During #148 an agent ran `git stash` while tests/run_tests.sh was running in
# the background, so part of the run tested HEAD instead of the working tree.
# tests/run_tests.sh now holds a lock (<git-dir>/cac-tests.lock, its PID) while
# it runs, and the PreToolUse hook .claude/hooks/block-git-during-tests.sh
# refuses git stash/checkout/switch/reset/restore while a live run holds it.
#
# Seams: tests/run_tests.sh as a process (the lock file while and after it
# runs), and the hook as Claude Code calls it (JSON on stdin -> exit code).
# Both run against a throwaway git repo holding a copy of the runner, so the
# lock of the real run that executes this suite is never touched.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_DIR/.claude/hooks/block-git-during-tests.sh"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

HAS_SHELLCHECK=false
framework_has_command shellcheck && HAS_SHELLCHECK=true

# A throwaway repo with the real runner and a fake "platform" suite whose body
# is $1. The suite sees the lock path as $LOCK. Prints the repo path.
_fake_repo() {
    local body="$1" repo
    repo="$(mktemp -d "$TEST_TMPDIR/repo.XXXXXX")"
    mkdir -p "$repo/tests"
    git -C "$repo" init -q
    cp "$SCRIPT_DIR/run_tests.sh" "$repo/tests/run_tests.sh"
    printf '#!/usr/bin/env bash\nLOCK=%q\n%s\n' "$repo/.git/cac-tests.lock" "$body" \
        > "$repo/tests/test_platform.sh"
    chmod +x "$repo/tests/run_tests.sh" "$repo/tests/test_platform.sh"
    printf '%s\n' "$repo"
}

test_1_lock_holds_runner_pid_while_running() {
    local repo pid
    repo="$(_fake_repo 'cat "$LOCK" > "$LOCK.seen" 2>/dev/null; echo "$PPID" > "$LOCK.runner"')"
    "$repo/tests/run_tests.sh" platform >/dev/null 2>&1
    [[ -f "$repo/.git/cac-tests.lock.seen" ]] || { echo "no lock while the suite ran" >&2; return 1; }
    pid="$(cat "$repo/.git/cac-tests.lock.runner")"
    assert_equals "$pid" "$(tr -d '[:space:]' < "$repo/.git/cac-tests.lock.seen")" "lock PID" || return 1
}

_assert_no_lock() {
    [[ ! -e "$1/.git/cac-tests.lock" ]] || { echo "lock left behind after $2: $(cat "$1/.git/cac-tests.lock")" >&2; return 1; }
}

test_2_lock_removed_after_pass() {
    local repo
    repo="$(_fake_repo 'exit 0')"
    "$repo/tests/run_tests.sh" platform >/dev/null 2>&1 || { echo "runner failed on a passing suite" >&2; return 1; }
    _assert_no_lock "$repo" "a passing run"
}

test_3_lock_removed_after_failure() {
    local repo
    repo="$(_fake_repo 'exit 1')"
    if "$repo/tests/run_tests.sh" platform >/dev/null 2>&1; then
        echo "runner passed on a failing suite" >&2; return 1
    fi
    _assert_no_lock "$repo" "a failing run"
}

# SIGINT goes to the runner's whole process group, as Ctrl-C does. Job control
# (set -m) gives the background runner its own group and keeps SIGINT
# un-ignored, which a plain `&` in a script would not.
test_4_lock_removed_after_sigint() {
    local repo pid i
    repo="$(_fake_repo 'touch "$LOCK.started"; sleep 30')"
    set -m
    "$repo/tests/run_tests.sh" platform >/dev/null 2>&1 &
    pid=$!
    set +m
    for i in $(seq 1 100); do
        [[ -e "$repo/.git/cac-tests.lock.started" ]] && break
        sleep 0.1
    done
    [[ -e "$repo/.git/cac-tests.lock" ]] || { kill -KILL -- "-$pid" 2>/dev/null; echo "no lock while running (after ${i} polls)" >&2; return 1; }
    kill -INT -- "-$pid"
    wait "$pid" 2>/dev/null
    _assert_no_lock "$repo" "SIGINT"
}

# Run the hook as Claude Code does: PreToolUse JSON on stdin, project dir in
# the environment. Prints stderr; returns the hook's exit code.
_hook() {
    local repo="$1" cmd="$2"
    jq -n --arg c "$cmd" --arg d "$repo" \
        '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' \
        | CLAUDE_PROJECT_DIR="$repo" "$HOOK" 2>&1 >/dev/null
}

BLOCKED_CMDS=(
    "git stash"
    "git stash pop"
    "git checkout HEAD -- lib/env.sh"
    "git switch main"
    "git reset --hard HEAD"
    "git restore tests/run_tests.sh"
    "cd /x && git -C /y stash"
    "git -c core.pager=cat checkout ."
    "shellcheck x; git stash && git stash pop"
)
ALLOWED_CMDS=(
    "git status"
    "git diff HEAD"
    "git log --oneline -5"
    "./tests/run_tests.sh 153"
    "grep -n 'stash' lib/env.sh"
)

# Start the real runner (copied) with a suite that sleeps; prints "<repo> <pid>".
_running_repo() {
    local repo pid
    repo="$(_fake_repo 'touch "$LOCK.started"; sleep 30')"
    set -m
    "$repo/tests/run_tests.sh" platform >/dev/null 2>&1 &
    pid=$!
    set +m
    for _ in $(seq 1 100); do
        [[ -e "$repo/.git/cac-tests.lock.started" ]] && break
        sleep 0.1
    done
    printf '%s %s\n' "$repo" "$pid"
}

test_5_hook_blocks_tree_commands_during_live_run() {
    local repo pid cmd out rc bad=0
    read -r repo pid < <(_running_repo)
    for cmd in "${BLOCKED_CMDS[@]}"; do
        rc=0; out="$(_hook "$repo" "$cmd")" || rc=$?
        if [[ $rc -ne 2 ]]; then
            echo "not blocked (exit $rc): $cmd" >&2; bad=1
        elif [[ "$out" != *"$pid"* || "$out" != *run_tests.sh* ]]; then
            echo "reason does not name the run (PID $pid): $out" >&2; bad=1
        elif [[ $(printf '%s\n' "$out" | wc -l) -ne 1 ]]; then
            echo "reason is not one line: $out" >&2; bad=1
        fi
    done
    for cmd in "${ALLOWED_CMDS[@]}"; do
        rc=0; out="$(_hook "$repo" "$cmd")" || rc=$?
        [[ $rc -eq 0 ]] || { echo "wrongly blocked (exit $rc): $cmd: $out" >&2; bad=1; }
    done
    kill -INT -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return "$bad"
}

test_6_hook_allows_tree_commands_without_run() {
    local repo cmd rc bad=0
    repo="$(_fake_repo 'exit 0')"
    for cmd in "${BLOCKED_CMDS[@]}"; do
        rc=0; _hook "$repo" "$cmd" >/dev/null || rc=$?
        [[ $rc -eq 0 ]] || { echo "blocked without a run (exit $rc): $cmd" >&2; bad=1; }
    done
    return "$bad"
}

test_7_hook_ignores_stale_lock() {
    local repo dead rc=0 out
    repo="$(_fake_repo 'exit 0')"
    sh -c 'exit 0' & dead=$!; wait "$dead"
    echo "$dead" > "$repo/.git/cac-tests.lock"
    out="$(_hook "$repo" "git stash")" || rc=$?
    [[ $rc -eq 0 ]] || { echo "stale lock (dead PID $dead) blocked: $out" >&2; return 1; }
}

test_8_settings_register_hook_for_bash() {
    local settings="$REPO_DIR/.claude/settings.json" cmds
    [[ -x "$HOOK" ]] || { echo "hook missing or not executable: $HOOK" >&2; return 1; }
    cmds="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$settings" 2>&1)" \
        || { echo "cannot read PreToolUse hooks from $settings: $cmds" >&2; return 1; }
    [[ "$cmds" == *'"$CLAUDE_PROJECT_DIR"/.claude/hooks/block-git-during-tests.sh'* ]] \
        || { echo "Bash PreToolUse hook not registered, got: $cmds" >&2; return 1; }
}

test_9_hook_is_shellcheck_clean() {
    shellcheck --severity=error "$HOOK"
}

echo "========================================"
echo "Issue #153: git tree commands blocked while tests run"
echo "========================================"

run_test "153.1  the lock holds the runner PID while a suite runs" test_1_lock_holds_runner_pid_while_running
run_test "153.2  the lock is removed after a passing run" test_2_lock_removed_after_pass
run_test "153.3  the lock is removed after a failing run" test_3_lock_removed_after_failure
run_test "153.4  the lock is removed after SIGINT" test_4_lock_removed_after_sigint
run_test "153.5  the hook blocks tree-changing git commands during a live run" test_5_hook_blocks_tree_commands_during_live_run
run_test "153.6  the hook allows them when no run holds the lock" test_6_hook_allows_tree_commands_without_run
run_test "153.7  the hook ignores a stale lock" test_7_hook_ignores_stale_lock
run_test "153.8  .claude/settings.json registers the hook for Bash" test_8_settings_register_hook_for_bash
run_test_if "$HAS_SHELLCHECK" "153.9  the hook is shellcheck clean" test_9_hook_is_shellcheck_clean "shellcheck not installed"

framework_report
