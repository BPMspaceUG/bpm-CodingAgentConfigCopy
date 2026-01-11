#!/usr/bin/env zsh
set -euo pipefail

# ------------------------------------------------------------
# cpaiagentconfig.sh <destination-user> [claude|codex|gemini|all]
# cpaiagentconfig.sh --test [user]
#
# Copies minimal AI agent auth/config from ubuntu -> <user>
# Creates backup if destination file exists
#
# Usage:
#   sudo ./cpaiagentconfig.sh rob          # copy all
#   sudo ./cpaiagentconfig.sh rob claude   # only claude
#   sudo ./cpaiagentconfig.sh rob codex    # only codex
#   sudo ./cpaiagentconfig.sh rob gemini   # only gemini
#   ./cpaiagentconfig.sh --test            # test current user
#   sudo ./cpaiagentconfig.sh --test rob   # test as user rob
# ------------------------------------------------------------

SRC_USER="ubuntu"
TS="$(date +%y%m%d-%H%M%S)"

# ---- help --------------------------------------------------

show_help() {
  cat <<'EOF'
cpaiagentconfig.sh - Copy AI agent credentials between users

USAGE:
  sudo ./cpaiagentconfig.sh <user> [tool]    Copy credentials to user
  ./cpaiagentconfig.sh --test [user]         Test API connectivity
  ./cpaiagentconfig.sh --help                Show this help

COPY MODE:
  sudo ./cpaiagentconfig.sh rob              Copy all (claude, codex, gemini)
  sudo ./cpaiagentconfig.sh rob claude       Copy only Claude credentials
  sudo ./cpaiagentconfig.sh rob codex        Copy only Codex credentials
  sudo ./cpaiagentconfig.sh rob gemini       Copy only Gemini credentials

TEST MODE:
  ./cpaiagentconfig.sh --test                Test current user
  sudo ./cpaiagentconfig.sh --test rob       Test as user rob

TOOLS:
  claude   - Claude Code (Anthropic)
  codex    - Codex CLI (OpenAI)
  gemini   - Gemini CLI (Google)
  all      - All tools (default)

NOTES:
  - Source user is always 'ubuntu'
  - Existing files are backed up with timestamp
  - Requires root for copy mode and testing other users
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  show_help
  exit 0
fi

# ---- test mode ---------------------------------------------

run_tests() {
  local test_user="${1:-$(whoami)}"
  local use_sudo=false

  if [[ "$test_user" != "$(whoami)" ]]; then
    [[ "$EUID" -eq 0 ]] || {
      print "ERROR: must be root to test as another user" >&2
      exit 1
    }
    use_sudo=true
  fi

  print "=== Testing AI Tools for user: $test_user ==="
  print ""

  run_cmd() {
    if $use_sudo; then
      sudo -u "$test_user" "$@"
    else
      "$@"
    fi
  }

  # Claude test
  print -- "--- Claude Code ---"
  if run_cmd claude -p "Antworte nur mit: CLAUDE_OK" --dangerously-skip-permissions 2>/dev/null | grep -q "CLAUDE_OK"; then
    print -- "✓ Claude: OK"
  else
    print -- "✗ Claude: FAILED"
  fi
  print ""

  # Codex test
  print -- "--- Codex ---"
  if run_cmd codex exec "Respond only with the text: CODEX_OK" --skip-git-repo-check 2>/dev/null | grep -q "CODEX_OK"; then
    print -- "✓ Codex: OK"
  else
    print -- "✗ Codex: FAILED"
  fi
  print ""

  # Gemini test
  print -- "--- Gemini ---"
  if run_cmd gemini -p "Respond only with: GEMINI_OK" 2>/dev/null | grep -q "GEMINI_OK"; then
    print -- "✓ Gemini: OK"
  else
    print -- "✗ Gemini: FAILED"
  fi
  print ""

  print "=== Test Complete ==="
}

# Check for --test flag
if [[ "${1:-}" == "--test" ]]; then
  run_tests "${2:-}"
  exit 0
fi

# ---- normal copy mode --------------------------------------

[[ $# -ge 1 ]] || {
  print "Usage: sudo $0 <destination-user> [claude|codex|gemini|all]" >&2
  print "       $0 --test [user]" >&2
  exit 1
}

DST_USER="$1"
TOOL="${2:-all}"

[[ "$EUID" -eq 0 ]] || {
  print "ERROR: must be run as root" >&2
  exit 1
}

# Validate tool parameter
if [[ "$TOOL" != "all" && "$TOOL" != "claude" && "$TOOL" != "codex" && "$TOOL" != "gemini" ]]; then
  print "ERROR: invalid tool '$TOOL'. Use: claude, codex, gemini, or all" >&2
  exit 1
fi

# ---- resolve homes -----------------------------------------

SRC_HOME="$(getent passwd "$SRC_USER" | cut -d: -f6)"
DST_HOME="$(getent passwd "$DST_USER" | cut -d: -f6)"

[[ -d "$SRC_HOME" ]] || {
  print "ERROR: source user '$SRC_USER' does not exist" >&2
  exit 1
}

[[ -d "$DST_HOME" ]] || {
  print "ERROR: destination user '$DST_USER' does not exist" >&2
  exit 1
}

print "Source:      $SRC_USER ($SRC_HOME)"
print "Destination: $DST_USER ($DST_HOME)"
print "Tool:        $TOOL"
print ""

# ---- helper ------------------------------------------------

copy_file() {
  local rel="$1"
  local src="$SRC_HOME/$rel"
  local dst="$DST_HOME/$rel"

  [[ -f "$src" ]] || return 0

  print "→ copy $rel"

  install -d -m 700 -o "$DST_USER" -g "$DST_USER" "${dst:h}"

  # backup existing destination file
  if [[ -f "$dst" ]]; then
    local backup="${dst}.backup${TS}"
    print "  backup → ${backup:t}"
    cp -a "$dst" "$backup"
  fi

  cp -a "$src" "$dst"
  chown "$DST_USER:$DST_USER" "$dst"
  chmod 600 "$dst"
}

# ---- tool-specific copy functions --------------------------

copy_claude() {
  print "=== Claude Code ==="
  copy_file ".claude.json"
  copy_file ".claude/.credentials.json"
  print ""
}

copy_codex() {
  print "=== Codex CLI ==="
  copy_file ".codex/auth.json"
  print ""
}

copy_gemini() {
  print "=== Gemini CLI ==="
  copy_file ".gemini/oauth_creds.json"
  copy_file ".gemini/google_accounts.json"
  copy_file ".gemini/settings.json"
  copy_file ".gemini/state.json"
  copy_file ".gemini/installation_id"
  # Optional: Google ADC
  copy_file ".config/gcloud/application_default_credentials.json"
  print ""
}

# ---- execute based on tool parameter -----------------------

case "$TOOL" in
  claude)
    copy_claude
    ;;
  codex)
    copy_codex
    ;;
  gemini)
    copy_gemini
    ;;
  all)
    copy_claude
    copy_codex
    copy_gemini
    ;;
esac

print "Done."
