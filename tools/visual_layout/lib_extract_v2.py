"""lib_extract_v2.py — Strategy-dispatched extraction for stage-5 of the
text-to-world pipeline. Sits on top of lib_extract.py's image-processing
helpers.

The yume-scene-class-catalog skill injects a `strategy` block into each
`object_placement` class entry (see data/lib/extraction_strategies.json
for the vocabulary). This module reads those strategies and dispatches
to the right extraction method.

Pure stdlib + numpy + PIL — no scipy.

Vocabulary (mirrors data/lib/extraction_strategies.json):
  extraction_method: single_instance / cluster_extract / snap_to_anchor /
                     scatter_in_mask / polygon_decompose / llm_gestalt
  rotation_rule:     no_rotation / face_nearest_road / face_anchor /
                     along_tangent / perpendicular_to_water / random_seeded
  y_anchor:          heightmap_sample / water_level / anchor_floor / constant
  primitive:         prim_unit_box / prim_unit_cylinder / prim_unit_sphere

Task #136 ships: single_instance, cluster_extract, snap_to_anchor,
                  scatter_in_mask + all rotation rules EXCEPT
                  along_tangent (lives in polygon_decompose, task #137)
                  + all y_anchors EXCEPT anchor_floor (deferred).
Task #137 adds:  polygon_decompose + along_tangent.
Task #138 adds:  llm_gestalt.
"""
from __future__ import annotations

import math
import random
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

from tools.visual_layout import lib_extract as cv


# ============================================================
# HEIGHTMAP SAMPLER (mirrors compose_world.HeightmapSampler)
# ============================================================

class HeightmapSampler:
    """Bilinear-sample a heightmap PNG at world coords. Mirrors the
    ground shader's UV math so entity Y values match the displaced
    ground surface.

    plane_size_m is the ground's X+Z extent in meters; height_scale
    + height_offset come from scene.json.ground.mesh.{height_scale,
    height_offset}.
    """

    def __init__(
        self,
        heightmap_path: str | Path,
        plane_size_m: float,
        height_scale: float = 3.0,
        height_offset: float = -0.5,
    ) -> None:
        img = Image.open(heightmap_path).convert("L")
        self.arr = np.array(img, dtype=np.float32) / 255.0
        self.h, self.w = self.arr.shape
        self.plane = float(plane_size_m)
        self.scale = float(height_scale)
        self.offset = float(height_offset)

    def y_at(self, wx: float, wz: float) -> float:
        """Bilinear sample at world (x, z). Returns y in meters."""
        u = (wx + self.plane * 0.5) / self.plane
        v = 1.0 - (wz + self.plane * 0.5) / self.plane
        u = max(0.0, min(1.0 - 1e-6, u))
        v = max(0.0, min(1.0 - 1e-6, v))
        # Convert to pixel coords
        fx = u * (self.w - 1)
        fy = v * (self.h - 1)
        x0 = int(math.floor(fx)); x1 = min(x0 + 1, self.w - 1)
        y0 = int(math.floor(fy)); y1 = min(y0 + 1, self.h - 1)
        dx = fx - x0; dy = fy - y0
        h00 = self.arr[y0, x0]; h10 = self.arr[y0, x1]
        h01 = self.arr[y1, x0]; h11 = self.arr[y1, x1]
        h_top = h00 * (1 - dx) + h10 * dx
        h_bot = h01 * (1 - dx) + h11 * dx
        h = h_top * (1 - dy) + h_bot * dy
        return round(float((h + self.offset) * self.scale), 3)


# ============================================================
# Y-ANCHOR DISPATCH
# ============================================================

