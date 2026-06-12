"""Embedding — text -> vector.

Athanor owns embedding now. The model is whatever vector.config / env says; this
module just calls the configured provider. Only `ollama` is implemented; add a
branch here to support another provider.

Ollama exposes two endpoints across versions:
  - POST /api/embed        {model, input}        -> {"embeddings": [[...]]}   (newer)
  - POST /api/embeddings   {model, prompt}       -> {"embedding": [...]}      (older)
We try the new one first, fall back to the legacy one.
"""

from __future__ import annotations

import httpx

from .config import Config


class EmbedError(RuntimeError):
    pass


def embed(text: str, cfg: Config, timeout: float = 60.0) -> list[float]:
    """Embed a single string. Returns the vector as a list[float]."""
    return embed_batch([text], cfg, timeout=timeout)[0]


def embed_batch(texts: list[str], cfg: Config, timeout: float = 120.0) -> list[list[float]]:
    """Embed many strings. Returns vectors in input order."""
    provider = cfg.get("VEC_EMBED_PROVIDER")
    if provider == "ollama":
        return _ollama_batch(texts, cfg, timeout)
    raise EmbedError(
        f"unsupported embed provider '{provider}' "
        f"(set VEC_EMBED_PROVIDER; only 'ollama' is implemented)"
    )


def _ollama_batch(texts: list[str], cfg: Config, timeout: float) -> list[list[float]]:
    base = cfg.get("VEC_EMBED_URL").rstrip("/")
    model = cfg.embed_model
    out: list[list[float]] = []
    with httpx.Client(timeout=timeout) as client:
        # Prefer the batch-capable /api/embed.
        try:
            r = client.post(f"{base}/api/embed", json={"model": model, "input": texts})
            if r.status_code == 200:
                data = r.json()
                embs = data.get("embeddings")
                if embs and len(embs) == len(texts):
                    return [[float(x) for x in v] for v in embs]
        except httpx.HTTPError:
            pass  # fall through to legacy per-item endpoint

        # Legacy /api/embeddings — one prompt per call.
        for t in texts:
            try:
                r = client.post(
                    f"{base}/api/embeddings", json={"model": model, "prompt": t}
                )
            except httpx.HTTPError as e:
                raise EmbedError(f"ollama unreachable at {base}: {e}") from e
            if r.status_code != 200:
                raise EmbedError(
                    f"ollama embed failed ({r.status_code}) for model '{model}': "
                    f"{r.text[:200]}"
                )
            emb = r.json().get("embedding")
            if not emb:
                raise EmbedError(f"ollama returned no embedding for model '{model}'")
            out.append([float(x) for x in emb])
    return out


def probe_dim(cfg: Config) -> int:
    """Embed a tiny probe to discover the model's output dimension."""
    return len(embed("dimension probe", cfg))


def health(cfg: Config) -> tuple[bool, str]:
    """Best-effort reachability check for the embedding provider."""
    base = cfg.get("VEC_EMBED_URL").rstrip("/")
    try:
        with httpx.Client(timeout=5.0) as client:
            r = client.get(f"{base}/api/tags")
            if r.status_code == 200:
                names = [m.get("name") for m in r.json().get("models", [])]
                have = cfg.embed_model in names
                msg = f"ollama up ({len(names)} models); model '{cfg.embed_model}' "
                msg += "present" if have else "NOT pulled — run: ollama pull " + cfg.embed_model
                return have, msg
            return False, f"ollama responded {r.status_code}"
    except httpx.HTTPError as e:
        return False, f"ollama unreachable at {base}: {e}"
