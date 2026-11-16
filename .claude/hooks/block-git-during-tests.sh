#!/usr/bin/env bash
# .claude/hooks/block-git-during-tests.sh - PreToolUse hook for Bash (#153)
#
# Refuses git stash/checkout/switch/reset/restore while tests/run_tests.sh is
# running. Those commands change the working tree under the running suites, so
# part of the run would test a different tree (it happened during #148).
#
# tests/run_tests.sh writes its PID to <git-dir>/cac-tests.lock and removes it
# on exit. A lock whose PID is dead is stale and blocks nothing.
#
# Input: the PreToolUse JSON on stdin. Exit 2 with a one-line reason on stderr
# blocks the call; exit 0 allows it. Tested by tests/test_issue_153.sh.

set -uo pipefail

input="$(cat)"
dir="${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)}"
[[ -n "$dir" ]] || exit 0

git_dir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
lock="${git_dir}/cac-tests.lock"
[[ -f "$lock" ]] || exit 0
pid="$(tr -d '[:space:]' < "$lock" 2>/dev/null)"
[[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || exit 0

cmd="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)" || cmd="$input"
cmd="${cmd//$'\n'/;}"

# `git`, optional global options (-C dir, -c key=val, --flag), then the subcommand.
re='(^|[;&|(`[:space:]])git([[:space:]]+(-C|-c)[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*[[:space:]]+(stash|checkout|switch|reset|restore)([[:space:];&|)`]|$)'
if [[ "$cmd" =~ $re ]]; then
    echo "Blocked: tests/run_tests.sh is running (PID ${pid}, lock ${lock}); git ${BASH_REMATCH[4]} would change the tree it tests. Wait for the run to finish." >&2
    exit 2
fi
exit 0
