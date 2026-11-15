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
