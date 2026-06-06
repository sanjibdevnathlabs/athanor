---
name: athanor-protocol
description: MANDATORY rulebook for all athanor KB operations. Read this before any read/write to Neo4j knowledge graph or SocratiCode vector index. Defines schema, vocabulary, write/read protocols, idempotency, and version migrations. All distillers, supervisors, and the main agent must comply.
---

# athanor-protocol

The single source of truth for KB operations. Wrappers in `.Codex/hooks/lib/kb-*.sh` enforce this protocol at runtime. The protocol spec lives at `protocol/` (committed to git).

## TL;DR for agents

- **Writes**: always through `kb-write-{entity,relation,observation}.sh`. Wrapper returns `ok:<id>` → then call `mcp__knowledge-graph__*`. Anything else → stop or route to HITL.
- **Reads**: always through `kb-recall.sh` for the canonical plan, then execute steps with frozen merge weights.
- **Vocabulary**: closed sets at `protocol/vocabulary/`. Missing term → append to `_state/pending-vocab-additions.json`, do NOT invent.
- **Embedding model**: NOT pinned by athanor. SocratiCode owns embedding (one model for index + query → consistent by construction). Change the model → re-index all artifacts via `codebase_context_index`.

## Write protocol (entity)

```bash
export KB_SESSION_ID=<session-id>
echo '{
  "entity_type": "Concept",
  "canonical_name": "payment-service",
  "domain": "software-engineering",
  "source_session_id": "<session-id>",
  "created_at": "2026-05-06T14:32:00Z"
}' | bash .Codex/hooks/lib/kb-write-entity.sh
```

Possible outputs (read exactly):

| Output | Meaning | What you do |
|---|---|---|
| `ok:<id>` | Validated + staged | Call `mcp__knowledge-graph__create_entities` with this payload |
| `reject:vocabulary-not-in-X` | Vocab miss | Append to `pending-vocab-additions.json`; do NOT call MCP |
| `reject:<schema reason>` | Malformed | Log + STOP; do NOT call MCP |
| `skip:already-written:<id>` | Idempotency hit | Reuse the id; no MCP call needed |

## Write protocol (relation)

```bash
echo '{
  "subject_type": "Finding",
  "subject_name": "checkout-timeout-2026-05-01",
  "predicate": "RESOLVED_BY",
  "object_type": "Procedure",
  "object_name": "connection-pool-resize",
  "source_session_id": "<session-id>"
}' | bash .Codex/hooks/lib/kb-write-relation.sh
```

Predicate must be in `vocabulary/relations.txt` (LOCKED). Tuple `(subject_type, predicate, object_type)` must match an entry in `schema/relation-types.json`. Otherwise `reject:`.

## Write protocol (observation)

```bash
echo '{
  "entity_type": "Finding",
  "entity_name": "checkout-timeout-2026-05-01",
  "observation": "checkout p99 jumped to 4200ms within 2 minutes of peak load",
  "evidence_snippet": "p99=4200ms, started 14:32 UTC ... connection pool maxed at 50 conns",
  "source_session_id": "<session-id>"
}' | bash .Codex/hooks/lib/kb-write-observation.sh
```

`evidence_snippet` is mandatory and must be ≥20 chars. The wrapper enforces this provenance gate.

## Read protocol

```bash
bash .Codex/hooks/lib/kb-recall.sh "high latency on care service"
```

Returns a JSON plan with:
1. Three `codebase_context_search` calls (runbooks, sessions, skills artifacts)
2. One `mcp__knowledge-graph__search_memories` call
3. One `mcp__knowledge-graph__find_memories_by_name` 1-hop expansion
4. One disputed-entity filter step (excludes any entity that is the *subject* of a `DISPUTED_BY` relation before scoring; the relation is set by the supervisor and review agents when an entity is flagged wrong)
5. A 0–10 additive scoring rubric (see `protocol/recall-algorithm.md`)
6. Output caps: ≤3 runbooks, ≤2 sessions, ≤3 graph relations

Execute the plan exactly as returned. Do NOT skip the disputed filter step.

## Vocabulary

Closed sets:
- `entity-types.txt` — `Concept`, `Finding`, `Procedure`, `Pattern`, `Session`, **LOCKED**
- `relations.txt` — 9 predicates, **LOCKED**
- `confidence-tiers.txt` — `unverified`, `tested`, `autonomous`, **LOCKED**
- `session-outcomes.txt` — `resolved`, `mitigated`, `open`, `abandoned`, **LOCKED**

Missing term → append a JSON line to `.athanor/_state/pending-vocab-additions.json`:

```jsonc
{"ts":"...","type":"entity-types","term":"Decision","context":"...","session_id":"..."}
```

Then continue distilling. Do NOT block. User reviews via `/athanor vocab-extend`.

## Idempotency

IDs are deterministic content hashes:
- entity_id = `sha256("entity_type:canonical_name:")[:16]`   # note: trailing colon from printf '%s:'
- relation_id = `sha256("subject_id:predicate:object_id:")[:16]`
- observation_id = `sha256("entity_id:observation_text:")[:16]`

The trailing colon is an implementation artifact of `kb-common.sh::kb_hash_id` using `printf '%s:' "$@"`. External tools must include the trailing colon to reproduce IDs.

Re-writing the same content → same ID → wrapper returns `skip:already-written`. No duplicates.

## Forbidden patterns

- ❌ Calling `mcp__knowledge-graph__create_entities` without first getting `ok:` from `kb-write-entity.sh`
- ❌ Inventing vocabulary terms
- ❌ Changing recall weights
- ❌ Writing to `.athanor/runbooks/` or `.athanor/local-skills/` without a corresponding entity write
- ❌ Bypassing wrappers because "it's just a small thing"

## Version & migrations

Current: `v2` (in `protocol/version.txt`). The v1→v2 migration script lives at `protocol/migrations/v1-to-v2.sh` (idempotent, safe to re-run). The v1→v2 migration (oncall-specific model → 5 universal entity types) is complete; every entity is now tagged `created_under_protocol: v2` by `kb-write-entity.sh`. Bumping to the next version requires:
1. Migration script in `protocol/migrations/v<N>-to-v<N+1>.sh`
2. Updated golden fixtures in `test-fixtures/`
3. `/athanor protocol-bump` command (HITL)
