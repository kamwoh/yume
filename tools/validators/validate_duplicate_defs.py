#!/usr/bin/env python3
"""
Static validator: no entity def id declared in 2+ files within an
engine-GLOBBED entities set.

Why this matters: world_loader.gd loads entity defs by GLOBBING
`<root>/entities/*.json` (sorted) AND reading `<root>/entities.json`,
then MERGES every definition into one dict. If the same def id appears
in two files, the last-loaded (alphabetically-later) file SILENTLY
WINS — its visual/state/tags overwrite the earlier def. No error is
raised; the user just sees the wrong mesh/color.

The classic trap is a backup snapshot left in the loaded dir. A
`cp -r src/. dst/` never removes orphans, and authors often save a
`foo.preChange.json` next to `foo.json` "to be safe" — but if it sits
inside `entities/`, the engine globs it and its stale defs clobber the
live ones.

Empirical case 2026-05-27: `entities/auto_gen.preBuckets.json` (a
manual pre-floor-tiers backup) re-declared `fountain`/`townhall`/
`wall_segment`/`bridge` with the OLD `prim_unit_*` meshes + raw
semantic-map classification hex (#e040a0). Sorted after
`auto_gen.json`, it won the merge → the fountain rendered as a bare
magenta sphere instead of the fountain_kit. Fix: relocate snapshots
to a NON-globbed `_snapshots/` dir. This gate prevents recurrence.

Convention: keep backups OUT of engine-globbed dirs. Put them in
`<game>/_snapshots/` (the engine never scans it).

Usage:
    python3 tools/validators/validate_duplicate_defs.py <game>
    python3 tools/validators/validate_duplicate_defs.py <game> --strict
"""

import json
import sys
from collections import defaultdict
from pathlib import Path


def _def_ids(path: Path) -> list[str]:
    try:
        doc = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return []
    defs = doc.get("definitions", []) if isinstance(doc, dict) else []
    return [d["id"] for d in defs if isinstance(d, dict) and "id" in d]


def _globbed_sets(game_dir: Path) -> list[tuple[str, list[Path]]]:
    """Return (label, files) for each engine-globbed entities set: the
    game-global set, and each level's set. Within a set, a def id in
    2+ files is the bug (cross-set override is a legitimate pattern)."""
    sets: list[tuple[str, list[Path]]] = []

    def collect(root: Path, label: str) -> None:
        files: list[Path] = []
        single = root / "entities.json"
        if single.exists():
            files.append(single)
        ents = root / "entities"
        if ents.is_dir():
            files.extend(sorted(ents.glob("*.json")))
        if files:
            sets.append((label, files))

    collect(game_dir, "entities (game-global)")
    levels = game_dir / "levels"
    if levels.is_dir():
        for lv in sorted(levels.iterdir()):
            if lv.is_dir():
                collect(lv, f"levels/{lv.name}")
    return sets


def validate_game(game_dir: Path) -> list[str]:
    errors: list[str] = []
    for label, files in _globbed_sets(game_dir):
        seen: dict[str, list[str]] = defaultdict(list)
        for f in files:
            for did in _def_ids(f):
                seen[did].append(f.name)
        for did, fs in sorted(seen.items()):
            if len(fs) > 1:
                errors.append(
                    f"[{label}] def '{did}' declared in {len(fs)} files: "
                    f"{', '.join(fs)} — last-loaded wins silently. Move "
                    f"backups to <game>/_snapshots/ (not engine-globbed)."
                )
    return errors


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    if not args:
        print("usage: validate_duplicate_defs.py <game> [--strict]")
        return 2
    game = args[0]
    repo = Path(__file__).resolve().parent.parent.parent
    game_dir = repo / "godot" / "data" / game
    if not game_dir.is_dir():
        print(f"[validate_duplicate_defs] game dir not found: {game_dir}")
        return 0
    errors = validate_game(game_dir)
    if not errors:
        print(f"[ok] {game}: no duplicate def ids across globbed entity files")
        return 0
    print(f"[validate_duplicate_defs] FAIL — {len(errors)} duplicate def id(s):")
    for e in errors:
        print(f"  {e}")
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
