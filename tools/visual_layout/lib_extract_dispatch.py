"""lib_extract_dispatch.py — Strategy-dispatched extraction for stage-5 of the
text-to-world pipeline. Sits on top of lib_extract.py's image-processing
helpers.

The yume-scene-class-catalog skill injects a `strategy` block into each
`object_placement` class entry (see data/lib/extraction_strategies.json
for the vocabulary). This module reads those strategies and dispatches
to the right extraction method.

Pure stdlib + numpy + PIL — no scipy.

Vocabulary (mirrors data/lib/extraction_strategies.json):
  extraction_method: single_instance / cluster_extract / snap_to_anchor /
                     scatter_in_mask / polygon_decompose / skeleton_polyline /
                     instance_per_component / require_adjacent
  rotation_rule:     no_rotation / face_nearest_road / face_anchor /
                     along_tangent / perpendicular_to_water / random_seeded /
                     edge_aligned
  y_anchor:          heightmap_sample / water_level / anchor_floor / constant
  primitive:         prim_unit_box / prim_unit_cylinder / prim_unit_sphere
"""
from __future__ import annotations

import math
import random
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

from tools.visual_layout import lib_extract as cv


# scatter_in_mask honors the catalog's expected_count as design intent:
# the density×area heuristic is CAPPED at expected_count × this factor so a
# large source mask can't emit hundreds of instances for a class the author
# asked ~30 of. Per-strategy override: strategy["scatter_max_factor"].
# Empirical 2026-06-08: lanterns emitted 1220 rocks + 239 trees (1510 total)
# for a catalog asking ~30 — density mask-fill ignored expected_count.
SCATTER_SPREAD_FACTOR = 1.5


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
        """Bilinear sample at world (x, z). Returns y in meters.

        UV MUST match pixel_to_world (image_y → world_z, NO flip) AND
        the ground shader, else entity Y is sampled from the mirrored
        row and buildings sit on the wrong terrain height (2026-05-26).
        """
        u = (wx + self.plane * 0.5) / self.plane
        v = (wz + self.plane * 0.5) / self.plane
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
    semantic_map_path: str | Path | None = None,
) -> list[dict]:
    """Dispatch on class_entry['strategy']['extraction_method'] and return
    a list of instance dicts of the form:

      {
        "class": "<class_name>",
        "id": "<class>_<n>",
        "position": [wx, wy, wz],
        "yaw": <radians>,        # Godot Y-rotation, read by renderer
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
    if method == "instance_per_component":
        return _extract_instance_per_component(
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
        return _extract_polygon_decompose(
            name=name, mask=mask, class_entry=class_entry,
            label_map=label_map, palette=palette,
            image_size=image_size, world_size_m=world_size_m,
            sampler=sampler, anchors=anchors, rng=rng,
        )
    if method == "skeleton_polyline":
        return _extract_skeleton_polyline(
            name=name, mask=mask, class_entry=class_entry,
            image_size=image_size, world_size_m=world_size_m,
            sampler=sampler,
        )
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
        # The named source class isn't present in THIS scene. Fall back
        # to the class's OWN mask — e.g. a "tree" object class drawn as
        # blobs (no separate "forest" terrain biome) scatters trees
        # within its own painted regions. Keeps scatter_in_mask generic
        # across scenes that don't share the medieval-town's class set.
        src_idx = _find_class_idx(palette, [name])
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
    # Cap (never inflate) at the catalog's expected_count × spread factor.
    # Counts come from expected_count, never unbounded mask-fill — a class
    # with no expected_count keeps the density-only behavior.
    expected = class_entry.get("expected_count")
    if expected and expected > 0:
        factor = float(strategy.get("scatter_max_factor", SCATTER_SPREAD_FACTOR))
        cap = max(1, int(round(expected * factor)))
        if target_n > cap:
            target_n = cap
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

    pca_oriented = bool(strategy.get("pca_oriented", False))
    min_elong = float(strategy.get("min_elongation_for_pca", 1.5))
    instances = []
    for n, c in enumerate(keepers, start=1):
        if pca_oriented:
            instances.append(_emit_pca_oriented(
                name=name, idx=n, comp=c, class_entry=class_entry,
                image_size=image_size, world_size_m=world_size_m,
                sampler=sampler, min_elongation=min_elong,
            ))
        else:
            instances.append(_emit_instance(
                name=name, idx=n, centroid_px=c["centroid"],
                class_entry=class_entry, label_map=label_map, palette=palette,
                image_size=image_size, world_size_m=world_size_m,
                sampler=sampler, anchors=anchors, rng=rng,
            ))
    return instances


# ============================================================
# INSTANCE-PER-COMPONENT — the 1:1 extraction primitive
# ============================================================

def _extract_instance_per_component(
    *, name, mask, class_entry, label_map, palette,
    image_size, world_size_m, sampler, anchors, rng,
):
    """Emit ONE instance per connected component meeting min_area_px.
    The right tool when the semantic-map class is authored as discrete
    tiles (one tile = one entity) — houses, towers, individual walls.

    Strategy fields:
      min_area_px:   reject components below this area (default 20)
      pca_oriented:  if true, facing = PCA major-axis angle AND
                     scale[0]/scale[2] are fitted to the component's
                     oriented bbox along that axis (length × thickness).
                     If false, canonical_size_meters drives scale and
                     rotation_rule drives facing (per resolve_facing).
      min_elongation_for_pca: when pca_oriented is true, require this
                     minimum elongation ratio to apply PCA rotation
                     (default 1.5 — below that, the shape is roughly
                     square and rotation is meaningless, so use
                     rotation_rule).
    """
    strategy = class_entry["strategy"]
    min_area = int(strategy.get("min_area_px", 20))
    pca_oriented = bool(strategy.get("pca_oriented", False))
    min_elong = float(strategy.get("min_elongation_for_pca", 1.5))
    buckets = strategy.get("variant_buckets")

    comps = cv.connected_components(mask, min_area=min_area)
    if not comps:
        return []

    # Per-bucket id counter so each bucket numbers from 001.
    bucket_counters: dict[str, int] = {}

    instances = []
    for comp in comps:
        # If variant_buckets is set, classify by area and use the
        # matched bucket's def name + canonical_size + albedo.
        bucket = _pick_bucket(buckets, comp["area_px"]) if buckets else None
        if bucket is not None:
            emit_name = bucket["def"]
        else:
            emit_name = name
        bucket_counters[emit_name] = bucket_counters.get(emit_name, 0) + 1
        idx = bucket_counters[emit_name]

        cx_px, cy_px = comp["centroid"]
        if pca_oriented:
            inst = _emit_pca_oriented(
                name=emit_name, idx=idx, comp=comp, class_entry=class_entry,
                image_size=image_size, world_size_m=world_size_m,
                sampler=sampler, min_elongation=min_elong,
                bucket=bucket,
            )
        else:
            inst = _emit_instance(
                name=emit_name, idx=idx, centroid_px=(cx_px, cy_px),
                class_entry=class_entry, label_map=label_map, palette=palette,
                image_size=image_size, world_size_m=world_size_m,
                sampler=sampler, anchors=anchors, rng=rng,
                bucket=bucket,
            )
        instances.append(inst)
    return instances


def _pick_bucket(buckets: list[dict] | None, area_px: int) -> dict | None:
    """Return the first bucket whose max_area_px >= area_px, or None
    if no buckets are defined. The last bucket should have a very
    large max_area_px to act as catch-all."""
    if not buckets:
        return None
    for b in buckets:
        if area_px <= int(b.get("max_area_px", 999999)):
            return b
    return buckets[-1]


# Rounding precision for emitted positions/scales (world metres → mm) and
# yaw (radians). Fixed across all emit paths so output is uniform.
_POS_DECIMALS = 3
_YAW_DECIMALS = 4


def _instance(name: str, idx: int, *, pos, yaw: float,
              primitive: str, front_axis: str,
              scale: list | None) -> dict:
    """THE single definition of an extracted-instance dict. Every _emit_*
    path goes through here so the schema (and its rounding) is defined
    once — no more three near-identical dict literals drifting apart.

    `scale=None` → the instance shares its class's canonical size (emits
    `_use_canonical_scale: true`, no per-instance scale). A [w, h, d] list
    → a fitted per-instance scale.
    """
    out = {
        "class": name,
        "id": f"{name}_{idx:03d}",
        "position": [round(float(pos[0]), _POS_DECIMALS),
                     round(float(pos[1]), _POS_DECIMALS),
                     round(float(pos[2]), _POS_DECIMALS)],
        "yaw": round(float(yaw), _YAW_DECIMALS),
        "primitive": primitive,
        "canonical_front_axis": front_axis,
    }
    if scale is None:
        out["_use_canonical_scale"] = True
    else:
        out["scale"] = [round(float(scale[0]), _POS_DECIMALS),
                        round(float(scale[1]), _POS_DECIMALS),
                        round(float(scale[2]), _POS_DECIMALS)]
    return out


def _emit_pca_oriented(
    *, name, idx, comp, class_entry, image_size, world_size_m,
    sampler, min_elongation, bucket=None,
):
    """Emit a box whose facing + length + thickness come from PCA on
    the component's pixels. Wall segments authored as oriented tiles
    end up correctly aligned along their long axis.

    When `bucket` is provided, its canonical_size_meters override the
    strategy's default (variant-bucket dispatch path)."""
    strategy = class_entry["strategy"]
    canonical = (bucket or strategy).get(
        "canonical_size_meters", strategy.get(
            "canonical_size_meters", [1.0, 3.0, 0.4]
        )
    )
    height_m = float(canonical[1])

    px = comp["pixels"].astype(float)
    ys = px[:, 0]; xs = px[:, 1]
    cy = ys.mean(); cx = xs.mean()
    cov = np.cov(np.stack([ys - cy, xs - cx]))
    eigvals, eigvecs = np.linalg.eigh(cov)
    eigval_min = max(eigvals[0], 1e-9)
    eigval_max = max(eigvals[1], 1e-9)
    elongation = math.sqrt(eigval_max / eigval_min)

    # Principal axis (major)
    vy_maj, vx_maj = eigvecs[:, 1]
    # Project pixels onto major axis to get LENGTH extent
    proj_maj = (ys - cy) * vy_maj + (xs - cx) * vx_maj
    length_px = float(proj_maj.max() - proj_maj.min())
    # Minor axis
    vy_min, vx_min = eigvecs[:, 0]
    proj_min = (ys - cy) * vy_min + (xs - cx) * vx_min
    thickness_px = float(proj_min.max() - proj_min.min())

    # Pixel → world length scale (use isotropic; semantic maps are square)
    iw, ih = image_size
    wx_m, wz_m = world_size_m
    px_per_m = 0.5 * (iw / wx_m + ih / wz_m)
    # footprint_scale shrinks the fitted footprint (X/Z only, not
    # height) so packed tiles leave walkable gaps between them. 1.0 =
    # exact fit. Used to open up streets in over-dense towns.
    fscale = float(strategy.get("footprint_scale", 1.0))
    length_m = max(0.3, length_px / px_per_m) * fscale
    thickness_m = max(0.15, thickness_px / px_per_m) * fscale

    # Position from centroid
    wx, wz = cv.pixel_to_world(cx, cy, image_size, world_size_m)
    wy = sampler.y_at(wx, wz) if sampler is not None else 0.0

    # SIZE always comes from the fitted PCA extents — that's the whole
    # point of 1:1 extraction. Only ROTATION gates on elongation
    # (rotating a near-square tile by its noise-jitter PCA angle looks
    # wrong; keep facing=0 for those).
    if elongation < min_elongation:
        facing = 0.0
    else:
        # Major-axis direction in (x_world, z_world).
        # eigvec is in (y, x) image-pixel space. pixel_to_world maps
        # image_y → world_z DIRECTLY (no flip): both increase southward.
        # image_x → world_x DIRECTLY (both increase eastward). So:
        dx_world = vx_maj
        dz_world = vy_maj
        # Godot Y-rotation that aligns local +X with (dx_world, dz_world):
        # rotating (1, 0, 0) by yaw gives (cos yaw, 0, -sin yaw), so
        # cos yaw = dx, -sin yaw = dz → yaw = atan2(-dz, dx).
        facing = math.atan2(-dz_world, dx_world)

    # Shared canonical size (scale=None) vs per-instance fitted PCA extents.
    scale = None if strategy.get("use_canonical_scale", False) \
        else [length_m, height_m, thickness_m]
    return _instance(
        name, idx, pos=(wx, wy, wz), yaw=facing,
        primitive=strategy.get("primitive", "prim_unit_box"),
        front_axis=strategy.get("canonical_front_axis", "+X"),
        scale=scale,
    )


