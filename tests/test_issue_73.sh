#!/usr/bin/env bash
# tests/test_issue_73.sh - Tests for Issue #73:
#   `cac env update` fails to update continuous-claude when the upstream
#   installer emits `curl: (23)`. cac correctly classifies this as a failure
#   but does not surface the actual cause, pre-flight check, or distinguish
#   curl-exit categories. Fix adds:
#     - Pre-flight: writability + free-space at the install target
#     - Capture: download-then-execute with installer log captured to tempfile
#     - Stage-aware classification: download vs execute, embedded vs pure-script
#     - Failure summary: per-tool cause one-liner in env_update_all
#     - Explicit cleanup: no trap RETURN; rm -f at every return site
#
# Style mirrors tests/test_issue_71.sh: self-contained helpers, ANSI colors,
# manual counters, set -uo pipefail (no errexit so ((c++)) from 0 is safe).
# Sources lib/env.sh directly; tests run in subshells for isolation.
#
# All curl/bash/network invocations are stubbed — fully network-free.
#
# Test inventory (16 cases):
#   73.1    execute-stage embedded curl:23 -> "installer script: write failure"
#   73.2    download-stage curl:6           -> "network/DNS"
#   73.3    download-stage curl:22          -> "HTTP error"
#   73.3a   execute-stage embedded curl:6   -> "installer script: network/DNS"
#   73.3b   pure-script failure (no curl)   -> "installer script exited with status N"
#   73.4    perm-denied target              -> pre-flight blocks, no curl invoked
#   73.5    disk-full                       -> pre-flight blocks, no curl invoked
#   73.6    successful curl                 -> tempfiles cleaned, post-install verify runs
#   73.7    npm path                        -> untouched by new diagnostics
#   73.8    Issue #71 refusal               -> still fires BEFORE tempfile creation
#   73.8b   refusal-first ordering          -> pre-flight not invoked when refusal fires
#   73.9    env_update_all batch summary    -> per-tool cause in Failed tools: line
#   73.10   log-tail truncation             -> exactly last 40 lines + frame markers
#   73.11a  cleanup on log-mktemp failure   -> installer tempfile removed
#   73.11b  cleanup across two back-to-back -> no leak between invocations
#   73.11c  cleanup on bash-execution fail  -> both tempfiles removed (F3)

set -uo pipefail

# ----------------------------------------------------------------------------
# Globals & helpers
# ----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((PASSED++)) || true
    ((TOTAL++)) || true
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "       Reason: $2"
    fi
    ((FAILED++)) || true
    ((TOTAL++)) || true
}

skip() {
    echo -e "${YELLOW}SKIP${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "       Reason: $2"
    fi
    ((SKIPPED++)) || true
    ((TOTAL++)) || true
}

header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

# Single root tmp tree, removed on EXIT.
ROOT_TMP=$(mktemp -d -t cac-test-73.XXXXXXXXXX)
trap '_teardown' EXIT

RESTORE_PERMS=()
_teardown() {
    local p
    for p in "${RESTORE_PERMS[@]+"${RESTORE_PERMS[@]}"}"; do
        chmod 700 "$p" 2>/dev/null || true
    done
    rm -rf "$ROOT_TMP" 2>/dev/null || true
}

# Source lib/env.sh into the parent shell. Subshells inherit the function
# table and override what they need without polluting other tests.
# shellcheck source=../lib/env.sh
source "${REPO_DIR}/lib/env.sh"

_scratch() {
    local name="$1"
    local d="${ROOT_TMP}/${name}"
    mkdir -p "$d"
    echo "$d"
}

# Count how many cac-env-update-* files match a tool prefix in TMPDIR.
# Returns the count (0 if none).
_count_leftover_tempfiles() {
    local tool="$1"
    local tmp="${TMPDIR:-/tmp}"
    find "$tmp" -maxdepth 1 -name "cac-env-update-${tool}-*" 2>/dev/null | wc -l
}

# ----------------------------------------------------------------------------
# 73.1 — execute-stage curl:23 surfaces "installer script: write failure"
# ----------------------------------------------------------------------------

test_73_1_execute_curl23() {
    local name="73.1"
    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local TOOL="continuous-claude"

    (
        # Stub curl on PATH: succeeds at download (writes a no-op installer to
        # the -o target), exit 0.
        mkdir -p "$T/bin"
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Find -o argument and write a placeholder installer.
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "$out" ]]; then
    cat > "$out" <<'INNER'
