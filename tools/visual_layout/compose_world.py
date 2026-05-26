"""compose_world.py — stages 5-7 of the text-to-world pipeline.

ONE entry point: prose-derived semantic map + heightmap → a runnable
Yume demo. Reads the stage-2 catalog, runs the strategy-driven
extraction (objects + non-objects), and writes the demo using
CODE-DRAWN PRIMITIVE SHAPES (boxes, cylinders, spheres). No asset
gen yet — every object's visual is a primitive sized + colored per
its strategy.

The flow (merged 2026-05-26 — was compose_world + compose_world_v2):
  1. inject strategies from data/lib/extraction_strategies.json
  2. detect anchors (plaza centroid, wall-ring corners)
  3. dispatch extraction (lib_extract_v2) → object instances
  4. extract road graph (lib_extract_roads) → world/road_graph.json
     metadata (roads RENDER as ground biomes, mask coverage)
  5. validate (lib_extract_validate)
  6. group instances by class/bucket → entity defs
  7. write scene.json (biome ground shader + water plane), entity
     defs, level instances, cameras, rules, input, flow, .tscn

OBJECTS (houses, walls, towers, bridges, fountain) become entities.
NON-OBJECTS become: biomes (ground splatmap shader), water (ADR 0059
plane), roads (extracted path-segment entities). The semantic map is
consumed ONCE here as a classification input.

Usage:
    python3 -m tools.visual_layout.compose_world demo_pipeline_v1 \\
        --catalog   /tmp/_class_catalog.json \\
        --semantic-map /path/to/semantic.png \\
        --heightmap    /path/to/heightmap.png \\
        --height-scale 8.0
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
from tools.visual_layout import lib_extract_v2 as v2         # noqa: E402
from tools.visual_layout import lib_extract_roads as roads_mod  # noqa: E402
from tools.visual_layout import lib_extract_validate as val  # noqa: E402

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
    "grass":          ("#6f9a4e", 0.95),
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
                           terrain_names: set[str]) -> np.ndarray:
    """Derive a TERRAIN-ONLY splatmap from the semantic map.

    Object_placement pixels (house / wall / tower / bridge / fountain /
    townhall) carry no ground info — they just say "object here". If the
    ground shader sampled them, it would classify each to the nearest
    TERRAIN biome and paint the object's footprint into the ground (a
    house-red tile → a brown dirt patch under the house). Wrong.

    So: flood-fill every non-terrain pixel with its nearest terrain
    pixel's semantic color (iterative 4-neighbour dilation of the
    terrain regions inward). The result is a clean terrain map the
    ground shader can sample — objects sit ON it as entities; the
    ground beneath them reads as the surrounding terrain.

    Returns an RGB uint8 array (the derived splatmap).
    """
    H, W = img.shape[:2]
    label = cv.threshold_nearest_palette(img, palette)
    terrain_idx = {i for i, (n, _h) in enumerate(palette) if n in terrain_names}
    filled = np.isin(label, list(terrain_idx))
    out = img.copy()
    # Multi-source inward fill: each loop pushes terrain colors one ring
    # into the object regions. Converges in ~(max object radius in px)
    # iterations. Cap to avoid pathological non-termination.
    for _ in range(256):
        if filled.all():
            break
        progressed = False
        for axis, shift in ((0, 1), (0, -1), (1, 1), (1, -1)):
            nbr_filled = np.roll(filled, shift, axis=axis)
            nbr_out = np.roll(out, shift, axis=axis)
            take = (~filled) & nbr_filled
            if take.any():
                out[take] = nbr_out[take]
                filled[take] = True
                progressed = True
        if not progressed:
            break
    return out


def _build_biome_arrays(catalog: dict, max_biomes: int = 8):
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
    for c in catalog.get("classes", []):
        if c.get("intent_type") != "terrain_shader":
            continue
        if len(keys) >= max_biomes:
            break
        name = str(c.get("name", ""))
        sem_hex = str(c.get("hex", "#808080"))
        tuned_hex, rough = BIOME_PALETTE.get(name, (sem_hex, 0.90))
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


# Heightmap sampling lives in lib_extract_v2.HeightmapSampler — used
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


def primitive_visual(primitive: str, hex_color: str) -> dict:
    """Yume visual block for a unit-primitive mesh + albedo. Per-instance
    state.scale (or the def's state_init.scale) gives real dimensions."""
    mesh = _PRIM_MESH.get(primitive, "prim_unit_box")
    return {"mesh": mesh, "params": {"albedo": hex_color}}


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
            outline = v2._trace_outline(label_map == wall_idx, {"pixels": all_px})
            if len(outline) >= 3:
                tol = 1.0 * (0.5 * (W / world_size_m[0] + H / world_size_m[1]))
                for cx, cy in v2._rdp(outline, tol):
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
            for b in buckets:
                specs[b["def"]] = {
                    "primitive": prim,
                    "canonical_scale": list(b.get(
                        "canonical_size_meters",
                        strat.get("canonical_size_meters", [1, 1, 1]))),
                    "albedo": b.get("albedo", c["hex"]),
                }
        else:
            canon = (list(strat["canonical_size_meters"])
                     if strat.get("use_canonical_scale")
                     and "canonical_size_meters" in strat else None)
            specs[c["name"]] = {
                "primitive": prim,
                "canonical_scale": canon,
                "albedo": c["hex"],
            }
    return specs


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
    world_size_m: tuple[float, float] = (80.0, 80.0),
    height_scale: float = 3.0,
    height_offset: float = -0.5,
    water_level: float | None = None,
    rng_seed: int = 42,
) -> Path:
    """Run extraction (objects + non-objects) and write a full
    data/demo_<name>/ folder. Returns the folder path.

    height_scale: max terrain displacement in meters (shader + entity
        Y sampler both use it). 3.0 for mostly_flat maps; ~8.0 hilly.
    height_offset: -0.5 makes grey-128 = ground level.
    water_level: None → derive from heightmap over the water mask.
    """
    catalog = json.loads(catalog_path.read_text())

    # ---- Extraction (the one place that reads semantic + heightmap) ----
    lib = json.loads(Path(LIB_STRATEGIES).read_text())
    inject_strategies(catalog, lib)
    anchors = detect_anchors(catalog, semantic_map_path, world_size_m)
    print(f"[compose_world] anchors: focal={anchors['focal_anchor']} "
          f"wall_ring_corners={len(anchors['wall_ring_corners'])}")

    instances = v2.dispatch_extraction(
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
                                       palette_t, terrain_names)
        terrain_splat_dest = (game_dir / "assets" / "layouts"
                              / "terrain_splatmap.png")
        _PILImage.fromarray(splat, "RGB").save(terrain_splat_dest)
        print(f"[compose_world] wrote terrain splatmap "
              f"(object footprints inpainted) → {terrain_splat_dest.name}")

    # ============ scene.json ============
    world_w, world_h = world_size_m
    scene = {
        "_comment": f"Auto-generated by compose_world.py for {game_name}. Code-primitive scene.",
        "tick_seconds": 0.0167,
        "renderer": {"position_scale": 1.0},
        "ground": {
            "mesh": {
                "size": [world_w, world_h],
                "color": "#a0d870",  # fallback if no biome shader
                "subdivide": 64,
            }
        },
        "camera": {
            "$extends": "@lib.cameras.iso_top_down",
            "follow_tag": "world_clock",   # follows the singleton at origin
            "distance": world_w * 0.55,    # frame the whole town
            "ortho_size": world_w * 0.7,   # 56m visible — fits an 80m world
        },
        "lighting": {
            "directional_light": {
                "direction": [0.4, -1.0, 0.3],
                "color": "#fff0d0",
                "energy": 1.2,
            },
            "ambient": {"color": "#a0b0c0", "energy": 0.4},
            "sky": {"top_color": "#88aadd", "bottom_color": "#dde0e8"},
        }
    }
    # Wire the multi-biome ground shader (ADR-style splatmap). The
    # semantic map is a CLASSIFICATION splatmap, NOT a texture — the
    # shader classifies each pixel to a biome and renders that biome's
    # TUNED color (blended + noise), then displaces by the heightmap.
    # 2026-05-26: replaced ground_simple_displace (which painted the
    # raw semantic hex directly — "blueprint" look).
    if semantic_dest or heightmap_dest:
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
            "blend_softness": 0.12,
            "noise_amount": 0.07,
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
        keys, albedos, roughs = _build_biome_arrays(catalog)
        shader_params["biome_count"] = len(keys)
        shader_params["biome_key"] = keys
        shader_params["biome_albedo"] = albedos
        shader_params["biome_roughness"] = roughs
        scene["ground"]["mesh"]["shader_params"] = shader_params

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

    # ============ entities/world_clock.json ============
    # Scene starts in isometric_3d for an obliquely-angled view. Press
    # C in-game to toggle into free_cam — pre-positioned anchors are
    # spawned below and Tab cycles between them.
    world_clock_def = {
        "_comment": "Auto-generated singleton. Starts in isometric_3d (good 3D framing). C → free_cam.",
        "definitions": [
            {
                "id": "world_clock",
                "tags": ["world_clock", "persistent"],
                "properties": {},
                "state_init": {
                    "camera_mode": "isometric_3d",
                    "previous_camera_mode": "isometric_3d",
                    "active_camera_id": "camera_oblique",
                    "current_level": "level_default",
                },
                "visual": {"hidden": True}
            }
        ]
    }
    (game_dir / "entities" / "world_clock.json").write_text(
        json.dumps(world_clock_def, indent=2)
    )

    # ============ entities/cameras.json ============
    # The free_camera def + 3 pre-positioned anchors.
    cameras_def = {
        "_comment": "Cinematic camera anchors. Logical entities — no mesh, hidden. Tab cycles between them in free_cam.",
        "definitions": [
            {
                "id": "free_camera",
                "tags": ["free_camera", "persistent", "decorative"],
                "properties": {"display_name": "Camera"},
                "state_init": {
                    "position": [0, 30, 30],
                    "yaw": 0.0,
                    "pitch": -0.6
                },
                "visual": {"hidden": True}
            }
        ]
    }
    (game_dir / "entities" / "cameras.json").write_text(
        json.dumps(cameras_def, indent=2)
    )

    # ============ entities/player.json ============
    # Minimal hidden actor — required for InputRegistrar to route
    # input. The default actor_manager resolves the "active actor" by
    # the `player` tag; with no player entity, _find_actor_id returns
    # "" and InputRegistrar.poll early-returns → input actions are
    # never queued onto the scheduler → rules with input triggers
    # never fire.
    player_def = {
        "_comment": "Hidden actor anchor. Exists ONLY so InputRegistrar has someone to route input to. No mesh, no physics, no movement rules — just an input target.",
        "definitions": [
            {
                "id": "player_input_anchor",
                "tags": ["player", "actor", "persistent"],
                "properties": {"display_name": "Input Anchor"},
                "state_init": {},
                "visual": {"hidden": True}
            }
        ]
    }
    (game_dir / "entities" / "player.json").write_text(
        json.dumps(player_def, indent=2)
    )

    # ============ world/rules/<NN>_*.json ============
    # Matching aldenmere's convention: numbered files per feature
    # module under world/rules/ instead of a single rules.json. The
    # engine loads either (load_rules_files_for handles both paths)
    # but the directory pattern lets future modules add rules without
    # editing one monolithic file. Naming: NN_<feature>.json,
    # alphabetic load order is deterministic.
    (game_dir / "world" / "rules").mkdir(exist_ok=True)
    rules_doc = {
        "_comment": "Auto-generated rules. C key toggles free_cam ↔ "
                    "previous camera mode.",
        "rules": [
            {
                "id": "freecam_enter",
                "_comment": "C → save current camera_mode + enter free_cam. "
                            "Engine has no _neq operator (only _eq / _in / _gt / "
                            "_lt / _gte / _lte / _has) — list the allowed source "
                            "modes via _in instead.",
                "trigger": {"type": "input", "action": "toggle_freecam"},
                "query": {
                    "tags_all": ["world_clock"],
                    "state": {"camera_mode_in": [
                        "isometric_3d", "top_down_3d",
                        "third_person_3d", "first_person_3d", "top_down_2d"
                    ]}
                },
                "effect": [
                    {"type": "state_set", "target": "self",
                     "field": "previous_camera_mode",
                     "value": "self.state.camera_mode"},
                    {"type": "state_set", "target": "self",
                     "field": "camera_mode", "value": "free_cam"}
                ]
            },
            {
                "id": "freecam_exit",
                "_comment": "C while in free_cam → restore saved camera_mode.",
                "trigger": {"type": "input", "action": "toggle_freecam"},
                "query": {
                    "tags_all": ["world_clock"],
                    "state": {"camera_mode_eq": "free_cam"}
                },
                "effect": [
                    {"type": "state_set", "target": "self",
                     "field": "camera_mode",
                     "value": "self.state.previous_camera_mode"}
                ]
            }
        ]
    }
    (game_dir / "world" / "rules" / "01_freecam_toggle.json").write_text(
        json.dumps(rules_doc, indent=2)
    )

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
    for name in sorted(grouped.keys()):
        if not grouped[name]:
            continue
        spec = specs.get(name, {"primitive": "prim_unit_box",
                                "canonical_scale": None, "albedo": "#808080"})
        canonical = spec["canonical_scale"]
        state_init = {"scale": [float(canonical[0]), float(canonical[1]),
                                float(canonical[2])]} if canonical else {"scale": [1, 1, 1]}
        defs_doc["definitions"].append({
            "id": name,
            "tags": [name, "compose_world_gen"],
            "properties": {},
            "state_init": state_init,
            "visual": primitive_visual(spec["primitive"], spec["albedo"]),
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

    # Prepend the world_clock + camera instances so they spawn first
    # Engine quirk (entity.gd line 124): the top-level `position` field
    # on an initial_instance OVERWRITES `state.position` after the state
    # block is applied. So the two MUST agree for free_cameras. Aldenmere's
    # convention is to set both to the same coords. We compute the camera
    # poses once and stamp both fields.
    cam_overhead_pos = [0.0, max(40.0, world_w * 0.7), 0.1]
    cam_oblique_pos  = [0.0, world_w * 0.35, world_w * 0.40]
    cam_ground_pos   = [0.0, 3.0, world_w * 0.40]

    singleton_instances = [
        {"def": "world_clock", "id": "world_clock", "position": [0, 0, 0]},
        {"def": "player_input_anchor", "id": "player_input_anchor",
         "position": [0, 0, 0]},
        # Three pre-positioned cameras — Tab cycles between them.
        # Both top-level position and state.position MUST match.
        {"def": "free_camera", "id": "camera_overhead",
         "position": cam_overhead_pos,
         "state": {"position": cam_overhead_pos,
                   "yaw": 0.0, "pitch": -1.55}},   # straight down
        # Yume's Camera3D uses Godot's YXZ-Euler convention:
        # yaw 0 = looking -Z. So a camera positioned SOUTH of origin
        # (positive Z) with yaw 0 looks NORTH toward origin. Pitch
        # negative = tilting nose down.
        {"def": "free_camera", "id": "camera_oblique",
         "position": cam_oblique_pos,
         "state": {"position": cam_oblique_pos,
                   "yaw": 0.0, "pitch": -0.72}},   # 28m up, 32m south, 41° down
        {"def": "free_camera", "id": "camera_ground",
         "position": cam_ground_pos,
         "state": {"position": cam_ground_pos,
                   "yaw": 0.0, "pitch": -0.1}},   # eye-level looking north
    ]
    level_doc = {
        "_comment": f"Auto-generated by compose_world.py for {game_name}.",
        "initial_instances": singleton_instances + initial_instances
    }
    (game_dir / "levels" / "level_default" / "entities.json").write_text(
        json.dumps(level_doc, indent=2)
    )

    # NOTE: NO levels/<name>/rules.json — aldenmere doesn't ship this
    # file either. The engine handles its absence. Per-level rules are
    # optional; the only required level-file is entities.json above.

    # ============ ui/input.json — free-cam controls ============
    # Action names must match what camera_director.gd reads via
    # Input.is_action_pressed (sprint / cam_up / cam_down — not
    # cam_sprint etc).
    (game_dir / "ui").mkdir(exist_ok=True)
    inputs = {
        "_comment": "Free-cam-only input. WASD via universal lib. C toggles, "
                    "Tab cycles cameras, Space ascends, Ctrl descends, "
                    "Shift sprints, ESC releases mouse.",
        "actions": [
            {"$include": "@lib.input.universal.actions"},
            {"name": "toggle_freecam",        "key": "C",        "edge": "press"},
            {"name": "cam_up",                "key": "Space",    "edge": "hold"},
            {"name": "cam_down",              "key": "Ctrl",     "edge": "hold"},
            {"name": "sprint",                "key": "Shift",    "edge": "hold"},
            {"name": "cycle_camera",          "key": "Tab",      "edge": "press"},
            {"name": "toggle_mouse_capture",  "key": "Escape",   "edge": "press"},
        ]
    }
    (game_dir / "ui" / "input.json").write_text(json.dumps(inputs, indent=2))

    # ============ tests.json ============
    (game_dir / "tests.json").write_text(json.dumps({"scenarios": []}, indent=2))

    # ============ per-game .tscn (3D launcher) ============
    # The universal play.tscn defaults to the 2D renderer — we need
    # entity_mesh_3d.gd. Mirror aldenmere_3d.tscn's minimal stub.
    # Convention: tscn name WITHOUT the "demo_" prefix (matches
    # aldenmere_3d.tscn ↔ data/demo_aldenmere/) so play.sh's per-game
    # scene-resolution pattern <slug>_3d.tscn finds it.
    tscn_slug = game_name.removeprefix("demo_")
    tscn_path = ROOT / "godot" / "scenes" / f"{tscn_slug}_3d.tscn"
    tscn_path.write_text(
        f"""[gd_scene load_steps=2 format=3]

; Auto-generated by compose_world.py — 3D top-down scene from extracted.json.
; All directors auto-mount via WorldBoot. Ground + lighting per scene.json.

[ext_resource type="Script" path="res://scripts/engine/core/world.gd" id="1"]

[node name="World" type="Node"]
script = ExtResource("1")
data_root = "res://data/{game_name}"
auto_start = true
verbose = true
renderer_script = "res://scripts/renderer_3d/entity_mesh_3d.gd"

[node name="Camera3D" type="Camera3D" parent="."]
position = Vector3(0, 60, 0)
rotation = Vector3(-1.5708, 0, 0)
projection = 1
size = {int(world_w)}
"""
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
    ap.add_argument("--world-x", type=float, default=80.0)
    ap.add_argument("--world-z", type=float, default=80.0)
    ap.add_argument("--height-scale", type=float, default=3.0,
                    help="max terrain displacement (m). 3.0 flat, ~8.0 hilly.")
    ap.add_argument("--height-offset", type=float, default=-0.5)
    ap.add_argument("--water-level", type=float, default=None,
                    help="water surface Y (ADR 0059). Omit to derive from "
                         "the heightmap over the water mask.")
    ap.add_argument("--rng-seed", type=int, default=42)
    args = ap.parse_args()

    game_dir = compose(
        game_name=args.game_name,
        catalog_path=Path(args.catalog),
        semantic_map_path=Path(args.semantic_map),
        heightmap_path=Path(args.heightmap) if args.heightmap else None,
        world_size_m=(args.world_x, args.world_z),
        height_scale=args.height_scale,
        height_offset=args.height_offset,
        water_level=args.water_level,
        rng_seed=args.rng_seed,
    )
    print(f"wrote demo at: {game_dir}")
    print(f"run with: ./scripts/play.sh {args.game_name.removeprefix('demo_')}")


if __name__ == "__main__":
    main()
