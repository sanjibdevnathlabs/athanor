---
description: INTERNAL — triage pending vocabulary additions (HITL). All vocab is locked in v2.
---

# _internal/athanor-vocab-extend

> **v2 note**: All files in `protocol/vocabulary/` (`entity-types.txt`, `relations.txt`, `confidence-tiers.txt`, `session-outcomes.txt`) are **LOCKED structural vocabulary**. There are no open, domain-specific vocab files — the v1 `services` / `symptom-categories` / `mcp-patterns` files were removed when the entity model became universal. Entity `canonical_name`s are **free-form** (pattern-checked only), so ordinary naming never needs an extension. This command exists solely to triage any legacy entries left in the pending queue; it never edits a vocabulary file.

Read `.athanor/_state/pending-vocab-additions.json` (one JSON object per line, append-only). If absent or empty, report "no pending vocab additions" and exit. For each unprocessed entry:

1. Show the user: target vocabulary file, term, context, source session.
2. State that the target is LOCKED — a genuine addition requires a **protocol version bump** (`/athanor protocol-bump`) with a migration, not a flat append.
3. Ask: reject (default) / escalate-to-protocol-bump / skip.
4. On reject: append a row to `.athanor/_state/vocab-rejections.jsonl` with reason.
5. On escalate: record the requested term + rationale for the protocol-bump author. Do NOT edit any `.txt`.
6. On skip: leave for next time.

Mark processed entries by writing a sibling file `pending-vocab-additions.processed.jsonl` with the decision applied. The pending file is then truncated of processed entries.

**Never edit any file in `protocol/vocabulary/` from this command** — all are LOCKED. Additions/removals go through `/athanor protocol-bump` so the change is versioned and migrated.
