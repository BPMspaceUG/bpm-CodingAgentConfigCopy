#!/usr/bin/env bash
# provision.sh - USB stick provisioning script for fresh Ubuntu machines
#
# Usage: sudo bash /path/to/provision.sh
#
# Requires: .env file in the same directory as this script
# Does NOT require curl, git, or any other tools pre-installed
#
# Steps:
#   1. Install system dependencies (curl, zip, unzip, git, tmux)
#   2. Install cac via pipe installer from GitHub (--global)
#   3. cac env install --global --yes
#   4. cac pull
#   5. cac test
#   6. cac skill install BPM library
#   7. cac skill install ICO library
#   8. Install Tailscale

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Must run as root
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run with sudo: sudo bash $0"

# Find .env next to this script
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR=""

# Fallback: /proc fd 255 (handles broken PWD from sudo on mounted drives)
if [[ -z "$SCRIPT_DIR" || ! -f "${SCRIPT_DIR}/.env" ]]; then
    if [[ -e /proc/$$/fd/255 ]]; then
        resolved="$(readlink /proc/$$/fd/255 2>/dev/null)" || true
        [[ -n "$resolved" && -f "$resolved" ]] && SCRIPT_DIR="$(dirname "$resolved")"
    fi
fi

[[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/.env" ]] || \
    die ".env file not found next to provision.sh"

# Validate .env before sourcing as root: must be a regular file, not a symlink,
# values must not contain shell expansion ($, backticks, $())
ENV_FILE="${SCRIPT_DIR}/.env"
[[ ! -L "$ENV_FILE" ]] || die ".env must not be a symlink"
if grep -qvE '^\s*(#|$|[A-Za-z_][A-Za-z_0-9]*=)' "$ENV_FILE"; then
    die ".env contains invalid lines (only KEY=VALUE and comments allowed)"
fi
if grep -qE '[$`]' "$ENV_FILE"; then
    die ".env contains shell expansion characters (\$, \`) — not safe to source as root"
fi

# Read config — safe after validation above
# shellcheck source=/dev/null
source "$ENV_FILE"

[[ -n "${CAC_BACKEND:-}" ]]       || die "CAC_BACKEND not set in .env"
[[ -n "${CAC_GOKAPI_URL:-}" ]]    || die "CAC_GOKAPI_URL not set in .env"
[[ -n "${CAC_GOKAPI_API_KEY:-}" ]] || die "CAC_GOKAPI_API_KEY not set in .env"

# Pin to main branch — change to a release tag for production lockdown
# e.g. INSTALLER_URL="https://raw.githubusercontent.com/.../v1.0.0/install.sh"
INSTALLER_URL="https://raw.githubusercontent.com/BPMspaceUG/bpm-CodingAgentConfigCopy/main/install.sh"
BPM_SKILL="https://github.com/BPMspaceUG/bpm-claude-global-agent-skill-library.git"
ICO_SKILL="https://github.com/International-Certification-Org/ico-claude-global-agent-skill-library.git"

echo ""
echo "====================================="
echo "   cac - USB Stick Provisioning"
echo "====================================="
echo ""

# Step 1: Install system dependencies
info "[Step 1/8] Installing system dependencies..."
apt-get update -qq
apt-get install -y curl zip unzip git tmux
success "[Step 1/8] Dependencies installed"

# Step 2: Install cac via pipe installer from GitHub
info "[Step 2/8] Installing cac (global)..."
curl -fsSL "$INSTALLER_URL" | bash -s -- \
    --global \
    --backend "$CAC_BACKEND" \
    --url "$CAC_GOKAPI_URL" \
    --api-key "$CAC_GOKAPI_API_KEY"
success "[Step 2/8] cac installed"

# Step 3: Install AI tool environments
info "[Step 3/8] Installing AI tool environments..."
cac env install --global --yes || echo "[WARN] Some AI tools had issues (continuing)"
success "[Step 3/8] AI tool environments done"

# Step 4: Pull latest config bundle
info "[Step 4/8] Pulling latest configuration..."
cac pull || echo "[WARN] Pull failed (continuing)"
success "[Step 4/8] Pull done"

# Step 5: Test AI tool connectivity
info "[Step 5/8] Testing AI tool connectivity..."
cac test || echo "[WARN] Some tests failed (continuing)"
success "[Step 5/8] Tests done"

# Step 6: Install BPM skill library
info "[Step 6/8] Installing BPM skill library..."
cac skill install "$BPM_SKILL" --global --yes || echo "[WARN] BPM skill install failed (continuing)"
success "[Step 6/8] BPM skills done"

# Step 7: Install ICO skill library
info "[Step 7/8] Installing ICO skill library..."
cac skill install "$ICO_SKILL" --global --yes || echo "[WARN] ICO skill install failed (continuing)"
success "[Step 7/8] ICO skills done"

# Step 8: Install Tailscale via signed apt repository
info "[Step 8/8] Installing Tailscale..."
# Tailscale official apt repo — signed package, no curl|bash
# See: https://tailscale.com/kb/1031/install-linux
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
apt-get update -qq
apt-get install -y tailscale || echo "[WARN] Tailscale install failed (continuing)"
success "[Step 8/8] Tailscale done"

echo ""
echo "====================================="
success "Provisioning complete!"
echo "====================================="
echo ""
