"""ChromaDB driver — STUB.

Registered so the driver abstraction is proven end-to-end, but not implemented.
Implement these five methods against the Chroma HTTP API (or chromadb client)
when you actually want to switch. Until then, selecting it fails loudly.
"""

from __future__ import annotations

from .base import Driver, Hit, Point

_MSG = (
    "chromadb driver is a stub — not yet implemented. "
    "Set VEC_DRIVER=qdrant, or implement vec/drivers/chromadb.py."
)


class ChromaDBDriver(Driver):
    def __init__(self, url: str, collection: str) -> None:
        self.url = url
        self.collection = collection

    def health(self) -> tuple[bool, str]:
        return False, _MSG

    def ensure(self, dim: int, distance: str) -> None:
        raise NotImplementedError(_MSG)

    def drop(self) -> None:
        raise NotImplementedError(_MSG)

    def upsert(self, points: list[Point]) -> int:
        raise NotImplementedError(_MSG)

    def delete(self, ids: list[str]) -> int:
        raise NotImplementedError(_MSG)

    def search(
        self, vector: list[float], k: int, artifact: str | None = None
    ) -> list[Hit]:
        raise NotImplementedError(_MSG)

    def count(self) -> int:
        raise NotImplementedError(_MSG)

    def rebuild(self, dim: int, distance: str, points: list[Point]) -> int:
        raise NotImplementedError(_MSG)

    def prune_orphans(self) -> int:
        raise NotImplementedError(_MSG)
