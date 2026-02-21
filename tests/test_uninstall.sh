#!/usr/bin/env bash
# tests/test_uninstall.sh - Tests for uninstall.sh --full-purge features
#
# Tests ownership verification, skill manifest checks, non-interactive mode,
# and backward compatibility.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source test framework
source "${SCRIPT_DIR}/test_framework.sh"

framework_init

echo "========================================"
echo "Uninstall Tests"
echo "========================================"

# ============================================================================
# Source uninstall functions for testing
# ============================================================================

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Override is_root for testing
_TEST_EUID=""
is_root() {
    local effective_uid="${_TEST_EUID:-${EUID:-$(id -u)}}"
    [[ "$effective_uid" -eq 0 ]]
}

is_interactive() {
    [[ -t 0 ]]
}

# Path constants (will be overridden per-test to use temp dirs)
CLAUDE_GLOBAL_DIR="/opt/claude-code"
CLAUDE_GLOBAL_BIN="/usr/local/bin/claude"
CC_GLOBAL_DIR="/opt/continuous-claude"
CC_GLOBAL_BIN="/usr/local/bin/continuous-claude"

# Skill/manifest paths (overridden per-test)
USER_SKILL_DIR=""
USER_SKILL_MANIFEST=""
SYS_SKILL_DIR=""
SYS_SKILL_MANIFEST=""

# Source the helper functions from uninstall.sh by extracting them
# We define them here to avoid running main()

remove_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        success "Removed: $dir"
        return 0
    fi
    return 1
}

remove_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        rm -f "$file"
        success "Removed: $file"
        return 0
    fi
    return 1
}

_is_cac_managed_wrapper() {
    local bin_path="$1"
    local marker="$2"
    [[ -f "$bin_path" ]] && grep -qF "$marker" "$bin_path" 2>/dev/null
}

_is_cac_managed_symlink() {
    local bin_path="$1"
    [[ -L "$bin_path" ]] || return 1
    local target
    target=$(readlink -f "$bin_path" 2>/dev/null) || return 1
    [[ "$target" == "$CLAUDE_GLOBAL_BIN" ]] || \
    [[ "$target" == "$CC_GLOBAL_BIN" ]] || \
    [[ "$target" == "/opt/claude-code/"* ]] || \
    [[ "$target" == "/opt/continuous-claude/"* ]]
}

# ============================================================================
# _is_cac_managed_wrapper tests
# ============================================================================

echo ""
echo "--- Wrapper Ownership Check ---"

test_wrapper_detects_cac_claude() {
    local tmpdir="${TEST_TMPDIR}/wrapper1"
    mkdir -p "$tmpdir"

    # Create a cac-managed claude wrapper
    cat > "${tmpdir}/claude" <<'EOF'
#!/usr/bin/env bash
exec /opt/claude-code/node_modules/.bin/claude "$@"
EOF

    _is_cac_managed_wrapper "${tmpdir}/claude" "/opt/claude-code"
}
run_test "wrapper detects cac-managed claude" test_wrapper_detects_cac_claude

test_wrapper_detects_cac_cc() {
    local tmpdir="${TEST_TMPDIR}/wrapper2"
    mkdir -p "$tmpdir"

    cat > "${tmpdir}/continuous-claude" <<'EOF'
#!/usr/bin/env bash
exec /opt/continuous-claude/node_modules/.bin/continuous-claude "$@"
EOF

    _is_cac_managed_wrapper "${tmpdir}/continuous-claude" "/opt/continuous-claude"
}
run_test "wrapper detects cac-managed continuous-claude" test_wrapper_detects_cac_cc

test_wrapper_rejects_non_cac_binary() {
    local tmpdir="${TEST_TMPDIR}/wrapper3"
    mkdir -p "$tmpdir"

    # Create a non-cac claude binary (e.g. installed by npm directly)
    cat > "${tmpdir}/claude" <<'EOF'
#!/usr/bin/env node
require('@anthropic-ai/claude-code')
EOF

    ! _is_cac_managed_wrapper "${tmpdir}/claude" "/opt/claude-code"
}
run_test "wrapper rejects non-cac binary" test_wrapper_rejects_non_cac_binary

test_wrapper_rejects_missing_file() {
    ! _is_cac_managed_wrapper "${TEST_TMPDIR}/nonexistent" "/opt/claude-code"
}
run_test "wrapper rejects missing file" test_wrapper_rejects_missing_file

test_wrapper_rejects_empty_file() {
    local tmpdir="${TEST_TMPDIR}/wrapper5"
    mkdir -p "$tmpdir"
    touch "${tmpdir}/claude"

    ! _is_cac_managed_wrapper "${tmpdir}/claude" "/opt/claude-code"
}
run_test "wrapper rejects empty file" test_wrapper_rejects_empty_file

# ============================================================================
# _is_cac_managed_symlink tests
# ============================================================================

echo ""
echo "--- Symlink Ownership Check ---"

