"""vec — athanor vector layer CLI.

Subcommands (invoked by the bash wrappers, never by the user directly):

  health              driver + embed provider reachability
  ensure              create collection (probe dim), write embeddings.lock
  lockcheck           compare config model vs built collection (drift guard)
  embed   TEXT        print a vector (debug)
  backfill            scan distilled/runbooks/skills -> corpus (no DB, no embed)
  index               sync: backfill + embed/upsert changed + prune deleted
  reindex [--rebuild] replay corpus -> DB (rebuild = drop first)
  search  --query Q   embed query, nearest-neighbour search (JSON to stdout)

Machine output (search/lockcheck) goes to stdout as JSON. Human progress goes to
stderr so it never pollutes a captured result.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from . import config as cfgmod
from . import embed as embedmod
from .corpus import Corpus, Record
from .drivers import make_driver
from .drivers.base import Point

SNIPPET_CHARS = 600
BATCH = 8
# Embedding models have a bounded context. Cap input so a large digest can't
# stall the model (the full text still lives in the corpus + payload snippet).
EMBED_MAX_CHARS = 8000


def _err(msg: str) -> None:
    print(msg, file=sys.stderr)


def _payload(rec: Record) -> dict:
    return {
        "artifact": rec.artifact,
        "source_path": rec.source_path,
        "doc_id": rec.doc_id,
        "content_hash": rec.content_hash,
        "snippet": rec.content[:SNIPPET_CHARS],
    }


# ---------- source discovery (what gets indexed) ----------

def _discover(cfg: cfgmod.Config) -> list[tuple[str, Path]]:
    """Return (artifact, absolute_path) for every indexable doc on disk."""
    out: list[tuple[str, Path]] = []
    if cfg.distilled_dir.is_dir():
        for p in sorted(cfg.distilled_dir.glob("*.md")):
            out.append(("sessions", p))
    if cfg.runbooks_dir.is_dir():
        for p in sorted(cfg.runbooks_dir.rglob("*.md")):
            out.append(("runbooks", p))
    if cfg.skills_dir.is_dir():
        for p in sorted(cfg.skills_dir.glob("*/SKILL.md")):
            out.append(("skills", p))
    return out


def _rel(cfg: cfgmod.Config, p: Path) -> str:
    try:
        return str(p.resolve().relative_to(cfg.root))
    except ValueError:
        return str(p)


# ---------- corpus sync ----------

def _backfill(cfg: cfgmod.Config, corpus: Corpus) -> tuple[list[Record], list[Record]]:
    """Append on-disk docs to the corpus + tombstone vanished docs.

    Returns (changed_upserts, tombstoned)."""
    changed: list[Record] = []
    on_disk = _discover(cfg)
    on_disk_keys = set()
    for artifact, path in on_disk:
        rel = _rel(cfg, path)
        on_disk_keys.add((artifact, rel))
        try:
            content = path.read_text(encoding="utf-8")
        except OSError:
            continue
        rec = corpus.append(artifact, rel, content, op="upsert")
        if rec is not None:
            changed.append(rec)

    # Prune: docs previously live in the corpus but whose file is now gone.
    tombstoned: list[Record] = []
    for rec in corpus.fold_latest():
        if (rec.artifact, rec.source_path) not in on_disk_keys:
            t = corpus.tombstone(rec.artifact, rec.source_path)
            if t is not None:
                tombstoned.append(t)
    return changed, tombstoned


def _embed_points(cfg: cfgmod.Config, recs: list[Record]) -> list[Point]:
    points: list[Point] = []
    total = len(recs)
    for i in range(0, total, BATCH):
        chunk = recs[i : i + BATCH]
        texts = [r.content[:EMBED_MAX_CHARS] for r in chunk]
        vectors = embedmod.embed_batch(texts, cfg)
        for r, v in zip(chunk, vectors):
            points.append(Point(id=r.doc_id, vector=v, payload=_payload(r)))
        _err(f"  embedded {min(i + BATCH, total)}/{total}")
    return points


def _write_lock(cfg: cfgmod.Config, dim: int) -> None:
    cfg.lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock = {
        "embedding_model": cfg.embed_model,
        "embedding_dim": dim,
        "distance": cfg.distance,
        "collection": cfg.collection,
        "driver": cfg.driver,
        "built_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    cfg.lock_path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")


def _read_lock(cfg: cfgmod.Config) -> dict | None:
    if not cfg.lock_path.is_file():
        return None
    try:
        return json.loads(cfg.lock_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


# ---------- commands ----------

def cmd_health(cfg: cfgmod.Config) -> int:
    drv = make_driver(cfg)
    d_ok, d_msg = drv.health()
    e_ok, e_msg = embedmod.health(cfg)
    _err(f"driver({cfg.driver}): {'OK' if d_ok else 'DOWN'} — {d_msg}")
    _err(f"embed({cfg.get('VEC_EMBED_PROVIDER')}): {'OK' if e_ok else 'WARN'} — {e_msg}")
    if d_ok:
        _err(f"collection '{cfg.collection}' points: {drv.count()}")
    return 0 if d_ok else 1


def cmd_ensure(cfg: cfgmod.Config) -> int:
    drv = make_driver(cfg)
    dim = embedmod.probe_dim(cfg)
    drv.ensure(dim, cfg.distance)
    _write_lock(cfg, dim)
    _err(f"ensured '{cfg.collection}' dim={dim} distance={cfg.distance} -> lock written")
    return 0


def cmd_lockcheck(cfg: cfgmod.Config) -> int:
    lock = _read_lock(cfg)
    if lock is None:
        print(json.dumps({"ok": True, "message": "no lock yet (fresh / not built)"}))
        return 0
    drift = lock.get("embedding_model") != cfg.embed_model
    if drift:
        msg = (
            f"collection built with '{lock.get('embedding_model')}' "
            f"but config says '{cfg.embed_model}' — run kb-reindex.sh --rebuild"
        )
    else:
        msg = f"lock OK (model {cfg.embed_model}, dim {lock.get('embedding_dim')})"
    print(json.dumps({"ok": not drift, "message": msg}))
    return 0


def cmd_embed(cfg: cfgmod.Config, text: str) -> int:
    print(json.dumps(embedmod.embed(text, cfg)))
    return 0


def cmd_backfill(cfg: cfgmod.Config) -> int:
    corpus = Corpus(cfg.corpus_dir, cfg.embed_model)
    changed, tombstoned = _backfill(cfg, corpus)
    total = len(corpus.fold_latest())
    _err(
        f"backfill: {len(changed)} new/changed, {len(tombstoned)} tombstoned, "
        f"{total} live docs in corpus ({cfg.corpus_dir})"
    )
    return 0


def cmd_index(cfg: cfgmod.Config) -> int:
    corpus = Corpus(cfg.corpus_dir, cfg.embed_model)
    changed, tombstoned = _backfill(cfg, corpus)
    if not changed and not tombstoned:
        _err("index: corpus already current — nothing to embed/upsert")
        return 0
    drv = make_driver(cfg)
    if changed:
        dim = embedmod.probe_dim(cfg)
        drv.ensure(dim, cfg.distance)
        _write_lock(cfg, dim)
        n = drv.upsert(_embed_points(cfg, changed))
        _err(f"index: upserted {n} points")
    if tombstoned:
        n = drv.delete([t.doc_id for t in tombstoned])
        _err(f"index: deleted {n} points (tombstoned)")
    return 0


def cmd_reindex(cfg: cfgmod.Config, rebuild: bool) -> int:
    corpus = Corpus(cfg.corpus_dir, cfg.embed_model)
    docs = corpus.fold_latest()
    if not docs:
        _err("reindex: corpus is empty — run backfill first")
        return 0
    drv = make_driver(cfg)
    dim = embedmod.probe_dim(cfg)
    # Embed everything BEFORE touching the DB — if embedding fails, the live
    # collection is never disturbed.
    points = _embed_points(cfg, docs)
    if rebuild:
        # Builds a fresh physical collection, then atomically swaps the alias.
        # The live name is never dropped → cannot wedge readers mid-rebuild.
        n = drv.rebuild(dim, cfg.distance, points)
        _write_lock(cfg, dim)
        _err(f"reindex: rebuilt '{cfg.collection}' via alias swap — {n} docs (dim={dim})")
    else:
        drv.ensure(dim, cfg.distance)
        n = drv.upsert(points)
        _write_lock(cfg, dim)
        _err(f"reindex: upserted {n}/{len(docs)} docs into '{cfg.collection}' (dim={dim})")
    return 0


def cmd_prune(cfg: cfgmod.Config) -> int:
    drv = make_driver(cfg)
    n = drv.prune_orphans()
    _err(f"prune: removed {n} orphan backing collection(s)")
    return 0


def _hits_json(hits) -> list[dict]:
    return [
        {
            "artifact": h.payload.get("artifact"),
            "source_path": h.payload.get("source_path"),
            "score": round(h.score, 4),
            "snippet": h.payload.get("snippet", ""),
        }
        for h in hits
    ]


def cmd_search(cfg: cfgmod.Config, query: str, k: int, artifact: str | None) -> int:
    drv = make_driver(cfg)
    vec = embedmod.embed(query, cfg)
    print(json.dumps(_hits_json(drv.search(vec, k, artifact)), ensure_ascii=False))
    return 0


# Per-artifact caps mirror the frozen recall algorithm (runbooks 5 / sessions 3 / skills 3).
RECALL_CAPS = {"runbooks": 5, "sessions": 3, "skills": 3}


def cmd_recall(cfg: cfgmod.Config, query: str) -> int:
    """One embed, three filtered searches. Output grouped by artifact.

    This is what kb-recall.sh runs inline. The query is embedded ONCE and reused
    across the three artifact filters."""
    drv = make_driver(cfg)
    vec = embedmod.embed(query, cfg)
    out = {
        artifact: _hits_json(drv.search(vec, cap, artifact))
        for artifact, cap in RECALL_CAPS.items()
    }
    print(json.dumps(out, ensure_ascii=False))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="vec", description="athanor vector layer")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("health")
    sub.add_parser("ensure")
    sub.add_parser("lockcheck")
    sub.add_parser("backfill")
    sub.add_parser("index")
    sub.add_parser("prune")

    p_embed = sub.add_parser("embed")
    p_embed.add_argument("text")

    p_reindex = sub.add_parser("reindex")
    p_reindex.add_argument("--rebuild", action="store_true")

    p_search = sub.add_parser("search")
    p_search.add_argument("--query", required=True)
    p_search.add_argument("--k", type=int, default=5)
    p_search.add_argument("--artifact", default=None)

    p_recall = sub.add_parser("recall")
    p_recall.add_argument("--query", required=True)

    args = ap.parse_args(argv)
    cfg = cfgmod.load()

    try:
        if args.cmd == "health":
            return cmd_health(cfg)
        if args.cmd == "ensure":
            return cmd_ensure(cfg)
        if args.cmd == "lockcheck":
            return cmd_lockcheck(cfg)
        if args.cmd == "embed":
            return cmd_embed(cfg, args.text)
        if args.cmd == "backfill":
            return cmd_backfill(cfg)
        if args.cmd == "index":
            return cmd_index(cfg)
        if args.cmd == "reindex":
            return cmd_reindex(cfg, args.rebuild)
        if args.cmd == "prune":
            return cmd_prune(cfg)
        if args.cmd == "search":
            return cmd_search(cfg, args.query, args.k, args.artifact)
        if args.cmd == "recall":
            return cmd_recall(cfg, args.query)
    except Exception as e:  # noqa: BLE001 — CLI boundary: surface one clean line
        _err(f"vec {args.cmd}: error: {e}")
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