def resolve_y(
    wx: float,
    wz: float,
    y_anchor: str,
    *,
    sampler: HeightmapSampler | None,
    y_value_meters: float = 0.0,
) -> float:
    """Compute the Y coordinate for an instance per its y_anchor rule."""
    if y_anchor == "heightmap_sample":
        if sampler is None:
            return 0.0
        return sampler.y_at(wx, wz)
    if y_anchor == "water_level":
        return 0.0
    if y_anchor == "constant":
        return float(y_value_meters)
    if y_anchor == "anchor_floor":
        # Deferred — task #136 doesn't implement. Fall back to 0.
        return 0.0
    return 0.0


# ============================================================
# ROTATION DISPATCH
# ============================================================

def resolve_facing(
    cx_px: float,
    cy_px: float,
    rotation_rule: str,
    *,
    image_size: tuple[int, int],
    world_size_m: tuple[float, float],
    label_map: np.ndarray | None = None,
    palette: list[tuple[str, str]] | None = None,
    anchors: dict[str, Any] | None = None,
    rng: random.Random | None = None,
) -> float:
    """Compute facing (radians, +Y rotation) per the rule. Returns 0.0
    for any rule that can't resolve in this caller's context."""
    if rotation_rule == "no_rotation":
        return 0.0

    if rotation_rule == "random_seeded":
        r = rng if rng is not None else random.Random()
        return round(r.uniform(0.0, 2 * math.pi), 4)

    # Compute world coords for this instance — used by face_anchor +
    # face_nearest_road + perpendicular_to_water.
    wx, wz = cv.pixel_to_world(cx_px, cy_px, image_size, world_size_m)

    if rotation_rule == "face_anchor":
        if anchors is None or "focal_anchor" not in anchors:
            return 0.0
        ax, az = anchors["focal_anchor"]
        return round(math.atan2(ax - wx, -(az - wz)), 4)

    if rotation_rule == "face_nearest_road":
        if label_map is None or palette is None:
            return 0.0
        target = _find_class_idx(palette, ["cobblestone", "dirt_path", "road",
                                            "stone_road"])
        if target is None:
            return 0.0
        nearest = _nearest_pixel_of_class(label_map, target, cx_px, cy_px)
        if nearest is None:
            return 0.0
        nwx, nwz = cv.pixel_to_world(*nearest, image_size, world_size_m)
        return round(math.atan2(nwx - wx, -(nwz - wz)), 4)

    if rotation_rule == "perpendicular_to_water":
        if label_map is None or palette is None:
            return 0.0
        target = _find_class_idx(palette, ["water_surface", "water", "river",
                                            "alien_water"])
        if target is None:
            return 0.0
        nearest = _nearest_pixel_of_class(label_map, target, cx_px, cy_px)
        if nearest is None:
            return 0.0
        nwx, nwz = cv.pixel_to_world(*nearest, image_size, world_size_m)
        # The bridge points TOWARD the water (its long axis crosses it)
        return round(math.atan2(nwx - wx, -(nwz - wz)), 4)

    # along_tangent is handled inside polygon_decompose; standalone here = 0.
    return 0.0


def _find_class_idx(
    palette: list[tuple[str, str]], candidate_names: list[str]
) -> int | None:
    """Return the palette index of the first candidate name present, else None."""
    for cand in candidate_names:
        for i, (name, _hex) in enumerate(palette):
            if name == cand:
                return i
    return None


def _nearest_pixel_of_class(
    label_map: np.ndarray,
    class_idx: int,
    cx_px: float,
    cy_px: float,
) -> tuple[float, float] | None:
    """Find the (px_x, px_y) of the class_idx pixel nearest the point."""
    ys, xs = np.where(label_map == class_idx)
    if ys.size == 0:
        return None
    dx = xs.astype(np.float32) - cx_px
    dy = ys.astype(np.float32) - cy_px
    d2 = dx * dx + dy * dy
    i = int(np.argmin(d2))
    return float(xs[i]), float(ys[i])


# ============================================================
# EXTRACTION-METHOD DISPATCH
# ============================================================