test_symlink_detects_cac_managed() {
    local tmpdir="${TEST_TMPDIR}/symlink1"
    mkdir -p "$tmpdir"

    # Create a fake global binary target
    local fake_global="${tmpdir}/global-claude"
    echo "#!/bin/bash" > "$fake_global"
    chmod +x "$fake_global"

    # Temporarily override CLAUDE_GLOBAL_BIN for this test
    local save_bin="$CLAUDE_GLOBAL_BIN"
    CLAUDE_GLOBAL_BIN="$fake_global"

    # Create symlink pointing to the global binary
    ln -sf "$fake_global" "${tmpdir}/claude"

    local result=0
    _is_cac_managed_symlink "${tmpdir}/claude" || result=1

    CLAUDE_GLOBAL_BIN="$save_bin"
    return $result
}
run_test "symlink detects cac-managed link" test_symlink_detects_cac_managed

test_symlink_detects_opt_target() {
    local tmpdir="${TEST_TMPDIR}/symlink2"
    mkdir -p "$tmpdir"
    mkdir -p "${tmpdir}/opt/claude-code/bin"

    # Create a target inside /opt/claude-code path
    local target="${tmpdir}/opt/claude-code/bin/claude"
    echo "#!/bin/bash" > "$target"
    chmod +x "$target"

    # Temporarily override to use temp paths
    local save_bin="$CLAUDE_GLOBAL_BIN"
    CLAUDE_GLOBAL_BIN="/some/other/path"

    ln -sf "$target" "${tmpdir}/claude-link"

    # This should fail because readlink resolves to tmpdir path, not /opt/claude-code
    # The check is for literal /opt/claude-code/* prefix
    local result=0
    _is_cac_managed_symlink "${tmpdir}/claude-link" || result=1

    CLAUDE_GLOBAL_BIN="$save_bin"

    # Should NOT match since target is in tmpdir, not /opt/claude-code/
    [[ $result -ne 0 ]]
}
run_test "symlink rejects non-cac target path" test_symlink_detects_opt_target

test_symlink_rejects_regular_file() {
    local tmpdir="${TEST_TMPDIR}/symlink3"
    mkdir -p "$tmpdir"

    # Regular file, not a symlink
    echo "#!/bin/bash" > "${tmpdir}/claude"
    chmod +x "${tmpdir}/claude"

    ! _is_cac_managed_symlink "${tmpdir}/claude"
}
run_test "symlink rejects regular file" test_symlink_rejects_regular_file

test_symlink_rejects_nonexistent() {
    ! _is_cac_managed_symlink "${TEST_TMPDIR}/nonexistent-link"
}
run_test "symlink rejects nonexistent path" test_symlink_rejects_nonexistent

test_symlink_rejects_unrelated_target() {
    local tmpdir="${TEST_TMPDIR}/symlink5"
    mkdir -p "$tmpdir"

    # Create a symlink to an unrelated target
    echo "unrelated" > "${tmpdir}/other-tool"
    ln -sf "${tmpdir}/other-tool" "${tmpdir}/claude"

    ! _is_cac_managed_symlink "${tmpdir}/claude"
}
run_test "symlink rejects unrelated symlink target" test_symlink_rejects_unrelated_target

# ============================================================================
# Skill manifest ownership proof tests
# ============================================================================

echo ""
echo "--- Skill Manifest Ownership ---"

# Source remove_skills with overridable paths
# Inline skill removal logic for testing (mirrors remove_skills from uninstall.sh)
# Uses USER_SKILL_DIR and USER_SKILL_MANIFEST which must be set before calling
_test_remove_skills() {
    local skill_dir="$1"
    local manifest="$2"
    _SKILL_REMOVED=0

    if [[ -f "$manifest" ]]; then
        remove_dir "$skill_dir" && { ((_SKILL_REMOVED++)) || true; }
        remove_file "$manifest" && { ((_SKILL_REMOVED++)) || true; }
    fi
}

test_skills_removed_with_manifest() {
    local tmpdir="${TEST_TMPDIR}/skill1"
    mkdir -p "${tmpdir}/skills/my-lib"
    echo '[{"name":"my-lib"}]' > "${tmpdir}/manifest.json"

    _test_remove_skills "${tmpdir}/skills" "${tmpdir}/manifest.json"

    # Both should be removed
    [[ $_SKILL_REMOVED -eq 2 ]] && \
    [[ ! -d "${tmpdir}/skills" ]] && \
    [[ ! -f "${tmpdir}/manifest.json" ]]
}
run_test "skills removed when manifest exists" test_skills_removed_with_manifest

test_skills_preserved_without_manifest() {
    local tmpdir="${TEST_TMPDIR}/skill2"
    mkdir -p "${tmpdir}/skills/my-lib"
    # No manifest file

    _test_remove_skills "${tmpdir}/skills" "${tmpdir}/manifest.json"

    # Nothing should be removed
    [[ $_SKILL_REMOVED -eq 0 ]] && \
    [[ -d "${tmpdir}/skills" ]]
}
run_test "skills preserved when no manifest" test_skills_preserved_without_manifest

