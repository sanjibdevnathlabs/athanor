#!/usr/bin/env bash
# kb-learn-commit.sh — commit + audit a mid-session "learn this" capture.
#
# This is the COMMIT HALF of session-stop.sh, scoped to a single ad-hoc learn
# session and run SYNCHRONOUSLY (the user is present and wants confirmation).
# The main agent has already acted as a live distiller: it extracted artifacts
# and staged them via the kb-write-*.sh wrappers under a dedicated LEARN_SID.
#
# This script then:
#   1. prepares the staged manifest (kb-prepare-commit.sh)
#   2. checks the auto_commit kill switch
#   3. spawns kb-committer (sync)        → graph + ledger + digest + qdrant
#   4. spawns distillation-supervisor (sync) → adversarial audit → HITL on non-approve
#   5. records learned entity names into a per-LIVE-session marker so the
#      end-of-session distiller skips re-observing them (near-dup prevention)
#
# It deliberately does NOT touch distill-cursor.json or distill-pending.jsonl —
# those belong to the live session's own Stop pipeline, which is left untouched.
#
# Usage:
#   bash kb-learn-commit.sh <LEARN_SID> [<LIVE_SESSION_ID>]
#
# Exit 0: committed (check the printed summary for supervisor outcome)
# Exit 1: nothing to commit / prepare failed / kill switch / committer failed
set -uo pipefail

LEARN_SID="${1:-}"
LIVE_SID="${2:-}"

if [ -z "$LEARN_SID" ]; then
  echo "kb-learn-commit:error:usage: kb-learn-commit.sh <LEARN_SID> [<LIVE_SESSION_ID>]" >&2
  exit 1
fi

# ---- Resolve root + canonical state paths (mirror kb-common.sh) ----
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  ROOT="$CLAUDE_PROJECT_DIR"
else
  ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
STATE="$ROOT/.athanor/_state"
STAGING="$ROOT/.athanor/_staging"
ERR_LOG="$STATE/hook-errors.jsonl"
TIMEOUT_CMD="$(command -v gtimeout || command -v timeout || true)"
mkdir -p "$STATE"

log() { printf '%s\n' "$1" >> "$ERR_LOG" 2>/dev/null || true; }
ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Guard: LEARN_SID must be a safe path component (same rule as kb_stage).
if [[ ! "$LEARN_SID" =~ ^[a-zA-Z0-9_-]{4,128}$ ]]; then
  echo "kb-learn-commit:error:invalid-learn-sid" >&2
  exit 1
fi

MANIFEST="$STAGING/$LEARN_SID/manifest.jsonl"
if [ ! -s "$MANIFEST" ]; then
  echo "kb-learn-commit:error:no-staged-manifest:$MANIFEST" >&2
  log "$(jq -nc --arg ts "$(ts_now)" --arg sid "$LEARN_SID" '{ts:$ts,event:"learn-commit-no-manifest",learn_sid:$sid}')"
  exit 1
fi

# ---- 1. Prepare (sort + validate) ----
PREPARED="$STAGING/$LEARN_SID/manifest-prepared.jsonl"
if ! bash "$ROOT/.claude/hooks/lib/kb-prepare-commit.sh" "$MANIFEST" "$PREPARED" 2>>"$ERR_LOG"; then
  echo "kb-learn-commit:error:prepare-failed" >&2
  log "$(jq -nc --arg ts "$(ts_now)" --arg sid "$LEARN_SID" '{ts:$ts,event:"learn-prepare-failed",learn_sid:$sid}')"
  exit 1
fi

# ---- 2. auto_commit kill switch ----
if ! bash "$ROOT/.claude/hooks/lib/kill-switch-check.sh" check auto_commit 2>/dev/null; then
  echo "kb-learn-commit:error:auto_commit-killswitch-active" >&2
  log "$(jq -nc --arg ts "$(ts_now)" --arg sid "$LEARN_SID" '{ts:$ts,event:"learn-commit-skip-killswitch",learn_sid:$sid}')"
  exit 1
fi

command -v claude >/dev/null 2>&1 || { echo "kb-learn-commit:error:claude-cli-not-found" >&2; exit 1; }
cd "$ROOT" || exit 1

# ---- 3. Commit (kb-committer, sync) ----
COMMIT_LOG="$STATE/last-learn-commit.log"
log "$(jq -nc --arg ts "$(ts_now)" --arg sid "$LEARN_SID" '{ts:$ts,event:"learn-commit-spawn",learn_sid:$sid}')"