def extract_class(
    *,
    class_entry: dict,
    label_map: np.ndarray,
    palette: list[tuple[str, str]],
    palette_idx: int,
    image_size: tuple[int, int],
    world_size_m: tuple[float, float],
    sampler: HeightmapSampler | None = None,
    anchors: dict[str, Any] | None = None,
    rng_seed: int = 0,
) -> list[dict]:
    """Dispatch on class_entry['strategy']['extraction_method'] and return
    a list of instance dicts of the form:

      {
        "class": "<class_name>",
        "id": "<class>_<n>",
        "position": [wx, wy, wz],
        "facing": <radians>,
        "scale": [W, H, D],
        "primitive": "prim_unit_box|cylinder|sphere",
      }
    """
    strategy = class_entry.get("strategy")
    if strategy is None:
        return []

    method = strategy.get("extraction_method", "single_instance")
    name = class_entry["name"]
    rng = random.Random(rng_seed + hash(name) % 100000)
    mask = label_map == palette_idx

    if method == "single_instance":
        return _extract_single(
            name=name, mask=mask, class_entry=class_entry,
            label_map=label_map, palette=palette,
            image_size=image_size, world_size_m=world_size_m,
            sampler=sampler, anchors=anchors, rng=rng,
        )
    if method == "cluster_extract":
        return _extract_cluster(
            name=name, mask=mask, class_entry=class_entry,
            label_map=label_map, palette=palette,
            image_size=image_size, world_size_m=world_size_m,
            sampler=sampler, anchors=anchors, rng=rng,
        )
    if method == "snap_to_anchor":
        return _extract_snap_to_anchor(
            name=name, class_entry=class_entry,
            label_map=label_map, palette=palette,
            image_size=image_size, world_size_m=world_size_m,
            sampler=sampler, anchors=anchors, rng=rng,
        )
    if method == "scatter_in_mask":
        return _extract_scatter(
            name=name, class_entry=class_entry,
            label_map=label_map, palette=palette,
            image_size=image_size, world_size_m=world_size_m,
            sampler=sampler, anchors=anchors, rng=rng,
        )
    if method == "polygon_decompose":
        # Task #137 will populate this. Return empty for now so callers
        # don't crash, but log to stderr.
        import sys
        print(f"[lib_extract_v2] polygon_decompose not yet implemented "
              f"(task #137) — skipping class '{name}'", file=sys.stderr)
        return []
    if method == "llm_gestalt":
        # Task #138 will populate this. Same fallthrough as polygon_decompose.
        import sys
        print(f"[lib_extract_v2] llm_gestalt not yet implemented "
              f"(task #138) — skipping class '{name}'", file=sys.stderr)
        return []
    if method == "require_adjacent":
        # Bridge-style strategy: only extract instances of THIS class
        # whose connected component touches `must_touch_class`. Light
        # variant — treat like cluster_extract with a touch-filter.
        return _extract_require_adjacent(
            name=name, mask=mask, class_entry=class_entry,
            label_map=label_map, palette=palette,
            image_size=image_size, world_size_m=world_size_m,
            sampler=sampler, anchors=anchors, rng=rng,
        )

    return []


# ---- single_instance ---------------------------------------------------

def _extract_single(*, name, mask, class_entry, label_map, palette,
                    image_size, world_size_m, sampler, anchors, rng):
    """Pick the LARGEST connected component, emit one instance at its
    centroid. Use for unique focal objects (well, statue)."""
    strategy = class_entry["strategy"]
    comps = cv.connected_components(mask, min_area=strategy.get("min_area_px", 4))
    if not comps:
        return []
    comp = max(comps, key=lambda c: c["area_px"])
    return [_emit_instance(
        name=name, idx=1, centroid_px=comp["centroid"],
        class_entry=class_entry, label_map=label_map, palette=palette,
        image_size=image_size, world_size_m=world_size_m,
        sampler=sampler, anchors=anchors, rng=rng,
    )]


# ---- cluster_extract ---------------------------------------------------

