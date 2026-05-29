---
description: Second-brain KB dashboard + admin. Default = status. Subcommands shown in dashboard.
---

# /athanor

The single user-facing command. Without args, render the dashboard. With a subcommand, dispatch.

Args from user: `$ARGUMENTS`

## Dispatch

Route based on the first token in `$ARGUMENTS`:

| Subcommand | Action |
|---|---|
| (empty) or `status` | Render dashboard (default) |
| `recent [N]` | Show last N (default 20) entries from `.athanor/_state/kb-writes.jsonl` |
| `trace <name>` | Show provenance chain for an entity (delegates to `_internal/athanor-trace`) |
| `validate` | Run `bash .claude/hooks/lib/kb-validate.sh` and surface the report |
| `audit` | Run kb-auditor (opus, ~$1–3) — `_internal/athanor-audit` |
| `audit --quick` | Quick audit: golden test + health only (~$0.50) |
| `review` | Walk through HITL queue interactively — `_internal/athanor-review` |
| `review --batch` | Open `.athanor/_state/hitl-queue.jsonl` in `$EDITOR` |
| `vocab-extend` | Approve/reject pending vocab additions — `_internal/athanor-vocab-extend` |
| `reset <flag> <reason>` | Reset a tripped kill switch flag (HITL) — `_internal/athanor-kill-switch reset` |
| `kill-switch` | Show kill switch status — `_internal/athanor-kill-switch status` |
| `protocol-bump <new-version>` | Bump protocol with migration — `_internal/athanor-protocol-bump` |
| `distill <session-id>` | Manually trigger distiller — `_internal/distill` |
| `reconcile` | Re-distill sessions in the backlog (reads `distill-pending.jsonl`) |
| `eval [--tier=1\|2]` | Run the eval suite — `_internal/eval-run` |
| `help` | Print this list |

## Dashboard (default)

Compose from these reads (in parallel, cheap):

```bash
ROOT="$CLAUDE_PROJECT_DIR"
S="$ROOT/.athanor/_state"
SESSIONS=$(grep -cE '"session_id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"' \
  "$S/session-ledger.jsonl" 2>/dev/null || echo 0)
WRITES=$(wc -l < "$S/kb-writes.jsonl" 2>/dev/null | tr -d ' ')
HITL=$(wc -l < "$S/hitl-queue.jsonl" 2>/dev/null | tr -d ' ')
RUNBOOKS=$(find "$ROOT/.athanor/runbooks" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
SKILLS=$(find "$ROOT/.athanor/local-skills" -type d -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
DIGESTS=$(find "$ROOT/.athanor/distilled/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
LAST_DISTILL=$(jq -r '.last_distilled_at // "never"' "$S/distill-cursor.json" 2>/dev/null)
PROTOCOL=$(cat "$ROOT/protocol/version.txt" 2>/dev/null)

# Distill backlog = sessions seen minus digests produced
BACKLOG=$(( SESSIONS - DIGESTS )); [ "$BACKLOG" -lt 0 ] && BACKLOG=0

# Kill-switch status (real read)
if [ -f "$S/kill-switch.json" ]; then
  TRIPPED=$(jq -r '[to_entries[] | select(.value == "disabled") | .key] | join(",")' "$S/kill-switch.json" 2>/dev/null)
  [ -n "$TRIPPED" ] && KILL_SWITCH="TRIPPED:$TRIPPED" || KILL_SWITCH="enabled"
else
  KILL_SWITCH="enabled"
fi

# Last distill outcome — match failure indicators at start of line or structured errors,
# not prose that happens to contain "reject"/"error".
if grep -qE '^reject:|^error:|"status":"failed"|"outcome":"failed"|distill.*failed|all.*rejected' \
     "$S/last-distill.log" 2>/dev/null; then
  LAST_OUTCOME="FAILED"
elif [ ! -s "$S/last-distill.log" ]; then
  LAST_OUTCOME="unknown"
else
  LAST_OUTCOME="ok"
fi

# Recent hook errors (last 100 events as 24h proxy)
ERR_COUNT=$(tail -100 "$S/hook-errors.jsonl" 2>/dev/null | grep -cE '"err":|"event":' || echo 0)

# Health score
HEALTH=$(jq -r '.current // 1.0' "$S/health-score.json" 2>/dev/null || echo "1.0")
```

