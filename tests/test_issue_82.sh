#!/usr/bin/env bash
# tests/test_issue_82.sh - Tests for Issue #82
#
# 1. `cac check codex` must use the lightweight `codex login status` probe
#    (instant, no tokens) instead of a full `codex exec` LLM generation that
#    times out and is misreported as TIMEOUT.
# 2. Credential checks must be default-OFF on all pull operations — `cac pull`
#    must never invoke a credential check.
#
# Codex-gated conditions baked in:
#  - assert EXACT exit codes (CHECK_EXIT_* constants)
#  - 82.1 asserts EXACT argv tokens/order (`login status`, NOT `exec`)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"
# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"
# shellcheck source=lib/tools.sh
source "$REPO_DIR/lib/tools.sh"
# shellcheck source=lib/check.sh
source "$REPO_DIR/lib/check.sh"

framework_init

# ============================================================================
# Helpers
# ============================================================================

# Create a mock `codex` binary that records its argv to <sentinel>.
# mode: ok    -> prints "Logged in ...", exit 0
#       fail  -> prints "Not logged in", exit 1
make_codex_stub() {
    local bindir="$1" mode="$2" sentinel="$3"
    mkdir -p "$bindir"
    {
        echo '#!/usr/bin/env bash'
        printf 'printf "%%s\\n" "$@" >> %q\n' "$sentinel"
        echo 'if [[ "$1" == "--version" ]]; then echo "codex 1.0.0"; exit 0; fi'
        case "$mode" in
            ok)   echo 'echo "Logged in using ChatGPT"; exit 0' ;;
            fail) echo 'echo "Not logged in"; exit 1' ;;
        esac
    } > "$bindir/codex"
    chmod +x "$bindir/codex"
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
    ( cd "$stage" && zip -q "$storage/$name" "$@" )
    rm -rf "$stage"
}

# ============================================================================
# Unit tests: check_tool_codex uses `codex login status`
# ============================================================================

# 82.1 [anti-bug]: logged-in probe -> SUCCESS, argv EXACTLY "login status", no exec
test_82_1_probe_success_exact_argv() {
    local d="$TEST_TMPDIR/821"; mkdir -p "$d/bin"
    local sentinel="$d/codex.args"; : > "$sentinel"
    make_codex_stub "$d/bin" ok "$sentinel"

    local rc=0
    PATH="$d/bin:$PATH" check_tool_codex "false" "$(whoami)" >/dev/null 2>&1 || rc=$?

    assert_equals "$CHECK_EXIT_SUCCESS" "$rc" "codex probe exit code" || return 1

    # EXACT argv tokens/order — kills a false positive like `codex exec login status`
    local argv; argv=$(cat "$sentinel")
    assert_equals $'login\nstatus' "$argv" "codex argv (exact)" || return 1
    if grep -qx "exec" "$sentinel"; then
        echo "FAIL: codex was invoked with 'exec' (generation), expected probe only" >&2
        return 1
    fi
    return 0
}

# 82.2: not-logged-in -> AUTH_FAIL (exact)
test_82_2_probe_auth_fail() {
    local d="$TEST_TMPDIR/822"; mkdir -p "$d/bin"
    local sentinel="$d/codex.args"; : > "$sentinel"
    make_codex_stub "$d/bin" fail "$sentinel"

    local rc=0
    PATH="$d/bin:$PATH" check_tool_codex "false" "$(whoami)" >/dev/null 2>&1 || rc=$?
    assert_equals "$CHECK_EXIT_AUTH_FAIL" "$rc" "codex auth-fail exit code"
}

# 82.3 [sentinel]: missing codex binary -> MISSING_DEP (exact, unchanged)
test_82_3_missing_binary() {
    local d="$TEST_TMPDIR/823"; mkdir -p "$d/empty"
    local rc=0
    # PATH with no codex at all
    PATH="$d/empty" check_tool_codex "false" "$(whoami)" >/dev/null 2>&1 || rc=$?
    assert_equals "$CHECK_EXIT_MISSING_DEP" "$rc" "codex missing-dep exit code"
}

# ============================================================================
# Integration: pull runs NO credential check (default-off)
# ============================================================================

# 82.4 [anti-bug]: `cac pull --tool codex` extracts, and the codex stub is never
# invoked (no credential check in the pull path).
test_82_4_pull_runs_no_check() {
    local d="$TEST_TMPDIR/824"
    mkdir -p "$d"/{storage,config,home,tmp,cache,bin}

    cat > "$d/config/.env" <<EOF
CAC_BACKEND=local
CAC_LOCAL_STORAGE=$d/storage
EOF
    chmod 600 "$d/config/.env"

    # getent mock so cac resolves home to the sandbox (NOT the real home)
    local user; user=$(whoami)
    cat > "$d/bin/getent" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "passwd" && "\$2" == "$user" ]]; then
    echo "$user:x:$(id -u):$(id -g):$user:$d/home:/bin/bash"; exit 0
