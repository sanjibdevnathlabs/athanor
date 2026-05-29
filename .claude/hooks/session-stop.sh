#!/usr/bin/env bash
# session-stop.sh — runs on Stop. Async (returns immediately).
# 1. Locate the live transcript JSONL in ~/.claude/projects/<encoded-cwd>/<session>.jsonl
# 2. Copy to .athanor/raw/<date>-<session>.jsonl
# 3. Spawn a detached `claude` CLI invocation of the session-distiller subagent
#
# On any error: log + exit 0 (must NOT break user's session-end).

set -uo pipefail

TIMEOUT_CMD="$(command -v gtimeout || command -v timeout || true)"

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE="$ROOT/.athanor/_state"
RAW_DIR="$ROOT/.athanor/raw"
ERR_LOG="$STATE/hook-errors.jsonl"

mkdir -p "$RAW_DIR" "$STATE"

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)"
TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || true)"
DATE="$(date -u +%Y-%m-%d)"

# ── Sanitize SESSION_ID before it ever reaches a spawn prompt ──
# SESSION_ID is interpolated into natural-language prompts passed to privileged
# `claude --agent` invocations. A crafted id (e.g. containing shell/instruction
# text) would be injected into the agent's instruction context. Allow only
# UUID-like / hex-with-dashes ids.
if [[ ! "$SESSION_ID" =~ ^[a-f0-9-]{8,64}$ ]]; then
  echo "[session-stop] WARN: SESSION_ID '$SESSION_ID' contains unsafe chars — aborting distillation" >> "$STATE/err-log.txt"
  exit 0
fi

# If transcript_path is provided, use it. Otherwise try to locate via session id.
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  # Encode CWD for the projects/ directory name (Claude Code uses path-encoded)
  ENCODED="$(printf '%s' "$ROOT" | sed 's|/|-|g')"
  CANDIDATE="$HOME/.claude/projects/$ENCODED/$SESSION_ID.jsonl"
  if [ -f "$CANDIDATE" ]; then
    TRANSCRIPT_PATH="$CANDIDATE"
  fi
fi

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  DEST="$RAW_DIR/${DATE}-${SESSION_ID}.jsonl"

  # ── Sanitize DEST: must resolve under $RAW_DIR to prevent path traversal ──
  # Use realpath if available; otherwise fall back to a string-prefix check on
  # the computed (unexpanded) path, which is sufficient because SESSION_ID has
  # already been validated to be hex+dashes only (no ../ components possible).
  # Prefer realpath for canonical containment, but `realpath -m` is a GNU-only
  # flag: BSD/macOS realpath does not support it and returns EMPTY for a
  # not-yet-existing path like DEST. Treat an empty realpath result as "realpath
  # unusable here" and fall back to the safe string-prefix check rather than
  # mis-firing the "outside RAW_DIR" abort (which silently broke ALL distillation
  # on macOS). SESSION_ID is already validated hex-only, so no ../ is possible
  # and the string-prefix check is sufficient.
  DEST_REAL=""
  RAW_REAL=""
  if command -v realpath >/dev/null 2>&1; then
    DEST_REAL="$(realpath -m "$DEST" 2>/dev/null || true)"
    RAW_REAL="$(realpath -m "$RAW_DIR" 2>/dev/null || true)"
  fi
  if [ -n "$DEST_REAL" ] && [ -n "$RAW_REAL" ]; then
    # realpath usable — canonical containment check.
    if [ "${DEST_REAL#"$RAW_REAL/"}" = "$DEST_REAL" ]; then
      echo "[session-stop] WARN: DEST '$DEST' is outside RAW_DIR — aborting distillation" >> "$STATE/err-log.txt"
      exit 0
    fi
  else
    # realpath unusable (e.g. BSD realpath without -m) — string-prefix fallback.
    case "$DEST" in
      "$RAW_DIR/"*) ;;
      *)
        echo "[session-stop] WARN: DEST '$DEST' is outside RAW_DIR — aborting distillation" >> "$STATE/err-log.txt"
        exit 0
        ;;
    esac
  fi
else
  printf '{"ts":"%s","hook":"session-stop","err":"transcript-not-found","session_id":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$SESSION_ID" >> "$ERR_LOG"
  exit 0
