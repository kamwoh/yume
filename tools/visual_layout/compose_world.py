"""compose_world.py — the MAP layer of the text-to-world pipeline.

Produces the world CONTENT from a semantic map + heightmap: entity
defs, object placements, terrain assets (biome splatmap, water mask,
road graph), and scene.json's ground + water. It says NOTHING about
how you view or control the world — that "shell" (camera, player,
input, lighting, .tscn) is added separately by compose_shell.py, so a
map generator never decides you walk around in third person.

The flow:
  1. inject strategies from data/lib/extraction_strategies.json
  2. detect anchors (plaza centroid, wall-ring corners)
  3. dispatch extraction (lib_extract_dispatch) → object instances
  4. extract road graph (lib_extract_roads) → world/road_graph.json
     (roads RENDER as ground biomes / mask coverage; graph is metadata)
  5. validate + extraction↔render alignment check
  6. group instances by class/bucket → entity defs (primitive boxes/
     cylinders/spheres, sized + colored per strategy)
  7. write scene.json (ground biome shader + water plane), defs, level
     placements (objects only), terrain assets, road_graph, flow

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

    instances = dispatch.dispatch_extraction(
        catalog=catalog, semantic_map_path=semantic_map_path,
        heightmap_path=heightmap_path, world_size_m=world_size_m,
        height_scale=height_scale, height_offset=height_offset,
        anchors=anchors, rng_seed=rng_seed,
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
    (game_dir / "levels" / "level_default").mkdir(parents=True, exist_ok=True)
    (game_dir / "game").mkdir(exist_ok=True)
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

    # Derive the TERRAIN-ONLY splatmap (object footprints filled with
    # surrounding terrain). The ground shader samples THIS, not the raw
    # semantic map — so house/wall/etc. footprints don't bleed into the
    # ground, and the plane's render-time texture is a derived terrain
    # layer, not the classification input. Regenerated each run
    # (deterministic from the semantic map; cheap, not a paid asset).
    terrain_splat_dest = None
    if semantic_dest is not None:
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
    if water_class is not None and heightmap_dest:
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

        scene["water"] = {
            "_comment": "ADR 0059 water surface. Confined to the river "
                        "region by water_mask (not a full plane). level = "
                        "world Y of the surface; the masked region's "
                        "riverbed (below level) fills.",
            "mesh": {
                "size": [world_w, world_h],
                "level": float(level),
                "shader": "res://data/lib/shaders/water_stylized.gdshader",
                "shader_params": {
                    "base_color": [0.10, 0.30, 0.45, 0.80],
                    "highlight_color": [0.62, 0.80, 0.92, 0.85],
                    "wave_speed": 0.22,
                    "ripple_density": 10.0,
                    "metallic_uniform": 0.30,
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

    # ============ world/state.json ============
    # Per data-demo.md convention: world/state.json is for env-level
    # global non-entity state (usually empty — env.world_state).
    # Singleton entities (world_clock) + free_camera defs go in
    # entities/ as proper entity definition files.
    (game_dir / "world" / "state.json").write_text(json.dumps({
        "_comment": "Empty placeholder. Singletons (world_clock, free_camera) live in entities/."
    }, indent=2))

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
    # SHELL — written by compose_shell.py, not here. The map only
    # defines world CONTENT.

    # ============ game/flow.json ============
    flow = {
        "levels": [{"id": "level_default", "name": "Auto-generated scene"}],
        "starting_level": "level_default",
    }
    (game_dir / "game" / "flow.json").write_text(json.dumps(flow, indent=2))

    # ============ entities/auto_gen.json — one def per class/bucket ====
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
        defs_doc["definitions"].append({
            "id": name,
            "tags": [name, "compose_world_gen"],
            "properties": {},
            "state_init": state_init,
            "visual": primitive_visual(spec["primitive"], spec["albedo"],
                                       mesh_override=spec.get("mesh"),
                                       mesh_prompt=emit_prompt,
                                       mesh_reference_prompt=emit_ref_prompt),
        })
    (game_dir / "entities" / "auto_gen.json").write_text(
        json.dumps(defs_doc, indent=2)
    )

    # ============ levels/level_default/entities.json ============
    # Instances consume the extraction output directly: position Y is
    # ALREADY heightmap-sampled at extraction time (no re-sampling);
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

    # The level holds MAP CONTENT only — the extracted objects. The
    # shell singletons (world_clock, player, free cameras) are spliced
    # in by compose_shell.py. (No world_clock/player here → not runnable
    # on its own; that's intentional — run compose_shell next.)
    level_doc = {
        "_comment": f"Map content for {game_name} (compose_world). "
                    f"compose_shell splices in world_clock/player/cameras.",
        "initial_instances": initial_instances
    }
    (game_dir / "levels" / "level_default" / "entities.json").write_text(
        json.dumps(level_doc, indent=2)
    )

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
    )
    print(f"[compose_world] wrote MAP at: {game_dir}")
    print(f"[compose_world] next: python3 -m tools.visual_layout.compose_shell "
          f"{args.game_name}  (adds camera/player/input → runnable)")


if __name__ == "__main__":
    main()
