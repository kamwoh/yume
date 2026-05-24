#!/usr/bin/env python3
"""
Static validator: properties.aabb_extents must match the entity's
mesh bbox × state.scale.

When an entity has both `visual.model_3d` (a .glb path) AND
`properties.aabb_extents` (the physics collider half-extents for
ADR 0004's blocks_motion translation), the two MUST agree:

    aabb_extents = (glb_bbox.max - glb_bbox.min) / 2 * state_init.scale

If the .glb mesh changes (re-rolled Tripo3D, scaled differently,
swapped to a different file) but aabb_extents is stale, the
collider stops wrapping the mesh — player tries to jump on the
bench and falls through, or walks through walls that visually look
solid.

This validator catches the drift. For each entity def with both
fields:
1. Parses the .glb header (pure Python, no Godot needed)
2. Computes expected aabb_extents from bbox + scale
3. Flags drift > tolerance with the corrected values

Empirical case 2026-05-24: user enabled --debug-colliders, observed
"all aldenmere entity colliders don't wrap the meshes enough."
Manual fix of each def is unsustainable; this validator catches the
class for every game.

Usage:
    python3 tools/validators/validate_aabb_extents.py
    python3 tools/validators/validate_aabb_extents.py demo_aldenmere
    python3 tools/validators/validate_aabb_extents.py demo_aldenmere --strict
    python3 tools/validators/validate_aabb_extents.py demo_aldenmere --fix
        (auto-patches the entity defs with corrected values)

Tolerance default: 20% per axis. Tunable via --tolerance=0.10 etc.
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path


HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"


def parse_glb_bbox(path: Path) -> tuple[list[float], list[float]] | None:
    """Read the .glb header + accessor min/max → return (min_xyz, max_xyz)
    spanning all mesh POSITION accessors. Returns None on parse failure.
    Pure Python — no pygltflib / trimesh / Godot dependency."""
    if not path.is_file():
        return None
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if raw[:4] != b"glTF":
        return None
    try:
        json_len = struct.unpack_from("<II", raw, 12)[0]
        doc = json.loads(raw[20:20 + json_len].decode("utf-8"))
    except (struct.error, json.JSONDecodeError, UnicodeDecodeError):
        return None
    bbox_min = [float("inf"), float("inf"), float("inf")]
    bbox_max = [float("-inf"), float("-inf"), float("-inf")]
    for m in doc.get("meshes", []):
        for p in m.get("primitives", []):
            pos = p.get("attributes", {}).get("POSITION")
            if pos is None:
                continue
            try:
                acc = doc["accessors"][pos]
            except (IndexError, KeyError):
                continue
            mn = acc.get("min", [])
            mx = acc.get("max", [])
            if len(mn) >= 3 and len(mx) >= 3:
                for i in range(3):
                    bbox_min[i] = min(bbox_min[i], float(mn[i]))
                    bbox_max[i] = max(bbox_max[i], float(mx[i]))
    if bbox_min[0] == float("inf"):
        return None
    return bbox_min, bbox_max


def resolve_res_path(res_path: str) -> Path | None:
    """`res://data/<game>/path/to/file.glb` → filesystem Path."""
    if not res_path.startswith("res://"):
        return None
    rel = res_path[len("res://"):]
    return REPO_ROOT / "godot" / rel


def expected_aabb_extents(
    bbox_min: list[float], bbox_max: list[float], scale: float
) -> list[float]:
    """Half-extents in WORLD units = (max - min) / 2 * state.scale."""
    return [
        (bbox_max[i] - bbox_min[i]) / 2.0 * scale
        for i in range(3)
    ]


def expected_aabb_offset(
    bbox_min: list[float], bbox_max: list[float], scale: float,
    visual_y_offset: float
) -> list[float]:
    """Where the collider CENTER sits relative to entity.position. The
    mesh is rendered at entity.position + (0, y_offset, 0); the bbox
    center within the mesh is ((min + max) / 2) * scale. The collider
    center = those summed.

    For Tripo3D bbox-centered meshes (min.y == -max.y, etc.), the bbox
    center is at the mesh origin → offset = visual.y_offset alone.
    For foot-pivoted rigged meshes (min.y ≈ 0), offset.y =
    visual.y_offset (typically 0) + extents.y."""
    return [
        (bbox_min[i] + bbox_max[i]) / 2.0 * scale + (
            visual_y_offset if i == 1 else 0.0
        )
        for i in range(3)
    ]


def drift_severity(declared: list[float], expected: list[float],
                   tolerance: float) -> tuple[float, bool]:
    """Return (max_axis_relative_drift, exceeds_tolerance). For axes
    where expected magnitude is very small (< 0.05 world units),
    fall back to absolute drift in meters — relative drift on tiny
    numbers is meaningless."""
    if len(declared) < 3 or len(expected) < 3:
        return (0.0, False)
    max_drift = 0.0
    for i in range(3):
        if abs(expected[i]) <= 0.05:
            # Absolute drift in meters: 0.1m = 10% notional drift
            max_drift = max(max_drift, abs(declared[i] - expected[i]) * 10.0)
            continue
        rel = abs(declared[i] - expected[i]) / abs(expected[i])
        max_drift = max(max_drift, rel)
    return max_drift, max_drift > tolerance


def scan_game(game_dir: Path, tolerance: float, apply_fix: bool
              ) -> list[dict]:
    """Walk entities/*.json. For each def with both glb + aabb_extents,
    return a list of drift records. If apply_fix, also patch the def
    in-place."""
    entities_dir = game_dir / "entities"
    if not entities_dir.is_dir():
        return []
    drifts: list[dict] = []
    for fp in sorted(entities_dir.glob("*.json")):
        try:
            doc = json.loads(fp.read_text())
        except json.JSONDecodeError:
            continue
        defs = doc.get("definitions", [])
        if not isinstance(defs, list):
            continue
        file_modified = False
        for d in defs:
            if not isinstance(d, dict):
                continue
            visual = d.get("visual", {})
            if not isinstance(visual, dict):
                continue
            # .glb path can live in EITHER visual.model_3d (preferred per
            # ADR 0046 Phase B) OR visual.mesh (when the mesh field points
            # directly at a .glb instead of a meshes.json library key).
            visual_glb_path = ""
            for key in ("model_3d", "mesh"):
                v = visual.get(key, "")
                if isinstance(v, str) and v.endswith(".glb"):
                    visual_glb_path = v
                    break
            if not visual_glb_path:
                continue
            props = d.get("properties", {})
            if not isinstance(props, dict):
                continue
            declared = props.get("aabb_extents", None)
            if not isinstance(declared, list) or len(declared) < 3:
                continue
            declared_f = [float(v) for v in declared[:3]]
            state_init = d.get("state_init", {})
            if not isinstance(state_init, dict):
                state_init = {}
            scale_v = state_init.get("scale", 1.0)
            try:
                scale = float(scale_v)
            except (TypeError, ValueError):
                scale = 1.0
            # Two sources of truth for the collider's bbox, both
            # mesh-derived (NO manual radius/height values anywhere):
            #
            #   1. `properties.collision_mesh` (path to a .glb authored
            #      as the collision shape, decoupled from the visual
            #      mesh). Used when the visible mesh's bbox would
            #      produce an undesirable gameplay collider — e.g. a
            #      tree's wide-canopy visual bbox blocks the player
            #      from walking between trunks. The tree's
            #      `properties.collision_mesh` points at the shared
            #      narrow cylinder primitive instead. Convention:
            #      collision_mesh is authored bottom-rooted (min.y=0,
            #      max.y=1) in its own coordinate frame — NO
            #      visual.y_offset added to the aabb_offset.
            #
            #   2. `visual.model_3d` / `visual.mesh` (the default).
            #      Collider matches the visible mesh's bbox.
            #      visual.y_offset is added to aabb_offset to
            #      compensate for the renderer's lift on bbox-centered
            #      Tripo3D meshes.
            #
            # Both sources are MESH-derived: authors can't type
            # "radius=0.3" manually anywhere. They either accept the
            # visual mesh's bbox or point properties.collision_mesh
            # at a different .glb. No escape hatches.
            collision_mesh_path = ""
            cm = props.get("collision_mesh", "")
            if isinstance(cm, str) and cm.endswith(".glb"):
                collision_mesh_path = cm
            use_collision_mesh = bool(collision_mesh_path)
            glb_path = collision_mesh_path if use_collision_mesh else visual_glb_path
            res_fs = resolve_res_path(glb_path)
            if res_fs is None or not res_fs.is_file():
                continue
            bbox = parse_glb_bbox(res_fs)
            if bbox is None:
                continue
            bbox_min, bbox_max = bbox
            # visual.y_offset compensates for the visual renderer's lift.
            # It does NOT apply when collision_mesh is the source — that
            # mesh is in its own coordinate frame.
            visual_y_off = (
                0.0 if use_collision_mesh
                else float(visual.get("y_offset", 0.0))
            )
            expected_ext = expected_aabb_extents(bbox_min, bbox_max, scale)
            expected_off = expected_aabb_offset(
                bbox_min, bbox_max, scale, visual_y_off
            )
            declared_off_raw = props.get("aabb_offset", [0.0, 0.0, 0.0])
            declared_off = (
                [float(v) for v in declared_off_raw[:3]]
                if isinstance(declared_off_raw, list) and len(declared_off_raw) >= 3
                else [0.0, 0.0, 0.0]
            )
            drift_ext, exceeds_ext = drift_severity(declared_f, expected_ext, tolerance)
            drift_off, exceeds_off = drift_severity(declared_off, expected_off, tolerance)
            if exceeds_ext or exceeds_off:
                drifts.append({
                    "def_id": d.get("id", "?"),
                    "file": fp.relative_to(REPO_ROOT),
                    "glb": glb_path,
                    "scale": scale,
                    "declared_ext": declared_f,
                    "expected_ext": [round(v, 4) for v in expected_ext],
                    "declared_off": declared_off,
                    "expected_off": [round(v, 4) for v in expected_off],
                    "max_drift": round(max(drift_ext, drift_off), 3),
                    "y_offset_from_visual": visual_y_off,
                })
                if apply_fix:
                    props["aabb_extents"] = [round(v, 4) for v in expected_ext]
                    # Only set offset if it's non-zero (keep defs clean)
                    if max(abs(v) for v in expected_off) > 0.01:
                        props["aabb_offset"] = [round(v, 4) for v in expected_off]
                    elif "aabb_offset" in props:
                        # Drift below tolerance + declared exists = remove stale
                        del props["aabb_offset"]
                    props["_comment_aabb_autofix"] = (
                        "Auto-recomputed by validate_aabb_extents.py "
                        "from .glb bbox + visual.y_offset (2026-05-24). "
                        "Collider center now aligned to mesh center "
                        "(was sitting half-underground when offset "
                        "was missing for bbox-centered Tripo3D meshes)."
                    )
                    file_modified = True
        if file_modified:
            fp.write_text(json.dumps(doc, indent=2) + "\n")
    return drifts


def main():
    ap = argparse.ArgumentParser(prog="validate_aabb_extents")
    ap.add_argument("game", nargs="?", default=None,
                    help="game folder name (e.g. demo_aldenmere). "
                         "Omit to scan every demo_* folder.")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 on any drift > tolerance")
    ap.add_argument("--fix", action="store_true",
                    help="auto-patch entity defs with corrected aabb_extents")
    ap.add_argument("--tolerance", type=float, default=0.20,
                    help="relative drift tolerance (default 0.20 = 20%%)")
    args = ap.parse_args()

    if args.game:
        targets = [args.game]
    else:
        targets = sorted(
            d.name for d in DATA_ROOT.iterdir()
            if d.is_dir() and d.name.startswith("demo_")
        )

    any_drift = False
    for game in targets:
        gdir = DATA_ROOT / game
        if not gdir.is_dir():
            continue
        drifts = scan_game(gdir, args.tolerance, args.fix)
        if drifts:
            any_drift = True
            verb = "fixed" if args.fix else "flagged"
            print(f"[{verb}] {game}: {len(drifts)} aabb_extents drift(s) > "
                  f"{int(args.tolerance * 100)}%:")
            for r in drifts:
                print(f"  - {r['def_id']}  (scale={r['scale']}, "
                      f"max_drift={int(r['max_drift'] * 100)}%)")
                print(f"      extents  declared: {r['declared_ext']}")
                print(f"      extents  expected: {r['expected_ext']}")
                print(f"      offset   declared: {r['declared_off']}")
                print(f"      offset   expected: {r['expected_off']}  "
                      f"(y_offset={r['y_offset_from_visual']} from visual)")
                print(f"      {r['file']}")
        else:
            print(f"[ok] {game}")

    if any_drift and args.strict and not args.fix:
        sys.exit(1)


if __name__ == "__main__":
    main()