# ============================================================
# POLYGON DECOMPOSE — walls, fences, palisades, retaining walls
# ============================================================

def _trace_outline(mask: np.ndarray, component: dict) -> list[tuple[int, int]]:
    """Naive outline trace: collect every mask pixel with a non-mask
    4-neighbor (the boundary), then walk greedily from topmost-leftmost
    picking the nearest unvisited boundary pixel each step.

    Works well for convex / mildly-concave polygons (octagon walls,
    house compounds, simple fence rings). Topologically thin features
    or self-intersecting boundaries may produce odd orderings; for
    those cases use a higher elongation threshold so the PCA-single-
    segment branch takes over.
    """
    H, W = mask.shape
    edges: list[tuple[int, int]] = []
    for y, x in component["pixels"].tolist():
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if ny < 0 or ny >= H or nx < 0 or nx >= W or not mask[ny, nx]:
                edges.append((int(x), int(y)))
                break
    if not edges:
        return []
    edges_set: set[tuple[int, int]] = set(edges)
    start = min(edges, key=lambda p: (p[1], p[0]))
    ordered = [start]
    edges_set.discard(start)
    current = start
    # Greedy nearest-neighbor walk
    while edges_set:
        best = None
        best_d2 = 10 ** 9
        for p in edges_set:
            d2 = (p[0] - current[0]) ** 2 + (p[1] - current[1]) ** 2
            if d2 < best_d2:
                best_d2 = d2
                best = p
        # If the nearest is too far, the rest is disconnected noise — bail
        if best is None or best_d2 > 16:
            break
        ordered.append(best)
        edges_set.discard(best)
        current = best
    return ordered