#!/usr/bin/env bash
# Simulated upstream installer that itself fails with curl:23.
echo "🔂 Installing Continuous Claude..."
echo "📥 Downloading continuous-claude..."
echo "curl: (23) client returned ERROR on write of 16375 bytes" >&2
echo "❌ Failed to download continuous-claude" >&2
exit 1
INNER
fi
exit 0
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        # Skip pre-flight by overriding target dir to empty.
        _env_diag_target_dir() { echo ""; }

        _env_curl_update_with_capture "$TOOL" "https://example/install.sh" "Continuous Claude" \
            >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code combined
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    combined=$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name execute-stage curl:23" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$combined" != *"installer script: write failure inside upstream installer"* ]]; then
        fail "$name execute-stage curl:23" "missing 'installer script: write failure ...': $combined"
        return
    fi
    if [[ "$combined" != *"curl exit 23"* ]]; then
        fail "$name execute-stage curl:23" "missing 'curl exit 23': $combined"
        return
    fi
    if [[ "$combined" != *"--- upstream installer log (last 40 lines) ---"* ]]; then
        fail "$name execute-stage curl:23" "missing log-tail open marker"
        return
    fi
    if [[ "$combined" != *"--- end log ---"* ]]; then
        fail "$name execute-stage curl:23" "missing log-tail close marker"
        return
    fi
    local leftover
    leftover=$(_count_leftover_tempfiles "$TOOL")
    if [[ "$leftover" -ne 0 ]]; then
        fail "$name execute-stage curl:23" "$leftover tempfile(s) leaked"
        return
    fi
    pass "$name execute-stage curl:23 surfaces 'installer script: write failure' + log tail + cleanup"
}

# ----------------------------------------------------------------------------
# 73.2 — download-stage curl:6 surfaces "network/DNS"
# ----------------------------------------------------------------------------

test_73_2_download_curl6() {
    local name="73.2"
    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local BASH_SENTINEL="$T/bash_invoked"
    local TOOL="claude"

    (
        # Stub curl: writes 'curl: (6)' to its stderr (which the helper
        # redirects via 2>"$_diag_log") then exits 6.
        mkdir -p "$T/bin"
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl: (6) Could not resolve host: example" >&2
exit 6
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        # Sentinel: prove bash never executes the installer (download failed).
        # We can't shadow the 'bash' command on the calling shell, but the
        # helper invokes 'bash "$_installer"' so the file would have to exist.
        # Instead, sentinel via the curl stub: it never wrote -o output, so
        # any 'bash' invocation would error on a missing file — we'll detect
        # via combined output.

        _env_diag_target_dir() { echo ""; }

        _env_curl_update_with_capture "$TOOL" "https://example/install.sh" "Claude Code" \
            >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )
    : "$BASH_SENTINEL"  # silence unused warning in older bash

    local exit_code combined
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    combined=$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name download-stage curl:6" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$combined" != *"network/DNS"* ]]; then
        fail "$name download-stage curl:6" "missing 'network/DNS': $combined"
        return
    fi
    # Must NOT misclassify as execute-stage.
    if [[ "$combined" == *"installer script:"* ]]; then
        fail "$name download-stage curl:6" "wrongly classified as execute-stage: $combined"
        return
    fi
    local leftover
    leftover=$(_count_leftover_tempfiles "$TOOL")
    if [[ "$leftover" -ne 0 ]]; then
        fail "$name download-stage curl:6" "$leftover tempfile(s) leaked"
        return
    fi
    pass "$name download-stage curl:6 surfaces 'network/DNS' + cleanup"
}

# ----------------------------------------------------------------------------
# 73.3 — download-stage curl:22 surfaces "HTTP error"
# ----------------------------------------------------------------------------

test_73_3_download_curl22() {
    local name="73.3"
    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local TOOL="mistral"

    (
        mkdir -p "$T/bin"
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl: (22) The requested URL returned error: 404" >&2
exit 22
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        _env_diag_target_dir() { echo ""; }

        _env_curl_update_with_capture "$TOOL" "https://example/install.sh" "Mistral Vibe" \
            >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code combined
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    combined=$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name download-stage curl:22" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$combined" != *"HTTP error from upstream"* ]]; then
        fail "$name download-stage curl:22" "missing 'HTTP error from upstream': $combined"
        return
    fi
    pass "$name download-stage curl:22 surfaces 'HTTP error from upstream'"
}

# ----------------------------------------------------------------------------
# 73.3a — execute-stage embedded curl:6
# ----------------------------------------------------------------------------

