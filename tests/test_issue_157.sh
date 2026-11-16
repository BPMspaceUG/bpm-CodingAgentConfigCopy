#!/usr/bin/env bash
# tests/test_issue_157.sh - Tests for Issue #157
#
# _env_package_owner (#148) parses `dpkg -S`, `rpm -qf` and `apk info -W`
# output. Only the dpkg owned/unowned shapes had a stub, and that stub was
# written by hand; rpm and apk were guessed. CODING_STANDARDS.md now requires
# real-shape fixtures for any parser of another program's output.
#
# Every package-manager answer here is a real capture from a container, kept
# verbatim in tests/fixtures/ (origin per file in tests/fixtures/README.md).
# The diversion captures showed the old parser naming "diversion by foo from"
# and "local diversion from" as the owning package.
#
# Seam: _env_package_owner <path>... A stub for exactly one package manager is
# the only one on PATH, so the host's real dpkg/rpm/apk is never asked.
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=lib/env.sh
source "$REPO_DIR/lib/env.sh"

framework_init

HEAD_BIN="$(command -v head)"
CAT_BIN="$(command -v cat)"

# stub_pm <manager> <expected args> <stdout fixture|-> <stderr fixture|-> <rc>
# Builds $TEST_TMPDIR/<manager>-bin/ holding only that manager and `head`.
# The stub replays the fixtures when called with the expected arguments and
# exits 99 otherwise, so a wrong invocation cannot pass as "unowned".
stub_pm() {
    local pm="$1" args="$2" out="$3" err="$4" rc="$5" dir
    dir="$TEST_TMPDIR/$pm-$RANDOM-bin"
    mkdir -p "$dir"
    ln -s "$HEAD_BIN" "$dir/head"
    {
        echo '#!/bin/sh'
        printf '[ "$*" = "%s" ] || exit 99\n' "$args"
        [[ "$out" == "-" ]] || printf '"%s" "%s"\n' "$CAT_BIN" "$FIXTURES/$out"
        [[ "$err" == "-" ]] || printf '"%s" "%s" >&2\n' "$CAT_BIN" "$FIXTURES/$err"
        printf 'exit %s\n' "$rc"
    } > "$dir/$pm"
    chmod 755 "$dir/$pm"
    STUB_PATH="$dir"
}

# owner_of <path>: run the seam with only the stub on PATH. Sets OUT and RC.
owner_of() {
    RC=0
    OUT=$(PATH="$STUB_PATH" _env_package_owner "$1" 2>&1) || RC=$?
}

test_1_dpkg_owned() {
    stub_pm dpkg "-S /usr/bin/ls" dpkg-S-owned.out - 0
    owner_of /usr/bin/ls
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "coreutils (dpkg)" "$OUT" "owner"
}

test_2_dpkg_unowned() {
    stub_pm dpkg "-S /nonexistent/cac157" - dpkg-S-unowned.err 1
    owner_of /nonexistent/cac157
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "" "$OUT" "owner"
}

# A package diversion: the diverting package provides the file at that path,
# the original package's copy lives under the "to:" name.
test_3_dpkg_diverted_names_diverting_package() {
    stub_pm dpkg "-S /usr/bin/ls" dpkg-S-diverted.out - 0
    owner_of /usr/bin/ls
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "foo (dpkg)" "$OUT" "owner"
}

# A local diversion is the admin's own file: no package owns it.
test_4_dpkg_local_diversion_is_unowned() {
    stub_pm dpkg "-S /usr/local/x157" dpkg-S-local-diversion.out - 0
    owner_of /usr/local/x157
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "" "$OUT" "owner"
}

test_5_rpm_owned() {
    stub_pm rpm "-qf /usr/bin/ls" rpm-qf-owned.out - 0
    owner_of /usr/bin/ls
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "coreutils-9.11-6.fc45.x86_64 (rpm)" "$OUT" "owner"
}

test_6_rpm_not_owned() {
    stub_pm rpm "-qf /usr/local/bin/x157" rpm-qf-not-owned.out - 1
    owner_of /usr/local/bin/x157
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "" "$OUT" "owner"
}

test_7_rpm_missing_file() {
    stub_pm rpm "-qf /nonexistent/cac157" - rpm-qf-missing.err 1
    owner_of /nonexistent/cac157
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "" "$OUT" "owner"
}

test_8_apk_owned() {
    stub_pm apk "info -W /bin/busybox" apk-info-W-owned.out - 0
    owner_of /bin/busybox
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "busybox-1.37.0-r31 (apk)" "$OUT" "owner"
}

test_9_apk_symlink_target_owned() {
    stub_pm apk "info -W /bin/ls" apk-info-W-symlink.out - 0
    owner_of /bin/ls
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "busybox-1.37.0-r31 (apk)" "$OUT" "owner"
}

test_10_apk_unowned() {
    stub_pm apk "info -W /usr/local/bin/x157" - apk-info-W-unowned.err 1
    owner_of /usr/local/bin/x157
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "" "$OUT" "owner"
}

# A local diversion of a packaged file: dpkg still prints the original
# package's owner line after the diversion lines. The admin's file now sits at
# that path, so the package line does not count: nothing is named.
test_11_dpkg_local_diversion_of_packaged_file_is_unowned() {
    stub_pm dpkg "-S /usr/bin/cat" dpkg-S-local-diversion-packaged.out - 0
    owner_of /usr/bin/cat
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "" "$OUT" "owner"
}

# The diverted-to path holds the original package's copy, but dpkg prints only
# the diversion lines and no owner line for it: nothing is named.
test_12_dpkg_diverted_to_path_is_unowned() {
    stub_pm dpkg "-S /usr/bin/ls.distrib" dpkg-S-diverted-to.out - 0
    owner_of /usr/bin/ls.distrib
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "" "$OUT" "owner"
}

# A path several packages share: the whole comma-separated list is named.
test_13_dpkg_multi_package_names_all() {
    stub_pm dpkg "-S /etc/default" dpkg-S-multi-package.out - 0
    owner_of /etc/default
    assert_equals 0 "$RC" "rc" || return 1
    assert_equals "passwd, base-files, libc-bin (dpkg)" "$OUT" "owner"
}

echo "========================================"
echo "Issue #157 Tests"
echo "========================================"

run_test "157.1 dpkg -S: owned path names the package" test_1_dpkg_owned
run_test "157.2 dpkg -S: unowned path names nothing" test_2_dpkg_unowned
run_test "157.3 dpkg -S: package diversion names the diverting package" test_3_dpkg_diverted_names_diverting_package
run_test "157.4 dpkg -S: local diversion names nothing" test_4_dpkg_local_diversion_is_unowned
run_test "157.5 rpm -qf: owned path names the package" test_5_rpm_owned
run_test "157.6 rpm -qf: 'not owned' names nothing" test_6_rpm_not_owned
run_test "157.7 rpm -qf: missing file names nothing" test_7_rpm_missing_file
run_test "157.8 apk info -W: owned path names the package" test_8_apk_owned
run_test "157.9 apk info -W: symlink target owner is named" test_9_apk_symlink_target_owned
run_test "157.10 apk info -W: unowned path names nothing" test_10_apk_unowned
run_test "157.11 dpkg -S: local diversion of a packaged file names nothing" test_11_dpkg_local_diversion_of_packaged_file_is_unowned
run_test "157.12 dpkg -S: diverted-to path names nothing" test_12_dpkg_diverted_to_path_is_unowned
run_test "157.13 dpkg -S: shared path names every package" test_13_dpkg_multi_package_names_all

framework_report
