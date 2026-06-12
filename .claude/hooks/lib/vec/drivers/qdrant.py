"""Qdrant driver — direct REST via httpx (no qdrant-client / grpc dependency).

The live name (`VEC_COLLECTION`, e.g. `athanor_kb`) is a Qdrant **alias**, not a
physical collection. Physical collections are named `<live>__<ts>`. This is what
makes rebuilds safe:

  - `rebuild()` builds a brand-new physical collection, fully populates it, then
    atomically repoints the alias and deletes the old physical. The live alias
    never points at a half-built or mid-dropped collection, so a killed or
    concurrent rebuild can never wedge readers. (The earlier deadlock came from
    `drop → create` on the live name; that path no longer exists.)
  - reads/writes (`search`, `upsert`, `count`, `delete`) target the alias name;
    Qdrant resolves the alias to the current physical collection.

Point id is a UUID5 derived from the corpus doc_id so re-upserting the same
logical document replaces its point.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

import httpx

from .base import Driver, Hit, Point

_NS = uuid.UUID("a7480000-0000-4000-8000-000000000001")

# Fail fast: a hung Qdrant should error in seconds, not block a hook for a minute.
DEFAULT_TIMEOUT = 20.0
WEDGE_PROBE_TIMEOUT = 5.0


def point_uuid(doc_id: str) -> str:
    return str(uuid.uuid5(_NS, doc_id))


class QdrantDriver(Driver):
    def __init__(self, url: str, collection: str, api_key: str = "") -> None:
        self.url = url.rstrip("/")
        self.live = collection  # alias name
        self.collection = collection  # alias name used for read/write paths
        headers = {"api-key": api_key} if api_key else {}
        self._c = httpx.Client(timeout=DEFAULT_TIMEOUT, headers=headers)

    # ---------- low-level ----------

    def _u(self, path: str) -> str:
        return f"{self.url}{path}"

    def _physical_name(self) -> str:
        ts = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f")
        return f"{self.live}__{ts}"

    def _all_collections(self, timeout: float = DEFAULT_TIMEOUT) -> list[str]:
        r = self._c.get(self._u("/collections"), timeout=timeout)
        if r.status_code != 200:
            return []
        return [c["name"] for c in r.json().get("result", {}).get("collections", [])]

    def _resolve_alias(self) -> str | None:
        """Physical collection the live alias points to, or None if no alias."""
        r = self._c.get(self._u(f"/collections/{self.live}/aliases"))
        if r.status_code == 200:
            for a in r.json().get("result", {}).get("aliases", []):
                if a.get("alias_name") == self.live:
                    return a.get("collection_name")
        # Fallback: cluster-wide alias listing
        r = self._c.get(self._u("/aliases"))
        if r.status_code == 200:
            for a in r.json().get("result", {}).get("aliases", []):
                if a.get("alias_name") == self.live:
                    return a.get("collection_name")
        return None

    def _exists(self, name: str) -> bool:
        return self._c.get(self._u(f"/collections/{name}")).status_code == 200

    def _dim_of(self, name: str) -> int | None:
        r = self._c.get(self._u(f"/collections/{name}"))
        if r.status_code != 200:
            return None
        try:
            return int(r.json()["result"]["config"]["params"]["vectors"]["size"])
        except (KeyError, TypeError, ValueError):
            return None

    def _create_physical(self, name: str, dim: int, distance: str) -> None:
        r = self._c.put(
            self._u(f"/collections/{name}"),
            json={"vectors": {"size": dim, "distance": distance}},
        )
        if r.status_code not in (200, 201):
            raise RuntimeError(f"qdrant create '{name}' failed ({r.status_code}): {r.text[:200]}")

    def _drop_physical(self, name: str) -> None:
        r = self._c.delete(self._u(f"/collections/{name}"))
        if r.status_code not in (200, 404):
            raise RuntimeError(f"qdrant drop '{name}' failed ({r.status_code}): {r.text[:200]}")

    def _upsert_to(self, name: str, points: list[Point]) -> int:
        if not points:
            return 0
        body = {
            "points": [
                {"id": point_uuid(p.id), "vector": p.vector, "payload": p.payload}
                for p in points
            ]
        }
        r = self._c.put(self._u(f"/collections/{name}/points?wait=true"), json=body)
        if r.status_code not in (200, 201):
            raise RuntimeError(f"qdrant upsert '{name}' failed ({r.status_code}): {r.text[:200]}")
        return len(points)

    def _swap_alias(self, new_physical: str, had_alias: bool) -> None:
        actions: list[dict] = []
        if had_alias:
            actions.append({"delete_alias": {"alias_name": self.live}})
        actions.append(
            {"create_alias": {"collection_name": new_physical, "alias_name": self.live}}
        )
        r = self._c.post(self._u("/collections/aliases"), json={"actions": actions})
        if r.status_code not in (200, 201):
            raise RuntimeError(f"qdrant alias swap failed ({r.status_code}): {r.text[:200]}")

    # ---------- interface ----------

    def health(self) -> tuple[bool, str]:
        try:
            r = self._c.get(self._u("/healthz"), timeout=WEDGE_PROBE_TIMEOUT)
            if r.status_code != 200:
                return False, f"qdrant /healthz responded {r.status_code}"
        except httpx.HTTPError as e:
            return False, f"qdrant unreachable at {self.url}: {e}"
        # healthz can pass while the collections subsystem is wedged on a lock.
        try:
            self._c.get(self._u("/collections"), timeout=WEDGE_PROBE_TIMEOUT)
        except httpx.HTTPError:
            return (
                False,
                f"qdrant /healthz OK but /collections is not responding at {self.url} "
                f"— the collection subsystem may be wedged; restart Qdrant.",
            )
        return True, f"qdrant up at {self.url}"

    def ensure(self, dim: int, distance: str) -> None:
        """Ensure the live alias exists and points at a physical collection of the
        right dim. Bootstraps the alias on first use; never drops the live data."""
        phys = self._resolve_alias()
        if phys is not None:
            existing = self._dim_of(phys)
            if existing is not None and existing != dim:
                raise RuntimeError(
                    f"alias '{self.live}' → '{phys}' has dim {existing}, configured "
                    f"model produces dim {dim}. Run kb-reindex.sh --rebuild."
                )
            return
        # No alias yet. If a plain (pre-alias) collection occupies the live name,
        # rebuild() handles the migration; for a bare ensure we bootstrap a fresh
        # physical + alias (only when the name is free).
        if self._exists(self.live):
            # A real collection squats the live name (legacy). Leave it for
            # rebuild() to migrate — ensure() must not drop live data.
            return
        new_phys = self._physical_name()
        self._create_physical(new_phys, dim, distance)
        self._swap_alias(new_phys, had_alias=False)

    def rebuild(self, dim: int, distance: str, points: list[Point]) -> int:
        # 1. Build + populate a fresh physical collection. Live name untouched.
        new_phys = self._physical_name()
        self._create_physical(new_phys, dim, distance)
        self._upsert_to(new_phys, points)

        # 2. Atomically cut the live name over to it.
        alias_target = self._resolve_alias()
        if alias_target is not None:
            self._swap_alias(new_phys, had_alias=True)
            if alias_target != new_phys:
                self._drop_physical(alias_target)  # discard old physical
        elif self._exists(self.live):
            # Legacy migration: a real collection squats the live name. The new
            # physical is already fully built, so the cutover is sub-second.
            self._drop_physical(self.live)
            self._swap_alias(new_phys, had_alias=False)
        else:
            self._swap_alias(new_phys, had_alias=False)

        # 3. Reclaim any other stragglers from past interrupted rebuilds.
        self.prune_orphans()
        return len(points)

    def prune_orphans(self) -> int:
        live_phys = self._resolve_alias()
        deleted = 0
        for name in self._all_collections():
            if name.startswith(f"{self.live}__") and name != live_phys:
                try:
                    self._drop_physical(name)
                    deleted += 1
                except RuntimeError:
                    pass
        return deleted

    def drop(self) -> None:
        """Full teardown: drop the live physical + alias. Not used by rebuild."""
        phys = self._resolve_alias()
        if phys is not None:
            r = self._c.post(
                self._u("/collections/aliases"),
                json={"actions": [{"delete_alias": {"alias_name": self.live}}]},
            )
            if r.status_code not in (200, 201, 404):
                raise RuntimeError(f"qdrant alias delete failed ({r.status_code}): {r.text[:200]}")
            self._drop_physical(phys)
        elif self._exists(self.live):
            self._drop_physical(self.live)

    def upsert(self, points: list[Point]) -> int:
        return self._upsert_to(self.live, points)

    def delete(self, ids: list[str]) -> int:
        if not ids:
            return 0
        body = {"points": [point_uuid(i) for i in ids]}
        r = self._c.post(self._u(f"/collections/{self.live}/points/delete?wait=true"), json=body)
        if r.status_code not in (200, 201):
            raise RuntimeError(f"qdrant delete failed ({r.status_code}): {r.text[:200]}")
        return len(ids)

    def search(
        self, vector: list[float], k: int, artifact: str | None = None
    ) -> list[Hit]:
        body: dict = {"vector": vector, "limit": k, "with_payload": True}
        if artifact:
            body["filter"] = {"must": [{"key": "artifact", "match": {"value": artifact}}]}
        r = self._c.post(self._u(f"/collections/{self.live}/points/search"), json=body)
        if r.status_code != 200:
            raise RuntimeError(f"qdrant search failed ({r.status_code}): {r.text[:200]}")
        return [
            Hit(id=str(i.get("id")), score=float(i.get("score", 0.0)), payload=i.get("payload") or {})
            for i in r.json().get("result", [])
        ]

    def count(self) -> int:
        if not (self._resolve_alias() or self._exists(self.live)):
            return 0
        r = self._c.post(self._u(f"/collections/{self.live}/points/count"), json={"exact": True})
        if r.status_code != 200:
            return 0
        try:
            return int(r.json()["result"]["count"])
        except (KeyError, TypeError, ValueError):
            return 0