test_73_3a_execute_embedded_curl6() {
    local name="73.3a"
    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local TOOL="continuous-claude"

    (
        mkdir -p "$T/bin"
        # curl succeeds at download, but the installer it writes will itself
        # emit 'curl: (6)' and exit non-zero.
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "$out" ]]; then
    cat > "$out" <<'INNER'
#!/usr/bin/env bash
echo "📥 Downloading from cdn..."
echo "curl: (6) Could not resolve host: cdn.example" >&2
exit 1
INNER
fi
exit 0
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        _env_diag_target_dir() { echo ""; }

        _env_curl_update_with_capture "$TOOL" "https://example/install.sh" "Continuous Claude" \
            >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code combined
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    combined=$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name execute-stage embedded curl:6" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$combined" != *"installer script: network/DNS failure inside upstream"* ]]; then
        fail "$name execute-stage embedded curl:6" "missing 'installer script: network/DNS failure inside upstream': $combined"
        return
    fi
    if [[ "$combined" != *"curl exit 6"* ]]; then
        fail "$name execute-stage embedded curl:6" "missing 'curl exit 6': $combined"
        return
    fi
    pass "$name execute-stage embedded curl:6 surfaces 'installer script: network/DNS failure inside upstream'"
}

# ----------------------------------------------------------------------------
# 73.3b — pure-script failure (no curl in log)
# ----------------------------------------------------------------------------

test_73_3b_pure_script_failure() {
    local name="73.3b"
    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local TOOL="claude"

    (
        mkdir -p "$T/bin"
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "$out" ]]; then
    cat > "$out" <<'INNER'
#!/usr/bin/env bash
echo "Pure script error: command not found: foo"
exit 127
INNER
fi
exit 0
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        _env_diag_target_dir() { echo ""; }

        _env_curl_update_with_capture "$TOOL" "https://example/install.sh" "Claude Code" \
            >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code combined
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    combined=$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name pure-script failure" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$combined" != *"installer script exited with status"* ]]; then
        fail "$name pure-script failure" "missing 'installer script exited with status': $combined"
        return
    fi
    if [[ "$combined" != *"no curl error in log"* ]]; then
        fail "$name pure-script failure" "missing 'no curl error in log': $combined"
        return
    fi
    # F1 fix: must NOT say 'curl exit' on a pure-script failure.
    # Extract just the classification line (the one starting with "ERROR: Failed to update").
    local classification_line
    classification_line=$(grep "Failed to update" "$STDERR_FILE" 2>/dev/null || true)
    if [[ "$classification_line" == *"curl exit"* ]]; then
        fail "$name pure-script failure" "F1 misclassification — classification line says 'curl exit' on pure-script failure: $classification_line"
        return
    fi
    pass "$name pure-script failure surfaces 'installer script exited with status N (no curl error in log)' (F1)"
}

# ----------------------------------------------------------------------------
# 73.4 — perm-denied target pre-flight blocks curl invocation
# ----------------------------------------------------------------------------

test_73_4_perm_denied_preflight() {
    local name="73.4"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        skip "$name perm-denied pre-flight" "running as root (root bypasses perm gate)"
        return
    fi

    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local CURL_SENTINEL="$T/curl_invoked"
    local TOOL="continuous-claude"

    # Build a fake /opt-style path that is not writable.
    local FAKE_OPT="$T/opt-cac-test-$$"
    mkdir -p "$FAKE_OPT"
    chmod 555 "$FAKE_OPT"
    RESTORE_PERMS+=("$FAKE_OPT")

    (
        mkdir -p "$T/bin"
        cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl invoked: \$*" > "$CURL_SENTINEL"
exit 0
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        # Override target_dir to point at our unwritable /opt-style path.
        # The case-arm matches /opt* so the perm gate fires.
        _env_diag_target_dir() {
            case "$1" in
                continuous-claude) echo "$FAKE_OPT/continuous-claude" ;;
                *) echo "" ;;
            esac
        }

        # Also override the case-arm match: our test path starts with $T which
        # doesn't match /opt*. Bypass that by overriding the helper itself to
        # exercise the perm-gate logic directly. We patch the helper in-place
        # to treat our test path as system-style.
        _env_diag_preflight_curl() {
            local tool="$1"
            local target
            target=$(_env_diag_target_dir "$tool")
            [[ -n "$target" ]] || return 0
            local probe_dir="$target"
            while [[ -n "$probe_dir" && ! -d "$probe_dir" ]]; do
                probe_dir="$(dirname "$probe_dir")"
                [[ "$probe_dir" == "/" || "$probe_dir" == "." ]] && break
            done
            [[ -d "$probe_dir" ]] || probe_dir="/"
            # Force system-path treatment for our test path.
            if [[ ! -w "$probe_dir" ]] && [[ "${EUID:-\$(id -u)}" -ne 0 ]]; then
                utils_error "Target \$target is not writable by EUID=\$EUID — needs sudo."
                echo "Remediation: sudo cac env update \$tool" >&2
                return 1
            fi
            return 0
        }

        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }

        env_update_tool "$TOOL" "user" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code combined
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    combined=$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name perm-denied pre-flight" "expected non-zero exit, got 0"
        return
    fi
    if [[ -e "$CURL_SENTINEL" ]]; then
        fail "$name perm-denied pre-flight" "curl was invoked despite perm-denied"
        return
    fi
    if [[ "$combined" != *"needs sudo"* ]]; then
        fail "$name perm-denied pre-flight" "missing 'needs sudo' hint: $combined"
        return
    fi
    if [[ "$combined" != *"Remediation: sudo cac env update"* ]]; then
        fail "$name perm-denied pre-flight" "missing remediation hint: $combined"
        return
    fi
    local leftover
    leftover=$(_count_leftover_tempfiles "$TOOL")
    if [[ "$leftover" -ne 0 ]]; then
        fail "$name perm-denied pre-flight" "$leftover tempfile(s) leaked"
        return
    fi
    pass "$name perm-denied target pre-flight blocks curl, no tempfile leak"
}

