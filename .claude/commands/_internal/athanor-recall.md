---
description: INTERNAL — execute canonical recall plan against the KB. Auto-invoked by hooks; user goes through "just talk".
---

# _internal/athanor-recall

Args: `$ARGUMENTS` = the natural-language query.

Process (deterministic, follows athanor-recall skill):

1. `bash .claude/hooks/lib/kb-recall.sh "$ARGUMENTS"` — get the canonical plan.
2. Execute the plan's 4 steps in parallel:
   - `mcp__plugin_socraticode_socraticode__codebase_context_search` × 3 (artifacts: athanor-runbooks, athanor-sessions, athanor-skills)
   - `mcp__knowledge-graph__search_memories`
3. Apply the frozen merge formula from the plan output.
4. Cap to ≤8 results, group by type.
5. Print paths only, with score and confidence — do NOT bulk-read bodies.

Use `athanor-recall` skill for any ambiguity. Never deviate from frozen weights.
