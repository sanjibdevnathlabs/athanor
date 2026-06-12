#!/usr/bin/env bash
# kb-validate.sh — sanity check the KB state. Run on demand or from /athanor validate.
# Reports: vocabulary file presence, schema parse, staging count, audit log size, recent rejections.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"

ok=0
fail=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ✓ %s\n' "$desc"
    ok=$((ok+1))
  else
    printf '  ✗ %s\n' "$desc"
    fail=$((fail+1))
  fi
}

echo "KB validation — protocol v$(cat "$KB_PROTOCOL_DIR/version.txt" 2>/dev/null || echo '?')"
echo

echo "Files:"
check "version.txt"             test -f "$KB_PROTOCOL_DIR/version.txt"
check "PROTOCOL.md"             test -f "$KB_PROTOCOL_DIR/PROTOCOL.md"
check "schema/entity-types.json valid JSON" jq -e . "$KB_SCHEMA_DIR/entity-types.json"
check "schema/relation-types.json valid JSON" jq -e . "$KB_SCHEMA_DIR/relation-types.json"
check "schema/observation-types.json valid JSON" jq -e . "$KB_SCHEMA_DIR/observation-types.json"
check "schema/relation-envelope.json valid JSON" jq -e . "$KB_SCHEMA_DIR/relation-envelope.json"
check "vocabulary/entity-types.txt"     test -f "$KB_VOCAB_DIR/entity-types.txt"
check "vocabulary/relations.txt"        test -f "$KB_VOCAB_DIR/relations.txt"
check "vocabulary/confidence-tiers.txt" test -f "$KB_VOCAB_DIR/confidence-tiers.txt"
check "vocabulary/session-outcomes.txt" test -f "$KB_VOCAB_DIR/session-outcomes.txt"
check "vector.config"            test -f "$KB_PROTOCOL_DIR/vector.config"
check "vec package (cli.py)"     test -f "$KB_ROOT/.claude/hooks/lib/vec/cli.py"
check "vec.sh dispatcher"        test -f "$KB_VEC"
check "recall-algorithm.md"      test -f "$KB_PROTOCOL_DIR/recall-algorithm.md"

# Vocabulary files must be non-empty (≥1 non-comment, non-blank line).
vocab_nonempty() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | grep -q .
}
check "vocabulary/entity-types.txt non-empty"      vocab_nonempty "$KB_VOCAB_DIR/entity-types.txt"
check "vocabulary/relations.txt non-empty"         vocab_nonempty "$KB_VOCAB_DIR/relations.txt"
check "vocabulary/confidence-tiers.txt non-empty"  vocab_nonempty "$KB_VOCAB_DIR/confidence-tiers.txt"
check "vocabulary/session-outcomes.txt non-empty"  vocab_nonempty "$KB_VOCAB_DIR/session-outcomes.txt"

# Vocab ↔ schema predicate invariant: relations.txt (the 9 v2 predicates) must
# exactly match the predicate field values in schema/relation-types.json (set
# equality). Both sides must be: REFERENCES, ADDRESSES, OBSERVED_IN, RESOLVED_BY,
# INSTANCE_OF, RELATED_TO, CORRECTED_IN, SUPERSEDES, DISPUTED_BY.
vocab_schema_predicates_match() {
  local vocab_p schema_p
  vocab_p="$(grep -vE '^[[:space:]]*(#|$)' "$KB_VOCAB_DIR/relations.txt" 2>/dev/null \
    | tr -d ' \t' | sort -u)"
  schema_p="$(jq -r '.relations[].predicate' "$KB_SCHEMA_DIR/relation-types.json" 2>/dev/null \
    | sort -u)"
  [ -n "$vocab_p" ] && [ "$vocab_p" = "$schema_p" ]
}
if vocab_schema_predicates_match; then
  printf '  ✓ %s\n' "vocab/schema predicates match"
  ok=$((ok+1))
else
  vp="$(grep -vE '^[[:space:]]*(#|$)' "$KB_VOCAB_DIR/relations.txt" 2>/dev/null | tr -d ' \t' | sort -u)"
  sp="$(jq -r '.relations[].predicate' "$KB_SCHEMA_DIR/relation-types.json" 2>/dev/null | sort -u)"
  diff_only="$(comm -3 <(printf '%s\n' "$vp") <(printf '%s\n' "$sp") 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')"
  printf '  ✗ vocab/schema predicate mismatch: %s\n' "${diff_only:-unknown}"
  fail=$((fail+1))
fi

echo
echo "State:"
SESSION_COUNT="$(wc -l < "$KB_STATE_DIR/session-ledger.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"
WRITES_COUNT="$(wc -l < "$KB_STATE_DIR/kb-writes.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"
HITL_COUNT="$(wc -l < "$KB_STATE_DIR/hitl-queue.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"
DISTILLED_COUNT="$(find "$KB_ROOT/.athanor/distilled/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
RUNBOOK_COUNT="$(find "$KB_ROOT/.athanor/runbooks" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
SKILL_COUNT="$(find "$KB_ROOT/.athanor/local-skills" -type d -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
echo "  sessions:   $SESSION_COUNT"
echo "  kb writes:  $WRITES_COUNT"
echo "  hitl queue: $HITL_COUNT"
echo "  digests:    $DISTILLED_COUNT"
echo "  runbooks:   $RUNBOOK_COUNT"
echo "  skills:     $SKILL_COUNT"
CORPUS_DOCS="$(find "$KB_CORPUS_DIR" -maxdepth 1 -name '*.ndjson' -type f -exec cat {} + 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
echo "  corpus recs:$CORPUS_DOCS"
if [ -f "$KB_STATE_DIR/embeddings.lock" ]; then
  LOCK_MODEL="$(jq -r '.embedding_model // "?"' "$KB_STATE_DIR/embeddings.lock" 2>/dev/null)"
  LOCK_DIM="$(jq -r '.embedding_dim // "?"' "$KB_STATE_DIR/embeddings.lock" 2>/dev/null)"
  echo "  vec lock:   $LOCK_MODEL (dim $LOCK_DIM)"
else
  echo "  vec lock:   (none — collection not built yet; run kb-reindex.sh --rebuild)"
fi

echo
printf 'Result: %d ok, %d fail\n' "$ok" "$fail"
[ $fail -eq 0 ]
