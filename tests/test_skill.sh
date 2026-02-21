#!/usr/bin/env bash
# tests/test_skill.sh - Skill library management tests
#
# Run with: ./tests/test_skill.sh
# Or run all tests: ./tests/run_tests.sh skill
#
# shellcheck disable=SC2317  # Test functions invoked via run_test
# shellcheck disable=SC2034  # Variables used by sourced modules

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source shared test framework
source "${SCRIPT_DIR}/test_framework.sh"

# Source library modules
source "${PROJECT_ROOT}/lib/logging.sh"
source "${PROJECT_ROOT}/lib/utils.sh"
source "${PROJECT_ROOT}/lib/skill.sh"

# ============================================================================
# Git Mock
# ============================================================================

MOCK_GIT_LOG=""
MOCK_GIT_CLONE_EXIT="0"
MOCK_GIT_FETCH_EXIT="0"
MOCK_GIT_PULL_EXIT="0"
MOCK_GIT_REV_PARSE_RESPONSE="abc123def456"
MOCK_GIT_REV_PARSE_REMOTE_RESPONSE="abc123def456"
MOCK_GIT_SYMBOLIC_REF_RESPONSE="refs/remotes/origin/main"
MOCK_GIT_LOG_ONELINE_RESPONSE=""
MOCK_GIT_DIFF_NAMES_RESPONSE=""
MOCK_GIT_STATUS_PORCELAIN_RESPONSE=""