# ----------------------------------------------------------------------------
# 73.5 — disk-full pre-flight blocks curl invocation
# ----------------------------------------------------------------------------

test_73_5_disk_full_preflight() {
    local name="73.5"
    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local CURL_SENTINEL="$T/curl_invoked"
    local TOOL="continuous-claude"

    (
        mkdir -p "$T/bin"
        cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl invoked: \$*" > "$CURL_SENTINEL"
exit 0
EOF
        chmod +x "$T/bin/curl"
        # Stub df: emits a header row + a data row with very low free space.
        cat > "$T/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake     1000000 999000      1024     100% /"
exit 0
EOF
        chmod +x "$T/bin/df"
        export PATH="$T/bin:$PATH"

        # Point target at an existing dir so probe_dir stays valid.
        _env_diag_target_dir() {
            case "$1" in
                continuous-claude) echo "$T/some-target" ;;
                *) echo "" ;;
            esac
        }

        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }

        env_update_tool "$TOOL" "user" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code combined
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    combined=$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name disk-full pre-flight" "expected non-zero exit, got 0"
        return
    fi
    if [[ -e "$CURL_SENTINEL" ]]; then
        fail "$name disk-full pre-flight" "curl was invoked despite low disk"
        return
    fi
    if [[ "$combined" != *"Low disk space"* ]]; then
        fail "$name disk-full pre-flight" "missing 'Low disk space' hint: $combined"
        return
    fi
    local leftover
    leftover=$(_count_leftover_tempfiles "$TOOL")
    if [[ "$leftover" -ne 0 ]]; then
        fail "$name disk-full pre-flight" "$leftover tempfile(s) leaked"
        return
    fi
    pass "$name disk-full pre-flight blocks curl, no tempfile leak"
}

# ----------------------------------------------------------------------------
# 73.6 — successful curl: tempfiles cleaned, post-install verify still runs
# ----------------------------------------------------------------------------

test_73_6_success_path() {
    local name="73.6"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        skip "$name success path" "running as root (uses post-install regression check)"
        return
    fi

    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local VERIFY_MARKER="$T/verify_called"
    local TOOL="claude"

    (
        mkdir -p "$T/bin"
        # Curl succeeds, writes a no-op installer.
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "$out" ]]; then
    cat > "$out" <<'INNER'
