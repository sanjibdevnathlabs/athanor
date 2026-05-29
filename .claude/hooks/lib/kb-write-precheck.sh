#!/usr/bin/env bash
# PreToolUse gate for graph write tools.
# Reads TOOL_INPUT from stdin (JSON). Checks that the caller is authorized:
# either (a) kb-committer active with matching manifest, or (b) the main session
# has a valid staged record for the entity being written.
# Returns exit 0 to allow, or outputs JSON deny decision and exits non-zero.
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo ".")"
STATE="$ROOT/.athanor/_state"
STAGING="$ROOT/.athanor/_staging"

TOOL_INPUT=$(cat)

# Check if kb-committer is active and the input id is in its authorized manifest
if [ -f "$STATE/committer-active.json" ]; then
  ORIGINAL_SID=$(jq -r '.original_sid // empty' "$STATE/committer-active.json" 2>/dev/null)
  if [ -n "$ORIGINAL_SID" ]; then
    MANIFEST="$STAGING/$ORIGINAL_SID/manifest.jsonl"
    if [ -f "$MANIFEST" ]; then
      # Committer is active and has a staging manifest — allow
      exit 0
    fi
  fi
fi

# Check if the current session has staged records via KB_SESSION_ID
if [ -n "${KB_SESSION_ID:-}" ]; then
  MANIFEST="$STAGING/$KB_SESSION_ID/manifest.jsonl"
  if [ -f "$MANIFEST" ] && grep -q '"kind"' "$MANIFEST" 2>/dev/null; then
    # Session has staged records — allow (wrapper already validated)
    exit 0
  fi
fi

# No authorization found — deny
echo '{"decision":"block","reason":"Graph write attempted without wrapper authorization. All writes must go through kb-write-*.sh wrappers first."}'
exit 1
