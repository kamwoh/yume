#!/usr/bin/env python3
"""
Static validator: every entity def has either a visual representation
OR an explicit `visual: {hidden: true}` opt-out.

Walks every `entities/*.json` under a game's data directory. For each
entity def, requires ONE of:

- `visual.mesh` (code-drawn primitive from meshes.json)
- `visual.model_3d` (.glb / .gltf / .scn / .tscn path)
- `visual.shape` (library shape from shapes.json)
- `visual.sprite_2d` (2D sprite path)
- `visual.hidden: true` (explicit opt-out — logical/singleton entity)

Without one of these, entity_mesh_3d.gd's tier-3 fallback renders the
entity as a bare colored box at state.position. The cube is silent —
no error, no warning — the author may not notice until a player sees
the mystery cube floating in the scene.

Catches the bug class that bit:
- 2026-05-03 towerdef3d singleton tracker rendered as pink square
- 2026-05-21 aldenmere free_camera defs rendered as 3 cubes at the
  authored camera positions; user noticed only when entering free_cam

Both cases fixed the same way: add `visual: {hidden: true}` to the def.
This validator catches them at sync time instead of playtest time.

Usage:
    python3 tools/validators/validate_visual_presence.py
    python3 tools/validators/validate_visual_presence.py demo_aldenmere
    python3 tools/validators/validate_visual_presence.py --strict

Exit code:
    0 — clean (or strict not requested)
    1 — at least one def with no visual + no hidden opt-out AND --strict
"""

import json
import os
import sys
from pathlib import Path


HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"


def has_visual_representation(visual):
    """True if the visual block declares a renderer-recognized representation
    OR opts out via hidden=true."""
    if not isinstance(visual, dict):
        return False
    if bool(visual.get("hidden", False)):
        return True
    for key in ("mesh", "model_3d", "shape", "sprite_2d"):
        v = visual.get(key, "")
        if v not in (None, ""):
            return True
    return False


def scan_game(game_dir):
    """Yield (def_id, file_path) for every def missing a visual representation."""
    entities_dir = game_dir / "entities"
    if not entities_dir.is_dir():
        return
    for fp in sorted(entities_dir.glob("*.json")):
        try:
            with open(fp) as f:
                data = json.load(f)
        except json.JSONDecodeError:
            continue
        defs = data.get("definitions", [])
        if not isinstance(defs, list):
            continue
        for d in defs:
            if not isinstance(d, dict):
                continue
            def_id = d.get("id", "<no-id>")
            visual = d.get("visual", None)
            if not has_visual_representation(visual):
                yield (def_id, fp)


def main():
    args = sys.argv[1:]
    strict = "--strict" in args
    targets = [a for a in args if not a.startswith("--")]

    if not targets:
        targets = [d.name for d in DATA_ROOT.iterdir() if d.is_dir() and d.name.startswith("demo_")]

    any_broken = False
    for game in targets:
        gdir = DATA_ROOT / game
        if not gdir.is_dir():
            print(f"[validate_visual_presence] skip — not a dir: {gdir}")
            continue
        broken = list(scan_game(gdir))
        if broken:
            any_broken = True
            print(f"[fail] {game}: {len(broken)} def(s) without visual representation:")
            for def_id, fp in broken:
                rel = fp.relative_to(REPO_ROOT)
                print(f"  - {def_id} in {rel}")
                print(f"    fix: add \"visual\": {{\"hidden\": true}} (if logical) OR")
                print(f"         \"visual\": {{\"mesh\": \"<name>\", ...}} / \"shape\": / \"model_3d\":")
        else:
            print(f"[ok] {game}")

    if any_broken and strict:
        sys.exit(1)


if __name__ == "__main__":
    main()
