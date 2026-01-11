# cac - Coding Agent Config

A production-grade CLI tool for managing versioned ZIP-based configuration bundles for AI coding assistants. Supports centralized storage with Gokapi backend or local filesystem.

## Supported Tools

- **Claude Code** (Anthropic)
- **Codex CLI** (OpenAI)
- **Gemini CLI** (Google)

## Installation

### Quick Install (curl|bash)

```bash
# User-local install (no root required)
curl -fsSL https://raw.githubusercontent.com/BPMspaceUG/bpm-CodingAgentConfigCopy/main/install.sh | bash

# System-wide install (requires root)
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
```

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

### Test API Connectivity

```bash
# Test current user's AI tool credentials
cac test

# Test another user (requires root)
sudo cac test --user ubuntu
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

## Legacy Script

The original `cpaiagentconfig.sh` script is still available for simple local copy operations between users on the same machine.

## License

MIT
