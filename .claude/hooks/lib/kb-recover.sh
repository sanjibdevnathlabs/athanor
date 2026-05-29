#!/usr/bin/env bash
# Recover a quarantined session by moving its manifest back to staging and re-triggering the committer.
# Usage: bash kb-recover.sh <session_id> [--with-feedback <feedback_file>]
# Returns: ok:<sid> on success, error:<reason> on failure
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo ".")"
source "$ROOT/.claude/hooks/lib/kb-common.sh"

SESSION_ID="${1:-}"
FEEDBACK_FILE="${3:-}"  # optional --with-feedback <file>

[ -z "$SESSION_ID" ] && { echo "error:missing-session-id"; exit 1; }

QUAR_BASE="$ROOT/.athanor/_quarantine"
STAGING="$ROOT/.athanor/_staging/$SESSION_ID"
STATE="$ROOT/.athanor/_state"

# Find the quarantine directory for this session
QUAR_DIR=$(ls -d "$QUAR_BASE/${SESSION_ID}"* 2>/dev/null | head -1 || true)
[ -z "$QUAR_DIR" ] && { echo "error:no-quarantine-found:$SESSION_ID"; exit 1; }

QUAR_MANIFEST="$QUAR_DIR/manifest.jsonl"
[ ! -f "$QUAR_MANIFEST" ] && { echo "error:no-manifest-in-quarantine:$QUAR_DIR"; exit 1; }

# Validate the quarantined manifest via prepare-commit
PREPARED_OUT="$QUAR_DIR/manifest-prepared.jsonl"
if ! bash "$ROOT/.claude/hooks/lib/kb-prepare-commit.sh" "$QUAR_MANIFEST" "$PREPARED_OUT"; then
  echo "error:manifest-validation-failed:see-$QUAR_DIR"
  exit 1
fi

# Move back to staging
mkdir -p "$STAGING"
cp "$QUAR_MANIFEST" "$STAGING/manifest.jsonl"
cp "$PREPARED_OUT" "$STAGING/manifest-prepared.jsonl"

# Inject feedback if provided
if [ -n "$FEEDBACK_FILE" ] && [ -f "$FEEDBACK_FILE" ]; then
  cp "$FEEDBACK_FILE" "$STAGING/.revise-feedback.md"
fi

# Reset the attempt counter so this recovery doesn't count as a retry
PENDING_FILE="$STATE/distill-pending.jsonl"
grep -v "\"session_id\":\"$SESSION_ID\"" "$PENDING_FILE" > "${PENDING_FILE}.tmp" \
  && mv "${PENDING_FILE}.tmp" "$PENDING_FILE" || true

# Add a fresh pending entry at attempts=0
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
printf '{"session_id":"%s","ts":"%s","attempts":0,"reason":"manual-recovery"}\n' \
  "$SESSION_ID" "$TS" >> "$PENDING_FILE"

# Archive the quarantine dir (don't delete — keep as audit trail)
mv "$QUAR_DIR" "${QUAR_DIR}-recovered-${TS//:/}" 2>/dev/null || true

echo "ok:$SESSION_ID"
