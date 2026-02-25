# cac - Coding Agent Config

A production-grade CLI tool for managing versioned ZIP-based configuration bundles for AI coding assistants. Supports centralized storage with Gokapi backend or local filesystem.

## Supported Tools

- **Claude Code** (Anthropic)
- **Codex CLI** (OpenAI)
- **Gemini CLI** (Google)
- **Mistral Vibe** (<a href="https://mistral.ai" target="_blank">Mistral AI</a>)

## Installation

### Quick Install (curl|bash)

#### User-local Install (no root required)

```bash
curl -fsSL https://raw.githubusercontent.com/BPMspaceUG/bpm-CodingAgentConfigCopy/main/install.sh | bash
```

#### System-wide Install (requires root)

```bash
curl -fsSL https://raw.githubusercontent.com/BPMspaceUG/bpm-CodingAgentConfigCopy/main/install.sh | sudo bash
```

### Installation Location Flags

Control where cac is installed with explicit flags:

| Flag | Behavior |
|------|----------|
| `--user` | Install to `~/.local/bin` only (works even as root) |
| `--global` | Install to `/usr/local/bin` only (requires root) |
| `--all` | Install to both locations (requires root) |
| (no flag) | Auto-detect: root→global, non-root→user (or prompt in interactive mode) |

```bash
# Explicit user-local install (even when running as root)
sudo ./install.sh --user

# Explicit system-wide install
sudo ./install.sh --global

# Install to both locations
sudo ./install.sh --all

# With curl (non-interactive)
curl -fsSL URL | bash -s -- --user
curl -fsSL URL | sudo bash -s -- --global
```

### Non-Interactive Configuration

For automated installations, provide configuration via CLI arguments:

```bash
# Gokapi backend
curl -fsSL URL | bash -s -- --backend gokapi --url https://gokapi.example.com --api-key SECRET

# Local backend
curl -fsSL URL | bash -s -- --backend local --storage /path/to/bundles

# Combined with location flag
curl -fsSL URL | bash -s -- --user --backend local
```

Or via environment variables:

```bash
export CAC_BACKEND=gokapi
export CAC_GOKAPI_URL=https://gokapi.example.com
export CAC_GOKAPI_API_KEY=your-api-key
curl -fsSL URL | bash
```

### Manual Install from Repository

```bash
git clone https://github.com/BPMspaceUG/bpm-CodingAgentConfigCopy.git
cd bpm-CodingAgentConfigCopy
./install.sh
```

### Uninstall

```bash
# User-local
./uninstall.sh

# System-wide
sudo ./uninstall.sh

# Complete removal including config
./uninstall.sh --purge
```

## Configuration

Before using cac, create a `.env` configuration file:

**User-local:** `~/.config/cac/.env` (takes precedence)
**System-wide:** `/etc/cac/.env` (fallback for all users)

```bash
# Copy the example and edit
cp .env.example ~/.config/cac/.env
chmod 600 ~/.config/cac/.env
```

### Config Precedence

If both user and system config exist, the **user config takes precedence** and a warning is shown:
```
ATTENTION: User config overrides central system config!
  Using:    /home/user/.config/cac/.env
  Ignoring: /etc/cac/.env
```

For centralized management, use only the system-wide config (`/etc/cac/.env`).

### Required Settings

```bash
# Backend: local or gokapi
CAC_BACKEND=local

# For local backend
CAC_LOCAL_STORAGE=/path/to/bundle/storage

# For gokapi backend
CAC_GOKAPI_URL=https://your-gokapi-instance.example.com
CAC_GOKAPI_API_KEY=your-api-key-here
CAC_GOKAPI_EXPIRY_DAYS=7  # Max 7 days (enforced for security)
```

### Bundle Expiration (Gokapi Backend)

For security, all bundles uploaded to Gokapi have a maximum TTL of 7 days:
- Values > 7 are automatically capped to 7 with a warning
- Value 0 (unlimited) is treated as 7 days
- Expired bundles are automatically deleted by Gokapi

## Usage

Every command prints a version banner (`cac v<VERSION>`) as the first line of output. Use `cac --version` for version-only output.

### Push (Upload) Configuration

```bash
# Bundle and upload current user's config
cac push

# Bundle another user's config (requires root)
sudo cac push --user ubuntu
```

