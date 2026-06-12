"""Configuration resolution for the athanor vector layer.

Precedence (highest first):
  1. environment variable
  2. protocol/vector.config  (committed defaults)
  3. built-in DEFAULTS below

Also resolves the repo root and the canonical KB paths so the rest of the
package never hardcodes a location.
"""

from __future__ import annotations

import os
from pathlib import Path

DEFAULTS = {
    "VEC_DRIVER": "qdrant",
    "VEC_COLLECTION": "athanor_kb",
    "VEC_DISTANCE": "Cosine",
    "VEC_QDRANT_URL": "http://localhost:6333",
    "VEC_QDRANT_API_KEY": "",
    "VEC_CHROMA_URL": "http://localhost:8000",
    "VEC_EMBED_PROVIDER": "ollama",
    "VEC_EMBED_URL": "http://localhost:11434",
    "VEC_EMBED_MODEL": "qwen3-embedding:0.6b",
}

# Artifact buckets stored in the single collection (payload-filtered).
ARTIFACTS = ("runbooks", "sessions", "skills")


def repo_root() -> Path:
    """Resolve the athanor repo root.

    CLAUDE_PROJECT_DIR wins (set by the harness). Otherwise walk up from this
    file looking for the protocol dir + .athanor marker.
    """
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env and (Path(env) / "protocol").is_dir():
        return Path(env).resolve()
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / "protocol" / "version.txt").is_file():
            return parent
    # Last resort: 4 levels up (.claude/hooks/lib/vec/config.py -> repo)
    return here.parents[4]


def _parse_config_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        out[key.strip()] = val.strip()
    return out


class Config:
    def __init__(self) -> None:
        self.root = repo_root()
        self.protocol_dir = self.root / "protocol"
        self.state_dir = Path(
            os.environ.get("KB_STATE_DIR", self.root / ".athanor" / "_state")
        )
        self.corpus_dir = Path(
            os.environ.get("KB_CORPUS_DIR", self.root / ".athanor" / "corpus")
        )
        self.distilled_dir = self.root / ".athanor" / "distilled" / "sessions"
        self.runbooks_dir = self.root / ".athanor" / "runbooks"
        self.skills_dir = self.root / ".athanor" / "local-skills"
        self.lock_path = self.state_dir / "embeddings.lock"

        file_vals = _parse_config_file(self.protocol_dir / "vector.config")
        self._vals = {}
        for key, default in DEFAULTS.items():
            self._vals[key] = os.environ.get(key, file_vals.get(key, default))

    def get(self, key: str) -> str:
        return self._vals[key]

    # convenience accessors
    @property
    def driver(self) -> str:
        return self.get("VEC_DRIVER")

    @property
    def collection(self) -> str:
        return self.get("VEC_COLLECTION")

    @property
    def distance(self) -> str:
        return self.get("VEC_DISTANCE")

    @property
    def embed_model(self) -> str:
        return self.get("VEC_EMBED_MODEL")

    def as_dict(self) -> dict[str, str]:
        # redact secrets
        d = dict(self._vals)
        if d.get("VEC_QDRANT_API_KEY"):
            d["VEC_QDRANT_API_KEY"] = "***"
        return d


def load() -> Config:
    return Config()
