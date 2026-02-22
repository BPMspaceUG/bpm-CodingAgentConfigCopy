---
model: opus
name: my-bpm-skill-optimizer
description: Create and optimize custom user skills derived from originals or built from scratch. Use when the user wants to create a new custom skill, optimize an existing skill for their workflow, or fork/customize an installed skill. Enforces the my- naming convention to clearly separate custom skills from originals. Includes Codex-reviewed quality gates, segregation of duty, and optional agent team orchestration for complex skill development. Derived from skill-creator.
---

# Skill Optimizer

Create, fork, and optimize skills for personal use. Extends `skill-creator` with strict separation of originals vs. custom skills, Codex review gates, and team orchestration support.

## Segregation of Duty

The most important principle: **original skills are read-only**.

### Rules

| Action | Allowed? | How |
|--------|----------|-----|
| Read original skill | YES | Read from `plugins/marketplaces/` or `skills/<original-name>/` |
| Modify original skill | **NEVER** | Fork to `my-` version first |
| Delete original skill | **NEVER** | Uninstall via marketplace only |
| Create custom skill | YES | Always with `my-` prefix |
| Fork original to custom | YES | Copy, rename with `my-` prefix, then modify |

### Why

- Originals may be updated upstream — local edits get overwritten
- Two versions coexist: original for reference, custom for use
- Clear audit trail: `my-` = user-created or user-modified
- Rollback is trivial: delete `my-` version, original still works

## The `my-` Naming Convention

**Custom/optimized skills MUST use the `my-` prefix.**

| Scenario | Name | Example |
|----------|------|---------|
| Installed/original skill | Keep original name | `frontend-design`, `n8n-code-javascript` |
| New custom skill | `my-` + descriptive name | `my-flightphp-pro`, `my-data-pipeline` |
| Forked/optimized original | `my-` + original name | `my-frontend-design`, `my-skill-creator` |
| Skills-about-skills | `my-bpm-skill-` + function | `my-bpm-skill-optimizer`, `my-bpm-skill-validator` |

### Identifying Custom vs. Original

- `LICENSE.txt` present -> likely an installed original
- No `LICENSE.txt` -> likely user-created
- Directory starts with `my-` -> definitively user-created/optimized
- Located in `plugins/marketplaces/` -> always original, never touch

## Skill Creation Workflow

### From Scratch

1. Read `skill-creator` SKILL.md for the full creation process (Steps 1-6)
2. Name the skill with `my-` prefix
3. Follow all skill-creator conventions (frontmatter, structure, progressive disclosure)
4. Run Codex review before finalizing (see Codex Review below)

### Forking an Existing Skill

1. Identify the original: `plugins/marketplaces/` or `skills/<name>/`
2. Copy to new directory: `cp -r original-name my-original-name`
3. Update `name:` in SKILL.md frontmatter to `my-original-name`
4. Update `description:` — add what was changed/optimized and why, include "Derived from <original>"
5. Remove `LICENSE.txt` if copied (custom skills don't carry original licenses)
6. Make modifications
7. Run Codex review on the result
8. **Keep the original intact** — verify no files were changed in the original directory

### Optimizing a Skill

1. **Identify what to improve** — missing patterns, wrong defaults, better examples, missing references
2. **Fork first** — copy to `my-` prefixed version (never edit in place)
3. **Document changes** — note what differs from the original in the SKILL.md body
4. **Codex review** — submit changes for review
5. **Test** — verify the optimized skill triggers correctly and provides better guidance
6. **Keep lean** — optimization means better, not bigger

## Codex Review

Codex is the review authority for skill quality. All non-trivial skill changes go through Codex review.

### When Required

- New skill creation (Step 4 of from-scratch workflow)
- Forking an original (Step 7 of forking workflow)
- Major changes to an existing custom skill

### When Optional

- Typo fixes, minor wording adjustments
- Adding a single example

### Invocation

```bash
codex exec --skip-git-repo-check "Review this Claude Code skill for quality. Check for:
1. Frontmatter: name and description are clear, description includes trigger conditions
2. Progressive disclosure: SKILL.md under 500 lines, references split out properly
3. No duplication between SKILL.md and reference files
4. Examples are concrete and minimal, not verbose explanations
5. Constraints are actionable (MUST/MUST NOT), not vague guidelines
6. No unnecessary files (README.md, CHANGELOG.md, etc.)
Skill content: <skill content>"
```

### Review Criteria

| Criterion | Pass | Fail |
|-----------|------|------|
| Description includes triggers | "Use when..." present | Missing trigger conditions |
| SKILL.md size | Under 500 lines | Over 500 lines without split |
| No duplication | Info in one place only | Same info in SKILL.md and references |
| Examples over explanations | Concrete code/usage examples | Walls of explanatory text |
| Lean structure | Only necessary files | README.md, CHANGELOG.md, etc. |
| Naming convention | `my-` prefix for custom | Missing prefix or renamed original |

## Frontmatter for Custom Skills

```yaml
---
name: my-example-skill
description: [What it does]. [When to use it — explicit triggers]. Derived from/inspired by [original-skill-name] with [what's different].
---
```

Always mention the origin in the description when forking. This helps track provenance.

## Directory Layout

```
~/.claude/skills/
├── frontend-design/          # Original (installed) — READ ONLY
├── n8n-code-javascript/      # Original (installed) — READ ONLY
├── skill-creator/            # Original (installed) — READ ONLY
├── my-flightphp-pro/         # Custom (user-created)
├── my-bpm-skill-optimizer/   # Custom (derived from skill-creator)
└── ...
```

## GitHub Issue Tracking

All skill development plans and progress are tracked in GitHub Issues, never in separate plan files.

- Plans -> Issue body or comments
- Progress -> Issue comments
- Codex review results -> Issue comments
- No `ISSUE_X_PLAN.md` or similar files

## Team Orchestration Mode

For complex skill development (multiple skills, large refactoring, cross-skill dependencies), use agent team orchestration with Codex-reviewed quality gates and milestone-tracked lifecycle.

Read `references/team-orchestration.md` for the complete phased workflow, milestone definitions, Codex review commands, and team coordination rules.

## Library Integration

After creating or optimizing a skill, use `my-library-push` to sync it to the Git repository. See `my-library-manager` skill for the full push/pull workflow and conventions for all artefact types (not just skills).

## Reference Files

### `references/team-orchestration.md`
Read when: orchestrating a team to build or refactor multiple skills in parallel, setting up milestone-based issue tracking for skill development, spawning and coordinating agent teammates, running Codex review gates, or managing the full development lifecycle from discovery through PR synthesis.
