#!/usr/bin/env python3
"""Static validator: top-level `position` and `state.position` in an
initial_instances entry MUST match if both are set.

Empirical case 2026-05-26: compose_world.py auto-generated free_camera
initial_instances with top-level position=[0,0,0] and state.position=
[0, 28, 32] (the actual camera pose). The engine's
entity._apply_overrides processes overrides in this order:

    1. state block       → state.position = [0, 28, 32]
    2. position top-level → state.position = [0, 0, 0]  (CLOBBERED)

The state.position the author intended was silently overwritten.
Symptom: free_camera entities all spawned at world origin instead
of their intended camera poses. Camera_director's _camera_free_cam
moved Camera3D to (0, 0, 0), looking inside a building, rendering
solid dark brown.

This bug is specific to `position` — it's the only top-level
override field in _apply_overrides that writes into the state dict.
Other top-level fields (properties, tags, visual) merge into their
own dicts without clobbering state.

This validator flags every initial_instance where top-level and
state.position are BOTH set and don't match (after normalization).
The fix is to set BOTH to the same value (aldenmere's convention).

Usage:
    python3 tools/validators/validate_position_consistency.py
    python3 tools/validators/validate_position_consistency.py demo_aldenmere
    python3 tools/validators/validate_position_consistency.py demo_aldenmere --strict
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"


def _norm_pos(p):
    """Normalize a position to a tuple of 3 floats. Returns None on bad input."""
    if not isinstance(p, list):
        return None
    if len(p) == 2:
        return (float(p[0]), 0.0, float(p[1]))
    if len(p) == 3:
        return (float(p[0]), float(p[1]), float(p[2]))
    return None


def _check_inst(inst: dict, ctx: str) -> list[str]:
    """Return a list of warning strings for this instance dict."""
    if not isinstance(inst, dict):
        return []
    top = inst.get("position", None)
    state = inst.get("state", {}) if isinstance(inst.get("state"), dict) else {}
    state_pos = state.get("position", None)
    if top is None or state_pos is None:
        return []   # one or the other unset: no conflict
    top_n = _norm_pos(top)
    state_n = _norm_pos(state_pos)
    if top_n is None or state_n is None:
        return []
    # Tolerance: 0.01m (sub-cm). Below that = same.
    if any(abs(a - b) > 0.01 for a, b in zip(top_n, state_n)):
        return [
            f"{ctx} (def={inst.get('def', '?')}, id={inst.get('id', '?')}): "
            f"top-level position={top} != state.position={state_pos}. "
            f"The engine processes overrides in order: state block first, "
            f"then top-level position. Top-level WINS and silently clobbers "
            f"state.position. Set both to the SAME value if you want state."
            f"position to stick."
        ]
    return []


def scan_game(game_dir: Path) -> list[str]:
    """Walk every JSON file under <game>/ that contains initial_instances."""
    findings: list[str] = []
    # Check levels/*/entities.json and world/state.json
    candidates = list((game_dir / "levels").glob("*/entities.json"))
    state_json = game_dir / "world" / "state.json"
    if state_json.exists():
        candidates.append(state_json)
    for path in candidates:
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue
        instances = doc.get("initial_instances", [])
        if not isinstance(instances, list):
            continue
        rel = path.relative_to(REPO_ROOT)
        for i, inst in enumerate(instances):
            findings.extend(_check_inst(inst, f"{rel}[{i}]"))
    return findings


def main():
    ap = argparse.ArgumentParser(prog="validate_position_consistency")
    ap.add_argument("game", nargs="?", default=None,
                    help="game folder name (e.g. demo_aldenmere). "
                         "Omit to scan every demo_* folder.")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 on any conflict")
    args = ap.parse_args()

    if args.game:
        targets = [args.game]
    else:
        targets = sorted(
            d.name for d in DATA_ROOT.iterdir()
            if d.is_dir() and d.name.startswith("demo_")
        )

    any_findings = False
    for game in targets:
        gdir = DATA_ROOT / game
        if not gdir.is_dir():
            continue
        findings = scan_game(gdir)
        if findings:
            any_findings = True
            print(f"[flagged] {game}: {len(findings)} position-field conflict(s):")
            for f in findings:
                print(f"  - {f}")
        else:
            print(f"[ok] {game}")

    if any_findings and args.strict:
        sys.exit(1)


if __name__ == "__main__":
    main()
