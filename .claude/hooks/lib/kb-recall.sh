#!/usr/bin/env bash
# kb-recall.sh — output the canonical recall plan for a query.
# Caller (LLM) executes the plan, applies the frozen merge formula, returns top-K.
#
# Usage:
#   kb-recall.sh "high latency on care service"
#
# Output: JSON describing the steps to execute (vector calls + graph calls + merge weights).
# This script does NOT call MCP itself — that's the caller's responsibility, but the
# plan is identical for every caller, ensuring determinism.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"

QUERY="${1:?usage: kb-recall.sh \"<query>\"}"
K="${2:-8}"
# Ensure K is a positive integer
[[ "$K" =~ ^[0-9]+$ ]] || K=8

# athanor does NOT pin/verify the embedding model. SocratiCode owns embedding and
# uses one configured model for both indexing and querying, so index/query
# consistency holds by construction. A separate athanor-side check was redundant
# and fired false "model not found" warnings when its hardcoded value drifted.

# Pre-flight: detect an empty KB (fresh install) so the caller knows recall
# steps will legitimately return nothing. Best-effort; never fails.
EMPTY_KB_NOTE=""
# Count distilled session digests. find avoids ls-glob edge cases; tr strips the
# leading whitespace wc emits (otherwise [ -eq ] sees " 0" and errors).
SESSION_COUNT=$( { find "$KB_ROOT/.athanor/distilled/sessions" -maxdepth 1 -name '*.md' -type f 2>/dev/null || true; } | wc -l | tr -d '[:space:]')
SESSION_COUNT=${SESSION_COUNT:-0}
if [ "$SESSION_COUNT" -eq 0 ]; then
  EMPTY_KB_NOTE="KB appears empty — no distilled sessions found. Recall steps will return empty results. This is normal on a fresh install."
fi

# Build the warnings array (only non-empty entries).
WARN_ITEMS=()
[ -n "$EMPTY_KB_NOTE" ] && WARN_ITEMS+=("$(printf '%s' "$EMPTY_KB_NOTE" | jq -Rs .)")
if [ "${#WARN_ITEMS[@]}" -gt 0 ]; then
  WARNINGS_JSON="[$(IFS=,; echo "${WARN_ITEMS[*]}")]"
else
  WARNINGS_JSON="[]"
fi

# Output canonical plan (frozen — do NOT change without protocol bump)
cat <<EOF
{
  "protocol_version": "v2",
  "query": $(printf '%s' "$QUERY" | jq -Rs .),
  "k": $K,
  "steps": [
    {
      "id": 1,
      "tool": "mcp__plugin_socraticode_socraticode__codebase_context_search",
      "args": {
        "query": $(printf '%s' "$QUERY" | jq -Rs .),
        "artifactName": "athanor-runbooks",
        "limit": 5,
        "projectPath": "$KB_ROOT"
      }
    },
    {
      "id": 2,
      "tool": "mcp__plugin_socraticode_socraticode__codebase_context_search",
      "args": {
        "query": $(printf '%s' "$QUERY" | jq -Rs .),
        "artifactName": "athanor-sessions",
        "limit": 3,
        "projectPath": "$KB_ROOT"
      }
    },
    {
      "id": 3,
      "tool": "mcp__plugin_socraticode_socraticode__codebase_context_search",
      "args": {
        "query": $(printf '%s' "$QUERY" | jq -Rs .),
        "artifactName": "athanor-skills",
        "limit": 3,
        "projectPath": "$KB_ROOT"
      }
    },
    {
      "id": 4,
      "tool": "mcp__knowledge-graph__search_memories",
      "args": {"query": $(printf '%s' "$QUERY" | jq -Rs .), "limit": 10}
    },
    {
      "id": 5,
      "tool": "mcp__knowledge-graph__find_memories_by_name",
      "description": "1-hop graph expansion: call with names of entities returned by step 4. Retrieve their connected entities (Findings, Procedures, Patterns, Sessions they relate to via any relation predicate).",
      "instruction": "Extract entity names from step 4 results. Call find_memories_by_name with those names. Add results to the candidate pool with scoring_rubric graph_direct_hit bonus.",
      "cap": 5
    },
    {
      "id": 6,
      "type": "filter",
      "description": "Disputed entity exclusion — remove any candidate that is the subject of a DISPUTED_BY relation before scoring",
      "instruction": "Collect ALL candidate entity names returned by steps 1-5 into a single array. Make ONE call to mcp__knowledge-graph__find_memories_by_name with all names in the array. From the returned subgraph, identify any entity that has an outgoing DISPUTED_BY relation (i.e., appears as the source of a DISPUTED_BY edge). Exclude those entities from the final scored candidate pool. This is a SINGLE batched call — do not loop per-entity.",
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
      "vector_rank_top3 (returned in top 3 by codebase_search): +2",
      "graph_direct_hit (returned by search_memories with high confidence): +2"
    ],
    "tie_break": "prefer procedures over sessions over graph_relations",
    "hard_exclusions": ["any candidate that is the subject of a DISPUTED_BY relation"]
  },
  "output_caps": {"runbooks": 3, "sessions": 2, "graph_relations": 3, "total_max": $K},
  "empty_results_handling": {
    "if_codebase_search_errors": "Treat as empty results array — do NOT retry or surface the error. Log: 'SocratiCode not indexed yet — no vector results available.'",
    "if_search_memories_empty": "Treat as empty results array — this is normal on a fresh install.",
    "if_all_steps_empty": "No prior knowledge found for this query. Respond with: 'Investigating from scratch — no prior knowledge found in KB.' then proceed normally.",
    "after_disputed_filter": "If filtering removes all candidates, return empty results — do not fall back to disputed candidates.",
    "never_do": "Never surface a tool error to the user because the KB is empty. Always treat empty/error as 'no prior knowledge'."
  },
  "warnings": $WARNINGS_JSON
}
EOF