def _extract_cluster(*, name, mask, class_entry, label_map, palette,
                     image_size, world_size_m, sampler, anchors, rng):
    """Connected components → merge components whose centroids are within
    `cluster_within_meters` of each other → emit one instance per cluster
    at the merged centroid."""
    strategy = class_entry["strategy"]
    min_area = int(strategy.get("min_area_px", 20))
    comps = cv.connected_components(mask, min_area=min_area)
    if not comps:
        return []

    cluster_m = float(strategy.get("cluster_within_meters", 2.0))
    # Convert meters to pixels (use mean of x,z plane scales)
    iw, ih = image_size
    wx_m, wz_m = world_size_m
    px_per_m_x = iw / wx_m
    px_per_m_z = ih / wz_m
    cluster_px = cluster_m * 0.5 * (px_per_m_x + px_per_m_z)
    cluster_px2 = cluster_px * cluster_px

    # Union-find clustering on centroids
    parents = list(range(len(comps)))
    def find(i):
        while parents[i] != i:
            parents[i] = parents[parents[i]]
            i = parents[i]
        return i
    def union(i, j):
        ri, rj = find(i), find(j)
        if ri != rj:
            parents[rj] = ri

    centroids = [c["centroid"] for c in comps]
    for i in range(len(comps)):
        for j in range(i + 1, len(comps)):
            dx = centroids[i][0] - centroids[j][0]
            dy = centroids[i][1] - centroids[j][1]
            if dx * dx + dy * dy <= cluster_px2:
                union(i, j)

    clusters: dict[int, list[int]] = {}
    for i in range(len(comps)):
        r = find(i)
        clusters.setdefault(r, []).append(i)

    instances = []
    for n, (_root, members) in enumerate(clusters.items(), start=1):
        total_area = sum(comps[m]["area_px"] for m in members)
        cx = sum(comps[m]["centroid"][0] * comps[m]["area_px"]
                 for m in members) / total_area
        cy = sum(comps[m]["centroid"][1] * comps[m]["area_px"]
                 for m in members) / total_area
        instances.append(_emit_instance(
            name=name, idx=n, centroid_px=(cx, cy),
            class_entry=class_entry, label_map=label_map, palette=palette,
            image_size=image_size, world_size_m=world_size_m,
            sampler=sampler, anchors=anchors, rng=rng,
        ))
    return instances


# ---- snap_to_anchor ----------------------------------------------------

def _extract_snap_to_anchor(*, name, class_entry, label_map, palette,
                            image_size, world_size_m, sampler, anchors, rng):
    """Spawn instance(s) at named anchor positions. The catalog's
    `anchors` dict is built upstream (e.g., focal_anchor = plaza centroid,
    wall_ring_corners = list of (wx, wz) tuples)."""
    if not anchors:
        return []
    strategy = class_entry["strategy"]
    src = strategy.get("anchor_source", "focal_anchor")
    if src not in anchors:
        return []
    val = anchors[src]
    # val can be a single (wx, wz) tuple OR a list of tuples.
    if isinstance(val, (tuple, list)) and len(val) == 2 and \
            all(isinstance(c, (int, float)) for c in val):
        positions = [tuple(val)]
    elif isinstance(val, list):
        positions = [tuple(p) for p in val]
    else:
        return []

    instances = []
    iw, ih = image_size
    wx_m, wz_m = world_size_m
    for n, (wx, wz) in enumerate(positions, start=1):
        # Convert world → pixel for rotation-rule resolution
        cx_px = (wx / wx_m + 0.5) * iw
        cy_px = (wz / wz_m + 0.5) * ih
        instances.append(_emit_instance(
            name=name, idx=n, centroid_px=(cx_px, cy_px),
            class_entry=class_entry, label_map=label_map, palette=palette,
            image_size=image_size, world_size_m=world_size_m,
            sampler=sampler, anchors=anchors, rng=rng,
        ))
    return instances


# ---- scatter_in_mask ---------------------------------------------------

