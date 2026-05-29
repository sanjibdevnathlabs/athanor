#!/usr/bin/env bash
# bypass-detector.sh — runs from PostToolUse hook on every mcp__knowledge-graph__*
# call. Verifies that the call was preceded by a wrapper green-light (kb-write-*
# stamped the same id into _state/kb-writes.jsonl OR _staging/<sid>/manifest.jsonl).
# If not → log to _state/bypass-log.jsonl and increment counter; trip kill switch
# at threshold.
#
# Authorization model: SESSION-SCOPED (not time-windowed).
#   A session is authorized if .athanor/_staging/<sid>/manifest.jsonl exists.
#   This means the distiller pre-staged entities via wrappers for this session.
#   A single valid wrapper write does NOT blanket-authorize unrelated calls.
#
# In eval mode (KB_EVAL=1), additionally detects writes outside .athanor/_staging/.
#
# Input on stdin: PostToolUse JSON from Claude Code:
#   {"tool_name": "...", "tool_input": {...}, "tool_response": {...}, "session_id": "..."}

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"
# shellcheck source=kill-switch-check.sh
. "$SCRIPT_DIR/kill-switch-check.sh"

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)"
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Guard: do nothing if tool is not graph-related and we're not in eval mode
case "$TOOL" in
  mcp__knowledge-graph__create_entities|mcp__knowledge-graph__create_relations|mcp__knowledge-graph__add_observations|mcp__knowledge-graph__delete_entities|mcp__knowledge-graph__delete_relations|mcp__knowledge-graph__delete_observations)
    GRAPH_CALL=1
    ;;
  *) GRAPH_CALL=0 ;;
esac

# ---------- bypass response helpers ----------
# Append a HITL queue entry. Soft-fail. jq -n encodes all fields safely (M4).
log_hitl() {
  # $1=type $2=tool $3=entity_type(may be empty) $4=extra-reason(may be empty)
  local type="$1" tool_name="$2" entity_type="${3:-}" reason="${4:-}"
  jq -n \
    --arg ts "$TS" \
    --arg type "$type" \
    --arg session_id "$SID" \
    --arg tool_name "$tool_name" \
    --arg entity_type "$entity_type" \
    --arg reason "$reason" \
    '{ts:$ts, type:$type, session_id:$session_id, tool_name:$tool_name, entity_type:$entity_type, reason:$reason}' \
    >> "$KB_STATE_DIR/hitl-queue.jsonl" 2>/dev/null || true
}

# Disable auto_commit in the kill switch and log to err-log.txt. Soft-fail.
disable_auto_commit() {
  # $1=reason
  bash "$SCRIPT_DIR/kill-switch-check.sh" trip auto_commit "$1" 2>/dev/null || true
  printf '%s kill-switch: auto_commit disabled due to %s\n' "$TS" "$1" \
    >> "$KB_STATE_DIR/err-log.txt" 2>/dev/null || true
}

