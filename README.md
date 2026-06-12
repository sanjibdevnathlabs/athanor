# athanor

> athanor is a second brain for anyone who uses Claude Code. Every session — debugging, research, design, writing, analysis — deposits structured knowledge. Future sessions draw on it proactively, before you repeat investigation you've already done.

## What it is

Works for any domain. Whether you're debugging production systems, researching a topic, writing a document, or analyzing data — the distiller extracts what matters: named things worth knowing (Concepts), discoveries and conclusions (Findings), repeatable processes (Procedures), and recurring patterns (Patterns). The next time you encounter something related, the system surfaces what you found last time before you start.

The user just talks. The system captures, validates, commits, and recalls silently. No manual invocation. No version migrations — the codebase is the version.

A supervisor agent runs adversarially after each distillation — blind to the distiller's prompt — to catch hallucinated or drifted entries and flag them for human review. The KB self-heals over time as bad entries are pruned and good ones gain confidence.

## Problem it solves

- **Repeated investigations.** You debug the same payment failure twice because you don't know you've seen it before. Athanor surfaces what you found last time before you start.
- **Agents forget across sessions.** Tribal knowledge stays in chat logs that get compacted away. Athanor extracts it before that happens.
- **Manual capture is lossy.** Engineers don't write postmortems for routine debugging. The distiller does.
- **KBs accumulate hallucination.** Most "AI knowledge bases" trust the writer. Athanor's supervisor + grep-based finding validator catch fabricated entries after commit and route them to HITL.
- **Vocabulary drift.** Closed-vocab terms with HITL extension prevent the same concept being captured 5 different ways.
- **Context window overload.** Loading the whole KB on session start burns the context window. Athanor injects ≤100 tokens at SessionStart and proactively recalls relevant context on each investigation prompt — injected automatically, not loaded wholesale.

## How it works

```
                                 ┌──────────────────┐
   Live session ──── Stop ──────▶│   distiller      │
   (Claude Code)                 │   (sonnet)       │
        ▲                        └────────┬─────────┘
        │                                 │
        │                                 ▼
        │                        ┌──────────────────┐
        │                        │   wrappers       │── reject:reason ──▶ HITL
        │                        │   (kb-write-*)   │
        │                        └────────┬─────────┘
        │                                 │ ok:id → stage to manifest
        │                                 ▼
        │                        ┌──────────────────┐
        │                        │   kb-committer   │
        │                        │   (reads staged  │
        │                        │    manifest)     │
        │                        └────────┬─────────┘
        │                                 │ commits + writes digest
        │                                 ▼
        │                        ┌──────────────────┐
        │                        │   KB             │
        │                        │   (graph+vector) │
        │                        └────────┬─────────┘
        │                                 │
        │                        ┌────────┘  async, after digest exists
        │                        ▼
        │               ┌──────────────────┐
        │               │   supervisor     │── findings ──▶ HITL queue
        │               │   (adversarial   │              (/athanor review)
        │               │    audit)        │
        │               └──────────────────┘
        │
        └──── proactive recall ◀── UserPromptSubmit hook
              (top-K injected as           (fires on investigation
               additionalContext)           intent, mandatory)
```

**Capture (Stop hook).** Async transcript copy → spawn distiller subagent.

**Validate + Stage (distiller + wrappers).** The distiller is a read-only extraction agent. Every candidate entity, relation, observation passes through `kb-write-{entity,relation,observation}.sh`. Wrappers enforce schema, locked structural vocabulary (entity types + relation predicates — `canonical_name`s themselves are free-form), idempotency (content-hash IDs), and provenance. Three outcomes: `ok:<id>` → distiller stages the artifact to `_staging/<sid>/manifest.jsonl`; `reject:<reason>` → stop; `skip:already-written:<id>` → no-op. The distiller never touches Neo4j or the vector layer directly.

**Commit (kb-committer).** A separate `kb-committer` agent reads the prepared, sorted manifest and commits to Neo4j after the distiller exits — entities first, then relations, then observations — writes `committed-ids.jsonl`, writes the session digest, then runs `kb-index.sh` (append to the immutable corpus → embed → upsert into the active vector driver), and runs confidence promotion.

**Audit (supervisor, async).** An independent supervisor — forbidden from reading the distiller's prompt — runs after the session digest exists. It re-derives findings from the transcript + what was committed. Findings with grep-verifiable evidence route to the HITL queue for human review. The supervisor can flag but not block; bad entries are pruned after human confirmation.

**Recall (proactive).** The `UserPromptSubmit` hook detects investigation intent and runs `kb-recall.sh` against the prompt. Top-K results are injected as `additionalContext` before the model responds — mandatory, not optional. `kb-recall.sh` runs the three vector passes (runbooks, sessions, skills) INLINE against the active driver — one query embed reused across three artifact-filtered searches — and emits them as `vector_results`, plus the residual graph plan: one graph search, one 1-hop graph expansion, and one disputed-entity filter. Results are ranked using a 0–10 additive scoring rubric (service match +4, symptom category match +3, resolved runbook +2, recent session +1, top-3 vector hit +2, graph direct hit +2). Disputed entities are excluded from recall regardless of vector similarity.

