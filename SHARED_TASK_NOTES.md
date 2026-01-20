# Shared Task Notes

## Current Status (2026-01-21, verified this iteration)

**All feature development complete.** Tests: 222/222 passing (6 test suites). Shellcheck: clean (info-level only).

**Open Issues: 2 (both blocked on human action)**

| Issue | Description | Status |
|-------|-------------|--------|
| #15 | Security review for public release | Blocked: awaiting key revocation + git history rewrite |
| #18 | API key breach detected | Blocked: awaiting key revocation |

## Required Human Actions

1. **Revoke leaked API keys:**
   - Historical: `j8aI5uDt9...` @ `offload.ico-cert.com`
   - Current: `2OVJ3oUoz...` @ `gokapi.bpmspace.org`

2. **Rewrite git history** (user stated: "will be done separately"):
   ```bash
   git filter-repo --invert-paths --path .env
   git push --force --all
   ```

3. **Close issues after remediation:**
   - #18 after keys revoked
   - #15 after full remediation + history rewrite

## Next Iteration

**No AI-actionable work remaining** until human completes key revocation and git history rewrite.

After remediation: close #18 and #15 via GitHub.
