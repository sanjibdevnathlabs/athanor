#!/usr/bin/env bash
# provenance-attach.sh — enrich a staged record with full provenance metadata
# before it gets committed to the KB.
#
# Adds fields:
#   created_under_protocol  ← from version.txt
#   created_by_distiller_version  ← from agent file mtime hash (best-effort)
#   supervised_by_version
#   supervisor_approved     (bool)
#   audit_evidence_hash     ← sha256 of evidence_snippet (8 chars)
#
# Usage:
#   echo '<record-json>' | bash provenance-attach.sh
#   Output: enriched JSON on stdout.
#
# This is a P2 layer that runs between supervisor approve and Neo4j commit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"

INPUT="${1:-$(cat)}"
[ -z "$INPUT" ] && { echo "no-input" >&2; exit 1; }

PROTO_VERSION="$(cat "$KB_PROTOCOL_DIR/version.txt" 2>/dev/null || echo v1)"
DISTILLER_FILE="$KB_ROOT/.claude/agents/session-distiller.md"
SUPERVISOR_FILE="$KB_ROOT/.claude/agents/distillation-supervisor.md"

distiller_v="$(stat -f %Sm -t %Y%m%d "$DISTILLER_FILE" 2>/dev/null || stat -c %Y "$DISTILLER_FILE" 2>/dev/null || echo unknown)"
supervisor_v="$(stat -f %Sm -t %Y%m%d "$SUPERVISOR_FILE" 2>/dev/null || stat -c %Y "$SUPERVISOR_FILE" 2>/dev/null || echo unknown)"

# Compute evidence hash if there's an evidence_snippet
evidence_hash="$(printf '%s' "$INPUT" | jq -r '.evidence_snippet // empty' | { read -r e; if [ -n "$e" ]; then printf '%s' "$e" | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-8; fi; })"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Enrich
printf '%s' "$INPUT" | jq -c \
  --arg pv "$PROTO_VERSION" \
  --arg dv "$distiller_v" \
  --arg sv "$supervisor_v" \
  --arg eh "$evidence_hash" \
  --arg ts "$NOW" \
  '. + {
    created_under_protocol: $pv,
    created_by_distiller_version: $dv,
    supervised_by_version: $sv,
    supervisor_approved: true,
    audit_evidence_hash: ($eh|select(. != "")),
    provenance_attached_at: $ts
  } | with_entries(select(.value != null))'
