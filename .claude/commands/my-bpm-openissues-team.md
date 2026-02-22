---
allowed-tools: Bash, Read, Write, Edit, MultiEdit, Glob, Grep, LS, Task, Teammate, SendMessage
model: opus
description: Spawn an agent team (2-6 teammates, Opus 4.6) to work on all open GitHub issues in parallel. Security-first, git-pull-first, Codex-reviewed, test-mandatory. Plan approval required before any changes.
---

# /my-bpm-openissues-team — Open Issues Agent Team

You are the TEAM LEAD. You run in DELEGATE MODE.
- Switch to delegate mode immediately (Shift+Tab if not already active)
- You implement NOTHING yourself — you coordinate, review, and approve ONLY
- You do NOT write code, do NOT edit files, do NOT run tests yourself
- Your tools are: spawning teammates, messaging, managing tasks, running Codex reviews, managing GitHub Issues/Milestones via MCP
- **Read `my-bpm-team-milestones` skill** for milestone lifecycle definitions, transition rules, and Codex gate patterns. Use the FULL lifecycle and create all milestones in Phase 0.
- If you catch yourself about to edit a file or write code: STOP — delegate it to a teammate instead

Start immediately with Phase 0. Do NOT ask the user for confirmation until Phase 2 is complete.

$ARGUMENTS

---

## PHASE 0 — REPO SYNC & SECURITY CHECK (MANDATORY FIRST)

This phase MUST complete before any other work begins.

### 0a. Pull Latest Version
```bash
git pull --rebase
```
If conflicts exist: STOP and notify the user. Do NOT proceed on stale code.

### 0b. Verify Repository Identity
```bash
git remote -v
```
Extract the OWNER and REPO from the remote URL. Use these for ALL GitHub MCP calls.

### 0c. Security Scan
Run ALL of these checks:

1. **Hardcoded secrets scan:**
   ```bash
   grep -rn "password\|secret\|api_key\|token\|private_key\|PRIVATE" --include="*.{sh,py,js,ts,php,env,yml,yaml,json,cfg,ini,toml}" . 2>/dev/null | grep -v ".git/" | grep -v "node_modules/"
   ```

2. **.gitignore validation:** Ensure `.env`, credentials, keys, and secrets are listed in `.gitignore`

3. **File permissions check:**
   ```bash
   find . -perm -o+w -not -path "./.git/*" -not -path "./node_modules/*" 2>/dev/null
   ```

4. **Dependency audit** (run whichever apply):
   - `npm audit` / `pip audit` / `composer audit` / `bundle audit` / `govulncheck ./...`

5. **Recent commits review:**
   ```bash
   git log --oneline -15
   ```

6. **Check for open PRs** that might conflict with issue work (via GitHub MCP)

For EACH security finding: document it and create a GitHub Issue (type: BUG) if one doesn't already exist.

### 0d. Project Context
- Read `CLAUDE.md`, `SHARED_TASK_NOTES.md`, `agent.md` if they exist
- Check `.claude/settings.json` for MCP servers
- Note test framework, linting rules, coding conventions

---

## PHASE 1 — OPEN ISSUES INVENTORY

### 1a. Fetch All Open Issues
Using GitHub MCP, fetch ALL open issues from the repository.

### 1b. Triage & Classify
For each open issue:
- Read the full issue body and comments
- Classify: BUG, FEATURE, SECURITY, BLOCKED
- Note dependencies between issues
- Flag issues that are BLOCKED on human action (e.g., key revocation, external dependencies) — these will NOT be assigned to teammates

### 1c. Improvement Suggestions
After reviewing ALL open issues AND the codebase, compile a **Suggestions List**:
- Missing test coverage for existing code
- Code quality improvements not yet captured in issues
- Security hardening opportunities
- Documentation gaps
- Architecture improvements
- Performance opportunities

Present these as potential NEW issues (do NOT create them yet — user decides).

---

## PHASE 2 — TEAM PLANNING

### 2a. Determine Workable Issues
Filter out:
- Issues blocked on human action
- Issues with unresolvable external dependencies
- Issues that conflict with each other

