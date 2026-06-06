---
name: athanor-learn
description: On-demand "learn this" — capture a user-stated offline fact into the KB through the FULL pipeline (graph + qdrant + digest + supervisor audit), the same backend the Stop-hook distiller uses, but fired immediately mid-session. Triggered ONLY by an explicit user learn signal. Supersedes the old graph-only live-graph-writes path.
---

# athanor-learn

The user stated a durable fact they want remembered ("peer said always pass `x-random-header` for the `abc` api — learn this") and asked you to learn it. Your job: act as a **live distiller** for that one fact and run it through the same commit pipeline the Stop hook uses, so it is searchable in the *next* session, not just this one.

This supersedes `live-graph-writes`. Every capture/learn trigger now runs the full pipeline (graph + vector index + digest + audit), never a graph-only write.

## When to run

ALL must hold:

1. The user used an explicit learn/capture signal: `learn this/it/that`, `add (this) to my (2nd|second) brain`, `memorize this`, `learn … in this codebase`, `remember`, `note that`, `important to know`, `for future reference`, `key insight`, `capture this`.
2. The fact is **durable** (useful in a future session, not just now).
3. The fact is **specific** (concrete entities — a service, an API, a header, a rule — not a vague impression).
4. You can quote an **evidence_snippet ≥20 chars** verbatim from the conversation.

If not all four hold, do NOT run this — let the end-of-session distiller handle it.

## Recipe

### 1. Identify the live session + a dedicated learn session id

```bash
LIVE_SID="${CLAUDE_SESSION_ID:-}"          # the current user session
LEARN_SID="learn-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
```

`LEARN_SID` MUST be distinct from `LIVE_SID` — that keeps the learn digest from colliding with the live session's end-of-session digest.

### 2. Extract artifacts from the stated fact

Decompose the fact into the 5 universal entity types. Typical shape for an API/integration fact:

- `Concept` for each named thing (`abc-api`, `x-random-header`).
- `Finding` for the rule/discovery (`abc-api-requires-x-random-header`), with a `summary`.
- relations tying them (schema-valid tuples — see `protocol/schema/relation-types.json`). The **Finding's `summary` carries the semantics**; relations just link nodes for traversal. Prefer neutral links: `Finding REFERENCES Concept` (for each named thing) and/or `Concept RELATED_TO Concept`. **Do NOT encode "callers must pass X" as `DEPENDS_ON`** — `DEPENDS_ON` means *subject cannot function without object*, which is rarely what an integration/requirement fact means and inverts graph traversal. Reserve `DEPENDS_ON`/`CAUSES` for true causal/dependency facts.
- one `observation` on the Finding carrying the **verbatim** statement + any source link.

Also emit ONE `Session` entity to anchor the digest and give recall a temporal hit:
`outcome=completed`, `occurred_at=<now>`, `summary="learned: <one line>"`.

`canonical_name` rule: lowercase kebab, `^[a-z][a-z0-9-]{0,127}$`.

### 3. Stage every artifact via the wrappers (entities FIRST)

```bash
export KB_SESSION_ID="$LEARN_SID"
```

Entities and the Session before relations (relations reject if an endpoint isn't staged yet), observations last.

Entity:
```bash
echo '{"entity_type":"Concept","canonical_name":"abc-api","source_session_id":"'"$LEARN_SID"'","created_at":"<ISO8601Z>","domain":"software-engineering"}' \
  | bash .claude/hooks/lib/kb-write-entity.sh
```
Finding adds `"summary":"…"` (10–500 chars). Session adds `"session_id":"$LEARN_SID","occurred_at":"<ISO>","outcome":"completed","summary":"…"`.

Relation (neutral link; the Finding summary holds the actual requirement):
```bash
echo '{"subject_type":"Finding","subject_name":"abc-api-requires-x-random-header","predicate":"REFERENCES","object_type":"Concept","object_name":"abc-api","source_session_id":"'"$LEARN_SID"'"}' \
  | bash .claude/hooks/lib/kb-write-relation.sh
echo '{"subject_type":"Finding","subject_name":"abc-api-requires-x-random-header","predicate":"REFERENCES","object_type":"Concept","object_name":"x-random-header","source_session_id":"'"$LEARN_SID"'"}' \
  | bash .claude/hooks/lib/kb-write-relation.sh
```

Observation (`evidence_snippet` ≥20 chars, verbatim; put any source link in `observation`):
```bash
echo '{"entity_type":"Finding","entity_name":"abc-api-requires-x-random-header","observation":"Peer <name> confirmed every abc-api call must send X-Random-Header. Source: <link>","evidence_snippet":"<verbatim user statement ≥20 chars>","source_session_id":"'"$LEARN_SID"'"}' \
  | bash .claude/hooks/lib/kb-write-observation.sh
```

Read each wrapper response:
- `ok:<id>` → staged, continue.
- `reject:predicate-not-in-locked-vocabulary:X` or `reject:tuple-not-in-schema:…` → pick a different schema-valid relation; do NOT invent a predicate.
- `reject:*vocabulary*` (a genuinely new entity-type/term) → append to `.athanor/_state/pending-vocab-additions.json`, tell the user one line ("new term 'X' → pending vocab, approve via /athanor vocab-extend"), skip that artifact.
- other `reject:<schema>` → tell the user the constraint, fix, retry.
- `skip:already-written:<id>` → already in KB, continue.

Do NOT call `mcp__knowledge-graph__*` yourself. The committer does all graph writes.

### 4. Commit + audit through the full pipeline

```bash
bash .claude/hooks/lib/kb-learn-commit.sh "$LEARN_SID" "$LIVE_SID"
```

This prepares the manifest, checks the kill switch, spawns `kb-committer` (graph + confidence ledger + digest + Qdrant index), writes the `learned-ids` marker for the end-of-session distiller, then spawns `distillation-supervisor` for an adversarial audit (non-approve → HITL flag). It never touches the live session's distill cursor/pending.

### 5. Confirm to the user — ONE line

Echo the script's summary, e.g.:

> Learned → KB: `abc-api`, `x-random-header` (Finding + DEPENDS_ON). Committed, indexed, supervised:approve. Recall will surface this next time.

If `kb-learn-commit.sh` exits non-zero, say so plainly and point at `.athanor/_state/last-learn-commit.log` — do not claim success.

## Forbidden

- ❌ Running without an explicit user learn/capture trigger.
- ❌ Capturing speculation ("might be a leak — learning it").
- ❌ Calling `mcp__knowledge-graph__*` directly (only the committer writes the graph).
- ❌ Inventing a vocabulary term, entity type, or relation predicate (route to HITL).
- ❌ Reusing the live session id as `LEARN_SID`.
- ❌ Touching `distill-cursor.json` / `distill-pending.jsonl`.
