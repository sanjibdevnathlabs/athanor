#!/usr/bin/env bash
# kb-write-relation.sh — validate + stage a relation write.
# Usage:
#   kb-write-relation.sh '{"subject_type":"Finding","subject_name":"care-p99-spike","predicate":"OBSERVED_IN","object_type":"Session","object_name":"sess-2026-05-06","source_session_id":"abc"}'

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"

PAYLOAD="${1:-$(cat)}"

kb_validate_json "$PAYLOAD" || kb_reject "invalid-json"

SUBJ_TYPE="$(kb_field "$PAYLOAD" subject_type)"
SUBJ_NAME="$(kb_field "$PAYLOAD" subject_name)"
PRED="$(kb_field "$PAYLOAD" predicate)"
OBJ_TYPE="$(kb_field "$PAYLOAD" object_type)"
OBJ_NAME="$(kb_field "$PAYLOAD" object_name)"
SESSION="$(kb_field "$PAYLOAD" source_session_id)"

[ -z "$SUBJ_TYPE" ] && kb_reject "missing-subject_type"
[ -z "$SUBJ_NAME" ] && kb_reject "missing-subject_name"
[ -z "$PRED" ] && kb_reject "missing-predicate"
[ -z "$OBJ_TYPE" ] && kb_reject "missing-object_type"
[ -z "$OBJ_NAME" ] && kb_reject "missing-object_name"
[ -z "$SESSION" ] && kb_reject "missing-source_session_id"

# subject_type and object_type must be one of the 5 universal types
case "$SUBJ_TYPE" in
  Concept|Finding|Procedure|Pattern|Session) ;;
  *) kb_reject "unknown-subject_type:$SUBJ_TYPE" ;;
esac
case "$OBJ_TYPE" in
  Concept|Finding|Procedure|Pattern|Session) ;;
  *) kb_reject "unknown-object_type:$OBJ_TYPE" ;;
esac

# Predicate must be in locked vocabulary
kb_vocab_contains "$KB_VOCAB_DIR/relations.txt" "$PRED" \
  || kb_reject "predicate-not-in-locked-vocabulary:$PRED"

# Validate (subject_type, predicate, object_type) tuple is allowed.
# The schema uses "any" sentinels for unconstrained sides; check both the
# exact tuple and any-wildcard forms.
TUPLE_OK="$(jq -r --arg st "$SUBJ_TYPE" --arg p "$PRED" --arg ot "$OBJ_TYPE" '
  .relations[] |
  select(.predicate == $p) |
  select(
    (.subject_types | index("any") != null) or (.subject_types | index($st) != null)
  ) |
  select(
    (.object_types | index("any") != null) or (.object_types | index($ot) != null)
  ) | "yes"
' "$KB_SCHEMA_DIR/relation-types.json" 2>/dev/null | head -1)"
[ "$TUPLE_OK" != "yes" ] \
  && kb_reject "tuple-not-in-schema:($SUBJ_TYPE,$PRED,$OBJ_TYPE)"

# Compute deterministic relation ID
SUBJ_ID="$(kb_hash_id "$SUBJ_TYPE" "$SUBJ_NAME")"
OBJ_ID="$(kb_hash_id "$OBJ_TYPE" "$OBJ_NAME")"
REL_ID="$(kb_hash_id "$SUBJ_ID" "$PRED" "$OBJ_ID")"

# Verify subject + object entities exist before allowing the relation.
# A relation must never create orphan entity stubs in Neo4j. Entities must be
# staged in this session OR committed in a prior session (entities-first rule).
COMMITTED_IDS="$KB_STATE_DIR/committed-ids.jsonl"
SESSION_MANIFEST="$KB_STAGING_DIR/${KB_SESSION_ID:-unknown}/manifest.jsonl"

subj_exists=false
# Check current session staging (anchored by id field, not substring).
# jq -e returns exit 0 only when the .id field equals SUBJ_ID exactly.
if command -v jq > /dev/null 2>&1 && [ -f "$SESSION_MANIFEST" ]; then
  jq -e --arg id "$SUBJ_ID" 'select(.id == $id)' "$SESSION_MANIFEST" \
    > /dev/null 2>&1 && subj_exists=true
elif [ -f "$SESSION_MANIFEST" ]; then
  # Fallback: substring grep (less precise)
  grep -qF "\"id\":\"$SUBJ_ID\"" "$SESSION_MANIFEST" 2>/dev/null && subj_exists=true
fi
# Check committed-ids ledger (cross-session)
if ! $subj_exists && [ -f "$COMMITTED_IDS" ]; then
  grep -Fxq "{\"id\":\"$SUBJ_ID\"}" "$COMMITTED_IDS" 2>/dev/null && subj_exists=true
fi

if ! $subj_exists; then
  echo "reject:subject-entity-not-staged-or-committed:$SUBJ_ID"
  exit 1
fi

obj_exists=false
# Check current session staging (anchored by id field, not substring).
if command -v jq > /dev/null 2>&1 && [ -f "$SESSION_MANIFEST" ]; then
  jq -e --arg id "$OBJ_ID" 'select(.id == $id)' "$SESSION_MANIFEST" \
    > /dev/null 2>&1 && obj_exists=true
elif [ -f "$SESSION_MANIFEST" ]; then
  # Fallback: substring grep (less precise)
  grep -qF "\"id\":\"$OBJ_ID\"" "$SESSION_MANIFEST" 2>/dev/null && obj_exists=true
fi
if ! $obj_exists && [ -f "$COMMITTED_IDS" ]; then
  grep -Fxq "{\"id\":\"$OBJ_ID\"}" "$COMMITTED_IDS" 2>/dev/null && obj_exists=true
fi

if ! $obj_exists; then
  echo "reject:object-entity-not-staged-or-committed:$OBJ_ID"
  exit 1
fi

if kb_already_written "$REL_ID"; then
  kb_skip "$REL_ID"
fi

ENRICHED="$(printf '%s' "$PAYLOAD" | jq -c --arg id "$REL_ID" --arg sid "$SUBJ_ID" --arg oid "$OBJ_ID" \
  '. + {id: $id, subject_id: $sid, object_id: $oid, kind: "relation"}')"
kb_stage "$ENRICHED"
kb_audit "write-relation-staged" "$ENRICHED"

kb_ok "$REL_ID"
