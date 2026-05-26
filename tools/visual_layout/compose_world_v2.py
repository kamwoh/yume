"""compose_world_v2.py — Stage 5 v2 → Stage 7 integration script.

Glues the new strategy-driven extraction (lib_extract_v2 +
extraction_strategies.json) into the existing compose_world.py
scene/level wiring without modifying it.

Flow:
  1. Read class_catalog.json (stage 2 output)
  2. Inject `strategy` blocks into every object_placement class
     from data/lib/extraction_strategies.json (yume-scene-class-
     catalog Step 4b done programmatically)
  3. Build anchor dict (focal_anchor from cobblestone plaza centroid;
     wall_ring_corners from polygon corners of wall_segment outline)
  4. Run lib_extract_v2.dispatch_extraction → flat instance list
  5. Run lib_extract_validate → print report
  6. Convert flat v2 instances → v1-shaped extracted.json (compose_world
     consumes that format)
  7. Monkey-patch compose_world.pick_primitive to honor each class's
     strategy.primitive instead of name-heuristics
  8. Call compose_world.compose() with the converted file

Output: godot/data/demo_<name>/ ready to launch.

CLI:
  python3 -m tools.visual_layout.compose_world_v2 demo_pipeline_v1 \\
    --catalog /tmp/_class_catalog.json \\
    --semantic-map .../semantic_map.png \\
    --heightmap   .../heightmap.png
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

from tools.visual_layout import lib_extract as cv
from tools.visual_layout import lib_extract_v2 as v2
from tools.visual_layout import lib_extract_validate as val
from tools.visual_layout import lib_extract_roads as roads_mod
from tools.visual_layout import compose_world


LIB_STRATEGIES = Path("godot/data/lib/extraction_strategies.json")

# Path classes extracted as the road NETWORK (non-object), not biomes.
ROAD_CLASS_NAMES = ["cobblestone", "dirt_path", "road", "stone_road", "gravel"]
PATH_WIDTH_M = 3.0
PATH_HEIGHT_M = 0.12
PATH_ALBEDO = "#9a8560"   # warm trodden-earth / cobble tone


def roads_to_instances(polylines_world, sampler) -> list[dict]:
    """Convert extracted road polylines → flat path-segment instances.

    Each segment becomes a thin box (length × PATH_HEIGHT × PATH_WIDTH)
    at the segment midpoint, yaw-aligned along the segment, Y-anchored
    just above the displaced ground. Reuses the entity render path —
    no new engine code. The non_objects road graph is also kept in
    extracted.json for the record / future NPC pathing.
    """
    out: list[dict] = []
    n = 0
    for poly in polylines_world:
        for i in range(len(poly) - 1):
            ax, az = poly[i]
            bx, bz = poly[i + 1]
            dx, dz = bx - ax, bz - az
            length = math.hypot(dx, dz)
            if length < 0.5:
                continue
            mx, mz = (ax + bx) * 0.5, (az + bz) * 0.5
            wy = sampler.y_at(mx, mz) if sampler is not None else 0.0
            # Align local +X with the segment (same convention as walls):
            # yaw = atan2(-dz, dx).
            yaw = math.atan2(-dz, dx)
            n += 1
            out.append({
                "class": "path_segment",
                "id": f"path_segment_{n:03d}",
                "position": [round(mx, 3), wy, round(mz, 3)],
                "yaw": round(yaw, 4),
                # +0.4 length overlap closes seams at segment joins.
                "scale": [round(length + 0.4, 3), PATH_HEIGHT_M, PATH_WIDTH_M],
                "primitive": "prim_unit_box",
                "canonical_front_axis": "+X",
                "_y_offset": 0.07,   # sit just above the ground plane
            })
    return out


# ============================================================
# STEP 2 — strategy injection (mirrors yume-scene-class-catalog Step 4b)
# ============================================================

def inject_strategies(catalog: dict, lib: dict) -> None:
    """Mutates catalog: every object_placement class gets a `strategy`
    block via exact name → alias → default_with_override resolution."""
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


# ============================================================
# STEP 3 — anchor detection (focal_anchor + wall_ring_corners)
# ============================================================

def detect_anchors(
    catalog: dict,
    semantic_map_path: Path,
    world_size_m: tuple[float, float],
) -> dict:
    """Build the `anchors` dict consumed by face_anchor +
    snap_to_anchor strategies.

      focal_anchor: centroid of the cobblestone/plaza biome (largest
                    connected component). Falls back to (0, 0) if
                    no plaza class exists.
      wall_ring_corners: corner vertices of the wall_segment outline
                    after R-D-P simplification. List of (wx, wz)
                    tuples. Empty if no wall_segment class.
    """
    img = cv.load_rgb(semantic_map_path)
    H, W = img.shape[:2]
    image_size = (W, H)
    palette = [(c["name"], c["hex"]) for c in catalog["classes"]
               if c.get("intent_type") in ("terrain_shader", "object_placement")]
    label_map = cv.threshold_nearest_palette(img, palette)

    anchors: dict = {"focal_anchor": (0.0, 0.0), "wall_ring_corners": []}

    # Focal anchor: centroid of plaza/cobblestone mass
    for plaza_name in ("plaza", "cobblestone", "stone_floor", "dirt_path"):
        idx = next((i for i, (n, _h) in enumerate(palette) if n == plaza_name),
                   None)
        if idx is None:
            continue
        mask = label_map == idx
        comps = cv.connected_components(mask, min_area=50)
        if not comps:
            continue
        # Use the LARGEST component's centroid
        comp = max(comps, key=lambda c: c["area_px"])
        cx_px, cy_px = comp["centroid"]
        wx, wz = cv.pixel_to_world(cx_px, cy_px, image_size, world_size_m)
        anchors["focal_anchor"] = (wx, wz)
        break

    # Wall-ring corners: polygon vertices of the wall_segment biome.
    wall_idx = next((i for i, (n, _h) in enumerate(palette)
                     if n == "wall_segment"), None)
    if wall_idx is not None:
        wall_mask = label_map == wall_idx
        # Merge ALL wall components into one outline by unioning their pixels
        comps = cv.connected_components(wall_mask, min_area=20)
        if comps:
            # Concatenate all wall pixels into a synthetic single-component
            # so the outline tracer treats them as one ring.
            all_pixels = np.concatenate([c["pixels"] for c in comps], axis=0)
            big = {"pixels": all_pixels}
            outline = v2._trace_outline(wall_mask, big)
            if len(outline) >= 3:
                # 1m simplification — coarse enough to give one corner per
                # octagon vertex without splitting them.
                tol_px = 1.0 * (0.5 * (W / world_size_m[0] + H / world_size_m[1]))
                simplified = v2._rdp(outline, tol_px)
                corners = []
                for cx_px, cy_px in simplified:
                    wx, wz = cv.pixel_to_world(
                        cx_px, cy_px, image_size, world_size_m
                    )
                    corners.append((wx, wz))
                anchors["wall_ring_corners"] = corners
    return anchors


# ============================================================
# STEP 6 — convert v2 flat list → v1 class-grouped extracted shape
# ============================================================

def v2_to_v1_extracted(
    *,
    catalog: dict,
    instances: list[dict],
    semantic_map_path: Path,
    heightmap_path: Path | None,
    world_size_m: tuple[float, float],
    image_size: tuple[int, int],
) -> dict:
    """Group v2 instances by class, emit v1-shaped extracted.json.

    compose_world.compose() reads:
      extracted["world_size_meters"]
      extracted["classes"][i] = {name, hex, intent_type,
                                 instances: [{id, position_world (2D),
                                              size_world (2D),
                                              rotation_deg}]}
    """
    by_class: dict[str, list[dict]] = {}
    for inst in instances:
        cn = inst["class"]
        # v2 stores position [x, y, z]; scale present only when the
        # strategy emits per-instance size (else use_canonical_scale).
        wx, _wy, wz = inst["position"]
        has_scale = "scale" in inst
        v1_inst = {
            "id": inst["id"],
            "position_world": [round(wx, 3), round(wz, 3)],
            "rotation_deg": round(math.degrees(inst["yaw"]), 2),
            "_v2_primitive": inst["primitive"],
            "_v2_canonical_front_axis": inst.get("canonical_front_axis", "-Z"),
            "_v2_use_canonical_scale": inst.get("_use_canonical_scale", False),
        }
        if has_scale:
            sx, sh, sz = inst["scale"]
            v1_inst["size_world"] = [round(sx, 3), round(sz, 3)]
            v1_inst["_v2_scale_y"] = float(sh)
        if "_y_offset" in inst:
            v1_inst["_v2_y_offset"] = float(inst["_y_offset"])
        by_class.setdefault(cn, []).append(v1_inst)

    out_classes = []
    for c in catalog["classes"]:
        strategy = c.get("strategy", {})
        buckets = strategy.get("variant_buckets")
        if c["intent_type"] == "object_placement" and buckets:
            # Split the parent class into one v1-shaped entry PER bucket.
            # Each becomes its own entity def in compose_world.
            for b in buckets:
                bname = b["def"]
                bcanonical = b.get(
                    "canonical_size_meters",
                    strategy.get("canonical_size_meters", [1.0, 1.0, 1.0]),
                )
                bhex = b.get("albedo", c["hex"])
                out_classes.append({
                    "name": bname,
                    "hex": bhex,
                    "intent_type": "object_placement",
                    "instances": by_class.get(bname, []),
                    "_canonical_scale": list(bcanonical),
                    "_parent_class": c["name"],
                })
        else:
            entry = {
                "name": c["name"],
                "hex": c["hex"],
                "intent_type": c["intent_type"],
            }
            if c["intent_type"] == "object_placement":
                entry["instances"] = by_class.get(c["name"], [])
                if strategy.get("use_canonical_scale", False):
                    entry["_canonical_scale"] = strategy.get(
                        "canonical_size_meters", [1.0, 1.0, 1.0]
                    )
            out_classes.append(entry)

    # Synthetic class for extracted road segments (non-object → flat
    # path-segment entities). Not in the catalog; per-instance scale.
    if by_class.get("path_segment"):
        out_classes.append({
            "name": "path_segment",
            "hex": PATH_ALBEDO,
            "intent_type": "object_placement",
            "instances": by_class["path_segment"],
            "_synthetic_non_object": True,
        })

    return {
        "source_semantic_map": str(semantic_map_path),
        "source_heightmap": str(heightmap_path) if heightmap_path else None,
        "image_size": list(image_size),
        "world_size_meters": list(world_size_m),
        "classes": out_classes,
    }


# ============================================================
# STEP 7 — monkey-patch pick_primitive
# ============================================================

def install_v2_pick_primitive(catalog: dict) -> None:
    """Override compose_world.pick_primitive so it reads the strategy's
    primitive choice + canonical_size_meters instead of guessing from
    the class name.

    For each class, the strategy specifies prim_unit_box / cylinder /
    sphere + a canonical [W, H, D]. The per-instance scale handles
    sizing.
    """
    class_to_strategy = {
        c["name"]: c.get("strategy", {}) for c in catalog["classes"]
        if c.get("intent_type") == "object_placement"
    }

    def pick_primitive_v2(class_name: str, size_world):
        s = class_to_strategy.get(class_name, {})
        prim = s.get("primitive", "prim_unit_box")
        canonical = s.get("canonical_size_meters", [1.0, 1.0, 1.0])
        H = float(canonical[1])
        if prim == "prim_unit_cylinder":
            return {"_primitive": "cylinder",
                    "radius": float(canonical[0]) / 2.0,
                    "height": H}
        if prim == "prim_unit_sphere":
            return {"_primitive": "sphere",
                    "radius": float(canonical[0]) / 2.0}
        return {"_primitive": "box",
                "size": [float(size_world[0]), H, float(size_world[1])]}

    compose_world.pick_primitive = pick_primitive_v2


# ============================================================
# MAIN
# ============================================================

def main() -> None:
    ap = argparse.ArgumentParser(prog="compose_world_v2")
    ap.add_argument("game_name", help="folder name (under godot/data/<name>)")
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--semantic-map", required=True)
    ap.add_argument("--heightmap", default=None)
    ap.add_argument("--world-x", type=float, default=80.0)
    ap.add_argument("--world-z", type=float, default=80.0)
    ap.add_argument("--height-scale", type=float, default=3.0,
                    help="max terrain displacement in meters (3.0 flat, "
                         "~8.0 hilly). Used by both the ground shader and "
                         "the entity Y sampler.")
    ap.add_argument("--height-offset", type=float, default=-0.5,
                    help="signed offset before scaling; -0.5 = grey128 is "
                         "ground level")
    ap.add_argument("--water-level", type=float, default=None,
                    help="world Y of the water surface (ADR 0059). Omit to "
                         "DERIVE it from the heightmap over the water mask "
                         "(85th pct — fills the river channel, town stays "
                         "dry). Pass a value to override.")
    ap.add_argument("--rng-seed", type=int, default=42)
    ap.add_argument("--validation-report", default=None,
                    help="optional path to write the validator's JSON report")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 if the validator's verdict != pass")
    args = ap.parse_args()

    catalog_path = Path(args.catalog)
    semantic_map_path = Path(args.semantic_map)
    heightmap_path = Path(args.heightmap) if args.heightmap else None
    world_size_m = (args.world_x, args.world_z)

    # 1. Read catalog
    catalog = json.loads(catalog_path.read_text())

    # 2. Inject strategies from lib
    lib = json.loads(Path(LIB_STRATEGIES).read_text())
    inject_strategies(catalog, lib)

    # 3. Detect anchors (focal_anchor + wall_ring_corners)
    anchors = detect_anchors(catalog, semantic_map_path, world_size_m)
    print(f"[compose_world_v2] anchors: focal_anchor={anchors['focal_anchor']} "
          f"wall_ring_corners={len(anchors['wall_ring_corners'])}")

    # 4. Run v2 dispatch
    instances = v2.dispatch_extraction(
        catalog=catalog,
        semantic_map_path=semantic_map_path,
        heightmap_path=heightmap_path,
        world_size_m=world_size_m,
        height_scale=args.height_scale,
        height_offset=args.height_offset,
        anchors=anchors,
        rng_seed=args.rng_seed,
    )
    print(f"[compose_world_v2] extracted {len(instances)} object instances")

    # 4b. Extract the road NETWORK (non-object) and emit flat path
    # segments. Roads are skeletonized from the path classes, traced to
    # polylines, and rendered as thin ground-following boxes. The path
    # classes are dropped from the ground biomes (compose_world
    # ROAD_CLASSES) so the terrain under a road is its surrounding biome.
    img = cv.load_rgb(semantic_map_path)
    H, W = img.shape[:2]
    image_size = (W, H)
    palette_all = [(c["name"], c["hex"]) for c in catalog["classes"]
                   if c.get("intent_type") in ("terrain_shader", "object_placement")]
    label_all = cv.threshold_nearest_palette(img, palette_all)
    road_sampler = None
    if heightmap_path is not None:
        road_sampler = v2.HeightmapSampler(
            heightmap_path, plane_size_m=float(world_size_m[0]),
            height_scale=args.height_scale, height_offset=args.height_offset,
        )
    road_result = roads_mod.extract_roads(
        label_map=label_all, palette=palette_all,
        path_class_names=ROAD_CLASS_NAMES,
        image_size=image_size, world_size_m=world_size_m,
        simplify_tolerance_meters=0.8, min_world_length_m=4.0,
    )
    road_instances = roads_to_instances(road_result["polylines_world"], road_sampler)
    print(f"[compose_world_v2] roads: {road_result['n_polylines']} polylines "
          f"→ {len(road_instances)} path segments")
    instances.extend(road_instances)

    # 5. Validate (objects only — path segments aren't in the catalog)
    extracted_for_val = {
        "instances": instances,
        "world_size_meters": list(world_size_m),
    }
    report = val.validate(extracted=extracted_for_val, catalog=catalog)
    print(val.format_report(report))
    if args.validation_report:
        Path(args.validation_report).write_text(json.dumps(report, indent=2))
    if args.strict and report["verdict"] != "pass":
        print("[compose_world_v2] STRICT mode + verdict != pass → exit 1")
        sys.exit(1)

    # 6. Convert to compose_world's expected shape
    v1_extracted = v2_to_v1_extracted(
        catalog=catalog,
        instances=instances,
        semantic_map_path=semantic_map_path,
        heightmap_path=heightmap_path,
        world_size_m=world_size_m,
        image_size=image_size,
    )
    tmp_path = Path("/tmp/_extracted_v2.json")
    tmp_path.write_text(json.dumps(v1_extracted, indent=2))

    # 7. Install primitive override
    install_v2_pick_primitive(catalog)

    # Write the strategized catalog to /tmp too (for diagnosis)
    Path("/tmp/_class_catalog_strategized.json").write_text(
        json.dumps(catalog, indent=2)
    )

    # 8. Call compose_world.compose()
    game_dir = compose_world.compose(
        game_name=args.game_name,
        extracted_path=tmp_path,
        catalog_path=Path("/tmp/_class_catalog_strategized.json"),
        semantic_map_path=semantic_map_path,
        heightmap_path=heightmap_path,
        height_scale=args.height_scale,
        height_offset=args.height_offset,
        water_level=args.water_level,
    )
    print(f"[compose_world_v2] wrote demo at: {game_dir}")
    print(f"[compose_world_v2] run with: "
          f"./scripts/play.sh {args.game_name.removeprefix('demo_')}")


if __name__ == "__main__":
    main()
