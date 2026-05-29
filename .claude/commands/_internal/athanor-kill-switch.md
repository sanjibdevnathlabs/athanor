---
description: INTERNAL — inspect or reset the kill switch (HITL only).
---

# _internal/athanor-kill-switch

Args: `$ARGUMENTS` = `status` | `reset <flag> <reason>` | `trip <flag> <reason>` (last one is for testing only)

Calls into `.claude/hooks/lib/kill-switch-check.sh`:

```
status                            → bash .../kill-switch-check.sh status   (cat the JSON)
reset auto_promotion "<reason>"   → bash .../kill-switch-check.sh reset auto_promotion <user>
trip  auto_commit    "<reason>"   → bash .../kill-switch-check.sh trip auto_commit "<reason>"
```

Reset is HITL-only — print the reason to the user, ask for confirmation, then run.

After any reset, append to `.athanor/_state/hitl-decisions.jsonl`:
```jsonc
{"ts":"...","type":"kill_switch_reset","flag":"...","reason":"...","actor":"user"}
```
