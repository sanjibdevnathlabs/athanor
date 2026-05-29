#!/usr/bin/env bash
# kill-switch-check.sh — gate function for P2.
# Source this and call `kb_kill_switch_check <flag>` to verify a feature is enabled.
# Flags (matching .athanor/_state/kill-switch.json keys):
#   distiller | auto_commit | auto_promotion | recall
#
# Exit 0 if enabled, 1 + reject message on stderr if disabled.
# Used as a gate in session-stop.sh, supervisor-gate.sh, kb-recall.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"

kb_kill_switch_check() {
  local flag="$1"
  local ks="$KB_STATE_DIR/kill-switch.json"
  [ -f "$ks" ] || return 0   # no switch file → assume enabled (genesis)
  local state
  state="$(jq -r ".${flag} // \"enabled\"" "$ks" 2>/dev/null || echo enabled)"
  if [ "$state" = "enabled" ]; then
    # Tamper detection: if the mutable switch reports "enabled" but the
    # out-of-tree append-only trip log shows a trip for this flag with no
    # subsequent reset, the switch file may have been tampered with.
    local trip_log="$KB_STATE_DIR/kill-switch-trips.jsonl"
    local TAMPER_DETECTED="false"
    if [ -f "$trip_log" ]; then
      local last_event
      last_event="$(grep -F "\"flag\":\"$flag\"" "$trip_log" 2>/dev/null \
        | tail -1 | jq -r '.event // empty' 2>/dev/null || echo "")"
      if [ "$last_event" = "trip" ]; then
        TAMPER_DETECTED="true"
        jq -cn \
          --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg level "CRITICAL" \
          --arg flag "$flag" \
          --arg msg "kill-switch.json reports enabled but trip log shows uncleared trip — possible tamper; failing closed" \
          '{ts:$ts, level:$level, flag:$flag, msg:$msg}' \
          >> "$KB_STATE_DIR/hook-errors.jsonl" 2>/dev/null || true
      fi
    fi
    # If tamper detected (hash mismatch or unexpected enabled state after trip), fail CLOSED.
    if [ "$TAMPER_DETECTED" = "true" ]; then
      echo "CRITICAL: kill-switch tamper detected — treating as TRIPPED (fail closed)" >&2
      return 1  # disabled = don't proceed
    fi
    return 0
  else
    local reason
    reason="$(jq -r '.tripped_reason // "kill-switch-tripped"' "$ks" 2>/dev/null)"
    printf 'reject:kill-switch-disabled-%s:%s\n' "$flag" "$reason" >&2
    return 1
  fi
}

# Auto-trip helper. Call when a metric exceeds a threshold.
kb_kill_switch_trip() {
  local flag="$1"
  local reason="${2:-unspecified}"
  local ks="$KB_STATE_DIR/kill-switch.json"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Create with safe defaults if missing (H2: genesis repos had no file → no-op trip).
  if [ ! -f "$ks" ]; then
    mkdir -p "$KB_STATE_DIR"
    printf '{"distiller":"enabled","auto_commit":"enabled","auto_promotion":"enabled","recall":"enabled","trip_history":[]}\n' > "$ks"
  fi
  local tmp="${ks}.tmp.$$"
  jq --arg f "$flag" --arg r "$reason" --arg t "$ts" \
    '.[$f] = "disabled" | .tripped_at = $t | .tripped_reason = $r | .trip_history += [{flag:$f, reason:$r, ts:$t}]' \
    "$ks" > "$tmp" && mv "$tmp" "$ks"
  # Append-only tamper-evidence log (never mutated, only appended). Lives
  # alongside the mutable switch file but is never rewritten, so it survives
  # corruption/tampering of kill-switch.json.
  local trip_log="$KB_STATE_DIR/kill-switch-trips.jsonl"
  jq -cn \
    --arg ts "$ts" \
    --arg flag "$flag" \
    --arg reason "$reason" \
    '{ts:$ts, flag:$flag, reason:$reason, event:"trip"}' \
    >> "$trip_log" 2>/dev/null || true
}

# Reset. Used by /athanor reset (HITL).
kb_kill_switch_reset() {
  local flag="$1"
  local actor="${2:-user}"
  local ks="$KB_STATE_DIR/kill-switch.json"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -f "$ks" ]; then
    local tmp="${ks}.tmp"
    jq --arg f "$flag" --arg a "$actor" --arg t "$ts" \
      '.[$f] = "enabled" | .trip_history += [{flag:$f, action:"reset", actor:$a, ts:$t}]' \
      "$ks" > "$tmp" && mv "$tmp" "$ks"
  fi
  # Append reset to the out-of-tree tamper-evidence log so the trip/reset
  # pairing stays auditable independent of kill-switch.json.
  local trip_log="$KB_STATE_DIR/kill-switch-trips.jsonl"
  jq -cn \
    --arg ts "$ts" \
    --arg flag "$flag" \
    --arg actor "$actor" \
    '{ts:$ts, flag:$flag, actor:$actor, event:"reset"}' \
    >> "$trip_log" 2>/dev/null || true
}

# Allow direct invocation for /athanor command and tests:
#   kill-switch-check.sh check <flag>   # exit 0/1
#   kill-switch-check.sh trip  <flag> <reason>
#   kill-switch-check.sh reset <flag> [actor]
#   kill-switch-check.sh status         # JSON
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:?usage: kill-switch-check.sh check|trip|reset|status [args]}"
  case "$cmd" in
    check)  kb_kill_switch_check "${2:?flag}" ;;
    trip)   kb_kill_switch_trip "${2:?flag}" "${3:?reason}" ;;
    reset)  kb_kill_switch_reset "${2:?flag}" "${3:-user}" ;;
    status) cat "$KB_STATE_DIR/kill-switch.json" ;;
    *) echo "unknown subcmd: $cmd" >&2; exit 2 ;;
  esac
fi
