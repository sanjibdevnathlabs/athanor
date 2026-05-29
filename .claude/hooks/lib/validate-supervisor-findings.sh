#!/usr/bin/env bash
# validate-supervisor-findings.sh — verify each supervisor finding's evidence
# is grounded in either the manifest or the transcript. Demote / discard
# findings whose evidence_snippet can't be found.
#
# Usage:
#   bash validate-supervisor-findings.sh <decision-json> <manifest-jsonl> <transcript-jsonl>
#
# Mutates the decision-json IN PLACE. Adds:
#   - For each finding: validator_status ∈ {verified, demoted, discarded}
#   - Top-level: validator_summary {verified: n, demoted: n, discarded: n}
#
# Output to stdout: one of
#   ok
#   demoted:<n>
#   discarded:<n>
#   all-high-discarded
#
# Exit codes:
#   0 — ok or some findings demoted/discarded but at least one high-severity finding survived
#   1 — usage / file error
#   2 — all high-severity findings were unverifiable (discarded); escalation required.
#       Caller (session-stop.sh supervisor pipeline) MUST route to HITL instead of approving.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kb-common.sh
. "$SCRIPT_DIR/kb-common.sh"

DECISION="${1:?usage: validate-supervisor-findings.sh <decision-json> <manifest> <transcript>}"
MANIFEST="${2:?manifest path}"
TRANSCRIPT="${3:?transcript path}"

[ -f "$DECISION" ] || { echo "reject:no-decision-file" >&2; exit 1; }
jq -e . "$DECISION" >/dev/null 2>&1 || { echo "reject:decision-not-json" >&2; exit 1; }

verified=0
demoted=0
discarded=0
total=0

# Load text once
manifest_text=""
transcript_text=""
[ -f "$MANIFEST" ] && manifest_text="$(cat "$MANIFEST")"
[ -f "$TRANSCRIPT" ] && transcript_text="$(cat "$TRANSCRIPT")"

# Process each finding (forward + adversarial). Annotate with validator_status.
# We rebuild the finding arrays with status, and update top-level summary.

