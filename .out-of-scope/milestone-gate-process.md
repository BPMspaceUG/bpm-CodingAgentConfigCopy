# Milestone lifecycle, Codex gates and landing sweeps

This repository does not run a milestone lifecycle (`planned`, `test-approved`,
`finding-recorded`, …), segregation-of-duty review gates by a second model, or
tooling that verifies those gates (`tests/verify_gate.sh`, `tests/gate_sweep.sh`).

## Why this is out of scope

The process was retired on 2026-09-18 in #134 (commit `ef85483`): the
lifecycle text left `CLAUDE.md`, `agent.md` and the self-built agents were
deleted, and so were the gate scripts and their suites. Work now follows the
mattpocock-skills workflow (`docs/agents/`): an issue labelled
`ready-for-agent` is implemented test-first, reviewed on two axes by
`/code-review` (Standards against `CODING_STANDARDS.md`, Spec against the
issue), committed straight to `main` and closed with a comment that names the
commits and the evidence.

The retired process produced more issues about itself than about the product:
of #87–#125, more than half concerned gates, milestones or the test
infrastructure built to police them. Every request below either hardens a gate
that no longer exists, or reports a state (`planned`, `test-approved`) that no
longer has a meaning. Reviving any of them would mean reviving the process.

What remains true and is kept: commits name their issue, every suite is
registered and guarded (`tests/test_suite_registration.sh`), CI runs the suite
and shellcheck on every push (`.github/workflows/ci.yml`), and an issue closes
only with evidence in its closing comment.

## Prior requests

- #87: Codex review gate cannot run commands (bubblewrap sandbox)
- #90: SoD gates are unenforced
- #98: test-approved commits stranded on a local branch
- #104: scheduled landing sweep over test-approved issues
- #112: test-approved issues with no commit
- #118: verify_gate.sh Invariant A unreliable
- #123: enforce the finding-only lifecycle
- #124: `planned` set on issues with no plan
- #125: test-approved issues citing never-committed files
