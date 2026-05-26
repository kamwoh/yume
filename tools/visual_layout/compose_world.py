"""compose_world.py — stage 7 of the text-to-world pipeline.

Reads the stage-5 extracted.json + stage-2 catalog and writes a
runnable Yume demo using ONLY CODE-DRAWN PRIMITIVE SHAPES (boxes,
cylinders, spheres). No asset gen — every object's visual is a
primitive sized per its extracted bbox + colored per its catalog
hex.

This is a DEFERRED-asset version of stage 7. The point: prove the
pipeline produces a coherent scene structurally BEFORE investing
in stage-6 asset generation. If the box-only scene reads as
"yes that's a medieval town from above", we know the pipeline
works; if not, we know where the issue is.

Usage:
    python3 -m tools.visual_layout.compose_world demo_pipeline_v1 \\
        --extracted /tmp/_extracted.json \\
        --catalog   /tmp/_class_catalog.json \\
        --semantic-map /path/to/semantic.png \\
        --heightmap    /path/to/heightmap.png   (optional)
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA_ROOT = ROOT / "godot" / "data"


# ============================================================
# CLASS → PRIMITIVE SHAPE HEURISTICS
# ============================================================

def pick_primitive(class_name: str, size_world: list[float]) -> dict:
    """Map a catalog class name to a primitive shape spec.

    Default = box at extracted size. Common class-name patterns
    pick more specific primitives (cylinder for tower, sphere for
    fountain orb, etc.). Color comes from the catalog hex applied
    by the caller.
    """
    name = class_name.lower()
    w_avg = (size_world[0] + size_world[1]) / 2.0
    h = max(1.5, w_avg * 1.5)  # default height = 1.5x footprint for
                                # a building-shaped silhouette

    # Cylinders for round-ish things
    if any(k in name for k in ("tower", "well", "silo", "spire", "pillar")):
        radius = w_avg / 2.0
        return {"_primitive": "cylinder", "radius": radius, "height": h}

    # Spheres for orb-ish things
    if any(k in name for k in ("orb", "egg", "fountain", "boulder", "ball")):
        # Fountain = a small dome (sphere of half-extents)
        return {"_primitive": "sphere", "radius": w_avg / 2.0}

    # Trees as cone-topped cylinder (composite). Simpler: just a
    # tall thin cylinder.
    if any(k in name for k in ("tree", "trunk", "pine", "oak")):
        return {"_primitive": "cylinder", "radius": w_avg * 0.4, "height": h * 1.5}

    # Walls as thin tall boxes (sized per extracted bbox).
    if any(k in name for k in ("wall", "fence", "barricade")):
        # Keep the extracted footprint but make it tall.
        return {"_primitive": "box",
                "size": [size_world[0], 3.0, size_world[1]]}

    # Bridges, paths-as-objects: flat thin slab
    if any(k in name for k in ("bridge", "platform", "slab")):
        return {"_primitive": "box",
                "size": [size_world[0], 0.4, size_world[1]]}

    # Default: building-shaped box (tall over footprint)
    return {"_primitive": "box", "size": [size_world[0], h, size_world[1]]}


def primitive_to_visual(prim: dict, hex_color: str) -> dict:
    """Convert a primitive spec to a Yume visual block.

    Uses data/meshes.json's prim_unit_box / prim_unit_cylinder /
    prim_unit_sphere as the underlying library meshes. The primitive
    is unit-sized (1x1x1 or radius 0.5); per-instance scale on the
    entity instance gives the actual dimensions. The mesh's $albedo
    parameter is recolored via visual.params.
    """
    p_type = prim["_primitive"]
    if p_type == "box":
        return {
            "mesh": "prim_unit_box",
            "params": {"albedo": hex_color},
        }
    if p_type == "cylinder":
        return {
            "mesh": "prim_unit_cylinder",
            "params": {"albedo": hex_color},
        }
    if p_type == "sphere":
        return {
            "mesh": "prim_unit_sphere",
            "params": {"albedo": hex_color},
        }
    return {"mesh": "prim_unit_box", "params": {"albedo": hex_color}}


# ============================================================
# Y-HEIGHT inference per primitive
# ============================================================

def y_offset_for(prim: dict) -> float:
    """Where the primitive's center sits in y so the BASE is at y=0.
    Match the engine's auto-lift convention (physics_body_builder)
    so visual + collider align."""
    if prim["_primitive"] == "box":
        return prim["size"][1] / 2.0
    if prim["_primitive"] == "cylinder":
        return prim["height"] / 2.0
    if prim["_primitive"] == "sphere":
        return prim["radius"]
    return 0.5


# ============================================================
# GENERATE YUME DEMO FILES
# ============================================================

def compose(
    game_name: str,
    extracted_path: Path,
    catalog_path: Path,
    semantic_map_path: Path | None,
    heightmap_path: Path | None,
) -> Path:
    """Build a full data/demo_<name>/ folder. Returns the folder path."""
    extracted = json.loads(extracted_path.read_text())
    catalog = json.loads(catalog_path.read_text())

    game_dir = DATA_ROOT / game_name
    if game_dir.exists():
        shutil.rmtree(game_dir)
    game_dir.mkdir(parents=True)

    # Subdirs
    (game_dir / "entities").mkdir()
    (game_dir / "world").mkdir()
    (game_dir / "levels" / "level_default").mkdir(parents=True)
    (game_dir / "game").mkdir()
    (game_dir / "assets" / "layouts").mkdir(parents=True)
    (game_dir / "assets" / "textures").mkdir(parents=True)

    # Copy semantic map + heightmap into the game's assets dir
    semantic_dest = None
    heightmap_dest = None
    if semantic_map_path and semantic_map_path.exists():
        semantic_dest = game_dir / "assets" / "layouts" / "semantic_map.png"
        shutil.copy(semantic_map_path, semantic_dest)
    if heightmap_path and heightmap_path.exists():
        heightmap_dest = game_dir / "assets" / "textures" / "heightmap.png"
        shutil.copy(heightmap_path, heightmap_dest)

    # ============ scene.json ============
    world_w, world_h = extracted["world_size_meters"]
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
    # Wire heightmap + semantic map through the lib's simple-displace
    # ground shader (data/lib/shaders/ground_simple_displace.gdshader).
    # That shader does vertex displacement from heightmap + samples
    # semantic_map as albedo. Reusable across any auto-gen game.
    if semantic_dest or heightmap_dest:
        scene["ground"]["mesh"]["shader"] = (
            "res://data/lib/shaders/ground_simple_displace.gdshader"
        )
        scene["ground"]["mesh"]["plane_size"] = float(world_w)
        scene["ground"]["mesh"]["height_scale"] = 3.0   # max displacement (m)
        scene["ground"]["mesh"]["height_offset"] = -0.5  # 128 = ground, brighter=up
        shader_params: dict = {}
        if semantic_dest:
            shader_params["biome_map"] = (
                f"res://data/{game_name}/assets/layouts/semantic_map.png"
            )
        if heightmap_dest:
            shader_params["heightmap"] = (
                f"res://data/{game_name}/assets/textures/heightmap.png"
            )
        scene["ground"]["mesh"]["shader_params"] = shader_params
    (game_dir / "scene.json").write_text(json.dumps(scene, indent=2))

    # ============ world/state.json ============
    # Per data-demo.md convention: world/state.json is for env-level
    # global non-entity state (usually empty — env.world_state).
    # Singleton entities (world_clock) + free_camera defs go in
    # entities/ as proper entity definition files.
    (game_dir / "world" / "state.json").write_text(json.dumps({
        "_comment": "Empty placeholder. Singletons (world_clock, free_camera) live in entities/."
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

    # ============ entities/<class>.json — one def per class ============
    # ALL object_placement classes get a def using primitive shapes.
    object_classes = [
        c for c in catalog["classes"]
        if c["intent_type"] == "object_placement"
    ]

    # Reference primitive per class — use median size across the
    # class's instances for the SHAPE; per-instance scale handled
    # via state.scale.
    extracted_by_name = {c["name"]: c for c in extracted["classes"]}

    defs_doc = {"_comment": f"Auto-gen primitives for {game_name}.", "definitions": []}
    for cls in object_classes:
        name = cls["name"]
        ext_cls = extracted_by_name.get(name, {})
        instances = ext_cls.get("instances", [])
        if not instances:
            continue
        # Median size_world across all instances of this class
        sizes = [i["size_world"] for i in instances]
        sizes.sort(key=lambda s: s[0] * s[1])
        med = sizes[len(sizes) // 2]
        primitive = pick_primitive(name, med)
        visual = primitive_to_visual(primitive, cls["hex"])
        defs_doc["definitions"].append({
            "id": name,
            "tags": [name, "compose_world_gen"],
            "properties": {},
            "state_init": {"scale": [1, 1, 1]},
            "visual": visual,
            "_primitive_spec": primitive,
            "_color": cls["hex"],
        })
    (game_dir / "entities" / "auto_gen.json").write_text(
        json.dumps(defs_doc, indent=2)
    )

    # ============ levels/level_default/entities.json ============
    initial_instances = []
    for ext_cls in extracted["classes"]:
        if ext_cls["intent_type"] != "object_placement":
            continue
        name = ext_cls["name"]
        defs_match = next((d for d in defs_doc["definitions"]
                           if d["id"] == name), None)
        if defs_match is None:
            continue
        prim_spec = defs_match["_primitive_spec"]
        prim_type = prim_spec["_primitive"]
        # Reference height for the chosen primitive shape
        # (median across class instances was used in pick_primitive)
        if prim_type == "box":
            ref_y = prim_spec["size"][1]   # used for instance y_off + scale_y
        else:
            ref_y = prim_spec.get("height", prim_spec.get("radius", 0.5) * 2)
        for inst in ext_cls.get("instances", []):
            wx, wz = inst["position_world"]
            ext_size = inst["size_world"]   # [width_m, depth_m]
            # state.scale = [width, height, depth] in METERS because each
            # mesh primitive is unit-sized. The primitive's base sits at
            # y=0; with scale_y=H, the box / cylinder / sphere stands H
            # meters tall, base on the ground.
            scale_x = max(0.2, ext_size[0])
            scale_z = max(0.2, ext_size[1])
            scale_y = max(0.5, ref_y)   # use the class's chosen height
            # Position the entity AT THE GROUND. The primitive's pivot
            # is at y=0.5 (top of unit box) BUT the renderer applies
            # mesh translation in its own frame; entity position +
            # state.scale = base on ground when the primitive pos = 0.5
            # and entity y = 0.
            pos = [wx, 0.0, wz]
            facing = math.radians(inst.get("rotation_deg", 0.0))
            initial_instances.append({
                "def": name,
                "id": inst["id"],
                "position": pos,
                "state": {
                    "scale": [scale_x, scale_y, scale_z],
                    "facing": round(facing, 4),
                }
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
        "_comment": f"Auto-generated initial_instances from {extracted_path.name}",
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
    ap.add_argument("game_name", help="folder name (will go under godot/data/<name>)")
    ap.add_argument("--extracted", required=True, help="stage-5 extracted.json")
    ap.add_argument("--catalog",   required=True, help="stage-2 class_catalog.json")
    ap.add_argument("--semantic-map", default=None, help="optional stage-3 semantic map PNG")
    ap.add_argument("--heightmap",    default=None, help="optional stage-4 heightmap PNG")
    args = ap.parse_args()

    game_dir = compose(
        game_name=args.game_name,
        extracted_path=Path(args.extracted),
        catalog_path=Path(args.catalog),
        semantic_map_path=Path(args.semantic_map) if args.semantic_map else None,
        heightmap_path=Path(args.heightmap) if args.heightmap else None,
    )
    print(f"wrote demo at: {game_dir}")
    print(f"run with: ./scripts/play.sh {args.game_name.removeprefix('demo_')}")


if __name__ == "__main__":
    main()
