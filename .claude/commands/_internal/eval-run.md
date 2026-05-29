---
description: INTERNAL — run the eval suite. Tier 1 deterministic (free, ~30s) or Tier 2 LLM-graded (paid, ~10min, ~$3).
---

# _internal/eval-run

Args: `$ARGUMENTS` = `--tier=1` (default) or `--tier=2` or `--all`

## Tier 1 — deterministic

Run the shell-based eval:

```bash
bash .athanor/_eval/run-tier1.sh
```

Surface the printed summary. If failures exist, show the relevant rows from `runs/<id>/diffs.jsonl`.

## Tier 2 — LLM grading (HITL gated)

Steps:

1. **Confirm spend** with user: "Tier 2 will distill 5 transcripts (~$1) and grade with opus (~$2). Approve?"
2. For each transcript under `.athanor/_eval/datasets/transcripts/<id>/`:
   - Spawn `session-distiller` agent (or `general-purpose` + sonnet if not registered yet) with the transcript path + a fresh `KB_SESSION_ID=eval-<id>`
   - Wait for completion
   - Spawn `kb-evaluator` agent (or `general-purpose` + opus) with the transcript id and the session id
   - Grader MUST write output to `.athanor/_eval/runs/<run>/grading/grading-<id>.json` matching `.athanor/_eval/grading-output.schema.json` exactly. Paste the JSON template into the grader prompt verbatim.
   - **Validate** the grader output: `bash .athanor/_eval/validate-grading.sh <path>`. On `reject:`, re-spawn the grader with the rejection reason in the prompt (max 1 retry).
3. Aggregate weighted scores into a single Tier 2 scorecard at `runs/<run>/tier2-scorecard.json`.
4. Append a Tier 2 section to `runs/<run>/report.md`.
5. Surface verdict counts (pass / fail / inconclusive).

Use `Agent` tool with `subagent_type="session-distiller"` and `subagent_type="kb-evaluator"` (or `general-purpose` + explicit `model` param). Run distillations sequentially (avoid context contention), grading in parallel (independent).

### Grader prompt template (paste verbatim per grader)

The grader prompt MUST end with this block so output shape is uniform:

```
OUTPUT (write to .athanor/_eval/runs/<RUN>/grading/grading-<ID>.json — strict schema):
{
  "transcript_id": "<ID>",
  "session_id": "eval-<ID>",
  "scores": {
    "groundedness": 0, "recall": 0, "precision": 0,
    "schema_compliance": 0, "vocab_discipline": 0,
    "confidence_calibration": 0, "provenance": 0,
    "granularity": 0, "adversarial_resistance": 0
  },
  "weighted_score": 0.0,
  "findings": [{"severity": "low|medium|high", "axis": "...", "evidence": "...", "fix_suggestion": "..."}],
  "verdict": "pass|fail|inconclusive"
}

Use EXACTLY these top-level keys. No extras. Eval runner validates against
.athanor/_eval/grading-output.schema.json and rejects drift.
```

## --all

Run Tier 1, then if it passes, prompt for Tier 2 confirmation.
