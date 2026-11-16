# Fixtures

Real-shape, sanitized copies of what the tools write (rule: `CODING_STANDARDS.md`, #144).
Every token, key and id is a `FIXTURE` placeholder or the nil UUID.

| File | Source of the shape |
|---|---|
| `claude-credentials.json` | `~/.claude/.credentials.json` on contabo03, 2026-11-13: one line, no trailing newline, top-level keys `seeded`, then `claudeAiOauth` with its keys in Claude Code's order. The `seeded` key is in the real file; its origin is unknown. |
| `claude-credentials-wiped.json` | The same file after the session was wiped (empty tokens, expiry 0), with a live MCP entry in front. |
| `codex-auth.json` | `~/.codex/auth.json` on contabo03, 2026-11-13: two-space indent, no trailing newline, keys and `tokens` keys in Codex's order. |
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