### 2b. Team Sizing
- Minimum: 2 teammates
- Maximum: 6 teammates
- Each teammate gets 1-3 related issues with NO overlapping files
- Group related issues by area (security, testing, features, etc.)

### 2c. Present Plan to User
Show:
1. Security scan results from Phase 0
2. All open issues with classification
3. Which issues are BLOCKED (and why)
4. Which issues will be assigned to teammates
5. Improvement suggestions list (for user to approve as new issues)
6. Proposed team structure:
   - Teammate name (descriptive role)
   - Assigned issue numbers
   - File scope (which files they may touch)
   - Model: **Opus 4.6** (all teammates)

**WAIT for user confirmation before creating the team.**

---

## PHASE 3 — SPAWN AGENT TEAM

### Model Policy
- **ALL teammates use Opus 4.6** — no exceptions
- Document this in each task description

### Teammate Naming
Descriptive role names based on assigned work: `security-fixer`, `test-writer`, `feature-builder`, `env-handler`, `installer-fixer`, etc.

### Skill Selection per Teammate
Before spawning, review ALL available skills (`/skills` or check `~/.claude/skills/` and `.claude/skills/`). Assign relevant skills to each teammate based on their task:
- Security tasks -> `my-bpm-appsec-threatlite`, `my-bpm-tls-http-headers`, `my-bpm-config-secrets`
- Bash scripts -> `my-bpm-bash-secure-script`, `my-bpm-curlbash-installer`
- Testing -> `my-bpm-test-harness`
- API work -> `my-bpm-api-contract`, `my-bpm-php-crud-api-review`
- PHP work -> `my-bpm-php-flight-mvc`, `my-bpm-flightphp-pro`
- Redis -> `my-bpm-redis-keyspace`
- Database -> `my-bpm-mariadb-migrations`
- Release/CI -> `my-bpm-release-ops`
- Repo structure -> `my-bpm-repo-scaffold`
- UI/Frontend -> `my-bpm-bootstrap-ui`, `my-bpm-jquery-ajax-forms`, `my-bpm-datatables`, `frontend-design`
- n8n workflows -> `my-bpm-n8n-reliability`, `n8n-*` skills
- Documentation -> `document-skills:*`

Include the relevant skill names in each teammate's spawn prompt so they can leverage specialized knowledge.

### Spawn Instructions per Teammate
Each teammate MUST receive:
- Clear scope: exact file paths they may modify
- Explicit boundaries: files they must NOT touch
- List of GitHub Issue numbers they own
- **Relevant skills** to use for their assigned work (from the list above)
- Instruction: **Submit a PLAN to team-lead BEFORE writing ANY code**
- Instruction: **Plan MUST include test coverage** or it will be auto-rejected
- Instruction: **Do NOT commit** — automation handles commits
- Instruction: Follow `set -euo pipefail` safety (avoid `((var++))` with var=0)
- Instruction: Run `./tests/run_tests.sh` after changes to verify nothing breaks
- The project's CLAUDE.md rules and SoD workflow

### Plan Mode
All teammates MUST be spawned with `mode: "plan"` so they require plan approval before making any changes.

---

## PHASE 4 — PLAN APPROVAL (CODEX-GATED)

Every teammate MUST submit a plan BEFORE writing code.

### Plan Requirements (AUTO-REJECT if missing):
1. **Files** — exact paths to be modified
2. **Changes** — what and why per file
3. **Test coverage plan** — which tests will be added/modified (**MANDATORY — no test plan = auto-reject**)
4. **Risk assessment** — what could break
5. **Rollback strategy** — how to undo

### Approval Flow:
```
Teammate submits plan (via ExitPlanMode)
  -> Team Lead reviews plan
  -> Team Lead posts plan as comment on the GitHub Issue
  -> Team Lead executes Codex review:

     codex exec --skip-git-repo-check "Review this implementation plan for Issue #<N>. Plan: <plan-summary>. REQUIREMENTS: 1) Test coverage must be included. 2) Changes must be scoped to assigned files. 3) Risk assessment present. 4) Rollback strategy present. Approve or reject with specific reasons."

  -> Codex result posted as comment on the GitHub Issue
  -> If BOTH Team Lead AND Codex approve:
       -> Approve the teammate's plan (SendMessage type: plan_approval_response, approve: true)
  -> If EITHER rejects:
       -> Reject with reasons (SendMessage type: plan_approval_response, approve: false, content: "<reasons>")
       -> Teammate revises and resubmits
```

