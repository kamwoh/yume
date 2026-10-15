"""
ledger.py — persistent record of paid asset-gen API calls.

Every successful call to a paid backend (nanobanana, tripo3d) is
recorded in `data/<game>/.assetgen_ledger.json`. The pipeline consults
the ledger BEFORE dispatching to a backend; if the same
(backend, kind, prompt_hash) tuple is already in the ledger, the call
is skipped so we don't re-pay.

Why this exists vs. plain `skip_existing`:
    skip_existing only checks whether the OUTPUT FILE is present. If
    someone deletes/moves a .png or .glb, the next run silently re-
    pays the API. The ledger persists the "we already paid for this
    prompt" fact independently of the output file's lifecycle.

To force regeneration: delete the matching entry from the JSON file
(or delete the whole file). Editing the prompt also forces regen,
since prompt_hash changes.

Mock backend writes are NOT tracked — they're free and the smoke
test re-runs them.

Pending tasks (2026-10-16, batch B). An async backend (tripo3d) charges
at submit, then returns a task id. The ledger records that id as a
`"status": "pending"` entry and saves at once, before the first poll.
A poll error, a timeout or a crash then leaves the pending entry, and
the next run resumes that task instead of paying again. A task that
ends `failed` or `cancelled` is dropped, because the provider refunds
it. `TaskSlot` wraps one pending key for a backend.
"""

import hashlib
import json
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path


LEDGER_FILENAME = ".assetgen_ledger.json"

# Backends whose calls cost real money / quota and should be tracked.
# `gemini_image` is the alias for nanobanana in the registry.
PAID_BACKENDS = frozenset({
    "nanobanana", "gemini_image", "imagen", "openai_images", "gpt_image", "tripo3d",
})

# Registry aliases of one API. A call recorded under one name also hits
# under the other.
_ALIASES = ({"nanobanana", "gemini_image"}, {"openai_images", "gpt_image"})


def _match_set(backend: str) -> set:
    for group in _ALIASES:
        if backend in group:
            return group
    return {backend}


def is_paid_backend(name: str) -> bool:
    return name in PAID_BACKENDS


def prompt_hash(text: str) -> str:
    """Stable hash of the assembled prompt. Includes 'sha256:' prefix
    so a future hash-algo migration can detect old entries."""
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


