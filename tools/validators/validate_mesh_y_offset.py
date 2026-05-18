#!/usr/bin/env python3
"""validate_mesh_y_offset.py — flag entities whose .glb mesh sinks
into the ground (post-mortem 2026-05-17).

Bug class: Tripo3D-generated .glbs typically have their origin at
the mesh's geometric CENTER, not its BASE. Placing such a mesh at
world y=0 buries the bottom half underground. The engine supports
`visual.y_offset` (added 2026-05-17 in entity_mesh_3d.gd::_sync_position)
to lift the mesh by that amount when rendering.

This validator scans every entity referencing a local .glb, reads
the .glb's bbox min.y, and flags entities where:
  - min.y < -0.05 (mesh extends meaningfully below origin) AND
  - visual.y_offset is missing or insufficient

For "insufficient": the expected offset is roughly -min.y * scale.
We allow a 20% tolerance to accommodate intentional half-buried
look (e.g. a half-buried stone). Larger discrepancies surface as
warnings.

Empirical case: 2026-05-17 aldenmere scene 1 — all 12 architecture +
4 tree + 12 foragable AI-gen meshes shipped without y_offset; mud_hut,
lean_to, well, fish_trap, market_stall etc. all rendered with their
bases below the ground plane. Took 5 visual-review iterations + user
pointing it out before the y_offset primitive was added + applied.
This validator catches the same bug at sync time.
"""
import argparse
import json
import struct
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent.parent
DATA_ROOT = ROOT / "godot" / "data"


def glb_bbox_min_y(path: Path) -> float | None:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if raw[:4] != b"glTF":
        return None
    try:
        json_len, _ = struct.unpack_from("<II", raw, 12)
        doc = json.loads(raw[20:20 + json_len].decode("utf-8"))
    except Exception:
        return None
    min_y = float("inf")
    for m in doc.get("meshes", []):
        for p in m.get("primitives", []):
            pi = p.get("attributes", {}).get("POSITION")
            if pi is None:
                continue
            acc = doc["accessors"][pi]
            mn = acc.get("min", [])
            if len(mn) >= 2:
                min_y = min(min_y, float(mn[1]))
    return None if min_y == float("inf") else min_y


def check_game(game_dir: Path, strict: bool) -> int:
    fails = []
    warns = []
    for jf in sorted((game_dir / "entities").rglob("*.json")):
        try:
            doc = json.loads(jf.read_text(encoding="utf-8"))
        except Exception:
            continue
        for d in doc.get("definitions", []):
            if not isinstance(d, dict):
                continue
            visual = d.get("visual") or {}
            mesh_ref = visual.get("mesh", "")
            if not (isinstance(mesh_ref, str)
                    and mesh_ref.startswith("res://")
                    and mesh_ref.endswith(".glb")):
                continue
            disk = ROOT / "godot" / mesh_ref.removeprefix("res://")
            if not disk.exists():
                continue
            min_y = glb_bbox_min_y(disk)
            if min_y is None or min_y >= -0.05:
                continue  # mesh doesn't extend below origin meaningfully
            scale = float(d.get("state_init", {}).get("scale", 1.0))
            expected = -min_y * scale
            y_offset = float(visual.get("y_offset", 0.0))
            # Authors can opt out per-entity when the mesh has artifacts
            # below the visible base (e.g. Tripo3D debris) that need to
            # stay buried. Set `visual.y_offset_intentional: true`.
            if bool(visual.get("y_offset_intentional", False)):
                continue
            shortfall = expected - y_offset
            tolerance = 0.20 * expected  # 20% tolerance
            if shortfall > tolerance:
                msg = (
                    f"  {d.get('id', '?'):25s}  "
                    f".glb min.y={min_y:+.3f} × scale={scale:.2f} "
                    f"→ expected y_offset ≈ {expected:.3f}m, "
                    f"actual {y_offset:.3f}m "
                    f"(short by {shortfall:.3f}m — mesh sinks into ground)"
                )
                fails.append(msg)
            elif shortfall > 0.05:
                msg = (
                    f"  {d.get('id', '?'):25s}  "
                    f"y_offset {y_offset:.3f}m within tolerance but "
                    f"slightly below expected {expected:.3f}m"
                )
                warns.append(msg)

    if fails:
        print(f"[fail] {game_dir.name} — {len(fails)} entity(ies) need y_offset:")
        for f in fails:
            print(f)
        if warns:
            print(f"  ({len(warns)} additional warning(s) within tolerance)")
        if strict:
            return 1
        return 0
    if warns:
        print(f"[warn] {game_dir.name} — {len(warns)} y_offset borderline:")
        for w in warns:
            print(w)
        return 0
    print(f"[ok] {game_dir.name} — all .glb-referencing entities have correct y_offset (or don't need one)")
    return 0


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    if args:
        targets = [DATA_ROOT / a for a in args]
    else:
        targets = sorted(p for p in DATA_ROOT.iterdir() if p.is_dir() and p.name.startswith("demo_"))
    rc = 0
    for t in targets:
        if not t.exists():
            print(f"[skip] {t.name} (not found)")
            continue
        rc |= check_game(t, strict)
    return rc


if __name__ == "__main__":
    sys.exit(main())
