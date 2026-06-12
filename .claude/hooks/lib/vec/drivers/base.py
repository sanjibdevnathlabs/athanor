"""Vector driver interface.

A driver is the ONLY thing that knows a specific vector DB. Swap the driver
(via VEC_DRIVER) and reindex — nothing else in athanor changes. Every driver
implements these five operations against a single collection whose points carry
an `artifact` payload field for filtering.
"""

from __future__ import annotations

import abc
from dataclasses import dataclass


@dataclass
class Point:
    id: str  # stable per-doc id (UUID string derived from corpus doc_id)
    vector: list[float]
    payload: dict


@dataclass
class Hit:
    id: str
    score: float
    payload: dict


class Driver(abc.ABC):
    @abc.abstractmethod
    def health(self) -> tuple[bool, str]:
        """(reachable, human message). Never raises."""

    @abc.abstractmethod
    def ensure(self, dim: int, distance: str) -> None:
        """Create the collection if absent. Must be idempotent. Raise on dim
        mismatch with an existing collection."""

    @abc.abstractmethod
    def drop(self) -> None:
        """Delete the collection if present. Idempotent."""

    @abc.abstractmethod
    def upsert(self, points: list[Point]) -> int:
        """Insert/replace points by id. Returns count upserted."""

    @abc.abstractmethod
    def delete(self, ids: list[str]) -> int:
        """Delete points by id. Returns count requested."""

    @abc.abstractmethod
    def search(
        self, vector: list[float], k: int, artifact: str | None = None
    ) -> list[Hit]:
        """Nearest-neighbour search, optionally filtered to one artifact."""

    @abc.abstractmethod
    def count(self) -> int:
        """Number of points in the collection (0 if absent)."""

    @abc.abstractmethod
    def rebuild(self, dim: int, distance: str, points: list[Point]) -> int:
        """Full rebuild WITHOUT dropping the live collection.

        Build a fresh backing store, populate it completely, then atomically
        switch the live name over to it and discard the old one. A failure or
        kill mid-rebuild must leave the live collection untouched (callers may
        retry; orphaned backing stores are reclaimed by prune_orphans). Returns
        points upserted."""

    @abc.abstractmethod
    def prune_orphans(self) -> int:
        """Delete leftover backing stores not currently live (from interrupted
        rebuilds). Returns count deleted."""