def _perp_dist(p: tuple[int, int], a: tuple[int, int], b: tuple[int, int]) -> float:
    if a == b:
        return math.hypot(p[0] - a[0], p[1] - a[1])
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    norm = math.hypot(dx, dy)
    return abs(dy * p[0] - dx * p[1] + b[0] * a[1] - b[1] * a[0]) / norm


def _rdp(points: list[tuple[int, int]], eps_px: float) -> list[tuple[int, int]]:
    """Ramer-Douglas-Peucker polyline simplification. Iterative
    stack-based to avoid Python recursion limits on long boundaries."""
    if len(points) < 3:
        return list(points)
    keep = [False] * len(points)
    keep[0] = True
    keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        if j - i < 2:
            continue
        max_d = 0.0
        max_k = -1
        for k in range(i + 1, j):
            d = _perp_dist(points[k], points[i], points[j])
            if d > max_d:
                max_d = d
                max_k = k
        if max_d > eps_px and max_k > 0:
            keep[max_k] = True
            stack.append((i, max_k))
            stack.append((max_k, j))
    return [points[i] for i, k in enumerate(keep) if k]


def _emit_edge_box(
    *,
    name: str,
    idx: int,
    a_px: tuple[float, float],
    b_px: tuple[float, float],
    class_entry: dict,
    image_size: tuple[int, int],
    world_size_m: tuple[float, float],
    sampler: HeightmapSampler | None,
) -> dict:
    """Emit a single rotated/scaled prim_unit_box that spans pixel
    endpoints a_px → b_px. The box's length lies along its
    canonical_front_axis (+X by lib convention)."""
    strategy = class_entry["strategy"]
    canonical = strategy.get("canonical_size_meters", [1.0, 3.0, 0.4])
    height_m = float(canonical[1])
    thickness_m = float(canonical[2])

    wax, waz = cv.pixel_to_world(a_px[0], a_px[1], image_size, world_size_m)
    wbx, wbz = cv.pixel_to_world(b_px[0], b_px[1], image_size, world_size_m)
    wx = (wax + wbx) * 0.5
    wz = (waz + wbz) * 0.5
    length_m = math.hypot(wbx - wax, wbz - waz)
    # facing = Godot Y-rotation that points local +X along (wbx-wax, wbz-waz).
    # Convention matches resolve_facing() (atan2(dx, -dz)) so wirer logic
    # is uniform across rotation rules.
    facing = math.atan2(wbx - wax, -(wbz - waz))

    wy = sampler.y_at(wx, wz) if sampler is not None else 0.0

    return _instance(
        name, idx, pos=(wx, wy, wz), yaw=facing,
        primitive=strategy.get("primitive", "prim_unit_box"),
        front_axis=strategy.get("canonical_front_axis", "+X"),
        scale=[length_m, height_m, thickness_m],
    )


