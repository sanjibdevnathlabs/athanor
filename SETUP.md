# Athanor Setup Guide

Get from zero to running in ~15 minutes.

## Prerequisites

| Dependency | Purpose | Default address |
|---|---|---|
| Neo4j | Knowledge graph (entities, relations, observations) | `bolt://localhost:7687` |
| Qdrant | Vector search (default driver; reached directly over REST) | `http://localhost:6333` |
| Ollama | Embeddings (called directly by the in-repo `vec` layer) | `http://localhost:11434` |
| Python 3.10+ | Runs the in-repo vector layer (`vec` package; auto-venv) | — |
| Claude Code CLI | Hook execution, MCP tool routing | — |

The vector half of athanor is **in-repo Python** (`.claude/hooks/lib/vec/`), driver-based
(Qdrant today, ChromaDB pluggable). There is no SocratiCode and no vector MCP — athanor
talks to Qdrant and Ollama directly. Configure it in `protocol/vector.config`.

### Neo4j

```bash
# Docker (quickest)
docker run -d \
  --name neo4j \
  -p 7474:7474 -p 7687:7687 \
  -e NEO4J_AUTH=neo4j/your-password \
  neo4j:5

# Or install natively: https://neo4j.com/docs/operations-manual/current/installation/
```

### Qdrant

```bash
docker run -d \
  --name qdrant \
  -p 6333:6333 \
  qdrant/qdrant
```

### Ollama

```bash
# macOS
brew install ollama
ollama serve &

# Pull the embedding model set in protocol/vector.config (VEC_EMBED_MODEL).
# The model is configurable, not pinned — change it there (then rebuild) anytime.
# Default:
ollama pull qwen3-embedding:0.6b
```

### Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code
```

---

## MCP Server Setup

### 1. knowledge-graph

Wraps Neo4j with MCP-compatible tools (`mcp__knowledge-graph__create_entities`, `search_memories`, etc.).

```bash
# Option 1: Use the included Python MCP server (recommended)
cd /path/to/athanor/../mcp-neo4j  # or wherever your neo4j MCP lives
pip install -e .
# Then configure command in .mcp.json as: uvx mcp-neo4j-memory OR python -m mcp_neo4j_memory

# Option 2: npm package (verify package name for your registry)
# npm install -g @modelcontextprotocol/server-neo4j
```

Register globally (`~/.claude/mcp.json`) or per-project (`.mcp.json`):

```json
{
  "mcpServers": {
    "knowledge-graph": {
      "command": "uvx",
      "args": ["mcp-neo4j-memory"],
      "env": {
        "NEO4J_URI": "bolt://localhost:7687",
        "NEO4J_USERNAME": "neo4j",
        "NEO4J_PASSWORD": "your-password"
      }
    }
  }
}
```

> **Note for project-local config:** This repo ships `.mcp.json` as a stub with placeholder values.
> Edit it directly (replace `_TODO` placeholders) OR delete it and use your global `~/.claude/mcp.json`.
> Claude Code reads the project-local file first; leaving the stub in place prevents the MCP from loading.

knowledge-graph is the **only** MCP athanor needs. The vector layer is not an MCP.

## Vector Layer Setup (in-repo, no MCP)

The vector layer lives at `.claude/hooks/lib/vec/` and is driven by `vec.sh`, which
owns a self-bootstrapping virtualenv (single dependency: `httpx`). Configure it in
`protocol/vector.config`:

```
VEC_DRIVER=qdrant                 # qdrant (live) | chromadb (stub)
VEC_COLLECTION=athanor_kb
VEC_DISTANCE=Cosine
VEC_QDRANT_URL=http://localhost:6333
VEC_EMBED_PROVIDER=ollama
VEC_EMBED_URL=http://localhost:11434
VEC_EMBED_MODEL=qwen3-embedding:0.6b   # any model your provider serves — configurable
```

Every key is overridable by an env var of the same name (env > file > built-in default).

One-time bootstrap + first build of the index:

```bash
# 1. Bootstrap the venv and confirm Qdrant + Ollama are reachable.
bash .claude/hooks/lib/vec.sh health

