---
name: athanor-supervision
description: Methodology for the distillation supervisor agent and the on-demand auditor. Defines the two-pass review loop (forward + rolling adversarial), the gate to KB commit, the confidence-promotion ladder, the kill switch trip rules, and the HITL escalation queue. Read this if modifying the supervisor or auditor prompts.
---

# athanor-supervision

How quality is enforced after distillation. Two complementary surfaces:

1. **Inline supervisor** (sonnet) — runs after every distillation, blocks bad commits.
2. **On-demand auditor** (opus) — deeper sweep via `/athanor audit`, catches drift the supervisor's per-session view can't.

## Pipeline (post-Stop)

```
distiller (sonnet)
   │
   ▼
.athanor/_staging/<sid>/manifest.jsonl
   │
   ▼
distillation-supervisor (sonnet) ←── reads forbidden-list-aware prompt
   │
   ├── approve  →  supervisor-gate.sh approve <sid>
   │                  │
   │                  ▼
   │             provenance-attach.sh per record
   │                  │
   │                  ▼
   │             KB_WRAPPER=1  mcp__knowledge-graph__create_*
   │                  │
   │                  ▼
   │             kb-writes.jsonl audit
   │
   └── reject   →  supervisor-gate.sh reject <sid> <reason>
                      │
                      ▼
                  .athanor/_quarantine/<sid>-<ts>/
                  + hitl-queue.jsonl entry
                  (3 consecutive rejects → kill switch trips auto_commit)
```

## Supervisor pass — what to check

Two passes per session, in this order:

### Pass 1 — Forward (THIS session's manifest)

| Axis | Check |
|---|---|
| Groundedness | Each observation's `evidence_snippet` exists verbatim in transcript (`rg`). |
| Schema | Records validate against `protocol/schema/*.json`. |
| Vocab | No invented terms. Missing terms routed to `pending-vocab-additions.json`. |
| Provenance | `evidence_snippet` ≥20 chars on observations. |
| Specificity | Not vague filler (no "investigated issue", no one-obs-per-tool-call). |
| Outcome calibration | Incident.outcome reflects what literally happened (mitigated ≠ resolved). |
| Confidence | New skills `unverified`. No auto-promotion. |
| Contradiction | New relations don't contradict existing graph (query before write). |
| Caps | ≤30 entities, ≤30 relations, ≤50 observations per session. |

Decision:
- All clean → `approve`
- One axis low-severity issue → `approve` with note logged
- Any axis high-severity → `reject` with reason
- Borderline → `revise` (return to distiller with feedback, max 1 revision)
- Ambiguous → `escalate` to HITL queue

### Pass 2 — Adversarial sample (rolling, bounded)

Pull 3–5 KB items from `.athanor/_state/probe-cursor.json` (oldest-not-recently-probed). Run the inverse prompt against them: "argue why these are wrong, stale, or harmful". Update probe cursor.

- If you can substantively argue against → mark for HITL review (`hitl-queue.jsonl`)
- If clean → bump probe cursor, continue
- After M sessions, every artifact has been adversarially probed at least once

This replaces the original cron-based monthly sweep — bounded cost, always fresh.

## Confidence promotion ladder

Strict evidence requirements (enforced in `_internal/promote-skill.md`):

| Transition | Requires |
|---|---|
| `unverified → tested` | uses ≥ 1, supervisor approved this session, no correction |
| `tested → autonomous` | uses ≥ 3, all supervisor-approved, zero corrections, no `DISPUTED_BY` involving this skill |
| Any → demoted (one tier) | Single user correction in same session OR auditor flags |

`autonomous` tier means a Skill can be auto-chained inside read-only investigation flows without confirmation. ANY write/post/exec is still HITL regardless of tier.

## Auditor — when and what

`/athanor audit` is on-demand (no cron). Auditor (opus) does a deep sweep:

1. **Sample 5 random runbooks**, verify every claim against the source session digest. Score `auditor_groundedness_avg`.
2. **Skill abandonment check**: any skill unused in last 30 sessions → propose retirement (HITL).
3. **Alias detection**: entities whose `canonical_name` differs only by hyphen/case/whitespace → propose merge (HITL).
4. **Graph orphan check**: entities with zero relations → propose pruning or HITL.
5. **Golden test fixture**: run `/athanor validate` and the test-fixtures pipeline.
6. **Health score** update: write rolling components to `_state/health-score.json`.
7. **Health < 0.7 → trip kill switch** auto_promotion.

Output: `.athanor/_audit/<date>-report.md` + HITL queue entries.

## Kill switch — auto-trip rules

Tripped automatically when ANY of these fire:

| Condition | Tripped flag | Reset path |
|---|---|---|
| Supervisor rejects ≥3 consecutive distillations | `auto_commit` | `/athanor reset auto_commit` (HITL with reason) |
| Bypass count > 5 in 24h | `auto_promotion` | `/athanor reset auto_promotion` (HITL) |
| Golden test fails | `auto_promotion` | After fix → `/athanor reset` |
| Auditor health score < 0.7 | `auto_promotion` | After audit-driven fixes → `/athanor reset` |

When tripped:
- Distiller still runs (capture still happens)
- Supervisor still grades (so we know if quality recovers)
- KB writes route to `_quarantine` instead of being committed
- SessionStart hook surfaces the trip loudly until reset

## HITL queue — single inbox

`.athanor/_state/hitl-queue.jsonl` accumulates anything needing human attention:

| Type | Source |
|---|---|
| `vocab_extension` | Distiller routed a missing term |
| `supervisor_rejection` | Pass 1 rejected, manifest quarantined |
| `adversarial_finding` | Pass 2 found a substantive argument against an existing artifact |
| `audit_finding` | Auditor flagged something |
| `kill_switch_trip` | Auto-trip surfaced for review |
| `contradiction` | Two relations contradict on same subject |

`/athanor review` walks the queue interactively. `/athanor review --batch` opens the file in `$EDITOR`.

## Forbidden reads (supervisor + auditor)

To preserve independence, these agents MUST NOT read the distiller's prompt or wrappers' source. Allowed: PROTOCOL.md, schemas, vocabulary, transcripts, manifests, KB state.

If they read forbidden files by accident, abort and report contamination (a high-severity finding in itself).
