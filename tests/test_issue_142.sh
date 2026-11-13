#!/usr/bin/env bash
# tests/test_issue_142.sh - Tests for Issue #142
#
# `cac check` over ssh without a TTY (cron, containers, agents) printed
# "/dev/tty: No such device or address" repeatedly. The spinner guarded with
# [[ -c /dev/tty ]], which is true whenever the device node exists, even in a
# process with no controlling terminal; only opening it fails. Every caller
# captures `_check_with_timeout ... 2>&1`, so those errors also landed in the
# output the credential check then parses.
#
# Seam: _check_with_timeout, run in a child process. setsid detaches it from
# any controlling terminal (the non-TTY case); script(1) gives it a pseudo-TTY
# (the interactive case).
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

# A child script that sources lib/check.sh and prints exactly what a caller of
# _check_with_timeout would capture, plus the exit code.
CHILD="$TEST_TMPDIR/child_check.sh"
cat > "$CHILD" <<EOF
#!/usr/bin/env bash
source "$REPO_DIR/lib/logging.sh"
source "$REPO_DIR/lib/check.sh"
out=\$(_check_with_timeout 5 bash -c 'sleep 0.5; echo credential-ok' 2>&1)
rc=\$?
printf 'OUT=[%s] RC=%s\n' "\$out" "\$rc"
EOF
chmod 700 "$CHILD"

# 142.1 [anti-bug]: without a controlling terminal, the captured output is the
#       command's output only: no /dev/tty errors, correct exit code.
test_142_1_no_tty_output_clean() {
    local result
    result=$(setsid bash "$CHILD" </dev/null 2>&1)

    if [[ "$result" == *"/dev/tty"* ]]; then
        echo "tty error leaked: $result" >&2
        return 1
    fi
    assert_contains "OUT=[credential-ok] RC=0" "$result" "captured output and exit code" || return 1
}

# 142.2: with a terminal, the spinner still draws on it and the captured
#        output stays clean.
test_142_2_tty_spinner_unchanged() {
    local log="$TEST_TMPDIR/tty.log"
    script -qec "bash '$CHILD'" "$log" </dev/null >/dev/null 2>&1

    local seen; seen=$(cat "$log")
    assert_contains "OUT=[credential-ok] RC=0" "$seen" "captured output and exit code" || return 1
    [[ "$seen" == *'|'$'\b'* ]] || { echo "no spinner frame on the TTY: $seen" >&2; return 1; }
}

echo "========================================"
echo "Issue #142: cac check without a TTY"
echo "========================================"

if framework_has_command setsid; then
    run_test "142.1 no TTY: no /dev/tty errors, output and exit code intact" test_142_1_no_tty_output_clean
else
    skip "142.1 no TTY: no /dev/tty errors" "setsid not installed"
fi
if framework_has_command script; then
    run_test "142.2 with a TTY: spinner still drawn, output intact" test_142_2_tty_spinner_unchanged
else
    skip "142.2 with a TTY: spinner still drawn" "script(1) not installed"
fi

framework_report
