# cac - Coding Agent Config

A production-grade CLI tool for managing versioned ZIP-based configuration bundles for AI coding assistants. Supports centralized storage with Gokapi backend or local filesystem.

## Supported Tools

- **Claude Code** (Anthropic)
- **Codex CLI** (OpenAI)
- **Gemini CLI** (Google)

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

**User-local:** `~/.config/cac/.env`
**System-wide:** `/etc/cac/.env`

```bash
# Copy the example and edit
cp .env.example ~/.config/cac/.env
chmod 600 ~/.config/cac/.env
```

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

### Push (Upload) Configuration

```bash
# Bundle and upload current user's config
cac push

# Bundle another user's config (requires root)
sudo cac push --user ubuntu
```

### Pull (Download) Configuration

```bash
# Download and apply newest bundle for current user/host
cac pull

# Apply to another user (requires root)
sudo cac pull --user bob
```

### List Bundles

```bash
# List all available bundles
cac list

# Filter by host or user
cac list --host prod-server-01
cac list --user ubuntu
cac list --host myhost --user deploy
```

### Get Specific Bundle

```bash
# Interactive selection
cac get

# By name or partial match
cac get CodingAgentConfig_myhost_user_250111-120000.zip
```

### Check/Test Credentials

The `check` command verifies that AI tool credentials actually work by making real API calls.

```bash
# Verify all configured tools for current user
cac check

# Verify specific tool only
cac check claude
cac check codex
cac check gemini

# Verify another user's credentials (requires root)
sudo cac check --user ubuntu
```

**Note:** `cac test` is an alias for `cac check` for backward compatibility.

### Push with Credential Verification

By default, `cac push` runs credential verification before uploading. Use `--skip-check` to bypass:

```bash
# Normal push (runs check first, aborts if any fail)
cac push

# Skip credential verification (for emergency uploads)
cac push --skip-check
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

| Tool | Files |
|------|-------|
| Claude Code | `.claude.json`, `.claude/.credentials.json` |
| Codex CLI | `.codex/auth.json` |
| Gemini CLI | `.gemini/oauth_creds.json`, `.gemini/google_accounts.json`, `.gemini/settings.json`, `.gemini/state.json`, `.gemini/installation_id`, `.config/gcloud/application_default_credentials.json` |

## Security

- `.env` file must have 600 permissions (owner read/write only)
- Extracted configuration files are set to 600 permissions
- ZIP extraction validates against path traversal attacks (zip-slip protection)
- API keys and credentials are never logged or echoed
- Temporary files use secure permissions and are cleaned up

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
