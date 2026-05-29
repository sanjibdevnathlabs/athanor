---
description: INTERNAL — surface full provenance chain for a KB entity. Used to forensically inspect "who put this here, when, with what evidence".
---

# _internal/athanor-trace

Args: `$ARGUMENTS` = `<entity-canonical-name>` or `<entity-id-prefix>`

Process:

1. Resolve target. If looks like an entity name → `mcp__knowledge-graph__find_memories_by_name(names=[<name>])`. Else, treat as ID prefix.
2. Fetch the entity's:
   - `created_under_protocol`, `created_by_distiller_version`, `supervised_by_version`, `supervisor_approved`, `audit_evidence_hash`, `created_at` (from provenance enrichment)
   - All observations attached to it
   - All incoming + outgoing relations
3. Filter `.athanor/_state/kb-writes.jsonl` by entity id → get full audit trail of who wrote what when
4. Filter `.athanor/_state/kb-writes.jsonl` for any `supervisor-reject` rows that ever quarantined this entity
5. Find the originating session digest at `.athanor/distilled/sessions/<date>-<sid>.md` and link it

Output (markdown, terse):

```
TRACE care (Service)
  id: 24f8fd3236f2d765
  created: 2026-05-06T11:13:00Z under protocol v1
  by: distiller-20260506 / supervisor-20260506
  approved: yes
  evidence_hash: a3b41c92

OBSERVATIONS (3):
  - "p99 spiked..." (evidence: 2026-05-06T14:32:00Z transcript line 3)
  - "rolled back..." (evidence: 2026-05-06T14:48:00Z transcript line 8)

RELATIONS (incoming/outgoing):
  ← care-latency-spike-20260506 [MANIFESTS]
  → coralogix-dataprime-app-subsystem-filter [USES_PATTERN]

ORIGIN SESSION: .athanor/distilled/sessions/2026-05-06-eval-t1-care-latency.md

AUDIT TRAIL (5 entries):
  2026-05-06T11:13Z write-entity-staged
  2026-05-06T11:13Z write-observation-staged ×3
  2026-05-06T11:14Z supervisor-approve
```

If entity not found: `not-found:<name>`.