Same prompt → semantically equivalent retrieval, regardless of model or session.

## Key concepts

**Closed vocabulary.** Entity types, relation predicates, confidence tiers, and session outcomes are enumerated in `protocol/vocabulary/`. Novel terms route to `pending-vocab-additions.json` for human approval via `/athanor vocab-extend`. The distiller never invents.

**Schema-driven write gates.** Entity types and required fields live in `protocol/schema/`. Wrappers reject any write that doesn't match. Schema bumps go through `/athanor protocol-bump` with a migration plan.

**Idempotent content-hash IDs.** `id = sha256(entity_type:canonical_name)[:16]`. The same entity written from two sessions becomes one record. Committed writes are durably recorded in `.athanor/_state/committed-ids.jsonl` (one `{"id":"..."}` per line), enabling cross-session dedup without re-querying Neo4j.

**Frozen retrieval algorithm.** Weights and step order are locked in `protocol/recall-algorithm.md`. Determinism across sessions/models depends on this not drifting.

**Confidence ladder.** Every artifact starts at `unverified`. Promotion to `tested` requires evidence of repeat use; `autonomous` (read-only auto-recall) requires audit clearance. Demotion happens automatically on user correction.

**Kill switch + bypass detection.** A `PostToolUse` hook flags any KB write that bypasses a wrapper. Three consecutive supervisor rejections, >5 bypasses in 24h, or a health score <0.7 trips the auto-commit flag. Reset is HITL via `/athanor reset <flag> <reason>`.

**Provenance enrichment.** Every committed record carries `created_under_protocol=v1`, `created_by_distiller_version=<hash>`, `supervised_by_version=<hash>`, `audit_evidence_hash=<sha>`. Surgical rollback by version + session_id.

**Pipeline credit.** A flaw the distiller introduced *and* the supervisor caught is no penalty against the system. The eval framework grades the pipeline, not the distiller alone.

## Quality bar

Two-tier eval framework. Both must pass for a release.

| Tier | What | Latest result |
|---|---|---|
| 1 | Deterministic — schema, vocab, idempotency, hooks, kill-switch, supervisor-validator, provenance | **65/65 pass** |
| 2 | Transcript graders — 5 synthetic transcripts × 5 independent opus graders, 9-axis scoring (groundedness, recall, precision, schema_compliance, vocab_discipline, confidence_calibration, provenance, granularity, adversarial_resistance) | **5/5 pass · avg 4.88 · 0 supervisor hallucinations leaked** |

Run via `bash .athanor/_eval/run-tier1.sh` (pure bash/jq, no external deps) and the `eval-run` internal command for Tier 2.

Tier 2 graders are forbidden from reading the distiller agent, the supervisor agent, the distill-session skill, or wrapper source — independent grading. Output is schema-validated against `.athanor/_eval/grading-output.schema.json` before being counted.

## File layout