COMMIT_PROMPT="Commit staged manifest for session $LEARN_SID. Manifest: $PREPARED. KB_ROOT: $ROOT. KB_SESSION_ID: $LEARN_SID. The manifest has already been sorted (entities → relations → observations) and validated by kb-prepare-commit.sh — read it directly, no sorting or validation needed. Source $ROOT/.claude/hooks/lib/kb-common.sh for helpers. This is an ad-hoc 'learn this' capture, not a full session; commit exactly what is in the manifest."
# Prompt piped via stdin (robust): a trailing positional prompt is dropped when
# combined with --agent/--allowedTools/--permission-mode. env -u clears any stale
# ANTHROPIC_API_KEY so the nested claude uses the OAuth session credentials.
printf '%s' "$COMMIT_PROMPT" | ${TIMEOUT_CMD:+$TIMEOUT_CMD 300} \
  env -u ANTHROPIC_API_KEY claude --agent kb-committer \
    --print \
    --permission-mode bypassPermissions \
    --allowedTools "Bash,Write,Edit,Read,Glob,Grep,mcp__knowledge-graph__create_entities,mcp__knowledge-graph__create_relations,mcp__knowledge-graph__add_observations,mcp__knowledge-graph__find_memories_by_name,mcp__knowledge-graph__search_memories" \
    > "$COMMIT_LOG" 2>&1 || true

# Success signal: a digest landed for this LEARN_SID (committer writes it only on zero failures).
DIGEST="$(ls "$ROOT/.athanor/distilled/sessions/"*"${LEARN_SID}"* 2>/dev/null | head -1)"
if [ -z "$DIGEST" ]; then
  echo "kb-learn-commit:error:commit-incomplete-no-digest (see $COMMIT_LOG)" >&2
  log "$(jq -nc --arg ts "$(ts_now)" --arg sid "$LEARN_SID" '{ts:$ts,event:"learn-commit-no-digest",learn_sid:$sid}')"
  exit 1
fi
log "$(jq -nc --arg ts "$(ts_now)" --arg sid "$LEARN_SID" '{ts:$ts,event:"learn-commit-done",learn_sid:$sid}')"

# ---- 5. Write learned-ids marker (keyed by LIVE session) for distiller skip ----
# Done BEFORE the supervisor so the marker exists even if the audit is slow.
if [ -n "$LIVE_SID" ] && [ "$LIVE_SID" != "unknown-live" ] && [[ "$LIVE_SID" =~ ^[a-zA-Z0-9_-]{4,128}$ ]]; then
  MARKER_DIR="$STATE/learned-ids"
  mkdir -p "$MARKER_DIR"
  MARKER="$MARKER_DIR/${LIVE_SID}.jsonl"
  # Pull committed entity canonical_names from the prepared manifest.
  while IFS= read -r ename; do
    [ -z "$ename" ] && continue
    jq -nc --arg e "$ename" --arg ls "$LEARN_SID" --arg ts "$(ts_now)" \
      '{entity:$e, learn_sid:$ls, ts:$ts}' >> "$MARKER" 2>/dev/null || true
  done < <(jq -r 'select(.kind=="entity") | .canonical_name // empty' "$PREPARED" 2>/dev/null)
fi

# ---- 4. Supervise (distillation-supervisor, sync) ----
# Resolve the live transcript as evidence (best-effort). The supervisor can also
# audit groundedness against the manifest's evidence_snippet fields.
SUPER_LOG="$STATE/last-learn-supervisor.log"
TRANSCRIPT=""
if [ -n "$LIVE_SID" ]; then
  ENCODED="$(printf '%s' "$ROOT" | sed 's|/|-|g')"
  CAND="$HOME/.claude/projects/$ENCODED/$LIVE_SID.jsonl"
  [ -f "$CAND" ] && TRANSCRIPT="$CAND"
fi
EVIDENCE_NOTE="The raw manifest is at .athanor/_staging/$LEARN_SID/manifest.jsonl and the prepared manifest at .athanor/_staging/$LEARN_SID/manifest-prepared.jsonl."
[ -n "$TRANSCRIPT" ] && EVIDENCE_NOTE="Transcript (live session, evidence): $TRANSCRIPT. $EVIDENCE_NOTE"