def _extract_scatter(*, name, class_entry, label_map, palette,
                     image_size, world_size_m, sampler, anchors, rng):
    """Distribute N=density*area instances within the source class's
    pixel mask using a poisson-disc-like rejection sampler."""
    strategy = class_entry["strategy"]
    src_class = strategy.get("mask_source_class", "grass")
    src_idx = _find_class_idx(palette, [src_class])
    if src_idx is None:
        return []
    mask = label_map == src_idx
    if not mask.any():
        return []

    iw, ih = image_size
    wx_m, wz_m = world_size_m

    # Mask area in m^2
    area_m2 = float(mask.sum()) * (wx_m * wz_m) / (iw * ih)
    density = float(strategy.get("scatter_density_per_m2", 0.02))
    target_n = max(1, int(round(area_m2 * density)))
    min_dist_m = float(strategy.get("min_distance_between_meters", 1.5))
    min_dist_px = min_dist_m * 0.5 * (iw / wx_m + ih / wz_m)

    ys, xs = np.where(mask)
    if ys.size == 0:
        return []

    placed_px: list[tuple[float, float]] = []
    attempts = 0
    max_attempts = target_n * 30
    while len(placed_px) < target_n and attempts < max_attempts:
        attempts += 1
        i = rng.randint(0, ys.size - 1)
        cx, cy = float(xs[i]), float(ys[i])
        ok = True
        for (px, py) in placed_px:
            dx = cx - px; dy = cy - py
            if dx * dx + dy * dy < min_dist_px * min_dist_px:
                ok = False
                break
        if ok:
            placed_px.append((cx, cy))

    instances = []
    for n, (cx, cy) in enumerate(placed_px, start=1):
        instances.append(_emit_instance(
            name=name, idx=n, centroid_px=(cx, cy),
            class_entry=class_entry, label_map=label_map, palette=palette,
            image_size=image_size, world_size_m=world_size_m,
            sampler=sampler, anchors=anchors, rng=rng,
        ))
    return instances


# ---- require_adjacent (bridge-style) ----------------------------------

def _extract_require_adjacent(*, name, mask, class_entry, label_map, palette,
                              image_size, world_size_m, sampler, anchors, rng):
    """Like cluster_extract but require each connected component to touch
    a specific other class (e.g., bridge must touch water_surface)."""
    strategy = class_entry["strategy"]
    must_touch = strategy.get("must_touch_class", "water_surface")
    touch_idx = _find_class_idx(palette, [must_touch])
    if touch_idx is None:
        return []

    comps = cv.connected_components(mask, min_area=strategy.get("min_area_px", 10))
    if not comps:
        return []

    H, W = label_map.shape
    keepers = []
    for c in comps:
        # Check whether any pixel in this component has a neighbor of the
        # required class.
        pixels = c["pixels"]
        touches = False
        for y, x in pixels:
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < H and 0 <= nx < W:
                    if label_map[ny, nx] == touch_idx:
                        touches = True
                        break
            if touches:
                break
        if touches:
            keepers.append(c)

    instances = []
    for n, c in enumerate(keepers, start=1):
        instances.append(_emit_instance(
            name=name, idx=n, centroid_px=c["centroid"],
            class_entry=class_entry, label_map=label_map, palette=palette,
            image_size=image_size, world_size_m=world_size_m,
            sampler=sampler, anchors=anchors, rng=rng,
        ))
    return instances


# ============================================================
# INSTANCE EMITTER
# ============================================================

