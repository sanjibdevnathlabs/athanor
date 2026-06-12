---
name: athanor-recall
description: Retrieve relevant runbooks, session digests, skills, and graph relations for an investigation query. Auto-invoked by .claude/hooks/auto-orchestrate.sh when user prompts contain investigation/symptom language. Internally executes the canonical recall plan from kb-recall.sh — never deviates from frozen weights.
---

# athanor-recall

Retrieve KB context for an investigation. Always use this skill before responding to investigation queries — never recall ad-hoc.

## When to invoke

- User mentions a known service, component, or entity name (free-form — no closed vocabulary in v2)
- User uses investigation language (latency, error, alert, oom, spike, etc.) — see `auto-orchestrate.sh` keyword list
- User explicitly asks "have we seen X before"
- Before drafting a runbook (to find existing related runbooks)

## How to invoke (deterministic)

### Step 1 — Get canonical plan (vectors already run)
```bash
bash .claude/hooks/lib/kb-recall.sh "<query verbatim>"
```

Returns JSON with `vector_results` (already computed), graph `steps`, scoring rubric, and warnings. **Do not modify the plan.** The three vector passes ran INLINE inside `kb-recall.sh` against the active driver — you do NOT call any vector tool yourself.

### Step 2 — Read `vector_results`, then execute the graph steps

`vector_results` is `{runbooks:[...], sessions:[...], skills:[...]}`, each item `{artifact, source_path, score, snippet}`. Treat top-3 by score per artifact as `vector_rank_top3` for scoring.

Then run the graph steps from the plan:

1. `mcp__knowledge-graph__search_memories` with the query (limit 10)
2. `mcp__knowledge-graph__find_memories_by_name` — 1-hop expansion: pass the entity names returned by step 1 to fetch their neighbors (cap 5). Add results to the candidate pool.
3. Disputed-entity filter: for each candidate in the pool, check whether it is the *subject* of a `DISPUTED_BY` relation via `mcp__knowledge-graph__find_memories_by_name`. If the entity has any outgoing `DISPUTED_BY` edge, exclude it from scoring. This relation is set by the supervisor and review agents when an entity is flagged wrong — disputed entities never surface in recall.

If the plan carries a `warnings` array (e.g. vector layer down, or embedding-model drift vs the built collection), note it inline — vector results may be degraded or empty — but proceed; recall is never blocked on it (graph-only is valid).

### Step 3 — Apply the scoring rubric

Score each candidate 0–10 using ONLY result metadata (no file reads):
```
+4  concept_exact_match     (result entity name exactly matches a key term in the query prompt)
+3  finding_category_match  (result is a Finding whose summary domain matches the query's apparent domain)
+2  source=procedure AND outcome=resolved
+1  source=session AND occurred_recently (< 30 days)
+2  vector_rank_top3        (top 3 by score in vector_results, per artifact)
+2  graph_direct_hit        (search_memories high-confidence hit)
```
Tie-break: prefer procedures > sessions > graph_relations.

### Step 4 — Cap and group

- Top-3 runbooks (paths)
- Top-2 sessions (paths)
- Top-3 graph relations
- Total ≤ 8 items

### Step 5 — Return paths only

Output to context as a compact list:
```
relevant runbooks:
  - .athanor/runbooks/care/latency-spike.md (score=0.78, autonomous)
  - .athanor/runbooks/care/oom.md (score=0.42, tested)
relevant sessions:
  - .athanor/distilled/sessions/2026-04-22-abc.md (score=0.61)
graph:
  - care -[MANIFESTS]-> care-latency-spike-* (3 incidents)
```

Then decide which to `Read` based on the user's specific question. Do NOT bulk-read all results — that defeats the on-demand design.

## Constraints

- Empty KB / empty corpus → graceful empty output ("no prior knowledge — investigating from scratch"). Do not fabricate.
- Vector layer down or embedding-model drift → kb-recall.sh emits a non-blocking `warnings` entry and empty/degraded `vector_results`. Surface it but continue graph-only; recall is never blocked.
- Query <5 chars → reject (too vague).

## Anti-patterns

- ❌ Calling `mcp__knowledge-graph__search_memories` directly without `kb-recall.sh` plan
- ❌ Calling the vector layer directly (`vec.sh search`, driver REST) instead of using the plan's precomputed `vector_results`
- ❌ Reading all 8 results into context speculatively
- ❌ Adjusting the scoring rubric "just for this query"
- ❌ Caching plan output across different queries
