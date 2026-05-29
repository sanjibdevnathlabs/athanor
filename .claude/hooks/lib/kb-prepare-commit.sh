#!/usr/bin/env bash
# kb-prepare-commit.sh — deterministic manifest pre-processor
# Usage: bash kb-prepare-commit.sh <manifest_path> <output_path>
#
# Takes a raw staging manifest (interleaved kinds, possibly invalid entries),
# sorts it (entities → relations → observations), validates each entry,
# and writes a clean commit-ready manifest.
#
# Pure shell + jq. No LLM. Deterministic. Mirrors the validation the
# kb-write-*.sh wrappers apply at stage time, so the kb-committer agent
# receives clean, sorted, validated input.
#
# Outputs:
#   $OUTPUT            — valid lines, sorted (entities → relations → observations)
#   $OUTPUT.rejected   — invalid lines, each annotated with a `_reject_reason`
#   stdout             — summary: entities=N relations=M observations=K rejected=R
#
# Exit 0: clean manifest written to output_path, commit can proceed
# Exit 1: manifest invalid/empty, or no valid lines survived (nothing to commit)
set -eo pipefail

MANIFEST="$1"
OUTPUT="$2"

# ---------- Resolve repo root + canonical vocabulary paths ----------
# Same resolution as kb-common.sh, but self-contained: this script is a
# pre-processor that may run before the committer sources the library.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  KB_ROOT="$CLAUDE_PROJECT_DIR"
else
  KB_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
VOCAB_DIR="$KB_ROOT/protocol/vocabulary"
RELATIONS_VOCAB="$VOCAB_DIR/relations.txt"

# ---------- Argument + input checks ----------
if [ -z "$MANIFEST" ] || [ -z "$OUTPUT" ]; then
  echo "prepare-commit:error:usage: kb-prepare-commit.sh <manifest_path> <output_path>" >&2
  exit 1
fi

if [ ! -f "$MANIFEST" ]; then
  echo "prepare-commit:error:manifest-not-found:$MANIFEST" >&2
  exit 1
fi

if [ ! -s "$MANIFEST" ]; then
  echo "prepare-commit:error:manifest-empty:$MANIFEST" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "prepare-commit:error:jq-not-found" >&2; exit 1; }

# ---------- Canonical vocabularies ----------
# Valid entity types (v2 universal schema — protocol/schema/entity-types.json).
VALID_ENTITY_TYPES="Concept Finding Procedure Pattern Session"

# Valid predicates: prefer the committed vocabulary file; fall back to the
# frozen v2 relation set if the file is somehow absent.
if [ -f "$RELATIONS_VOCAB" ]; then
  VALID_PREDICATES="$(grep -vE '^\s*(#|$)' "$RELATIONS_VOCAB" 2>/dev/null | tr '\n' ' ')"
else
  VALID_PREDICATES="REFERENCES ADDRESSES OBSERVED_IN RESOLVED_BY INSTANCE_OF RELATED_TO CORRECTED_IN SUPERSEDES DISPUTED_BY"
fi

# Canonical-name pattern (POSIX ERE form of ^[a-z][a-z0-9-]{0,127}$).
NAME_RE='^[a-z][a-z0-9-]{0,127}$'

# Membership helper: is "$1" a space-delimited token in "$2"?
in_list() {
  local needle="$1" haystack="$2"
  case " $haystack " in
    *" $needle "*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- Stage 1: sort by kind (jq slurp) ----------
# Partition the manifest into JSON-valid and JSON-invalid lines first. A single
# malformed line must not abort the whole sort (jq slurp dies on any bad line),
# and malformed lines still need to land in $REJECTED rather than vanish.
SORTED="$OUTPUT.sorted"
VALIDJSON="$OUTPUT.validjson"
BADJSON="$OUTPUT.badjson"
: > "$VALIDJSON"
: > "$BADJSON"
while IFS= read -r _l || [ -n "$_l" ]; do
  [ -z "$_l" ] && continue
  if printf '%s' "$_l" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$_l" >> "$VALIDJSON"
  else
    printf '%s\n' "$_l" >> "$BADJSON"
  fi
done < "$MANIFEST"

# entities=0, relations=1, observations=2, anything else=3 (sorts last; those
# lines fail kind validation below anyway). sort_by is stable, so original
# order is preserved within each kind bucket.
if ! jq -sc 'sort_by(
       if .kind == "entity" then 0
       elif .kind == "relation" then 1
       elif .kind == "observation" then 2
       else 3 end
     )[]' "$VALIDJSON" > "$SORTED" 2>/dev/null; then
  echo "prepare-commit:error:manifest-sort-failed:$MANIFEST" >&2
  rm -f "$SORTED" "$VALIDJSON" "$BADJSON"
  exit 1
fi
rm -f "$VALIDJSON"

# ---------- Stage 2: validate each line ----------
REJECTED="$OUTPUT.rejected"
: > "$OUTPUT"
: > "$REJECTED"

ENTITY_COUNT=0
RELATION_COUNT=0
OBS_COUNT=0
REJECT_COUNT=0

# Emit a rejected line (original JSON + reason) into $REJECTED.
emit_reject() {
  local line="$1" reason="$2"
  REJECT_COUNT=$((REJECT_COUNT + 1))
  # Annotate with reason; if the line isn't valid JSON, wrap it as a raw payload.
  if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$line" | jq -c --arg r "$reason" '. + {_reject_reason: $r}' >> "$REJECTED" 2>/dev/null \
      || printf '{"_reject_reason":"%s","_raw":%s}\n' "$reason" "$(printf '%s' "$line" | jq -Rs .)" >> "$REJECTED"
  else
    printf '{"_reject_reason":"%s","_raw":%s}\n' \
      "$reason" "$(printf '%s' "$line" | jq -Rs . 2>/dev/null || printf '""')" >> "$REJECTED"
  fi
}