Render concisely:

```
ATHANOR KB · protocol $PROTOCOL · last distill $LAST_DISTILL

  sessions=$SESSIONS  digests=$DIGESTS  runbooks=$RUNBOOKS  skills=$SKILLS
  total writes=$WRITES  hitl pending=$HITL
  backlog=$BACKLOG  switch=$KILL_SWITCH
  last distill=$LAST_OUTCOME  errors(24h)=$ERR_COUNT  health=$HEALTH

PENDING HITL ($HITL):
  <jq -r '"  · \(.type): \(.subject)"' $S/hitl-queue.jsonl | head -3>

SUBCOMMANDS:
  /athanor recent [N]      last writes
  /athanor trace <name>    entity provenance
  /athanor validate        run protocol checks
  /athanor review          step through HITL queue
  /athanor review --batch  open queue in $EDITOR
  /athanor vocab-extend    approve/reject pending vocab
  /athanor distill <id>    manually distill a session
  /athanor reconcile       re-distill backlog (distill-pending.jsonl)
  /athanor help            this list
```

## Implementation guidance for the agent

- For `validate`: run the bash command, show output verbatim.
- For `recent`: `tail -N $S/kb-writes.jsonl | jq -r '"\(.ts) \(.action) \(.payload.entity_type // .payload.kind)"'`
- For `trace <name>`: query `mcp__knowledge-graph__find_memories_by_name` with the name, then read `.athanor/_state/kb-writes.jsonl` filtered by entity name to show provenance chain.
- For `review`: read each line of `hitl-queue.jsonl`, present one at a time, ask y/n/skip, write decision to `.athanor/_state/hitl-decisions.jsonl`, on approve apply the action.
- For `review --batch`: print `EDITOR=$EDITOR — open: .athanor/_state/hitl-queue.jsonl` so the user can edit it directly.
- For `vocab-extend`: same pattern — read `pending-vocab-additions.json`, present each, on approve append to the relevant vocab file + add a `CHANGELOG.md` entry.
- For `distill <id>`: invoke `claude --agent session-distiller "Distill session $id"` directly.
- For `reconcile`: read `distill-pending.jsonl` and re-spawn the distiller for each pending session:

```bash
reconcile)
  # Resolve state dir (this block is independent — $STATE is not inherited)
  ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  STATE="$ROOT/.athanor/_state"
  PENDING_FILE="$STATE/distill-pending.jsonl"
  if [ ! -f "$PENDING_FILE" ] || [ ! -s "$PENDING_FILE" ]; then
    echo "No pending sessions to reconcile."
    exit 0
  fi
  COUNT=$(wc -l < "$PENDING_FILE" || echo 0)
  echo "Reconciling $COUNT pending session(s)..."
  while IFS= read -r line; do
    SID=$(printf '%s' "$line" | jq -r '.session_id // empty')
    TRANSCRIPT=$(printf '%s' "$line" | jq -r '.transcript // empty')
    [ -z "$SID" ] || [ -z "$TRANSCRIPT" ] && continue
    if [ ! -f "$TRANSCRIPT" ]; then
      echo "  SKIP $SID — transcript missing: $TRANSCRIPT"
      continue
    fi
    echo "  Distilling $SID..."
    # Re-use session-stop.sh distill spawn logic
    claude --agent session-distiller --print \
      "Distill session $SID from transcript at $TRANSCRIPT. Follow all protocol steps." \
      > "$STATE/last-distill.log" 2>&1 &
    wait $!
    echo "  Done $SID"
  done < "$PENDING_FILE"
  echo "Reconcile complete."
  ;;
```

Keep dashboard ≤25 lines. No emojis unless the user asks.