def _extract_skeleton_polyline(*, name, mask, class_entry, image_size,
                               world_size_m, sampler):
    """Skeleton-based polyline extraction — for THIN linear structures
    (fences, roads, walls, hedges) the LLM might draw as either a clean
    line OR a shaded zone. Algorithm:

      1. Skeletonize the binary mask (skimage) → 1-pixel-wide medial axis
         — collapses any shaded zone down to its centerline.
      2. Trace the skeleton: start from endpoints (degree-1 pixels), walk
         the connected path one neighbor at a time, building a polyline
         per connected branch. Cycles (closed-loop fences) trace from any
         starting pixel in the cycle.
      3. Ramer-Douglas-Peucker simplify each polyline (eps from strategy).
      4. Emit one rotated unit_box per polyline edge — same downstream
         logic as polygon_decompose.

    Compared to polygon_decompose (traces the CONTOUR of the blob), this
    is the right method when the LLM might render a fence as a fat band
    rather than a thin line — the skeleton's centerline is invariant to
    the band's width, so we get ONE chain instead of multiple parallel
    polylines.

    2026-05-29.
    """
    from skimage.morphology import skeletonize as _skel
    strategy = class_entry["strategy"]
    eps_px = float(strategy.get("simplify_tolerance_px", 4.0))
    min_skeleton_len = int(strategy.get("min_skeleton_len_px", 6))

    bool_mask = mask.astype(bool)
    if bool_mask.sum() == 0:
        return []
    skel = _skel(bool_mask)
    polylines = _trace_skeleton(skel)
    # Filter tiny noise polylines
    polylines = [p for p in polylines if len(p) >= min_skeleton_len]
    if not polylines:
        return []

    out: list[dict] = []
    idx = 0
    for poly in polylines:
        # poly is a list of (x, y) pixel coords
        simplified = _rdp(poly, eps_px)
        if len(simplified) < 2:
            continue
        for i in range(len(simplified) - 1):
            a = simplified[i]
            b = simplified[i + 1]
            out.append(_emit_edge_box(
                name=name, idx=idx, a_px=(a[0], a[1]), b_px=(b[0], b[1]),
                class_entry=class_entry, image_size=image_size,
                world_size_m=world_size_m, sampler=sampler,
            ))
            idx += 1
    return out


