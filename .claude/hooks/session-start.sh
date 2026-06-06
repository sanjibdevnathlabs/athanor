#!/usr/bin/env bash
# session-start.sh — runs on SessionStart. HOT tier: ≤100 tokens injected as context.
# Output to stdout = injected as additionalContext (Claude Code 2.1+ behavior).
# Hard 5s budget; on any error, emit nothing (don't break sessions).

set -uo pipefail
TIMEOUT=5

# Resolve project root
ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE="$ROOT/.athanor/_state"
ERR_LOG="$STATE/hook-errors.jsonl"

# Soft-fail on any error
trap 'printf "{\"ts\":\"%s\",\"hook\":\"session-start\",\"err\":\"trap\"}\n" "$(date -u +%FT%TZ)" >> "$ERR_LOG" 2>/dev/null; exit 0' ERR

# Read input from Claude Code (JSON on stdin) — used for session metadata
INPUT="$(cat 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)"
MODEL="$(printf '%s' "$INPUT" | jq -r '.model // ""' 2>/dev/null || true)"
SOURCE="$(printf '%s' "$INPUT" | jq -r '.source // "startup"' 2>/dev/null || true)"

# Append session ledger row
TS="$(date -u +%FT%TZ)"
mkdir -p "$STATE"
printf '{"ts":"%s","session_id":"%s","model":"%s","source":"%s"}\n' \
  "$TS" "$SESSION_ID" "$MODEL" "$SOURCE" >> "$STATE/session-ledger.jsonl" 2>/dev/null || true

