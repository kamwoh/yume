"""try_layout.py — install a compiled visual_layout fragment as a NEW
LEVEL, then switch the game's starting_level to it.

Yume games are multi-level by default (game/flow.json). Adding a new
level is a one-time install + a one-line switch — no backup/restore
dance, no destructive edits.

Three subcommands:
    install   — copy a compiled fragment into a new level folder
    switch    — change game/flow.json's starting_level (just swap which
                level the game boots into)
    list      — show available levels + which one is current

Usage:
    # 1. Install the compiled fragment as a new level called "camp_v1":
    python3 -m tools.visual_layout.try_layout install \\
        --game demo_aldenmere \\
        --fragment godot/data/demo_aldenmere/layouts/camp_entities_68be49b0.json \\
        --as-level camp_v1

    # 2. Switch the game to boot into it:
    python3 -m tools.visual_layout.try_layout switch \\
        --game demo_aldenmere --level camp_v1

    # 3. Run the game — it loads camp_v1 instead of level_proto_village:
    ./scripts/play.sh demo_aldenmere

    # 4. Switch back to the original whenever:
    python3 -m tools.visual_layout.try_layout switch \\
        --game demo_aldenmere --level level_proto_village

    # 5. See available levels:
    python3 -m tools.visual_layout.try_layout list --game demo_aldenmere
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


# ============================================================
# install
# ============================================================


def cmd_install(args) -> int:
    game_dir = _game_dir(args.game)
    if not game_dir.exists():
        print(f"ERROR: game dir not found: {game_dir}")
        return 2

    frag_path = args.fragment
    if not frag_path.is_absolute():
        frag_path = ROOT / args.fragment
    if not frag_path.exists():
        # Try interpreting relative to <game>/layouts/
        alt = game_dir / "layouts" / args.fragment.name
        if alt.exists():
            frag_path = alt
        else:
            print(f"ERROR: fragment not found: {frag_path}")
            return 2

    fragment = json.loads(frag_path.read_text(encoding="utf-8"))

    levels_dir = game_dir / "levels" / args.as_level
    if levels_dir.exists() and not args.overwrite:
        print(f"ERROR: level dir already exists: {levels_dir}")
        print("       Pass --overwrite to replace, or pick a different --as-level name.")
        return 2

    levels_dir.mkdir(parents=True, exist_ok=True)
    target = levels_dir / "entities.json"

    # Wrap the fragment in a complete level entities.json shape.
    # Fragment has initial_instances + patterns. We add the standard
    # comment + (optionally) initial_relations placeholder.
    level_doc = {
        "_comment": (
            f"Auto-generated level from visual_layout fragment. "
            f"Source: {frag_path.name}. Edit freely — this file is "
            f"yours now."
        ),
        "_layout_source": str(frag_path.relative_to(ROOT)) if frag_path.is_relative_to(ROOT) else str(frag_path),
        "initial_instances": fragment.get("initial_instances", []),
        "initial_relations": [],
        "patterns": fragment.get("patterns", []),
    }
    target.write_text(
        json.dumps(level_doc, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    # Register in flow.json's levels list (idempotent — don't dup).
    flow_p = _flow_path(args.game)
    if flow_p.exists():
        flow = json.loads(flow_p.read_text(encoding="utf-8"))
        if args.as_level not in flow.get("levels", []):
            flow.setdefault("levels", []).append(args.as_level)
            flow_p.write_text(
                json.dumps(flow, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            registered = True
        else:
            registered = False
    else:
        registered = False
        print(f"WARNING: {flow_p} not found — level created but not registered in flow.json")

    n_inst = len(level_doc["initial_instances"])
    n_pat = len(level_doc["patterns"])
    print(f"[install] {args.as_level}: {n_inst} instances + {n_pat} patterns")
    print(f"  written to: {target.relative_to(ROOT)}")
    if registered:
        print(f"  registered in {flow_p.relative_to(ROOT)}'s levels[]")
    print()
    print("Next:")
    print(f"  python3 -m tools.visual_layout.try_layout switch \\")
    print(f"      --game {args.game} --level {args.as_level}")
    return 0


# ============================================================
# switch
# ============================================================


def cmd_switch(args) -> int:
    flow_p = _flow_path(args.game)
    if not flow_p.exists():
        print(f"ERROR: flow.json not found: {flow_p}")
        return 2
    flow = json.loads(flow_p.read_text(encoding="utf-8"))

    levels = flow.get("levels", [])
    if args.level not in levels:
        print(f"ERROR: '{args.level}' not in flow.json's levels[].")
        print(f"  Available: {levels}")
        print(f"  Install it first via: python3 -m tools.visual_layout.try_layout install ...")
        return 2

    old = flow.get("starting_level", "")
    flow["starting_level"] = args.level
    flow["entry_level"] = args.level
    flow_p.write_text(
        json.dumps(flow, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"[switch] {old} → {args.level}")
    print(f"  flow.json updated: {flow_p.relative_to(ROOT)}")
    print()
    print("Next:")
    print(f"  ./scripts/play.sh {args.game}")
    return 0


# ============================================================
# list
# ============================================================


def cmd_list(args) -> int:
    flow_p = _flow_path(args.game)
    if not flow_p.exists():
        print(f"ERROR: flow.json not found: {flow_p}")
        return 2
    flow = json.loads(flow_p.read_text(encoding="utf-8"))
    current = flow.get("starting_level", "")
    levels = flow.get("levels", [])

    # Also scan levels/ for any folders not registered (orphans)
    levels_dir = _game_dir(args.game) / "levels"
    on_disk = set()
    if levels_dir.exists():
        on_disk = {p.name for p in levels_dir.iterdir() if p.is_dir()}

    print(f"[{args.game}] levels in flow.json:")
    for lv in levels:
        marker = " ← current" if lv == current else ""
        exists = "" if lv in on_disk else "  (MISSING on disk)"
        print(f"  • {lv}{marker}{exists}")
    orphans = on_disk - set(levels)
    if orphans:
        print(f"\n  Unregistered (on disk but not in flow.json):")
        for o in sorted(orphans):
            print(f"  • {o}")
    return 0


# ============================================================
# CLI
# ============================================================


def main() -> int:
    ap = argparse.ArgumentParser(prog="try_layout")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s_install = sub.add_parser("install", help="Install a compiled fragment as a new level.")
    s_install.add_argument("--game", required=True)
    s_install.add_argument("--fragment", required=True, type=Path)
    s_install.add_argument("--as-level", required=True,
                           help="Name of the new level folder.")
    s_install.add_argument("--overwrite", action="store_true")
    s_install.set_defaults(func=cmd_install)

    s_switch = sub.add_parser("switch", help="Switch the game's starting_level.")
    s_switch.add_argument("--game", required=True)
    s_switch.add_argument("--level", required=True)
    s_switch.set_defaults(func=cmd_switch)

    s_list = sub.add_parser("list", help="Show levels in this game.")
    s_list.add_argument("--game", required=True)
    s_list.set_defaults(func=cmd_list)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
