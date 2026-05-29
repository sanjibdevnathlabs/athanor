#!/usr/bin/env bash
# pre-compact.sh — backup transcript before context compaction.
# Async (Claude Code respects async:true config).
# Lets distiller see the FULL pre-compact transcript on Stop.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE="$ROOT/.athanor/_state"
RAW_DIR="$ROOT/.athanor/raw"
ERR_LOG="$STATE/hook-errors.jsonl"
mkdir -p "$RAW_DIR"

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)"
TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || true)"
TRIGGER="$(printf '%s' "$INPUT" | jq -r '.trigger // "auto"' 2>/dev/null || true)"
TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  DEST="$RAW_DIR/precompact-${TS}-${SESSION_ID}.jsonl"
  cp -f "$TRANSCRIPT_PATH" "$DEST" 2>/dev/null || {
    printf '{"ts":"%s","hook":"pre-compact","err":"copy-failed","trigger":"%s"}\n' \
      "$(date -u +%FT%TZ)" "$TRIGGER" >> "$ERR_LOG"
  }
fi

exit 0