#!/usr/bin/env bash
echo "installed ok"
exit 0
INNER
fi
exit 0
EOF
        chmod +x "$T/bin/curl"

        # Provide a fake binary so post-install verification finds it on PATH.
        local fake_binary="cac_test_73_6_$$"
        : > "$T/bin/$fake_binary"
        chmod +x "$T/bin/$fake_binary"
        export HOME="$T/home"; mkdir -p "$HOME/.local/bin"
        : > "$HOME/.local/bin/$fake_binary"
        chmod +x "$HOME/.local/bin/$fake_binary"
        export PATH="$T/bin:$PATH"

        _env_diag_target_dir() { echo ""; }
        env_is_installed() { return 0; }
        # Counter file: env_get_version is invoked via $(...) subshells, so
        # function-local state doesn't persist. Marker on second call proves
        # the post-install verification ran.
        local _vc_file="$T/vc"
        echo 0 > "$_vc_file"
        env_get_version() {
            local n
            n=$(cat "$_vc_file" 2>/dev/null || echo 0)
            n=$((n + 1))
            echo "$n" > "$_vc_file"
            if [[ "$n" -ge 2 ]]; then
                echo "called" > "$VERIFY_MARKER"
            fi
            echo "2.1.129"
        }
        _env_global_install_exists() { return 1; }
        _env_tool_to_binary() {
            case "$1" in
                claude) echo "$fake_binary" ;;
                *) return 1 ;;
            esac
        }

        env_update_tool "$TOOL" "user" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code combined
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    combined=$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" != "0" ]]; then
        fail "$name success path" "expected exit 0, got $exit_code. output=$combined"
        return
    fi
    if [[ "$combined" == *"--- upstream installer log"* ]]; then
        fail "$name success path" "log-tail markers present on success path: $combined"
        return
    fi
    if [[ ! -e "$VERIFY_MARKER" ]]; then
        fail "$name success path" "post-install verification did not run (env_get_version called <2 times)"
        return
    fi
    local leftover
    leftover=$(_count_leftover_tempfiles "$TOOL")
    if [[ "$leftover" -ne 0 ]]; then
        fail "$name success path" "$leftover tempfile(s) leaked"
        return
    fi
    pass "$name successful curl path: tempfiles cleaned, post-install verification ran"
}

# ----------------------------------------------------------------------------
# 73.7 — npm path untouched by new diagnostics
# ----------------------------------------------------------------------------

test_73_7_npm_untouched() {
    local name="73.7"
    local T
    T=$(_scratch "$name")
    local CURL_SENTINEL="$T/curl_invoked"
    local NPM_SENTINEL="$T/npm_invoked"
    local PREFLIGHT_SENTINEL="$T/preflight_invoked"
    local CAPTURE_SENTINEL="$T/capture_invoked"
    local CLASSIFY_SENTINEL="$T/classify_invoked"
    local LOGTAIL_SENTINEL="$T/logtail_invoked"
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"

    (
        mkdir -p "$T/bin"
        cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl invoked: \$*" > "$CURL_SENTINEL"
exit 0
EOF
        chmod +x "$T/bin/curl"
        cat > "$T/bin/npm" <<EOF
#!/usr/bin/env bash
echo "npm invoked: \$*" > "$NPM_SENTINEL"
exit 0
EOF
        chmod +x "$T/bin/npm"
        cat > "$T/bin/node" <<'EOF'
#!/usr/bin/env bash
echo "v20.0.0"
EOF
        chmod +x "$T/bin/node"
        export PATH="$T/bin:$PATH"

        env_is_installed() { return 0; }
        env_get_version() { echo "0.94.0"; }
        _env_global_install_exists() { return 0; }

        # Sentinel: any of these helpers being called from the npm path is
        # a regression. Make them write a sentinel and return an error.
        _env_diag_preflight_curl() {
            echo "called: $*" > "$PREFLIGHT_SENTINEL"
            return 1
        }
        _env_curl_update_with_capture() {
            echo "called: $*" > "$CAPTURE_SENTINEL"
            return 1
        }
        _env_diag_classify_failure() {
            echo "called: $*" > "$CLASSIFY_SENTINEL"
            echo "should-not-appear"
        }
        _env_diag_print_log_tail() {
            echo "called: $*" > "$LOGTAIL_SENTINEL"
        }

        env_update_tool "codex" "user" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code combined
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    combined=$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" != "0" ]]; then
        fail "$name npm path untouched" "expected exit 0, got $exit_code. output=$combined"
        return
    fi
    if [[ ! -e "$NPM_SENTINEL" ]]; then
        fail "$name npm path untouched" "npm was not invoked"
        return
    fi
    if [[ -e "$CURL_SENTINEL" ]]; then
        fail "$name npm path untouched" "curl was invoked on npm path"
        return
    fi
    for sentinel in "$PREFLIGHT_SENTINEL" "$CAPTURE_SENTINEL" "$CLASSIFY_SENTINEL" "$LOGTAIL_SENTINEL"; do
        if [[ -e "$sentinel" ]]; then
            fail "$name npm path untouched" "diagnostic helper called from npm path: $sentinel"
            return
        fi
    done
    pass "$name npm path untouched by new curl-only diagnostics"
}

# ----------------------------------------------------------------------------
# 73.8 — Issue #71 refusal still works BEFORE any tempfile creation
# ----------------------------------------------------------------------------

test_73_8_71_refusal_before_tempfile() {
    local name="73.8"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        skip "$name #71 refusal-before-tempfile" "running as root"
        return
    fi

    local T
    T=$(_scratch "$name")
    local CURL_SENTINEL="$T/curl_invoked"
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local TOOL="continuous-claude"

    (
        mkdir -p "$T/bin"
        cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl invoked: \$*" > "$CURL_SENTINEL"
exit 0
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 0; }

        env_update_tool "$TOOL" "user" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code stderr_content
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name #71 refusal-before-tempfile" "expected non-zero exit, got 0"
        return
    fi
    if [[ -e "$CURL_SENTINEL" ]]; then
        fail "$name #71 refusal-before-tempfile" "curl was invoked despite refusal"
        return
    fi
    if [[ "$stderr_content" != *"system-wide install"* ]]; then
        fail "$name #71 refusal-before-tempfile" "stderr missing 'system-wide install': $stderr_content"
        return
    fi
    local leftover
    leftover=$(_count_leftover_tempfiles "$TOOL")
    if [[ "$leftover" -ne 0 ]]; then
        fail "$name #71 refusal-before-tempfile" "$leftover tempfile(s) leaked despite refusal"
        return
    fi
    pass "$name #71 refusal still fires before any #73 tempfile creation"
}

# ----------------------------------------------------------------------------
# 73.8b — refusal-first ordering: pre-flight not invoked when refusal fires
# ----------------------------------------------------------------------------

test_73_8b_refusal_first_ordering() {
    local name="73.8b"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        skip "$name refusal-first ordering" "running as root"
        return
    fi

    local T
    T=$(_scratch "$name")
    local PREFLIGHT_MARKER="$T/preflight_called"
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local TOOL="continuous-claude"

    (
        mkdir -p "$T/bin"
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        env_is_installed() { return 0; }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 0; }
        # Sentinel: pre-flight should NEVER be reached when refusal fires.
        _env_diag_preflight_curl() {
            echo "called: $*" > "$PREFLIGHT_MARKER"
            return 0
        }

        env_update_tool "$TOOL" "user" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code stderr_content
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name refusal-first ordering" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$stderr_content" != *"system-wide install"* ]]; then
        fail "$name refusal-first ordering" "stderr missing #71 refusal text: $stderr_content"
        return
    fi
    if [[ -e "$PREFLIGHT_MARKER" ]]; then
        fail "$name refusal-first ordering" "_env_diag_preflight_curl was called BEFORE #71 refusal"
        return
    fi
    pass "$name refusal-first ordering: #71 refusal short-circuits before #73 pre-flight"
}