### Pull (Download) Configuration

```bash
# Download and apply the globally newest bundle
cac pull

# Filter by tool or user
cac pull --tool claude
cac pull --user bob

# Apply to another user (requires root)
sudo cac pull --user bob

# Pull to ALL users with AI tool configs (requires root)
sudo cac pull --all
```

Without `--tool` or `--user` flags, `cac pull` fetches the **globally newest** bundle across all hosts and users. Use `--tool` and/or `--user` to narrow the search.

The `--all` flag scans `/home/*` and `/root` for users with AI tool config directories (`.claude`, `.codex`, `.gemini`) or files (`.claude.json`) and pulls the matching bundle for each.

### List Bundles

```bash
# List all available bundles
cac list

# Filter by tool or user
cac list --tool codex
cac list --user ubuntu
cac list --tool claude --user deploy
```

### Pull Specific Bundle

```bash
# By name or partial match
cac pull CodingAgentConfig_myhost_user_250111-120000.zip
cac pull mybundle
```

**Note:** `cac get` is a silent alias for `cac pull` and works identically.

### Check/Test Credentials

The `check` command verifies that AI tool CLI subscriptions work by running each CLI with a test prompt. A spinner shows progress during the check (up to 30 seconds per tool).

```bash
# Verify all configured tools for current user
cac check

# Verify specific tool only
cac check claude
cac check codex
cac check gemini
cac check mistral

# Verify another user's credentials (requires root)
sudo cac check --user ubuntu
```

**Note:** `cac test` is an alias for `cac check` for backward compatibility.

Results are cached for 5 minutes to avoid repeated checks.

### Self-Update

```bash
# Update cac to the latest version
cac update

# Check if an update is available (without installing)
cac update --check

# System-wide update (requires root)
sudo cac update
```

### Push with Credential Verification

By default, `cac push` runs credential verification before uploading. Use `--skip-check` to bypass:

```bash
# Normal push (runs check first, aborts if any fail)
cac push

# Skip credential verification (for emergency uploads)
cac push --skip-check
```

### Manage AI Tool Environments

The `env` subcommand installs, updates, and checks status of AI coding tool environments.

```bash
# Show status of all AI tools
cac env status

# Machine-readable status (tab-separated)
cac env status --parseable

# Install tools interactively (prompts for selection)
cac env install

# Install specific tool
cac env install claude
cac env install codex
cac env install gemini
cac env install mistral
cac env install continuous-claude

# Install with --yes to skip confirmation prompts
cac env install claude --yes

# Install Claude Code with tmux teammate mode
cac env install claude --tmux

# Global scope (requires root)
sudo cac env install --global             # Interactive tool selection
sudo cac env install claude --global      # Install specific tool globally

# Update tools
cac env update              # Update all installed tools
cac env update codex        # Update specific tool
```

**Scope flags:**

| Flag | Behavior |
|------|----------|
| `--user` | User-local install (default). npm tools use `~/.local` prefix |
| `--global` | System-wide install (requires root). npm tools use global prefix |
| `--yes`, `-y` | Skip confirmation prompts (for curl-based installers) |
| `--tmux` | Set Claude Code `teammateMode: "tmux"` in `settings.json` (install only) |

The `--tmux` flag configures Claude Code to display agent teammates as tmux panes instead of background processes. Requires tmux to be installed; logs a warning and skips `teammateMode` if tmux is missing.

`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is set in `settings.json` during Claude Code install (requires `python3` for JSON merge; logs a warning if unavailable).

**Note:** Scope flags control npm install prefix. Curl-based installers (Claude, continuous-claude) use their own install logic and may install to different locations.

**Tools registry:**

| Tool | Install Method | Optional |
|------|---------------|----------|
| Claude Code | curl installer | No |
| Codex CLI | npm | No |
| Gemini CLI | npm | No |
| continuous-claude | curl installer | Yes |
| Mistral Vibe | curl installer | No |

**Automated installation with cac installer:**

```bash
# Install cac + AI tools for current user (non-interactive)
curl -fsSL URL | CAC_ENV_INSTALL=user bash

