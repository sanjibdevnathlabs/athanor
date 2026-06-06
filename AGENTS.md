# AGENTS.md

This file provides operational guidance to Codex (Codex.ai/code) when working with this repository.

For an overview of `athanor` — what it is, how it works, file layout, eval results, and how to extend it — see [README.md](README.md). This file covers only what the agent must do at runtime.

## MANDATORY: Self-Learning KB Protocol

This repo (`athanor`) auto-captures structured knowledge from every session. Hooks at `.Codex/hooks/` orchestrate the loop deterministically. The user just talks; you orchestrate silently.

### Non-negotiable rules

1. **All KB writes** to Neo4j (`mcp__knowledge-graph__create_entities`/`create_relations`/`add_observations`) MUST be preceded by a green-light from the corresponding wrapper at `.Codex/hooks/lib/kb-write-{entity,relation,observation}.sh`. Wrapper returns `ok:<id>` (proceed), `reject:<reason>` (stop), or `skip:already-written:<id>` (no-op).

2. **All KB reads** go through `.Codex/hooks/lib/kb-recall.sh` for the canonical retrieval plan. Frozen merge weights (0.50/0.30/0.15/0.05). Never call `codebase_context_search` or `mcp__knowledge-graph__search_memories` ad-hoc on `.athanor/*` artifacts.

3. **Vocabulary is closed**. New service / symptom-category / mcp-pattern terms route to `.athanor/_state/pending-vocab-additions.json` for HITL via `/athanor vocab-extend`. Never invent vocabulary mid-session.

4. **Read first**: `.Codex/skills/athanor-protocol/SKILL.md` is binding before any KB op. The other skills (`athanor-recall`, `distill-session`, `athanor-learn`) are operational guides.

### Auto-orchestration (you, the agent)

- User mentions investigation language OR a known service name → invoke `athanor-recall` skill BEFORE responding. Cite recalled paths inline. Do NOT bulk-Read all results.
- User uses an explicit learn/capture trigger ("learn this", "add to my brain", "memorize", "remember", "note that", "important", "for future reference", "key insight", "capture this") → follow `athanor-learn` skill: extract → stage via wrappers → run kb-learn-commit.sh (full pipeline: graph + qdrant + digest + supervisor). Confirm in one line.
- All other prompts → behave normally.
- Never ask the user to invoke skills/agents/commands. The system invokes them; the user just talks.
- The only user-facing command is `/athanor` (dashboard + admin). All other commands under `.Codex/commands/_internal/` are agent-only.

### What runs automatically (you don't trigger these)

- `SessionStart` hook injects ≤100 tokens (KB stats + recall hint + 1 pending HITL inline)
- `Stop` hook (async) backs up transcript and spawns the `session-distiller` subagent
- `PreCompact` hook (async) backs up transcript before compaction
- `UserPromptSubmit` hook detects investigation/capture intent and emits orchestration hints
- `PostToolUse` hook detects wrapper bypass and trips the kill switch on threshold breach

### Forbidden

- ❌ Calling `mcp__knowledge-graph__create_entities|create_relations|add_observations` without first getting `ok:` from the corresponding wrapper
- ❌ Inventing vocabulary terms (route to HITL instead)
- ❌ Changing recall weights
- ❌ Telling the user to invoke `/distill`, `/athanor validate`, `/promote-skill` directly — those are `_internal/`
- ❌ Reading the entire `protocol/` for context — load only what you need

### Protocol spec (committed, repo root)

| Path | Purpose |
|---|---|
| `protocol/` | Spec — schemas, vocabulary, recall algorithm, golden fixtures (read first). Committed dir, NOT under `.athanor/`, so a fresh clone has vocabulary and write-gates work. |

### KB layout (gitignored under `.athanor/`)

| Path | Purpose |
|---|---|
| `raw/` | Transcript copies, one per session |
| `distilled/sessions/` | Per-session digests |
| `runbooks/<svc>/<sym>.md` | Accumulated runbooks |
| `local-skills/<n>/SKILL.md` | WIP local skills |
| `memory/` | Typed memory entries |
| `_state/` | Cursors, ledgers, audit logs, HITL queue, kill-switch, health-score |
| `_staging/<sid>/` | Pre-commit manifests |
| `_quarantine/` | Rejected manifests |
| `_eval/` | Tier 1 + Tier 2 datasets, scripts, run history |

For the full design rationale, read `DESIGN.md`. For protocol contract, `protocol/PROTOCOL.md`.

## Skill / Agent / Command Creation

All skills, agents, and commands for athanor live in this repo under `.Codex/`. New ones go in the same place. For when to create which (skill vs agent vs command) and how, see the "Extending" section in [README.md](README.md). Model on existing artifacts in `.Codex/skills/`, `.Codex/agents/`, `.Codex/commands/` — they ARE the reference.

## Scratch Files

During live sessions, any new files or investigation notes go to `memory_bank/` (gitignored). Never create new directories at the repo root. The distiller extracts knowledge from the transcript, not from files — scratch files are ephemeral.

## Domain-Specific Configuration (Optional)

For your environment's codebases, MCP tools, and conventions, create a `Codex.local.md`
in this directory (gitignored). Model it on `Codex.example.md`. Codex will NOT
auto-load it — add an @import reference or paste relevant sections here.