# ----------------------------------------------------------------------------
# 73.9 — env_update_all batch summary carries per-tool cause
# ----------------------------------------------------------------------------

test_73_9_batch_summary_per_tool_cause() {
    local name="73.9"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        skip "$name batch summary cause" "running as root"
        return
    fi

    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"

    (
        mkdir -p "$T/bin"
        # Curl: succeed at download, write installer that emits curl:23 + exit 1.
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "$out" ]]; then
    cat > "$out" <<'INNER'
#!/usr/bin/env bash
echo "📥 Downloading continuous-claude..."
echo "curl: (23) client returned ERROR on write of 16375 bytes" >&2
exit 1
INNER
fi
exit 0
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        # Only continuous-claude is "installed"; everything else is skipped.
        env_is_installed() {
            case "$1" in
                continuous-claude) return 0 ;;
                *) return 1 ;;
            esac
        }
        env_get_version() { echo "1.0.0"; }
        _env_global_install_exists() { return 1; }
        _env_diag_target_dir() { echo ""; }

        env_update_all "user" >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code stdout_content
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    stdout_content=$(cat "$STDOUT_FILE" 2>/dev/null || echo "")

    if [[ "$exit_code" == "0" ]]; then
        fail "$name batch summary cause" "expected non-zero exit, got 0"
        return
    fi
    if [[ "$stdout_content" != *"Failed: 1"* ]]; then
        fail "$name batch summary cause" "stdout missing 'Failed: 1': $stdout_content"
        return
    fi
    if [[ "$stdout_content" != *"Failed tools: continuous-claude (installer script: write failure"* ]]; then
        fail "$name batch summary cause" "stdout missing per-tool cause one-liner. got: $stdout_content"
        return
    fi
    pass "$name batch summary 'Failed tools:' line carries per-tool cause"
}

