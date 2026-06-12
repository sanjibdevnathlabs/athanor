#!/usr/bin/env bash
# kb-reindex.sh — replay the corpus into the vector DB (migration / disaster recovery).
#
# The corpus (.athanor/corpus/*.ndjson) is the DB-independent source of truth.
# This script rebuilds the searchable index from it. Use it when:
#   - the vector DB was down / corrupted / wiped
#   - you switched VEC_DRIVER (e.g. qdrant -> chromadb)
#   - you changed VEC_EMBED_MODEL (re-embed everything)
#   - first-time bootstrap of a fresh collection
#
# Usage:
#   bash .claude/hooks/lib/kb-reindex.sh              # incremental replay (upsert latest per doc)
#   bash .claude/hooks/lib/kb-reindex.sh --rebuild    # build a fresh collection + atomic alias swap
#   bash .claude/hooks/lib/kb-reindex.sh --backfill   # scan disk -> corpus, then replay
#   bash .claude/hooks/lib/kb-reindex.sh --prune      # drop orphan backing collections only
#
# --rebuild is SAFE: it builds a brand-new physical collection, populates it, then
# atomically repoints the live alias and drops the old one. The live collection is
# never dropped, so a killed/concurrent rebuild cannot wedge readers. Runs under a
# single-flight lock (serialised with kb-index.sh). Run it in the FOREGROUND — do
# not background it.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"

REBUILD=""
DO_BACKFILL=0
PRUNE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --rebuild)  REBUILD="--rebuild" ;;
    --backfill) DO_BACKFILL=1 ;;
    --prune)    PRUNE_ONLY=1 ;;
    *) echo "kb-reindex.sh: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

if ! kb_vec_lock wait; then
  echo "kb-reindex: another vec write is in progress — try again shortly" >&2
  exit 1
fi
trap 'kb_vec_unlock' EXIT

if [ "$PRUNE_ONLY" -eq 1 ]; then
  bash "$KB_VEC" prune
  exit $?
fi

if [ "$DO_BACKFILL" -eq 1 ]; then
  bash "$KB_VEC" backfill
fi

bash "$KB_VEC" reindex $REBUILD
