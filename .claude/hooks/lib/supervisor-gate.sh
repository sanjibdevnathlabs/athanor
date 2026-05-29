#!/usr/bin/env bash
# supervisor-gate.sh — moves a supervisor-approved manifest from
# _staging/<session>/ to either:
#   - "committed" state (audit log entry indicating it has been or will be
#     persisted to Neo4j by the caller), or
#   - _quarantine/<session>/ (rejected)
#
# Usage:
#   bash supervisor-gate.sh approve <session-id>
#   bash supervisor-gate.sh reject  <session-id> <reason>
#   bash supervisor-gate.sh status  <session-id>
#
# This script does NOT call MCP graph tools itself. The supervisor agent or
# session-stop pipeline calls it, then iterates the manifest and invokes
# mcp__knowledge-graph__* with KB_WRAPPER=1 to mark wrapper-mediated commits.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"

ACTION="${1:?usage: supervisor-gate.sh approve|reject|status <sid> [reason]}"
SID="${2:?session id}"
REASON="${3:-}"

STAGING="$KB_STAGING_DIR/$SID"
MANIFEST="$STAGING/manifest.jsonl"
QUAR_DIR="$KB_ROOT/.athanor/_quarantine"
AUDIT_DIR="$KB_ROOT/.athanor/_state"

[ -d "$STAGING" ] || { echo "reject:no-staging-for-session:$SID" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "reject:no-manifest-in-staging:$SID" >&2; exit 1; }

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