# 2. Capture existing on-disk digests/runbooks/skills into the immutable corpus,
#    then build the Qdrant collection from it (--rebuild drops any existing collection).
bash .claude/hooks/lib/kb-reindex.sh --backfill --rebuild
```

After this, `session-stop.sh` (distill) and the live "learn this" path keep the index
current automatically via `kb-index.sh`. The corpus (`.athanor/corpus/*.ndjson`) is the
durable, DB-independent backup — to switch driver or embedding model later, edit
`vector.config` and re-run `kb-reindex.sh --rebuild`.

---

## Verify It Works

Run these checks before opening Claude Code:

```bash
# Neo4j
cypher-shell -u neo4j -p your-password "RETURN 1"
# Expected: 1 row

# Qdrant
curl -s localhost:6333/collections | jq .
# Expected: {"result":{"collections":[...]}}

# Ollama
ollama list
# Expected: the model in protocol/vector.config (e.g. qwen3-embedding:0.6b)

# Vector layer (after venv bootstrap)
bash .claude/hooks/lib/vec.sh health
# Expected: driver(qdrant): OK ... ; embed(ollama): OK ...
```

Then open Claude Code in this directory and run:

```
/athanor
```

Expected output: KB stats panel (entities, relations, sessions distilled). If you see zeros — that's normal for a fresh install. The graph populates as you use it.

### Index Context Artifacts

Athanor's recall retrieves past runbooks, sessions, and skills from the vector DB.
On first run, build the index from the corpus (see "Vector Layer Setup" above):

```bash
bash .claude/hooks/lib/kb-reindex.sh --backfill --rebuild
```

After that it stays current automatically — the session-stop hook (and the live
"learn this" path) call `kb-index.sh` after each distillation/capture.

---

## HITL Queue

Athanor routes uncertain decisions to a human-in-the-loop queue. Items appear when:
- The supervisor flags a potentially hallucinated entity
- A novel vocabulary term is proposed
- The kill switch is tripped
- A distillation fails 3 times (max retries)

Review the queue with `/athanor review`. Each item shows:
- `vocab_extension` — proposed new vocabulary term; approve to add to `protocol/vocabulary/`
- `supervisor_rejection` — entity flagged as wrong; approve to prune from graph
- `adversarial_finding` — supervisor found evidence of hallucination
- `kill_switch_trip` — auto-commit was disabled; approve to re-enable

Items must be resolved before the affected session's knowledge is committed.

---

## First Run

1. Open Claude Code: `claude` from this directory
2. The `.athanor/` runtime directory is auto-created on first session
3. Hooks in `.claude/hooks/` fire automatically — nothing to invoke manually
4. Just start talking. Investigate something, describe a symptom, mention a service name
5. The `UserPromptSubmit` hook detects investigation language and injects a mandatory recall plan — relevant past findings appear in your response context automatically
6. After session ends, `session-stop.sh` spawns the distiller subagent to extract KB artifacts

---

## Directory Layout: Committed vs Gitignored

| Path | Status | Contents |
|---|---|---|
| `.claude/` | committed | Hooks, agents, commands, skills, settings |
| `protocol/` | committed | Schema, vocabulary, recall algorithm, golden fixtures |
| `DESIGN.md`, `SETUP.md`, `README.md` | committed | Documentation |
| `.athanor/` | gitignored | Sessions, graph staging, quarantine, eval runs |
| `memory_bank/` | gitignored | Scratch files written during live sessions |

`protocol/` is the spec contract — it must exist on a fresh clone so the write-gate wrappers have vocabulary to validate against. Everything under `.athanor/` is runtime state — per-clone, never shared.

---

## Troubleshooting

**`/athanor` shows "KB unreachable"** — Neo4j not running or wrong credentials in `.mcp.json`.

**Hooks don't fire** — Check `.claude/settings.json` has `hooks` block. Re-run `claude` from the repo root (not a parent dir).

**Recall returns no vector hits** — Qdrant empty on first run, or collection not built. Run `bash .claude/hooks/lib/kb-reindex.sh --backfill --rebuild`. Check reachability with `bash .claude/hooks/lib/vec.sh health`.

**`vec.sh` errors / venv issues** — Delete `.claude/hooks/lib/vec/.venv` and re-run any `vec.sh` command; it rebuilds the venv. Needs Python 3.10+ on PATH (override with `VEC_PYTHON=/path/to/python3`).

**Embedding-model drift warning in recall** — `vector.config` model differs from the model the collection was built with (`.athanor/_state/embeddings.lock`). Run `kb-reindex.sh --rebuild` to re-embed everything with the new model.

**Distiller/index fails silently** — Check `.athanor/_state/hook-errors.jsonl`. Most common cause: Ollama or Qdrant not running when `kb-index.sh` tries to embed/upsert. The corpus still captured the write — a later `kb-reindex.sh` replays it.
