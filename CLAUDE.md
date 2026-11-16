# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`cac` (Coding Agent Config) is a production-grade CLI tool for managing versioned ZIP-based configuration bundles for AI coding assistants. It supports centralized storage via Gokapi backend or local filesystem, enabling configuration portability across hosts and users.

Supports: Claude Code, Codex CLI, Gemini CLI, and Mistral Vibe. OpenCode is supported for `check` / `push` / `pull`; its `env install` / `env update` path is still open (#80).

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
cac pull                    # Download and apply globally newest bundle
cac pull [BUNDLE_ID]        # Download and apply specific bundle
cac list                    # List available bundles
cac test                    # Test AI tool API connectivity
```

## Architecture

### CLI Commands

| Command | Description |
|---------|-------------|
| `cac push [--user USER] [--skip-check]` | Create ZIP bundle from user configs and upload to backend |
| `cac pull [BUNDLE_ID] [--tool TOOL] [--user USER]` | Download and apply bundle (globally newest, filtered, or specific) |
| `cac get` | Silent alias for `cac pull` (backward compatibility) |
| `cac list [--tool TOOL] [--user USER]` | List available bundles with optional filtering |
| `cac check [TOOL] [--user USER]` | Verify AI tool credentials work (real API calls) |
| `cac test [--user USER]` | Alias for check (backward compatibility) |
| `cac update [--check]` | Self-update cac to the latest version |
| `cac env status [--parseable]` | Show AI tool installation status |
| `cac env install [TOOL] [--global] [--yes] [--tmux]` | Install AI tool environments |
| `cac env update [TOOL]` | Update installed AI tools |

### Library Modules

- **config.sh**: Loads `.env` configuration, validates backend settings, checks file permissions
- **security.sh**: User access checks, file permission validation, zip-slip protection, secure temp directories
- **tools.sh**: Maps AI tools to their configuration files (dual registry: credentials + settings), collects/counts existing files
- **bundle.sh**: ZIP creation with correct naming convention, secure extraction with backups
- **backend_local.sh**: Local filesystem storage operations (upload, download, list, get_newest)
- **backend_gokapi.sh**: Gokapi REST API operations (upload, download, list, get_newest, delete); enforces 7-day max TTL
- **check.sh**: Credential verification via real API calls; 5-minute cache, 10-second timeout per provider
- **env.sh**: AI tool environment management; install/update/status for Claude, Codex, Gemini, Mistral Vibe, continuous-claude; `--tmux` flag sets `teammateMode` in settings.json
- **logging.sh**: Structured logging (info, warn, error, verbose, spinner)
- **platform.sh**: Platform detection and wrappers (Linux, macOS, WSL, Windows Git Bash) for filesystem, user and system operations
- **skill.sh**: Skill library management (`cac skill install/update/list/status` from Git repositories)
- **update.sh**: Self-update logic; detects install scope (user/global), compares local vs remote version, downloads and re-runs install.sh
- **utils.sh**: Shared utilities (JSON field extraction, retry with backoff, filter parsing, command context)

### Bundle Naming Convention

```
CodingAgentConfig_<HOST>_<USER>_<TOOL>_<YYMMDD-HHMMSS>.zip
```

### Credential Files (portable across hosts)

| Tool | Files |
|------|-------|
| Claude Code | `.claude.json`, `.claude/.credentials.json` |
| Codex CLI | `.codex/auth.json` |
| Gemini CLI | `.gemini/oauth_creds.json`, `.gemini/google_accounts.json`, `.gemini/settings.json`, `.gemini/state.json`, `.gemini/installation_id`, `.config/gcloud/application_default_credentials.json` |
| Mistral Vibe | `.vibe/.env`, `.vibe/config.toml` |
| OpenCode | `.local/share/opencode/auth.json`, `.config/opencode/opencode.json` |

### Settings Files (host+user-specific, NOT portable)

| Tool | Files |
|------|-------|
| Claude Code | `.claude/settings.json` |

Settings are bundled with `cac push` but only extracted by `cac pull` when the bundle's hostname AND username match the target. This prevents host-specific config (e.g. `teammateMode: "tmux"`) from being overwritten by bundles from other hosts.

`.claude.json` stays in the credential list but is merged, not moved, when the bundle comes from another host or user: only `oauthAccount` is taken from the bundle, all other keys (`mcpServers`, `projects`, `machineID`, `userID` …) stay local (#136, `_bundle_merge_claude_json`). No jq or invalid JSON → local file untouched.

## Installation Paths

| Mode | Binary | Libraries | Config |
|------|--------|-----------|--------|
| System-wide (root) | `/usr/local/bin/cac` | `/usr/local/lib/cac/` | `/etc/cac/.env` |
| User-local | `~/.local/bin/cac` | `~/.local/lib/cac/` | `~/.config/cac/.env` |

## Banned Dependencies

- **Bun is BANNED.** Do not use Bun anywhere in this project — no `bun add`, no `bun update`, no `bun install`, no `/opt/claude-code` bun-based paths. Use `npm` for package management and official `curl | bash` installers for tool installation. Existing Bun code (Issue #56) is legacy debt being removed.

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

# Run all tests (over 2 minutes: start it in the background)
./tests/run_tests.sh

# Run one registered suite by issue number or key, e.g. 141. An unknown key
# fails with "no suite matches '<key>'" (exit 2).
./tests/run_tests.sh 141

# Run specific suite
./tests/test_bundle.sh
./tests/test_security.sh
./tests/test_integration.sh
```

### Linting

The gate is the lint step in `.github/workflows/ci.yml`; these are its two invocations. Both must exit 0. Without `--severity=error`, shellcheck exits 1 on info-level notes in untouched code and floods the output.

```bash
shellcheck --severity=error bin/cac lib/*.sh install.sh uninstall.sh .claude/hooks/*.sh
shellcheck --severity=error tests/*.sh
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
- `backend_*_list([--tool TOOL] [--user USER])` - List bundles
- `backend_*_get_newest([--tool TOOL] [--user USER])` - Get newest matching

**check.sh:**
- `check_single_tool(tool, user)` - Verify one tool's credentials with caching
- `check_all_tools(user)` - Verify all configured tools
- `check_tool_claude/codex/gemini(user)` - Provider-specific verification

## Agent skills

Work in this repo follows the mattpocock-skills workflow. The former milestone lifecycle, Codex gates and SoD rules were retired on 2026-09-18.

### Issue tracker

Issues live as GitHub issues in `BPMspaceUG/bpm-CodingAgentConfigCopy`, managed with the `gh` CLI. `gh issue view <N>` without `--json` fails here. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, using the default label strings. See `docs/agents/triage-labels.md`.

### Coding standards

Reviewers check `CODING_STANDARDS.md` (credential and config parsers are tested against real-shape fixtures in `tests/fixtures/`).

### Domain docs

Single-context. Where the glossary and ADRs live, and how to read them: `docs/agents/domain.md`.

## Status: v1 is the active codebase

The v1 freeze declared in #135 was lifted by the owner on 2026-11-13 (#147): new work, not only crash and security fixes, happens in this repo. The spec-first rewrite in `BPMspaceUG/bpm-CodingAgentConfigCopy2` is paused; its `docs/spec/` summarises this repo's issue history and is reference only, not the place for new work.
