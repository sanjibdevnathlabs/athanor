---
description: INTERNAL — process pending vocabulary additions with HITL approval.
---

# _internal/athanor-vocab-extend

Read `.athanor/_state/pending-vocab-additions.json` (one JSON object per line, append-only). For each unprocessed entry:

1. Show the user: type (services / symptom-categories / mcp-patterns), term, context, source session.
2. Ask: approve / reject / skip.
3. On approve: append term to the corresponding `protocol/vocabulary/<file>.txt` (one line, lowercase, hyphen-separated). Add a CHANGELOG entry with date + reason.
4. On reject: append a row to `.athanor/_state/vocab-rejections.jsonl` with reason.
5. On skip: leave for next time.

Mark processed entries by writing a sibling file `pending-vocab-additions.processed.jsonl` with the decision applied. The pending file is then truncated of processed entries.

Vocabulary file `relations.txt` is LOCKED — reject any additions to it; require a protocol version bump instead.
