#!/usr/bin/env python3
"""Static validator: flag instances authored with CENTER-PIVOT y on a
base-anchored mesh (y suspiciously equal to half the instance's height).

The engine anchors EVERY visual base-on-ground: normalized .glb meshes
(entity_mesh_3d._normalize_glb maps the bbox base to y=0) and code-draw
prims (prim_unit_* bake pos [0, 0.5, 0], scaled by node scale). The
authored instance `position[1]` is therefore the BASE height — y=0 means
"standing on the floor". Authoring y = height/2 (center-pivot semantics,
the convention of raw Godot primitives) FLOATS the prop by exactly half
its height.

Heuristic: for an instance whose def has a visual mesh and a height-form
scale, flag when 0.2 < y ≈ 0.5 * height (±18%). The 0.2m floor skips
cosmetic micro-lifts (curb z-fighting offsets).

Empirical case 2026-06-11 (autorace): the entire track/decor set was
center-pivot authored — grandstand floated 2.25m, flag poles 1.6m,
gantry posts 2.7m, tire stacks 0.5m. User: "i see something is
floating." Each y was exactly half the prop's height.

Usage:
    python3 tools/validators/validate_center_pivot_y.py [demo_x] [--strict]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from content import asset_file  # noqa: E402

HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"

MIN_SUSPECT_Y = 0.2     # below this, lifts are cosmetic (z-fighting offsets)
REL_TOLERANCE = 0.18    # |y - h/2| / (h/2) under this = center-pivot suspect


def _height_of(def_entry: dict, inst: dict) -> float | None:
    """Instance height in world units: scale's vertical component."""
    state = inst.get("state", {}) if isinstance(inst.get("state"), dict) else {}
    s = state.get("scale", def_entry.get("state_init", {}).get("scale"))
    if s is None:
        return None
    if isinstance(s, (int, float)):
        return float(s)
    if isinstance(s, list) and len(s) >= 2:
        return float(s[1])
    return None


def _has_visual_mesh(def_entry: dict) -> bool:
    vis = def_entry.get("visual", {})
    if not isinstance(vis, dict) or vis.get("hidden"):
        return False
    return bool(vis.get("mesh") or vis.get("model_3d"))


def _shader_surface(game_dir: Path):
    """Return f(x, z) -> ground surface height when scene.json's ground mesh
    displaces by a heightmap (ground_biome_displace.gdshader), else None.
    The shader samples uv = ((x, z) + plane/2) / plane and lifts each vertex
    by (heightmap.r + height_offset) * height_scale.

    Empirical 2026-10-16: demo_lanterns props sit on a shader-displaced
    terrain. Their y (0.46 to 0.71) is the surface height plus 0.012, but
    the flat-ground check read it as a half-height float and flagged 11."""
    try:
        mesh = json.loads((game_dir / "scene.json").read_text())["ground"]["mesh"]
        sp = mesh["shader_params"]
        hm = asset_file(str(sp["heightmap"]), game_dir)
        from PIL import Image
        img = Image.open(hm).convert("L")
    except (OSError, KeyError, TypeError, ValueError, ImportError, json.JSONDecodeError):
        return None
    plane = float(sp.get("plane_size", mesh.get("plane_size", 80.0)))
    scale = float(sp.get("height_scale", 3.0))
    offset = float(sp.get("height_offset", -0.5))
    w, h = img.size
    px = img.load()

    def surface(x: float, z: float) -> float:
        fx = min(w - 1.0, max(0.0, (x + plane / 2) / plane * (w - 1)))
        fz = min(h - 1.0, max(0.0, (z + plane / 2) / plane * (h - 1)))
        x0, z0 = int(fx), int(fz)
        x1, z1 = min(w - 1, x0 + 1), min(h - 1, z0 + 1)
        tx, tz = fx - x0, fz - z0
        top = px[x0, z0] * (1 - tx) + px[x1, z0] * tx
        bottom = px[x0, z1] * (1 - tx) + px[x1, z1] * tx
        return ((top * (1 - tz) + bottom * tz) / 255.0 + offset) * scale

    return surface


