"""compare_semantic.py — close the feedback loop on text-to-world.

The DESIRED semantic is what the LLM drew (a top-down position spec).
The ACTUAL semantic is synthesized from the entity placements that
compose_world emitted into the level — each entity rendered as a flat
colored footprint at its world (x, z), using the catalog's class hex.

Diff = per-class IoU + coverage delta + a colour-coded image (R=desired
but absent, G=match, B=actual but unwanted). Gives a NUMERICAL signal
of how well the extraction + placement matched the LLM's positional
intent — way better than my squinting at captures.

Usage:
    python3 -m tools.visual_layout.compare_semantic <game> \\
        [--catalog /path/to/catalog.json]

Outputs:
    <game>/assets/layouts/semantic_actual.png  (synthesized)
    <game>/assets/layouts/semantic_diff.png    (colour-coded diff)
    stdout: per-class IoU + coverage table (sortable)

2026-05-29.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from tools.visual_layout import lib_extract as cv

ROOT = Path(__file__).resolve().parents[2]


def hex_to_rgb(hex_str: str) -> tuple[int, int, int]:
    h = hex_str.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def _normalize_bucket(cls: str) -> str:
    """Strip house-size-bucket prefixes so `large_house` → `house`."""
    for p in ("large_", "medium_", "small_"):
        if cls.startswith(p):
            return cls[len(p):]
    return cls


# Classes whose top-down footprint reads as a round canopy/blob (the LLM
# draws them as circles). Everything else is a structural rectangle.
_ROUND_CLASSES = {"tree", "rock", "flower_patch", "hay_bale", "lantern"}


def synthesize_actual_semantic(level_entities: list[dict], catalog: dict,
                               image_size: tuple[int, int],
                               world_size_m: tuple[float, float],
                               strategies: dict) -> np.ndarray:
    """Render entities as solid-color footprints into a top-down canvas,
    matching the semantic_map convention (world XZ → pixel, no V flip).

    Background filled with the dominant terrain class colour (typically
    grass). Each object entity's footprint is read from its strategy's
    `canonical_size_meters` (the SAME dimensions the engine renders) — no
    magic radii, no 1m default. Round classes paint as an ellipse, the
    rest as a (yaw-rotated) rectangle.
    """
    W, H = image_size
    plane_w, plane_h = world_size_m
    canvas = np.zeros((H, W, 3), dtype=np.uint8)

    # Background: dominant terrain class (largest expected_coverage_pct)
    terrains = [c for c in catalog.get("classes", [])
                if c.get("intent_type") == "terrain_shader"]
    if terrains:
        bg_cls = max(terrains, key=lambda c: c.get("expected_coverage_pct", 0))
        canvas[:, :] = hex_to_rgb(bg_cls["hex"])

    # Class color lookup (by name)
    cls_color = {c["name"]: hex_to_rgb(c["hex"])
                 for c in catalog.get("classes", [])}

    # Footprint dimensions per class, read from the SAME canonical_size_meters
    # the engine uses (no magic radii). Fall back to 1m if a class lacks one.
    strat_classes = strategies.get("classes", strategies)

    def footprint_m(cls: str) -> tuple[float, float]:
        cs = (strat_classes.get(cls) or {}).get("canonical_size_meters")
        if cs and len(cs) >= 3:
            return float(cs[0]), float(cs[2])
        return 1.0, 1.0

    # Paint via PIL for clean rotated rectangles (fences need rotation)
    img = Image.fromarray(canvas, "RGB")
    draw = ImageDraw.Draw(img)

    def world_to_pixel(wx: float, wz: float) -> tuple[float, float]:
        return ((wx + plane_w * 0.5) / plane_w * W,
                (wz + plane_h * 0.5) / plane_h * H)

    def m_to_px_x(m: float) -> float:
        return m / plane_w * W

    def m_to_px_y(m: float) -> float:
        return m / plane_h * H

    placed_count: dict[str, int] = {}
    for inst in level_entities:
        cls_name = _normalize_bucket(str(inst.get("class", inst.get("def", ""))))
        if cls_name not in cls_color:
            # Could be free_camera/world_clock/player_input_anchor — skip
            continue
        color = cls_color[cls_name]
        # Position: top-level `position` wins (matches entity._apply_overrides)
        pos = inst.get("position") or [0, 0, 0]
        wx, _, wz = pos[0], pos[1] if len(pos) > 1 else 0, pos[2] if len(pos) > 2 else 0
        # Footprint from the engine's canonical_size_meters × per-instance scale
        scale = inst.get("scale") or [1.0, 1.0, 1.0]
        sx_s = float(scale[0])
        sz_s = float(scale[2]) if len(scale) > 2 else sx_s
        fw, fd = footprint_m(cls_name)
        fw *= sx_s
        fd *= sz_s
        yaw = float(inst.get("yaw", 0.0))
        cx, cy = world_to_pixel(wx, wz)

        if cls_name in _ROUND_CLASSES:
            # Round canopy/blob: ellipse with the canonical footprint as diameter
            rx_px = m_to_px_x(fw * 0.5)
            ry_px = m_to_px_y(fd * 0.5)
            draw.ellipse([(cx - rx_px, cy - ry_px), (cx + rx_px, cy + ry_px)], fill=color)
        else:
            # Buildings + fence + banner: yaw-rotated rectangle from canonical bbox
            hw = m_to_px_x(fw * 0.5)
            hh = m_to_px_y(fd * 0.5)
            cos_y, sin_y = math.cos(yaw), math.sin(yaw)
            corners = []
            for lx, ly in ((-hw, -hh), (+hw, -hh), (+hw, +hh), (-hw, +hh)):
                rx = lx * cos_y - ly * sin_y
                ry = lx * sin_y + ly * cos_y
                corners.append((cx + rx, cy + ry))
            draw.polygon(corners, fill=color)
        placed_count[cls_name] = placed_count.get(cls_name, 0) + 1

    canvas = np.array(img)
    return canvas, placed_count


def compare(desired: np.ndarray, actual: np.ndarray,
            catalog: dict) -> tuple[dict, np.ndarray]:
    """Compute per-class IoU + coverage delta. Build a colour-coded diff
    PNG. Returns (per_class_stats, diff_image).

    Both desired (the LLM map) and actual (the synthesized footprints)
    are partitioned with the SAME `threshold_nearest_palette` the
    extractor uses — exclusive nearest-class assignment, no free
    threshold constant. This makes the diff apples-to-apples: the
    extractor fills exactly the region the comparator scores against,
    and near-neighbour hues (e.g. rock vs tower grey) can't double-count.
    """
    if desired.shape != actual.shape:
        # Resize actual to match desired's resolution
        a_img = Image.fromarray(actual, "RGB").resize(
            (desired.shape[1], desired.shape[0]), Image.NEAREST)
        actual = np.array(a_img)

    H, W = desired.shape[:2]
    diff = np.full((H, W, 3), 30, dtype=np.uint8)   # dark neutral background

    # Same hard partition the extractor uses (lib_extract.threshold_nearest_palette).
    palette = [(c["name"], c["hex"]) for c in catalog.get("classes", [])
               if c.get("intent_type") in ("terrain_shader", "object_placement")]
    idx_of = {name: i for i, (name, _h) in enumerate(palette)}
    label_des = cv.threshold_nearest_palette(desired, palette)
    label_act = cv.threshold_nearest_palette(actual, palette)

    stats: dict = {}
    for cls in catalog.get("classes", []):
        name = cls["name"]
        # terrain_shader classes (grass, dirt_path) are rendered via the
        # ground_paint texture, NOT entities — they never appear in the
        # synthesized actual, so painting their diff would show the whole
        # terrain region as a false "missing" (red). Skip them entirely.
        if cls.get("intent_type") == "terrain_shader":
            continue
        if name not in idx_of:
            continue
        i = idx_of[name]
        des_mask = label_des == i
        act_mask = label_act == i
        inter = des_mask & act_mask
        union = des_mask | act_mask
        iou = inter.sum() / max(1, union.sum())
        n_pix = H * W
        des_pct = 100.0 * des_mask.sum() / n_pix
        act_pct = 100.0 * act_mask.sum() / n_pix
        stats[name] = {
            "iou": float(iou),
            "desired_pct": float(des_pct),
            "actual_pct": float(act_pct),
            "delta_pct": float(act_pct - des_pct),
        }
        # Paint diff:
        # green = match, red = desired but missing, blue = actual but unwanted
        only_des = des_mask & ~act_mask
        only_act = ~des_mask & act_mask
        diff[inter] = [60, 200, 60]
        diff[only_des] = [220, 60, 60]
        diff[only_act] = [60, 60, 220]

    return stats, diff


def print_report(stats: dict, placed: dict, catalog: dict) -> None:
    # Filter out terrain_shader classes from per-entity report — they're
    # encoded in ground_paint texture, not entity placements; their diff
    # is meaningless for the extraction-loop signal.
    terrain_names = {c["name"] for c in catalog.get("classes", [])
                     if c.get("intent_type") == "terrain_shader"}
    print(f"\n{'class':22s} {'IoU':>6s} {'desired%':>9s} {'actual%':>8s} "
          f"{'delta%':>8s} {'placed':>7s}")
    print("-" * 70)
    # Sort by IoU ascending (worst first → drives the eye to problems)
    rows = sorted(((n, s) for n, s in stats.items() if n not in terrain_names),
                  key=lambda kv: kv[1]["iou"])
    for name, s in rows:
        flag = ""
        if s["iou"] < 0.10 and s["desired_pct"] > 0.05:
            flag = "  ← LOW IoU (placement / count off)"
        elif s["actual_pct"] > s["desired_pct"] * 2 and s["desired_pct"] > 0.05:
            flag = "  ← OVER (actual >> desired)"
        elif s["desired_pct"] > s["actual_pct"] * 2 and s["actual_pct"] > 0.05:
            flag = "  ← UNDER (actual << desired)"
        print(f"{name:22s} {s['iou']:6.2f} {s['desired_pct']:9.2f} "
              f"{s['actual_pct']:8.2f} {s['delta_pct']:+8.2f} "
              f"{placed.get(name, 0):7d}{flag}")


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print("usage: compare_semantic.py <game> [--catalog <path>]")
        return 2
    game = args[0]
    catalog_path = None
    if "--catalog" in sys.argv:
        catalog_path = sys.argv[sys.argv.index("--catalog") + 1]

    game_dir = ROOT / "godot" / "data" / game
    layouts = game_dir / "assets" / "layouts"
    desired_png = layouts / "semantic_map.png"
    actual_png = layouts / "semantic_actual.png"
    diff_png = layouts / "semantic_diff.png"

    if not desired_png.exists():
        print(f"missing {desired_png}")
        return 1

    if catalog_path is None:
        # Look in per-game data dir first (compose_scene can copy it there),
        # else fall back to a /tmp convention.
        for cand in (game_dir / "catalog.json",
                     Path(f"/tmp/_{game.replace('demo_', '')}_catalog.json")):
            if cand.exists():
                catalog_path = str(cand)
                break
    if catalog_path is None or not Path(catalog_path).exists():
        print("no catalog found (--catalog <path> or place at "
              f"{game_dir}/catalog.json)")
        return 1
    catalog = json.loads(Path(catalog_path).read_text())

    # Strategy lib supplies canonical_size_meters per class (the engine's
    # footprint dimensions) so the synthesized footprints are faithful.
    strat_path = ROOT / "godot" / "data" / "lib" / "extraction_strategies.json"
    strategies = json.loads(strat_path.read_text()) if strat_path.exists() else {}

    # Scene world size — read from scene.json's ground mesh.size
    scene = json.loads((game_dir / "scene.json").read_text())
    size_arr = scene.get("ground", {}).get("mesh", {}).get("size", [100.0, 100.0])
    world_size_m = (float(size_arr[0]), float(size_arr[1]))

    # Image size matches semantic_map
    des_img = Image.open(desired_png).convert("RGB")
    image_size = des_img.size

    # Collect all level instances
    instances: list[dict] = []
    for level_file in sorted((game_dir / "levels").glob("*/entities.json")):
        d = json.loads(level_file.read_text())
        instances.extend(d.get("initial_instances", []))

    # Synthesize actual
    actual, placed = synthesize_actual_semantic(
        instances, catalog, image_size, world_size_m, strategies
    )
    Image.fromarray(actual, "RGB").save(actual_png)
    print(f"actual semantic synthesized: {actual_png}")

    # Compare
    desired = np.array(des_img)
    stats, diff = compare(desired, actual, catalog)
    Image.fromarray(diff, "RGB").save(diff_png)
    print(f"diff saved: {diff_png}")

    print_report(stats, placed, catalog)
    return 0


if __name__ == "__main__":
    sys.exit(main())
