#!/usr/bin/env python3
"""
Static validator: biome albedo textures must not have a radial
concentration (center significantly brighter/darker than edges).

When a tileable texture has its detail concentrated near the center
(e.g., a single radial swirl, a centered focal point), tiling it
N times across a plane produces an obvious N×N grid pattern visible
from overhead — even if the LLM that asked for "a water texture"
got one that looks fine in isolation.

Measures: mean intensity within r<200px of center vs r>400px from
center. If diff > THRESHOLD (default 25 on 0-255 scale), flag as
non-tileable.

Empirical case 2026-05-23: aldenmere proto_village wide-corner
sanity captures showed checker pattern in the corners. Investigation
revealed water_albedo (diff=63) and path_albedo (diff=38) both have
radial concentration that becomes visible grid pattern when tiled
at uv_tile=30 across the 80m plane.

Usage:
    python3 tools/validators/validate_tileable_albedo.py
    python3 tools/validators/validate_tileable_albedo.py demo_aldenmere --strict

Exit code:
    0 — clean OR --strict not requested
    1 — at least one biome albedo flagged AND --strict given
"""

import os
import sys
from pathlib import Path
from statistics import mean

try:
    from PIL import Image
except ImportError:
    print("[validate_tileable_albedo] PIL not available — skipping check")
    sys.exit(0)


HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"

# Diff threshold (0-255 intensity scale). Above this is flagged.
RADIAL_DIFF_THRESHOLD = 25


def measure_radial_concentration(img_path: Path) -> float:
    """Return |center_intensity - edge_intensity| on the 0-255 scale."""
    img = Image.open(img_path).convert("RGB")
    w, h = img.size
    cx, cy = w / 2, h / 2
    # Sample stride for speed
    stride = max(4, w // 256)
    center_samples = []
    edge_samples = []
    r_inner = min(w, h) * 0.2
    r_outer = min(w, h) * 0.4
    for y in range(0, h, stride):
        for x in range(0, w, stride):
            r2 = (x - cx) ** 2 + (y - cy) ** 2
            px = img.getpixel((x, y))
            intensity = (px[0] + px[1] + px[2]) / 3
            if r2 < r_inner ** 2:
                center_samples.append(intensity)
            elif r2 > r_outer ** 2:
                edge_samples.append(intensity)
    if not center_samples or not edge_samples:
        return 0.0
    return abs(mean(center_samples) - mean(edge_samples))


def scan_game(game_dir: Path) -> list[tuple[str, Path, float]]:
    """Scan biome_*.png textures, return list of (biome, path, diff) over threshold."""
    tex_dir = game_dir / "assets" / "textures"
    if not tex_dir.is_dir():
        return []
    flagged: list[tuple[str, Path, float]] = []
    for fp in sorted(tex_dir.glob("biome_*.png")):
        # Parse biome name from filename: biome_water_xxx.png → water
        name_parts = fp.stem.split("_")
        biome = name_parts[1] if len(name_parts) >= 2 else "?"
        diff = measure_radial_concentration(fp)
        if diff > RADIAL_DIFF_THRESHOLD:
            flagged.append((biome, fp, diff))
    return flagged


def main():
    args = sys.argv[1:]
    strict = "--strict" in args
    targets = [a for a in args if not a.startswith("--")]
    if not targets:
        targets = [d.name for d in DATA_ROOT.iterdir() if d.is_dir() and d.name.startswith("demo_")]

    any_flagged = False
    for game in targets:
        gdir = DATA_ROOT / game
        if not gdir.is_dir():
            continue
        flagged = scan_game(gdir)
        if flagged:
            any_flagged = True
            print(f"[warn] {game}: {len(flagged)} biome albedo(s) with radial concentration > {RADIAL_DIFF_THRESHOLD}:")
            for biome, fp, diff in flagged:
                rel = fp.relative_to(REPO_ROOT)
                print(f"  - biome_{biome}: diff={diff:.0f} ({rel})")
                print(f"    fix: regenerate with nanobanana, prompt should include")
                print(f"         'uniform random distribution, no focal point, seamless")
                print(f"         tileable, tile boundary not detectable from any angle'")
        else:
            print(f"[ok] {game}: all biome albedos uniformly distributed")

    if any_flagged and strict:
        sys.exit(1)


if __name__ == "__main__":
    main()
