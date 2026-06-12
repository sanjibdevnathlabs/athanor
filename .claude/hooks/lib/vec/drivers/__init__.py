"""Driver registry. Pick a backend by name from config."""

from __future__ import annotations

from ..config import Config
from .base import Driver, Hit, Point

__all__ = ["Driver", "Hit", "Point", "make_driver", "REGISTERED"]

REGISTERED = ("qdrant", "chromadb")


def make_driver(cfg: Config) -> Driver:
    name = cfg.driver
    if name == "qdrant":
        from .qdrant import QdrantDriver

        return QdrantDriver(
            url=cfg.get("VEC_QDRANT_URL"),
            collection=cfg.collection,
            api_key=cfg.get("VEC_QDRANT_API_KEY"),
        )
    if name == "chromadb":
        from .chromadb import ChromaDBDriver

        return ChromaDBDriver(url=cfg.get("VEC_CHROMA_URL"), collection=cfg.collection)
    raise ValueError(
        f"unknown VEC_DRIVER '{name}' (registered: {', '.join(REGISTERED)})"
    )