# Compute KB stats (cheap)
SESSIONS=$(wc -l < "$STATE/session-ledger.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
RUNBOOKS=$(find "$ROOT/.athanor/runbooks" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ' || echo 0)
SKILLS=$(find "$ROOT/.athanor/local-skills" -type d -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ' || echo 0)
HITL=$(wc -l < "$STATE/hitl-queue.jsonl" 2>/dev/null | tr -d ' ' || echo 0)

# Pick the HIGHEST-PRIORITY unresolved HITL item (FIFO within priority).
# Unresolved = ts+type+session_id key not present in hitl-decisions.jsonl.
# Severity ranking: bypass/unauthorized_delete/kill_switch_trip (1) >
#   supervisor_escalation (2) > supervisor_rejection/revision_needed (3) >
#   contradiction (4) > everything else (5). Within a priority: oldest first.
HITL_LINE=""
HITL_COUNT=0
QUEUE="$STATE/hitl-queue.jsonl"
DECISIONS="$STATE/hitl-decisions.jsonl"
if [ -f "$QUEUE" ]; then
  # Set of resolved keys (ts|type|session_id) from decisions.
  RESOLVED_KEYS="$(jq -r '"\(.ts // "")|\(.type // "")|\(.session_id // "")"' "$DECISIONS" 2>/dev/null || true)"
  # Emit unresolved items as: priority<TAB>ts<TAB>type<TAB>session_id
  HITL_RANKED="$(
    jq -r '
      ([.type] | join(" ")) as $t
      | (if   ($t|test("bypass_detected|unauthorized_delete|kill_switch_trip")) then 1
         elif ($t|test("supervisor_escalation"))                               then 2
         elif ($t|test("supervisor_rejection|supervisor_revision_needed"))     then 3
         elif ($t|test("contradiction"))                                       then 4
         else 5 end) as $p
      | [$p, (.ts // ""), (.type // ""), (.session_id // "")] | @tsv
    ' "$QUEUE" 2>/dev/null \
    | while IFS="$(printf '\t')" read -r p ts ty sid; do
        key="${ts}|${ty}|${sid}"
        if ! printf '%s\n' "$RESOLVED_KEYS" | grep -qxF "$key"; then
          printf '%s\t%s\t%s\t%s\n' "$p" "$ts" "$ty" "$sid"
        fi
      done
  )" || true
  if [ -n "$HITL_RANKED" ]; then
    HITL_COUNT="$(printf '%s\n' "$HITL_RANKED" | grep -c . || echo 0)"
    # Sort by priority asc, then ts asc (FIFO). Pick the first.
    TOP="$(printf '%s\n' "$HITL_RANKED" | sort -t"$(printf '\t')" -k1,1n -k2,2 | head -1)"
    TOP_TYPE="$(printf '%s' "$TOP" | cut -f3)"
    TOP_SID="$(printf '%s' "$TOP" | cut -f4)"
    SHORT_SID="$(printf '%s' "$TOP_SID" | cut -c1-8)"
    [ -z "$SHORT_SID" ] && SHORT_SID="unknown"
    HITL_LINE="$(printf 'HITL: %s item(s) pending review. Highest priority: %s for session %s. Run /athanor review to action.' \
      "$HITL_COUNT" "$TOP_TYPE" "$SHORT_SID")"
  fi
fi

# Kill switch state — read real state from kill-switch.json
KILL_SWITCH_FILE="$STATE/kill-switch.json"
if [ -f "$KILL_SWITCH_FILE" ]; then
  # Show the most restrictive tripped flag, if any
  TRIPPED=$(jq -r '[to_entries[] | select(.value == "disabled") | .key] | join(",")' \
    "$KILL_SWITCH_FILE" 2>/dev/null || echo "")
  if [ -n "$TRIPPED" ]; then
    KILL_SWITCH="TRIPPED:$TRIPPED"
  else
    KILL_SWITCH="enabled"
  fi
else
  KILL_SWITCH="enabled"
fi

# Compute distill backlog
LEDGER_COUNT=$(grep -cE '"session_id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"' \
  "$STATE/session-ledger.jsonl" 2>/dev/null || echo 0)
DIGEST_COUNT=$(ls "$ROOT/.athanor/distilled/sessions/"*.md 2>/dev/null | wc -l | tr -d ' ' || echo 0)
PENDING_COUNT=$(wc -l < "$STATE/distill-pending.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
BACKLOG=$((LEDGER_COUNT - DIGEST_COUNT))
[ "$BACKLOG" -lt 0 ] && BACKLOG=0

# Backlog warning fragment
BACKLOG_LINE=""
if [ "$BACKLOG" -gt 5 ]; then
  BACKLOG_LINE="backlog=${BACKLOG}"
  [ "$PENDING_COUNT" -gt 0 ] && BACKLOG_LINE="${BACKLOG_LINE}(${PENDING_COUNT}q)"
fi

# Health score check
HEALTH=$(jq -r '.current // 1.0' "$STATE/health-score.json" 2>/dev/null || echo "1.0")
HEALTH_INT=$(awk -v h="$HEALTH" 'BEGIN{printf "%d", h*10}')
HEALTH_WARN=""
if [ "$HEALTH_INT" -lt 8 ]; then
  HEALTH_WARN="health=${HEALTH}⚠"
fi

# Count recent hook errors (last 24h, proxied by last 100 lines)
RECENT_ERR_COUNT=0
ERRORS_LINE=""
if [ -f "$STATE/hook-errors.jsonl" ]; then
  RECENT_ERR_COUNT=$(tail -100 "$STATE/hook-errors.jsonl" 2>/dev/null | grep -cE '"err":|"event":' || echo 0)
fi
[ "$RECENT_ERR_COUNT" -gt 0 ] && ERRORS_LINE="errors(24h)=${RECENT_ERR_COUNT}"

# HOT tier — keep tight. Target ≤100 tokens.
# Build optional health/backlog/errors suffix (short fragments only).
EXTRA=""
[ -n "$BACKLOG_LINE" ] && EXTRA="$EXTRA $BACKLOG_LINE"
[ -n "$HEALTH_WARN" ] && EXTRA="$EXTRA $HEALTH_WARN"
[ -n "$ERRORS_LINE" ] && EXTRA="$EXTRA $ERRORS_LINE"
{
  printf '## Oncall KB\n'
  printf 'sessions=%s runbooks=%s skills=%s hitl=%s switch=%s%s\n' \
    "$SESSIONS" "$RUNBOOKS" "$SKILLS" "$HITL" "$KILL_SWITCH" "$EXTRA"
  printf 'Talk normally — system auto-recalls and learns. Type /athanor for dashboard.\n'
  if [ -n "$HITL_LINE" ]; then
    printf '%s\n' "$HITL_LINE"
  fi
} 2>/dev/null

exit 0
