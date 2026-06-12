#!/usr/bin/env bash
# kb-index.sh — incremental index of new/changed KB artifacts into the vector DB.
#
# This is the single WRITE entry point for the vector layer. Both learning paths
# call it after their digest/runbook/skill lands on disk:
#   - kb-committer (Stop-hook distill) Step 6
#   - kb-learn-commit.sh (live "learn this")
#
# It (1) appends new/changed docs to the immutable corpus, (2) embeds only the
# changed ones, (3) upserts them into the active driver (no collection-lifecycle
# op — pure point upsert), (4) prunes vanished docs. Corpus append is the durable
# part; an embed/upsert failure never loses the knowledge (a later reindex replays
# it).
#
# Serialised against kb-reindex.sh via a single-flight lock so two vector ops can
# never overlap.
#
# Usage: bash .claude/hooks/lib/kb-index.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"
ERR_LOG="$KB_STATE_DIR/hook-errors.jsonl"

if ! kb_vec_lock wait; then
  printf '{"ts":"%s","stage":"kb-index","note":"another vec write in progress; skipped (in-flight run rescans all on-disk docs)"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$ERR_LOG" 2>/dev/null || true
  echo "kb-index: another vec write in progress — skipped (corpus picked up by the in-flight run)" >&2
  exit 0
fi
trap 'kb_vec_unlock' EXIT

if bash "$KB_VEC" index; then
  exit 0
else
  rc=$?
  mkdir -p "$KB_STATE_DIR"
  printf '{"ts":"%s","stage":"kb-index","error":"vec index failed rc=%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >> "$ERR_LOG" 2>/dev/null || true
  # Non-fatal: corpus already captured the knowledge; reindex can replay later.
  echo "kb-index: vec index failed (rc=$rc) — corpus intact, run kb-reindex.sh later" >&2
  exit "$rc"
fi
