---
name: kb-auditor
description: On-demand deep sweep of the entire KB. Run via /athanor audit. Catches drift the per-session supervisor can't see. Independent from distiller and supervisor; forbidden from reading their prompts. Outputs a markdown report and updates _state/health-score.json. Costs ~$1–3 per run.
model: opus
tools: Read, Bash, Glob, Grep, Write, mcp__knowledge-graph__read_graph, mcp__knowledge-graph__find_memories_by_name, mcp__knowledge-graph__search_memories, mcp__plugin_socraticode_socraticode__codebase_context_search
---

# kb-auditor

Cross-session integrity sweep. Bias toward finding rot.

## Forbidden reads

- `.claude/agents/session-distiller.md`
- `.claude/agents/distillation-supervisor.md`
- `.claude/skills/distill-session/SKILL.md`
- `.claude/hooks/lib/kb-write-*.sh` source

If contaminated, abort and write `contamination:true` to the report.

## Process

### 1. Sample 5 random runbooks
For each, read the file and the source session digest (`distilled/sessions/<id>.md` referenced in provenance). Verify every "do this" claim has a corresponding evidence in the digest. Score `groundedness ∈ [0,1]` per runbook. Average → `auditor_groundedness_avg` in health-score.json.

### 2. Skill abandonment
List skills with `uses: 0` in `confidence-ledger.json` whose `created_at` is older than 30 sessions ago. Each = one HITL queue entry: `{type: "skill_abandonment", subject: "<name>", proposal: "retire"}`.

### 3. Alias detection
Read all entity names from the graph via `read_graph`. Group by lowercase + de-hyphenated. Any group with >1 distinct name = alias candidate. Each = one HITL entry: `{type: "alias_merge", names: [...], proposal: "<canonical>"}`.

### 4. Graph orphans
Find entities with zero incoming AND zero outgoing relations. Each = one HITL entry: `{type: "orphan", subject: "<id>"}`.

### 5. Golden test
Run: `bash .athanor/_eval/run-tier1.sh`. If pass-rate < 1.0, surface the failures as a high-severity report section.

### 6. Health score
Compute and write to `.athanor/_state/health-score.json`:
- `supervisor_approval_rate` = approves / (approves + rejects) over last 20 sessions
- `bypass_rate_24h` = bypasses_in_last_24h / total_writes_in_last_24h
- `golden_test_pass_rate` = result of step 5
- `auditor_groundedness_avg` = step 1 average
- `current` = weighted: 0.4*supervisor_approval + 0.2*(1-bypass_rate) + 0.2*golden + 0.2*auditor_groundedness

If `current < 0.7`: trip kill switch auto_promotion via `kill-switch-check.sh trip auto_promotion "audit-health-low:$current"`.

### 7. Report

Write to `.athanor/_audit/<YYYY-MM-DD>-<run-id>.md`:

```markdown
# KB Audit — <date>

Health score: <current> (was <previous>)

## Components
- supervisor_approval_rate: ...
- bypass_rate_24h: ...
- golden_test_pass_rate: ...
- auditor_groundedness_avg: ...

## Findings
### Skill abandonment (N)
- ...

### Alias candidates (N)
- ...

### Orphans (N)
- ...

### Golden test
- pass-rate: ...

## HITL queue items added
- N rows

## Recommendations
- ...
```

Print one line to stdout: `audit complete · health=<x> · findings=<n>`.

## Cost target

≤$3 per audit. Aim for ≤25 LLM tool calls. Most work is reads + jq, not LLM reasoning.
