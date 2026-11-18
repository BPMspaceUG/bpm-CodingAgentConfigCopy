# Fixtures

Real-shape, sanitized copies of what the tools write (rule: `CODING_STANDARDS.md`, #144).
Every token, key and id is a `FIXTURE` placeholder or the nil UUID.

| File | Source of the shape |
|---|---|
| `claude-credentials.json` | `~/.claude/.credentials.json` on contabo03, 2026-11-13: one line, no trailing newline, top-level keys `seeded`, then `claudeAiOauth` with its keys in Claude Code's order. The `seeded` key is in the real file; its origin is unknown. |
| `claude-credentials-wiped.json` | The same file after the session was wiped (empty tokens, expiry 0), with a live MCP entry in front. |
| `codex-auth.json` | `~/.codex/auth.json` on contabo03, 2026-11-13: two-space indent, no trailing newline, keys and `tokens` keys in Codex's order. |
| `claude-json-local.json`, `claude-json-bundle.json` | `~/.claude.json` on contabo03, 2026-11-16 (#136): two-space indent, no trailing newline. Top-level keys are a subset of the real file in its order; the `projects` entry keys and all `oauthAccount` keys are in Claude Code's order. `local` is the target host (one MCP server, `machineID` LOCAL); `bundle` is another host (no MCP server, `machineID` REMOTE, paths under `/home/source`). **Guessed:** the host had no top-level `mcpServers`, so its position (after `projects`) and its entry shape (`type`, `command`, `args`, `env`) follow the issue report and Claude Code's `claude mcp add` format, not a captured file. |
| `github-commits-main.json` | `GET /repos/BPMspaceUG/bpm-CodingAgentConfigCopy/commits/d90f3b4` (GitHub REST API), 2026-11-15: two-space indent, keys in the API's order, `files` cut to one entry. Strings are `FIXTURE`, numbers 0. The dates are set: author `2026-07-26T16:05:12Z`, committer `2026-07-26T17:48:51Z` (the real commit, #140), so a parser that takes the author date fails. |

The `mcpOAuth` entry is **not** taken from a real file: the host's file had none. Its keys are a best guess; what matters for the parsers is that it sits before `claudeAiOauth` and carries its own `accessToken`, `refreshToken` and `expiresAt` (the #141 bug).

### Package-manager output (#157)

Verbatim captures, `.out` = stdout, `.err` = stderr; the exit code is in the column. Captured 2026-11-16 with `docker run --rm <image> sh -c '<command>'`. Images: `debian:stable` (13.7, dpkg), `fedora:latest` (Fedora 45, RPM 6.1.0), `alpine:latest` (3.24.4, apk-tools 3.0.9).

| File | Image | Command | Exit |
|---|---|---|---|
| `dpkg-S-owned.out` | `debian:stable` | `dpkg -S /usr/bin/ls` | 0 |
| `dpkg-S-unowned.err` | `debian:stable` | `dpkg -S /nonexistent/cac157` (stdout empty) | 1 |
| `dpkg-S-diverted.out` | `debian:stable` | `dpkg-divert --package foo --divert /usr/bin/ls.distrib --rename --add /usr/bin/ls; dpkg -S /usr/bin/ls`. The diversion lines come before the owner line. | 0 |
| `dpkg-S-local-diversion.out` | `debian:stable` | `dpkg-divert --local --divert /usr/local/x.d --no-rename --add /usr/local/x157; dpkg -S /usr/local/x157`. There is no owner line, and the exit code is still 0. | 0 |
| `dpkg-S-local-diversion-packaged.out` | `debian:stable` | `dpkg-divert --local --rename --add /usr/bin/cat; dpkg -S /usr/bin/cat`. The original package's owner line follows the local-diversion lines. | 0 |
| `dpkg-S-diverted-to.out` | `debian:stable` | `dpkg-divert --package foo --divert /usr/bin/ls.distrib --rename --add /usr/bin/ls; dpkg -S /usr/bin/ls.distrib`. Only the diversion lines, no owner line. | 0 |
| `dpkg-S-multi-package.out` | `debian:stable` | `dpkg -S /etc/default`. A path several packages share: `pkgA, pkgB, pkgC: <path>`. | 0 |
| `rpm-qf-owned.out` | `fedora:latest` | `rpm -qf /usr/bin/ls` | 0 |
| `rpm-qf-not-owned.out` | `fedora:latest` | `touch /usr/local/bin/x157; rpm -qf /usr/local/bin/x157`. The message goes to stdout. | 1 |
| `rpm-qf-missing.err` | `fedora:latest` | `rpm -qf /nonexistent/cac157` (stdout empty) | 1 |
| `apk-info-W-owned.out` | `alpine:latest` | `apk info -W /bin/busybox` | 0 |
| `apk-info-W-symlink.out` | `alpine:latest` | `apk info -W /bin/ls` (a symlink: "symlink target is owned by") | 0 |
| `apk-info-W-unowned.err` | `alpine:latest` | `touch /usr/local/bin/x157; apk info -W /usr/local/bin/x157` (stdout empty) | 1 |

Package names (`foo` included) and paths are as captured; nothing is guessed. On Debian 13, `dpkg -S /bin/ls` finds nothing (merged `/usr`): only the `/usr/bin` path is owned.

### Gokapi file list (#158)

| File | Source of the shape |
|---|---|
| `gokapi-files-list.json` | `GET /api/files/list` on the team's Gokapi backend, 2026-11-16: one line, no trailing newline, 15 entries with every key in Gokapi's order, entries in the server's (not date) order. Host and user in every `Name` are replaced by `FIXTURE-HOST` / `fixture`; tool and timestamp are kept. `Id` is `FIXTURE<n>`, `UrlDownload` / `UrlHotlink` point to `gokapi.example.invalid` with that id, `UploaderId` is 0. Sizes, dates and flags are the real values. Built with `jq` from the captured answer rather than from structure only: the list holds no secret once ids and URLs are replaced, and the real names, dates and server order are what the matching code is tested against. |

### CLI and npm version output (#83)

Verbatim captures on contabo03, 2026-11-18, `.out` = stdout, `.err` = stderr. Real versions at capture time: codex was one minor release behind npm, Claude Code matched.

| File | Command | Exit |
|---|---|---|
| `codex-version.out` | `codex --version` (codex-cli 0.169.1, stderr empty) | 0 |
| `claude-version.out` | `claude --version` (apt package 2.1.327, stderr empty) | 0 |
| `npm-view-codex-version.out` | `npm view @openai/codex version` (npm 11.19.1) | 0 |
| `npm-view-claude-code-version.out` | `npm view @anthropic-ai/claude-code version` | 0 |
| `npm-view-404.err` | `npm view @openai/codex-fixture-nonexistent-cac83 version` (stdout empty): the shape of a failed lookup for a valid but unpublished name | 1 |
