# DESIGN.md — Athanor Architecture Decisions

This document explains *why* athanor is built the way it is. For *what* it does and *how* to set it up, see README.md and SETUP.md.

---

## Vision

Athanor is ambient institutional memory for anyone using Claude Code. Every session deposits structured knowledge into a shared graph. Future sessions draw on it automatically — before the user has to ask. The user just works; the system learns silently and surfaces relevant past knowledge so investigations don't repeat.

The unit of value is: you resolve something today, and six months later, a related task prompts a recall that shows you exactly what you found last time. That holds whether the session was a debugging investigation (a recurring service failure surfaces the prior root cause and fix) or a non-engineering one (research on a topic surfaces the sources and conclusions you already gathered).

---

## Architecture Decisions

### Distiller and supervisor are separate agents

The supervisor is forbidden from reading the distiller's prompt. If they shared a prompt, they'd share blind spots — the same reasoning that caused a hallucination in the distiller would cause the supervisor to miss it. Independence is the entire point of adversarial review. Two agents that share a prompt are one agent with extra latency.

### Commit flow: distiller stages, kb-committer commits, supervisor audits after

The distiller runs as a read-only extraction agent: it reads the transcript, runs every candidate through `kb-write-*.sh` wrappers (schema validation, vocab check, idempotency), and stages approved artifacts to `_staging/<sid>/manifest.jsonl`. It never touches Neo4j or SocratiCode directly.

A separate kb-committer agent reads the prepared, sorted manifest and performs all graph writes. It runs `mcp__knowledge-graph__create_entities/relations/observations` in dependency order (entities first, then relations, then observations), writes `committed-ids.jsonl`, writes the session digest, runs the `codebase_context_index` for Qdrant, and performs confidence promotion.

The supervisor runs after the digest exists, reads the transcript + what was committed, and flags issues to the HITL queue.

This is correct because:
- Separating extraction from commit keeps the distiller read-only, so a buggy distiller can never corrupt the graph directly — every write is gated through the staged manifest.
- Making commits gated on supervisor approval creates a broken pipeline when the supervisor lacks commit tools.
- Adversarial audit doesn't require blocking — it requires flagging. Flagging after the fact is sufficient, and blocking would serialize a pipeline that should be parallel.

### Entity types are intentionally generic

Entity types are intentionally generic — five types that cover the knowledge produced by any type of session. Concept covers named things. Finding covers discoveries and conclusions. Procedure covers repeatable processes. Pattern covers recurring structures. Session provides the temporal anchor. This small set means the distiller adapts to any domain without configuration.

### Closed vocabulary

Open vocabulary causes KB drift: "payment-service", "payments", "the-payment-svc", "PaymentService" become four records for the same concept. Closed vocab (entity types, relation predicates, confidence tiers, session outcomes) with HITL extension forces canonical names. The tax is one approval per new term. The benefit is a KB that stays coherent over hundreds of sessions.

New terms go to `.athanor/_state/pending-vocab-additions.json` and are approved via `/athanor vocab-extend`. Agents never invent vocabulary mid-session.

### Frozen recall weights (0.50 / 0.30 / 0.15 / 0.05)

Weights: vector similarity 0.50, graph proximity 0.30, confidence tier 0.15, recency 0.05.

If weights are tunable per-session, recall output changes between sessions for the same query. Two sessions debugging the same symptom would retrieve different context. Determinism is a feature. Weights were set empirically against the eval suite; changing them requires a protocol bump with a migration script.

### Confidence ladder (unverified → tested → autonomous)

An entity written from one session is `unverified` — could be a one-off or a misread. After repeat use with consistent evidence, it is promoted to `tested`. `autonomous` entities are auto-recalled without user action; `unverified` ones require explicit recall.

This prevents one noisy session from polluting future sessions with low-quality data. The ladder also makes the KB self-healing: bad data that never gets corroborated stays `unverified` and decays in recall priority.

### `protocol/` committed, `.athanor/` gitignored

`protocol/` contains the spec — vocabulary, schema, recall algorithm, golden fixtures. It is code, not data. It must be version-controlled alongside the hooks that enforce it. Gitignoring the spec was an early bug: fresh clones had broken wrappers because the wrappers couldn't find the vocabulary file.

`.athanor/` is runtime KB data — sessions, graph entries, staging manifests, audit logs. It is per-clone and never shared. Committing it would create merge conflicts on every session end.

### Kill switch and bypass detector

The system writes to a shared graph. If the agent writes unchecked (bypassing wrappers), bad data accumulates silently with no audit trail. The bypass detector catches direct Neo4j calls made without wrapper pre-staging. The kill switch auto-trips on anomaly thresholds and requires human reset.

Failing closed is correct here. A paused KB is recoverable; a corrupted KB is not.

### Cascade prevention in session-stop

`session-stop.sh` spawns `claude --agent session-distiller`. The distiller is itself a Claude session. When it ends, `session-stop.sh` fires again. Without prevention, this creates exponential spawning — each distiller spawns two more distillers.

Fix: a project-level global lock file (`/tmp/athanor-distiller-<project>.lock`) combined with improved agent-session detection. The lock is created before spawning and removed on completion. If the lock exists, `session-stop.sh` exits immediately.

### `memory_bank/` as live-session scratch space

During live sessions, agents sometimes create files (investigation notes, analysis drafts). These are ephemeral — the distiller extracts knowledge from the session transcript, not from files. Scratch files should go to `memory_bank/` (gitignored) to avoid polluting the committed repo. The directory is stable across sessions but its contents are disposable.

---

## What's Committed vs Gitignored

| Path | Status | Why |
|------|--------|-----|
| `.claude/` | Committed | Agent config — skills, hooks, agents, commands |
| `protocol/` | Committed | Spec — must be versioned with the hooks that enforce it |
| `DESIGN.md`, `README.md`, `SETUP.md` | Committed | Documentation |
| `.athanor/` | Gitignored | Runtime KB data — per-clone, never shared |
| `memory_bank/` | Gitignored | Live-session scratch — ephemeral, not knowledge |
| `.oncall/` | Gitignored | Legacy path, superseded by `.athanor/` |
| `runbooks/` (repo root) | Should not exist | Runbooks belong at `.athanor/runbooks/` |

> **Legacy `.oncall/`**: This directory is a legacy artifact from the Razorpay-specific predecessor that
> seeded athanor. It is gitignored in v2 and should not be used — all runtime KB state lives under
> `.athanor/`. It will be cleaned up. Do not write to it or read from it.

`committed-ids.jsonl` — append-only ledger of durably committed entity/relation/observation IDs. Used by wrappers for cross-session `skip:already-written` dedup. Written by bypass-detector.sh on authorized writes. Never read by Neo4j queries.

The distill cursor (`distill-cursor.json`) is written by `session-stop.sh` (not the distiller) after confirming the session digest exists, ensuring it only advances on successful distillation.

---

## Bootstrap Requirements

See `SETUP.md`. Required:
- **Neo4j** — knowledge-graph MCP server (`mcp__knowledge-graph__*`)
- **Qdrant + Ollama** — SocratiCode MCP server for vector search
- **Claude Code CLI** — with hooks registered in `.claude/settings.json`

All three must be reachable before hooks will function. The `session-start.sh` hook performs a health check and logs failures to `.athanor/_state/health-score.json`.
