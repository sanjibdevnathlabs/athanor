# Vocabulary Changelog

Append-only log of vocabulary additions/removals. Every change requires HITL
approval via `/athanor vocab-extend`.

## v2 — 2026-05-29 (universal second brain)

- Replaced oncall-specific entity model with 5 universal types.
- Added `entity-types.txt` (LOCKED): `Concept`, `Finding`, `Procedure`, `Pattern`, `Session`.
- Relocked `relations.txt` to 9 universal predicates: `REFERENCES`, `ADDRESSES`,
  `OBSERVED_IN`, `RESOLVED_BY`, `INSTANCE_OF`, `RELATED_TO`, `CORRECTED_IN`,
  `SUPERSEDES`, `DISPUTED_BY`.
- Added `confidence-tiers.txt` (LOCKED): `unverified`, `tested`, `autonomous`.
- Added `session-outcomes.txt` (LOCKED): `resolved`, `mitigated`, `open`, `abandoned`.
- `services.txt`, `symptom-categories.txt`, `mcp-patterns.txt` are deprecated by the
  v2 entity model — `canonical_name` is now free-form (pattern-checked only), no
  closed-vocab lookup.
- **Wrapper migration: COMPLETE** — `kb-write-entity.sh` and `kb-validate.sh` were
  updated to v2 schema. The deprecated files `services.txt`, `symptom-categories.txt`,
  `mcp-patterns.txt` have been removed from `protocol/vocabulary/`. All wrapper
  references to v1 types and symptom categories have been eliminated.

## v1 — 2026-05-06 (genesis)

- Seeded `services.txt` from oncall/CLAUDE.md service tables (28 services).
- Seeded `symptom-categories.txt` with 20 standard categories.
- Seeded `mcp-patterns.txt` with 17 canonical patterns.
- Locked `relations.txt` (8 predicates).
