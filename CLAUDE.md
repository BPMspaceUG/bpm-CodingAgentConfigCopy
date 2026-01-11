# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`cac` (Coding Agent Config) is a production-grade CLI tool for managing versioned ZIP-based configuration bundles for AI coding assistants. It supports centralized storage via Gokapi backend or local filesystem, enabling configuration portability across hosts and users.

Supports: Claude Code, Codex CLI, and Gemini CLI.

## Quick Start

```bash
# Install
./install.sh

# Configure backend
cp .env.example ~/.config/cac/.env
chmod 600 ~/.config/cac/.env
# Edit ~/.config/cac/.env with backend settings

# Use
cac push                    # Bundle and upload current user's config
cac pull                    # Download and apply newest matching bundle
cac list                    # List available bundles
cac get [BUNDLE_ID]         # Download specific bundle
cac test                    # Test AI tool API connectivity
```

## Repository Structure

```
bpm-CodingAgentConfigCopy/
├── bin/
│   └── cac                      # Main CLI entrypoint
├── lib/
│   ├── backend_gokapi.sh        # Gokapi REST API integration
│   ├── backend_local.sh         # Local filesystem backend
│   ├── bundle.sh                # ZIP creation/extraction logic
│   ├── config.sh                # Configuration loading (.env)
│   ├── security.sh              # Permission checks, zip-slip protection
│   └── tools.sh                 # Tool-specific file mappings
├── tests/
│   ├── run_tests.sh             # Test runner
│   ├── test_bundle.sh           # Bundle tests
│   ├── test_security.sh         # Security validation tests
│   └── test_integration.sh      # End-to-end tests
├── install.sh                   # Bootstrap installer
├── uninstall.sh                 # Clean removal script
├── cpaiagentconfig.sh           # Legacy single-host copy script
├── .env.example                 # Configuration template
└── README.md                    # User documentation
```

## Architecture

### CLI Commands

| Command | Description |
|---------|-------------|
| `cac push [--user USER]` | Create ZIP bundle from user configs and upload to backend |
| `cac pull [--user USER]` | Download and apply newest bundle matching current host/user |
| `cac list [--host HOST] [--user USER]` | List available bundles with optional filtering |
| `cac get [BUNDLE_ID]` | Download and apply specific bundle (by ID or interactive) |
| `cac test [--user USER]` | Test AI tool API connectivity |

### Library Modules

- **config.sh**: Loads `.env` configuration, validates backend settings, checks file permissions
- **security.sh**: User access checks, file permission validation, zip-slip protection, secure temp directories
- **tools.sh**: Maps AI tools to their configuration files, collects/counts existing files
- **bundle.sh**: ZIP creation with correct naming convention, secure extraction with backups
- **backend_local.sh**: Local filesystem storage operations (upload, download, list, get_newest)
- **backend_gokapi.sh**: Gokapi REST API operations (upload, download, list, get_newest, delete)

### Bundle Naming Convention

```
CodingAgentConfig_<HOST>_<USER>_<YYMMDD-HHMMSS>.zip
```

### Configuration Files Managed

| Tool | Files |
|------|-------|
| Claude Code | `.claude.json`, `.claude/.credentials.json` |
| Codex CLI | `.codex/auth.json` |
| Gemini CLI | `.gemini/oauth_creds.json`, `.gemini/google_accounts.json`, `.gemini/settings.json`, `.gemini/state.json`, `.gemini/installation_id`, `.config/gcloud/application_default_credentials.json` |

## Installation Paths

| Mode | Binary | Libraries | Config |
|------|--------|-----------|--------|
| System-wide (root) | `/usr/local/bin/cac` | `/usr/local/lib/cac/` | `/etc/cac/.env` |
| User-local | `~/.local/bin/cac` | `~/.local/lib/cac/` | `~/.config/cac/.env` |

## Security Requirements

- `.env` must have 600 permissions; CLI refuses to run if too open
- Cross-user operations require root privileges
- ZIP extraction validates against path traversal attacks
- Extracted files set to 600 permissions
- Temporary files use secure permissions (700 directories, 600 files)

## Development

### Running Tests

```bash
# Install dependencies
sudo apt-get install zip unzip

# Run all tests
./tests/run_tests.sh

# Run specific suite
./tests/test_bundle.sh
./tests/test_security.sh
./tests/test_integration.sh
```

### Linting

```bash
shellcheck bin/cac lib/*.sh install.sh uninstall.sh tests/*.sh
```

### Key Functions

**bundle.sh:**
- `bundle_generate_filename(user)` - Creates standard filename
- `bundle_create(home_dir, output_file, tool)` - Creates ZIP bundle
- `bundle_extract(zip_file, home_dir, username)` - Extracts with security validation

**security.sh:**
- `security_check_user_access(target_user)` - Validates permissions
- `security_validate_zip(zip_file, target_dir)` - Zip-slip protection
- `security_mktemp_dir(prefix)` - Creates secure temp directory

**backend_local.sh / backend_gokapi.sh:**
- `backend_*_upload(bundle_file)` - Upload bundle
- `backend_*_download(bundle_id, output_file)` - Download bundle
- `backend_*_list([--host HOST] [--user USER])` - List bundles
- `backend_*_get_newest([--host HOST] [--user USER])` - Get newest matching
