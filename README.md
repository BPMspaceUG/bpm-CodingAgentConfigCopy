# cpaiagentconfig

A Zsh utility script for copying AI agent credentials and configurations between Unix/Linux user accounts.

## Supported Tools

- **Claude Code** (Anthropic)
- **Codex CLI** (OpenAI)
- **Gemini CLI** (Google)

## Installation

```bash
chmod +x cpaiagentconfig.sh
```

## Usage

### Copy Credentials

```bash
# Copy all credentials from ubuntu user to destination user
sudo ./cpaiagentconfig.sh <username>

# Copy only specific tool credentials
sudo ./cpaiagentconfig.sh <username> claude
sudo ./cpaiagentconfig.sh <username> codex
sudo ./cpaiagentconfig.sh <username> gemini
```

### Test API Connectivity

```bash
# Test current user's setup
./cpaiagentconfig.sh --test

# Test another user's setup (requires root)
sudo ./cpaiagentconfig.sh --test <username>
```

### Help

```bash
./cpaiagentconfig.sh --help
```

## Configuration Files Managed

| Tool | Files |
|------|-------|
| Claude Code | `.claude.json`, `.claude/.credentials.json` |
| Codex CLI | `.codex/auth.json` |
| Gemini CLI | `.gemini/oauth_creds.json`, `.gemini/google_accounts.json`, `.gemini/settings.json`, `.gemini/state.json`, `.gemini/installation_id`, `.config/gcloud/application_default_credentials.json` |

## Notes

- Source user is always `ubuntu`
- Requires root privileges for copy operations
- Existing files are backed up with timestamps before overwriting
- Uses strict error handling (`set -euo pipefail`)

## Linting

```bash
shellcheck cpaiagentconfig.sh
```

## License

MIT
