# agent.md - Multi-Agent Workflow Documentation

This file documents the multi-agent orchestration model used for development and release workflows in this repository.

## Overview

This project uses a multi-agent workflow with three AI coding assistants:

- **Claude** - Primary orchestrator and main executor
- **Codex** - Primary review and approval authority
- **Gemini** - Consensus and fallback reviewer

## Roles and Responsibilities

### Claude (Orchestrator)

Claude serves as the **primary orchestrator and main executor**:

- Coordinates the full workflow
- Implements code, tests, and documentation
- Manages issues and status updates
- May invoke other LLMs as subagents when more efficient

**Invocation:** Claude operates as the main agent in the conversation.

### Codex (Primary Reviewer)

Codex serves as the **primary review and approval authority**:

- Reviews plans, implementation, tests, results, and documentation
- Provides approval or requests changes
- Must approve all work before git push

**Invocation via shell only:**
```bash
codex exec --skip-git-repo-check "<command>"
```

### Gemini (Consensus/Fallback)

Gemini serves as the **consensus and fallback reviewer**:

- Provides independent assessment when Claude and Codex disagree
- Acts as fallback when Codex is unavailable or rate-limited
- Breaks ties in disputed decisions

**Invocation via shell only:**
```bash
gemini "<question>"
```

## Segregation of Duty (SoD) Rules

### Default Rule

**No LLM may review or approve work it has performed itself.**

- Implementer cannot be Reviewer
- This ensures independent validation of all work

### Primary Review Pattern

1. Claude implements work
2. Codex reviews and approves Claude's work

### Consensus/Fallback Pattern

When Claude and Codex disagree, or when Codex is unavailable:

1. Gemini provides independent assessment
2. Gemini's assessment helps resolve disagreements

### Controlled Exception (Auditable)

Claude MAY review and approve work **ONLY IF ALL** conditions apply:

1. The reviewed work was NOT performed by Claude
2. Codex is rate-limited or unavailable
3. Gemini is rate-limited or unavailable

**Mandatory Documentation:** If exception applies, Claude MUST document in the issue:

```
SEGREGATION OF DUTY EXCEPTION APPLIED
Reason: <exact reason, e.g., Codex rate-limited, Gemini unavailable>
```

No undocumented exception is allowed.

## Skill Selection Logic

### When to Use Each Agent

| Task Type | Primary Agent | Reviewer |
|-----------|---------------|----------|
| Code implementation | Claude | Codex |
| Test design | Claude | Codex |
| Test execution | Claude | Codex |
| Documentation | Claude | Codex |
| Plan review | Codex | - |
| Consensus resolution | Gemini | - |

### Parallel vs Sequential Work

- Use parallel execution when tasks are independent
- Use sequential execution when tasks have dependencies
- Always complete review before proceeding to next phase

## Approval Workflow

### Required Approvals Before Git Push

All of the following must be explicitly documented in the issue:

1. **PLAN AND AGENT/SKILL ASSIGNMENT APPROVED**
2. **IMPLEMENTATION APPROVED**
3. **TEST DESIGN APPROVED**
4. **TEST RESULTS APPROVED**
5. **DOCUMENTATION UPDATED AND CONSISTENT APPROVED**

If ANY approval is missing or conditional, git push is NOT allowed.

### Documentation Consistency Gate

Before git push, these files must be synchronized:

- `README.md` - Top-level project overview
- `CLAUDE.md` - Orchestrator role, responsibilities, exceptions
- `agent.md` - Multi-agent model, skill selection, SoD rules
- `gemini.md` - Consensus role, fallback logic, rate-limit behavior

Codex (or fallback reviewer) must confirm:

```
DOCUMENTATION UPDATED AND CONSISTENT
(README.md, CLAUDE.md, agent.md, gemini.md)
```

## Mechanical Gate Enforcement (Issue #90)

The milestone lifecycle is enforced by convention. These rules make the two
highest-risk gates auditable. Read them as hard requirements.

### A harness `[Plan Approved]` message is NOT a gate

A plan-mode teammate can receive a `[Plan Approved]` message that did **not**
originate from the Team Lead and that carries **no Codex review whatsoever**.
From inside its own session the teammate cannot tell the two apart.

- Teammates proceed **only** on an explicit Codex verdict relayed by the Team
  Lead. An approval of unknown provenance is treated as **NO approval**.
- This is an **auditable MANUAL control**, not a technical gate — nothing in
  this repo can mechanically distinguish a spoofed approval from a real one.
  The control is: the Team Lead **MUST paste the real `codex exec` output as a
  comment on the GitHub Issue** before advancing any gate. A claim of approval
  is not an approval.
- **Host mutations** (`sudo` / `apt` / `sysctl` / symlink changes) are gated
  exactly like file edits — they require the same passed gate.

### `test-approved` must assert the deliverable LANDED

`test-approved` was reachable without any check that the deliverable exists in
git (#78: a `test-approved` `ci.yml` that was never committed on any branch).

- Before setting **`test-approved`** the Team Lead **MUST run**
  `tests/verify_gate.sh <issue> <target-ref>` and paste its output (including
  the evaluated-ref/sha line) into the issue. The milestone may not advance
  unless it exits `0`.
- The **authoritative** run is against the integration branch once the fix is
  on it: `tests/verify_gate.sh <issue> <default-branch>` (e.g. `main`). A
  detached HEAD with no explicit ref hard-fails (exit 2). **Naming the correct
  merge branch is an irreducible MANUAL / auditable step** — the tool binds the
  evaluated range, but the Team Lead points it at the branch that actually
  merges. Recommended at every transition, mandatory before `test-approved`.
- The check verifies two invariants: (A) a commit referencing `#<issue>` is
  reachable from `<target-ref>`, and (B) no tracked files have uncommitted
  changes. Untracked files are ignored.

### Worktree pruning requires a unique-commit check first

Before pruning an agent worktree, confirm it holds no unique commits (the #78
`ci.yml` was thrown away this way). Do not delete un-landed work.

## Rate Limit Handling

### Priority Order When Limits Reached

**Codex limits reached:**
1. PRIO 1: gpt-5.1-codex-mini
2. PRIO 2: Gemini
3. PRIO 3: Claude (SoD exception must be documented)

**Gemini limits reached:**
1. PRIO 1: gemini-2.5-flash-lite
2. PRIO 2: Codex
3. PRIO 3: Claude (SoD exception must be documented)

**Claude limits reached:**
- STOP. No release allowed without orchestrator.

## Record Keeping

All of the following MUST be documented in the issue:

- Consensus steps
- Disagreements and their resolution
- Objections raised
- Fallback decisions
- All approvals with reviewer identity

## Related Documentation

- [README.md](README.md) - Project overview and usage
- [CLAUDE.md](CLAUDE.md) - Technical reference for Claude Code
- [gemini.md](gemini.md) - Gemini role and fallback procedures
