#!/usr/bin/env bash
# kb-recall.sh — run the vector passes inline, emit the residual graph plan.
#
# SocratiCode is gone. The three vector passes (runbooks / sessions / skills) now
# run HERE, directly against the active driver via vec.sh, and their results are
# embedded in the output under "vector_results". The caller (LLM) then executes
# only the remaining GRAPH steps (knowledge-graph MCP) and merges everything with
# the frozen scoring rubric.
#
# Usage:
#   kb-recall.sh "high latency on care service" [K]
#
# Fail-soft: if the vector layer is down (Qdrant/Ollama unreachable), the vector
# passes return empty and recall continues graph-only. Never errors the caller.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"

QUERY="${1:?usage: kb-recall.sh \"<query>\"}"
K="${2:-8}"
[[ "$K" =~ ^[0-9]+$ ]] || K=8

# Resolve a timeout command so a hung embed/search can't stall a user prompt.
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_CMD="timeout 20"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD="gtimeout 20"; fi

WARN_ITEMS=()

# --- Drift guard: config model vs the model the collection was built with ---
LOCK_MSG="$($TIMEOUT_CMD bash "$KB_VEC" lockcheck 2>/dev/null || true)"
DRIFT_OK="$(printf '%s' "$LOCK_MSG" | jq -r '.ok // true' 2>/dev/null || echo true)"
if [ "$DRIFT_OK" = "false" ]; then
  WARN_ITEMS+=("$(printf '%s' "$LOCK_MSG" | jq -r '.message' | jq -Rs .)")
fi

# --- Vector passes (inline, single embed across the three artifacts) ---
VECTOR_RESULTS="$($TIMEOUT_CMD bash "$KB_VEC" recall --query "$QUERY" 2>/dev/null || true)"
if ! printf '%s' "$VECTOR_RESULTS" | jq -e . >/dev/null 2>&1; then
  VECTOR_RESULTS='{"runbooks":[],"sessions":[],"skills":[]}'
  WARN_ITEMS+=("$(printf '%s' "vector layer unavailable — recall is graph-only this turn" | jq -Rs .)")
fi

# Empty-KB note (no corpus yet).
CORPUS_RECS=0
if [ -d "$KB_CORPUS_DIR" ]; then
  CORPUS_RECS=$( { find "$KB_CORPUS_DIR" -maxdepth 1 -name '*.ndjson' -type f 2>/dev/null || true; } | wc -l | tr -d '[:space:]')
fi
if [ "${CORPUS_RECS:-0}" -eq 0 ]; then
  WARN_ITEMS+=("$(printf '%s' "KB corpus empty — run kb-reindex.sh --backfill. Recall returns nothing. Normal on fresh install." | jq -Rs .)")
fi

if [ "${#WARN_ITEMS[@]}" -gt 0 ]; then
  WARNINGS_JSON="[$(IFS=,; echo "${WARN_ITEMS[*]}")]"
else
  WARNINGS_JSON="[]"
fi

# Output canonical plan. Vector results are precomputed inline; remaining steps
# are graph-only. Scoring rubric is FROZEN (unchanged from prior protocol).
cat <<EOF
{
  "protocol_version": "v2",
  "query": $(printf '%s' "$QUERY" | jq -Rs .),
  "k": $K,
  "vector_results": $VECTOR_RESULTS,
  "vector_results_note": "Precomputed by kb-recall.sh via the active vector driver. Each artifact lists {artifact, source_path, score, snippet}. Treat top-3 by score per artifact as vector_rank_top3 for scoring. Read source_path only if you need the full body.",
  "steps": [
    {
      "id": 1,
      "tool": "mcp__knowledge-graph__search_memories",
      "args": {"query": $(printf '%s' "$QUERY" | jq -Rs .), "limit": 10}
    },
    {
      "id": 2,
      "tool": "mcp__knowledge-graph__find_memories_by_name",
      "description": "1-hop graph expansion: call with names of entities returned by step 1. Retrieve their connected entities (Findings, Procedures, Patterns, Sessions they relate to via any relation predicate).",
      "instruction": "Extract entity names from step 1 results. Call find_memories_by_name with those names. Add results to the candidate pool with scoring_rubric graph_direct_hit bonus.",
      "cap": 5
    },
    {
      "id": 3,
      "type": "filter",
      "description": "Disputed entity exclusion — remove any candidate that is the subject of a DISPUTED_BY relation before scoring",
      "instruction": "Collect ALL candidate entity names returned by the graph steps into a single array. Make ONE call to mcp__knowledge-graph__find_memories_by_name with all names in the array. From the returned subgraph, identify any entity that has an outgoing DISPUTED_BY relation (i.e., appears as the source of a DISPUTED_BY edge). Exclude those entities from the final scored candidate pool. This is a SINGLE batched call — do not loop per-entity.",
      "rationale": "A disputed entity was explicitly flagged as incorrect by a supervisor rejection or review agent. It must never surface in recall even if semantically similar."
    }
  ],
  "scoring_rubric": {
    "note": "Score each candidate 0-10 using only available metadata",
    "rules": [
      "concept_exact_match (result entity name exactly matches a key term in the query prompt): +4",
      "finding_category_match (result is a Finding whose summary domain matches the query's apparent domain): +3",
      "source=procedure AND outcome=resolved in result: +2",
      "source=session AND occurred_recently (< 30 days): +1",
      "vector_rank_top3 (returned in top 3 by the vector pass for its artifact): +2",
      "graph_direct_hit (returned by search_memories with high confidence): +2"
    ],
    "tie_break": "prefer procedures over sessions over graph_relations",
    "hard_exclusions": ["any candidate that is the subject of a DISPUTED_BY relation"]
  },
  "output_caps": {"runbooks": 3, "sessions": 2, "graph_relations": 3, "total_max": $K},
  "empty_results_handling": {
    "if_vector_results_empty": "Treat as no vector hits — proceed graph-only. The vector layer may be down (see warnings) or the corpus not yet built.",
    "if_search_memories_empty": "Treat as empty results array — this is normal on a fresh install.",
    "if_all_steps_empty": "No prior knowledge found for this query. Respond with: 'Investigating from scratch — no prior knowledge found in KB.' then proceed normally.",
    "after_disputed_filter": "If filtering removes all candidates, return empty results — do not fall back to disputed candidates.",
    "never_do": "Never surface a tool error to the user because the KB is empty. Always treat empty/error as 'no prior knowledge'."
  },
  "warnings": $WARNINGS_JSON
}
EOF
