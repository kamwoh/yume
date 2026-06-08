"""compose_world.py — the SCENE layer of the text-to-world pipeline.

Produces ONLY the 3D environment from a semantic map + heightmap:
entity defs + their placements, terrain assets (biome splatmap, water
mask, road graph), and scene.json's ground + water. It says NOTHING
about how you view or control the world (the "shell" — camera, player,
input, lighting, .tscn — is added by compose_shell.py) AND NOTHING
about the GAME (mechanics, goals, level progression, global state —
owned by /yume-design; see ADR 0067). So this writes NO game/flow.json,
NO levels/, NO world/state.json — it stays in the scene lane.

The map placements are emitted as flat `initial_instances` INSIDE
entities/auto_gen.json (the engine globs entities/*.json and spawns
them; flat single-level boot needs no flow.json — world_boot
_load_content's else-branch). A consumer that wants a level system
(/yume-design with multi-level, or compose_shell standalone) adds it
on top without compose_world ever touching the game's files.

The flow:
  1. inject strategies from data/lib/extraction_strategies.json
  2. detect anchors (plaza centroid, wall-ring corners)
  3. dispatch extraction (lib_extract_dispatch) → object instances
  4. extract road graph (lib_extract_roads) → world/road_graph.json
     (roads RENDER as ground biomes / mask coverage; graph is metadata)
  5. validate + extraction↔render alignment check
  6. group instances by class/bucket → entity defs (primitive boxes/
     cylinders/spheres, sized + colored per strategy)
  7. write scene.json (ground biome shader + water plane), terrain
     assets, road_graph, and entities/auto_gen.json (defs + flat
     placements). NO game-domain files.

OBJECTS (houses/walls/towers/bridges/fountain) → entities. NON-OBJECTS
→ biomes (ground splatmap), water (ADR 0059 plane), roads (biome
coverage). The semantic map is consumed ONCE here, as classification.

Two-step to a runnable demo:
    python3 -m tools.visual_layout.compose_world demo_x \\
        --catalog ... --semantic-map ... --heightmap ... --height-scale 8.0
    python3 -m tools.visual_layout.compose_shell demo_x
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image as _PILImage

ROOT = Path(__file__).resolve().parents[2]
DATA_ROOT = ROOT / "godot" / "data"
sys.path.insert(0, str(ROOT))

from tools.visual_layout import lib_extract as cv            # noqa: E402
from tools.visual_layout import lib_extract_dispatch as dispatch  # noqa: E402
from tools.visual_layout import lib_extract_roads as roads_mod  # noqa: E402
from tools.visual_layout import lib_extract_validate as val  # noqa: E402
from tools.visual_layout import scene_config as scfg          # noqa: E402

LIB_STRATEGIES = DATA_ROOT / "lib" / "extraction_strategies.json"

# Path classes extracted as the road NETWORK (non-object), not biomes.
# Road/path classes. Rendered as ground BIOMES (mask coverage matches
# the semantic map). lib_extract_roads still skeletonizes them into a
# polyline graph, but that's written as metadata (world/road_graph.json)
# for future NPC pathing — NOT rendered. (Centerlines were the wrong
# VISUAL representation; the mask is the truth — 2026-05-26.)
ROAD_CLASS_NAMES = ["cobblestone", "dirt_path", "road", "stone_road", "gravel"]


# ============================================================
# BIOME PALETTE — tuned display colors per terrain class
# ============================================================

# Maps a terrain_shader class name → (tuned_albedo_hex, roughness).
# The semantic map's raw hex is only a CLASSIFICATION key; these are
# the colors actually shown on the ground. Picked to read as real
# matte terrain, not flat paint. Unknown classes fall back to their
# own semantic hex (so nothing breaks) at default roughness.
BIOME_PALETTE = {
    "grass":          ("#79b048", 0.95),
    "forest":         ("#3c5a2e", 0.96),
    "farm_field":     ("#7a8240", 0.92),
    "cobblestone":    ("#9a8f7a", 0.80),
    "dirt_path":      ("#7c5a38", 0.92),
    "stone_floor":    ("#8c8478", 0.82),
    "sand":           ("#c8b487", 0.90),
    "snow":           ("#e8eef2", 0.85),
    # Water is rendered by the ADR 0059 transparent plane; this is the
    # riverbed FLOOR seen at the shoreline / under the water surface.
    "water_surface":  ("#3a4a48", 0.55),
    "water":          ("#3a4a48", 0.55),
}


def _srgb_to_linear(c: float) -> float:
    """Per-channel sRGB (0..1) → linear (0..1). ALBEDO expects linear."""
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _hex_to_rgb01(h: str) -> list[float]:
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]


def _carve_class_mask(semantic_rgb: np.ndarray, classes: list[dict],
                      sigma_px: float) -> np.ndarray:
    """Soft mask: union of class hexes via RGB-distance, then Gaussian-blur."""
    import cv2 as _cv
    H, W = semantic_rgb.shape[:2]
    mask = np.zeros((H, W), dtype=np.float32)
    for cls in classes:
        hx = str(cls["hex"]).lstrip("#")
        ref = np.array([int(hx[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32)
        diff = np.linalg.norm(semantic_rgb - ref, axis=-1)
        cls_mask = np.exp(-(diff * diff) / (2.0 * 30.0 * 30.0))
        mask = np.maximum(mask, cls_mask)
    return _cv.GaussianBlur(mask, (0, 0), sigma_px)


def carve_paths_into_heightmap(heightmap_src: Path, semantic_path: Path,
                               catalog: dict, output: Path,
                               path_depth_m: float = 0.25,
                               path_sigma_px: float = 6.0,
                               water_depth_m: float = 1.5,
                               water_sigma_px: float = 14.0) -> bool:
    """Deterministic post-process: carve depressions for path-like AND
    water-like terrain classes into the heightmap. Returns True if any
    carving was applied. Source: semantic_map's exact pixel positions.

    Two passes:
      - PATHS: subtle ruts (~0.25m, soft sigma) for dirt_path/road class
      - WATER: deeper trench (~1.5m, smoother sigma) under water_surface
        class so the terrain reliably sits BELOW water_level across the
        whole mask region. Without this, the LLM-carved channels miss
        spots and the water plane "floats" above unflattened terrain.

    Inputs depth in METERS — caller divides by height_scale to map into
    normalized heightmap units before passing.
    """
    import cv2 as _cv
    path_classes = [c for c in catalog.get("classes", [])
                    if c.get("intent_type") == "terrain_shader"
                    and ("path" in str(c.get("name", "")).lower()
                         or "road" in str(c.get("name", "")).lower())]
    water_classes = [c for c in catalog.get("classes", [])
                     if c.get("intent_type") == "terrain_shader"
                     and ("water" in str(c.get("name", "")).lower()
                          or "river" in str(c.get("name", "")).lower()
                          or "pond" in str(c.get("name", "")).lower()
                          or "lake" in str(c.get("name", "")).lower())]
    if not path_classes and not water_classes:
        return False
    hm = np.array(_PILImage.open(heightmap_src).convert("L"), dtype=np.float32) / 255.0
    sem = np.array(_PILImage.open(semantic_path).convert("RGB"), dtype=np.float32)
    H, W = hm.shape
    if sem.shape[:2] != (H, W):
        sem = _cv.resize(sem, (W, H), interpolation=_cv.INTER_NEAREST)
    if path_classes:
        path_mask = _carve_class_mask(sem, path_classes, path_sigma_px)
        hm = np.clip(hm - path_depth_m * path_mask, 0.0, 1.0)
    if water_classes:
        water_mask = _carve_class_mask(sem, water_classes, water_sigma_px)
        hm = np.clip(hm - water_depth_m * water_mask, 0.0, 1.0)
    _PILImage.fromarray((hm * 255.0).astype(np.uint8)).save(output)
    return True


def flatten_building_pads(heightmap_src: Path, instances: list[dict],
                          classes_dict: dict,
                          world_w: float, world_h: float,
                          height_scale: float, height_offset: float,
                          output: Path,
                          sigma_px: float = 4.0,
                          bbox_padding_factor: float = 1.3,
                          extra_lift_norm: float = 0.005) -> bool:
    """Raise heightmap to a soft flat pad under each building instance.
    Mirror of carve_paths_into_heightmap, but instead of digging trenches
    along terrain-shader classes, this LIFTS the terrain under
    object_placement instances whose class has `_flatten_pad: true` in
    the strategy.

    For each opted-in instance: find the MAX heightmap-Y in its footprint
    bbox, stamp that value into a per-instance pad layer, then combine
    all pads via max + a gaussian blur for soft falloff at edges. Final
    heightmap = max(carved heightmap, padded layer). Result: each
    building sits on a flat foundation pad at the local terrain's high
    point, with a small soft slope into the surrounding ground.

    Also mutates each affected instance's `position[1]` to the raised
    pad height (so the building's mesh sits flush on the pad rather
    than the original sample-point of the un-raised terrain). Returns
    True if any pad was applied.

    Yume principle: the heightmap is THE single source of truth for
    terrain shape, including the local flatness needed for buildings to
    sit cleanly. We don't add per-building "foundation meshes" — we
    deterministically modify the heightmap, like a world-builder height
    brush would.
    """
    import cv2 as _cv
    flat_classes = {c for c, e in classes_dict.items() if e.get("_flatten_pad")}
    if not flat_classes:
        return False
    # The house strategy buckets a single semantic blob into one of
    # {small_,medium_,large_}house. Instances carry the BUCKETED class
    # name (e.g. "large_house"), not the catalog name ("house"). Treat
    # the size-bucket prefixes as equivalent so the flatten flag on
    # "house" covers all three buckets.
    bucket_prefixes = ("large_", "medium_", "small_")
    def _normalize(cls: str) -> str:
        for p in bucket_prefixes:
            if cls.startswith(p):
                return cls[len(p):]
        return cls
    to_flatten = [i for i in instances
                  if _normalize(str(i.get("class", ""))) in flat_classes]
    if not to_flatten:
        return False

    hm = np.array(_PILImage.open(heightmap_src).convert("L"), dtype=np.float32) / 255.0
    H, W = hm.shape
    pad_layer = np.zeros((H, W), dtype=np.float32)

    for inst in to_flatten:
        pos = inst.get("position", [0.0, 0.0, 0.0])
        scale = inst.get("scale", [1.0, 1.0, 1.0])
        wx = float(pos[0])
        wz = float(pos[2])
        fp_w_m = float(scale[0]) * bbox_padding_factor
        fp_d_m = float(scale[2]) * bbox_padding_factor
        # World → pixel (no V flip — matches pixel_to_world convention)
        cx = (wx + world_w * 0.5) / world_w * W
        cy = (wz + world_h * 0.5) / world_h * H
        fpx = max(2.0, fp_w_m / world_w * W)
        fpy = max(2.0, fp_d_m / world_h * H)
        x0 = int(max(0, cx - fpx * 0.5))
        x1 = int(min(W, cx + fpx * 0.5))
        y0 = int(max(0, cy - fpy * 0.5))
        y1 = int(min(H, cy + fpy * 0.5))
        if x1 <= x0 or y1 <= y0:
            continue
        max_y_norm = float(hm[y0:y1, x0:x1].max()) + extra_lift_norm
        # Per-building pad: stamp max value into the bbox
        bpad = np.zeros((H, W), dtype=np.float32)
        bpad[y0:y1, x0:x1] = max_y_norm
        pad_layer = np.maximum(pad_layer, bpad)
        # Update instance Y to sit flush on the raised pad
        raised_world_y = (max_y_norm + height_offset) * height_scale
        pos[1] = raised_world_y

    # Gaussian falloff at pad edges so surrounding terrain rises into
    # the pad smoothly (no abrupt cliff at the footprint edge).
    pad_layer = _cv.GaussianBlur(pad_layer, (0, 0), sigma_px)
    raised = np.maximum(hm, pad_layer)
    _PILImage.fromarray((raised * 255.0).astype(np.uint8)).save(output)
    return True


def build_terrain_splatmap(img: np.ndarray, palette: list[tuple[str, str]],
                           terrain_names: set[str],
                           road_names: set[str] | None = None) -> np.ndarray:
    """Derive a TERRAIN-ONLY splatmap from the semantic map.

    Object_placement pixels carry no ground info, so we fill their
    footprints with the surrounding terrain. BUT not with ROAD: houses
    are wrapped by streets, so a naive nearest-terrain fill turns every
    house footprint into road and the town interior becomes a road slab
    (empirically 12% → 30% road). Instead the fill is seeded ONLY from
    non-road terrain (grass/forest/water/farm) and PASSES THROUGH road
    pixels without recoloring them — road stays just the real streets,
    and deep-town houses (ringed by road) still get a non-road ground.

    Returns an RGB uint8 array (the derived splatmap).
    """
    road_names = road_names or set()
    label = cv.threshold_nearest_palette(img, palette)
    terrain_idx = {i for i, (n, _h) in enumerate(palette) if n in terrain_names}
    road_idx = {i for i, (n, _h) in enumerate(palette) if n in road_names}
    nonroad_terrain_idx = terrain_idx - road_idx

    is_object = ~np.isin(label, list(terrain_idx))   # not terrain at all
    out = img.copy()
    # `reached` = the fill front has arrived. `prop` = the non-road
    # terrain color the front carries. Seeds = non-road terrain.
    reached = np.isin(label, list(nonroad_terrain_idx))
    prop = img.copy()
    for _ in range(512):
        if reached.all():
            break
        progressed = False
        for axis, shift in ((0, 1), (0, -1), (1, 1), (1, -1)):
            nbr_reached = np.roll(reached, shift, axis=axis)
            nbr_prop = np.roll(prop, shift, axis=axis)
            take = (~reached) & nbr_reached
            if not take.any():
                continue
            # Object pixels ADOPT the carried non-road color; road pixels
            # keep their own color but still relay the front onward.
            obj_take = take & is_object
            out[obj_take] = nbr_prop[obj_take]
            prop[take] = nbr_prop[take]
            reached[take] = True
            progressed = True
        if not progressed:
            break
    return out


def _build_biome_arrays(catalog: dict, max_biomes: int = 8,
                        overrides: dict | None = None,
                        single_biome: bool = False):
    """Build (keys, albedos, roughnesses) for the biome ground shader.

    keys[i]   — splatmap key color (sRGB 0..1) = the class's semantic hex
    albedos[i]— tuned display color, sRGB→linear (ALBEDO is linear)
    roughs[i] — per-biome roughness

    Every terrain_shader class is a biome — INCLUDING roads (cobblestone
    / dirt_path), which render at exact mask coverage with a tuned road
    color (their BIOME_PALETTE entry). Capped at max_biomes (the
    shader's MAX_BIOMES). object_placement classes are entities.
    """
    keys: list[list[float]] = []
    albedos: list[list[float]] = []
    roughs: list[float] = []
    # single_biome: clean uniform ground (one grass biome) — pick the
    # dominant terrain class (prefer "grass", else highest coverage) and
    # render ONLY it; the multi-biome splatmap (paths/regions) is dropped.
    # The water plane is emitted separately, so water is unaffected.
    chosen: str | None = None
    if single_biome:
        terrains = [c for c in catalog.get("classes", [])
                    if c.get("intent_type") == "terrain_shader"]
        if terrains:
            grass = next((c for c in terrains if c.get("name") == "grass"), None)
            chosen = (grass or max(
                terrains, key=lambda c: c.get("expected_coverage_pct", 0)))["name"]
    for c in catalog.get("classes", []):
        if c.get("intent_type") != "terrain_shader":
            continue
        if single_biome and c.get("name") != chosen:
            continue
        if len(keys) >= max_biomes:
            break
        name = str(c.get("name", ""))
        sem_hex = str(c.get("hex", "#808080"))
        tuned_hex, rough = BIOME_PALETTE.get(name, (sem_hex, 0.90))
        # Per-scene display-colour override (scene_config.json "biomes").
        if overrides and name in overrides:
            tuned_hex = str(overrides[name])
        keys.append(_hex_to_rgb01(sem_hex))                 # sRGB key
        albedos.append([_srgb_to_linear(v) for v in _hex_to_rgb01(tuned_hex)])
        roughs.append(float(rough))
    if not keys:
        # No terrain classes — give the shader one neutral biome so it
        # doesn't divide by zero.
        keys = [[0.5, 0.5, 0.5]]
        albedos = [[_srgb_to_linear(0.5)] * 3]
        roughs = [0.9]
    return keys, albedos, roughs


# ============================================================
# WORLD SIZE — derived so buildings land at human scale
# ============================================================

def derive_world_size(
    semantic_path: Path,
    palette: list[tuple[str, str]],
    catalog: dict,
    target_footprint_m: float = 5.0,
    fallback_m: float = 80.0,
) -> float:
    """Derive the world plane size (meters) so the DOMINANT building
    type lands at ~target_footprint_m across.

    The semantic map is unitless pixels; converting to meters needs ONE
    physical anchor. We use "the typical building should be ~5m". The
    dominant object_placement class (most connected components — houses
    in a town, huts in a camp, etc.) supplies the reference footprint
    in pixels; world_size scales so that median footprint = target.

      world_m = image_px * target_footprint_m / median_building_px

    A dense map of tiny tiles → a larger world (each tile becomes a
    5m house, spread out); a sparse map of big tiles → a smaller world.
    Buildings stay human-scale regardless of map density. Street width
    then follows from footprint_scale + the tiles' spacing.

    Returns a single (square) size; falls back if no buildings found.
    """
    img = cv.load_rgb(semantic_path)
    H, W = img.shape[:2]
    label = cv.threshold_nearest_palette(img, palette)
    obj_names = {c["name"] for c in catalog.get("classes", [])
                 if c.get("intent_type") == "object_placement"}
    # Dominant object class = most connected components.
    best_name, best_foots = None, []
    for i, (name, _h) in enumerate(palette):
        if name not in obj_names:
            continue
        comps = cv.connected_components(label == i, min_area=20)
        foots = [math.sqrt(c["area_px"]) for c in comps]
        if len(foots) > len(best_foots):
            best_name, best_foots = name, foots
    if not best_foots:
        return fallback_m
    best_foots.sort()
    med_px = best_foots[len(best_foots) // 2]
    world_m = W * (target_footprint_m / med_px)
    print(f"[compose_world] derived world_size={world_m:.0f}m "
          f"(ref class '{best_name}': {len(best_foots)} tiles, "
          f"median {med_px:.0f}px → {target_footprint_m}m)")
    return round(world_m, 1)


# ============================================================
# WATER LEVEL — derived from the heightmap over the water mask
# ============================================================

def derive_water_level(
    semantic_path: Path,
    heightmap_path: Path,
    water_hex: str,
    height_scale: float,
    height_offset: float,
    percentile: float = 85.0,
    color_tol: int = 48,
) -> float:
    """Derive the water surface Y (ADR 0059) from the terrain itself.

    Samples the heightmap at every pixel the semantic map marks as
    water, converts to world-Y via the same (h+offset)*scale transform
    the shader uses, and returns a high percentile of those Ys. That
    percentile is the waterline: high enough to fill the river channel,
    low enough that the surrounding terrain (banks, town) stays above
    it. The 85th-percentile default trims the few water pixels that
    bleed onto high banks without flooding the town.

    Yume principle: derive, don't hand-tune. A hardcoded water_level
    floods or drains depending on the map; this reads the actual map.
    """
    import numpy as np
    from PIL import Image

    sm = np.array(Image.open(semantic_path).convert("RGB")).astype(int)
    hm_img = Image.open(heightmap_path).convert("L")
    if hm_img.size != (sm.shape[1], sm.shape[0]):
        hm_img = hm_img.resize((sm.shape[1], sm.shape[0]))
    hm = np.array(hm_img).astype(float) / 255.0

    h = water_hex.lstrip("#")
    ref = np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)])
    dist = np.sqrt(((sm - ref) ** 2).sum(axis=2))
    mask = dist < color_tol
    if not mask.any():
        return 0.0
    y = (hm[mask] + height_offset) * height_scale
    return float(round(float(np.percentile(y, percentile)), 3))


# Heightmap sampling lives in lib_extract_dispatch.HeightmapSampler — used
# by dispatch_extraction (entity Y) + roads_to_instances (path Y). The
# old local copy was removed in the 2026-05-26 merge; there is one
# sampler implementation now.


# ============================================================
# PRIMITIVE → VISUAL
# ============================================================

_PRIM_MESH = {
    "prim_unit_box": "prim_unit_box",
    "prim_unit_cylinder": "prim_unit_cylinder",
    "prim_unit_sphere": "prim_unit_sphere",
}


def primitive_visual(primitive: str, hex_color: str,
                     mesh_override: str | None = None,
                     mesh_prompt: str | None = None,
                     mesh_reference_prompt: str | None = None) -> dict:
    """Yume visual block for a mesh + albedo. `mesh_override` (a kit
    mesh like 'house_kit') wins; else the unit primitive. The kit's
    body color param is named $albedo so the per-bucket color applies
    uniformly; the kit's other params (roof/door/window) keep defaults
    via visual.params deep-merge. Per-instance state.scale (or the
    def's state_init.scale) gives real dimensions.

    `mesh_prompt` (asset_source:tripo) is emitted alongside so the
    assetgen pipeline generates a .glb and patches `mesh` → its path;
    until then the kit/primitive `mesh` here is the fallback. The engine
    auto-normalizes the resulting static .glb into the fitted placement."""
    mesh = mesh_override or _PRIM_MESH.get(primitive, "prim_unit_box")
    visual = {"mesh": mesh, "params": {"albedo": hex_color}}
    if mesh_prompt:
        visual["mesh_prompt"] = mesh_prompt
    # When set, assetgen generates a style-aligned CONCEPT image first
    # (hero-conditioned) and Tripo image_to_model's from it — far closer
    # to the scene style than text-to-3D from mesh_prompt alone.
    if mesh_reference_prompt:
        visual["mesh_reference_prompt"] = mesh_reference_prompt
    return visual


# --- asset-resolution tier policy (2026-05-27) ---------------------------

def _kit_registry() -> set[str]:
    """Set of kit names available in the shared meshes.json — the
    'do we already have a kit?' registry for the reuse check (tier 0)."""
    try:
        meshes = json.loads((DATA_ROOT / "meshes.json").read_text())
        return set(meshes.get("meshes", {}).keys())
    except (OSError, json.JSONDecodeError):
        return set()


def _resolve_asset_source(strat: dict, bucket: dict | None) -> str:
    """Tier decision for a class/bucket: 'kit' | 'procedural' | 'tripo'.
    Explicit `asset_source` wins; else AUTO — 'tripo' if a mesh_prompt is
    declared (no kit chosen), otherwise 'kit'."""
    src = (bucket or {}).get("asset_source") or strat.get("asset_source")
    if src in ("kit", "procedural", "tripo"):
        return src
    has_prompt = bool((bucket or {}).get("mesh_prompt") or strat.get("mesh_prompt"))
    has_kit = bool((bucket or {}).get("mesh") or strat.get("mesh"))
    if has_prompt and not has_kit:
        return "tripo"
    return "kit"


# ============================================================
# EXTRACTION ORCHESTRATION (merged from compose_world_v2)
# ============================================================

def inject_strategies(catalog: dict, lib: dict) -> None:
    """Give every object_placement class a `strategy` block via exact
    name → alias → default resolution (yume-scene-class-catalog Step 4b,
    done programmatically)."""
    for c in catalog.get("classes", []):
        if c.get("intent_type") != "object_placement":
            continue
        name = c["name"]
        if name in lib["classes"]:
            s = dict(lib["classes"][name])
            s["strategy_origin"] = "lib_exact_match"
        elif name in lib["class_aliases"]:
            canonical = lib["class_aliases"][name]
            s = dict(lib["classes"][canonical])
            s["strategy_origin"] = f"lib_alias_match:{canonical}"
        else:
            s = dict(lib["default_strategy"])
            s["strategy_origin"] = "default_with_override"
        s.pop("_comment", None)
        c["strategy"] = s


def detect_anchors(catalog: dict, semantic_map_path: Path,
                   world_size_m: tuple[float, float]) -> dict:
    """Build the anchors dict for face_anchor / snap_to_anchor strategies.
    focal_anchor = centroid of the plaza/cobblestone mass; wall_ring_
    corners = polygon vertices of the wall_segment outline."""
    img = cv.load_rgb(semantic_map_path)
    H, W = img.shape[:2]
    image_size = (W, H)
    palette = [(c["name"], c["hex"]) for c in catalog["classes"]
               if c.get("intent_type") in ("terrain_shader", "object_placement")]
    label_map = cv.threshold_nearest_palette(img, palette)
    anchors: dict = {"focal_anchor": (0.0, 0.0), "wall_ring_corners": []}

    for plaza in ("plaza", "cobblestone", "stone_floor", "dirt_path"):
        idx = next((i for i, (n, _h) in enumerate(palette) if n == plaza), None)
        if idx is None:
            continue
        comps = cv.connected_components(label_map == idx, min_area=50)
        if not comps:
            continue
        comp = max(comps, key=lambda c: c["area_px"])
        anchors["focal_anchor"] = tuple(
            cv.pixel_to_world(*comp["centroid"], image_size, world_size_m))
        break

    wall_idx = next((i for i, (n, _h) in enumerate(palette)
                     if n == "wall_segment"), None)
    if wall_idx is not None:
        comps = cv.connected_components(label_map == wall_idx, min_area=20)
        if comps:
            all_px = np.concatenate([c["pixels"] for c in comps], axis=0)
            outline = dispatch._trace_outline(label_map == wall_idx, {"pixels": all_px})
            if len(outline) >= 3:
                tol = 1.0 * (0.5 * (W / world_size_m[0] + H / world_size_m[1]))
                for cx, cy in dispatch._rdp(outline, tol):
                    anchors["wall_ring_corners"].append(
                        tuple(cv.pixel_to_world(cx, cy, image_size, world_size_m)))
    return anchors


def _class_specs(catalog: dict) -> dict:
    """class/bucket name → {primitive, canonical_scale|None, albedo}.

    Drives the def-builder directly (replaces the old pick_primitive
    monkey-patch). Each variant bucket gets its own spec.
    """
    specs: dict = {}
    for c in catalog.get("classes", []):
        if c.get("intent_type") != "object_placement":
            continue
        strat = c.get("strategy", {})
        prim = strat.get("primitive", "prim_unit_box")
        buckets = strat.get("variant_buckets")
        if buckets:
            # Bucket canonical_scale only when the class uses canonical
            # sizing. With use_canonical_scale:false (fit-to-mask), the
            # def's state_init.scale stays [1,1,1] and each instance
            # carries its fitted scale; the bucket then only provides
            # ALBEDO tier (+ height via canonical_size_meters[1] in the
            # emit). 2026-05-26.
            use_canon = strat.get("use_canonical_scale", False)
            for b in buckets:
                bcanon = list(b.get(
                    "canonical_size_meters",
                    strat.get("canonical_size_meters", [1, 1, 1])))
                specs[b["def"]] = {
                    "primitive": prim,
                    "mesh": b.get("mesh", strat.get("mesh")),
                    "canonical_scale": bcanon if use_canon else None,
                    "albedo": b.get("albedo", c["hex"]),
                    "asset_source": _resolve_asset_source(strat, b),
                    "mesh_prompt": b.get("mesh_prompt", strat.get("mesh_prompt")),
                    "mesh_reference_prompt": b.get("mesh_reference_prompt", strat.get("mesh_reference_prompt")),
                    # Collision (ADR 0067 §colliders): "solid" → a static box
                    # collider sized from canonical_size_meters so the player
                    # can't walk through; "none" → passable (floor decor). The
                    # box scales with per-instance state.scale in-engine.
                    "collision": strat.get("collision", "solid"),
                    "collision_size": list(b.get("canonical_size_meters",
                        strat.get("canonical_size_meters", [1, 1, 1]))),
                }
        else:
            canon = (list(strat["canonical_size_meters"])
                     if strat.get("use_canonical_scale")
                     and "canonical_size_meters" in strat else None)
            # albedo: a kit may want a material color unrelated to the
            # semantic classification hex (e.g. a fountain's stone basin
            # vs its pink semantic key). strategy.albedo overrides.
            specs[c["name"]] = {
                "primitive": prim,
                "mesh": strat.get("mesh"),
                "canonical_scale": canon,
                "albedo": strat.get("albedo", c["hex"]),
                "asset_source": _resolve_asset_source(strat, None),
                "mesh_prompt": strat.get("mesh_prompt"),
                "mesh_reference_prompt": strat.get("mesh_reference_prompt"),
                # Collision (ADR 0067 §colliders): "solid" (default) → static
                # box collider sized from canonical_size_meters; "none" →
                # passable (floor decor like flower_patch). Scales with
                # per-instance state.scale in-engine.
                "collision": strat.get("collision", "solid"),
                "collision_size": list(strat.get("canonical_size_meters",
                                                  [1, 1, 1])),
            }
    return specs


def _check_extraction_alignment(instances, label_map, palette, image_size,
                                world_size_m, catalog) -> None:
    """Gate: each object instance, mapped world→pixel via the CANONICAL
    no-flip convention (matching pixel_to_world + the shaders), should
    land on its own class's pixel in the semantic map. If the shaders/
    sampler ever reintroduce a V flip, the ground/water/height samples
    drift off the entities and this drops well below 100%. Warns loudly.
    """
    W, H = image_size
    wx_m, wz_m = world_size_m
    names = [n for n, _h in palette]
    # bucket def → parent class, so small_house counts as 'house'
    parent: dict[str, str] = {}
    for c in catalog.get("classes", []):
        for b in (c.get("strategy", {}).get("variant_buckets") or []):
            parent[b["def"]] = c["name"]
    hits = tot = 0
    for inst in instances:
        cls = inst.get("class", "")
        if cls == "path_segment":
            continue
        want = parent.get(cls, cls)
        if want not in names:
            continue
        x, _y, z = inst["position"]
        u = (x + wx_m * 0.5) / wx_m
        v = (z + wz_m * 0.5) / wz_m       # NO flip — canonical convention
        px = int(min(W - 1, max(0, u * W)))
        py = int(min(H - 1, max(0, v * H)))
        tot += 1
        if names[label_map[py, px]] == want:
            hits += 1
    if tot:
        pct = 100.0 * hits / tot
        tag = "OK" if pct >= 90.0 else "MISALIGNED"
        print(f"[compose_world] extraction↔render alignment: "
              f"{hits}/{tot} ({pct:.0f}%) [{tag}]")
        if pct < 90.0:
            print("  ⚠ entities don't land on their semantic pixels — a "
                  "coordinate-convention (V-flip?) mismatch between "
                  "pixel_to_world and the shaders/HeightmapSampler.")


def _group_by_class(instances: list[dict]) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for inst in instances:
        grouped.setdefault(inst["class"], []).append(inst)
    return grouped


def _extract_instances(*, game_name, catalog, semantic_map_path,
                       heightmap_path, world_size_m, height_scale,
                       height_offset, anchors, rng_seed) -> list[dict]:
    """Run object extraction. If a per-scene authored extractor exists at
    `data/<game>/extract.py` exposing `extract(ctx)`, run THAT (the
    LLM-authored, comparator-tuned script that DERIVES count / spacing /
    scale / rotation from geometry instead of hand-set constants).
    Otherwise fall back to the generic strategy dispatch.

    The script lives WITH the scene it extracts (per-scene content,
    gitignored alongside the rest of data/<game>/ — it is not shared
    tooling). It receives a ctx dict with everything dispatch gets and
    returns the SAME instance-dict shape (see _instance in
    lib_extract_dispatch). Yume invariant (data-demo.md): the script
    computes values via functions; it never carries hand-tuned magic
    numbers in the strategy JSON.
    """
    script_path = (DATA_ROOT / game_name / "extract.py").resolve()
    if script_path.exists():
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            f"scene_extractor_{game_name}", script_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        ctx = {
            "catalog": catalog,
            "semantic_map_path": semantic_map_path,
            "heightmap_path": heightmap_path,
            "world_size_m": world_size_m,
            "height_scale": height_scale,
            "height_offset": height_offset,
            "anchors": anchors,
            "rng_seed": rng_seed,
        }
        print(f"[compose_world] per-scene extractor: {script_path.name}")
        return mod.extract(ctx)

    return dispatch.dispatch_extraction(
        catalog=catalog, semantic_map_path=semantic_map_path,
        heightmap_path=heightmap_path, world_size_m=world_size_m,
        height_scale=height_scale, height_offset=height_offset,
        anchors=anchors, rng_seed=rng_seed,
    )


# ============================================================
# GENERATE YUME DEMO FILES
# ============================================================

def compose(
    game_name: str,
    catalog_path: Path,
    semantic_map_path: Path,
    heightmap_path: Path | None,
    world_size_m: tuple[float, float] | None = None,
    target_footprint_m: float = 5.0,
    height_scale: float = 3.0,
    height_offset: float = -0.5,
    water_level: float | None = None,
    rng_seed: int = 42,
    biome_overrides: dict | None = None,
    noise_amount: float = 0.12,
    blend_softness: float = 0.12,
    single_biome: bool = False,
    albedo_image: str | None = None,
    water_enabled: bool = True,
) -> Path:
    """Run extraction (objects + non-objects) and write a full
    data/demo_<name>/ folder. Returns the folder path.

    world_size_m: None → DERIVE so the dominant building lands at
        ~target_footprint_m across (human scale). Pass a tuple to force.
    target_footprint_m: the physical-scale anchor (a typical building's
        footprint, meters). The one unitless→metric calibration.
    height_scale: max terrain displacement in meters (shader + entity
        Y sampler both use it). 3.0 for mostly_flat maps; ~8.0 hilly.
    height_offset: -0.5 makes grey-128 = ground level.
    water_level: None → derive from heightmap over the water mask.
    """
    catalog = json.loads(catalog_path.read_text())

    # ---- Extraction (the one place that reads semantic + heightmap) ----
    lib = json.loads(Path(LIB_STRATEGIES).read_text())
    inject_strategies(catalog, lib)

    # Derive world size from building footprint unless forced. No
    # hardcoded scale — the world sizes itself to the content.
    if world_size_m is None:
        palette_w = [(c["name"], c["hex"]) for c in catalog["classes"]
                     if c.get("intent_type") in ("terrain_shader", "object_placement")]
        wsz = derive_world_size(semantic_map_path, palette_w, catalog,
                                target_footprint_m=target_footprint_m)
        world_size_m = (wsz, wsz)
    anchors = detect_anchors(catalog, semantic_map_path, world_size_m)
    print(f"[compose_world] anchors: focal={anchors['focal_anchor']} "
          f"wall_ring_corners={len(anchors['wall_ring_corners'])}")

    instances = _extract_instances(
        game_name=game_name, catalog=catalog,
        semantic_map_path=semantic_map_path, heightmap_path=heightmap_path,
        world_size_m=world_size_m, height_scale=height_scale,
        height_offset=height_offset, anchors=anchors, rng_seed=rng_seed,
    )
    print(f"[compose_world] extracted {len(instances)} object instances")

    # Road network (non-object). Roads render as ground BIOMES (mask
    # coverage = the semantic map). Here we ALSO skeletonize them into
    # a polyline GRAPH, written as metadata (world/road_graph.json) for
    # future NPC pathing — NOT rendered. The mask is the visual; the
    # graph is data.
    img = cv.load_rgb(semantic_map_path)
    H, W = img.shape[:2]
    palette_all = [(c["name"], c["hex"]) for c in catalog["classes"]
                   if c.get("intent_type") in ("terrain_shader", "object_placement")]
    label_all = cv.threshold_nearest_palette(img, palette_all)
    road_result = roads_mod.extract_roads(
        label_map=label_all, palette=palette_all,
        path_class_names=ROAD_CLASS_NAMES, image_size=(W, H),
        world_size_m=world_size_m, simplify_tolerance_meters=0.8,
        min_world_length_m=2.5, prune_branch_meters=1.5)
    print(f"[compose_world] road graph (metadata): "
          f"{road_result['n_polylines']} polylines")

    report = val.validate(
        extracted={"instances": instances, "world_size_meters": list(world_size_m)},
        catalog=catalog)
    print(val.format_report(report))

    # Extraction↔rendering alignment gate (post-mortem 2026-05-26).
    # The shaders + HeightmapSampler must sample the splatmap at the
    # SAME pixel pixel_to_world read each entity from — i.e. NO V flip.
    # Map each object instance's world pos back to a pixel via the
    # canonical no-flip convention; it should land on its own class's
    # (or parent class's) pixel. A flip anywhere drops this far below
    # 100% (empirically 99/216 with the old flip vs 216/216 fixed).
    _check_extraction_alignment(instances, label_all, palette_all,
                                (W, H), world_size_m, catalog)

    specs = _class_specs(catalog)
    grouped = _group_by_class(instances)

    game_dir = (DATA_ROOT / game_name).resolve()

    # NEVER DELETE — Yume convention (memory feedback_never_delete_
    # generated_assets, 2026-05-26 reinforcement): generated assets
    # are paid artifacts. Iterate by overwriting JSON config files
    # (cheap, text, git-diffable) but NEVER rmtree the game dir.
    # Aldenmere's pattern: every PNG/GLB carries a hash suffix and
    # coexists with prior versions; the engine reads from the latest
    # config which references the chosen variant by path.
    #
    # Empirical case 2026-05-26: an earlier version of this function
    # did shutil.rmtree(game_dir) here. compose_world_v2 was called
    # with --semantic-map + --heightmap pointing at files inside
    # the same game_dir; rmtree wiped them BEFORE the copy step
    # could read them. Lost the user's stage-3+4 outputs (re-
    # generated from Downloads/ backup).
    game_dir.mkdir(parents=True, exist_ok=True)
    (game_dir / "entities").mkdir(exist_ok=True)
    (game_dir / "world").mkdir(exist_ok=True)
    (game_dir / "assets" / "layouts").mkdir(parents=True, exist_ok=True)
    (game_dir / "assets" / "textures").mkdir(parents=True, exist_ok=True)

    # Copy semantic map + heightmap into the game's assets dir.
    # NEVER OVERWRITE — if the dest exists, leave it alone (treat as
    # the authoritative version). Caller can pass a different
    # destination name to keep multiple variants side-by-side.
    semantic_dest = None
    heightmap_dest = None
    if semantic_map_path and semantic_map_path.exists():
        semantic_dest = game_dir / "assets" / "layouts" / "semantic_map.png"
        if not semantic_dest.exists():
            shutil.copy(semantic_map_path, semantic_dest)
        elif semantic_map_path.resolve() != semantic_dest.resolve():
            print(
                f"[compose_world] semantic_map already at {semantic_dest} — "
                f"keeping existing (passed-in path differs but NOT "
                f"overwriting; rename if you want to compare variants)"
            )
    if heightmap_path and heightmap_path.exists():
        # Preserve the source basename so variants (heightmap.png,
        # heightmap_hilly.png, ...) coexist. scene.json + the entity
        # Y sampler both reference whichever file was passed.
        heightmap_dest = (
            game_dir / "assets" / "textures" / Path(heightmap_path).name
        )
        if not heightmap_dest.exists():
            shutil.copy(heightmap_path, heightmap_dest)

    # Deterministic path-carving: take the LLM's heightmap + the semantic
    # map's path-class pixels, gaussian-blur into a soft mask, subtract
    # a depression. Writes <textures>/heightmap_carved.png. Downstream
    # (scene.json shader_params + dispatch_extraction y_anchor) uses
    # this carved version. The pristine LLM heightmap stays in place.
    # Deterministic = no LLM drift = paths sink exactly where semantic
    # says they are, aligning with the 3D extraction.
    if (heightmap_dest is not None and semantic_dest is not None):
        carved_dest = (game_dir / "assets" / "textures" / "heightmap_carved.png")
        # Convert METERS to normalized heightmap units via height_scale.
        # Path depth = ~0.25m (subtle footpath rut). Water depth = ~1.5m
        # (deep enough that the whole water_mask region sits below
        # water_level regardless of the LLM's per-pixel channel depth).
        hs = max(height_scale, 0.001)
        # Skip water-mask carving when water is disabled — leaves the
        # water_mask regions as regular ground, no trench.
        water_carve_norm = (1.5 / hs) if water_enabled else 0.0
        applied = carve_paths_into_heightmap(
            heightmap_dest, semantic_dest, catalog, carved_dest,
            path_depth_m=0.25 / hs, path_sigma_px=6.0,
            water_depth_m=water_carve_norm, water_sigma_px=14.0,
        )
        if applied:
            print(f"[compose_world] carved path+water depressions into "
                  f"{carved_dest.name} (deterministic, semantic-aligned)")
            heightmap_dest = carved_dest

        # Flatten foundation pads under buildings (deterministic terrain
        # raise — mirror of the carving pass). For each instance whose
        # class has `_flatten_pad: true`, raise the heightmap under its
        # footprint to a flat pad at the local max-Y; the building's
        # state.position.y is updated to match. No floating houses, no
        # need for separate "foundation" meshes.
        catalog_classes = {c["name"]: c for c in catalog.get("classes", [])}
        # Merge in the strategy dicts (which carry _flatten_pad) — the
        # catalog's `strategy` block per class was injected by
        # inject_strategies earlier; here we just need access to those
        # strategy fields via class name.
        classes_with_strategies = {
            name: (c.get("strategy") or {}) for name, c in catalog_classes.items()
        }
        _ww, _wh = world_size_m
        flat_applied = flatten_building_pads(
            heightmap_dest, instances, classes_with_strategies,
            float(_ww), float(_wh), height_scale, height_offset,
            heightmap_dest,    # overwrite carved file in-place
            sigma_px=4.0, bbox_padding_factor=1.3,
        )
        if flat_applied:
            print(f"[compose_world] flattened foundation pads under "
                  f"buildings into {heightmap_dest.name} (deterministic, "
                  f"instance-aligned; building Y updated to pad)")

        # Programmatic enclosure: for each class whose strategy declares
        # `enclose_around: [target_class, ...]`, generate a rectangular
        # fence loop around each target instance's footprint. Deterministic
        # — doesn't rely on the LLM drawing a closed-loop fence in the
        # semantic. Bypasses the "LLM amnesia for small structural
        # elements" problem the same way flatten_pads and scatter-on-grass
        # bypass LLM density issues.
        from tools.visual_layout.lib_extract_dispatch import HeightmapSampler
        sampler = HeightmapSampler(
            heightmap_dest, max(_ww, _wh), height_scale, height_offset
        ) if heightmap_dest is not None else None

        def _normalize_bucket(c: str) -> str:
            for p in ("large_", "medium_", "small_"):
                if c.startswith(p):
                    return c[len(p):]
            return c

        for cls in catalog.get("classes", []):
            strategy = cls.get("strategy") or {}
            enclose_targets = strategy.get("enclose_around", [])
            if not enclose_targets:
                continue
            pad_m = float(strategy.get("enclose_padding_m", 2.0))
            canonical = strategy.get("canonical_size_meters", [3.0, 1.2, 0.18])
            seg_w = float(canonical[0])
            seg_h = float(canonical[1])
            seg_t = float(canonical[2])
            targets = [i for i in instances
                       if _normalize_bucket(str(i.get("class", ""))) in enclose_targets]
            if not targets:
                continue
            added = 0
            for ti in targets:
                tx, _, tz = (ti.get("position") or [0, 0, 0])[:3]
                ts = ti.get("scale") or [3.0, 3.0, 3.0]
                hw = float(ts[0]) * 0.5 + pad_m
                hd = float(ts[2]) * 0.5 + pad_m
                # 4 corners of the rectangle around the target footprint
                corners = [
                    (tx - hw, tz - hd),
                    (tx + hw, tz - hd),
                    (tx + hw, tz + hd),
                    (tx - hw, tz + hd),
                ]
                # For each edge, tile fence panels at canonical width
                # end-to-end so a long edge gets MULTIPLE panels — preserves
                # mesh detail (rail + posts) instead of stretching one mesh.
                for ei in range(4):
                    ax, az = corners[ei]
                    bx, bz = corners[(ei + 1) % 4]
                    edge_len = math.hypot(bx - ax, bz - az)
                    if edge_len < 0.5:
                        continue
                    n_panels = max(1, int(round(edge_len / seg_w)))
                    panel_len = edge_len / n_panels
                    dirx = (bx - ax) / edge_len
                    dirz = (bz - az) / edge_len
                    yaw = math.atan2(bx - ax, -(bz - az))
                    for pi in range(n_panels):
                        # Panel center along the edge
                        t_along = (pi + 0.5) * panel_len
                        wx = ax + dirx * t_along
                        wz = az + dirz * t_along
                        wy = sampler.y_at(wx, wz) if sampler else 0.0
                        instances.append({
                            "class": cls["name"],
                            "id": f"{cls['name']}_enc_{ti['id']}_{ei}_{pi:02d}",
                            "position": [round(wx, 3), round(wy, 3), round(wz, 3)],
                            "yaw": round(yaw, 4),
                            "primitive": strategy.get("primitive", "prim_unit_box"),
                            "canonical_front_axis": strategy.get(
                                "canonical_front_axis", "+X"),
                            "scale": [round(panel_len, 3), seg_h, seg_t],
                        })
                        added += 1
            if added:
                print(f"[compose_world] enclose_around: generated {added} "
                      f"`{cls['name']}` panels around "
                      f"{len(targets)} {enclose_targets} instance(s)")

    # Derive the TERRAIN-ONLY splatmap (object footprints filled with
    # surrounding terrain). The ground shader samples THIS, not the raw
    # semantic map — so house/wall/etc. footprints don't bleed into the
    # ground, and the plane's render-time texture is a derived terrain
    # layer, not the classification input. Regenerated each run
    # (deterministic from the semantic map; cheap, not a paid asset).
    terrain_splat_dest = None
    # In ortho-albedo mode the ground samples the orthographic painting
    # directly — the multi-biome splatmap is unused, so skip writing it.
    if semantic_dest is not None and albedo_image is None:
        from PIL import Image as _PILImage
        terrain_names = {c["name"] for c in catalog.get("classes", [])
                         if c.get("intent_type") == "terrain_shader"}
        palette_t = [(c["name"], c["hex"]) for c in catalog["classes"]
                     if c.get("intent_type") in ("terrain_shader", "object_placement")]
        splat = build_terrain_splatmap(cv.load_rgb(semantic_dest),
                                       palette_t, terrain_names,
                                       road_names=set(ROAD_CLASS_NAMES))
        terrain_splat_dest = (game_dir / "assets" / "layouts"
                              / "terrain_splatmap.png")
        _PILImage.fromarray(splat, "RGB").save(terrain_splat_dest)
        print(f"[compose_world] wrote terrain splatmap "
              f"(object footprints inpainted) → {terrain_splat_dest.name}")

    # ============ scene.json (MAP portion: terrain only) ============
    # compose_world writes tick/renderer/ground/water. The camera +
    # lighting (the "shell") are added by compose_shell.py — a map
    # generator shouldn't decide how you view the world.
    world_w, world_h = world_size_m
    scene = {
        "_comment": f"Map terrain for {game_name} (compose_world). "
                    f"Camera + lighting added by compose_shell.",
        "tick_seconds": 0.0167,
        "renderer": {"position_scale": 1.0},
        "ground": {
            "mesh": {
                "size": [world_w, world_h],
                "color": "#a0d870",  # fallback if no biome shader
                "subdivide": 64,
            }
        },
    }
    # Wire the multi-biome ground shader (ADR-style splatmap). The
    # semantic map is a CLASSIFICATION splatmap, NOT a texture — the
    # shader classifies each pixel to a biome and renders that biome's
    # TUNED color (blended + noise), then displaces by the heightmap.
    # 2026-05-26: replaced ground_simple_displace (which painted the
    # raw semantic hex directly — "blueprint" look).
    # Ortho-albedo mode (scene_config.terrain.albedo_image set) paints the
    # ground with the hero-conditioned orthographic image itself — bakes
    # the hero's painterly grass/rocks/paths/water onto the floor in one
    # step. Bypasses biome classification entirely.
    if albedo_image is not None and (semantic_dest or heightmap_dest):
        scene["ground"]["mesh"]["shader"] = (
            "res://data/lib/shaders/ground_ortho_displace.gdshader"
        )
        scene["ground"]["mesh"]["plane_size"] = float(world_w)
        ortho_params: dict = {
            "height_scale": float(height_scale),
            "height_offset": float(height_offset),
            "ortho_albedo": f"res://data/{game_name}/{albedo_image}",
        }
        if heightmap_dest:
            ortho_params["heightmap"] = (
                f"res://data/{game_name}/assets/textures/{heightmap_dest.name}"
            )
        scene["ground"]["mesh"]["shader_params"] = ortho_params
        # Flowers still pretty on top of the painted floor.
        scene["ground"]["flowers"] = {
            "enabled": True,
            "count": 2200,
            "radius": round(world_w * 0.45, 1),
            "size": 0.14,
            "colors": ["#f2e25c", "#f6f4ec", "#f0a8c4"],
            "seed": 13,
        }
    elif semantic_dest or heightmap_dest:
        scene["ground"]["mesh"]["shader"] = (
            "res://data/lib/shaders/ground_biome_displace.gdshader"
        )
        scene["ground"]["mesh"]["plane_size"] = float(world_w)
        # ground_renderer.gd only forwards `shader_params` (+ auto-sets
        # plane_size); mesh-level uniforms are silently ignored. So all
        # uniforms live in shader_params (post-mortem 2026-05-26).
        shader_params: dict = {
            "height_scale": float(height_scale),
            "height_offset": float(height_offset),
            "blend_softness": float(blend_softness),
            "noise_amount": float(noise_amount),
        }
        # Sample the DERIVED terrain splatmap (object footprints filled
        # with surrounding terrain), NOT the raw semantic map — so house/
        # wall/etc. footprints don't bleed into the ground.
        if terrain_splat_dest is not None:
            shader_params["biome_map"] = (
                f"res://data/{game_name}/assets/layouts/{terrain_splat_dest.name}"
            )
        elif semantic_dest:
            shader_params["biome_map"] = (
                f"res://data/{game_name}/assets/layouts/{semantic_dest.name}"
            )
        if heightmap_dest:
            shader_params["heightmap"] = (
                f"res://data/{game_name}/assets/textures/{heightmap_dest.name}"
            )
        # Build the biome arrays from terrain_shader classes. biome_key
        # is the splatmap color (sRGB 0..1, matches the raw-sampled map);
        # biome_albedo is the TUNED display color converted sRGB→linear
        # (ALBEDO expects linear); biome_roughness per biome.
        keys, albedos, roughs = _build_biome_arrays(
            catalog, overrides=biome_overrides, single_biome=single_biome)
        shader_params["biome_count"] = len(keys)
        shader_params["biome_key"] = keys
        shader_params["biome_albedo"] = albedos
        shader_params["biome_roughness"] = roughs

        # Grass detail texture + wind (shared shader feature). The shader
        # applies detail + the gust-band wind ONLY to the grass biome slot,
        # so we tell it which slot that is (same order as _build_biome_arrays;
        # -1 = no grass → feature inert). The detail map is a shared lib asset;
        # wind params use the shader's defaults (tunable per scene later).
        terrain_ordered = [c["name"] for c in catalog.get("classes", [])
                           if c.get("intent_type") == "terrain_shader"][:8]
        shader_params["grass_biome_index"] = (
            terrain_ordered.index("grass") if "grass" in terrain_ordered else -1)
        grass_tex = DATA_ROOT / "lib" / "textures" / "grass_detail.png"
        if shader_params["grass_biome_index"] >= 0 and grass_tex.exists():
            shader_params["grass_detail"] = "res://data/lib/textures/grass_detail.png"
        scene["ground"]["mesh"]["shader_params"] = shader_params

        # Real grass blades (MultiMesh, GrassRenderer) — OPT-IN, default OFF.
        # The painterly pass (slope/height shading + SSAO) carries the
        # hero-reference look without blades, so the field stays smooth.
        # Flip enabled:true (here or in scene_config) to add protruding
        # blades back. count/radius are the perf knobs when enabled.
        if shader_params["grass_biome_index"] >= 0:
            scene["ground"]["grass_blades"] = {
                "enabled": False,
                "count": 60000,
                "radius": round(world_w * 0.45, 1),
                "blade_w": 0.085,
                "blade_h": 0.24,
                "scale_jitter": 0.35,
                "seed": 7,
            }
            # Flower specks — the hero reference's scattered yellow/white
            # dots. Sparse, per-instance colour, one draw call. ON by
            # default (cheap); the painterly grass it sits on is smooth.
            scene["ground"]["flowers"] = {
                "enabled": True,
                "count": 2200,
                "radius": round(world_w * 0.45, 1),
                "size": 0.14,
                "colors": ["#f2e25c", "#f6f4ec", "#f0a8c4"],
                "seed": 13,
            }

    # ADR 0059 — real water surface. Emit a `water` block when the
    # catalog has a water class (terrain_shader named water*). A flat
    # transparent plane at water_level; the heightmap-carved riverbed
    # fills with water, depth-test handles the shoreline.
    water_class = next(
        (c for c in catalog.get("classes", [])
         if str(c.get("name", "")).startswith("water")
         and c.get("intent_type") == "terrain_shader"),
        None,
    )
    if water_class is not None and heightmap_dest and water_enabled:
        # Derive the waterline from the heightmap over the water mask
        # unless the caller passed an explicit override. Default
        # behavior = derive (no flooding-the-town guesswork).
        if water_level is None and semantic_dest is not None:
            level = derive_water_level(
                semantic_dest, heightmap_dest,
                str(water_class.get("hex", "#3070c0")),
                height_scale, height_offset,
            )
            print(f"[compose_world] derived water_level={level} "
                  f"(85th pct of heightmap-Y over water mask)")
        else:
            level = water_level if water_level is not None else 0.0

        # Derive a WATER MASK (white = river/pond region) so the water
        # surface renders ONLY there — not as a full plane that floods
        # low city terrain. Dilated a few px so water meets the banks.
        from PIL import Image as _PILImg
        sm = cv.load_rgb(semantic_dest)
        wmask = cv.threshold_by_hex(sm, str(water_class.get("hex", "#3070c0")), 40)
        # small dilation (~4px) via 4-neighbour rolls
        m = wmask.copy()
        for _ in range(4):
            m = (m | np.roll(m, 1, 0) | np.roll(m, -1, 0)
                 | np.roll(m, 1, 1) | np.roll(m, -1, 1))
        water_mask_dest = game_dir / "assets" / "layouts" / "water_mask.png"
        _PILImg.fromarray((m * 255).astype("uint8"), "L").save(water_mask_dest)

        # Box-mesh water volume (2026-05-28): the mesh is now a 3D BOX
        # with the top face at water_level and the bottom face buried
        # well below the deepest carved channel. The engine's water
        # renderer reads box_depth to build a BoxMesh; if box_depth is
        # absent it falls back to the legacy flat PlaneMesh (for older
        # demos). With a box + cull_disabled shader, the player descending
        # below water_level renders the box's interior — refraction +
        # depth-tint produces the underwater look for FREE, no
        # post-process needed.
        scene["water"] = {
            "_comment": "ADR 0059 water volume (box mesh). Confined to the "
                        "river region by water_mask (top face discards "
                        "outside mask). box_depth: thickness BELOW the "
                        "water surface (so terrain hides the box bottom).",
            "mesh": {
                "size": [world_w, world_h],
                "level": float(level),
                "box_depth": 8.0,
                "shader": "res://data/lib/shaders/water_stylized.gdshader",
                "shader_params": {
                    # Stylized water — box-mesh aware. Uniform names match
                    # water_stylized.gdshader (2026-05-28).
                    "deep_color": [0.03, 0.10, 0.20, 1.0],
                    "shallow_color": [0.30, 0.62, 0.74, 0.85],
                    "foam_color": [0.97, 0.99, 1.0, 1.0],
                    "water_normal_tex": "res://data/lib/textures/water_normal.tres",
                    "normal_tile_m": 6.0,
                    "ripple_strength": 0.85,
                    "flow_dir": [0.72, 0.32],
                    "flow_speed": 0.045,
                    "depth_fade_m": 0.45,
                    "refraction_strength": 0.05,
                    "fresnel_power": 3.5,
                    "foam_distance_m": 0.65,
                    "foam_softness": 0.40,
                    "foam_animation": 1.8,
                    "use_water_mask": True,
                    "plane_size": float(world_w),
                    "water_mask": (
                        f"res://data/{game_name}/assets/layouts/"
                        f"{water_mask_dest.name}"
                    ),
                },
            },
        }
    (game_dir / "scene.json").write_text(json.dumps(scene, indent=2))

    # NOTE (ADR 0067): world/state.json is GAME-domain (global state) —
    # owned by /yume-design, not the scene layer. compose_world no
    # longer writes it. A flat scene needs no world_state to boot.

    # ============ world/road_graph.json (metadata, not rendered) ====
    # Skeleton-derived road polylines. Roads render as ground biomes
    # (mask coverage); this graph is for future NPC pathing / "walk
    # the streets" gameplay. World-space polylines [[x, z], ...].
    (game_dir / "world" / "road_graph.json").write_text(json.dumps({
        "_comment": "Road centerline graph (metadata for pathing). "
                    "Roads are RENDERED as ground biomes, not from this. "
                    "Each polyline is a list of [world_x, world_z] points.",
        "n_polylines": road_result["n_polylines"],
        "polylines": road_result["polylines_world"],
    }, indent=2))

    # world_clock / cameras / player / camera+movement rules are the
    # SHELL — written by compose_shell.py, not here. game/flow.json,
    # levels/, and goals are the GAME — owned by /yume-design (ADR 0067).
    # The scene layer only defines world CONTENT (defs + placements).

    # ============ entities/auto_gen.json — defs + flat placements ====
    # Driven by _class_specs (strategy primitive + canonical scale +
    # albedo). Each variant bucket (small/medium/large_house) + the
    # synthetic path_segment get their own def. No pick_primitive
    # heuristic, no monkey-patch (merged 2026-05-26).
    defs_doc = {"_comment": f"Auto-gen primitives for {game_name}.", "definitions": []}
    kit_registry = _kit_registry()
    for name in sorted(grouped.keys()):
        if not grouped[name]:
            continue
        spec = specs.get(name, {"primitive": "prim_unit_box",
                                "canonical_scale": None, "albedo": "#808080"})
        canonical = spec["canonical_scale"]
        state_init = {"scale": [float(canonical[0]), float(canonical[1]),
                                float(canonical[2])]} if canonical else {"scale": [1, 1, 1]}
        # Asset-resolution tier: kit/procedural use the kit mesh as-is;
        # tripo also emits mesh_prompt so the assetgen pipeline generates a
        # .glb (the kit mesh is the fallback until then). 2026-05-27.
        source = spec.get("asset_source", "kit")
        emit_prompt = spec.get("mesh_prompt") if source == "tripo" else None
        emit_ref_prompt = spec.get("mesh_reference_prompt") if source == "tripo" else None
        if source == "tripo":
            # (2) kit-reuse check — don't pay for a Tripo gen when a fitting
            # kit already exists. Flag <class>_kit / the spec's own kit.
            candidates = [f"{name}_kit", spec.get("mesh") or ""]
            existing = [k for k in candidates if k and k in kit_registry]
            if existing:
                print(f"[compose_world] [kit-reuse] class '{name}' is asset_source"
                      f":tripo but kit(s) {existing} exist — set asset_source:kit "
                      f"to reuse and skip the paid Tripo gen.")
        entity_def = {
            "id": name,
            "tags": [name, "compose_world_gen"],
            "properties": {},
            "state_init": state_init,
            "visual": primitive_visual(spec["primitive"], spec["albedo"],
                                       mesh_override=spec.get("mesh"),
                                       mesh_prompt=emit_prompt,
                                       mesh_reference_prompt=emit_ref_prompt),
        }
        # Collider (ADR 0067 §colliders). Solid props get a STATIC box sized
        # from canonical_size_meters, offset up by half-height so its base
        # sits at the entity's ground position. `wall` layer is in the shell
        # player's collision_mask → the player can't walk through. The engine
        # scales the box by per-instance state.scale (physics_body_builder).
        # "none" (floor decor: flower_patch, walkable bridge, thin banner) →
        # no physics block → passable. Configurable via the class's
        # `collision` field in extraction_strategies.json.
        if spec.get("collision", "solid") != "none":
            cs = spec.get("collision_size") or [1.0, 1.0, 1.0]
            entity_def["physics"] = {
                "$extends": "@lib.physics.bodies.static_wall",
                "collision_shape": {
                    "type": "box",
                    # from_visual_mesh: the engine shrink-wraps the box to the
                    # entity's actual visual .glb (normalized + per-instance
                    # scaled exactly like the renderer) so the collider tracks
                    # the drawn mesh. `size`/`offset` below are the FALLBACK for
                    # kit/primitive visuals (no .glb bbox to read) — sized from
                    # canonical_size_meters. (ADR 0067 §colliders.)
                    "from_visual_mesh": True,
                    # Fallback box (kit/primitive visuals with no .glb bbox):
                    # canonical size, base on the ground, TIGHT (no skirt).
                    # .glb visuals get shrink-wrapped to the actual mesh bbox
                    # in-engine (_shrinkwrap_box_to_visual). (ADR 0067.)
                    "size": [float(cs[0]), float(cs[1]), float(cs[2])],
                    "offset": [0.0, float(cs[1]) * 0.5, 0.0],
                },
            }
        defs_doc["definitions"].append(entity_def)

    # Flat placements live in the SAME file as the defs (ADR 0067): the
    # engine globs entities/*.json and spawns initial_instances, so a
    # scene boots flat with no levels/ or flow.json. Instances consume
    # the extraction output directly: position Y is ALREADY
    # heightmap-sampled at extraction time (no re-sampling);
    # canonical-scale classes carry size in their def's state_init.scale
    # (instances are position + yaw only); others carry per-instance
    # scale. _y_offset lifts a flat feature (path segment) above ground.
    initial_instances = []
    for name in sorted(grouped.keys()):
        canonical = specs.get(name, {}).get("canonical_scale")
        for inst in grouped[name]:
            x, y, z = inst["position"]
            pos = [round(x, 3), round(y + inst.get("_y_offset", 0.0), 3), round(z, 3)]
            state: dict = {"yaw": round(inst["yaw"], 4)}
            if canonical is None and "scale" in inst:
                s = inst["scale"]
                state["scale"] = [max(0.2, float(s[0])), float(s[1]),
                                  max(0.2, float(s[2]))]
            initial_instances.append({
                "def": name,
                "id": inst["id"],
                "position": pos,
                "state": state,
            })

    # auto_gen.json holds MAP CONTENT only — the extracted defs +
    # placements. The shell singletons (world_clock, player, free
    # cameras) come from compose_shell.py; a game's player + mechanics
    # come from /yume-design. (No world_clock/player here → not runnable
    # on its own; that's intentional — add a shell or a game next.)
    defs_doc["initial_instances"] = initial_instances
    (game_dir / "entities" / "auto_gen.json").write_text(
        json.dumps(defs_doc, indent=2)
    )

    # Re-apply any previously-generated .glb / texture paths (ADR 0067
    # Assets layer). The write_text above re-emitted tripo classes with
    # their kit FALLBACK mesh + mesh_prompt — wiping the assetgen-resolved
    # res:// paths. The Assets layer owns that resolution, so we ASK it to
    # re-resolve rather than reading our own prior output (compose_world
    # stays a pure function of its inputs). patch_only generates nothing
    # and needs no API key; it's a no-op when no assets were ever generated
    # (guarded on asset_gen.json existing). Empirical 2026-06-08: a second
    # compose_world run silently reverted tiny_village/lanterns meshes to
    # kit primitives.
    if (game_dir / "asset_gen.json").exists():
        try:
            from tools.yume_assetgen.pipeline import run_pipeline
            s = run_pipeline(game_dir, patch_only=True, verbose=False)
            if s.get("patched"):
                print(f"[compose_world] re-applied {s['patched']} generated "
                      f"asset path(s) to entity defs")
        except Exception as e:  # never let a re-patch break composition
            print(f"[compose_world] WARN: mesh re-patch skipped ({e})")

    return game_dir


# ============================================================
# CLI
# ============================================================

def main():
    ap = argparse.ArgumentParser(prog="compose_world")
    ap.add_argument("game_name", help="folder name (under godot/data/<name>)")
    ap.add_argument("--catalog", required=True, help="stage-2 class_catalog.json")
    ap.add_argument("--semantic-map", required=True, help="stage-3 semantic map PNG")
    ap.add_argument("--heightmap", default=None, help="stage-4 heightmap PNG")
    ap.add_argument("--world-x", type=float, default=None,
                    help="force world X size (m). Omit to DERIVE from "
                         "building footprint (human scale).")
    ap.add_argument("--world-z", type=float, default=None,
                    help="force world Z size (m). Omit to derive.")
    # Defaults are None so we can tell "flag supplied" from "use config /
    # built-in". Precedence: CLI flag > scene_config.json > built-in.
    ap.add_argument("--target-house-m", type=float, default=None,
                    help="physical anchor: typical building footprint (m). "
                         "World size derives so the dominant building lands "
                         "at this size. (config: world.target_house_m)")
    ap.add_argument("--height-scale", type=float, default=None,
                    help="max terrain displacement (m). 3.0 flat, ~8.0 hilly. "
                         "(config: terrain.height_scale)")
    ap.add_argument("--height-offset", type=float, default=None,
                    help="(config: terrain.height_offset)")
    ap.add_argument("--water-level", type=float, default=None,
                    help="water surface Y (ADR 0059). Omit to derive from "
                         "the heightmap over the water mask. (config: water.level)")
    ap.add_argument("--rng-seed", type=int, default=None,
                    help="(config: world.rng_seed)")
    args = ap.parse_args()

    cfg = scfg.SceneConfig.load(DATA_ROOT / args.game_name)

    # World size: CLI --world-x/z > config world.size_m > derive (None).
    forced_world = None
    if args.world_x is not None and args.world_z is not None:
        forced_world = (args.world_x, args.world_z)
    elif cfg.world.size_m and len(cfg.world.size_m) == 2:
        forced_world = (float(cfg.world.size_m[0]), float(cfg.world.size_m[1]))

    game_dir = compose(
        game_name=args.game_name,
        catalog_path=Path(args.catalog),
        semantic_map_path=Path(args.semantic_map),
        heightmap_path=Path(args.heightmap) if args.heightmap else None,
        world_size_m=forced_world,
        target_footprint_m=scfg.pick(args.target_house_m, cfg.world.target_house_m),
        height_scale=scfg.pick(args.height_scale, cfg.terrain.height_scale),
        height_offset=scfg.pick(args.height_offset, cfg.terrain.height_offset),
        water_level=scfg.pick(args.water_level, cfg.water.level),
        rng_seed=scfg.pick(args.rng_seed, cfg.world.rng_seed),
        biome_overrides=cfg.biomes,
        noise_amount=cfg.terrain.noise_amount,
        blend_softness=cfg.terrain.blend_softness,
        single_biome=cfg.terrain.single_biome,
        albedo_image=cfg.terrain.albedo_image,
        water_enabled=cfg.water.enabled,
    )
    print(f"[compose_world] wrote MAP at: {game_dir}")
    print(f"[compose_world] next: python3 -m tools.visual_layout.compose_shell "
          f"{args.game_name}  (adds camera/player/input → runnable)")


if __name__ == "__main__":
    main()
