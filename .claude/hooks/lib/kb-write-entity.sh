#!/usr/bin/env bash
# kb-write-entity.sh — validate + stage an entity write.
# On ok:<id> → caller invokes mcp__knowledge-graph__create_entities with the validated payload.
# On reject:<reason> → caller MUST stop. Surface error.
# On skip:already-written:<id> → no-op.
#
# Usage:
#   echo '{"entity_type":"Concept","canonical_name":"p99-spike", ...}' | kb-write-entity.sh
#   kb-write-entity.sh '<json>'

set -eo pipefail

# Locate self
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"

# Read payload
if [ -n "${1:-}" ]; then
  PAYLOAD="$1"
else
  PAYLOAD="$(cat)"
fi

# 1. JSON parse check
kb_validate_json "$PAYLOAD" || kb_reject "invalid-json"

# 2. Required common fields
ENTITY_TYPE="$(kb_field "$PAYLOAD" entity_type)"
CANONICAL_NAME="$(kb_field "$PAYLOAD" canonical_name)"
SOURCE_SID="$(kb_field "$PAYLOAD" source_session_id)"
CREATED_AT="$(kb_field "$PAYLOAD" created_at)"
[ -z "$ENTITY_TYPE" ] && kb_reject "missing-entity_type"
[ -z "$CANONICAL_NAME" ] && kb_reject "missing-canonical_name"
[ -z "$SOURCE_SID" ] && kb_reject "missing-source_session_id"
[ -z "$CREATED_AT" ] && kb_reject "missing-created_at"

# 2b. created_at must look ISO-8601 (basic shape: YYYY-MM-DDTHH:MM:SSZ)
echo "$CREATED_AT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$' \
  || kb_reject "created_at-must-be-iso8601-utc"

# 3. canonical_name format
# Reject embedded newlines before regex (grep is line-oriented)
case "$CANONICAL_NAME" in
  *$'\n'*) kb_reject "canonical_name-must-match" "contains newline" ;;
esac
printf '%s' "$CANONICAL_NAME" | grep -qxE '^[a-z][a-z0-9-]{0,127}$' || kb_reject "canonical_name-must-match" "$CANONICAL_NAME"

# 4. entity_type must be one of the 5 universal types
case "$ENTITY_TYPE" in
  Concept|Finding|Procedure|Pattern|Session) ;;
  *) kb_reject "unknown-entity_type:$ENTITY_TYPE" ;;
esac

# 5. Optional confidence field — validate enum if present
CONFIDENCE="$(kb_field "$PAYLOAD" confidence)"
if [ -n "$CONFIDENCE" ]; then
  case "$CONFIDENCE" in
    unverified|tested|autonomous) ;;
    *) kb_reject "confidence-not-in-enum:$CONFIDENCE" ;;
  esac
fi

# 6. Optional outcome field — validate enum if present (used by Procedure and Session)
OUTCOME="$(kb_field "$PAYLOAD" outcome)"
if [ -n "$OUTCOME" ]; then
  case "$OUTCOME" in
    resolved|mitigated|open|abandoned|completed|partial) ;;
    *) kb_reject "outcome-not-in-enum:$OUTCOME" ;;
  esac
fi

# 7. Type-specific required fields
case "$ENTITY_TYPE" in
  Finding)
    SUM="$(kb_field "$PAYLOAD" summary)"
    [ -z "$SUM" ] && kb_reject "Finding-missing-summary"
    [ ${#SUM} -lt 10 ] && kb_reject "Finding-summary-too-short-min-10-chars"
    ;;
  Session)
    SID="$(kb_field "$PAYLOAD" session_id)"
    OCC="$(kb_field "$PAYLOAD" occurred_at)"
    [ -z "$SID" ] && kb_reject "Session-missing-session_id"
    [ -z "$OCC" ] && kb_reject "Session-missing-occurred_at"
    [ -z "$OUTCOME" ] && kb_reject "Session-missing-outcome"
    echo "$OCC" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$' \
      || kb_reject "Session-occurred_at-must-be-iso8601-utc"
    ;;
esac

# 8. Compute deterministic ID
ID="$(kb_hash_id "$ENTITY_TYPE" "$CANONICAL_NAME")"

# 9. Idempotency check
if kb_already_written "$ID"; then
  kb_skip "$ID"
fi

# 10. Stage + audit
# Read protocol version so every entity records the protocol it was created under.
PROTOCOL_VERSION="$(tr -d '[:space:]' < "$KB_PROTOCOL_DIR/version.txt" 2>/dev/null || echo "unknown")"
[ -z "$PROTOCOL_VERSION" ] && PROTOCOL_VERSION="unknown"
ENRICHED="$(printf '%s' "$PAYLOAD" | jq -c --arg id "$ID" --arg v "$PROTOCOL_VERSION" '. + {id: $id, kind: "entity", created_under_protocol: $v}')"
kb_stage "$ENRICHED"
kb_audit "write-entity-staged" "$ENRICHED"

# 11. Green light to caller
kb_ok "$ID"
