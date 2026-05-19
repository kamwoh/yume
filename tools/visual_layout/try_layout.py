"""try_layout.py — swap into a generated layout, play, swap back.

ONE-COMMAND workflow:

    # Try the layout (installs + switches in one step):
    python3 -m tools.visual_layout.try_layout demo_aldenmere camp_entities_68be49b0

    # Then just play:
    ./scripts/play.sh demo_aldenmere

    # When done, undo:
    python3 -m tools.visual_layout.try_layout demo_aldenmere --back

Fragment can be:
    - Bare hash:       camp_entities_68be49b0
    - Filename:        camp_entities_68be49b0.json
    - Full path:       godot/data/demo_aldenmere/layouts/camp_entities_68be49b0.json

The level name is auto-derived from the fragment hash. Previous
starting_level is remembered so --back undoes the switch.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _game_dir(game: str) -> Path:
    return ROOT / "godot" / "data" / game


def _flow_path(game: str) -> Path:
    return _game_dir(game) / "game" / "flow.json"


def _resolve_fragment(game: str, fragment: str) -> Path | None:
    """Resolve a fragment arg (bare hash / filename / path) to an absolute Path."""
    # Try as path
    p = Path(fragment)
    if p.is_absolute() and p.exists():
        return p
    if p.exists():
        return p.resolve()
    # Try with .json appended
    layouts_dir = _game_dir(game) / "layouts"
    candidates = []
    if not fragment.endswith(".json"):
        candidates.append(layouts_dir / f"{fragment}.json")
        # Bare hash → camp_entities_<hash>.json
        if not fragment.startswith("camp_entities_"):
            candidates.append(layouts_dir / f"camp_entities_{fragment}.json")
    candidates.append(layouts_dir / fragment)
    for c in candidates:
        if c.exists():
            return c
    return None


def cmd_swap(game: str, fragment_arg: str) -> int:
    """Install + switch in one shot."""
    frag = _resolve_fragment(game, fragment_arg)
    if frag is None:
        layouts_dir = _game_dir(game) / "layouts"
        available = sorted(layouts_dir.glob("camp_entities_*.json")) if layouts_dir.exists() else []
        print(f"ERROR: could not resolve fragment '{fragment_arg}'")
        if available:
            print(f"  Available fragments in {layouts_dir.relative_to(ROOT)}:")
            for a in available:
                print(f"    • {a.stem}")
        return 2

    # Derive level name from fragment stem (strip the camp_entities_ prefix)
    stem = frag.stem
    level_name = stem.replace("camp_entities_", "layout_") if stem.startswith("camp_entities_") else f"layout_{stem}"

    # 1. Install: create levels/<level_name>/entities.json
    fragment = json.loads(frag.read_text(encoding="utf-8"))
    levels_dir = _game_dir(game) / "levels" / level_name
    levels_dir.mkdir(parents=True, exist_ok=True)
    target = levels_dir / "entities.json"
    level_doc = {
        "_comment": f"Auto-generated from visual_layout fragment {frag.name}.",
        "_layout_source": str(frag.relative_to(ROOT)) if frag.is_relative_to(ROOT) else str(frag),
        "initial_instances": fragment.get("initial_instances", []),
        "initial_relations": [],
        "patterns": fragment.get("patterns", []),
    }
    target.write_text(
        json.dumps(level_doc, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    # 2. Update flow.json: register level + switch + remember previous
    flow_p = _flow_path(game)
    if not flow_p.exists():
        print(f"ERROR: flow.json not found: {flow_p}")
        return 2
    flow = json.loads(flow_p.read_text(encoding="utf-8"))
    if level_name not in flow.get("levels", []):
        flow.setdefault("levels", []).append(level_name)
    prev = flow.get("starting_level", "")
    if prev != level_name:
        flow["_previous_starting_level"] = prev  # for --back
    flow["starting_level"] = level_name
    flow["entry_level"] = level_name
    flow_p.write_text(
        json.dumps(flow, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    n_inst = len(level_doc["initial_instances"])
    n_pat = len(level_doc["patterns"])
    print(f"[swap] installed + switched → {level_name}")
    print(f"  {n_inst} instances + {n_pat} patterns")
    if prev:
        print(f"  previous: {prev} (use --back to restore)")
    print()
    print(f"  ./scripts/play.sh {game}")
    return 0


def cmd_back(game: str) -> int:
    """Restore previous starting_level."""
    flow_p = _flow_path(game)
    if not flow_p.exists():
        print(f"ERROR: flow.json not found: {flow_p}")
        return 2
    flow = json.loads(flow_p.read_text(encoding="utf-8"))
    prev = flow.get("_previous_starting_level")
    current = flow.get("starting_level", "")
    if not prev:
        print(f"[back] nothing to restore. starting_level = {current}")
        return 0
    flow["starting_level"] = prev
    flow["entry_level"] = prev
    flow.pop("_previous_starting_level", None)
    flow_p.write_text(
        json.dumps(flow, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"[back] {current} → {prev}")
    return 0


def cmd_list(game: str) -> int:
    """Show levels + current."""
    flow_p = _flow_path(game)
    if not flow_p.exists():
        print(f"ERROR: flow.json not found: {flow_p}")
        return 2
    flow = json.loads(flow_p.read_text(encoding="utf-8"))
    current = flow.get("starting_level", "")
    print(f"[{game}] levels:")
    for lv in flow.get("levels", []):
        marker = " ← current" if lv == current else ""
        print(f"  • {lv}{marker}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="try_layout",
        description="Swap into a generated layout, play, swap back.",
    )
    ap.add_argument("game", help="Game id, e.g. demo_aldenmere")
    ap.add_argument(
        "fragment",
        nargs="?",
        help="Fragment to swap into (bare hash, filename, or path). "
        "Omit with --back / --list.",
    )
    ap.add_argument("--back", action="store_true",
                    help="Restore previous starting_level.")
    ap.add_argument("--list", action="store_true",
                    help="Show levels + current.")
    args = ap.parse_args()

    if args.back:
        return cmd_back(args.game)
    if args.list:
        return cmd_list(args.game)
    if not args.fragment:
        ap.print_help()
        return 2
    return cmd_swap(args.game, args.fragment)


if __name__ == "__main__":
    sys.exit(main())
