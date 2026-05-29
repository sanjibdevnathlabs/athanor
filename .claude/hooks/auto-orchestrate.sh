#!/usr/bin/env bash
# auto-orchestrate.sh — runs on UserPromptSubmit.
# Detects intent in the user prompt and silently injects retrieval plan
# as additionalContext. Conservative: prefer false-negatives over noise.
#
# Output to stdout becomes additionalContext for the agent. Keep tight.

set -uo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE="$ROOT/.athanor/_state"
ERR_LOG="$STATE/hook-errors.jsonl"

INPUT="$(cat 2>/dev/null || true)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null || true)"
[ -z "$PROMPT" ] && exit 0

# Lowercase for matching
P_LOWER="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')"

# Detect investigation or learning intent across any domain (domain-agnostic).
# Broadened from the original oncall-specific set to also catch research,
# code debugging, product/feature issues, and data-analysis prompts. Any
# investigative or analytical session should recall prior knowledge.
IS_INVESTIGATION=false
if echo "$P_LOWER" | grep -qiE \
  '\b(investigat|debug|diagnos|troubleshoot|analyz|analyse|understand|explore|research)\b|\b(why|how does|what is|what.*wrong|what.*happening|what.*causing)\b|\b(error|errors|fail|fails|failing|failed|broken|wrong|issue|problem|trouble|bug|crash|exception)\b|\b(slow|timeout|not working|not responding|not starting|hang|stuck|stalled|incorrect|unexpected)\b|\b(not (working|loading|showing|running|connecting|responding|completing))\b|\b(5xx|4xx|p99|p95|latency|performance|memory|cpu|leak)\b|\b(draft|write|rewrite|edit|review|summari[sz]e|compare|plan|design|scope|outline|continue|build|create|compile|synthesi[sz]e|evaluate|assess|decide)\b|\b(last time|previously|we (found|decided|discussed)|status of|continue|pick up|where (did|were) we|have we (seen|done|tried))\b|\b[45][0-9]{2}\b|\boom\b|oomkill|\b(throughput|queue (is|backing)|disk (full|usage)|connection refused|degraded|regress)\b'; then
  IS_INVESTIGATION=true
fi

# Detect explicit capture intent
IS_CAPTURE=0
echo "$P_LOWER" | grep -qE '\b(remember|note that|important to know|for future reference|key insight|capture this)\b' \
  && IS_CAPTURE=1

# Decide
if [ "$IS_INVESTIGATION" = false ] && [ "$IS_CAPTURE" -eq 0 ]; then
  exit 0  # nothing to do
fi

# Emit orchestration directives as additionalContext
{
  if [ "$IS_INVESTIGATION" = true ]; then
    RECALL_PLAN="$("$ROOT/.claude/hooks/lib/kb-recall.sh" "$P_LOWER" 2>/dev/null || echo '{"note":"recall-plan-unavailable"}')"
    printf '\n## Athanor: Prior Knowledge Recall — MANDATORY FIRST ACTION\n'
    printf 'Before responding, execute this recall plan and surface relevant past findings inline:\n'
    printf '%s\n' "$RECALL_PLAN"
    printf '\nIf the plan returns results, lead your response with: "From past sessions: [key finding]"\n'
    printf 'If no relevant results, proceed normally.\n'
  fi
  if [ "$IS_CAPTURE" -eq 1 ]; then
    printf '\n[athanor auto-orchestrate] Capture intent detected. Use kb-write-* wrappers per athanor-protocol skill before any mcp__knowledge-graph__* call.\n'
  fi
} 2>/dev/null

exit 0
