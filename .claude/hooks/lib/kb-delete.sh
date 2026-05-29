#!/usr/bin/env bash
# Sanctioned delete wrapper for Neo4j graph entities.
# Sets KB_WRAPPER=1 so bypass-detector authorizes the delete.
# Usage: echo '{"entity_name":"foo","entity_type":"Concept","source_session_id":"...","reason":"..."}' | bash kb-delete.sh
set -euo pipefail

export KB_WRAPPER=1

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo ".")"
source "$ROOT/.claude/hooks/lib/kb-common.sh"

INPUT=$(cat)
ENTITY_NAME=$(printf '%s' "$INPUT" | jq -r '.entity_name // empty')
ENTITY_TYPE=$(printf '%s' "$INPUT" | jq -r '.entity_type // empty')
REASON=$(printf '%s' "$INPUT" | jq -r '.reason // "supervisor-reject"')
SOURCE_SID=$(printf '%s' "$INPUT" | jq -r '.source_session_id // "unknown"')

if [ -z "$ENTITY_NAME" ] || [ -z "$ENTITY_TYPE" ]; then
  echo "reject:missing-required-fields"
  exit 1
fi

# Log the sanctioned delete
kb_audit "sanctioned-delete" "$INPUT"

# Return the delete command for the agent to execute
echo "ok:sanctioned-delete:entity_name=$ENTITY_NAME"