def _trace_skeleton(skel: np.ndarray) -> list[list[tuple[int, int]]]:
    """Walk a 1-pixel binary skeleton into polylines. Endpoints (degree=1)
    seed forward traces; remaining unvisited pixels (cycles) seed their
    own traces. Branches at junctions (degree>=3) split into separate
    polylines (each junction-to-junction segment is one polyline).

    Returns list of polylines, each a list of (x, y) pixel coords.
    """
    H, W = skel.shape
    visited = np.zeros((H, W), dtype=bool)

    def neighbors(y, x):
        out = []
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy == 0 and dx == 0:
                    continue
                ny, nx = y + dy, x + dx
                if 0 <= ny < H and 0 <= nx < W and skel[ny, nx]:
                    out.append((ny, nx))
        return out

    def degree(y, x):
        return len(neighbors(y, x))

    ys, xs = np.where(skel)
    polylines: list[list[tuple[int, int]]] = []

    # Pass 1: trace from endpoints (degree 1)
    for k in range(len(ys)):
        y0, x0 = int(ys[k]), int(xs[k])
        if visited[y0, x0]:
            continue
        if degree(y0, x0) != 1:
            continue
        poly: list[tuple[int, int]] = []
        cy, cx = y0, x0
        while True:
            poly.append((cx, cy))
            visited[cy, cx] = True
            nxt = None
            for ny, nx in neighbors(cy, cx):
                if not visited[ny, nx]:
                    nxt = (ny, nx)
                    break
            if nxt is None:
                break
            # Stop at junction so each junction-to-junction is its own polyline
            if degree(nxt[0], nxt[1]) > 2:
                poly.append((nxt[1], nxt[0]))
                visited[nxt[0], nxt[1]] = False  # keep junction available
                break
            cy, cx = nxt
        if len(poly) >= 2:
            polylines.append(poly)

    # Pass 2: any unvisited skeleton pixels are inside cycles or
    # junction-to-junction segments. Trace one from each unvisited.
    for k in range(len(ys)):
        y0, x0 = int(ys[k]), int(xs[k])
        if visited[y0, x0]:
            continue
        poly = []
        cy, cx = y0, x0
        while True:
            poly.append((cx, cy))
            visited[cy, cx] = True
            nxt = None
            for ny, nx in neighbors(cy, cx):
                if not visited[ny, nx]:
                    nxt = (ny, nx)
                    break
            if nxt is None:
                break
            cy, cx = nxt
        if len(poly) >= 2:
            polylines.append(poly)

    return polylines