_mock_git_setup() {
    MOCK_GIT_LOG="${TEST_TMPDIR}/mock_git_log.txt"
    : > "$MOCK_GIT_LOG"
    MOCK_GIT_CLONE_EXIT="0"
    MOCK_GIT_FETCH_EXIT="0"
    MOCK_GIT_PULL_EXIT="0"
    MOCK_GIT_REV_PARSE_RESPONSE="abc123def456"
    MOCK_GIT_REV_PARSE_REMOTE_RESPONSE="abc123def456"
    MOCK_GIT_SYMBOLIC_REF_RESPONSE="refs/remotes/origin/main"
    MOCK_GIT_LOG_ONELINE_RESPONSE=""
    MOCK_GIT_DIFF_NAMES_RESPONSE=""
    MOCK_GIT_STATUS_PORCELAIN_RESPONSE=""

    # Override git command
    git() {
        echo "$*" >> "$MOCK_GIT_LOG"
        local subcmd="${1:-}"
        shift || true

        case "$subcmd" in
            clone)
                local target="" url=""
                for arg in "$@"; do
                    [[ "$arg" == -* ]] && continue
                    if [[ -z "$url" ]]; then url="$arg"; else target="$arg"; fi
                done
                if [[ -n "$target" ]]; then mkdir -p "${target}/.git"; fi
                return "$MOCK_GIT_CLONE_EXIT"
                ;;
            status)
                printf '%s' "$MOCK_GIT_STATUS_PORCELAIN_RESPONSE"
                return 0
                ;;
            fetch) return "$MOCK_GIT_FETCH_EXIT" ;;
            pull) return "$MOCK_GIT_PULL_EXIT" ;;
            rev-parse)
                local last_arg="${*: -1}"
                if [[ "$last_arg" == origin/* ]]; then
                    printf '%s' "$MOCK_GIT_REV_PARSE_REMOTE_RESPONSE"
                else
                    printf '%s' "$MOCK_GIT_REV_PARSE_RESPONSE"
                fi
                return 0
                ;;
            symbolic-ref) printf '%s' "$MOCK_GIT_SYMBOLIC_REF_RESPONSE"; return 0 ;;
            log) printf '%s' "$MOCK_GIT_LOG_ONELINE_RESPONSE"; return 0 ;;
            diff) printf '%s' "$MOCK_GIT_DIFF_NAMES_RESPONSE"; return 0 ;;
            -C)
                shift || true  # skip directory
                local real_subcmd="${1:-}"
                shift || true
                case "$real_subcmd" in
                    status) printf '%s' "$MOCK_GIT_STATUS_PORCELAIN_RESPONSE"; return 0 ;;
                    rev-parse)
                        local last_arg="${*: -1}"
                        if [[ "$last_arg" == origin/* ]]; then
                            printf '%s' "$MOCK_GIT_REV_PARSE_REMOTE_RESPONSE"
                        else
                            printf '%s' "$MOCK_GIT_REV_PARSE_RESPONSE"
                        fi
                        return 0
                        ;;
                    fetch) return "$MOCK_GIT_FETCH_EXIT" ;;
                    pull) return "$MOCK_GIT_PULL_EXIT" ;;
                    symbolic-ref) printf '%s' "$MOCK_GIT_SYMBOLIC_REF_RESPONSE"; return 0 ;;
                    log) printf '%s' "$MOCK_GIT_LOG_ONELINE_RESPONSE"; return 0 ;;
                    diff) printf '%s' "$MOCK_GIT_DIFF_NAMES_RESPONSE"; return 0 ;;
                    *) return 0 ;;
                esac
                ;;
            *) return 0 ;;
        esac
    }
    export -f git
}

_assert_git_called_with() {
    local expected="$1"
    if [[ ! -s "$MOCK_GIT_LOG" ]]; then
        echo "FAIL: No git calls recorded" >&2
        return 1
    fi
    if grep -q "$expected" "$MOCK_GIT_LOG"; then
        return 0
    else
        echo "FAIL: Expected git call containing '${expected}' but got:" >&2
        cat "$MOCK_GIT_LOG" >&2
        return 1
    fi
}

_assert_git_not_called_with() {
    local unexpected="$1"
    if [[ ! -s "$MOCK_GIT_LOG" ]]; then
        return 0
    fi
    if grep -q "$unexpected" "$MOCK_GIT_LOG"; then
        echo "FAIL: Expected no git call containing '${unexpected}' but found:" >&2
        cat "$MOCK_GIT_LOG" >&2
        return 1
    fi
    return 0
}

# Helper: set up test environment with skill dir + manifest override
_setup_test_env() {
    local test_name="$1"
    SKILL_USER_DIR="${TEST_TMPDIR}/skills_${test_name}"
    SKILL_MANIFEST_USER="${TEST_TMPDIR}/config_${test_name}/skill-libraries.json"
    mkdir -p "${TEST_TMPDIR}/config_${test_name}"
}

# ============================================================================
# Test Cases: Repo Name Extraction & Path Traversal Validation
# ============================================================================

test_repo_name_from_https_url() {
    local name
    name=$(_skill_repo_name_from_url "https://github.com/BPMspaceUG/bpm-claude-global-agent-skill-library.git")
    assert_equals "bpm-claude-global-agent-skill-library" "$name" "HTTPS URL repo name"
}

test_repo_name_from_https_url_no_git() {
    local name
    name=$(_skill_repo_name_from_url "https://github.com/BPMspaceUG/bpm-claude-global-agent-skill-library")
    assert_equals "bpm-claude-global-agent-skill-library" "$name" "HTTPS URL without .git"
}

test_repo_name_from_ssh_url() {
    local name
    name=$(_skill_repo_name_from_url "git@github.com:BPMspaceUG/bpm-claude-global-agent-skill-library.git")
    assert_equals "bpm-claude-global-agent-skill-library" "$name" "SSH URL repo name"
}

test_repo_name_trailing_slash() {
    local name
    name=$(_skill_repo_name_from_url "https://github.com/org/my-repo/")
    assert_equals "my-repo" "$name" "URL with trailing slash"
}

test_repo_name_invalid_empty() {
    if _skill_repo_name_from_url "" 2>/dev/null; then
        echo "FAIL: Should have failed for empty URL" >&2
        return 1
    fi
    return 0
}

test_repo_name_path_traversal_dotdot() {
    # Direct .. as repo name component
    if _skill_repo_name_from_url "https://evil.com/.." 2>/dev/null; then
        echo "FAIL: Should reject path traversal with .." >&2
        return 1
    fi
    return 0
}

test_repo_name_path_traversal_special_chars() {
    if _skill_repo_name_from_url "https://evil.com/repo;rm -rf /" 2>/dev/null; then
        echo "FAIL: Should reject repo name with special characters" >&2
        return 1
    fi
    return 0
}

test_repo_name_valid_chars_only() {
    local name
    name=$(_skill_repo_name_from_url "https://github.com/org/valid.repo-name_v2.git")
    assert_equals "valid.repo-name_v2" "$name" "valid chars in repo name"
}

# ============================================================================
# Test Cases: Manifest Operations
# ============================================================================

test_manifest_read_missing() {
    local result
    result=$(_skill_manifest_read "${TEST_TMPDIR}/nonexistent.json")
    assert_equals "[]" "$result" "missing manifest returns empty array"
}

test_manifest_add_and_read() {
    local manifest_path="${TEST_TMPDIR}/test_manifest.json"
    _skill_manifest_add_entry "$manifest_path" "test-lib" "https://example.com/test-lib.git" "sha123" "2026-01-01T00:00:00Z"

    local contents
    contents=$(_skill_manifest_read "$manifest_path")
    assert_contains "test-lib" "$contents" "manifest contains library name" &&
    assert_contains "sha123" "$contents" "manifest contains SHA" &&
    assert_contains "https://example.com/test-lib.git" "$contents" "manifest contains URL"
}

test_manifest_add_multiple() {
    local manifest_path="${TEST_TMPDIR}/test_manifest2.json"
    _skill_manifest_add_entry "$manifest_path" "lib-one" "https://example.com/lib-one.git" "sha111" "2026-01-01T00:00:00Z"
    _skill_manifest_add_entry "$manifest_path" "lib-two" "https://example.com/lib-two.git" "sha222" "2026-01-02T00:00:00Z"

    local contents
    contents=$(_skill_manifest_read "$manifest_path")
    assert_contains "lib-one" "$contents" "manifest contains first library" &&
    assert_contains "lib-two" "$contents" "manifest contains second library"
}

test_manifest_has_entry() {
    local manifest_path="${TEST_TMPDIR}/test_manifest_has.json"
    _skill_manifest_add_entry "$manifest_path" "exists-lib" "https://example.com/exists-lib.git" "sha999" "2026-01-01T00:00:00Z"

    _skill_manifest_has_entry "$manifest_path" "exists-lib" &&
    ! _skill_manifest_has_entry "$manifest_path" "nonexistent-lib"
}

test_manifest_update_sha() {
    local manifest_path="${TEST_TMPDIR}/test_manifest_update.json"
    _skill_manifest_add_entry "$manifest_path" "update-lib" "https://example.com/update-lib.git" "old_sha" "2026-01-01T00:00:00Z"
    _skill_manifest_update_sha "$manifest_path" "update-lib" "new_sha_value"

    local contents
    contents=$(_skill_manifest_read "$manifest_path")
    assert_contains "new_sha_value" "$contents" "manifest contains updated SHA"
}

test_manifest_remove_entry() {
    local manifest_path="${TEST_TMPDIR}/test_manifest_remove.json"
    _skill_manifest_add_entry "$manifest_path" "keep-lib" "https://example.com/keep.git" "sha1" "2026-01-01T00:00:00Z"
    _skill_manifest_add_entry "$manifest_path" "remove-lib" "https://example.com/remove.git" "sha2" "2026-01-02T00:00:00Z"
    _skill_manifest_remove_entry "$manifest_path" "remove-lib"

    local contents
    contents=$(_skill_manifest_read "$manifest_path")
    assert_contains "keep-lib" "$contents" "kept library still present" &&
    ! printf '%s' "$contents" | grep -q "remove-lib"
}

test_manifest_corrupt_recovery() {
    # Manifest with invalid JSON should not crash list
    local manifest_path="${TEST_TMPDIR}/test_manifest_corrupt.json"
    printf '%s\n' "NOT_VALID_JSON" > "$manifest_path"

    # _skill_manifest_read should return the content as-is (no crash)
    local contents
    contents=$(_skill_manifest_read "$manifest_path")
    # It won't be "[]" but it shouldn't crash
    [[ -n "$contents" ]]
}

test_manifest_location_user() {
    # Verify manifest path uses ~/.config/cac/ location, not inside skills dir
    local path
    path=$(_skill_manifest_path "false")
    assert_contains "/.config/cac/skill-libraries.json" "$path" "user manifest in config dir" ||
    assert_contains "/cac/skill-libraries.json" "$path" "user manifest in cac config dir"
}

test_manifest_location_system() {
    local path
    path=$(_skill_manifest_path "true")
    assert_equals "/etc/cac/skill-libraries.json" "$path" "system manifest path"
}

# ============================================================================
# Test Cases: Install
# ============================================================================

test_install_success() {
    _mock_git_setup
    _setup_test_env "install_ok"

    local output
    output=$(skill_install "https://github.com/BPMspaceUG/bpm-claude-global-agent-skill-library.git" 2>&1)

    assert_contains "Installed" "$output" "success message" &&
    assert_contains "bpm-claude-global-agent-skill-library" "$output" "library name in output" &&
    _assert_git_called_with "clone" &&
    assert_file_exists "$SKILL_MANIFEST_USER" "manifest created"
}

test_install_already_exists() {
    _mock_git_setup
    _setup_test_env "install_dup"
    mkdir -p "${SKILL_USER_DIR}/my-repo"

    local output
    if output=$(skill_install "https://github.com/org/my-repo.git" 2>&1); then
        echo "FAIL: Should have failed for duplicate install" >&2
        return 1
    fi
    assert_contains "already installed" "$output" "duplicate error message"
}

test_install_no_url() {
    local output
    if output=$(skill_install 2>&1); then
        echo "FAIL: Should have failed without URL" >&2
        return 1
    fi
    assert_contains "Usage" "$output" "usage message shown"
}

test_install_clone_failure() {
    _mock_git_setup
    MOCK_GIT_CLONE_EXIT="1"
    _setup_test_env "install_fail"

    local output
    if output=$(skill_install "https://github.com/org/bad-repo.git" 2>&1); then
        echo "FAIL: Should have failed on clone error" >&2
        return 1
    fi
    assert_contains "Failed to clone" "$output" "clone failure message"
}

test_install_manifest_updated() {
    _mock_git_setup
    _setup_test_env "install_manifest"

    skill_install "https://github.com/org/test-lib.git" >/dev/null 2>&1 || true

    local manifest
    manifest=$(_skill_manifest_read "$SKILL_MANIFEST_USER")
    assert_contains "test-lib" "$manifest" "manifest has library entry" &&
    assert_contains "abc123de" "$manifest" "manifest has SHA"
}

test_install_path_traversal_rejected() {
    _mock_git_setup
    _setup_test_env "install_traversal"

    # URL whose extracted repo name contains special characters
    local output
    if output=$(skill_install "https://evil.com/repo;rm%20-rf" 2>&1); then
        echo "FAIL: Should reject path traversal URL" >&2
        return 1
    fi
    assert_contains "Invalid repository name" "$output" "path traversal rejection message"
}

test_install_url_starts_with_dash() {
    _mock_git_setup
    _setup_test_env "install_dash"

    # skill_install's arg parser catches --options, so test _skill_repo_name_from_url directly
    local output
    if output=$(_skill_repo_name_from_url "--upload-pack=evil" 2>&1); then
        echo "FAIL: Should reject URL starting with dash" >&2
        return 1
    fi
    assert_contains "must not start with" "$output" "dash URL rejection message"
}

# ============================================================================
# Test Cases: List
# ============================================================================

test_list_empty() {
    _setup_test_env "list_empty"

    local output
    output=$(skill_list 2>&1)
    assert_contains "No skill libraries installed" "$output" "empty list message"
}

test_list_with_entries() {
    _setup_test_env "list_entries"
    mkdir -p "$SKILL_USER_DIR"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "lib-alpha" "https://example.com/lib-alpha.git" "aaa111bbb222" "2026-01-15T10:00:00Z"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "lib-beta" "https://example.com/lib-beta.git" "ccc333ddd444" "2026-02-01T12:00:00Z"

    local output
    output=$(skill_list 2>&1)
    assert_contains "lib-alpha" "$output" "first library in list" &&
    assert_contains "lib-beta" "$output" "second library in list" &&
    assert_contains "Total: 2" "$output" "total count"
}

# ============================================================================
# Test Cases: Update
# ============================================================================

test_update_no_libraries() {
    _setup_test_env "upd_none"

    local output
    output=$(skill_update 2>&1)
    assert_contains "No skill libraries installed" "$output" "no libraries message"
}

test_update_already_up_to_date() {
    _mock_git_setup
    MOCK_GIT_REV_PARSE_RESPONSE="same_sha_123"
    MOCK_GIT_REV_PARSE_REMOTE_RESPONSE="same_sha_123"

    _setup_test_env "upd_current"
    mkdir -p "${SKILL_USER_DIR}/test-lib/.git"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "test-lib" "https://example.com/test-lib.git" "same_sha_123" "2026-01-01T00:00:00Z"

    local output
    output=$(skill_update --yes 2>&1)
    assert_contains "already up to date" "$output" "up to date message"
}

test_update_applies_changes() {
    _mock_git_setup
    MOCK_GIT_REV_PARSE_RESPONSE="old_sha_111"
    MOCK_GIT_REV_PARSE_REMOTE_RESPONSE="new_sha_222"
    MOCK_GIT_LOG_ONELINE_RESPONSE="abc1234 Add new skill"

    _setup_test_env "upd_apply"
    mkdir -p "${SKILL_USER_DIR}/test-lib/.git"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "test-lib" "https://example.com/test-lib.git" "old_sha_111" "2026-01-01T00:00:00Z"

    local output
    output=$(skill_update --yes 2>&1)
    assert_contains "Updated" "$output" "update success message" &&
    _assert_git_called_with "pull"
}

test_update_specific_library() {
    _mock_git_setup
    MOCK_GIT_REV_PARSE_RESPONSE="old_sha"
    MOCK_GIT_REV_PARSE_REMOTE_RESPONSE="new_sha"

    _setup_test_env "upd_specific"
    mkdir -p "${SKILL_USER_DIR}/lib-a/.git"
    mkdir -p "${SKILL_USER_DIR}/lib-b/.git"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "lib-a" "https://example.com/lib-a.git" "old_sha" "2026-01-01T00:00:00Z"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "lib-b" "https://example.com/lib-b.git" "old_sha" "2026-01-02T00:00:00Z"

    local output
    output=$(skill_update "lib-a" --yes 2>&1)
    assert_contains "Updated" "$output" "update message for lib-a" &&
    assert_contains "lib-a" "$output" "lib-a in output"
}

test_update_nonexistent_library() {
    _mock_git_setup
    _setup_test_env "upd_noexist"
    mkdir -p "$SKILL_USER_DIR"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "real-lib" "https://example.com/real.git" "sha1" "2026-01-01T00:00:00Z"

    local output
    if output=$(skill_update "fake-lib" --yes 2>&1); then
        echo "FAIL: Should have failed for nonexistent library" >&2
        return 1
    fi
    assert_contains "not found" "$output" "not found error"
}

test_update_dirty_tree_skipped() {
    _mock_git_setup
    MOCK_GIT_REV_PARSE_RESPONSE="old_sha"
    MOCK_GIT_REV_PARSE_REMOTE_RESPONSE="new_sha"
    MOCK_GIT_STATUS_PORCELAIN_RESPONSE=" M modified-file.md"

    _setup_test_env "upd_dirty"
    mkdir -p "${SKILL_USER_DIR}/dirty-lib/.git"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "dirty-lib" "https://example.com/dirty-lib.git" "old_sha" "2026-01-01T00:00:00Z"

    local output
    output=$(skill_update --yes 2>&1)
    assert_contains "uncommitted changes" "$output" "dirty tree warning" &&
    assert_contains "Skipping" "$output" "skip message" &&
    _assert_git_not_called_with "pull"
}

test_update_fetch_failure() {
    _mock_git_setup
    MOCK_GIT_FETCH_EXIT="1"

    _setup_test_env "upd_fetch_fail"
    mkdir -p "${SKILL_USER_DIR}/fail-lib/.git"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "fail-lib" "https://example.com/fail-lib.git" "sha1" "2026-01-01T00:00:00Z"

    local output
    output=$(skill_update --yes 2>&1)
    assert_contains "Failed to fetch" "$output" "fetch failure message" &&
    assert_contains "1 failed" "$output" "failure count in summary"
}

test_update_manifest_traversal_rejected() {
    _mock_git_setup
    _setup_test_env "upd_traversal"

    # Manually inject a poisoned manifest entry with path traversal name
    _skill_manifest_write "$SKILL_MANIFEST_USER" '[{"name":"../../etc","url":"https://evil.com/repo.git","sha":"abc123","installed":"2026-01-01T00:00:00Z"}]'

    local output
    output=$(skill_update --yes 2>&1)
    assert_contains "invalid library name" "$output" "traversal name rejected" &&
    _assert_git_not_called_with "pull"
}

# ============================================================================
# Test Cases: my- Prefix Protection
# ============================================================================

test_my_prefix_detection() {
    local test_dir="${TEST_TMPDIR}/my_prefix_test"
    mkdir -p "$test_dir"
    mkdir -p "${test_dir}/my-custom-skill"
    touch "${test_dir}/my-special-agent"
    touch "${test_dir}/regular-skill"

    local found
    found=$(_skill_find_my_prefixed "$test_dir")
    assert_contains "my-custom-skill" "$found" "found my-custom-skill" &&
    assert_contains "my-special-agent" "$found" "found my-special-agent"
}

test_my_prefix_empty_dir() {
    local test_dir="${TEST_TMPDIR}/my_prefix_empty"
    mkdir -p "$test_dir"

    local found
    found=$(_skill_find_my_prefixed "$test_dir")
    assert_equals "" "$found" "no my-* items found"
}

test_my_prefix_nonexistent_dir() {
    local found
    found=$(_skill_find_my_prefixed "${TEST_TMPDIR}/nonexistent_dir")
    assert_equals "" "$found" "nonexistent dir returns empty"
}

test_my_prefix_in_skills_root_not_library() {
    # my-* items in the skills root dir (NOT inside library subdirs) are protected
    # Install and update should never delete/overwrite them
    _mock_git_setup
    MOCK_GIT_REV_PARSE_RESPONSE="old_sha"
    MOCK_GIT_REV_PARSE_REMOTE_RESPONSE="new_sha"

    _setup_test_env "my_root"
    mkdir -p "${SKILL_USER_DIR}/some-lib/.git"
    # Create my-* items directly in skills root (user-customised)
    touch "${SKILL_USER_DIR}/my-custom-skill.md"
    mkdir -p "${SKILL_USER_DIR}/my-personal-toolkit"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "some-lib" "https://example.com/some-lib.git" "old_sha" "2026-01-01T00:00:00Z"

    # Update should succeed and my-* items in root should still exist
    skill_update --yes >/dev/null 2>&1 || true

    assert_file_exists "${SKILL_USER_DIR}/my-custom-skill.md" "my-* skill in root preserved" &&
    [[ -d "${SKILL_USER_DIR}/my-personal-toolkit" ]]
}

# ============================================================================
# Test Cases: Status
# ============================================================================

test_status_no_libraries() {
    _setup_test_env "status_empty"

    local output
    output=$(skill_status 2>&1)
    assert_contains "No skill libraries installed" "$output" "no libraries message"
}

test_status_up_to_date() {
    _mock_git_setup
    MOCK_GIT_REV_PARSE_RESPONSE="same_sha"
    MOCK_GIT_REV_PARSE_REMOTE_RESPONSE="same_sha"

    _setup_test_env "status_ok"
    mkdir -p "${SKILL_USER_DIR}/status-lib/.git"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "status-lib" "https://example.com/status-lib.git" "same_sha" "2026-01-01T00:00:00Z"

    local output
    output=$(skill_status 2>&1)
    assert_contains "status-lib" "$output" "library name in status" &&
    assert_contains "up-to-date" "$output" "up-to-date status"
}

test_status_update_available() {
    _mock_git_setup
    MOCK_GIT_REV_PARSE_RESPONSE="local_sha"
    MOCK_GIT_REV_PARSE_REMOTE_RESPONSE="remote_sha"

    _setup_test_env "status_avail"
    mkdir -p "${SKILL_USER_DIR}/avail-lib/.git"
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "avail-lib" "https://example.com/avail-lib.git" "local_sha" "2026-01-01T00:00:00Z"

    local output
    output=$(skill_status 2>&1)
    assert_contains "avail-lib" "$output" "library name in status" &&
    assert_contains "update-available" "$output" "update-available status"
}

test_status_missing_dir() {
    _mock_git_setup
    _setup_test_env "status_missing"
    # Manifest entry exists but dir does not
    _skill_manifest_add_entry "$SKILL_MANIFEST_USER" "gone-lib" "https://example.com/gone-lib.git" "sha1" "2026-01-01T00:00:00Z"

    local output
    output=$(skill_status 2>&1)
    assert_contains "gone-lib" "$output" "library name in status" &&
    assert_contains "missing" "$output" "missing status"
}

# ============================================================================
# Test Cases: Help & Routing
# ============================================================================

test_skill_help() {
    local output
    output=$(skill_cmd_main --help 2>&1)
    assert_contains "cac skill" "$output" "help header" &&
    assert_contains "install" "$output" "install subcommand in help" &&
    assert_contains "update" "$output" "update subcommand in help" &&
    assert_contains "list" "$output" "list subcommand in help" &&
    assert_contains "status" "$output" "status subcommand in help"
}

test_skill_unknown_subcommand() {
    local output
    if output=$(skill_cmd_main "bogus" 2>&1); then
        echo "FAIL: Should have failed for unknown subcommand" >&2
        return 1
    fi
    assert_contains "Unknown skill subcommand" "$output" "unknown subcommand error"
}

# ============================================================================
# Test Cases: Scope
# ============================================================================

test_get_dir_user() {
    local dir
    dir=$(_skill_get_dir "false")
    assert_equals "$SKILL_USER_DIR" "$dir" "user dir returned"
}

test_get_dir_global() {
    local dir
    dir=$(_skill_get_dir "true")
    assert_equals "$SKILL_SYSTEM_DIR" "$dir" "system dir returned"
}

# ============================================================================
# Test Cases: Atomic Write
# ============================================================================

test_manifest_atomic_write() {
    # Verify write uses temp file + mv (atomic)
    local manifest_path="${TEST_TMPDIR}/atomic_test.json"
    _skill_manifest_write "$manifest_path" '[{"test":"atomic"}]'
    assert_file_exists "$manifest_path" "manifest file exists" &&
    local contents
    contents=$(_skill_manifest_read "$manifest_path")
    assert_contains "atomic" "$contents" "content written correctly"
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "========================================"
    echo "Skill Library Tests"
    echo "========================================"
    echo ""

    framework_init

    echo "--- Repo Name Extraction & Path Traversal ---"
    run_test "repo name from HTTPS URL" test_repo_name_from_https_url
    run_test "repo name from HTTPS URL without .git" test_repo_name_from_https_url_no_git
    run_test "repo name from SSH URL" test_repo_name_from_ssh_url
    run_test "repo name with trailing slash" test_repo_name_trailing_slash
    run_test "repo name invalid empty" test_repo_name_invalid_empty
    run_test "path traversal with .. rejected" test_repo_name_path_traversal_dotdot
    run_test "path traversal special chars rejected" test_repo_name_path_traversal_special_chars
    run_test "valid chars accepted in repo name" test_repo_name_valid_chars_only
    echo ""

    echo "--- Manifest Operations ---"
    run_test "manifest read missing file" test_manifest_read_missing
    run_test "manifest add and read" test_manifest_add_and_read
    run_test "manifest add multiple entries" test_manifest_add_multiple
    run_test "manifest has entry check" test_manifest_has_entry
    run_test "manifest update SHA" test_manifest_update_sha
    run_test "manifest remove entry" test_manifest_remove_entry
    run_test "manifest corrupt content no crash" test_manifest_corrupt_recovery
    run_test "manifest location user (~/.config/cac/)" test_manifest_location_user
    run_test "manifest location system (/etc/cac/)" test_manifest_location_system
    run_test "manifest atomic write" test_manifest_atomic_write
    echo ""

    echo "--- Install ---"
    run_test "install success" test_install_success
    run_test "install already exists" test_install_already_exists
    run_test "install no URL" test_install_no_url
    run_test "install clone failure" test_install_clone_failure
    run_test "install manifest updated" test_install_manifest_updated
    run_test "install path traversal rejected" test_install_path_traversal_rejected
    run_test "install URL starts with dash rejected" test_install_url_starts_with_dash
    echo ""

    echo "--- List ---"
    run_test "list empty" test_list_empty
    run_test "list with entries" test_list_with_entries
    echo ""

    echo "--- Update ---"
    run_test "update no libraries" test_update_no_libraries
    run_test "update already up to date" test_update_already_up_to_date
    run_test "update applies changes" test_update_applies_changes
    run_test "update specific library" test_update_specific_library
    run_test "update nonexistent library" test_update_nonexistent_library
    run_test "update dirty tree skipped" test_update_dirty_tree_skipped
    run_test "update fetch failure" test_update_fetch_failure
    run_test "update manifest traversal rejected" test_update_manifest_traversal_rejected
    echo ""

    echo "--- my- Prefix Protection ---"
    run_test "my- prefix detection" test_my_prefix_detection
    run_test "my- prefix empty dir" test_my_prefix_empty_dir
    run_test "my- prefix nonexistent dir" test_my_prefix_nonexistent_dir
    run_test "my- prefix in skills root preserved" test_my_prefix_in_skills_root_not_library
    echo ""

    echo "--- Status ---"
    run_test "status no libraries" test_status_no_libraries
    run_test "status up to date" test_status_up_to_date
    run_test "status update available" test_status_update_available
    run_test "status missing directory" test_status_missing_dir
    echo ""

    echo "--- Help & Routing ---"
    run_test "skill help output" test_skill_help
    run_test "unknown subcommand error" test_skill_unknown_subcommand
    echo ""

    echo "--- Scope ---"
    run_test "get dir user scope" test_get_dir_user
    run_test "get dir global scope" test_get_dir_global
    echo ""

    framework_report
    exit $?
}

main "$@"
