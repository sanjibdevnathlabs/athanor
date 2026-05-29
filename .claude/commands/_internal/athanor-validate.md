---
description: INTERNAL — run protocol validators and the golden-test fixture.
---

# _internal/athanor-validate

1. Run `bash .claude/hooks/lib/kb-validate.sh`. If it exits non-zero, print failures and stop.
2. Read `protocol/test-fixtures/sample-transcript.jsonl` and `protocol/test-fixtures/expected-entities.json`.
3. (Optional in P1) Invoke session-distiller against the fixture transcript with a special `KB_SESSION_ID=fixture-test` env. Compare actual staging manifest against `expected-entities.json`. Drift → fail loud, surface diff.
4. Print summary.

In P1, step 3 is an aspirational check. The distiller invocation is wired but the diff comparison is best-effort.
