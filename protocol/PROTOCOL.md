# Universal KB Protocol — v2

`athanor` is a universal second brain for any topic — coding, research, product,
oncall, writing, anything. This protocol governs every read/write to its
knowledge base (Neo4j graph + SocratiCode/Qdrant vector index + filesystem).

**MANDATORY**: ALL agents (distiller, supervisor, main agent) MUST follow this
protocol. Wrapper scripts at `.claude/hooks/lib/kb-*.sh` enforce it at runtime.
Direct calls to `mcp__knowledge-graph__*` or `codebase_context_search` from any
agent are protocol violations.

## Why

Without a protocol, different sessions/models will write the KB differently:
naming drift (`care` vs `Care` vs `care-service`), schema drift, relation-type
drift, observation-phrasing drift. The KB rots into noise within weeks. This
protocol locks the shape so the same prompt produces semantically equivalent
output across sessions and models.

## The 8 layers

| Layer | What | Where |
|---|---|---|
| L1 | Schema validation | `schema/entity-types.json`, `schema/relation-types.json`, `schema/relation-envelope.json`, `schema/observation-types.json` |
| L2 | Closed vocabulary | `vocabulary/*.txt` |
| L3 | Wrapper scripts (only write path) | `.claude/hooks/lib/kb-write-*.sh` |
| L4 | Frozen retrieval algorithm | `recall-algorithm.md` |
| L5 | Idempotent IDs (content hash) | `kb-common.sh::hash_id` |
| L6 | Qdrant collection contract (model owned by SocratiCode) | `embeddings.lock` |
| L7 | Golden test fixtures | `test-fixtures/` |
| L8 | Protocol version + migrations | `version.txt`, `migrations/` |

## Entity types (5 universal)

These are topic-agnostic. The same five types describe a bug fix, a research
finding, a product decision, or an oncall incident.

| Type | What it captures |
|---|---|
| `Concept` | Any named thing worth knowing: tool, service, person, library, feature, organization, technology |
| `Finding` | Something discovered, concluded, or observed: bug, insight, root cause, hypothesis, anomaly, risk |
| `Procedure` | Repeatable steps or process: runbook, setup guide, debugging workflow, recipe, methodology |
| `Pattern` | Recurring structure, problem type, or solution approach: design pattern, failure mode, anti-pattern |
| `Session` | A work session capturing what was worked on, discovered, and the outcome |

All types share: `canonical_name`, `entity_type`, `source_session_id`, `created_at` (required);
`confidence`, `domain`, `tags`, `summary` (optional). `Finding` also requires `summary`.
`Session` also requires `session_id`, `occurred_at`, `outcome`. `Procedure` may carry an optional `outcome`.

## Relation predicates (9 universal, LOCKED)

| Predicate | Allowed (subject → object) |
|---|---|
| `REFERENCES` | any → any |
| `ADDRESSES` | Procedure\|Concept → Finding\|Concept |
| `OBSERVED_IN` | Finding\|Pattern → Session |
| `RESOLVED_BY` | Finding → Procedure |
| `INSTANCE_OF` | Finding\|Concept → Pattern |
| `RELATED_TO` | any → any |
| `CORRECTED_IN` | any → Session |
| `SUPERSEDES` | Finding\|Procedure\|Pattern → Finding\|Procedure\|Pattern |
| `DISPUTED_BY` | Finding\|Procedure\|Pattern → Session\|Concept |

## Write protocol

1. Compose payload as JSON matching `schema/entity-types.json` (or relation/observation schema).
2. Call `kb-write-entity.sh '<json>'` (or `kb-write-relation.sh`, `kb-write-observation.sh`).
3. Wrapper validates schema → vocabulary → computes deterministic ID → checks idempotency.
4. On `ok:<id>` → wrapper has staged the write to `_staging/<session>/manifest.jsonl` and audit-logged to `_state/kb-writes.jsonl`. Caller then invokes the corresponding `mcp__knowledge-graph__*` tool with the validated payload.
5. On `reject:<reason>` → STOP. Do not call MCP. Surface error to user (or stage to HITL if vocab-related).
6. On `skip:already-written` → no-op. Idempotency hit.

## Read protocol

1. Call `kb-recall.sh '<query>'`. It outputs the canonical recall plan.
2. Execute the plan: `codebase_context_search` over each artifact (athanor-runbooks, athanor-sessions, athanor-skills) + `mcp__knowledge-graph__search_memories` for graph fulltext + 1-hop expansion via `find_memories_by_name`.
3. Merge with frozen weights from `recall-algorithm.md`:
   `score = 0.50 * vector_norm + 0.30 * graph_match + 0.15 * confidence + 0.05 * recency`
4. Return top-K (default K=8) grouped by type. Paths only, not bodies. Caller decides what to Read.

## Vocabulary growth

Closed vocabularies (entity-types, relations, confidence-tiers, session-outcomes)
are extended ONLY via `/athanor-vocab-extend` (HITL). Distiller proposes additions
in `.athanor/_state/pending-vocab-additions.json`; user reviews and approves.
`domain` and `tags` are intentionally free-form — the distiller infers them per
session — so no closed vocabulary gates them.

`relations.txt` is **LOCKED** — bumping requires protocol version bump.

## Versioning

`version.txt` holds current protocol version (`vN`). All entities are tagged
with `created_under_protocol: vN`. Bumping requires:

1. Migration script at `protocol/migrations/v<N>-to-v<N+1>.sh` covering all existing entities. Each must be idempotent (safe to re-run).
2. Updated golden test fixtures under `test-fixtures/`.
3. `/athanor-protocol-bump` command runs the migration, updates `version.txt`,
   re-validates the entire KB.

## Contract for agents

- **DO**: call wrappers for every read/write. Treat `reject:` as terminal.
- **DON'T**: call `mcp__knowledge-graph__create_entities|create_relations|add_observations`
  without first getting `ok:<id>` from the corresponding wrapper.
- **DON'T**: invent vocabulary terms. If a term is not in `vocabulary/`, route via
  `pending-vocab-additions.json` and stop.
- **DON'T**: change retrieval weights. They are frozen in `recall-algorithm.md`.

## Non-goals (P1)

- Inline supervisor (P2)
- Kill switch (P2)
- Provenance metadata enrichment (P2 will add)
- Weekly auditor (P2)
- Bypass detection (P2)
