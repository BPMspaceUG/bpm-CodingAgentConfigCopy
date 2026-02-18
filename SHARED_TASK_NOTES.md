# Shared Task Notes

## CRITICAL: SoD Compliance — HARD STOP RULE

**If your task involves writing or changing code: STOP HERE.**

You MUST complete these steps IN ORDER before touching any code:

1. **Post plan in the GitHub Issue** — If no issue exists, create one first
2. **Run `codex exec --skip-git-repo-check "<review prompt>"`** to get plan approval
3. **Receive explicit approval** — "PLAN AND AGENT/SKILL ASSIGNMENT APPROVED"
4. **Only then** implement
5. **Run `codex exec`** again to get implementation review
6. **Receive all 5 approvals** documented in the issue:
   - PLAN AND AGENT/SKILL ASSIGNMENT APPROVED
   - IMPLEMENTATION APPROVED
   - TEST DESIGN APPROVED
   - TEST RESULTS APPROVED
   - DOCUMENTATION UPDATED AND CONSISTENT APPROVED

If Codex unavailable → try Gemini (`gemini "<question>"`). If both unavailable → **STOP. Do NOT implement. Document the blocker.**

## Uncommitted Changes — Ready for Commit

### Issues #22 + #26 (SoD 5/5 APPROVED — ready to commit)

**Files changed:**
- `lib/env.sh` — Two fixes:
  - Issue #22: `env_cmd_install()` reordered to check `--yes` before `-t 0`
  - Issue #26: `env_interactive_install()` case patterns expanded: `Q|QUIT)` and `A|ALL)`
- `tests/test_env.sh` — Added regression test `test_env_yes_flag_bypasses_interactive`

All 5 Codex approvals documented in Issues #22 and #26.

### Issue #25 Phase 1 (SoD 5/5 APPROVED — ready to commit)

**Files changed:**
- `lib/backend_gokapi.sh` — `_gokapi_try_request()`: added verbose diagnostic logging (exit code, response length, single-line preview with newlines collapsed). Also fixes subtle `$?` capture bug.

All 5 Codex approvals documented in Issue #25.

### Issue #24 (SoD 5/5 APPROVED — ready to commit)

**Files changed:**
- `install.sh` — Added `_detect_shell_rc()`, `_cleanup_path_entry()`, rewrote `setup_path()` to persist PATH to shell RC files, updated `do_uninstall()` to clean up PATH entries
- `uninstall.sh` — Added `_cleanup_path_entry()`, updated `do_uninstall()` to clean up PATH entries
- `tests/test_install.sh` — 12 new tests (72 total, up from 60): RC detection, idempotency, cross-shell, cleanup, permission preservation, profile fallback

All 5 Codex approvals documented in Issue #24.

## Open Issues Status

| # | Title | Status |
|---|-------|--------|
| **#22** | `--yes` flag ignored | **FIXED** — 5/5 SoD, ready to commit |
| **#24** | PATH not persistent after reboot | **FIXED** — 5/5 SoD, ready to commit |
| **#25** | `cac pull` fails until `cac list` run | Phase 1 diagnostics **DONE** — 5/5 SoD, ready to commit. User needs to reproduce with `cac pull --verbose` for Phase 2. |
| **#26** | Interactive menu rejects "All" | **FIXED** — 5/5 SoD, ready to commit |
| **#27** | Script exits after session | **CLOSED** — Not a cac issue (SSH Manager). User confirmed closure. |

## Next Actions

1. **Commit** changes for Issues #22, #24, #25, #26 (automation handles this)
2. **Issue #25**: After deploy, user reproduces with `cac pull --verbose` on cold start. Phase 2 fix depends on diagnostic output.

## Blocked Issues

- **Issues #15, #18** — Security issues blocked on human action (key revocation + git history rewrite)

## Test Suite Notes

- 244/244 tests pass across 6 suites (bundle 16, security 23, utils 80, integration 29, install 72, environment 24)
- Gokapi test suites skipped (not found/not executable) — pre-existing
