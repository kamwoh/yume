#!/usr/bin/env python3
"""validate_mesh_y_offset.py — flag entities whose .glb mesh sinks
into the ground or floats above it.

Two bug classes covered:

(A) Tripo3D-generated .glbs typically have their origin at the mesh's
    geometric CENTER, not its BASE. Placing such a mesh at world y=0
    buries the bottom half underground. The engine supports
    `visual.y_offset_mesh` (preferred, mesh-space) and the legacy
    `visual.y_offset` (world-space constant) to lift the mesh.

(B) Pattern-spawned variants (level patterns with scale_min/scale_max)
    inherit the def's y_offset. The LEGACY world-space y_offset is a
    constant that doesn't scale with state.scale — so dwarf bushes at
    scale=0.3 inherit the same lift as full trees at scale=3.5, and
    end up floating above ground. The preferred `y_offset_mesh` scales
    automatically. This validator flags any pattern whose scale range
    differs from the def's state_init.scale when the def uses legacy
    `y_offset` (forcing migration to `y_offset_mesh`).

For "insufficient": the expected offset is roughly -min.y * scale.
We allow a 20% tolerance to accommodate intentional half-buried
look (e.g. a half-buried stone). Larger discrepancies surface as
warnings.

Empirical cases:
- 2026-05-17 aldenmere scene 1 — 12 architecture + 4 tree + 12
  foragable AI-gen meshes shipped without y_offset; everything sank.
  Took 5 visual-review iterations before the y_offset primitive was
  added.
- 2026-05-18 — prop_tree_fruit pattern at scale 0.3-0.55 floated as
  dwarf bushes ~1.15m above ground because legacy y_offset=1.337
  (constant world-units) was inherited regardless of per-instance
  scale. Fix: migrated to y_offset_mesh + added pattern-scale check.
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


def _collect_pattern_scale_ranges(game_dir: Path) -> dict[str, list[tuple[float, float]]]:
    """Scan every level's patterns; collect (scale_min, scale_max) ranges
    per def_id. A def whose patterns use scale outside its state_init.scale
    will inherit a constant legacy y_offset wrong for those instances.
    """
    out: dict[str, list[tuple[float, float]]] = {}
    levels_dir = game_dir / "levels"
    candidates: list[Path] = []
    if levels_dir.exists():
        candidates.extend(sorted(levels_dir.rglob("entities.json")))
    # Top-level entities (legacy)
    for f in sorted(game_dir.glob("entities/zz_*.json")):
        candidates.append(f)
    for jf in candidates:
        try:
            doc = json.loads(jf.read_text(encoding="utf-8"))
        except Exception:
            continue
        for pat in doc.get("patterns", []):
            if not isinstance(pat, dict):
                continue
            def_ids = []
            if pat.get("def"):
                def_ids.append(str(pat["def"]))
            for d in pat.get("def_choices", []) or []:
                def_ids.append(str(d))
            smin = float(pat.get("scale_min", 1.0))
            smax = float(pat.get("scale_max", 1.0))
            for did in def_ids:
                out.setdefault(did, []).append((smin, smax))
    return out


def check_game(game_dir: Path, strict: bool) -> int:
    fails = []
    warns = []
    pattern_scales = _collect_pattern_scale_ranges(game_dir)
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
            # Authors can opt out per-entity when the mesh has artifacts
            # below the visible base (e.g. Tripo3D debris) that need to
            # stay buried. Set `visual.y_offset_intentional: true`.
            if bool(visual.get("y_offset_intentional", False)):
                continue
            did = d.get("id", "?")
            # Two field variants. Preferred is y_offset_mesh (engine
            # multiplies by state.scale per-instance — pattern-safe).
            # Legacy is y_offset (constant world units — pattern-unsafe).
            if "y_offset_mesh" in visual:
                expected_mesh = -min_y
                actual_mesh = float(visual["y_offset_mesh"])
                shortfall = abs(expected_mesh - actual_mesh)
                tolerance = max(0.05, 0.20 * expected_mesh)
                if shortfall > tolerance:
                    fails.append(
                        f"  {did:25s}  "
                        f".glb min.y={min_y:+.3f} → expected y_offset_mesh "
                        f"≈ {expected_mesh:.3f}, actual {actual_mesh:.3f} "
                        f"(off by {shortfall:.3f})"
                    )
                continue

            # Legacy y_offset path
            expected = -min_y * scale
            y_offset = float(visual.get("y_offset", 0.0))
            shortfall = expected - y_offset
            tolerance = 0.20 * expected  # 20% tolerance
            if shortfall > tolerance:
                msg = (
                    f"  {did:25s}  "
                    f".glb min.y={min_y:+.3f} × scale={scale:.2f} "
                    f"→ expected y_offset ≈ {expected:.3f}m, "
                    f"actual {y_offset:.3f}m "
                    f"(short by {shortfall:.3f}m — mesh sinks into ground)"
                )
                fails.append(msg)
            elif shortfall > 0.05:
                msg = (
                    f"  {did:25s}  "
                    f"y_offset {y_offset:.3f}m within tolerance but "
                    f"slightly below expected {expected:.3f}m"
                )
                warns.append(msg)
            # Pattern-scale check (bug class B). If any level pattern
            # spawns this def at a scale range outside state_init.scale,
            # the legacy world-units y_offset will be wrong for those
            # instances. Force migration to y_offset_mesh.
            for (smin, smax) in pattern_scales.get(did, []):
                # If pattern's scale range BRACKETS or differs from
                # state_init.scale by more than 10%, flag.
                lo = smin
                hi = smax
                if abs(lo - scale) / max(scale, 0.01) > 0.10 or \
                   abs(hi - scale) / max(scale, 0.01) > 0.10:
                    fails.append(
                        f"  {did:25s}  "
                        f"uses legacy y_offset (constant world-units) but a "
                        f"level pattern spawns it at scale [{lo:.2f}, {hi:.2f}] "
                        f"vs def's state_init.scale={scale:.2f} — pattern "
                        f"variants will float/sink. Migrate to y_offset_mesh "
                        f"= {-min_y:.3f}."
                    )
                    break

    if fails:
        print(f"[fail] {game_dir.name} — {len(fails)} y_offset issue(s):")
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
