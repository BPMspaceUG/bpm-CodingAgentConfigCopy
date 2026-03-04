---
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
description: Show a table of the local repo's open issues with status, type, and milestone. If no milestones exist in the GitHub repo, creates them and adds the mandatory lifecycle section to the local CLAUDE.md.
---

# /my-bpm-openissues-list — Open Issues Dashboard

Show all open GitHub Issues for the current repository in a compact table. If milestones are missing from the repo, set them up and enforce the lifecycle in CLAUDE.md.

$ARGUMENTS

---

## Step 1 — Identify Repository

```bash
git remote -v | head -1
```

Extract the **OWNER** and **REPO** from the remote URL. Use these for ALL subsequent calls.

## Step 2 — Check Milestones in GitHub Repo

List existing milestone titles (compact output):

```bash
gh api 'repos/{OWNER}/{REPO}/milestones?per_page=100&state=all' --jq '.[].title' | sort
```

The full lifecycle requires these milestones:

| Milestone | Description |
|-----------|-------------|
| `new` | Issue created, not yet planned |
| `planned` | Agent submitted a plan |
| `plan-approved` | Team Lead + Codex both approved the plan |
| `test-designed` | Agent submitted test design |
| `test-design-approved` | Team Lead + Codex both approved test design |
| `implemented` | Code written, agent reports completion |
| `tested-success` | All tests pass |
| `tested-failed` | Tests fail — bounces back with documented reason |
| `test-approved` | Final automated gate — independent verification passed |
| `DONE` | Human-only final sign-off |

### If ANY milestones are missing:

1. **Create the missing milestones** via `gh api`:

   ```bash
   gh api repos/{OWNER}/{REPO}/milestones -f title="<name>" -f description="<description>"
   ```

   Skip milestones that already exist. Create only what's missing.

2. **Update the local CLAUDE.md** — check if the file already contains a `## Mandatory: Milestone-Based Issue Lifecycle` section. If it does NOT exist, append the following section to the end of CLAUDE.md:

   ```markdown
   ## Mandatory: Milestone-Based Issue Lifecycle

   **All issues in this repo MUST follow the milestone-based lifecycle. No exceptions.**

   Every issue gets exactly ONE milestone at a time representing its current state. Milestones are progressed in order — no skipping states.

   ### Lifecycle Flow

   ```
   new -> planned -> plan-approved -> test-designed -> test-design-approved
     -> implemented -> tested-success / tested-failed -> test-approved -> DONE
   ```

   ### Non-Negotiable Rules

   1. **One milestone at a time** per issue — no skipping states
   2. **Dual approval required** at every gate — Team Lead AND Codex must both approve
   3. **`DONE` is human-only** — agents must NEVER set this milestone
   4. **One issue per discrete change** — all phases documented as comments on that issue
   5. **Audit trail** — every Codex response posted as comment on the GitHub Issue
   6. **On failure**: `tested-failed` bounces back to `planned` (wrong approach) or `implemented` (code bug), with documented reason
   7. **Run `/my-bpm-openissues-list` before any issue-related work** to check status and milestones
   ```

   If the section already exists, do NOT duplicate it.

3. **Report what was done:**
   ```
   Created milestones: new, planned, plan-approved, ... (list only the ones created)
   CLAUDE.md updated with mandatory milestone lifecycle section
   ```

### If ALL milestones already exist:

Display:
```
All lifecycle milestones exist in the repo.
```

## Step 3 — Fetch Open Issues (compact)

**IMPORTANT**: Do NOT use GitHub MCP `list_issues` — it returns full issue bodies and wastes context.

Use `gh api` with `--jq` to fetch ONLY the fields needed for the table:

```bash
gh api 'repos/{OWNER}/{REPO}/issues?state=open&per_page=100' \
  --jq '.[] | select(.pull_request == null) | [.number, .title, (.labels | map(.name) | join(",")), (.milestone.title // "—")] | @tsv'
```

This returns one TSV line per issue with: number, title, labels, milestone.

If more than 100 issues, paginate with `&page=2`, `&page=3`, etc.

**NEVER use `-f` flags with GET endpoints** — `-f` triggers a POST request. Always pass parameters as URL query strings for GET requests.

## Step 4 — Display Table

Render a markdown table with these columns:

| # | Title | Type | Milestone |
|---|-------|------|-----------|

- **#** — Issue number (e.g., `#33`)
- **Title** — Issue title as plain text (NOT a URL link)
- **Type** — From labels: `bug`, `enhancement`, etc. — or `—` if none
- **Milestone** — Current milestone name, or `—` if none

Sort by issue number ascending.

After the table, show a summary line:
```
N open issue(s) | M with milestones | K without milestones
```

## Step 5 — Final Status

### If ALL issues have milestones:
```
All open issues have milestones assigned. Lifecycle is on track.
```

### If ANY issues lack milestones:
```
{K} issue(s) have no milestone assigned.
Milestones are available — assign them via GitHub or `/my-bpm-team-milestones`.
```

## Notes

- Show issue titles as readable text, NEVER as clickable URLs
- If there are no open issues, say: "No open issues found for OWNER/REPO."
- The command creates milestones and updates CLAUDE.md only when milestones don't exist yet
- It does NOT auto-assign milestones to individual issues — that's a Team Lead decision
- **All data fetching uses `gh api` with `--jq`** — never GitHub MCP (too verbose)
- **All GET requests use URL query params** — never `-f` flags (which trigger POST)
