#!/usr/bin/env bash
# post-tool-use.sh — PostToolUse hook entry point.
# Forwards to bypass-detector for the work. Soft-fail.

set -uo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
ERR="$ROOT/.athanor/_state/hook-errors.jsonl"

trap 'printf "{\"ts\":\"%s\",\"hook\":\"post-tool-use\",\"err\":\"trap\"}\n" "$(date -u +%FT%TZ)" >> "$ERR" 2>/dev/null; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
printf '%s' "$INPUT" | bash "$ROOT/.claude/hooks/lib/bypass-detector.sh" 2>/dev/null || true

exit 0