@dataclass
class Ledger:
    path: Path
    entries: list[dict] = field(default_factory=list)
    _dirty: bool = False

    def has(
        self,
        backend: str,
        kind: str,
        p_hash: str,
        *,
        discriminator: str | None = None,
    ) -> dict | None:
        """Return the first matching entry, or None. Skip key is
        (backend, kind, prompt_hash[, discriminator]).

        `discriminator` is an optional extra dimension for paid call
        chains where (backend, kind, prompt_hash) alone isn't unique.
        Animation pipeline (ADR 0053) uses it to encode rig_type, clip
        id, rig_model_version so cached REJECT/SUCCESS verdicts are
        properly partitioned. Format: "<rig_type>:<rig_model_ver>" for
        rig + prerigcheck, "<rig_type>:<clip>:<rig_model_ver>" for
        retarget. A None discriminator only matches entries that ALSO
        have no discriminator (i.e. existing pre-animation entries).
        """
        for e in self._matches(backend, kind, p_hash, discriminator):
            if e.get("status") != "pending":
                return e
        return None

    def pending(
        self, backend: str, kind: str, p_hash: str, *, discriminator: str | None = None
    ) -> dict | None:
        """Return the pending (submitted, not finished) entry for this key."""
        for e in self._matches(backend, kind, p_hash, discriminator):
            if e.get("status") == "pending":
                return e
        return None

    def add_pending(
        self, *, backend: str, kind: str, entity_id: str, prompt: str, p_hash: str,
        task_id: str, discriminator: str | None = None,
    ) -> None:
        """Record a submitted task. add() saves at once."""
        self.drop_pending(backend, kind, p_hash, discriminator=discriminator)
        self.add(
            backend=backend, kind=kind, entity_id=entity_id, prompt=prompt,
            p_hash=p_hash, out_path="", discriminator=discriminator,
            extra={"status": "pending", "task_id": task_id},
        )

    def drop_pending(
        self, backend: str, kind: str, p_hash: str, *, discriminator: str | None = None
    ) -> None:
        keep = [
            e for e in self.entries
            if not (e.get("status") == "pending"
                    and e in self._matches(backend, kind, p_hash, discriminator))
        ]
        if len(keep) != len(self.entries):
            self.entries = keep
            self._dirty = True

    def slot(
        self, *, backend: str, kind: str, entity_id: str, prompt: str, p_hash: str,
        discriminator: str | None = None,
    ) -> "TaskSlot":
        return TaskSlot(self, backend, kind, entity_id, prompt, p_hash, discriminator)

    def _matches(self, backend, kind, p_hash, discriminator) -> list[dict]:
        names = _match_set(backend)
        return [
            e for e in self.entries
            if e.get("backend") in names
            and e.get("kind") == kind
            and e.get("prompt_hash") == p_hash
            and e.get("discriminator") == discriminator
        ]

    def add(
        self,
        *,
        backend: str,
        kind: str,
        entity_id: str,
        prompt: str,
        p_hash: str,
        out_path: str,
        discriminator: str | None = None,
        extra: dict | None = None,
    ) -> None:
        entry = {
            "timestamp": _utc_now_iso(),
            "backend": backend,
            "kind": kind,
            "entity_id": entity_id,
            "prompt_hash": p_hash,
            "prompt": prompt,
            "out_path": out_path,
        }
        if discriminator is not None:
            entry["discriminator"] = discriminator
        if extra:
            entry.update(extra)
        if entry.get("status") != "pending":
            self.drop_pending(backend, kind, p_hash, discriminator=discriminator)
        self.entries.append(entry)
        self._dirty = True
        # Save per call. A crash later in a batch must not lose the record
        # of a paid call. Before batch B (2026-10-16), callers saved only
        # at the end of a batch.
        self.save()

    def save(self) -> None:
        if not self._dirty:
            return
        doc = {
            "_comment": (
                "Auto-managed by tools.yume_assetgen. Tracks paid API "
                "calls (all paid backends) so re-runs don't regenerate. "
                "To force regen: delete the matching entry (or this "
                "whole file). Editing the prompt also triggers regen "
                "since prompt_hash changes."
            ),
            "version": 1,
            "entries": self.entries,
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Write a temp file, then rename it, so a crash mid-write never
        # leaves a cut ledger (load_ledger reads a broken file as empty).
        tmp = self.path.with_name(self.path.name + ".tmp")
        tmp.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(tmp, self.path)
        self._dirty = False


@dataclass
class TaskSlot:
    """One pending-task key in the ledger, for an async paid backend.

    get() returns the task id of an earlier submit, or None. put() records
    a new submit and saves. drop() deletes the pending entry (the task
    ended failed or cancelled, so the provider refunded it)."""

    ledger: Ledger
    backend: str
    kind: str
    entity_id: str
    prompt: str
    p_hash: str
    discriminator: str | None = None

    def get(self) -> str | None:
        e = self.ledger.pending(self.backend, self.kind, self.p_hash,
                                discriminator=self.discriminator)
        return e.get("task_id") if e else None

    def put(self, task_id: str) -> str:
        self.ledger.add_pending(
            backend=self.backend, kind=self.kind, entity_id=self.entity_id,
            prompt=self.prompt, p_hash=self.p_hash, task_id=task_id,
            discriminator=self.discriminator,
        )
        return task_id

    def drop(self) -> None:
        self.ledger.drop_pending(self.backend, self.kind, self.p_hash,
                                 discriminator=self.discriminator)
        self.ledger.save()


def load_ledger(game_dir: Path) -> Ledger:
    """Load (or initialize empty) the per-game ledger at
    `<game_dir>/.assetgen_ledger.json`."""
    p = game_dir / LEDGER_FILENAME
    if not p.exists():
        return Ledger(path=p)
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return Ledger(path=p)
    entries = doc.get("entries", []) if isinstance(doc, dict) else []
    return Ledger(path=p, entries=list(entries))
