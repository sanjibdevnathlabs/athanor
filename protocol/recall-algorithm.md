# Recall Algorithm — v2 (FROZEN)

Changing the algorithm or weights requires a protocol version bump.

## Inputs

- `query` (string): natural language question; look for Concepts, Findings,
  Procedures, or Patterns matching the query
- `K` (int, default 8): max results returned

## Steps

Steps 1–3 run INLINE inside `kb-recall.sh` (one query embed reused across three
artifact-filtered searches against the active driver). Their results are emitted
under `vector_results` in the plan; the caller does NOT call any vector tool.

1. **Vector pass — runbooks**:
   `vec search --artifact runbooks --k 5` (single collection, payload filter)
   → list of {artifact, source_path, score, snippet}

2. **Vector pass — sessions**:
   `vec search --artifact sessions --k 3`
   → list of {artifact, source_path, score, snippet}

3. **Vector pass — skills**:
   `vec search --artifact skills --k 3`
   → list of {artifact, source_path, score, snippet}

4. **Graph fulltext**:
   `mcp__knowledge-graph__search_memories(query)`
   → matched entities

5. **Graph 1-hop expansion** (emitted as step 5 in the recall plan):
   For each matched entity from step 4, fetch direct neighbors via
   `mcp__knowledge-graph__find_memories_by_name(names=[entity.name])`.
   Extract the entity names from step 4 results, call `find_memories_by_name`
   with those names, and add the returned neighbors (Concepts, Findings,
   Procedures, Patterns) to the candidate pool with the `graph_direct_hit`
   rubric bonus. Capped at 5 expansion results.

6. **Score** (scoring rubric, not a merge formula):

   The merge formula was retired. Confidence and recency terms required reading
   artifact frontmatter (which the protocol forbids), and vector/graph score
   normalisation across Qdrant RRF and Neo4j match scores was undefined. The
   recall plan now emits a `scoring_rubric` the LLM applies at rank time using
   only metadata it already has from the result sets (matched Concepts/Findings,
   category/domain, source type, rank position, graph hit) — no file reads
   required.

   Each candidate is scored 0–10:

   - `concept_exact_match` (a Concept in result matches a term in query): **+4**
   - `finding_category_match` (a Finding category or domain matches query): **+3**
   - `source=procedure` AND `outcome=resolved` in result: **+2**
   - `recent_session` (session occurred within 30 days): **+1**
   - `vector_rank_top3` (returned in top 3 by the vector pass for its artifact): **+2**
   - `graph_direct_hit` (returned by search_memories with high confidence): **+2**

   Tie-break: prefer procedures over sessions over graph_relations.

7. **Disputed-entity filter** (emitted as step 6 in the recall plan):
   For each candidate entity returned in prior steps, check whether it is the
   *subject* of a `DISPUTED_BY` relation using
   `mcp__knowledge-graph__find_memories_by_name`. If the returned entity has any
   outgoing `DISPUTED_BY` edge, exclude it from scoring. This relation is set by
   the supervisor and review agents when an entity is flagged wrong. Disputed
   entities must never surface in recall even if semantically similar.

8. **Group + cap**:
   - Top-3 Runbooks
   - Top-2 Sessions
   - Top-3 graph relations
   - Total ≤ 8 (`output_caps.total_max`, consistent with the sub-caps);
     plan still reports the request-level `K` cap.

9. **Output**: paths only, not bodies. Caller decides what to Read.

## Determinism guarantees

- Same query string → same retrieval (modulo new data writes).
- Embedding is owned by athanor now (SocratiCode removed). The model is whatever
  `protocol/vector.config` (or a `VEC_EMBED_MODEL` env override) specifies — it is
  configurable, not pinned. `vec.sh` uses the SAME model for indexing and querying,
  so query and index vectors are always in the same space by construction. The
  built collection's model + dim are fingerprinted in `.athanor/_state/embeddings.lock`;
  `kb-recall.sh` emits a non-blocking drift warning if the config model diverges
  from the fingerprint. Changing the model requires `kb-reindex.sh --rebuild`
  (re-embed everything from the corpus) — existing vectors are model- and dim-specific.
- The scoring rubric is a fixed set of additive rules over result metadata; no
  model-side ranking calls and no frontmatter reads.
