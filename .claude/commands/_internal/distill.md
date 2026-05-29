---
description: INTERNAL — manually trigger the session-distiller for a given session id. Normally auto-fires from session-stop.sh.
---

# _internal/distill

Run the distiller against `$ARGUMENTS` (session id).

Resolution:
1. Look for transcript at `.athanor/raw/*-$ARGUMENTS.jsonl`. If not present, look at `~/.claude/projects/$(pwd | tr / -)/$ARGUMENTS.jsonl` and copy it to `.athanor/raw/`.
2. Invoke the session-distiller subagent via the Agent tool, passing the transcript path and session id.
3. Print the distiller's stdout report.

This command is callable by the agent but should not appear in user-visible slash menus. Users go through `/athanor distill <id>` instead.