# Fold the JSON-invalid lines captured in Stage 1 into the rejected file.
if [ -s "$BADJSON" ]; then
  while IFS= read -r bad || [ -n "$bad" ]; do
    [ -z "$bad" ] && continue
    emit_reject "$bad" "invalid-json"
  done < "$BADJSON"
fi
rm -f "$BADJSON"

# $SORTED contains only JSON-valid lines (Stage 1 partitioned out the rest).
while IFS= read -r line || [ -n "$line" ]; do
  # Skip wholly blank lines silently.
  [ -z "$line" ] && continue

  # Common required fields: id, kind.
  id="$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null)"
  kind="$(printf '%s' "$line" | jq -r '.kind // empty' 2>/dev/null)"
  if [ -z "$id" ]; then
    emit_reject "$line" "missing-id"
    continue
  fi
  if [ -z "$kind" ]; then
    emit_reject "$line" "missing-kind"
    continue
  fi

  case "$kind" in
    entity)
      entity_type="$(printf '%s' "$line" | jq -r '.entity_type // empty' 2>/dev/null)"
      canonical_name="$(printf '%s' "$line" | jq -r '.canonical_name // empty' 2>/dev/null)"
      if [ -z "$entity_type" ]; then
        emit_reject "$line" "entity-missing-entity_type"
        continue
      fi
      if ! in_list "$entity_type" "$VALID_ENTITY_TYPES"; then
        emit_reject "$line" "entity-invalid-type:$entity_type"
        continue
      fi
      if [ -z "$canonical_name" ]; then
        emit_reject "$line" "entity-missing-canonical_name"
        continue
      fi
      # Reject embedded newlines before regex (grep is line-oriented)
      case "$canonical_name" in
        *$'\n'*) emit_reject "$line" "entity-bad-canonical_name:contains-newline"; continue ;;
      esac
      if ! printf '%s' "$canonical_name" | grep -Eqx "$NAME_RE"; then
        emit_reject "$line" "entity-bad-canonical_name:$canonical_name"
        continue
      fi
      printf '%s\n' "$line" >> "$OUTPUT"
      ENTITY_COUNT=$((ENTITY_COUNT + 1))
      ;;

    relation)
      predicate="$(printf '%s' "$line" | jq -r '.predicate // empty' 2>/dev/null)"
      subject_name="$(printf '%s' "$line" | jq -r '.subject_name // empty' 2>/dev/null)"
      object_name="$(printf '%s' "$line" | jq -r '.object_name // empty' 2>/dev/null)"
      if [ -z "$predicate" ]; then
        emit_reject "$line" "relation-missing-predicate"
        continue
      fi
      if ! in_list "$predicate" "$VALID_PREDICATES"; then
        emit_reject "$line" "relation-invalid-predicate:$predicate"
        continue
      fi
      if [ -z "$subject_name" ]; then
        emit_reject "$line" "relation-missing-subject_name"
        continue
      fi
      if [ -z "$object_name" ]; then
        emit_reject "$line" "relation-missing-object_name"
        continue
      fi
      printf '%s\n' "$line" >> "$OUTPUT"
      RELATION_COUNT=$((RELATION_COUNT + 1))
      ;;

    observation)
      entity_name="$(printf '%s' "$line" | jq -r '.entity_name // empty' 2>/dev/null)"
      observation="$(printf '%s' "$line" | jq -r '.observation // empty' 2>/dev/null)"
      evidence_snippet="$(printf '%s' "$line" | jq -r '.evidence_snippet // empty' 2>/dev/null)"
      if [ -z "$entity_name" ]; then
        emit_reject "$line" "observation-missing-entity_name"
        continue
      fi
      # Provenance gate: evidence_snippet must be >= 20 chars (citation minimum).
      #
      # 5-vs-20 mismatch: the stage-time wrapper kb-write-observation.sh
      # historically accepted evidence_snippet >= 5 chars, but this commit-time
      # gate requires >= 20. A staged observation with 5–19 chars of evidence
      # would pass staging then be silently DROPPED here. The wrapper minimum has
      # been RAISED to 20 to match this gate (see kb-write-observation.sh), so the
      # two stages are now consistent. This check is the authoritative gate.
      ev_len="${#evidence_snippet}"
      if [ "$ev_len" -lt 20 ]; then
        emit_reject "$line" "observation-evidence-too-short:${ev_len}<20"
        continue
      fi
      printf '%s\n' "$line" >> "$OUTPUT"
      OBS_COUNT=$((OBS_COUNT + 1))
      ;;

    *)
      emit_reject "$line" "unknown-kind:$kind"
      ;;
  esac
done < "$SORTED"

# Sorted intermediate no longer needed.
rm -f "$SORTED"

# Drop an empty rejected file to avoid leaving noise behind.
[ -s "$REJECTED" ] || rm -f "$REJECTED"

# ---------- Stage 3: summary + return code ----------
printf 'entities=%d relations=%d observations=%d rejected=%d\n' \
  "$ENTITY_COUNT" "$RELATION_COUNT" "$OBS_COUNT" "$REJECT_COUNT"

VALID_TOTAL=$((ENTITY_COUNT + RELATION_COUNT + OBS_COUNT))
if [ "$VALID_TOTAL" -eq 0 ]; then
  # No valid lines survived — nothing to commit. Remove the empty output so the
  # caller's `-s` check on the prepared manifest fails cleanly.
  rm -f "$OUTPUT"
  echo "prepare-commit:error:no-valid-lines" >&2
  exit 1
fi

exit 0
