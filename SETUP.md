# Athanor Setup Guide

Get from zero to running in ~15 minutes.

## Prerequisites

All four must be running before athanor works.

| Dependency | Purpose | Default address |
|---|---|---|
| Neo4j | Knowledge graph (entities, relations, observations) | `bolt://localhost:7687` |
| Qdrant | Vector search (semantic code/runbook retrieval) | `http://localhost:6333` |
| Ollama | Local embeddings (required by SocratiCode) | `http://localhost:11434` |
| Claude Code CLI | Hook execution, MCP tool routing | — |

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

# Pull the embedding model SocratiCode uses
ollama pull nomic-embed-text
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

### 2. socraticode

SocratiCode is a Claude Code plugin (not a standalone npm package). Install via the Claude Code plugin marketplace:

```bash
claude plugin install socraticode
```

Or add its marketplace if it's in a private registry — see the SocratiCode README for the exact marketplace URL.

> **SocratiCode availability:** If SocratiCode is not publicly listed in the Claude Code marketplace,
> install it from its source repo or ask your administrator. The recall system degrades gracefully
> (graph-only recall) if SocratiCode is unavailable.

SocratiCode auto-discovers Qdrant at `localhost:6333` and Ollama at `localhost:11434`. No additional env vars needed for local installs.

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
# Expected: nomic-embed-text in the list
```

Then open Claude Code in this directory and run:

```
/athanor
```

Expected output: KB stats panel (entities, relations, sessions distilled). If you see zeros — that's normal for a fresh install. The graph populates as you use it.

### Index Context Artifacts

Athanor's recall system uses SocratiCode to retrieve past runbooks, sessions, and skills.
On first run, index the context artifacts:

```
/athanor
```

Then in Claude Code: invoke the `codebase_context_index` tool against the athanor root.
Or just start a session — the session-stop hook indexes artifacts automatically after the first distillation.

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

**SocratiCode search returns nothing** — Qdrant empty on first run. Index the codebase: `/socraticode:codebase-management`.

**Distiller fails silently** — Check `.athanor/_state/` for error logs. Most common cause: Ollama not running when distiller tries to embed.
