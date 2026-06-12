#!/usr/bin/env bash
# kb-common.sh — shared functions for KB wrapper scripts.
# Source this from kb-write-*.sh and kb-recall.sh.
# Pure shell + jq. No external deps beyond jq, sha256sum/shasum.
# Entity types: Concept, Finding, Procedure, Pattern, Session.

set -eo pipefail

# Resolve repo root from CLAUDE_PROJECT_DIR or git toplevel
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  KB_ROOT="$CLAUDE_PROJECT_DIR"
else
  KB_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

KB_PROTOCOL_DIR="$KB_ROOT/protocol"
# KB_STATE_DIR is overridable via env (used by the eval harness to isolate
# wrapper tests from the live committed-ids ledger). Falls back to the repo's
# canonical state dir when unset.
KB_STATE_DIR="${KB_STATE_DIR:-$KB_ROOT/.athanor/_state}"
KB_STAGING_DIR="${KB_STAGING_DIR:-$KB_ROOT/.athanor/_staging}"
KB_VOCAB_DIR="$KB_PROTOCOL_DIR/vocabulary"
KB_SCHEMA_DIR="$KB_PROTOCOL_DIR/schema"
# Vector layer (athanor-owned; SocratiCode removed). The corpus is the durable,
# DB-independent backup; vec.sh is the single entry point to the vector DB.
KB_CORPUS_DIR="${KB_CORPUS_DIR:-$KB_ROOT/.athanor/corpus}"
KB_VEC="$KB_ROOT/.claude/hooks/lib/vec.sh"

# ---------- Single-flight lock for vector-DB writes ----------
# Serialises kb-index.sh / kb-reindex.sh so two collection ops can never overlap
# (overlapping drop/create on a vector DB is what caused the Qdrant deadlock).
# mkdir is atomic on every POSIX fs; flock is absent on macOS, so we don't use it.
# Stale locks (holder PID dead) are reclaimed automatically.
kb_vec_lock() {
  # $1 = "wait" (poll up to ~30s) | "nowait" (default: fail immediately if held)
  local mode="${1:-nowait}" lockd waited=0
  lockd="$KB_STATE_DIR/vec-write.lock.d"
  mkdir -p "$KB_STATE_DIR" 2>/dev/null || true
  while ! mkdir "$lockd" 2>/dev/null; do
    local opid; opid="$(cat "$lockd/pid" 2>/dev/null || echo '')"
    if [ -n "$opid" ] && ! kill -0 "$opid" 2>/dev/null; then
      rm -rf "$lockd" 2>/dev/null; continue   # holder is dead — reclaim
    fi
    if [ "$mode" = "wait" ] && [ "$waited" -lt 30 ]; then
      sleep 1; waited=$((waited + 1)); continue
    fi
    return 1   # held by a live process and we won't wait
  done
  echo $$ > "$lockd/pid" 2>/dev/null || true
  KB_VEC_LOCKD="$lockd"
  return 0
}
kb_vec_unlock() { [ -n "${KB_VEC_LOCKD:-}" ] && rm -rf "$KB_VEC_LOCKD" 2>/dev/null; KB_VEC_LOCKD=""; }

# ---------- ID hashing (deterministic, content-based) ----------
kb_hash_id() {
  # Args: any number of strings to hash. Joined with ":".
  local input
  input="$(printf '%s:' "$@")"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | cut -c1-16
  else
    printf '%s' "$input" | shasum -a 256 | cut -c1-16
  fi
}

# ---------- Vocabulary check ----------
# Returns 0 if term is in vocab, 1 if not.
kb_vocab_contains() {
  local vocab_file="$1"
  local term="$2"
  [ -f "$vocab_file" ] || return 1
  grep -Fxq -- "$term" "$vocab_file" 2>/dev/null
}

# ---------- Audit log ----------
kb_audit() {
  local action="$1"
  local payload="$2"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$KB_STATE_DIR"
  # Compact the payload to ensure one row per write (compatible with jsonl tools).
  local compact
  compact="$(printf '%s' "$payload" | jq -c . 2>/dev/null || printf '%s' "$payload")"
  printf '{"ts":"%s","action":"%s","payload":%s}\n' \
    "$ts" "$action" "$compact" >> "$KB_STATE_DIR/kb-writes.jsonl"
}

