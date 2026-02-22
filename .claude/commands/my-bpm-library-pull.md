---
allowed-tools: Bash
description: Pull my-prefixed items (skills, agents, commands, runbooks) from the Git repository to local ~/.claude/. Supports --dry-run, --only-skills, --only-agents, --only-commands, --only-runbooks, --verbose.
---

# /my-bpm-library-pull — Pull my-items from repo to local

Run the `my-bpm-library-pull` command to synchronise custom `my-` items from the Git repository to the local `~/.claude/` directory.

Pass any arguments the user provided via `$ARGUMENTS`.

```bash
my-bpm-library-pull $ARGUMENTS
```

After execution, summarise:
- How many items were new, modified, unchanged
- If `--dry-run` was used, note that no changes were made
- If errors occurred, suggest fixes (e.g., "run `git pull` in the repo first")
