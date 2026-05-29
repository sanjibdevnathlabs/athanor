---
name: live-graph-writes
description: Rules for the main agent (during live sessions) to write to the KB graph mid-investigation. Distinguishes from distiller writes. Triggered ONLY by explicit user signal (remember/note/important).
---

# live-graph-writes

The main agent (the model handling user prompts during a live session) is allowed to write to the KB graph mid-session — but only under tight constraints. Most writes are batched by the distiller post-Stop. This skill defines the narrow exceptions.

## When to write live

ONLY when ALL of these are true:

1. User said one of: "remember", "note that", "important to know", "for future reference", "key insight", "capture this"
2. The fact is **durable** — would be useful to recall in a future session, not just this one
3. The fact is **specific** — has concrete entities (service, symptom, fix) not vague impressions
4. You can produce an **evidence_snippet** ≥20 chars from the immediate conversation

When not all 4 are true: do NOT write live. Let the distiller handle it.

## Write recipe

For each fact, run wrapper validation FIRST:

```bash
export KB_SESSION_ID=<current-session>
echo '<json>' | bash .claude/hooks/lib/kb-write-entity.sh
```

Read the response:
- `ok:<id>` → call `mcp__knowledge-graph__create_entities` with the validated payload
- `reject:vocabulary-not-in-X` → tell user one short line: "That introduces a new term '<X>'. Adding pending vocab — approve via /athanor vocab-extend." Append to `pending-vocab-additions.json`. Don't write.
- `reject:<schema>` → tell user the constraint, ask for clarification
- `skip:already-written:<id>` → say "already in KB" and move on

For relations and observations, same flow with `kb-write-relation.sh` / `kb-write-observation.sh`.

## Confirm to user (one line)

After a successful live write:

> Noted in KB: `Service:care MANIFESTS Symptom:care-latency-spike-20260506`. Audited.

That's it. Don't dump the entity JSON. Don't list every observation written.

## Forbidden

- ❌ Writing live without an explicit user trigger phrase
- ❌ Writing speculation ("might be a memory leak — capturing")
- ❌ Writing during open-ended discussion / brainstorming
- ❌ Calling `mcp__knowledge-graph__*` without wrapper green-light
- ❌ Writing a new vocabulary term without HITL approval

## What lands in the distiller's lap (not yours)

- Routine investigation flow (every kubectl call doesn't need a live capture)
- Inferring relations from history
- Updating runbooks
- Updating confidence ledger
- Session digest

Stay narrow. Live writes are for the user's intentional, durable signals.
