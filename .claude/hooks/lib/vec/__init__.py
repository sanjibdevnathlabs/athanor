"""athanor vector layer — driver-based, DB-independent, replayable.

SocratiCode is gone. This package is the entire vector half of athanor's KB:

  config   — resolve VEC_* settings (env > protocol/vector.config > default)
  embed    — turn text into vectors (Ollama; provider-pluggable)
  corpus   — append-only, immutable, self-contained NDJSON backup (source of truth)
  drivers  — vector DB backends behind one interface (qdrant live, chromadb stub)
  cli      — command surface invoked by the bash wrappers

The corpus is the durable, DB-independent record. The vector DB is a disposable
materialized view: drop it, swap the driver, change the embedding model — then
`reindex` replays the corpus to rebuild it.
"""
