# gemini.md - Gemini Role Documentation

This file documents Gemini's role as the consensus and fallback reviewer in the multi-agent development workflow.

## Overview

Gemini serves as the **consensus and fallback reviewer** in the multi-agent workflow. It provides independent assessment when primary reviewers disagree or are unavailable.

## Primary Role: Consensus Resolution

### When Gemini Is Invoked

Gemini is used when:

1. **Disagreement exists** between Claude and Codex
2. **Codex is unavailable** (rate-limited or unreachable)
3. **Independent assessment** is needed to break a tie

### Invocation Method

Gemini MUST be invoked via shell command only:

```bash
gemini "<question>"
```

Do not use Gemini as an inline tool or API call within Claude's context.

## Fallback Logic

### Fallback Priority When Codex Is Unavailable

When Codex cannot perform review:

| Priority | Reviewer | Notes |
|----------|----------|-------|
| 1 | gpt-5.1-codex-mini | Lighter-weight Codex variant |
| 2 | Gemini | Independent assessment |
| 3 | Claude | Only with documented SoD exception |

### Fallback Priority When Gemini Is Unavailable

When Gemini cannot perform consensus review:

| Priority | Reviewer | Notes |
|----------|----------|-------|
| 1 | gemini-2.5-flash-lite | Lighter-weight Gemini variant |
| 2 | Codex | Primary reviewer as fallback |
| 3 | Claude | Only with documented SoD exception |

## Rate Limit Behavior

### Detection

Rate limits are detected when:

- API returns rate limit error
- Response timeout occurs
- Service unavailability is reported

### Response to Rate Limits

When Gemini is rate-limited:

1. Attempt gemini-2.5-flash-lite first
2. Fall back to Codex if still unavailable
3. Document the fallback in the issue
4. If Claude must self-review, document SoD exception

### Rate Limit Documentation

When rate limits affect workflow, document:

```
RATE LIMIT ENCOUNTERED
Service: Gemini
Action taken: Fallback to <alternative>
```

## Exception Handling

### Segregation of Duty Exception

If Gemini is unavailable AND Codex is unavailable, Claude may perform review with mandatory documentation:

```
SEGREGATION OF DUTY EXCEPTION APPLIED
Reason: <exact reason, e.g., Codex rate-limited, Gemini unavailable>
```

### Requirements for Exception

All conditions must be met:

1. Work was NOT performed by Claude
2. Codex is rate-limited or unavailable
3. Gemini is rate-limited or unavailable
4. Exception is explicitly documented in the issue

## Consensus Process

### Standard Flow

1. Claude summarizes implementation state, test results, and readiness
2. Codex reviews and either approves or requests changes
3. If disagreement occurs, Gemini provides independent assessment
4. Final decision follows Gemini's recommendation

### Disagreement Resolution

When Claude and Codex disagree:

1. Invoke Gemini with clear context about the disagreement
2. Gemini provides independent technical assessment
3. The assessment helps resolve the disagreement
4. Document the resolution in the issue

## Approval Authority

### Primary Authority

- **Codex** is the default approval authority

### Fallback Authority

- **Gemini** when Codex is unavailable

### Emergency Authority

- **Claude** only under documented SoD exception

## Required Approvals Before Git Push

All must be documented in the issue:

1. PLAN AND AGENT/SKILL ASSIGNMENT APPROVED
2. IMPLEMENTATION APPROVED
3. TEST DESIGN APPROVED
4. TEST RESULTS APPROVED
5. DOCUMENTATION UPDATED AND CONSISTENT APPROVED

If ANY approval is missing or conditional, git push is NOT allowed.

## Documentation Requirements

### What Must Be Documented

In the issue, record:

- All Gemini invocations and responses
- Disagreements that required consensus
- Rate limit occurrences and fallback actions
- Any exceptions applied

### Approval Statement

When Gemini provides approval, document:

```
APPROVED BY: Gemini (fallback reviewer)
Reason for fallback: <reason>
```

## Related Documentation

- [README.md](README.md) - Project overview and usage
- [CLAUDE.md](CLAUDE.md) - Technical reference for Claude Code
- [agent.md](agent.md) - Multi-agent orchestration model
