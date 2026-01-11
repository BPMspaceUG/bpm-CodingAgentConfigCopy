# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Zsh utility script (`cpaiagentconfig.sh`) for copying AI agent credentials and configurations between Unix/Linux user accounts. It supports three AI platforms: Claude Code, Codex CLI, and Gemini CLI.

## Usage

```bash
# Copy all credentials from ubuntu user to destination user
sudo ./cpaiagentconfig.sh <username>

# Copy only specific tool credentials
sudo ./cpaiagentconfig.sh <username> claude|codex|gemini

# Test API connectivity for current user
./cpaiagentconfig.sh --test

# Test another user's setup (requires root)
sudo ./cpaiagentconfig.sh --test <username>
```

## Architecture

The script is organized into these sections:

1. **Help section** (`show_help()`) - Usage documentation
2. **Test mode** (`run_tests()`) - API connectivity validation for each tool
3. **Copy setup** - Parameter validation, user home directory resolution, permission checks
4. **Helper functions** (`copy_file()`) - Core file copying with automatic timestamped backups
5. **Tool-specific copy functions** (`copy_claude()`, `copy_codex()`, `copy_gemini()`) - Handle each tool's config files
6. **Main execution** - Case statement routing

## Configuration Files Managed

- **Claude Code:** `.claude.json`, `.claude/.credentials.json`
- **Codex CLI:** `.codex/auth.json`
- **Gemini CLI:** `.gemini/oauth_creds.json`, `.gemini/google_accounts.json`, `.gemini/settings.json`, `.gemini/state.json`, `.gemini/installation_id`, `.config/gcloud/application_default_credentials.json`

## Development Notes

- No build step required - this is a standalone shell script
- Uses `set -euo pipefail` for strict error handling
- Copy operations require root privileges; existing files are backed up with timestamps before overwriting
- ShellCheck can be used for linting: `shellcheck cpaiagentconfig.sh`