test_skills_manifest_only_no_dir() {
    local tmpdir="${TEST_TMPDIR}/skill3"
    mkdir -p "$tmpdir"
    echo '[]' > "${tmpdir}/manifest.json"
    # No skills directory

    _test_remove_skills "${tmpdir}/skills" "${tmpdir}/manifest.json"

    # Only manifest removed (dir didn't exist)
    [[ $_SKILL_REMOVED -eq 1 ]] && \
    [[ ! -f "${tmpdir}/manifest.json" ]]
}
run_test "manifest removed even if skill dir missing" test_skills_manifest_only_no_dir

# ============================================================================
# Non-interactive mode tests
# ============================================================================

echo ""
echo "--- Non-Interactive Mode ---"

test_full_purge_noninteractive_skips_ai_tools() {
    local output
    output=$(echo "" | bash "${PROJECT_DIR}/uninstall.sh" --full-purge 2>&1) || true

    # Should contain the non-interactive skip message
    assert_contains "Non-interactive mode: skipping AI tool removal" "$output" "non-interactive skip message"
}
run_test "full-purge non-interactive skips AI tools" test_full_purge_noninteractive_skips_ai_tools

test_full_purge_noninteractive_mentions_interactive() {
    local output
    output=$(echo "" | bash "${PROJECT_DIR}/uninstall.sh" --full-purge 2>&1) || true

    assert_contains "Run interactively with --full-purge to remove AI tools" "$output" "interactive hint"
}
run_test "full-purge non-interactive shows hint" test_full_purge_noninteractive_mentions_interactive

# ============================================================================
# Argument parsing tests
# ============================================================================

echo ""
echo "--- Argument Parsing ---"

test_help_shows_full_purge() {
    local output
    output=$(bash "${PROJECT_DIR}/uninstall.sh" --help 2>&1)

    assert_contains "--full-purge" "$output" "help output"
}
run_test "help shows --full-purge" test_help_shows_full_purge

test_help_shows_purge() {
    local output
    output=$(bash "${PROJECT_DIR}/uninstall.sh" --help 2>&1)

    assert_contains "--purge" "$output" "help output"
}
run_test "help shows --purge" test_help_shows_purge

test_unknown_flag_fails() {
    local output
    output=$(bash "${PROJECT_DIR}/uninstall.sh" --bogus 2>&1) && return 1 || true

    assert_contains "Unknown option" "$output" "error message"
}
run_test "unknown flag fails with error" test_unknown_flag_fails

test_default_mode_no_error() {
    local output
    output=$(echo "" | bash "${PROJECT_DIR}/uninstall.sh" 2>&1) || true

    # Should not contain ERROR
    ! echo "$output" | grep -q '\[ERROR\]'
}
run_test "default mode runs without errors" test_default_mode_no_error

test_purge_mode_no_error() {
    local output
    output=$(echo "" | bash "${PROJECT_DIR}/uninstall.sh" --purge 2>&1) || true

    ! echo "$output" | grep -q '\[ERROR\]'
}
run_test "purge mode runs without errors" test_purge_mode_no_error

test_full_purge_implies_purge() {
    # --full-purge should not show "Use --purge to remove" hint since purge is implied
    local output
    output=$(echo "" | bash "${PROJECT_DIR}/uninstall.sh" --full-purge 2>&1) || true

    ! echo "$output" | grep -q "Use --purge to remove"
}
run_test "full-purge implies purge (no hint)" test_full_purge_implies_purge

# ============================================================================
# Help content tests
# ============================================================================

echo ""
echo "--- Help Content ---"

test_help_shows_skill_paths() {
    local output
    output=$(bash "${PROJECT_DIR}/uninstall.sh" --help 2>&1)

    assert_contains "Skills:" "$output" "skills label" && \
    assert_contains "Manifest:" "$output" "manifest label"
}
run_test "help shows skill and manifest paths" test_help_shows_skill_paths

test_help_shows_modes() {
    local output
    output=$(bash "${PROJECT_DIR}/uninstall.sh" --help 2>&1)

    assert_contains "Modes:" "$output" "modes section" && \
    assert_contains "(default)" "$output" "default mode" && \
    assert_contains "Skill libraries and manifests" "$output" "skill description"
}
run_test "help shows mode descriptions" test_help_shows_modes

test_help_shows_noninteractive_note() {
    local output
    output=$(bash "${PROJECT_DIR}/uninstall.sh" --help 2>&1)

    assert_contains "Non-interactive mode:" "$output" "non-interactive section"
}
run_test "help shows non-interactive note" test_help_shows_noninteractive_note

# ============================================================================
# Syntax validation
# ============================================================================

echo ""
echo "--- Syntax Validation ---"

test_bash_syntax_valid() {
    bash -n "${PROJECT_DIR}/uninstall.sh"
}
run_test "uninstall.sh passes bash -n syntax check" test_bash_syntax_valid

# ============================================================================
# Report
# ============================================================================

echo ""
framework_report
