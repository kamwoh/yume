"""validate_level_instances.py — sync-time gate for per-level entity refs.

Walks every `data/<game>/levels/*/entities.json` (and the optional
single-file `data/<game>/entities.json`) and verifies that every
`initial_instances[].def` AND `patterns[].def` resolves to an entity
def_id in `data/<game>/entities/*.json`.

Catches the bug class:

    [world.def_unknown] Unknown def: prop_log_bridge

…which the engine raises at runtime when a level instance references
a def that no longer exists (renamed, deleted, never authored). Until
this validator landed, the only catch was at level-load time —
fine for the active level, but a STALE legacy level (still registered
in flow.json) would only fail when the player switched to it.

Empirical case 2026-05-20: aldenmere's `camp_visual` level shipped
with 6 missing def_ids — `prop_fire_pit`, `prop_lean_to`,
`prop_log_bridge`, `prop_mud_hut`, `prop_stone_small`, `prop_tree_pine`.
The level was a leftover from an earlier authoring pass before
aldenmere's def names were standardized to `structure_fire_pit`,
`shelter_lean_to`, etc. Engine fired def_unknown errors when the user
hit the level via the in-game level picker. validate_spawn_templates
already existed but only covers rule effects, not level placements —
this validator closes that gap.

Usage:
    python3 tools/validators/validate_level_instances.py <game> [--strict]

With --strict, exits 1 on any violation; without, prints warnings
and exits 0. Wired into tools/validators/run_all.py.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _scan_def_ids(game_dir: Path) -> set[str]:
    out: set[str] = set()
    ent_dir = game_dir / "entities"
    if not ent_dir.exists():
        return out
    for jf in ent_dir.rglob("*.json"):
        try:
            doc = json.loads(jf.read_text(encoding="utf-8"))
        except Exception:
            continue
        for d in doc.get("definitions", []):
            if isinstance(d, dict) and d.get("id"):
                out.add(str(d["id"]))
    # Single-file entities.json — also accept defs there.
    single = game_dir / "entities.json"
    if single.exists():
        try:
            doc = json.loads(single.read_text(encoding="utf-8"))
            for d in doc.get("definitions", []):
                if isinstance(d, dict) and d.get("id"):
                    out.add(str(d["id"]))
        except Exception:
            pass
    return out


def _scan_level_refs(game_dir: Path) -> list[dict]:
    """Return [{file, kind, index, def, id?}, ...] for every def-ref."""
    refs: list[dict] = []
    # Per-level entities.json
    for jf in (game_dir / "levels").rglob("entities.json"):
        if "/.bak" in str(jf) or jf.name.endswith(".bak"):
            continue
        rel = jf.relative_to(game_dir)
        try:
            doc = json.loads(jf.read_text(encoding="utf-8"))
        except Exception:
            continue
        for i, e in enumerate(doc.get("initial_instances", []) or []):
            if isinstance(e, dict) and e.get("def"):
                refs.append({
                    "file": str(rel),
                    "kind": "initial_instance",
                    "index": i,
                    "def": str(e["def"]),
                    "id": str(e.get("id", "")),
                })
        for i, p in enumerate(doc.get("patterns", []) or []):
            if isinstance(p, dict) and p.get("def"):
                refs.append({
                    "file": str(rel),
                    "kind": "pattern",
                    "index": i,
                    "def": str(p["def"]),
                    "id_prefix": str(p.get("id_prefix", "")),
                })
    return refs


def validate(game: str, strict: bool = False) -> int:
    game_dir = ROOT / "godot" / "data" / game
    if not game_dir.exists():
        print(f"[validate_level_instances] game dir not found: {game_dir}",
              file=sys.stderr)
        return 2

    def_ids = _scan_def_ids(game_dir)
    if not def_ids:
        print(f"[validate_level_instances] no entity defs found under "
              f"{game_dir}/entities/ — skipping (nothing to validate "
              f"against)")
        return 0

    refs = _scan_level_refs(game_dir)
    if not refs:
        print(f"[ok] {game} — no level instance refs to check")
        return 0

    errors: list[dict] = []
    for r in refs:
        if r["def"] not in def_ids:
            errors.append(r)

    if not errors:
        print(f"[ok] {game} — {len(refs)} level instance refs all resolve "
              f"({len(def_ids)} defs catalogued)")
        return 0

    # Group by file for tidier reporting
    by_file: dict[str, list[dict]] = {}
    for e in errors:
        by_file.setdefault(e["file"], []).append(e)

    header = "ERROR" if strict else "WARN "
    print(f"[{header}] {game} — {len(errors)} unknown defs across "
          f"{len(by_file)} level file(s):", file=sys.stderr)
    for fp, items in sorted(by_file.items()):
        unique_defs = sorted({i["def"] for i in items})
        print(f"  {fp}:", file=sys.stderr)
        for d in unique_defs:
            uses = [i for i in items if i["def"] == d]
            ids = [i.get("id") or i.get("id_prefix") or f"#{i['index']}" for i in uses[:3]]
            print(f"    ✗ def='{d}' ({len(uses)} ref{'s' if len(uses)>1 else ''}: "
                  f"{', '.join(ids)}{'…' if len(uses)>3 else ''})",
                  file=sys.stderr)
    return 1 if strict else 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="validate_level_instances")
    ap.add_argument("game", help="Game id, e.g. demo_aldenmere")
    ap.add_argument("--strict", action="store_true",
                    help="Exit 1 on violation (default: warn + exit 0)")
    args = ap.parse_args()
    return validate(args.game, strict=args.strict)


if __name__ == "__main__":
    sys.exit(main())
