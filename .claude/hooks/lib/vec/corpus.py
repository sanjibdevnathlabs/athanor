"""Corpus — the append-only, immutable, self-contained backup.

This is athanor's source of truth for the vector layer. Every record carries the
FULL content (not a pointer), so the corpus survives deletion of .athanor/distilled
markdown, Qdrant going away, or a driver swap. The vector DB is rebuildable from
this file alone.

Invariants:
  - Append-only. Records are NEVER edited or deleted in place.
  - A logical document is identified by `doc_id` = sha256(artifact:source_path).
  - Editing a doc appends a NEW record (same doc_id, new content_hash, supersedes
    the prior record id). Deleting appends an op:"delete" tombstone.
  - Records are versioned by `created_at_ms`; latest wins at index/reindex time.
  - Re-appending identical content (same doc_id + content_hash as the current
    latest) is a no-op — keeps the corpus from growing on repeated backfills.

Sharded by month: corpus/YYYY-MM.ndjson.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

CORPUS_VERSION = "v1"


def doc_id(artifact: str, source_path: str) -> str:
    return hashlib.sha256(f"{artifact}:{source_path}".encode("utf-8")).hexdigest()


def content_hash(content: str) -> str:
    return "sha256:" + hashlib.sha256(content.encode("utf-8")).hexdigest()


def _now_ms() -> int:
    return int(time.time() * 1000)


def _rand6() -> str:
    return os.urandom(3).hex()


@dataclass
class Record:
    id: str
    doc_id: str
    artifact: str
    source_path: str
    content: str
    content_hash: str
    embedding_model: str
    corpus_version: str
    created_at_ms: int
    created_at: str
    supersedes: str | None
    op: str  # "upsert" | "delete"

    @classmethod
    def from_json(cls, d: dict) -> "Record":
        return cls(
            id=d["id"],
            doc_id=d["doc_id"],
            artifact=d["artifact"],
            source_path=d["source_path"],
            content=d.get("content", ""),
            content_hash=d.get("content_hash", ""),
            embedding_model=d.get("embedding_model", ""),
            corpus_version=d.get("corpus_version", CORPUS_VERSION),
            created_at_ms=int(d["created_at_ms"]),
            created_at=d.get("created_at", ""),
            supersedes=d.get("supersedes"),
            op=d.get("op", "upsert"),
        )

    def to_json(self) -> dict:
        return {
            "id": self.id,
            "doc_id": self.doc_id,
            "artifact": self.artifact,
            "source_path": self.source_path,
            "content": self.content,
            "content_hash": self.content_hash,
            "embedding_model": self.embedding_model,
            "corpus_version": self.corpus_version,
            "created_at_ms": self.created_at_ms,
            "created_at": self.created_at,
            "supersedes": self.supersedes,
            "op": self.op,
        }


class Corpus:
    def __init__(self, corpus_dir: Path, embedding_model: str) -> None:
        self.dir = corpus_dir
        self.embedding_model = embedding_model

    # ---- read ----

    def _shards(self) -> list[Path]:
        if not self.dir.is_dir():
            return []
        return sorted(self.dir.glob("*.ndjson"))

    def iter_records(self) -> Iterator[Record]:
        """Yield all records across shards in created_at_ms order."""
        records: list[Record] = []
        for shard in self._shards():
            for line in shard.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(Record.from_json(json.loads(line)))
                except (json.JSONDecodeError, KeyError):
                    continue
        records.sort(key=lambda r: (r.created_at_ms, r.id))
        yield from records

    def fold_latest(self) -> list[Record]:
        """Collapse to the latest record per doc_id; drop tombstoned docs."""
        latest: dict[str, Record] = {}
        for r in self.iter_records():
            latest[r.doc_id] = r
        return [r for r in latest.values() if r.op != "delete"]

    def _latest_for(self, did: str) -> Record | None:
        found: Record | None = None
        for r in self.iter_records():
            if r.doc_id == did:
                found = r
        return found

    # ---- write (append-only) ----

    def _shard_path(self) -> Path:
        month = datetime.now(timezone.utc).strftime("%Y-%m")
        return self.dir / f"{month}.ndjson"

    def append(
        self, artifact: str, source_path: str, content: str, op: str = "upsert"
    ) -> Record | None:
        """Append a record. Returns the new Record, or None if it was a no-op
        (identical to the current latest)."""
        did = doc_id(artifact, source_path)
        chash = content_hash(content)
        prev = self._latest_for(did)
        if prev is not None and prev.op == op and prev.content_hash == chash:
            return None  # unchanged — do not grow the corpus

        ms = _now_ms()
        rec = Record(
            id=f"{ms}-{_rand6()}",
            doc_id=did,
            artifact=artifact,
            source_path=source_path,
            content=content,
            content_hash=chash,
            embedding_model=self.embedding_model,
            corpus_version=CORPUS_VERSION,
            created_at_ms=ms,
            created_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            supersedes=prev.id if prev is not None else None,
            op=op,
        )
        self.dir.mkdir(parents=True, exist_ok=True)
        with self._shard_path().open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec.to_json(), ensure_ascii=False) + "\n")
        return rec

    def tombstone(self, artifact: str, source_path: str) -> Record | None:
        return self.append(artifact, source_path, content="", op="delete")
