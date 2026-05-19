"""extract_map.py — semantic top-down map → anchor/zone/path schema
(ADR 0054 Phase 3).

Pipeline (extends Phase 0 foundation):
    load image
    → quantize + match to legend (extractor_common)
    → per legend entry:
        kind=anchor → connected components → one MapAnchor per component
                      at centroid (with footprint area + bbox + rotation hint)
        kind=zone   → continuous mask (cleaned via morph) → MapZone
                      (mask path + area in world units)
        kind=path   → mask → skeletonize (Zhang-Suen) → MapPath
                      (sequence of (x, z) world points)
    → transform image coords → world coords (centered, scale per map_size)
    → emit MapLayout

Coordinate convention:
    - Image: pixel coords, y-down, (0, 0) at top-left.
    - World: meter coords, centered at (0, 0).
      Image (px, py) maps to world (wx, wz) via:
        wx = (px - W/2) * (map_size_x / W)
        wz = (py - H/2) * (map_size_z / H)
      Y-up in world; image-y becomes world-z. This matches Yume's
      3D convention (X right, Y up, Z forward in top-down birds-eye).

Usage:
    python3 -m tools.visual_layout.extract_map --image map.png \\
        --legend tools/visual_layout/legends/map_camp_default.json \\
        --map-size 100 --output map.layout.json
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.visual_layout.extractor_common import (  # noqa: E402
    Component,
    Legend,
    connected_components,
    extract_components_from_image,
    load_image,
    save_mask_png,
)

# scikit-image is imported lazily (only the map extractor uses
# skeletonize). Avoids a hard dep for ui-only consumers.
try:
    from skimage.morphology import skeletonize
except ImportError as e:
    raise ImportError(
        "extract_map requires scikit-image. "
        "Install: pip install -r tools/visual_layout/requirements.txt"
    ) from e


# ============================================================
# DATA TYPES
# ============================================================


@dataclass
class MapAnchor:
    """One discrete entity placed at an image centroid."""

    name: str
    image_px: tuple[float, float]      # (x, y)
    world_pos: tuple[float, float]     # (x, z) in meters
    footprint_px: int                  # area in pixels
    bbox_px: tuple[int, int, int, int]
    rotation_hint: str = ""            # e.g. "face_fire_pit"; downstream rule resolves


@dataclass
class MapZone:
    """Continuous region (forest, grass, water)."""

    name: str
    mask_path: str                     # rel path to dumped PNG mask
    area_px: int
    area_world: float                  # in m²


@dataclass
class MapPath:
    """Skeletonized polyline (paths / roads). One per connected
    component in the path mask."""

    name: str
    image_pts: list[tuple[int, int]]   # ordered pixel coords
    world_pts: list[tuple[float, float]]  # ordered (x, z) meters
    length_world: float                # in meters


@dataclass
class MapLayout:
    """Result of extracting a semantic map image."""

    image_path: str
    image_size_px: tuple[int, int]     # (W, H)
    map_size: tuple[float, float]      # (size_x, size_z) in meters
    legend_name: str
    anchors: list[MapAnchor] = field(default_factory=list)
    zones: list[MapZone] = field(default_factory=list)
    paths: list[MapPath] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


# ============================================================
# COORDINATE TRANSFORM
# ============================================================


def image_px_to_world(
    px: float, py: float,
    image_size_px: tuple[int, int],
    map_size: tuple[float, float],
) -> tuple[float, float]:
    """Image pixel coords → world (x, z) meters. Centered at origin.

    Yume convention: world X = right, world Z = down-in-bird's-eye.
    Image pixel (W/2, H/2) → world (0, 0).
    """
    iw, ih = image_size_px
    mx, mz = map_size
    wx = (px - iw / 2.0) * (mx / iw)
    wz = (py - ih / 2.0) * (mz / ih)
    return (wx, wz)


# ============================================================
# PATH SKELETONIZATION
# ============================================================


def _trace_skeleton_components(skel: np.ndarray) -> list[list[tuple[int, int]]]:
    """Trace each connected component in a skeletonized mask into
    an ordered sequence of (x, y) pixel coords.

    Strategy: find connected components in the skeleton, then for
    each component pick an endpoint (degree-1 pixel) and BFS to the
    other end. If no endpoints (closed loop), pick any pixel.

    Returns: list of polylines, one per connected component.
    """
    if skel.dtype != bool:
        raise ValueError(f"expected bool skeleton, got {skel.dtype}")
    import cv2
    src = (skel.astype(np.uint8)) * 255
    n_labels, label_img, _stats, _cent = cv2.connectedComponentsWithStats(
        src, connectivity=8
    )
    polylines: list[list[tuple[int, int]]] = []
    for cid in range(1, n_labels):
        ys, xs = np.where(label_img == cid)
        if len(xs) < 2:
            continue
        # Build a point set + neighbors map
        coords = set(zip(xs.tolist(), ys.tolist()))
        # Endpoint = pixel with exactly 1 neighbor in the set
        endpoints: list[tuple[int, int]] = []
        for x, y in coords:
            n_neighbors = 0
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    if (x + dx, y + dy) in coords:
                        n_neighbors += 1
            if n_neighbors == 1:
                endpoints.append((x, y))
        # BFS from one endpoint to trace the polyline
        start = endpoints[0] if endpoints else next(iter(coords))
        visited = {start}
        order = [start]
        current = start
        while True:
            best = None
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    cand = (current[0] + dx, current[1] + dy)
                    if cand in coords and cand not in visited:
                        best = cand
                        break
                if best is not None:
                    break
            if best is None:
                break
            visited.add(best)
            order.append(best)
            current = best
        polylines.append(order)
    return polylines


def _polyline_length_world(
    polyline_px: list[tuple[int, int]],
    image_size_px: tuple[int, int],
    map_size: tuple[float, float],
) -> float:
    if len(polyline_px) < 2:
        return 0.0
    total = 0.0
    prev = image_px_to_world(*polyline_px[0], image_size_px, map_size)
    for p in polyline_px[1:]:
        cur = image_px_to_world(*p, image_size_px, map_size)
        total += float(np.hypot(cur[0] - prev[0], cur[1] - prev[1]))
        prev = cur
    return total


# ============================================================
# EXTRACTION
# ============================================================


def extract_map_layout(
    image_path: Path,
    legend: Legend,
    map_size: tuple[float, float] = (100.0, 100.0),
    *,
    skip_legend_names: tuple[str, ...] = ("background",),
    masks_out_dir: Path | None = None,
    random_state: int = 42,
) -> MapLayout:
    """Extract a semantic top-down map image into a MapLayout schema.

    Args:
        image_path:        path to the semantic map PNG.
        legend:            map legend (each entry has kind=anchor/zone/path).
        map_size:          (x, z) in meters. Determines image-px → world transform.
        skip_legend_names: legend entries to ignore.
        masks_out_dir:     if set, dump per-zone mask PNGs here. Used for
                           downstream patterns that scatter inside zones.
        random_state:      kmeans seed.

    Returns:
        MapLayout with anchors / zones / paths populated.
    """
    img = load_image(image_path)
    h, w = img.shape[:2]
    comps_by_name, masks_by_name = extract_components_from_image(
        img, legend, random_state=random_state
    )
    layout = MapLayout(
        image_path=str(image_path),
        image_size_px=(w, h),
        map_size=map_size,
        legend_name=legend.name,
    )

    for legend_name in legend.names:
        if legend_name in skip_legend_names:
            continue
        entry = legend.by_name(legend_name)
        comps = comps_by_name.get(legend_name, [])
        mask = masks_by_name.get(legend_name)

        # No matching pixels at all
        if not comps and (mask is None or not mask.any()):
            layout.warnings.append(f"missing_component: {legend_name}")
            continue

        kind = (entry.kind if entry else "anchor")

        if kind == "anchor":
            # Each connected component → one MapAnchor
            for c in comps:
                cx, cy = c.centroid_px
                wx, wz = image_px_to_world(cx, cy, (w, h), map_size)
                layout.anchors.append(
                    MapAnchor(
                        name=legend_name,
                        image_px=(cx, cy),
                        world_pos=(wx, wz),
                        footprint_px=c.area_px,
                        bbox_px=c.bbox_xywh,
                    )
                )

        elif kind == "zone":
            # Single zone for the entry (may contain multiple components,
            # but the mask is the source of truth for downstream scatter).
            if mask is None or not mask.any():
                layout.warnings.append(f"missing_component: {legend_name}")
                continue
            area_px = int(mask.sum())
            area_world = (
                area_px * (map_size[0] / w) * (map_size[1] / h)
            )
            mask_rel = ""
            if masks_out_dir is not None:
                masks_out_dir.mkdir(parents=True, exist_ok=True)
                mask_file = masks_out_dir / f"{legend_name}_mask.png"
                save_mask_png(mask, mask_file)
                mask_rel = str(mask_file.name)
            layout.zones.append(
                MapZone(
                    name=legend_name,
                    mask_path=mask_rel,
                    area_px=area_px,
                    area_world=round(area_world, 3),
                )
            )

        elif kind == "path":
            # Skeletonize, then trace each connected component
            if mask is None or not mask.any():
                layout.warnings.append(f"missing_component: {legend_name}")
                continue
            skel = skeletonize(mask)
            polylines = _trace_skeleton_components(skel)
            for poly_px in polylines:
                if len(poly_px) < 2:
                    continue
                world_pts = [
                    image_px_to_world(px, py, (w, h), map_size)
                    for (px, py) in poly_px
                ]
                length = _polyline_length_world(poly_px, (w, h), map_size)
                layout.paths.append(
                    MapPath(
                        name=legend_name,
                        image_pts=[(int(px), int(py)) for (px, py) in poly_px],
                        world_pts=[(round(x, 3), round(z, 3)) for (x, z) in world_pts],
                        length_world=round(length, 3),
                    )
                )

        else:
            layout.warnings.append(f"unknown_kind: {legend_name}={kind}")

    return layout


# ============================================================
# SERIALIZATION
# ============================================================


def layout_to_dict(layout: MapLayout) -> dict:
    return {
        "image_path": layout.image_path,
        "image_size_px": list(layout.image_size_px),
        "map_size": list(layout.map_size),
        "legend_name": layout.legend_name,
        "anchors": [
            {
                "name": a.name,
                "image_px": [round(a.image_px[0], 2), round(a.image_px[1], 2)],
                "world_pos": [round(a.world_pos[0], 3), round(a.world_pos[1], 3)],
                "footprint_px": a.footprint_px,
                "bbox_px": list(a.bbox_px),
                "rotation_hint": a.rotation_hint,
            }
            for a in layout.anchors
        ],
        "zones": [
            {
                "name": z.name,
                "mask_path": z.mask_path,
                "area_px": z.area_px,
                "area_world": z.area_world,
            }
            for z in layout.zones
        ],
        "paths": [
            {
                "name": p.name,
                "world_pts": [list(w) for w in p.world_pts],
                "length_world": p.length_world,
                "n_pts": len(p.world_pts),
            }
            for p in layout.paths
        ],
        "warnings": list(layout.warnings),
    }


# ============================================================
# CLI
# ============================================================


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="extract_map")
    ap.add_argument("--image", required=True, type=Path)
    ap.add_argument("--legend", required=True, type=Path)
    ap.add_argument("--map-size", type=float, default=100.0)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--masks-dir", type=Path, default=None)
    args = ap.parse_args(argv)

    legend = Legend.from_file(args.legend)
    layout = extract_map_layout(
        args.image, legend,
        map_size=(args.map_size, args.map_size),
        masks_out_dir=args.masks_dir,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(layout_to_dict(layout), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        f"[extract_map] {len(layout.anchors)} anchors, "
        f"{len(layout.zones)} zones, "
        f"{len(layout.paths)} paths → {args.output}"
    )
    if layout.warnings:
        print(f"  warnings: {layout.warnings}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
