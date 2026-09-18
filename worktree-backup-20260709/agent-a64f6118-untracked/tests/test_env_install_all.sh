#!/usr/bin/env bash
# tests/test_env_install_all.sh - Tests for 'cac env install all' feature (Issue #64)
#
# Verifies that:
# - env_get_core_tools excludes optional tools
# - env_get_all_tools includes optional tools
# - "all" keyword in env_cmd_install routes to env_install_all_tools
# - env_install_all uses core tools only
# - env_install_all_tools uses all tools including optional

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source test framework
source "${SCRIPT_DIR}/test_framework.sh"

# Source the env module (and its dependencies)
source "${PROJECT_DIR}/lib/logging.sh"
source "${PROJECT_DIR}/lib/env.sh"

# ============================================================================
# Test Functions
# ============================================================================

test_core_tools_excludes_optional() {
    local core_tools
    core_tools=$(env_get_core_tools)

    # Core tools should NOT contain optional tools
    if echo "$core_tools" | grep -q "^continuous-claude$"; then
        echo "env_get_core_tools should not include continuous-claude" >&2
        return 1
    fi
    if echo "$core_tools" | grep -q "^playwright$"; then
        echo "env_get_core_tools should not include playwright" >&2
        return 1
    fi

    # Core tools should contain core tools
    if ! echo "$core_tools" | grep -q "^claude$"; then
        echo "env_get_core_tools should include claude" >&2
        return 1
    fi
    if ! echo "$core_tools" | grep -q "^codex$"; then
        echo "env_get_core_tools should include codex" >&2
        return 1
    fi

    return 0
}

test_all_tools_includes_optional() {
    local all_tools
    all_tools=$(env_get_all_tools)

    # All tools should contain optional tools
    if ! echo "$all_tools" | grep -q "^continuous-claude$"; then
        echo "env_get_all_tools should include continuous-claude" >&2
        return 1
    fi
    if ! echo "$all_tools" | grep -q "^playwright$"; then
        echo "env_get_all_tools should include playwright" >&2
        return 1
    fi

    # All tools should also contain core tools
    if ! echo "$all_tools" | grep -q "^claude$"; then
        echo "env_get_all_tools should include claude" >&2
        return 1
    fi

    return 0
}

test_all_tools_superset_of_core() {
    local all_tools core_tools
    all_tools=$(env_get_all_tools)
    core_tools=$(env_get_core_tools)

    # Every core tool must be in all tools
    while IFS= read -r tool; do
        if ! echo "$all_tools" | grep -q "^${tool}$"; then
            echo "Core tool '$tool' missing from env_get_all_tools" >&2
            return 1
        fi
    done <<< "$core_tools"

    # All tools must have MORE entries than core tools
    local all_count core_count
    all_count=$(echo "$all_tools" | wc -l)
    core_count=$(echo "$core_tools" | wc -l)

    if [[ "$all_count" -le "$core_count" ]]; then
        echo "env_get_all_tools ($all_count) should have more tools than env_get_core_tools ($core_count)" >&2
        return 1
    fi

    return 0
}

test_env_is_optional_correct() {
    # Optional tools should return 0 (true)
    if ! env_is_optional "continuous-claude"; then
        echo "continuous-claude should be optional" >&2
        return 1
    fi
    if ! env_is_optional "playwright"; then
        echo "playwright should be optional" >&2
        return 1
    fi

    # Core tools should return 1 (false)
    if env_is_optional "claude"; then
        echo "claude should NOT be optional" >&2
        return 1
    fi
    if env_is_optional "codex"; then
        echo "codex should NOT be optional" >&2
        return 1
    fi

    return 0
}

test_all_keyword_not_valid_tool() {
    # "all" is a keyword, not a registered tool name
    if env_validate_tool "all"; then
        echo "'all' should NOT be a valid tool name" >&2
        return 1
    fi
    return 0
}

test_env_install_all_tools_function_exists() {
    # Verify the function exists and is callable
    if ! declare -f env_install_all_tools &>/dev/null; then
        echo "env_install_all_tools function does not exist" >&2
        return 1
    fi
    return 0
}

test_env_cmd_install_routes_all_keyword() {
    # Override env_install_all_tools to track whether it was called
    local was_called="false"
    env_install_all_tools() {
        was_called="true"
        return 0
    }

    # Simulate: cac env install all
    # _env_parse_scope_args puts "all" into ENV_PARSED_TOOLS
    env_cmd_install "all" 2>/dev/null || true

    if [[ "$was_called" != "true" ]]; then
        echo "env_cmd_install 'all' should route to env_install_all_tools" >&2
        return 1
    fi

    return 0
}

test_env_cmd_install_no_args_does_not_route_all() {
    # Override to track calls
    local all_tools_called="false"
    local core_called="false"
    env_install_all_tools() {
        all_tools_called="true"
        return 0
    }
    env_install_all() {
        core_called="true"
        return 0
    }

    # Simulate non-interactive: cac env install --yes (no tool arg)
    env_cmd_install "--yes" 2>/dev/null </dev/null || true

    if [[ "$all_tools_called" == "true" ]]; then
        echo "env_cmd_install with no tool args should NOT call env_install_all_tools" >&2
        return 1
    fi

    return 0
}

# ============================================================================
# Main
# ============================================================================

framework_init

echo "========================================"
echo "env install all Tests (Issue #64)"
echo "========================================"
echo ""

run_test "env_get_core_tools excludes optional tools" test_core_tools_excludes_optional
run_test "env_get_all_tools includes optional tools" test_all_tools_includes_optional
run_test "env_get_all_tools is superset of env_get_core_tools" test_all_tools_superset_of_core
run_test "env_is_optional returns correct values" test_env_is_optional_correct
run_test "'all' is not a valid registered tool name" test_all_keyword_not_valid_tool
run_test "env_install_all_tools function exists" test_env_install_all_tools_function_exists
run_test "env_cmd_install routes 'all' keyword to env_install_all_tools" test_env_cmd_install_routes_all_keyword
run_test "env_cmd_install without args does not trigger all-tools install" test_env_cmd_install_no_args_does_not_route_all

echo ""
framework_report
