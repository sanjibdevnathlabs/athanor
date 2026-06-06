---
description: INTERNAL — walk the HITL queue. Default = interactive (one item at a time). Pass --batch to open the file in $EDITOR.
---

# _internal/athanor-review

Args: `$ARGUMENTS` (optional: `--batch`)

## Default — interactive walk

1. Read `.athanor/_state/hitl-queue.jsonl` line by line.
2. Skip any line that already has a matching decision in `.athanor/_state/hitl-decisions.jsonl` (keyed by `ts+type+subject`, or `ts+type+session_id` when `subject` is absent, or `ts+type+manifest_path` as a final fallback).
3. For each unprocessed item, present:
   ```
   [N/M]  type=<type>  subject=<subject>
          context: <short context>

          Approve / Reject / Skip / Note?
   ```
4. Read user response. Map:
   - `y` / `yes` / `approve` → approve
   - `n` / `no` / `reject`  → reject (ask for one-line reason)
   - `s` / `skip` → leave for next time
   - Any other text → treat as a note, store with `decision: noted`
5. Apply the decision:
   - **vocab_extension approve** → append term to the appropriate `protocol/vocabulary/<file>.txt` + add CHANGELOG.md entry
   - **vocab_extension reject** → just log the rejection
   - **supervisor_rejection** — Supervisor rejected the committed records.
     - **Approve (accept data as-is)**: `bash .claude/hooks/lib/kb-delete.sh` for each hallucinated entity, then mark resolved.
     - **Approve (re-inject for re-commit)**: `bash .claude/hooks/lib/kb-recover.sh <session_id>` — moves manifest back to staging with attempts reset to 0. The next session-stop will re-commit it.
     - **Reject**: leave quarantined; permanent.
   - **adversarial_finding approve** → mark the artifact as `disputed:true` in the graph
   - **alias_merge approve** → run a merge script (TODO: P3)
   - **orphan approve** → delete the orphan entity
   - **kill_switch_trip approve** → trip remains; user will reset via `/athanor reset` separately
   - **supervisor_revision_needed** — Supervisor requested distiller revision.
     - **Approve (re-distill with feedback)**:
       1. Edit `.athanor/_quarantine/<sid>-revise/.revise-feedback.md` with your corrections
       2. `bash .claude/hooks/lib/kb-recover.sh <session_id> --with-feedback .athanor/_quarantine/<sid>-revise/.revise-feedback.md`
       3. This re-injects the manifest for re-commit. To re-distill from scratch: delete `_staging/<sid>/manifest.jsonl` first, then let session-stop re-distill.
     - Reject: quarantine permanently (leave as-is).
   - **supervisor_escalation** — Supervisor flagged an unresolvable conflict.
     - Approve: accept the committed data as-is and advance the cursor.
     - Reject: run kb-delete.sh for each flagged entity, then quarantine.
   - **max_retries_exceeded** — Session failed 3 distillation attempts.
     - **Approve (retry)**:
       1. Inspect `.athanor/_quarantine/<sid>-max-retries/manifest.jsonl` and fix any issues
       2. `bash .claude/hooks/lib/kb-recover.sh <session_id>` — resets attempt counter and re-injects
     - Reject: discard permanently.
   - **bypass_detected** / **unauthorized_delete** — A graph write bypassed the wrapper gates.
     - Review: check the flagged entity in Neo4j. If legitimate, add to committed-ids.jsonl and mark resolved.
     - If malicious: run kb-delete.sh to remove the entity, reset kill switch.
   - **learn_supervisor_no_outcome** — Learn commit succeeded, but supervisor produced no outcome.
     - Action: manually review the prepared manifest, digest, and `last-learn-*` logs. If issues found, use `kb-delete.sh`.
     - Mark resolved: add a `hitl-decisions.jsonl` entry confirming manual review.
     - If this came from `/_internal/slack-backfill`, advance `.athanor/_state/slack-backfill-cursor.json` to the replayed Slack ts (`last_processed_ts` + `last_committed_ts`) and set `last_mode` to `commit`, because the records are already committed and replaying the same post again is wrong.
   - **supervisor_timeout_auto_approved** — Session was committed without supervisor review (timeout).
     - Action: manually review the session digest and graph entities. If issues found, use kb-delete.sh.
     - Mark resolved: add a `hitl-decisions.jsonl` entry confirming manual review.
     - If this item also gates a replay cursor, advance that cursor after acceptance.
6. Append decision row to `.athanor/_state/hitl-decisions.jsonl`.
7. After loop: print `reviewed N items · approved=A rejected=R skipped=S noted=O`.

## --batch mode

Print: `EDITOR=$EDITOR — opening: .athanor/_state/hitl-queue.jsonl`. The user edits inline (decisions in a `decision` field per line) and saves. Then call:

```
bash .athanor/_eval/apply-hitl-decisions.sh   # P3 — for now just print "manual apply"
```

In P2, batch mode just opens the file and prints a hint to manually apply.