# Install cac + AI tools system-wide (non-interactive)
curl -fsSL URL | CAC_ENV_INSTALL=global sudo bash
```

### Help

```bash
cac --help
cac --version
```

## Bundle Naming Convention

Bundles follow the naming pattern:
```
CodingAgentConfig_<HOST>_<USER>_<YYMMDD-HHMMSS>.zip
```

Example: `CodingAgentConfig_prod-server-01_ubuntu_250111-143022.zip`

## Configuration Files Managed

### Credential Files (portable across hosts)

| Tool | Files |
|------|-------|
| Claude Code | `.claude.json`, `.claude/.credentials.json` |
| Codex CLI | `.codex/auth.json` |
| Gemini CLI | `.gemini/oauth_creds.json`, `.gemini/google_accounts.json`, `.gemini/settings.json`, `.gemini/state.json`, `.gemini/installation_id`, `.config/gcloud/application_default_credentials.json` |
| Mistral Vibe | `.vibe/.env`, `.vibe/config.toml` |

### Settings Files (host+user-specific, NOT portable)

| Tool | Files |
|------|-------|
| Claude Code | `.claude/settings.json` |

Settings are always included in `cac push` bundles but only extracted by `cac pull` when the bundle's hostname **AND** username match the target system. This prevents host-specific configuration (e.g. `teammateMode: "tmux"`, agent teams env vars) from being overwritten by bundles originating from different hosts.

**Note:** Host+user matching relies on the bundle filename convention (`CodingAgentConfig_<HOST>_<USER>_<TIMESTAMP>.zip`). If a bundle is renamed or pulled by Gokapi file ID instead of its original filename, settings extraction is skipped as a safety measure.

## Security

- User `.env` file must have 600 permissions (owner read/write only)
- System `.env` file (`/etc/cac/.env`) allows 644 for shared access
- Extracted configuration files are set to 600 permissions
- ZIP extraction validates against path traversal attacks (zip-slip protection)
- Credentials are never logged or echoed
- Temporary files use secure permissions and are cleaned up
- Settings files are host+user-guarded: only extracted when bundle origin matches target

## Installation Paths

| Mode | Binary | Libraries | Config |
|------|--------|-----------|--------|
| User-local | `~/.local/bin/cac` | `~/.local/lib/cac/` | `~/.config/cac/.env` |
| System-wide | `/usr/local/bin/cac` | `/usr/local/lib/cac/` | `/etc/cac/.env` |

## Development

### Running Tests

```bash
# Install test dependencies
sudo apt-get install zip unzip

# Run all tests
./tests/run_tests.sh

# Run specific test suite
./tests/test_bundle.sh
./tests/test_security.sh
./tests/test_integration.sh
./tests/test_env_settings.sh
```

### Linting

```bash
shellcheck bin/cac lib/*.sh install.sh uninstall.sh tests/*.sh
```

## Multi-Agent Workflow

This project uses a multi-agent development workflow:

- **Claude** - Primary orchestrator and main executor
- **Codex** - Primary review and approval authority
- **Gemini** - Consensus and fallback reviewer

### Segregation of Duty (SoD)

No LLM may review or approve work it has performed itself. If both Codex and Gemini are unavailable, Claude may self-review only with documented exception (see [agent.md](agent.md)).

### Consensus and Fallback

When Claude and Codex disagree, Gemini provides independent assessment.

**Rate-limit fallback:**
- Codex unavailable: gpt-5.1-codex-mini → Gemini → Claude (with SoD exception)
- Gemini unavailable: gemini-2.5-flash-lite → Codex → Claude (with SoD exception)
- Claude unavailable: STOP - no release allowed

### Required Approvals Before Git Push

1. PLAN AND AGENT/SKILL ASSIGNMENT APPROVED
2. IMPLEMENTATION APPROVED
3. TEST DESIGN APPROVED
4. TEST RESULTS APPROVED
5. DOCUMENTATION UPDATED AND CONSISTENT APPROVED

For detailed policies, see:
- [agent.md](agent.md) - Full SoD rules, rate-limit handling, approval workflow
- [gemini.md](gemini.md) - Consensus process, fallback logic, exception handling
- [CLAUDE.md](CLAUDE.md) - Technical reference for Claude Code

## Legacy Script

The original `cpaiagentconfig.sh` script is still available for simple local copy operations between users on the same machine.

## License

MIT