```
.claude/                       # Agent artifacts (committed)
  skills/
    athanor-protocol/          # Mandatory rulebook for KB ops
    athanor-recall/             # Retrieval methodology
    athanor-supervision/        # Supervisor + auditor methodology
    distill-session/            # Distiller methodology
    athanor-learn/              # On-demand "learn this" — full-pipeline mid-session capture
  agents/
    session-distiller.md        # Sonnet, async post-Stop — stages manifest
    kb-committer.md             # Reads prepared manifest, commits entities/relations/observations to Neo4j, writes session digest, indexes via kb-index.sh, runs confidence promotion
    distillation-supervisor.md  # Sonnet, validates manifests
    kb-auditor.md               # Opus, on-demand drift sweep
    kb-evaluator.md             # Tier 2 grader template
  commands/
    athanor.md                  # User-facing dashboard (/athanor)
    _internal/                  # Agent-only sub-commands — invoked by agents, never users
      athanor-{audit,trace,review,validate,recall,vocab-extend,kill-switch,protocol-bump}.md
      distill.md
      promote-skill.md
      eval-run.md
  hooks/
    session-start.sh            # ≤100-token KB stats injection
    session-stop.sh             # Async distiller spawn
    pre-compact.sh              # Async transcript backup
    auto-orchestrate.sh         # UserPromptSubmit intent detection
    post-tool-use.sh            # Bypass detection
    lib/
      kb-common.sh              # Shared helpers
      kb-write-{entity,relation,observation}.sh   # Write gates
      kb-recall.sh              # Runs vector passes inline + emits residual graph plan
      kb-index.sh               # WRITE: corpus append + embed + upsert (both learn paths)
      kb-reindex.sh             # Replay corpus → vector DB (DR / driver swap / model change)
      kb-validate.sh            # State sanity check
      vec.sh                    # Dispatcher → vec Python package (owns venv)
      vec/                      # Vector layer (athanor-owned; SocratiCode removed)
        config.py               #   resolve VEC_* (env > protocol/vector.config > default)
        embed.py                #   text → vector (Ollama; provider-pluggable)
        corpus.py               #   append-only immutable NDJSON backup (source of truth)
        drivers/                #   base.py + qdrant.py (live) + chromadb.py (stub)
        cli.py                  #   health|ensure|backfill|index|reindex|recall|search
      kill-switch-check.sh      # Auto-trip + reset
      bypass-detector.sh        # Wrapper-bypass detection
      supervisor-gate.sh        # approve/reject/status
      provenance-attach.sh      # Enrich records
      validate-supervisor-findings.sh   # Grep-verify finding evidence
  settings.json                 # Hooks + permissions

protocol/                      # Spec (committed) — schemas, vocab, recall algo, version
                               # Lives at repo root, NOT under .athanor/, so a fresh
                               # clone has vocabulary and the write-gates function.
  vector.config                 # Vector layer config (driver, collection, embed model)
  vocabulary/
    entity-types.txt            # Concept, Finding, Procedure, Pattern, Session
    relations.txt               # 12 locked relation predicates
    confidence-tiers.txt        # unverified, tested, autonomous
    session-outcomes.txt        # resolved, mitigated, open, abandoned

.athanor/                      # KB (gitignored, per-clone)
  _state/                       # Cursors, ledgers, kill-switch, health-score, HITL queue, embeddings.lock
  _eval/                        # Datasets + run history + tier scripts
  _staging/<sid>/               # Pre-commit manifests
  _quarantine/                  # Rejected manifests
  _audit/                       # On-demand audit reports
  _meta/                         # Internal design notes
  raw/                          # Transcript copies
  corpus/<YYYY-MM>.ndjson       # Immutable, self-contained vector backup (replayable)
  distilled/sessions/           # Per-session digests
  runbooks/<svc>/<sym>.md       # Accumulated playbooks
  local-skills/<n>/SKILL.md     # WIP skills
  memory/                       # Typed memory entries
```

> **Agent-only**: `_internal/` commands are invoked by agents, not by users directly. Running them
> manually may corrupt pipeline state. The only user-facing command is `/athanor`.

## Quick start

1. Clone the repo. Follow `SETUP.md` to get Neo4j (+ its MCP), Qdrant, and Ollama running. The vector layer is in-repo Python — `SETUP.md` covers the one-time venv bootstrap and first index.
2. Open Claude Code from this directory: `claude`
3. Just talk. Hooks fire automatically — capture, validate, commit, and proactive recall all happen silently.
4. `/athanor` opens the dashboard — KB stats, recent writes, HITL queue, kill-switch status, eval results.
5. When the system surfaces a pending vocab term or a supervisor finding, run `/athanor review` to walk through the queue.

## Currently accumulated content

The KB accumulates knowledge from any domain. Content grows with use.

| | |
|---|---|
| Entity types | `Concept`, `Finding`, `Procedure`, `Pattern`, `Session` |
| Vocabulary | 5 entity types, 12 locked relation predicates, 3 confidence tiers, 4 session outcomes |
| Integrated MCPs | `knowledge-graph` (Neo4j) |
| Vector layer | In-repo, athanor-owned (`.claude/hooks/lib/vec/`) — driver-based (Qdrant live, ChromaDB pluggable) + Ollama embeddings. Not an MCP. |

> Additional domain-specific MCPs (observability, infra, data, messaging) can be added per your environment — see `CLAUDE.md` for examples.

## Extending

| Extension | Mechanism |
|---|---|
| Add a vocabulary term | Distiller routes novel term → `/athanor vocab-extend` (HITL approves/rejects) |
| Add an entity type | Edit `protocol/schema/entity-types.json` → `/athanor protocol-bump` |
| Add a relation predicate | Edit `protocol/schema/relation-types.json` (LOCKED list) → protocol-bump |
| Integrate a new MCP | Register in `.claude/settings.json` + add a section under "Currently Integrated MCP Tools" in `CLAUDE.md` |
| Add a skill | `.claude/skills/<name>/SKILL.md` — methodology + examples |
| Add an agent | `.claude/agents/<name>.md` — system prompt + scope |
| Add a slash command | `.claude/commands/<name>.md` (user-facing) or `_internal/<name>.md` (agent-only) |
| Promote an artifact | `_internal/promote-skill.md` walks the confidence ladder |

## Pointers

- `CLAUDE.md` — agent operational rules (mandatory reading for the agent)
- `DESIGN.md` — design rationale, why each architectural decision was made
- `SETUP.md` — how to get Neo4j (+ MCP), Qdrant, Ollama, and the in-repo vector layer running from scratch
- `protocol/PROTOCOL.md` — public spec, contract for all agents
- `protocol/recall-algorithm.md` — the frozen retrieval algorithm
- `.athanor/_eval/runs/` — historical eval results