SUPER_PROMPT="Supervise ad-hoc learn capture $LEARN_SID. $EVIDENCE_NOTE The kb-committer has already committed all staged records to the graph. This was a user-asserted 'learn this' capture (not an LLM-distilled session), so the user is the primary authority — focus your audit on schema compliance, vocabulary discipline, and whether each committed record is grounded in the stated fact / evidence_snippet. Decide approve|reject|revise|escalate per athanor-supervision/SKILL.md. On approve, append your decision to .athanor/_state/supervisor-decisions.jsonl with session_id \"$LEARN_SID\". On reject/revise/escalate, append your decision with session_id \"$LEARN_SID\" and an 'outcome' field. Do NOT touch distill-cursor.json or distill-pending.jsonl."
printf '%s' "$SUPER_PROMPT" | ${TIMEOUT_CMD:+$TIMEOUT_CMD 300} \
  env -u ANTHROPIC_API_KEY claude --agent distillation-supervisor --print \
    --permission-mode acceptEdits \
    --allowedTools "Bash Write Read Glob Grep mcp__knowledge-graph__search_memories mcp__knowledge-graph__find_memories_by_name mcp__knowledge-graph__read_graph" \
    > "$SUPER_LOG" 2>&1 || true

# ---- Read supervisor outcome (scoped to LEARN_SID); HITL on non-approve ----
DECISIONS="$STATE/supervisor-decisions.jsonl"
OUTCOME=""
# Retry: the supervisor's decision write may not be flushed the instant its
# process exits. Poll briefly (6×1s) before concluding "no outcome".
for _try in 1 2 3 4 5 6; do
  if [ -f "$DECISIONS" ]; then
    # Slurp the whole ledger as a JSON-value stream (robust to compact OR
    # pretty-printed / multi-line objects), filter by session_id, take last.
    # A line-oriented grep|tail|jq breaks the moment the supervisor writes
    # indented JSON, which it does — the field is "session_id": "..." (with a
    # space), and a multi-line object has no single greppable line.
    OUTCOME="$(jq -rs --arg sid "$LEARN_SID" 'map(select(.session_id==$sid)) | last // {} | (.outcome // .decision // empty)' "$DECISIONS" 2>/dev/null)"
  fi
  [ -n "$OUTCOME" ] && break
  sleep 1
done

case "$OUTCOME" in
  approve)
    : # committed + audited clean
    ;;
  reject|revise|escalate)
    jq -nc --arg ts "$(ts_now)" --arg type "learn_supervisor_$OUTCOME" \
      --arg sid "$LEARN_SID" --arg mp "$STAGING/$LEARN_SID/manifest-prepared.jsonl" \
      '{ts:$ts,type:$type,session_id:$sid,manifest_path:$mp,note:"learn-commit already wrote to graph; this is a post-hoc audit flag"}' \
      >> "$STATE/hitl-queue.jsonl" 2>/dev/null || true
    log "$(jq -nc --arg ts "$(ts_now)" --arg sid "$LEARN_SID" --arg o "$OUTCOME" '{ts:$ts,event:"learn-supervisor-flag",learn_sid:$sid,outcome:$o}')"
    ;;
  *)
    # supervisor timed out / empty — committed knowledge stands; flag for review.
    jq -nc --arg ts "$(ts_now)" --arg type "learn_supervisor_no_outcome" \
      --arg sid "$LEARN_SID" --arg mp "$STAGING/$LEARN_SID/manifest-prepared.jsonl" \
      '{ts:$ts,type:$type,session_id:$sid,manifest_path:$mp,note:"learn committed without a supervisor outcome (timeout/empty)"}' \
      >> "$STATE/hitl-queue.jsonl" 2>/dev/null || true
    log "$(jq -nc --arg ts "$(ts_now)" --arg sid "$LEARN_SID" '{ts:$ts,event:"learn-supervisor-no-outcome",learn_sid:$sid}')"
    ;;
esac

# ---- Report (single line) ----
E=$(grep -c '"kind":"entity"' "$PREPARED" 2>/dev/null || echo 0)
R=$(grep -c '"kind":"relation"' "$PREPARED" 2>/dev/null || echo 0)
O=$(grep -c '"kind":"observation"' "$PREPARED" 2>/dev/null || echo 0)
echo "learned: ${E} entities, ${R} relations, ${O} observations → committed → supervised:${OUTCOME:-none} → indexed"
exit 0