case "$ACTION" in
  approve)
    # Append a "supervisor-approved" record to the audit log
    COUNT=$(wc -l < "$MANIFEST" | tr -d ' ')
    printf '{"ts":"%s","action":"supervisor-approve","session_id":"%s","manifest_count":%s}\n' \
      "$TS" "$SID" "$COUNT" >> "$AUDIT_DIR/kb-writes.jsonl"
    # Mark the staging dir with a supervisor-approval sentinel
    printf '{"ts":"%s","approved_by":"supervisor","reason":"%s"}\n' "$TS" "${REASON:-clean}" \
      > "$STAGING/.supervisor-approved"
    echo "ok:approved:$SID:$COUNT-records"
    ;;
  reject)
    [ -z "$REASON" ] && { echo "reject:missing-reason-for-rejection" >&2; exit 1; }
    mkdir -p "$QUAR_DIR"
    DEST="$QUAR_DIR/$SID-$TS"
    mv "$STAGING" "$DEST"
    printf '{"ts":"%s","action":"supervisor-reject","session_id":"%s","reason":"%s","quarantined_to":"%s"}\n' \
      "$TS" "$SID" "$REASON" "$DEST" >> "$AUDIT_DIR/kb-writes.jsonl"
    # Also append to HITL queue for human review (jq -n to prevent JSON injection)
    DELETE_INSTRUCTIONS="For each committed entity in this manifest that was flagged as hallucinated, call: echo '{\"entity_name\":\"<name>\",\"entity_type\":\"<type>\",\"reason\":\"supervisor-reject\",\"source_session_id\":\"$SID\"}' | bash .claude/hooks/lib/kb-delete.sh. Then invoke mcp__knowledge-graph__delete_entities."
    jq -cn \
      --arg ts "$TS" \
      --arg type "supervisor_rejection" \
      --arg session_id "$SID" \
      --arg reason "${REASON:-unspecified}" \
      --arg quarantined_to "$DEST" \
      --arg delete_instructions "$DELETE_INSTRUCTIONS" \
      '{ts:$ts, type:$type, session_id:$session_id, reason:$reason, quarantined_to:$quarantined_to, delete_instructions:$delete_instructions}' \
      >> "$AUDIT_DIR/hitl-queue.jsonl" 2>/dev/null || true
    # Auto-trip kill switch on 3+ rejections within the last 30 days (windowed,
    # not a lifetime ratchet). GNU date -d first, BSD/macOS date -v fallback.
    # Portable extraction: the 3-arg awk match(str,regex,array) is a GNU
    # extension that silently fails on macOS BSD awk. Use grep+sed instead so
    # the windowed counter works cross-platform.
    THIRTY_DAYS_AGO=$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
      || date -u -v-30d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
      || echo "1970-01-01T00:00:00Z")
    KB_WRITES_LOG="$AUDIT_DIR/kb-writes.jsonl"
    RECENT_REJECTS=0
    if [ -f "$KB_WRITES_LOG" ]; then
      while IFS= read -r line; do
        # Extract ts and action fields portably (lexicographic ISO-8601 compare).
        ts=$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | head -1 | sed 's/"ts":"//;s/"//')
        action=$(printf '%s' "$line" | grep -o '"action":"[^"]*"' | head -1 | sed 's/"action":"//;s/"//')
        if [ "$action" = "supervisor-reject" ] && [ -n "$ts" ] && [ "$ts" \> "$THIRTY_DAYS_AGO" ]; then
          RECENT_REJECTS=$((RECENT_REJECTS + 1))
        fi
      done < "$KB_WRITES_LOG"
    fi
    if [ "${RECENT_REJECTS:-0}" -ge 3 ]; then
      bash "$SCRIPT_DIR/kill-switch-check.sh" trip auto_commit "supervisor-rejected-3-in-30d" 2>/dev/null || true
    fi
    # Remove rejected entity IDs from committed-ids ledger so they can be re-committed
    # after the HITL review corrects them. The manifest was moved to $DEST above.
    COMMITTED_IDS="${KB_ROOT:-.}/.athanor/_state/committed-ids.jsonl"
    REJECTED_MANIFEST="$DEST/manifest.jsonl"
    if [ -f "$COMMITTED_IDS" ] && [ -f "$REJECTED_MANIFEST" ]; then
      # Single-pass removal (race-safe): collect all reject IDs from the manifest
      # into one file, then do ONE grep -vFf pass and ONE mv. The race window is
      # now a single atomic mv instead of N sequential mv operations.
      REJECT_IDS_FILE="${COMMITTED_IDS}.reject.$$"
      jq -r 'select(.id != null) | .id' "$REJECTED_MANIFEST" 2>/dev/null \
        | sed 's/.*/{"id":"&"}/' > "$REJECT_IDS_FILE" || true

      if [ -s "$REJECT_IDS_FILE" ]; then
        # Keep only lines NOT in the reject set (full-line fixed-string match).
        # Wrap the entire read-modify-write under the same lock used by
        # kb_record_commit() so a concurrent committer append can't be lost.
        if command -v flock >/dev/null 2>&1; then
          ( flock -x 9
            grep -vFxf "$REJECT_IDS_FILE" "$COMMITTED_IDS" > "${COMMITTED_IDS}.tmp" \
              && mv "${COMMITTED_IDS}.tmp" "$COMMITTED_IDS"
          ) 9>"${COMMITTED_IDS}.lock" || true
        else
          grep -vFxf "$REJECT_IDS_FILE" "$COMMITTED_IDS" > "${COMMITTED_IDS}.tmp" \
            && mv "${COMMITTED_IDS}.tmp" "$COMMITTED_IDS" || true
        fi
      fi
      rm -f "$REJECT_IDS_FILE" "${COMMITTED_IDS}.tmp"
    fi
    echo "ok:rejected:$SID:$DEST"
    ;;
  revise)
    # Supervisor wants distiller to revise the manifest.
    # We don't re-spawn (infinite loop risk). Quarantine and queue for HITL.
    QUAR_PATH="$KB_ROOT/.athanor/_quarantine/${SID}-revise"
    mv "$KB_ROOT/.athanor/_staging/$SID" "$QUAR_PATH" 2>/dev/null || true
    jq -cn \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg type "supervisor_revision_needed" \
      --arg session_id "$SID" \
      --arg manifest_path "$QUAR_PATH/manifest.jsonl" \
      --arg feedback_path "$QUAR_PATH/.revise-feedback.md" \
      '{ts:$ts, type:$type, session_id:$session_id, manifest_path:$manifest_path, feedback_path:$feedback_path}' \
      >> "$KB_ROOT/.athanor/_state/hitl-queue.jsonl" 2>/dev/null || true
    echo "revise:queued-for-hitl"
    ;;
  escalate)
    # High-severity finding requiring human review.
    jq -cn \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg type "supervisor_escalation" \
      --arg session_id "$SID" \
      --arg severity "high" \
      --arg manifest_path "$KB_ROOT/.athanor/_staging/$SID/manifest.jsonl" \
      '{ts:$ts, type:$type, session_id:$session_id, severity:$severity, manifest_path:$manifest_path}' \
      >> "$KB_ROOT/.athanor/_state/hitl-queue.jsonl" 2>/dev/null || true
    echo "escalate:queued-for-hitl"
    ;;
  status)
    if [ -f "$STAGING/.supervisor-approved" ]; then
      echo "approved"
    else
      # Check if any quarantine dir exists for this SID (safe for 0, 1, or many matches)
      QUAR_MATCH=$(ls -d "$QUAR_DIR/${SID}"* 2>/dev/null | head -1)
      if [ -n "$QUAR_MATCH" ]; then
        echo "rejected"
      else
        echo "pending"
      fi
    fi
    ;;
  *)
    echo "reject:unknown-action:$ACTION" >&2
    exit 1
    ;;
esac
