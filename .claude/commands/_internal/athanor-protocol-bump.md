---
description: INTERNAL — bump the protocol version with a migration script. HITL-only.
---

# _internal/athanor-protocol-bump

Args: `$ARGUMENTS` = `<new-version>` (e.g. `v2`)

Process (must complete in order):

1. Verify there's a migration script at `protocol/migrations/v<current>-to-v<new>.sh`. If missing, abort.
2. Verify there are updated golden test fixtures in `protocol/test-fixtures/`. If unchanged from previous version, warn and ask user to confirm.
3. Run the migration script. Capture stdout/stderr to `.athanor/_state/protocol-migration-<ts>.log`.
4. On success, update `protocol/version.txt` to the new version.
5. Run `_internal/athanor-validate`. If it fails, roll back version.txt, surface error.
6. Append CHANGELOG entry to `protocol/vocabulary/CHANGELOG.md` (create if missing).

Phase 1: this command is wired but no migrations exist yet. Calling it without a v1-to-v2 script will abort cleanly.