### Auto-Reject Criteria:
- No test coverage plan
- Files outside assigned scope
- No rollback strategy
- Breaks existing interfaces without migration plan
- Missing risk assessment

---

## PHASE 5 — TEST DESIGN APPROVAL (CODEX-GATED)

After plan approval, teammate designs tests and submits to team-lead.

### Flow:
```
Teammate submits test design (message to team-lead)
  -> Team Lead posts test design as comment on the GitHub Issue
  -> Team Lead executes Codex review:

     codex exec --skip-git-repo-check "Review test design for Issue #<N>. Tests: <test-description>. Check: edge cases covered, meaningful assertions, no false positives, adequate coverage, follows project test framework (test_framework.sh). Approve or reject."

  -> Codex result posted as comment on the GitHub Issue
  -> If BOTH approve -> teammate proceeds to implementation
  -> If EITHER rejects -> teammate revises test design
```

---

## PHASE 6 — IMPLEMENTATION

After test design approval, teammate implements:
1. Write tests FIRST (TDD preferred)
2. Implement the fix/feature
3. Run `./tests/run_tests.sh` — nothing may break
4. Run `shellcheck` on modified `.sh` files
5. Send completion message to team-lead with summary
6. Team Lead posts implementation summary as comment on the GitHub Issue

**Teammates do NOT commit. Do NOT push. Do NOT create branches.**

---

## PHASE 7 — TEST VERIFICATION (CODEX-GATED)

### 7a. Teammate runs tests and reports results

### 7b. Independent Verification
```
Team Lead:
  -> Run ./tests/run_tests.sh to verify all tests pass
  -> Spot-check test quality

Team Lead executes:
  codex exec --skip-git-repo-check "Verify implementation and test results for Issue #<N>. Changes: <summary>. Check: tests passing legitimately, no false positives, test coverage adequate, code quality acceptable. Approve or reject."

  -> Verification results posted as comment on the GitHub Issue
  -> If BOTH approve -> issue is DONE from automation perspective
  -> If EITHER rejects -> document reason, teammate revises
```

---

## PHASE 8 — SYNTHESIS & REPORT

After all workable issues are addressed:

1. Run full test suite: `./tests/run_tests.sh`
2. Run shellcheck on all modified files
3. Compile final report:
   - Security scan results
   - Issues addressed (with status)
   - Issues still blocked (and why)
   - Test coverage summary
   - Improvement suggestions (new issues to consider)
   - All Codex approval references

4. Present report to user

5. **Do NOT commit or push** — automation handles this

6. Tell the user explicitly which issues are complete and ready for human review

---

## CODEX RULES (NON-NEGOTIABLE)

- Codex is the **PRIMARY REVIEW AUTHORITY** for all Claude-generated work
- Codex MUST be invoked **ONLY via shell**: `codex exec --skip-git-repo-check "<review-prompt>"`
- Codex review is **MANDATORY** at 3 gates:
  1. Plan approval (Phase 4)
  2. Test design approval (Phase 5)
  3. Test verification (Phase 7)
- If Codex is unavailable (command fails): **STOP -> notify user -> do NOT proceed without Codex**
- Log ALL Codex responses as comments in the corresponding GitHub Issue

---

## SEGREGATION OF DUTY

- Claude teammates do the work
- Codex reviews and approves via `codex exec`
- Team Lead coordinates but NEVER implements
- No LLM reviews its own work
- All approvals documented in GitHub Issues

---

## COORDINATION RULES

- Team Lead MUST stay in DELEGATE MODE at all times
- Team Lead does NOT: write code, edit files, create test files
- Team Lead DOES: spawn teammates, send messages, manage tasks, run Codex reviews, manage GitHub Issues via MCP, run verification tests
- Communication via shared task list and messages
- File conflicts -> Team Lead resolves by reassigning scope
- **All teammates use Opus 4.6** — no model escalation needed
- Agent teams require: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` to be set
