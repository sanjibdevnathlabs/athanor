#!/usr/bin/env bash
# kb-write-observation.sh — validate + stage an observation write.
# Usage:
#   kb-write-observation.sh '{"entity_type":"Finding","entity_name":"care-p99-spike","observation":"text...","source_session_id":"abc","evidence_snippet":"..."}'

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"

PAYLOAD="${1:-$(cat)}"

kb_validate_json "$PAYLOAD" || kb_reject "invalid-json"

ENT_TYPE="$(kb_field "$PAYLOAD" entity_type)"
ENT_NAME="$(kb_field "$PAYLOAD" entity_name)"
OBS="$(kb_field "$PAYLOAD" observation)"
SESSION="$(kb_field "$PAYLOAD" source_session_id)"
EVIDENCE="$(kb_field "$PAYLOAD" evidence_snippet)"

[ -z "$ENT_TYPE" ] && kb_reject "missing-entity_type"
[ -z "$ENT_NAME" ] && kb_reject "missing-entity_name"
[ -z "$OBS" ] && kb_reject "missing-observation"
[ -z "$SESSION" ] && kb_reject "missing-source_session_id"
[ -z "$EVIDENCE" ] && kb_reject "missing-evidence_snippet-required-for-provenance"

# entity_type must be one of the 5 universal types
case "$ENT_TYPE" in
  Concept|Finding|Procedure|Pattern|Session) ;;
  *) kb_reject "unknown-entity_type:$ENT_TYPE" ;;
esac

# Provenance: evidence_snippet must be at least 20 chars (citation gate).
# This MUST stay >= 20 to match the commit-time gate in kb-prepare-commit.sh.
# The "5-vs-20 mismatch" bug was: an earlier wrapper accepted shorter evidence
# than prepare-commit required, so a staged observation could be silently
# dropped at commit. The wrapper minimum is RAISED to 20 here to stay
# consistent with kb-prepare-commit.sh (see pc-03/pc-08 in the Tier-1 eval).
[ ${#EVIDENCE} -lt 20 ] && kb_reject "evidence_snippet-too-short-min-20-chars"

# Length bounds on observation. Minimum RAISED from 5 to 20 to stay consistent
# with kb-prepare-commit.sh's commit-time validation (no silent commit-time drop).
[ ${#OBS} -lt 20 ] && kb_reject "observation-too-short"
[ ${#OBS} -gt 2000 ] && kb_reject "observation-too-long-max-2000"

# Entity must exist (idempotency: lookup by hash). For P1 we just validate format.
ENT_ID="$(kb_hash_id "$ENT_TYPE" "$ENT_NAME")"
OBS_ID="$(kb_hash_id "$ENT_ID" "$OBS")"

# Verify referenced entity exists (staged or committed)
ENT_EXISTS=false
SESSION_MANIFEST="$KB_STAGING_DIR/$KB_SESSION_ID/manifest.jsonl"

# Check current session staging
if [ -f "$SESSION_MANIFEST" ]; then
  grep -qF "\"id\":\"$ENT_ID\"" "$SESSION_MANIFEST" 2>/dev/null && ENT_EXISTS=true
fi

# Check committed-ids ledger (cross-session)
COMMITTED_IDS="$KB_STATE_DIR/committed-ids.jsonl"
if ! $ENT_EXISTS && [ -f "$COMMITTED_IDS" ]; then
  grep -Fxq "{\"id\":\"$ENT_ID\"}" "$COMMITTED_IDS" 2>/dev/null && ENT_EXISTS=true
fi

if ! $ENT_EXISTS; then
  echo "reject:entity-not-staged-or-committed:$ENT_ID"
  exit 1
fi

if kb_already_written "$OBS_ID"; then
  kb_skip "$OBS_ID"
fi

ENRICHED="$(printf '%s' "$PAYLOAD" | jq -c --arg id "$OBS_ID" --arg eid "$ENT_ID" \
  '. + {id: $id, entity_id: $eid, kind: "observation"}')"
kb_stage "$ENRICHED"
kb_audit "write-observation-staged" "$ENRICHED"

kb_ok "$OBS_ID"