annotate() {
  local arr_path="$1"  # e.g. .forward_findings
  local len
  len=$(jq -r "$arr_path | length" "$DECISION" 2>/dev/null || echo 0)
  local i
  for ((i=0; i<len; i++)); do
    local finding
    finding=$(jq -c "${arr_path}[$i]" "$DECISION")
    [ "$finding" = "null" ] && continue
    total=$((total+1))

    local axis severity manifest_line t_start t_end evidence claim
    axis=$(jq -r '.axis // ""' <<<"$finding")
    severity=$(jq -r '.severity // "low"' <<<"$finding")
    manifest_line=$(jq -r '.manifest_line // -1' <<<"$finding")
    t_start=$(jq -r '.transcript_line_range[0] // -1' <<<"$finding" 2>/dev/null || echo -1)
    t_end=$(jq -r '.transcript_line_range[1] // -1' <<<"$finding" 2>/dev/null || echo -1)
    evidence=$(jq -r '.evidence_snippet // ""' <<<"$finding")
    claim=$(jq -r '.claim // ""' <<<"$finding")

    local status="verified"

    # Normalize evidence: collapse newlines to spaces so multi-line snippets
    # can match against line-by-line grep, and squeeze repeated spaces.
    local evidence_clean
    evidence_clean=$(echo "$evidence" | tr '\n' ' ' | sed 's/  */ /g')

    # Length check (raise floor to 20 chars — short snippets match trivially)
    if [ ${#evidence} -lt 20 ]; then
      status="discarded"
    fi

    # Evidence verification: must appear verbatim in manifest OR transcript
    # Skip if "absence" finding (manifest_line == -1 AND t_start == -1)
    if [ "$status" = "verified" ]; then
      if [ "$manifest_line" -ne -1 ] || [ "$t_start" -ne -1 ]; then
        # Search for substring (escape special chars by using fgrep)
        local found=0
        if [ -n "$manifest_text" ] && printf '%s' "$manifest_text" | grep -qF -- "$evidence_clean"; then
          found=1
        fi
        if [ "$found" -eq 0 ] && [ -n "$transcript_text" ]; then
          # If the finding carries a non-zero transcript line range, scope the
          # grep to those lines. Otherwise fall back to full-file grep.
          if [ "$t_start" -gt 0 ] && [ "$t_end" -gt 0 ]; then
            if sed -n "${t_start},${t_end}p" "$TRANSCRIPT" | grep -qF -- "$evidence_clean"; then
              found=1
            fi
          elif printf '%s' "$transcript_text" | grep -qF -- "$evidence_clean"; then
            found=1
          fi
        fi
        if [ "$found" -eq 0 ]; then
          status="discarded"
        fi
      fi
    fi

    # Vocab-claim check: if axis is vocab_discipline AND claim mentions a term
    # being "in vocabulary" or "not in vocabulary", verify the claim.
    if [ "$status" = "verified" ] && [ "$axis" = "vocab_discipline" ]; then
      # Heuristic: extract any quoted term, check against services.txt et al.
      local quoted_term
      quoted_term=$(printf '%s' "$claim" | grep -oE "'[a-z][a-z0-9-]+'" | head -1 | tr -d "'" || true)
      if [ -n "$quoted_term" ]; then
        local in_any_vocab=0
        for vf in "$KB_VOCAB_DIR"/*.txt; do
          [ -f "$vf" ] && grep -qE "^$quoted_term\$" "$vf" 2>/dev/null && in_any_vocab=1 && break
        done
        # If supervisor's claim contradicts reality, demote
        if printf '%s' "$claim" | grep -qiE "(should be|expected) in vocab"; then
          [ "$in_any_vocab" -eq 0 ] && status="demoted"
        fi
        if printf '%s' "$claim" | grep -qiE "not in vocab"; then
          [ "$in_any_vocab" -eq 1 ] && status="demoted"
        fi
      fi
    fi

    case "$status" in
      verified)  verified=$((verified+1)) ;;
      demoted)   demoted=$((demoted+1)) ;;
      discarded) discarded=$((discarded+1)) ;;
    esac

    # Patch the finding with validator_status (and downgrade severity on demote)
    local jqf=".${arr_path#.}[$i] |= (. + {validator_status: \"$status\"}"
    if [ "$status" = "demoted" ]; then
      jqf="$jqf | .severity = \"low\""
    fi
    jqf="$jqf)"
    local tmp="${DECISION}.tmp"
    jq "$jqf" "$DECISION" > "$tmp" && mv "$tmp" "$DECISION"
  done
}

annotate ".forward_findings"
annotate ".adversarial_findings"

# Add summary
tmp="${DECISION}.tmp"
jq --argjson v "$verified" --argjson d "$demoted" --argjson dc "$discarded" --argjson t "$total" \
  '. + {validator_summary: {verified: $v, demoted: $d, discarded: $dc, total: $t}}' \
  "$DECISION" > "$tmp" && mv "$tmp" "$DECISION"

# If any high-severity findings were discarded such that NO high findings
# remain, suggest decision downgrade. We don't auto-rewrite the decision
# (caller should), but we surface a recommendation.
remaining_high=$(jq -r '
  ((.forward_findings // []) + (.adversarial_findings // []))
  | map(select(.severity == "high" and (.validator_status // "verified") == "verified"))
  | length
' "$DECISION")

if [ "$discarded" -gt 0 ] && [ "${remaining_high:-0}" -eq 0 ]; then
  current_dec=$(jq -r '.outcome // .decision // empty' "$DECISION" 2>/dev/null)
  if [ "$current_dec" = "reject" ]; then
    tmp="${DECISION}.tmp"
    jq '. + {validator_recommendation: "downgrade-from-reject-no-verified-high"}' "$DECISION" > "$tmp" && mv "$tmp" "$DECISION"
  fi
fi

if [ "$discarded" -gt 0 ]; then
  echo "discarded:$discarded"
elif [ "$demoted" -gt 0 ]; then
  echo "demoted:$demoted"
else
  echo "ok"
fi

# Hard gate: if all high-severity findings were discarded, signal escalation required.
# Exit 2 tells the supervisor pipeline (session-stop.sh) to route to HITL.
HIGH_TOTAL=$(jq '[.forward_findings[], .adversarial_findings[] | select(.severity == "high")] | length' "$DECISION" 2>/dev/null || echo 0)
HIGH_DISCARDED=$(jq '[.forward_findings[], .adversarial_findings[] | select(.severity == "high" and .validator_status == "discarded")] | length' "$DECISION" 2>/dev/null || echo 0)

if [ "$HIGH_TOTAL" -gt 0 ] && [ "$HIGH_TOTAL" -eq "$HIGH_DISCARDED" ]; then
  echo "all-high-discarded"
  # Update the decision file to recommend escalation
  jq '.validator_recommendation = "escalate-all-high-findings-unverifiable"' "$DECISION" > "${DECISION}.tmp" && mv "${DECISION}.tmp" "$DECISION"
  exit 2
fi

exit 0
