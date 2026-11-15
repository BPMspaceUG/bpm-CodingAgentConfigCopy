#!/usr/bin/env bash
# tests/test_issue_132.sh - Tests for Issue #132
#
# After `cac update` (and install.sh) the operator is pointed at `cac env update`
# and sees whether the installed AI tools are up to date.
#
# Seams:
#   - update_self (lib/update.sh), with the version lookups and the install.sh
#     download stubbed. After a real update the report must come from the newly
#     installed cac binary, not from the code loaded in the running process.
#   - print_usage_summary (install.sh), loaded the way test_issue_77 loads
#     install.sh functions.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=tests/test_framework.sh
source "${SCRIPT_DIR}/test_framework.sh"
# shellcheck source=lib/update.sh
source "${PROJECT_ROOT}/lib/update.sh"

framework_init

# Write a fake installed cac at $1 with version $2. On `env status
# --check-updates` it prints NEW-BINARY-REPORT, touches <itself>.called and exits
# with ${3:-0}.
_mk_cac() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<EOF
#!/usr/bin/env bash
VERSION="$2"
if [[ "\$*" == "env status --check-updates" ]]; then
    : > "\$0.called"
    echo "NEW-BINARY-REPORT"
    exit ${3:-0}
fi
exit 0
EOF
    chmod 755 "$1"
}

# Run update_self in a subshell against a fake user-scope install under
# $TEST_TMPDIR/<name>. Mode "uptodate" (remote == local) or "update" (remote
# newer; the stubbed install.sh replaces the binary with version 260201-0000).
# REPORT_RC sets the new binary's report exit code. Sets OUT, RC, CAC.
run_update_self() {
    local name="$1" mode="$2"
    local home="$TEST_TMPDIR/$name"
    CAC="$home/.local/bin/cac"
    _mk_cac "$CAC" "260101-0000" "${REPORT_RC:-0}"
    local new_cac_src="$home/new-cac"
    _mk_cac "$new_cac_src" "260201-0000" "${REPORT_RC:-0}"
    local remote="260101-0000"
    [[ "$mode" == "update" ]] && remote="260201-0000"
    RC=0
    OUT=$(
        export HOME="$home" PATH="$home/.local/bin:/usr/bin:/bin"
        update_get_remote_version() { echo "$remote"; }
        env_show_status() { echo "IN-PROCESS-REPORT check_updates=$1"; return "${REPORT_RC:-0}"; }
        # The install.sh download: a script that installs the new binary.
        curl() {
            local out=""
            while [[ $# -gt 0 ]]; do
                [[ "$1" == "-o" ]] && { out="$2"; shift; }
                shift
            done
            printf '#!/usr/bin/env bash\ncp "%s" "%s"\nrm -f "%s.called"\n' \
                "$new_cac_src" "$CAC" "$CAC" > "$out"
        }
        update_self 2>&1
    ) || RC=$?
}

# 132.1: up to date: hint lines and the in-process report, exit 0.
test_132_1_up_to_date_shows_report() {
    run_update_self 1321 uptodate
    assert_equals 0 "$RC" "exit code" || { echo "$OUT" >&2; return 1; }
    assert_contains "Already up to date" "$OUT" "up-to-date line" || return 1
    assert_contains "cac env update" "$OUT" "env update hint" || return 1
    assert_contains "IN-PROCESS-REPORT check_updates=true" "$OUT" "report with update checks" || return 1
}

# 132.2 [anti-bug]: after a real update the report comes from the newly
# installed binary, not from the old code loaded in this process.
test_132_2_report_from_new_binary() {
    run_update_self 1322 update
    assert_equals 0 "$RC" "exit code" || { echo "$OUT" >&2; return 1; }
    assert_contains "Update complete: 260101-0000 -> 260201-0000" "$OUT" "update line" || return 1
    [[ -e "$CAC.called" ]] || { echo "new binary was not asked for the report: $OUT" >&2; return 1; }
    assert_contains "NEW-BINARY-REPORT" "$OUT" "report from the new binary" || return 1
    if [[ "$OUT" == *"IN-PROCESS-REPORT"* ]]; then
        echo "report came from the old in-process code: $OUT" >&2
        return 1
    fi
}

# 132.3: a failing report never changes the exit code (update path).
test_132_3_failing_report_after_update() {
    REPORT_RC=3 run_update_self 1323 update
    assert_equals 0 "$RC" "exit code with failing report" || { echo "$OUT" >&2; return 1; }
}

# 132.4: a failing report never changes the exit code (up-to-date path).
test_132_4_failing_report_up_to_date() {
    REPORT_RC=3 run_update_self 1324 uptodate
    assert_equals 0 "$RC" "exit code with failing report" || { echo "$OUT" >&2; return 1; }
}

# 132.5: `cac update --check` prints no tool report.
test_132_5_check_has_no_report() {
    local out
    out=$(
        update_get_local_version() { echo "260101-0000"; }
        update_get_remote_version() { echo "260101-0000"; }
        env_show_status() { echo "IN-PROCESS-REPORT"; }
        update_cmd_main --check 2>&1
    )
    if [[ "$out" == *"REPORT"* || "$out" == *"cac env update"* ]]; then
        echo "--check printed the report: $out" >&2
        return 1
    fi
}

# 132.6: install.sh's closing usage summary names the env commands, no table.
test_132_6_install_usage_summary() {
    local out
    out=$(
        eval "$(sed -n '/^print_usage_summary()/,/^}/p' "$PROJECT_ROOT/install.sh")"
        declare -F print_usage_summary >/dev/null || { echo "print_usage_summary not found"; exit 1; }
        env_show_status() { echo "TABLE"; }
        print_usage_summary
    ) || { echo "$out" >&2; return 1; }
    assert_contains "cac env update" "$out" "env update line" || return 1
    assert_contains "sudo for global installs" "$out" "sudo note" || return 1
    assert_contains "cac env status --check-updates" "$out" "status line" || return 1
    assert_contains "cac push" "$out" "existing lines kept" || return 1
    if [[ "$out" == *"TABLE"* || "$out" == *"Latest"* ]]; then
        echo "install.sh printed a tool table: $out" >&2
        return 1
    fi
}

echo "========================================"
echo "Issue #132: env-update hint and tool report after cac update"
echo "========================================"

run_test "132.1 up to date: hint and in-process report, exit 0" test_132_1_up_to_date_shows_report
run_test "132.2 after update: report from the new binary" test_132_2_report_from_new_binary
run_test "132.3 failing report after update keeps exit 0" test_132_3_failing_report_after_update
run_test "132.4 failing report when up to date keeps exit 0" test_132_4_failing_report_up_to_date
run_test "132.5 --check prints no report" test_132_5_check_has_no_report
run_test "132.6 install.sh usage names env commands, no table" test_132_6_install_usage_summary

framework_report