fi
$(command -v getent) "\$@"
EOF
    chmod +x "$d/bin/getent"

    # codex stub that writes a sentinel if it is EVER called (it must not be)
    local sentinel="$d/codex.called"
    make_codex_stub "$d/bin" fail "$sentinel"
    rm -f "$sentinel"

    seed_bundle "$d/storage" "CodingAgentConfig_HOSTA_${user}_codex_260101-100000.zip" ".codex/auth.json"

    local rc=0
    PATH="$d/bin:$PATH" CAC_CONFIG_DIR="$d/config" HOME="$d/home" TMPDIR="$d/tmp" XDG_CACHE_HOME="$d/cache" \
        "$REPO_DIR/bin/cac" pull --tool codex >/dev/null 2>&1 || rc=$?

    assert_equals "0" "$rc" "pull exit code" || return 1
    assert_file_exists "$d/home/.codex/auth.json" "extracted codex auth" || return 1
    if [[ -f "$sentinel" ]]; then
        echo "FAIL: codex credential check ran during pull (sentinel present)" >&2
        return 1
    fi
    return 0
}

# ============================================================================
# Integration: push runs NO credential check by default; --check opts in
# ============================================================================

# Build a push sandbox: local backend .env, getent mock -> sandbox home, and a
# codex stub whose sentinel is written only if the credential check runs.
# Echoes the sandbox dir. codex_mode: ok|fail.
_setup_push_sandbox() {
    local d="$1" codex_mode="$2" sentinel="$3"
    mkdir -p "$d"/{storage,config,home/.codex,tmp,cache,bin}
    cat > "$d/config/.env" <<EOF
CAC_BACKEND=local
CAC_LOCAL_STORAGE=$d/storage
EOF
    chmod 600 "$d/config/.env"
    local user; user=$(whoami)
    cat > "$d/bin/getent" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "passwd" && "\$2" == "$user" ]]; then
    echo "$user:x:$(id -u):$(id -g):$user:$d/home:/bin/bash"; exit 0
fi
$(command -v getent) "\$@"
EOF
    chmod +x "$d/bin/getent"
    make_codex_stub "$d/bin" "$codex_mode" "$sentinel"
    rm -f "$sentinel"
    # codex config file so there is something to bundle
    echo '{"marker":"auth"}' > "$d/home/.codex/auth.json"
}

# 82.5 [anti-bug]: default `cac push --tool codex` (no --check) must NOT run any
# credential check (sentinel absent) and must still create the bundle.
test_82_5_push_default_no_check() {
    local d="$TEST_TMPDIR/825"; local sentinel="$d/codex.called"
    _setup_push_sandbox "$d" ok "$sentinel"
    local user; user=$(whoami)

    local rc=0
    PATH="$d/bin:$PATH" CAC_CONFIG_DIR="$d/config" HOME="$d/home" TMPDIR="$d/tmp" XDG_CACHE_HOME="$d/cache" \
        "$REPO_DIR/bin/cac" push --tool codex >/dev/null 2>&1 || rc=$?

    assert_equals "0" "$rc" "push exit code (default, no check)" || return 1
    # a codex bundle was uploaded to storage
    if ! compgen -G "$d/storage/CodingAgentConfig_"*"_${user}_codex_"*.zip >/dev/null; then
        echo "FAIL: no codex bundle created by default push" >&2; return 1
    fi
    # the credential check must NOT have run
    if [[ -f "$sentinel" ]]; then
        echo "FAIL: credential check ran on default push (sentinel present)" >&2; return 1
    fi
    return 0
}

# 82.6 [anti-bug]: `cac push --tool codex --check` MUST run the codex probe
# (sentinel present, argv = login status) and succeed.
test_82_6_push_check_opts_in() {
    local d="$TEST_TMPDIR/826"; local sentinel="$d/codex.called"
    _setup_push_sandbox "$d" ok "$sentinel"

    local rc=0
    PATH="$d/bin:$PATH" CAC_CONFIG_DIR="$d/config" HOME="$d/home" TMPDIR="$d/tmp" XDG_CACHE_HOME="$d/cache" \
        "$REPO_DIR/bin/cac" push --tool codex --check >/dev/null 2>&1 || rc=$?

    assert_equals "0" "$rc" "push --check exit code" || return 1
    if [[ ! -f "$sentinel" ]]; then
        echo "FAIL: --check did not run the credential check (sentinel absent)" >&2; return 1
    fi
    # and it used the lightweight 'login status' probe, not exec
    if ! grep -qx "login" "$sentinel" || ! grep -qx "status" "$sentinel" || grep -qx "exec" "$sentinel"; then
        echo "FAIL: --check did not use 'login status' probe" >&2; return 1
    fi
    return 0
}

# ============================================================================
# Run
# ============================================================================

echo "=========================================="
echo "Issue #82: fast codex probe + checks default-off (pull & push)"
echo "=========================================="

run_test "82.1 codex probe success + exact argv (login status, not exec)" test_82_1_probe_success_exact_argv
run_test "82.2 codex probe not-logged-in -> AUTH_FAIL" test_82_2_probe_auth_fail
run_test "82.3 codex missing binary -> MISSING_DEP" test_82_3_missing_binary
run_test "82.4 pull runs no credential check (default-off)" test_82_4_pull_runs_no_check
run_test "82.5 push runs no credential check by default" test_82_5_push_default_no_check
run_test "82.6 push --check opts in to the codex probe" test_82_6_push_check_opts_in

framework_report