def _emit_instance(*, name, idx, centroid_px, class_entry, label_map,
                   palette, image_size, world_size_m, sampler, anchors, rng):
    """Common emit logic: pixel → world coords, resolve facing + Y,
    set scale from canonical_size."""
    strategy = class_entry["strategy"]
    cx_px, cy_px = centroid_px
    wx, wz = cv.pixel_to_world(cx_px, cy_px, image_size, world_size_m)

    wy = resolve_y(
        wx, wz, strategy.get("y_anchor", "heightmap_sample"),
        sampler=sampler,
        y_value_meters=float(strategy.get("y_value_meters", 0.0)),
    )

    facing = resolve_facing(
        cx_px, cy_px, strategy.get("rotation_rule", "no_rotation"),
        image_size=image_size, world_size_m=world_size_m,
        label_map=label_map, palette=palette,
        anchors=anchors, rng=rng,
    )

    canonical = strategy.get("canonical_size_meters", [1.0, 1.0, 1.0])
    return {
        "class": name,
        "id": f"{name}_{idx:03d}",
        "position": [wx, wy, wz],
        "facing": facing,
        "scale": [float(canonical[0]), float(canonical[1]), float(canonical[2])],
        "primitive": strategy.get("primitive", "prim_unit_box"),
        "canonical_front_axis": strategy.get("canonical_front_axis", "-Z"),
    }


# ============================================================
# TOP-LEVEL DISPATCH
# ============================================================

def dispatch_extraction(
    *,
    catalog: dict,
    semantic_map_path: str | Path,
    heightmap_path: str | Path | None = None,
    world_size_m: tuple[float, float] = (80.0, 80.0),
    height_scale: float = 3.0,
    height_offset: float = -0.5,
    anchors: dict[str, Any] | None = None,
    rng_seed: int = 42,
) -> list[dict]:
    """Run extraction over every object_placement class in the catalog.
    Returns a flat list of instance dicts (the same shape as
    extracted.json's `instances` array)."""
    img = cv.load_rgb(semantic_map_path)
    H, W = img.shape[:2]
    image_size = (W, H)

    palette = [(c["name"], c["hex"]) for c in catalog["classes"]
               if c.get("intent_type") in ("terrain_shader", "object_placement")]
    label_map = cv.threshold_nearest_palette(img, palette)

    sampler = None
    if heightmap_path is not None:
        sampler = HeightmapSampler(
            heightmap_path,
            plane_size_m=float(world_size_m[0]),
            height_scale=height_scale,
            height_offset=height_offset,
        )

    out: list[dict] = []
    for c in catalog["classes"]:
        if c.get("intent_type") != "object_placement":
            continue
        if "strategy" not in c:
            continue
        # Find this class in the palette
        idx = next((i for i, (n, _h) in enumerate(palette) if n == c["name"]),
                   None)
        if idx is None:
            continue
        instances = extract_class(
            class_entry=c,
            label_map=label_map,
            palette=palette,
            palette_idx=idx,
            image_size=image_size,
            world_size_m=world_size_m,
            sampler=sampler,
            anchors=anchors,
            rng_seed=rng_seed,
        )
        out.extend(instances)
    return out


# ============================================================
# CLI (for manual testing)
# ============================================================

if __name__ == "__main__":
    import argparse
    import json
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True, help="path to class_catalog.json")
    parser.add_argument("--semantic-map", required=True)
    parser.add_argument("--heightmap", default=None)
    parser.add_argument("--world-x", type=float, default=80.0)
    parser.add_argument("--world-z", type=float, default=80.0)
    parser.add_argument("--out", required=True, help="path for extracted.json")
    parser.add_argument("--rng-seed", type=int, default=42)
    args = parser.parse_args()

    catalog = json.loads(Path(args.catalog).read_text())
    instances = dispatch_extraction(
        catalog=catalog,
        semantic_map_path=args.semantic_map,
        heightmap_path=args.heightmap,
        world_size_m=(args.world_x, args.world_z),
        rng_seed=args.rng_seed,
    )
    doc = {
        "source_catalog": str(args.catalog),
        "source_semantic_map": str(args.semantic_map),
        "source_heightmap": str(args.heightmap) if args.heightmap else None,
        "world_size_meters": [args.world_x, args.world_z],
        "n_instances": len(instances),
        "instances": instances,
    }
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(doc, indent=2))
    print(f"Wrote {len(instances)} instances to {args.out}")