fi

# ── Guard 1: skip agent sessions (meta-session cascade prevention) ──
# Runs BEFORE the raw copy (Bug M1) so infra transcripts are never copied to raw/.
# `claude --agent X` sessions emit agent-setting records in their transcript.
# These are infra agents (distiller, supervisor, auditor) with no user knowledge.
# In-session Agent() subagents (Explore, general-purpose) share the parent transcript.
# Read from the SOURCE transcript ($TRANSCRIPT_PATH) since $DEST does not exist yet.
# Scan first 50 lines (increased from 20 — record may appear later in some agents).

# Guard 1a: Check active-infra-sessions sentinel (covers kb-committer which
# runs with bypassPermissions and does NOT emit an agentSetting record, so the
# head/grep agentSetting check below misses it). The committer writes
# active-infra-sessions/<committer_sid>.lock during self-registration.
ACTIVE_INFRA_DIR="$ROOT/.athanor/_state/active-infra-sessions"
if [ -f "$ACTIVE_INFRA_DIR/${SESSION_ID}.lock" ]; then
  printf '{"ts":"%s","event":"skip","reason":"infra-session-sentinel","session_id":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" \
    >> "$STATE/hook-errors.jsonl" 2>/dev/null || true
  exit 0
fi

AGENT_NAME=$(head -50 "$TRANSCRIPT_PATH" 2>/dev/null | \
  jq -r 'select(.type=="agent-setting") | .agentSetting // empty' 2>/dev/null | \
  head -1)

# All athanor infrastructure agents — their sessions must never be re-distilled
INFRA_AGENTS="session-distiller|kb-committer|distillation-supervisor|kb-auditor|kb-evaluator"

if [ -n "$AGENT_NAME" ] && echo "$AGENT_NAME" | grep -qE "^($INFRA_AGENTS)$"; then
  printf '{"ts":"%s","event":"skip","reason":"infra-agent-session","agent":"%s","session_id":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$AGENT_NAME" "$SESSION_ID" \
    >> "$STATE/hook-errors.jsonl" 2>/dev/null || true
  exit 0
fi

# NOTE: Guard 1b (sentinel-match cascade guard) removed — it was broken
# (checked parent's $SESSION_ID against committer's own session id, never matched)
# and Guard 1 (agentSetting check) already handles all infra agents incl. kb-committer.

