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
"""

import hashlib
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path


LEDGER_FILENAME = ".assetgen_ledger.json"

# Backends whose calls cost real money / quota and should be tracked.
# `gemini_image` is the alias for nanobanana in the registry.
PAID_BACKENDS = frozenset({"nanobanana", "gemini_image", "tripo3d"})


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
        # Treat nanobanana ↔ gemini_image as equivalent so a prior
        # call recorded under one alias still hits under the other.
        equivalents = {"nanobanana", "gemini_image"}
        match_set = equivalents if backend in equivalents else {backend}
        for e in self.entries:
            if (
                e.get("backend") in match_set
                and e.get("kind") == kind
                and e.get("prompt_hash") == p_hash
                and e.get("discriminator") == discriminator
            ):
                return e
        return None

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
        self.entries.append(entry)
        self._dirty = True

    def save(self) -> None:
        if not self._dirty:
            return
        doc = {
            "_comment": (
                "Auto-managed by tools.yume_assetgen. Tracks paid API "
                "calls (nanobanana, tripo3d) so re-runs don't regenerate. "
                "To force regen: delete the matching entry (or this "
                "whole file). Editing the prompt also triggers regen "
                "since prompt_hash changes."
            ),
            "version": 1,
            "entries": self.entries,
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(
            json.dumps(doc, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        self._dirty = False


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