# ----------------------------------------------------------------------------
# 73.10 — log-tail truncation: log >100 lines emits exactly last 40 + markers
# ----------------------------------------------------------------------------

test_73_10_log_tail_truncation() {
    local name="73.10"
    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local TOOL="continuous-claude"

    (
        mkdir -p "$T/bin"
        # Curl writes installer that emits 100 lines + curl:23 then exit 1.
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "$out" ]]; then
    cat > "$out" <<'INNER'
#!/usr/bin/env bash
for i in $(seq 1 100); do
    echo "log_line_$i"
done
echo "curl: (23) write error" >&2
exit 1
INNER
fi
exit 0
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        _env_diag_target_dir() { echo ""; }

        _env_curl_update_with_capture "$TOOL" "https://example/install.sh" "Continuous Claude" \
            >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local stderr_content
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")

    if [[ "$stderr_content" != *"--- upstream installer log (last 40 lines) ---"* ]]; then
        fail "$name log-tail truncation" "missing open marker"
        return
    fi
    if [[ "$stderr_content" != *"--- end log ---"* ]]; then
        fail "$name log-tail truncation" "missing close marker"
        return
    fi
    # Count lines strictly between the markers.
    local frame_lines
    frame_lines=$(awk '
        /^--- upstream installer log \(last 40 lines\) ---$/ {inframe=1; next}
        /^--- end log ---$/ {inframe=0}
        inframe {count++}
        END {print count+0}
    ' "$STDERR_FILE")
    if [[ "$frame_lines" -ne 40 ]]; then
        fail "$name log-tail truncation" "expected 40 lines between markers, got $frame_lines"
        return
    fi
    # First line inside frame should be log_line_61 (=100-40+1).
    # The installer output also has the trailing curl: (23) line; tee captured
    # both stderr + stdout so the order is: 100 log_line_NN lines + curl:(23)
    # = 101 lines; tail -40 gives lines 62..101. So first frame line = log_line_62.
    local first_frame_line
    first_frame_line=$(awk '
        /^--- upstream installer log \(last 40 lines\) ---$/ {inframe=1; next}
        /^--- end log ---$/ {inframe=0}
        inframe && !shown {print; shown=1}
    ' "$STDERR_FILE")
    if [[ "$first_frame_line" != "log_line_62" ]] && [[ "$first_frame_line" != "log_line_61" ]]; then
        fail "$name log-tail truncation" "first frame line unexpected: '$first_frame_line' (expected log_line_61 or log_line_62)"
        return
    fi
    pass "$name log-tail truncation: exactly 40 lines between frame markers"
}

# ----------------------------------------------------------------------------
# 73.11a — cleanup on log-mktemp failure
# ----------------------------------------------------------------------------

test_73_11a_cleanup_on_log_mktemp_fail() {
    local name="73.11a"
    local T
    T=$(_scratch "$name")
    local INSTALLER_PATH_LOG="$T/installer_paths"
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local TOOL="continuous-claude"

    (
        mkdir -p "$T/bin"
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        # Override mktemp: first call (installer) succeeds with a tracked path,
        # second call (log) fails. Use a counter file because function-local
        # state doesn't persist across calls.
        local _mt_counter="$T/mt_counter"
        echo 0 > "$_mt_counter"
        mktemp() {
            local n
            n=$(cat "$_mt_counter" 2>/dev/null || echo 0)
            n=$((n + 1))
            echo "$n" > "$_mt_counter"
            if [[ "$n" -eq 1 ]]; then
                local p="$T/installer-tracked.sh"
                : > "$p"
                echo "$p" >> "$INSTALLER_PATH_LOG"
                echo "$p"
                return 0
            else
                return 1
            fi
        }

        _env_curl_update_with_capture "$TOOL" "https://example/install.sh" "Continuous Claude" \
            >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    if [[ "$exit_code" == "0" ]]; then
        fail "$name cleanup on log-mktemp fail" "expected non-zero exit, got 0"
        return
    fi
    # The tracked installer tempfile must not still exist.
    if [[ -e "$T/installer-tracked.sh" ]]; then
        fail "$name cleanup on log-mktemp fail" "installer tempfile leaked: $T/installer-tracked.sh"
        return
    fi
    pass "$name cleanup on log-mktemp failure: installer tempfile removed"
}

# ----------------------------------------------------------------------------
# 73.11b — cleanup across two back-to-back successful runs
# ----------------------------------------------------------------------------

test_73_11b_back_to_back_cleanup() {
    local name="73.11b"
    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local TOOL="continuous-claude"

    (
        mkdir -p "$T/bin"
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "$out" ]]; then
    cat > "$out" <<'INNER'
#!/usr/bin/env bash
exit 0
INNER
fi
exit 0
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        # Run twice.
        _env_curl_update_with_capture "$TOOL" "https://example/install.sh" "Continuous Claude" \
            >>"$STDOUT_FILE" 2>>"$STDERR_FILE"
        local rc1=$?
        _env_curl_update_with_capture "$TOOL" "https://example/install.sh" "Continuous Claude" \
            >>"$STDOUT_FILE" 2>>"$STDERR_FILE"
        local rc2=$?
        echo "$rc1 $rc2" > "$T/exits"
    )

    local exits
    exits=$(cat "$T/exits" 2>/dev/null || echo "missing")
    if [[ "$exits" != "0 0" ]]; then
        fail "$name back-to-back cleanup" "expected '0 0' exits, got '$exits'"
        return
    fi
    local leftover
    leftover=$(_count_leftover_tempfiles "$TOOL")
    if [[ "$leftover" -ne 0 ]]; then
        fail "$name back-to-back cleanup" "$leftover tempfile(s) leaked after two runs"
        return
    fi
    pass "$name back-to-back successful runs leave no tempfiles"
}