# Also skip if transcript was copied into .athanor/raw/ — that's an infra session's own copy.
case "$TRANSCRIPT_PATH" in
  */.athanor/raw/*)
    printf '{"ts":"%s","hook":"session-stop","skip":"infra-raw-transcript","session_id":"%s"}\n' \
      "$(date -u +%FT%TZ)" "$SESSION_ID" >> "$ERR_LOG"
    exit 0
    ;;
esac

# ── Raw copy (Bug M1: only for non-infra/user sessions, after Guard 1) ──
cp -f "$TRANSCRIPT_PATH" "$DEST" 2>/dev/null || {
  printf '{"ts":"%s","hook":"session-stop","err":"copy-failed"}\n' "$(date -u +%FT%TZ)" >> "$ERR_LOG"
  exit 0
}

# ── Guard 2: cursor-based dedup (skip if already distilled) ──
CURSOR_FILE="$STATE/distill-cursor.json"
if [ -f "$CURSOR_FILE" ]; then
  LAST_SID="$(jq -r '.last_distilled_session_id // ""' "$CURSOR_FILE" 2>/dev/null || true)"
  if [ "$LAST_SID" = "$SESSION_ID" ]; then
    printf '{"ts":"%s","hook":"session-stop","skip":"already-distilled","session_id":"%s"}\n' \
      "$(date -u +%FT%TZ)" "$SESSION_ID" >> "$ERR_LOG"
    exit 0
  fi
fi

# ── Guard 3: global project-level lock (at most 1 active distill pipeline) ──
GLOBAL_LOCK="$STATE/distill-global.lock"
if [ -f "$GLOBAL_LOCK" ]; then
  LOCK_PID="$(jq -r '.pid // ""' "$GLOBAL_LOCK" 2>/dev/null || true)"
  LOCK_SID="$(jq -r '.session_id // ""' "$GLOBAL_LOCK" 2>/dev/null || true)"
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    # Lock held by a live process — skip.
    printf '{"ts":"%s","hook":"session-stop","skip":"global-lock-held","lock_pid":"%s","lock_sid":"%s","session_id":"%s"}\n' \
      "$(date -u +%FT%TZ)" "$LOCK_PID" "$LOCK_SID" "$SESSION_ID" >> "$ERR_LOG"
    exit 0
  fi
  # Stale lock (process dead) — reclaim silently.
  rm -f "$GLOBAL_LOCK"
fi

# Kill-switch check: if `distiller` is disabled, skip everything.
if [ -f "$STATE/kill-switch.json" ]; then
  DSTATE="$(jq -r '.distiller // "enabled"' "$STATE/kill-switch.json" 2>/dev/null || echo enabled)"
  if [ "$DSTATE" != "enabled" ]; then
    printf '{"ts":"%s","hook":"session-stop","err":"distiller-killswitch-disabled","session_id":"%s"}\n' \
      "$(date -u +%FT%TZ)" "$SESSION_ID" >> "$ERR_LOG"
    exit 0
  fi
fi

# ── Prefer pre-compact transcript copy if one exists (Bug M1) ──
# pre-compact.sh writes a richer pre-compaction copy to
# .athanor/raw/precompact-<ts>-<sid>.jsonl. That copy captures content lost to
# compaction, so the distiller should consume it in preference to the
# post-compaction copy at $DEST. Fall back to $DEST when none exists.
PRECOMPACT=$(ls "$RAW_DIR/precompact-"*"-${SESSION_ID}.jsonl" 2>/dev/null | tail -1)
DISTILL_SRC="${PRECOMPACT:-$DEST}"
if [ -n "$PRECOMPACT" ]; then
  PRECOMPACT_USED="yes"
else
  PRECOMPACT_USED="no"
fi

# ── Fix 4: acquire global lock BEFORE reading/incrementing the attempt counter ──
# The attempt-counter read + pending-entry write + all spawns must be inside the
# global lock. Acquiring the lock here (instead of at the original line below the
# attempt read) closes the race where two concurrent Stop hooks both read the same
# EXISTING_ATTEMPTS, both write a pending entry, and both spawn the pipeline.
# The background subshell inherits this lock and removes it on EXIT.
GLOBAL_LOCK="$STATE/distill-global.lock"
printf '{"pid":%s,"session_id":"%s","ts":"%s"}\n' "$$" "$SESSION_ID" "$(date -u +%FT%TZ)" > "$GLOBAL_LOCK"

# ── Track pending distillation durably (Bug H3) ──
# Record this session as pending BEFORE spawning the distiller so a crashed
# distiller leaves a recoverable trail. Removed on confirmed success below.
PENDING_FILE="$STATE/distill-pending.jsonl"
# Fix 7: retry counter for partial commits. Read prior attempts (if a pending
# entry already exists for this session) and increment.
EXISTING_ATTEMPTS=$(grep -F "\"session_id\":\"$SESSION_ID\"" "$PENDING_FILE" 2>/dev/null | tail -1 | jq -r '.attempts // 0' 2>/dev/null || echo 0)
NEW_ATTEMPTS=$((EXISTING_ATTEMPTS + 1))
printf '{"ts":"%s","session_id":"%s","transcript":"%s","attempts":%s}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" "$DISTILL_SRC" "$NEW_ATTEMPTS" \
  >> "$PENDING_FILE"

# Fix 7: max-retries guard. If this session has already been attempted >= 3
# times, do NOT re-spawn the pipeline. Quarantine and enqueue HITL instead.
if [ "$NEW_ATTEMPTS" -ge 3 ]; then
  TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  QUAR_BASE="$ROOT/.athanor/_quarantine"
  QUAR_DEST="$QUAR_BASE/${SESSION_ID}-max-retries"
  mkdir -p "$QUAR_BASE"
  if [ -d "$ROOT/.athanor/_staging/$SESSION_ID" ]; then
    mv "$ROOT/.athanor/_staging/$SESSION_ID" "$QUAR_DEST" 2>/dev/null || true
  fi
  jq -n \
    --arg ts "$TS_NOW" \
    --arg type "max_retries_exceeded" \
    --arg session_id "$SESSION_ID" \
    --arg reason "max-retries-exceeded" \
    --arg manifest_path "$QUAR_DEST/manifest.jsonl" \
    -c '{ts:$ts, type:$type, session_id:$session_id, reason:$reason, manifest_path:$manifest_path}' \
    >> "$STATE/hitl-queue.jsonl" 2>/dev/null || true
  printf '{"ts":"%s","event":"distill-skip-max-retries","attempts":%s,"session_id":"%s"}\n' \
    "$TS_NOW" "$NEW_ATTEMPTS" "$SESSION_ID" >> "$ERR_LOG"
  exit 0
fi

# P2 pipeline: distiller → supervisor → commit-or-quarantine.
# Global lock was already acquired above (Fix 4) before the attempt-counter read;
# the background subshell inherits it and removes it on EXIT.

# Spawn detached so the user's session ends fast.
DISTILL_LOG="$STATE/last-distill.log"
SUPER_LOG="$STATE/last-supervisor.log"
{
  # ── Guard 4: mkdir-based lock per session (atomic on POSIX, no flock needed) ──
  LOCK_DIR="$ROOT/.athanor/_staging/$SESSION_ID/.distill.lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Lock exists — check for stale lock (PID file inside, process dead = stale)
    LOCK_PID_FILE="$LOCK_DIR/pid"
    if [ -f "$LOCK_PID_FILE" ]; then
      OLD_PID="$(cat "$LOCK_PID_FILE" 2>/dev/null || true)"
      if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        printf '{"ts":"%s","hook":"session-stop","skip":"already-locked","pid":"%s","session_id":"%s"}\n' \
          "$(date -u +%FT%TZ)" "$OLD_PID" "$SESSION_ID" >> "$ERR_LOG"
        exit 0
      fi
      # Stale lock — previous process died. Reclaim.
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    else
      printf '{"ts":"%s","hook":"session-stop","skip":"already-locked","session_id":"%s"}\n' \
        "$(date -u +%FT%TZ)" "$SESSION_ID" >> "$ERR_LOG"
      exit 0
    fi
  fi
  echo $$ > "$LOCK_DIR/pid"
  # Fix 3: cascade sentinel path keyed by OUR session id. Declared here (before
  # the trap) so the combined trap can clean it up via ${COMMITTER_SENTINEL:-}
  # even though it is not touched until just before the committer spawn.
  SENTINEL_DIR="$ROOT/.athanor/_state/active-infra-sessions"
  COMMITTER_SENTINEL="$SENTINEL_DIR/committer-pending-${SESSION_ID}.lock"
  # Single combined trap (Fix 4 + Fix 3): the per-session LOCK_DIR, the global
  # lock, and the committer cascade sentinel are all cleaned up. Previously two
  # separate `trap … EXIT` lines meant the second clobbered the first, leaving
  # GLOBAL_LOCK orphaned.
  trap 'rm -rf "${LOCK_DIR:-}"; rm -f "${GLOBAL_LOCK:-}"; rm -f "${COMMITTER_SENTINEL:-}"' EXIT TERM INT

  if command -v claude >/dev/null 2>&1; then
    cd "$ROOT" || exit 0

    # 1. Distill (skipped on manual recovery)
    # NOTE: The distiller STAGES ONLY via the kb-write-* wrappers. It never commits
    # to Neo4j. The kb-committer (spawned below) performs all graph/vector commits
    # after the distiller exits. The supervisor audits the committed records.
    #
    # Recovery path (kb-recover.sh): if staging already has a manifest, the
    # distiller has nothing to do — the manifest was re-injected from quarantine.
    # Skip distillation entirely and jump straight to prepare-commit + committer.
    if [ -f "$ROOT/.athanor/_staging/$SESSION_ID/manifest.jsonl" ]; then
      printf '{"ts":"%s","event":"recovery-manifest-exists","note":"skipping distiller; using existing staging manifest","session_id":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$ERR_LOG"
      # Jump directly to prepare-commit step (no distiller spawn).
    else
      printf '{"ts":"%s","hook":"session-stop","note":"distill-spawn","session_id":"%s","src":"%s","precompact_used":"%s"}\n' \
        "$(date -u +%FT%TZ)" "$SESSION_ID" "$DISTILL_SRC" "$PRECOMPACT_USED" >> "$ERR_LOG"
      if ! ${TIMEOUT_CMD:+$TIMEOUT_CMD 600} claude --agent session-distiller --print \
        --permission-mode acceptEdits \
        --allowedTools "Bash Write Edit Read Glob Grep mcp__knowledge-graph__find_memories_by_name mcp__knowledge-graph__search_memories mcp__plugin_socraticode_socraticode__codebase_context_index" \
        "Distill session $SESSION_ID from transcript at $DISTILL_SRC. Stage all extracted artifacts via the kb-write-*.sh wrappers. Do NOT call mcp__knowledge-graph__create_entities, create_relations, or add_observations — the kb-committer handles all Neo4j commits after you exit. Your job ends when the staging manifest is complete." \
        > "$DISTILL_LOG" 2>&1; then
        # Distiller exited non-zero — leave pending entry in place for retry/visibility.
        printf '{"ts":"%s","event":"distill-failed","session_id":"%s"}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$STATE/hook-errors.jsonl"
        exit 0
      fi
    fi

    # --- kb-committer: commit staged manifest to Neo4j + Qdrant ---
    MANIFEST_FILE="$ROOT/.athanor/_staging/$SESSION_ID/manifest.jsonl"

    if [ -f "$MANIFEST_FILE" ] && [ -s "$MANIFEST_FILE" ]; then
      COMMIT_LOG="$STATE/last-commit.log"

      # Pre-process the manifest: sort and validate (deterministic, no LLM).
      # The committer receives a clean, sorted, pre-validated manifest instead of
      # the raw interleaved one. If preparation fails (empty / all-rejected /
      # read error), there is nothing valid to commit — stay pending and exit.
      PREPARED_MANIFEST="$ROOT/.athanor/_staging/$SESSION_ID/manifest-prepared.jsonl"
      if bash "$ROOT/.claude/hooks/lib/kb-prepare-commit.sh" \
           "$MANIFEST_FILE" "$PREPARED_MANIFEST" 2>> "$STATE/hook-errors.jsonl"; then
        COMMIT_MANIFEST="$PREPARED_MANIFEST"
      else
        printf '{"ts":"%s","event":"prepare-commit-failed","session_id":"%s"}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$STATE/hook-errors.jsonl" || true
        exit 0  # nothing valid to commit, stay pending
      fi

      # Check auto_commit kill switch before spawning committer (Fix 2)
      if ! bash "$ROOT/.claude/hooks/lib/kill-switch-check.sh" check auto_commit 2>/dev/null; then
        printf '{"ts":"%s","event":"commit-skip-killswitch","reason":"auto_commit kill switch is active; skipping kb-committer","session_id":"%s"}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$ERR_LOG" 2>/dev/null || true
        exit 0
      fi

      printf '{"ts":"%s","event":"commit-spawn","session_id":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$STATE/hook-errors.jsonl" 2>/dev/null || true

      # Fix 3: write cascade sentinel BEFORE spawning the committer so it is in
      # place even if the committer crashes before its own Step-1 self-registration.
      # Keyed by OUR session id (we don't know the committer's future session id).
      # The committer ALSO writes its own SID-keyed sentinel in Step 1 for
      # self-protection. Cleaned up by the combined EXIT trap above.
      mkdir -p "$SENTINEL_DIR"
      touch "$COMMITTER_SENTINEL"

      # NOTE: parent-side sentinel (active-infra-sessions/committer-<parent_sid>.lock)
      # removed along with the broken Guard 1b that consumed it. The kb-committer now
      # writes its OWN sentinel at active-infra-sessions/<committer_sid>.lock during
      # self-registration; Guard 1 (agentSetting check) is the primary cascade defense.

      # NOTE: committer-context.json (shared singleton) removed — it had 6 failure
      # modes (race on concurrent commits, stale on crash, etc.). The kb-committer
      # now self-registers by creating its own _staging/<committer_sid>/manifest.jsonl
      # symlink at startup, so bypass-detector's session-manifest check resolves
      # the correct manifest without any shared state.

      ${TIMEOUT_CMD:+$TIMEOUT_CMD 600} \
        claude --agent kb-committer \
          --print \
          --permission-mode bypassPermissions \
          --allowedTools "Bash,Write,Edit,Read,Glob,Grep,mcp__knowledge-graph__create_entities,mcp__knowledge-graph__create_relations,mcp__knowledge-graph__add_observations,mcp__knowledge-graph__find_memories_by_name,mcp__knowledge-graph__search_memories,mcp__plugin_socraticode_socraticode__codebase_context_index" \
          "Commit staged manifest for session $SESSION_ID. Manifest: $COMMIT_MANIFEST. KB_ROOT: $ROOT. KB_SESSION_ID: $SESSION_ID. The manifest has already been sorted (entities → relations → observations) and validated by kb-prepare-commit.sh — read it directly, no sorting or validation needed. Source $ROOT/.claude/hooks/lib/kb-common.sh for helpers." \
          > "$COMMIT_LOG" 2>&1 || true

      printf '{"ts":"%s","event":"commit-done","session_id":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$STATE/hook-errors.jsonl" 2>/dev/null || true
    else
      printf '{"ts":"%s","event":"commit-skip","reason":"empty-manifest","session_id":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$STATE/hook-errors.jsonl" 2>/dev/null || true
    fi

    # ── Confirm distillation success: a session digest must exist (Bug H3) ──
    # "Success" = a digest file landed in distilled/sessions/ for this session.
    # The kb-committer writes the digest now (not the distiller), so this check
    # must run AFTER the committer completes. On confirmation, drop the pending
    # entry; otherwise log a failure and leave the pending entry for recovery.
    DIGEST_GLOB="$ROOT/.athanor/distilled/sessions/"*"${SESSION_ID}"*
    # shellcheck disable=SC2086
    if ls $DIGEST_GLOB >/dev/null 2>&1; then
      # NOTE (Bug H1): neither the cursor write nor the pending removal happen here.
      # Both now happen only in the supervisor 'approve)' case below, so a later
      # supervisor reject leaves the session eligible for re-distillation AND keeps
      # a recoverable pending entry.
      :
    else
      printf '{"ts":"%s","event":"distill-failed","session_id":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$STATE/hook-errors.jsonl"
    fi

    # ── Fix H1: gate supervisor on digest-exists ──
    # A partial commit (committer exit 1, no digest written) should NOT trigger the
    # supervisor — it has nothing useful to audit if the commit failed.
    DIGEST_EXISTS=$(ls "$ROOT/.athanor/distilled/sessions/"*"${SESSION_ID}"* 2>/dev/null | head -1)
    if [ -z "$DIGEST_EXISTS" ]; then
      printf '{"ts":"%s","event":"supervisor-skipped","reason":"no-digest","session_id":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$STATE/hook-errors.jsonl" 2>/dev/null || true
      # Session stays in pending, cursor not written
      exit 0
    fi

    # 2. Supervise (always runs when staging exists) — Bug M4.
    # The supervisor is an adversarial AUDIT of records the kb-committer already
    # committed. It is NOT gated on auto_commit: commits happen in the committer
    # above, so gating the audit on auto_commit would skip the audit while still
    # committing (semantically backwards). The audit always runs after a commit.
    if [ -f "$ROOT/.athanor/_staging/$SESSION_ID/manifest.jsonl" ]; then
      ${TIMEOUT_CMD:+$TIMEOUT_CMD 600} claude --agent distillation-supervisor --print \
        --permission-mode acceptEdits \
        --allowedTools "Bash Write Read Glob Grep mcp__knowledge-graph__search_memories mcp__knowledge-graph__find_memories_by_name mcp__knowledge-graph__read_graph" \
        "Supervise session $SESSION_ID. Transcript: $DISTILL_SRC. Manifest (the prepared manifest the kb-committer actually consumed): .athanor/_staging/$SESSION_ID/manifest-prepared.jsonl. The raw pre-preparation manifest is also available at .athanor/_staging/$SESSION_ID/manifest.jsonl — diff raw vs prepared if you suspect preparation dropped or altered records. Decide approve|reject|revise|escalate per athanor-supervision/SKILL.md. The kb-committer has committed all staged records to the graph. The distiller only staged artifacts via wrappers. Your role is to audit what the kb-committer committed against the original transcript. On approve, call supervisor-gate.sh approve and append your decision to .athanor/_state/supervisor-decisions.jsonl. On reject, call supervisor-gate.sh reject with reason. On revise or escalate, append your outcome to .athanor/_state/supervisor-decisions.jsonl with a 'outcome' field set to 'revise' or 'escalate'." \
        > "$SUPER_LOG" 2>&1 || true

      # ── Read supervisor outcome and act (Bug H1, H5) ──
      # The supervisor appends its decision to supervisor-decisions.jsonl.
      # Read the last entry. The cursor advances ONLY on approve; revise/escalate
      # quarantine the manifest and enqueue HITL (session stays eligible).
      DECISIONS_FILE="$STATE/supervisor-decisions.jsonl"
      HITL_QUEUE="$STATE/hitl-queue.jsonl"
      QUAR_BASE="$ROOT/.athanor/_quarantine"
      SUPER_OUTCOME=""
      if [ -f "$DECISIONS_FILE" ]; then
        # Fix 5: scope to THIS session_id instead of a blind tail -1 (a concurrent
        # pipeline's decision could otherwise be read as this session's outcome).
        SUPER_OUTCOME=$(grep -F "\"session_id\":\"$SESSION_ID\"" "$DECISIONS_FILE" 2>/dev/null | tail -1 | jq -r '.outcome // .decision // empty' 2>/dev/null)
      fi

      case "$SUPER_OUTCOME" in
        approve)
          # Cursor advances only on supervisor approval (Bug H1).
          jq -cn \
            --arg sid "$SESSION_ID" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{last_distilled_session_id: $sid, last_distilled_at: $ts, schema_version: "v1"}' \
            > "${CURSOR_FILE}.tmp" && mv "${CURSOR_FILE}.tmp" "$CURSOR_FILE" || true
          # Pending removed only on full successful pipeline (Bug M2). A supervisor
          # reject/revise/escalate leaves the pending entry for retry/visibility.
          if [ -f "$STATE/distill-pending.jsonl" ]; then
            grep -v "\"session_id\":\"$SESSION_ID\"" "$STATE/distill-pending.jsonl" \
              > "$STATE/distill-pending.jsonl.tmp" && \
              mv "$STATE/distill-pending.jsonl.tmp" "$STATE/distill-pending.jsonl"
          fi
          # Fix 2: clean up staging dir now that session is fully approved and committed.
          STAGING_DIR="$ROOT/.athanor/_staging/$SESSION_ID"
          if [ -d "$STAGING_DIR" ]; then
            rm -rf "$STAGING_DIR" || true
          fi
          ;;
        revise|escalate)
          # Fix 5 + Fix 6: HITL ownership and manifest-path resolution.
          #
          # The distillation-supervisor agent does NOT call supervisor-gate.sh for
          # revise/escalate (revise → writes .revise-feedback.md only; escalate →
          # writes its own HITL row), so session-stop must still own a HITL write
          # here for the revise case to be visible. To avoid a dangling pointer,
          # resolve manifest_path to wherever the manifest actually lives now:
          # prefer an existing quarantine manifest (in case some path already moved
          # staging via the gate), else fall back to the staging manifest.
          # Fix 6: NO quarantine mv here — we never move staging in this arm, so we
          # cannot create the dangling-pointer bug that duplicating the gate's move did.
          TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          # Enqueue HITL entry
          if [ "$SUPER_OUTCOME" = "revise" ]; then
            HITL_TYPE="supervisor_revision_needed"
          else
            HITL_TYPE="supervisor_escalation"
          fi
          # Resolve manifest_path: prefer an existing quarantine manifest (gate may
          # already have moved staging), else the staging manifest.
          MANIFEST_PATH="$ROOT/.athanor/_staging/$SESSION_ID/manifest.jsonl"
          QUAR_MATCH="$(ls -d "$QUAR_BASE/${SESSION_ID}"* 2>/dev/null | head -1)"
          if [ -n "$QUAR_MATCH" ] && [ -f "$QUAR_MATCH/manifest.jsonl" ]; then
            MANIFEST_PATH="$QUAR_MATCH/manifest.jsonl"
          fi
          # Construct via jq -n to escape session_id / paths (injection-safe).
          jq -n \
            --arg ts "$TS_NOW" \
            --arg type "$HITL_TYPE" \
            --arg session_id "$SESSION_ID" \
            --arg manifest_path "$MANIFEST_PATH" \
            -c '{ts:$ts, type:$type, session_id:$session_id, manifest_path:$manifest_path}' \
            >> "$HITL_QUEUE"
          # Log to err-log
          printf 'Session %s supervisor outcome: %s — see HITL queue\n' \
            "$SESSION_ID" "$SUPER_OUTCOME" \
            >> "$STATE/err-log.txt"
          ;;
        *)
          # reject or empty/unknown outcome — no cursor write (session stays eligible).
          printf '{"ts":"%s","hook":"session-stop","note":"supervisor-no-approve","outcome":"%s","session_id":"%s"}\n' \
            "$(date -u +%FT%TZ)" "$SUPER_OUTCOME" "$SESSION_ID" >> "$ERR_LOG"
          ;;
      esac

      # ── Fix H2: supervisor timeout/crash fallback ──
      # If the supervisor produced no valid outcome (timeout/crash/empty), the
      # session would otherwise get stuck: digest exists, but cursor never written
      # → infinite re-distill. The committer already committed, so the knowledge is
      # in Neo4j. Auto-approve (advance cursor) with a warning to break the limbo.
      if [ -z "$SUPER_OUTCOME" ] || [ "$SUPER_OUTCOME" = "unknown" ]; then
        # Fix 3: if staging is gone AND a quarantine dir exists for this session,
        # do NOT auto-approve — this is a previously-rejected session retrying.
        # Auto-approving would advance the cursor over a quarantined manifest.
        if ls "$ROOT/.athanor/_quarantine/${SESSION_ID}"* 2>/dev/null | head -1 | grep -q .; then
          printf '{"ts":"%s","event":"supervisor-skip-quarantined","reason":"staging missing and quarantine exists; not auto-approving","session_id":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$ERR_LOG" 2>/dev/null || true
          exit 0
        fi
        printf '{"ts":"%s","event":"supervisor-timeout-auto-approve","session_id":"%s"}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$STATE/hook-errors.jsonl" 2>/dev/null || true
        # Knowledge is already in Neo4j from committer — advance cursor to prevent infinite re-distill
        jq -cn \
          --arg sid "$SESSION_ID" \
          --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{last_distilled_session_id: $sid, last_distilled_at: $ts, schema_version: "v1"}' \
          > "${CURSOR_FILE}.tmp" && mv "${CURSOR_FILE}.tmp" "$CURSOR_FILE" || true

        # Create a HITL entry so the user can retroactively audit this un-supervised commit
        HITL_FILE="$ROOT/.athanor/_state/hitl-queue.jsonl"
        printf '{"ts":"%s","type":"supervisor_timeout_auto_approved","session_id":"%s","manifest_path":"%s","note":"Committed without supervisor review - timeout or crash"}\n' \
          "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SESSION_ID" "$ROOT/.athanor/_staging/$SESSION_ID/manifest-prepared.jsonl" >> "$HITL_FILE"

        # Fix 1: AUTO_APPROVED path must also remove the pending entry (same as the
        # normal approve path). Without this the session lingers in pending forever.
        PENDING_FILE="$ROOT/.athanor/_state/distill-pending.jsonl"
        if [ -f "$PENDING_FILE" ]; then
          grep -v "\"session_id\":\"$SESSION_ID\"" "$PENDING_FILE" > "${PENDING_FILE}.tmp" \
            && mv "${PENDING_FILE}.tmp" "$PENDING_FILE" || true
        fi

        # Fix 2: clean up staging dir on the timeout-fallback approve path too.
        STAGING_DIR="$ROOT/.athanor/_staging/$SESSION_ID"
        if [ -d "$STAGING_DIR" ]; then
          rm -rf "$STAGING_DIR" || true
        fi
      fi
    fi
  fi
} </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true

exit 0
