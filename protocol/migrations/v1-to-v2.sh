#!/usr/bin/env bash
# Protocol migration: v1 (oncall-specific) → v2 (universal second brain)
#
# This script is idempotent. It checks whether the v1→v2 migration has already
# been applied and reports status. On a fresh install, v2 is already the baseline.
#
# Changes in v2:
#   Entity types:  Service, Symptom, Runbook, Skill, Incident, MCPPattern
#                  → Concept, Finding, Procedure, Pattern, Session
#   Relations:     Old oncall-specific predicates
#                  → 9 universal predicates (REFERENCES, ADDRESSES, OBSERVED_IN,
#                    RESOLVED_BY, INSTANCE_OF, RELATED_TO, CORRECTED_IN,
#                    SUPERSEDES, DISPUTED_BY)
#   Vocabulary:    Removed: services.txt, symptom-categories.txt, mcp-patterns.txt
#                  Added:   entity-types.txt, relations.txt, confidence-tiers.txt,
#                           session-outcomes.txt
#
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo ".")"
VOCAB="$ROOT/protocol/vocabulary"
VERSION_FILE="$ROOT/protocol/version.txt"
LOG="$ROOT/.athanor/_state/protocol-migration-v1-to-v2.log"

mkdir -p "$(dirname "$LOG")"
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

log() { echo "[$TS] $*" | tee -a "$LOG"; }

log "Starting v1→v2 migration check"

# --- Check 1: Version already v2? ---
CURRENT_VERSION=$(cat "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
if [ "$CURRENT_VERSION" = "v2" ]; then
  log "Already on v2 — migration already applied or not needed."
fi

# --- Check 2: Deprecated v1 vocab files should be absent ---
DEPRECATED_FILES="services.txt symptom-categories.txt mcp-patterns.txt"
DEPRECATED_FOUND=0
for f in $DEPRECATED_FILES; do
  if [ -f "$VOCAB/$f" ]; then
    log "WARNING: deprecated v1 vocab file still present: $VOCAB/$f"
    DEPRECATED_FOUND=1
  fi
done
if [ "$DEPRECATED_FOUND" -eq 0 ]; then
  log "✓ No deprecated v1 vocabulary files found."
fi

# --- Check 3: Required v2 vocab files present ---
REQUIRED_FILES="entity-types.txt relations.txt confidence-tiers.txt session-outcomes.txt"
MISSING=0
for f in $REQUIRED_FILES; do
  if [ ! -f "$VOCAB/$f" ]; then
    log "ERROR: required v2 vocabulary file missing: $VOCAB/$f"
    MISSING=1
  fi
done
if [ "$MISSING" -eq 0 ]; then
  log "✓ All required v2 vocabulary files present."
fi

# --- Check 4: entity-types.txt contains only v2 types ---
V2_TYPES="Concept Finding Procedure Pattern Session"
for t in $V2_TYPES; do
  if ! grep -qxF "$t" "$VOCAB/entity-types.txt" 2>/dev/null; then
    log "WARNING: v2 entity type '$t' not found in entity-types.txt"
  fi
done

# --- Check 5: Neo4j graph (optional — requires MCP connection) ---
# Cannot run from shell directly — graph migration of existing v1 entities
# must be done manually or via the kb-auditor agent if v1 entities are found.
log "NOTE: Graph entity migration (v1 type rename) requires running /athanor audit."
log "      If no v1 entities exist in Neo4j, migration is complete."

# --- Summary ---
if [ "$DEPRECATED_FOUND" -eq 0 ] && [ "$MISSING" -eq 0 ]; then
  log "Migration v1→v2: COMPLETE"
  echo "ok:v2"
  exit 0
else
  log "Migration v1→v2: INCOMPLETE — see log at $LOG"
  echo "error:migration-incomplete"
  exit 1
fi
