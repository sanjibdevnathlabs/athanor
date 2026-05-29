---
description: INTERNAL — run a deep KB audit via the kb-auditor agent (opus). On-demand only, ~$1–3 per run.
---

# _internal/athanor-audit

Args: `$ARGUMENTS` (optional: `--quick` for a 3-step subset)

Process:

1. Spawn the `kb-auditor` agent (or `general-purpose` + opus model if not registered yet) with prompt:

   ```
   Run the standard 7-step audit per .claude/skills/athanor-supervision/SKILL.md
   "Auditor — when and what" section. Write report to
   .athanor/_audit/<YYYY-MM-DD>-<runid>.md. Update
   .athanor/_state/health-score.json. Append HITL queue entries.
   Print: audit complete · health=<x> · findings=<n>
   ```

2. After agent completes, surface:
   - Path to the report
   - Current health score + delta
   - HITL queue entries added (count)
   - Whether kill switch was tripped

3. If health score < 0.7, the agent will have auto-tripped `auto_promotion`. Surface this prominently and ask the user to review via `/athanor review`.

## --quick mode

Skip steps 1 (groundedness sample), 2 (skill abandonment), 3 (alias detection). Run only golden test (step 5) + health update (step 6). Useful for fast checks; cost ~$0.50.
