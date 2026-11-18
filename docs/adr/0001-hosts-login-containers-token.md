# 1. Hosts use the interactive Claude login, containers use the long-lived token

Date: 2026-11-18
Status: accepted (owner decision, #166)

## Context

A Claude subscription login is an OAuth session whose refresh token works once
(#141). `cac push` / `cac pull` move that session between hosts.

`claude setup-token` creates a long-lived OAuth token that is never refreshed,
so copies cannot invalidate each other. Wherever `CLAUDE_CODE_OAUTH_TOKEN` is
set it takes precedence over the login. The token can only make model requests,
so Remote Control and claude.ai connectors do not work with it.

The owner develops on the hosts with the interactive login and checks the work
from another device through Remote Control. Systems built here sometimes call
Claude themselves at runtime (reports, reviews); nobody watches those calls.

## Decision

- **Hosts** (contabo03, ICO-ROB-01, laptops) use the interactive login
  (`/login`, `~/.claude/.credentials.json`). `cac` moves it between hosts as
  before.
- **Containers** that call Claude at runtime use the token: one file per host,
  `~/.config/claude/oauth-token.env` (700/600), mounted read-only as a
  directory, loaded at container start as `CLAUDE_CODE_OAUTH_TOKEN`
  (contract: the `c-bpm-sk-subscription-login` skill). No host shell loads it.
- `cac` never bundles the token file and never expects or recommends the token
  on a host. A "token host" does not exist for `cac pull` or `cac check`.
- Codex is unchanged: there is no `setup-token` equivalent (`codex login`
  0.170.0 offers `--with-api-key`, billed per use, and `--with-access-token`,
  lifetime unverified), so Codex logins keep the move flow.

## Consequences

- Remote Control keeps working on every host.
- Container AI does not depend on a host's login staying fresh, and revoking one
  host's token touches only that host.
- Advice that pointed hosts at the token (README, the dead-session hint of
  `cac check claude`) was removed; `tests/test_issue_166.sh` keeps it out and
  asserts that `cac push` never packs the token file.