# ---------- Reject / OK / Skip ----------
kb_reject() {
  local reason="$1"
  printf 'reject:%s\n' "$reason" >&2
  exit 1
}

kb_ok() {
  local id="$1"
  printf 'ok:%s\n' "$id"
  exit 0
}

kb_skip() {
  local id="$1"
  printf 'skip:already-written:%s\n' "$id"
  exit 0
}

# ---------- Idempotency check ----------
# Has this exact ID been written before? Checks current-session staging (fast path)
# then the cross-session committed-ids log (canonical dedup source).
kb_already_written() {
  local id="$1"
  local session_id="${KB_SESSION_ID:-unknown}"
  # Step 1 (fast path): current session staging manifest.
  local manifest="$KB_STAGING_DIR/$session_id/manifest.jsonl"
  if [ -f "$manifest" ]; then
    if grep -qF "\"id\":\"$id\"" "$manifest" 2>/dev/null; then
      return 0
    fi
  fi
  # Step 2 (cross-session): committed-ids log. Whole-line fixed-string match
  # (-x) so free text in the file can't poison via substring. The committed
  # line format is exactly: {"id":"<val>"}
  local cfile="$KB_STATE_DIR/committed-ids.jsonl"
  if [ -f "$cfile" ]; then
    if grep -Fxq "{\"id\":\"$id\"}" "$cfile" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# ---------- Pending-vocab size cap ----------
# Call AFTER appending a new pending-vocab entry to bound unbounded growth.
# Caps the pending-vocab file at 500 entries (keeps the newest 500 lines).
# Soft-fail: never abort the caller on a cap error.
kb_cap_pending_vocab() {
  # Cap pending-vocab file at 500 entries (dedup by term+type, keep latest)
  local PENDING_VOCAB="$KB_ROOT/.athanor/_state/pending-vocab-additions.json"
  [ -f "$PENDING_VOCAB" ] || return 0
  local ENTRY_COUNT
  ENTRY_COUNT=$(wc -l < "$PENDING_VOCAB" 2>/dev/null || echo 0)
  if [ "${ENTRY_COUNT:-0}" -gt 500 ]; then
    # Keep last 500 lines (newest entries)
    tail -500 "$PENDING_VOCAB" > "${PENDING_VOCAB}.tmp" 2>/dev/null && \
      mv "${PENDING_VOCAB}.tmp" "$PENDING_VOCAB" 2>/dev/null || true
  fi
}

# ---------- Record a durable commit ----------
# Appends a compact whole-line {"id":"..."} for cross-session idempotency.
# Called by bypass-detector.sh when it records an authorized write.
kb_record_commit() {
  local id="$1"
  local cfile="$KB_STATE_DIR/committed-ids.jsonl"
  mkdir -p "$KB_STATE_DIR"
  if command -v flock >/dev/null 2>&1; then
    ( flock -x 9; printf '{"id":"%s"}\n' "$id" >> "$cfile" ) 9>"${cfile}.lock"
  else
    # macOS: O_APPEND writes <4KB are atomic; no flock available
    printf '{"id":"%s"}\n' "$id" >> "$cfile"
  fi
}

# ---------- Stage write ----------
kb_stage() {
  local payload="$1"
  local session_id="${KB_SESSION_ID:-unknown}"
  # Validate session_id is a safe path component (UUID-like / hex / slug).
  if [[ ! "$session_id" =~ ^[a-zA-Z0-9_-]{4,128}$ ]]; then
    echo "reject:invalid-session-id-format" >&2
    exit 1
  fi
  # Defense-in-depth: ensure constructed path stays under the staging dir.
  local staging_path="$KB_STAGING_DIR/$session_id/manifest.jsonl"
  case "$staging_path" in
    "$KB_STAGING_DIR/"*) : ;;  # ok
    *) echo "reject:path-traversal-detected" >&2; exit 1 ;;
  esac
  local dir="$KB_STAGING_DIR/$session_id"
  mkdir -p "$dir"
  printf '%s\n' "$payload" >> "$staging_path"
}

# ---------- jq helper with field extraction ----------
kb_field() {
  local json="$1"
  local field="$2"
  printf '%s' "$json" | jq -r ".$field // empty" 2>/dev/null
}

# ---------- Validate JSON parses ----------
kb_validate_json() {
  local json="$1"
  printf '%s' "$json" | jq -e . >/dev/null 2>&1
}