if [ "$GRAPH_CALL" -eq 1 ]; then
  # Wrapper-mediated calls (future) set KB_WRAPPER and are trusted as-is.
  if [ -z "${KB_WRAPPER:-}" ]; then
    # Session manifest path uses KB_STAGING_DIR (kb-common.sh, eval-overridable).
    # The kb-committer self-registers at startup by symlinking
    # $KB_STAGING_DIR/<committer_sid>/manifest.jsonl -> the original session's
    # manifest, so this standard lookup transparently authorizes committer
    # writes (jq/grep follow the symlink). No committer-context fallback needed.
    SESSION_MANIFEST=""
    if [ -n "$SID" ]; then
      SESSION_MANIFEST="$KB_STAGING_DIR/$SID/manifest.jsonl"
    fi

    case "$TOOL" in
      # ---- Bug 3 (C4): deletes have NO wrapper. Always a bypass. One trips the switch. ----
      mcp__knowledge-graph__delete_entities|mcp__knowledge-graph__delete_relations|mcp__knowledge-graph__delete_observations)
        printf '{"ts":"%s","kind":"bypass","tool":"%s","session_id":"%s","reason":"unauthorized-delete"}\n' \
          "$TS" "$TOOL" "$SID" >> "$KB_STATE_DIR/bypass-log.jsonl"
        log_hitl "unauthorized_delete" "$TOOL" "" "no automated deletion path exists in protocol"
        disable_auto_commit "unauthorized-delete:$TOOL"
        ;;

      # ---- Bug 2 (C3): per-record authorization for create/observe writes. ----
      *)
        # Extract the records being written. create_entities/create_relations/
        # add_observations all carry an "entities" array (name+type per record).
        # Fail-closed: malformed / missing array → whole call is a bypass.
        RECORDS_TSV="$(printf '%s' "$INPUT" | jq -r '
          .tool_input.entities
          | if type == "array" then
              .[] | [(.type // .entityType // ""), (.name // .entityName // "")] | @tsv
            else empty end
        ' 2>/dev/null)"

        if [ -z "$RECORDS_TSV" ]; then
          # Could not parse any record → fail closed, treat as bypass.
          printf '{"ts":"%s","kind":"bypass","tool":"%s","session_id":"%s","reason":"unparseable-tool-input-fail-closed"}\n' \
            "$TS" "$TOOL" "$SID" >> "$KB_STATE_DIR/bypass-log.jsonl"
          log_hitl "bypass_detected" "$TOOL" "" "unparseable tool input (fail-closed)"
        else
          # Check each record's deterministic id against the session manifest.
          while IFS=$'\t' read -r REC_TYPE REC_NAME; do
            [ -z "$REC_TYPE" ] && [ -z "$REC_NAME" ] && continue
            REC_ID="$(kb_hash_id "$REC_TYPE" "$REC_NAME")"
            AUTH_REASON=""
            if [ -n "$SESSION_MANIFEST" ] && [ -f "$SESSION_MANIFEST" ] \
               && grep -F "\"id\":\"$REC_ID\"" "$SESSION_MANIFEST" >/dev/null 2>&1; then
              # This specific record was staged by a wrapper → authorized.
              # For the committer, $SESSION_MANIFEST is a symlink to the original
              # session's manifest (committer self-registration); grep -F follows it.
              AUTH_REASON="record-in-manifest"
            fi

            # Fallback: check if an active committer registered via committer-active.json.
            # This handles the case where $CLAUDE_SESSION_ID was not available during
            # symlink-based self-registration, so $SESSION_MANIFEST does not resolve to
            # the original session's manifest. The committer writes committer-active.json
            # carrying the original session ID; authorize records present in that manifest.
            if [ -z "$AUTH_REASON" ]; then
              COMMITTER_ACTIVE="$KB_STATE_DIR/committer-active.json"
              if [ -f "$COMMITTER_ACTIVE" ]; then
                ORIG_SID=$(jq -r '.original_sid // empty' "$COMMITTER_ACTIVE" 2>/dev/null)
                if [ -n "$ORIG_SID" ]; then
                  ORIG_MANIFEST="$KB_STAGING_DIR/$ORIG_SID/manifest.jsonl"
                  if [ -f "$ORIG_MANIFEST" ] \
                     && grep -F "\"id\":\"$REC_ID\"" "$ORIG_MANIFEST" >/dev/null 2>&1; then
                    AUTH_REASON="committer-active-manifest"
                  fi
                fi
              fi
            fi

            if [ -n "$AUTH_REASON" ]; then
              printf '{"ts":"%s","kind":"authorized","tool":"%s","session_id":"%s","id":"%s","reason":"%s"}\n' \
                "$TS" "$TOOL" "$SID" "$REC_ID" "$AUTH_REASON" >> "$KB_STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
              # Record as durably committed for cross-session idempotency (C3/C4).
              if ! declare -f kb_record_commit > /dev/null 2>&1; then
                # shellcheck source=kb-common.sh
                source "$SCRIPT_DIR/kb-common.sh" 2>/dev/null || true
              fi
              kb_record_commit "$REC_ID" 2>/dev/null || true
            else
              # No matching manifest record for this session → bypass.
              printf '{"ts":"%s","kind":"bypass","tool":"%s","session_id":"%s","id":"%s","reason":"no-manifest-record"}\n' \
                "$TS" "$TOOL" "$SID" "$REC_ID" >> "$KB_STATE_DIR/bypass-log.jsonl"
              log_hitl "bypass_detected" "$TOOL" "$REC_TYPE" "no manifest record for id $REC_ID"
            fi
          done <<EOF
$RECORDS_TSV
EOF
        fi
        ;;
    esac
  fi
fi

# Eval-mode discipline (G-01): catch writes outside .athanor/_staging/.
if [ "${KB_EVAL:-}" = "1" ]; then
  case "$TOOL" in
    Write|Edit|NotebookEdit)
      PATH_VAL="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)"
      if [ -n "$PATH_VAL" ]; then
        case "$PATH_VAL" in
          *"/.athanor/_staging/"*|*"/.athanor/_eval/"*)  : ;;  # allowed during eval
          *"/.athanor/runbooks/"*|*"/.athanor/distilled/"*|*"/.athanor/local-skills/"*|*"/.athanor/memory/"*)
            printf '{"ts":"%s","kind":"eval-discipline-leak","tool":"%s","path":"%s","session_id":"%s"}\n' \
              "$TS" "$TOOL" "$PATH_VAL" "$SID" >> "$KB_STATE_DIR/bypass-log.jsonl"
            ;;
          *) : ;;
        esac
      fi
      ;;
  esac
fi

# Bug 1 (C2) + Bug 4 (H3): trip kill switch on bypass spike.
# Primary guard: cross-session 24h window (documented "5 in 24h" rule).
# Secondary fast-trip: per-session > 3 (catches a single runaway session fast).
# Authorized lines don't count — only kind=="bypass".
if [ "$GRAPH_CALL" -eq 1 ] && [ -z "${KB_WRAPPER:-}" ]; then
  BYPASS_LOG="$KB_STATE_DIR/bypass-log.jsonl"

  # ── Primary: cross-session 24h window ──
  TWENTY_FOUR_HOURS_AGO=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-24H '+%Y-%m-%dT%H:%M:%S')
  RECENT_BYPASSES=$(grep '"kind":"bypass"' "$BYPASS_LOG" 2>/dev/null | \
    jq -r --arg cutoff "$TWENTY_FOUR_HOURS_AGO" 'select(.ts >= $cutoff) | .kind' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${RECENT_BYPASSES:-0}" -gt 5 ]; then
    bash "$SCRIPT_DIR/kill-switch-check.sh" trip auto_commit "bypass-spike: $RECENT_BYPASSES bypasses in 24h" 2>/dev/null || true
    printf '%s kill-switch: auto_commit disabled due to bypass-spike: %s bypasses in 24h\n' "$TS" "$RECENT_BYPASSES" \
      >> "$KB_STATE_DIR/err-log.txt" 2>/dev/null || true
  fi

  # ── Secondary: per-session fast-trip (> 3 this session) ──
  if [ -n "$SID" ]; then
    BYPASS_COUNT=$(grep -F "\"session_id\":\"$SID\"" "$BYPASS_LOG" 2>/dev/null \
      | grep -Fc '"kind":"bypass"' 2>/dev/null | head -1 | tr -dc '0-9')
    if [ "${BYPASS_COUNT:-0}" -gt 3 ]; then
      disable_auto_commit "bypass-count-exceeded:$BYPASS_COUNT"
    fi
  fi
fi

exit 0
