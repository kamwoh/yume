#!/usr/bin/env python3
"""Static validator: 3D demos authored in world units must set
scene.json renderer.position_scale = 1.0.

The 3D renderer's exported default is 0.05 (the 2D pixel convention:
200 px -> 10 world units). A hand-authored 3D demo with world-unit
positions (tens of meters) that forgets `"renderer": {"position_scale":
1.0}` has every entity silently compressed 20x into a cluster at the
origin — geometry "loads fine" (no error, correct entity count) and
renders as one overlapping blob.

Heuristic: scene.json has a `lighting` block (the 3D signal) AND some
instance sits further than 15 units from origin AND renderer.position_scale
is absent → flag. 2D demos (no lighting block) and compose_world output
(which writes the key) never trip it.

Empirical case 2026-06-12 (demo_lightlab): 9 hand-authored instances
spread across ±10m all spawned within ±0.5m of origin; a top-down probe
capture showed a single glow-point cluster. Cost: three debugging probes
before the 20x compression was recognized.

Usage:
    python3 tools/validators/validate_position_scale.py [demo_x] [--strict]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"

WORLD_UNIT_THRESHOLD = 15.0


def scan_game(game_dir: Path) -> list[str]:
    scene_path = game_dir / "scene.json"
    if not scene_path.exists():
        return []
    try:
        scene = json.loads(scene_path.read_text())
    except json.JSONDecodeError:
        return []
    if "lighting" not in scene:
        return []  # no 3D signal — 2D demos keep the pixel default
    renderer = scene.get("renderer", {})
    if isinstance(renderer, dict) and "position_scale" in renderer:
        return []
    # find the farthest instance
    far = 0.0
    far_id = ""
    files = sorted((game_dir / "entities").glob("*.json")) + list(
        (game_dir / "levels").glob("*/entities.json")
    )
    for path in files:
        try:
            doc = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        for inst in doc.get("initial_instances", []) or []:
            pos = inst.get("position")
            if isinstance(pos, list) and len(pos) >= 3:
                d = max(abs(float(pos[0])), abs(float(pos[2])))
                if d > far:
                    far = d
                    far_id = str(inst.get("id", "?"))
    if far <= WORLD_UNIT_THRESHOLD:
        return []
    return [
        f"{scene_path.relative_to(REPO_ROOT)}: 3D scene (lighting block) with "
        f"world-unit positions (|{far_id}| at {far:.1f}u) but NO "
        f'renderer.position_scale. The renderer DEFAULT is 0.05 (2D pixels) — '
        f"every entity will compress 20x into a cluster at the origin. Add "
        f'"renderer": {{"position_scale": 1.0}} to scene.json.'
    ]


def main():
    ap = argparse.ArgumentParser(prog="validate_position_scale")
    ap.add_argument("game", nargs="?", default=None)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()
    targets = (
        [args.game]
        if args.game
        else sorted(
            d.name for d in DATA_ROOT.iterdir() if d.is_dir() and d.name.startswith("demo_")
        )
    )
    findings: list[str] = []
    for game in targets:
        game_dir = DATA_ROOT / game
        if not game_dir.is_dir():
            print(f"[skip] {game}: not found")
            continue
        f = scan_game(game_dir)
        if f:
            print(f"[WARN] {game}:")
            for line in f:
                print(f"  {line}")
            findings.extend(f)
        else:
            print(f"[ok] {game}")
    if findings and args.strict:
        sys.exit(1)


if __name__ == "__main__":
    main()