def scan_game(game_dir: Path) -> list[str]:
    findings: list[str] = []
    defs: dict[str, dict] = {}
    files = sorted((game_dir / "entities").glob("*.json")) + list(
        (game_dir / "levels").glob("*/entities.json")
    )
    docs: list[tuple[Path, dict]] = []
    for path in files:
        try:
            doc = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        docs.append((path, doc))
        for d in doc.get("definitions", []) or []:
            if isinstance(d, dict) and "id" in d:
                defs[d["id"]] = d
    # A TERRAIN ground voids the flat-ground (y=0) premise: assets sit at the
    # terrain's SURFACE height, so a non-zero y is legitimate and can't be told
    # apart from a center-pivot offset. Skip the check when a terrain is present
    # — a non-normalized ground mesh or a `terrain`-tagged def (ADR 0074 C2).
    # Empirical 2026-06-20: Infinigen terrain + ecological scatter flagged 19
    # correctly-placed assets whose surface-height y coincidentally ≈ height/2.
    has_terrain = any(
        ("terrain" in (d.get("tags") or []))
        or (isinstance(d.get("visual"), dict) and d["visual"].get("normalize") is False)
        for d in defs.values())
    if has_terrain:
        return []
    # A heightmap ground: measure each prop's height ABOVE the surface.
    surface = _shader_surface(game_dir)
    for path, doc in docs:
        rel = path.relative_to(REPO_ROOT)
        for i, inst in enumerate(doc.get("initial_instances", []) or []):
            if not isinstance(inst, dict):
                continue
            pos = inst.get("position")
            if not (isinstance(pos, list) and len(pos) >= 3):
                continue
            y = float(pos[1])
            if surface is not None:
                y -= surface(float(pos[0]), float(pos[2]))
            if y <= MIN_SUSPECT_Y:
                continue
            de = defs.get(str(inst.get("def", "")))
            if de is None or not _has_visual_mesh(de):
                continue
            h = _height_of(de, inst)
            if h is None or h <= 0:
                continue
            half = h * 0.5
            if abs(y - half) <= half * REL_TOLERANCE:
                findings.append(
                    f"{rel}[{i}] (def={inst.get('def')}, id={inst.get('id', '?')}): "
                    f"y={y:.3f} (above the ground) ≈ height/2 ({half:.2f}) — center-pivot authoring on a "
                    f"base-anchored mesh; the prop floats {y:.2f}m. Engine anchors "
                    f"every visual base-on-ground: y is the BASE height, use y=0 "
                    f"for floor-standing props. (Deliberate elevation, e.g. a "
                    f"crossbar capping posts, should NOT sit at exactly half its "
                    f"own height — nudge or restructure if intentional.)"
                )
    return findings


def main():
    ap = argparse.ArgumentParser(prog="validate_center_pivot_y")
    ap.add_argument("game", nargs="?", default=None)
    ap.add_argument("--strict", action="store_true", help="exit 1 on any finding")
    args = ap.parse_args()

    targets = (
        [args.game]
        if args.game
        else sorted(
            d.name
            for d in DATA_ROOT.iterdir()
            if d.is_dir() and d.name.startswith("demo_")
        )
    )
    all_findings: list[str] = []
    for game in targets:
        game_dir = DATA_ROOT / game
        if not game_dir.is_dir():
            print(f"[skip] {game}: not found")
            continue
        findings = scan_game(game_dir)
        if findings:
            print(f"[WARN] {game} ({len(findings)} suspect):")
            for f in findings:
                print(f"  {f}")
            all_findings.extend(findings)
        else:
            print(f"[ok] {game}")
    if all_findings and args.strict:
        sys.exit(1)


if __name__ == "__main__":
    main()