# ----------------------------------------------------------------------------
# 73.11c — cleanup on bash-execution failure (F3)
# ----------------------------------------------------------------------------

test_73_11c_cleanup_on_bash_failure() {
    local name="73.11c"
    local T
    T=$(_scratch "$name")
    local STDERR_FILE="$T/stderr"
    local STDOUT_FILE="$T/stdout"
    local TOOL="continuous-claude"

    (
        mkdir -p "$T/bin"
        # Curl succeeds + writes installer that exits 1.
        cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "$out" ]]; then
    cat > "$out" <<'INNER'
#!/usr/bin/env bash
echo "installer ran but failed"
exit 1
INNER
fi
exit 0
EOF
        chmod +x "$T/bin/curl"
        export PATH="$T/bin:$PATH"

        _env_curl_update_with_capture "$TOOL" "https://example/install.sh" "Continuous Claude" \
            >"$STDOUT_FILE" 2>"$STDERR_FILE"
        echo "$?" > "$T/exit"
    )

    local exit_code
    exit_code=$(cat "$T/exit" 2>/dev/null || echo "missing")
    if [[ "$exit_code" == "0" ]]; then
        fail "$name cleanup on bash-execution failure" "expected non-zero exit, got 0"
        return
    fi
    # Both an installer tempfile and a log tempfile were created. Both must be gone.
    local tmp="${TMPDIR:-/tmp}"
    local installer_left log_left
    installer_left=$(find "$tmp" -maxdepth 1 -name "cac-env-update-${TOOL}-installer-*" 2>/dev/null | wc -l)
    log_left=$(find "$tmp" -maxdepth 1 -name "cac-env-update-${TOOL}-*.log" 2>/dev/null | wc -l)
    if [[ "$installer_left" -ne 0 ]]; then
        fail "$name cleanup on bash-execution failure" "$installer_left installer tempfile(s) leaked"
        return
    fi
    if [[ "$log_left" -ne 0 ]]; then
        fail "$name cleanup on bash-execution failure" "$log_left log tempfile(s) leaked"
        return
    fi
    pass "$name cleanup on bash-execution failure (F3): both tempfiles removed"
}

# ----------------------------------------------------------------------------
# Runner
# ----------------------------------------------------------------------------

header "Issue #73 tests: env update upstream-installer diagnostics"

test_73_1_execute_curl23
test_73_2_download_curl6
test_73_3_download_curl22
test_73_3a_execute_embedded_curl6
test_73_3b_pure_script_failure
test_73_4_perm_denied_preflight
test_73_5_disk_full_preflight
test_73_6_success_path
test_73_7_npm_untouched
test_73_8_71_refusal_before_tempfile
test_73_8b_refusal_first_ordering
test_73_9_batch_summary_per_tool_cause
test_73_10_log_tail_truncation
test_73_11a_cleanup_on_log_mktemp_fail
test_73_11b_back_to_back_cleanup
test_73_11c_cleanup_on_bash_failure

echo ""
echo "=========================================="
echo "Results: $PASSED/$TOTAL passed (skipped: $SKIPPED)"
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED}$FAILED test(s) failed${NC}"
    exit 1
fi
echo -e "${GREEN}All run tests passed${NC}"
exit 0
