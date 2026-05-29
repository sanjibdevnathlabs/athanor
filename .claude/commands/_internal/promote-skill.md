---
description: INTERNAL — bump a skill's confidence tier in the ledger after evidence accumulates.
---

# _internal/promote-skill

Args: `$ARGUMENTS` = `<skill-canonical-name> <new-tier>`

Tiers: `unverified` → `tested` → `autonomous`. Demotion in same syntax.

Process:
1. Read `.athanor/_state/confidence-ledger.json`.
2. Validate that the proposed transition matches evidence:
   - `tested` requires `uses >= 1` and `corrections == 0` for this session
   - `autonomous` requires `uses >= 3` and `corrections == 0` cumulative
3. Update the skill entry; write back atomically.
4. Append a row to `.athanor/_state/promotion-log.jsonl` with timestamp, before/after, evidence snapshot.

Reject if evidence insufficient. Reject if tier doesn't exist.