def _extract_polygon_decompose(*, name, mask, class_entry, label_map, palette,
                               image_size, world_size_m, sampler, anchors, rng):
    """Decompose each connected component into rotated unit_boxes:

      1. Highly elongated component (PCA elongation > 2.5): emit ONE
         box along the PCA major axis. (Single-strip walls, isolated
         fence segments.)
      2. Otherwise: trace outline → R-D-P simplify → emit ONE box per
         polygon edge. (Town walls, polygonal fences, compound
         perimeters.)

    Yume reuse principle: walls are NOT a new primitive — they're
    rotated/scaled instances of the same prim_unit_box used by houses,
    townhalls, etc. New genres get walls/fences for free by writing
    a strategy entry pointing here.
    """
    strategy = class_entry["strategy"]
    min_area = int(strategy.get("min_area_px", 20))
    tol_m = float(strategy.get("simplify_tolerance_meters", 0.6))
    iw, ih = image_size
    wx_m, wz_m = world_size_m
    px_per_m = 0.5 * (iw / wx_m + ih / wz_m)
    tol_px = tol_m * px_per_m

    comps = cv.connected_components(mask, min_area=min_area)
    if not comps:
        return []

    instances: list[dict] = []
    idx = 0
    for comp in comps:
        _angle_deg, elongation = cv.infer_rotation_deg(comp)
        if elongation > 2.5:
            # Single-segment branch: emit one box along major axis.
            # Compute endpoint pixels by projecting comp pixels onto
            # the principal eigenvector and taking min/max.
            px = comp["pixels"].astype(float)
            ys = px[:, 0]; xs = px[:, 1]
            cy = ys.mean(); cx = xs.mean()
            cov = np.cov(np.stack([ys - cy, xs - cx]))
            _eigvals, eigvecs = np.linalg.eigh(cov)
            vy, vx = eigvecs[:, 1]
            proj = (ys - cy) * vy + (xs - cx) * vx
            i_min = int(np.argmin(proj)); i_max = int(np.argmax(proj))
            a_px = (float(xs[i_min]), float(ys[i_min]))
            b_px = (float(xs[i_max]), float(ys[i_max]))
            idx += 1
            instances.append(_emit_edge_box(
                name=name, idx=idx, a_px=a_px, b_px=b_px,
                class_entry=class_entry, image_size=image_size,
                world_size_m=world_size_m, sampler=sampler,
            ))
            continue

        # Polygon branch: trace outline + R-D-P + per-edge boxes.
        outline = _trace_outline(mask, comp)
        if len(outline) < 3:
            continue
        simplified = _rdp(outline, tol_px)
        # Close the polygon by appending the start
        if len(simplified) >= 3 and simplified[0] != simplified[-1]:
            simplified = simplified + [simplified[0]]
        if len(simplified) < 3:
            continue
        for i in range(len(simplified) - 1):
            a = simplified[i]
            b = simplified[i + 1]
            # Skip degenerate edges
            wax, waz = cv.pixel_to_world(a[0], a[1], image_size, world_size_m)
            wbx, wbz = cv.pixel_to_world(b[0], b[1], image_size, world_size_m)
            if math.hypot(wbx - wax, wbz - waz) < 0.3:
                continue
            idx += 1
            instances.append(_emit_edge_box(
                name=name, idx=idx, a_px=(a[0], a[1]), b_px=(b[0], b[1]),
                class_entry=class_entry, image_size=image_size,
                world_size_m=world_size_m, sampler=sampler,
            ))
    return instances


# ============================================================
# INSTANCE EMITTER
# ============================================================

def _emit_instance(*, name, idx, centroid_px, class_entry, label_map,
                   palette, image_size, world_size_m, sampler, anchors, rng,
                   bucket=None):
    """Common emit logic: pixel → world coords, resolve facing + Y,
    set scale from canonical_size. When `bucket` is provided, its
    canonical_size_meters override the strategy default (variant-bucket
    dispatch path)."""
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

    canonical = (bucket or strategy).get(
        "canonical_size_meters",
        strategy.get("canonical_size_meters", [1.0, 1.0, 1.0]),
    )
    # Bucketed defs + use_canonical_scale share a canonical size (scale=None).
    use_canonical = strategy.get("use_canonical_scale", False) or bucket is not None
    scale = None if use_canonical else [canonical[0], canonical[1], canonical[2]]
    return _instance(
        name, idx, pos=(wx, wy, wz), yaw=facing,
        primitive=strategy.get("primitive", "prim_unit_box"),
        front_axis=strategy.get("canonical_front_axis", "-Z"),
        scale=scale,
    )


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
            semantic_map_path=semantic_map_path,
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
