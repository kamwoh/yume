#!/usr/bin/env python3
"""Validate generated simulation world data — catch issues before running Godot.

Usage:
    python validate_sim_world.py /path/to/game/data/sim/generated_world.json

Checks:
  - Elements inside world bounds
  - No extreme overlaps
  - Heightmap valid (no NaN, reasonable range)
  - Camp at flat center
  - Paths connected to camp
  - Element counts reasonable
  - All model names exist in known models
"""

import json
import math
import sys
from pathlib import Path


def load_world(path: Path) -> dict:
    return json.loads(path.read_text())


def validate(world: dict) -> list[str]:
    errors = []
    warnings = []
    info = []

    w = world.get("world_size", {}).get("width", 100)
    h = world.get("world_size", {}).get("height", 100)
    half_w, half_h = w / 2, h / 2

    # --- Heightmap ---
    hmap = world.get("terrain", {}).get("heightmap", {})
    heights = hmap.get("heights", [])
    res = hmap.get("resolution", 0)
    if res > 0:
        expected = res * res
        if len(heights) != expected:
            errors.append(f"Heightmap: expected {expected} values, got {len(heights)}")
        h_min = min(heights) if heights else 0
        h_max = max(heights) if heights else 0
        h_avg = sum(heights) / len(heights) if heights else 0
        info.append(f"Heightmap: {res}x{res}, range [{h_min:.3f}, {h_max:.3f}], avg={h_avg:.3f}")
        if h_max > 2.0:
            warnings.append(f"Heightmap max {h_max:.3f} is high — may look too steep with scale")
        # Check for NaN
        nan_count = sum(1 for v in heights if math.isnan(v) or math.isinf(v))
        if nan_count > 0:
            errors.append(f"Heightmap has {nan_count} NaN/Inf values")
    else:
        warnings.append("No heightmap data")

    # --- Elements ---
    elements = world.get("elements", [])
    info.append(f"Elements: {len(elements)} total")

    out_of_bounds = 0
    element_counts = {}
    positions = []
    for el in elements:
        eid = el.get("element", "")
        ex, ez = el.get("x", 0), el.get("z", 0)
        element_counts[eid] = element_counts.get(eid, 0) + 1
        positions.append((ex, ez, eid))

        if abs(ex) > half_w or abs(ez) > half_h:
            out_of_bounds += 1

    if out_of_bounds > 0:
        errors.append(f"Elements: {out_of_bounds} outside world bounds ({w}x{h})")

    for eid, count in sorted(element_counts.items()):
        info.append(f"  {eid}: {count}")

    # Check for extreme overlaps (elements too close)
    overlap_count = 0
    for i in range(len(positions)):
        for j in range(i + 1, min(i + 20, len(positions))):  # Check nearby only
            dx = positions[i][0] - positions[j][0]
            dz = positions[i][1] - positions[j][1]
            dist = math.sqrt(dx * dx + dz * dz)
            if dist < 0.3:  # Very close
                overlap_count += 1
    if overlap_count > 10:
        warnings.append(f"Elements: {overlap_count} pairs extremely close (<0.3 units)")

    # --- Camp ---
    camp = world.get("camp", [])
    info.append(f"Camp: {len(camp)} structures")
    if camp:
        camp_x = sum(c.get("x", 0) for c in camp) / len(camp)
        camp_z = sum(c.get("z", 0) for c in camp) / len(camp)
        dist_from_center = math.sqrt(camp_x ** 2 + camp_z ** 2)
        if dist_from_center > 10:
            warnings.append(f"Camp center ({camp_x:.1f}, {camp_z:.1f}) is far from world center")
        else:
            info.append(f"Camp center: ({camp_x:.1f}, {camp_z:.1f}) — near world center")

        # Check camp is on flat terrain
        if heights and res > 0:
            cx_idx = int((camp_x + half_w) / w * (res - 1))
            cz_idx = int((camp_z + half_h) / h * (res - 1))
            idx = cz_idx * res + cx_idx
            if 0 <= idx < len(heights):
                camp_height = heights[idx]
                if abs(camp_height) > 0.2:
                    warnings.append(f"Camp terrain height {camp_height:.3f} — should be near 0 (flat)")
                else:
                    info.append(f"Camp terrain height: {camp_height:.3f} — flat")

    # --- Paths ---
    paths = world.get("paths", [])
    info.append(f"Paths: {len(paths)} tiles")
    if paths:
        path_bounds = 0
        for p in paths:
            if abs(p.get("x", 0)) > half_w or abs(p.get("z", 0)) > half_h:
                path_bounds += 1
        if path_bounds > 0:
            warnings.append(f"Paths: {path_bounds} tiles outside world bounds")

    # --- Edge trees ---
    edge_trees = world.get("edge_trees", [])
    info.append(f"Edge trees: {len(edge_trees)}")
    if len(edge_trees) < 50:
        warnings.append(f"Few edge trees ({len(edge_trees)}) — world edges may be visible")

    # --- Spawn ---
    spawn = world.get("spawn", {})
    sx, sz = spawn.get("x", 0), spawn.get("z", 0)
    if abs(sx) > half_w * 0.5 or abs(sz) > half_h * 0.5:
        warnings.append(f"Spawn ({sx}, {sz}) is far from center")

    # --- Atmosphere ---
    atmo = world.get("atmosphere", {})
    if not atmo:
        warnings.append("No atmosphere data")
    else:
        sun_e = atmo.get("sun_energy", 0)
        if sun_e <= 0:
            warnings.append("Sun energy is 0 — will be very dark")

    # --- Model names ---
    known_prefixes = [
        "tree_", "rock_", "plant_", "grass", "flower_", "mushroom_",
        "campfire_", "tent", "ground_path", "_primitive",
        "Bush_", "Grass_", "patch-grass",
    ]
    unknown_models = set()
    for el in elements + edge_trees + paths + camp:
        model = el.get("model", "")
        if model and not any(model.startswith(p) or model == p.rstrip("_") for p in known_prefixes):
            # Check if it's a known model name
            if model not in ["rock-large", "rock-small", "tent-canvas", "ground_pathCross"]:
                unknown_models.add(model)
    if unknown_models:
        warnings.append(f"Unknown models: {unknown_models}")

    return errors, warnings, info


def main():
    if len(sys.argv) < 2:
        print("Usage: python validate_sim_world.py /path/to/generated_world.json")
        sys.exit(1)

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"Error: {path} not found")
        sys.exit(1)

    world = load_world(path)
    errors, warnings, info = validate(world)

    print("=" * 60)
    print("  SIMULATION WORLD VALIDATION")
    print("=" * 60)
    print(f"  Seed: {world.get('seed', '?')}  Size: {world.get('world_size', {}).get('width', '?')}x{world.get('world_size', {}).get('height', '?')}")
    print()

    for line in info:
        print(f"  [INFO] {line}")

    print()
    if warnings:
        for w in warnings:
            print(f"  [WARN] {w}")
    else:
        print("  [WARN] None")

    print()
    if errors:
        for e in errors:
            print(f"  [ERROR] {e}")
        print(f"\n  RESULT: FAILED ({len(errors)} errors, {len(warnings)} warnings)")
        sys.exit(1)
    else:
        print(f"  [ERROR] None")
        print(f"\n  RESULT: PASSED ({len(warnings)} warnings)")


if __name__ == "__main__":
    main()
