"""compose_shell.py — the PLAYABLE WRAPPER for a generated map.

compose_world.py produces the MAP (content): entity defs, object
placements, terrain assets, scene.json's ground+water. It says nothing
about how you VIEW or CONTROL the world.

compose_shell.py adds that "shell" on top of an existing map dir:
  - scene.json camera + lighting (merged into the map's scene.json)
  - a player entity + the camera anchors (world_clock, free cameras)
  - camera/movement rules (free-cam toggle + WASD)
  - input map + a per-game .tscn launcher
  - the world_clock / player / camera singleton instances spliced into
    the level's entities.json

The shell is GAME-TYPE specific — a third-person explorer, a top-down
strategy view, and an FPS want different camera + player + input. This
file ships one preset today (`third_person_explorer`); add more as
dict-returning builders. Swap the shell, keep the same map.

Run AFTER compose_world:
    python3 -m tools.visual_layout.compose_world demo_x --catalog ...
    python3 -m tools.visual_layout.compose_shell demo_x
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA_ROOT = ROOT / "godot" / "data"
sys.path.insert(0, str(ROOT))
from tools.visual_layout import scene_config as scfg  # noqa: E402


# ============================================================
# SHELL PRESET: third_person_explorer
# ============================================================

def _camera_block() -> dict:
    return {
        # Third-person, follows the player. Press C to toggle free-cam.
        "$extends": "@lib.cameras.third_person_default",
        "follow_tag": "player",
        "distance": 8.0,
        "distance_min": 3.0,
        "distance_max": 18.0,
        "height": 3.0,
        "fov": 60.0,
        "lerp": 1.0,   # instant follow — snap to target each frame, no delay
    }


def _lighting_block() -> dict:
    return {
        # Sun is DAY/NIGHT-cycle driven (LightingDirector), bound to
        # world_clock.current_hour (pinned to 15h → low angled sun =
        # long readable shadows; noon would be flat overhead).
        "directional_light": {
            "enabled": True,
            "shadow_enabled": True,
            "binds_to": "world_clock.current_hour",
            "color_at_noon": "#fff2d8",
            "color_at_dawn_dusk": "#ffb070",
            "color_at_night": "#2a3260",
            "energy_noon": 1.15,
            "energy_horizon": 0.85,
            "energy_night": 0.05,
        },
        "ambient": {"color": "#aebccf", "energy": 0.35},
        "sky": {
            "shader": "res://data/lib/shaders/sky_clouds.gdshader",
            "shader_params": {
                "sky_top_color": [0.22, 0.45, 0.82],
                "sky_horizon_color": [0.80, 0.87, 0.93],
                "cloud_color": [0.99, 0.98, 0.96],
                "cloud_coverage": 0.48,
                "cloud_softness": 0.58,
                "cloud_speed": 0.008,
                "cloud_scale": 5.0,
            },
        },
        # Atmospheric depth — the dreamy distance fade. Higher density +
        # aerial_perspective make far hills/totems recede into haze, which
        # is most of the "cinematic / painterly" feel. Warm-neutral fog so
        # the warm sun reads through it.
        "fog": {
            "enabled": True,
            "light_color": "#d6dce0",
            "light_energy": 1.0,
            "density": 0.0075,
            "sun_scatter": 0.35,
            "aerial_perspective": 0.8,
        },
        # Painterly pop — pushed saturation + contrast so the stylized
        # palette reads vivid (Journey / Kena / Tiny-Glade direction).
        "adjustments": {
            "enabled": True,
            "contrast": 1.18,
            "saturation": 1.34,
            "brightness": 1.0,
        },
    }


def _player_def() -> dict:
    # Walkable third-person player. Vector2 velocity [x,y]→world(x,0,y)
    # per data-demo.md; drag=0 for snappy feel; mesh_yaw_offset π/2
    # because Tripo character meshes face +Z. NOTE: borrows aldenmere's
    # player .glb as a stand-in avatar (per-game player mesh is future
    # work) — a cross-demo asset reference, fine for the shell layer.
    return {
        "_comment": "Walkable player. Third-person camera follows tag 'player'.",
        "definitions": [
            {
                "id": "player_input_anchor",
                "tags": ["player", "actor", "persistent"],
                "properties": {
                    "display_name": "Player",
                    "speed_base": 7.0,
                    "mesh_yaw_offset": 1.5708,
                },
                "state_init": {
                    "velocity": [0, 0],
                    "drag": 0.0,
                    "max_speed": 7.0,
                    "speed_multiplier": 1.0,
                    "facing": 0.0,
                    "pitch": 0.0,
                    "y_velocity": 0.0,
                    "on_floor": 1,
                    "gravity": 18.0,
                    "camera_distance": 8.0,
                    "scale": 1.7,
                },
                "physics": {"$extends": "@lib.physics.bodies.standard_character_player"},
                "visual": {
                    "mesh": "res://data/demo_aldenmere/assets/meshes/player_marken_animated_cc1c2175.glb"
                }
            }
        ]
    }


def _world_clock_def() -> dict:
    return {
        "_comment": "Shell singleton. Starts third_person_3d (camera follows player). C → free_cam.",
        "definitions": [
            {
                "id": "world_clock",
                "tags": ["world_clock", "persistent"],
                "properties": {},
                "state_init": {
                    "camera_mode": "third_person_3d",
                    "previous_camera_mode": "third_person_3d",
                    "active_camera_id": "camera_oblique",
                    "current_level": "level_default",
                    "current_hour": 15.0,
                },
                "visual": {"hidden": True}
            }
        ]
    }


def _cameras_def() -> dict:
    return {
        "_comment": "Free-cam anchors. Logical entities — hidden. Tab cycles in free_cam.",
        "definitions": [
            {
                "id": "free_camera",
                "tags": ["free_camera", "persistent", "decorative"],
                "properties": {"display_name": "Camera"},
                "state_init": {
                    "position": [0, 30, 30],
                    "yaw": 0.0,
                    "pitch": -0.6,
                    "fov": 60.0
                },
                "visual": {"hidden": True}
            }
        ]
    }


def _camera_rules() -> dict:
    # One ENTER rule per source camera_mode, each saving a LITERAL
    # previous_camera_mode. Critical: do NOT use a formula
    # `value: "self.state.camera_mode"` in the same effect list that
    # also writes camera_mode=free_cam — effect-resolution order can
    # evaluate the formula AFTER the camera_mode write, saving
    # "free_cam" as previous → exit restores free_cam and you're stuck.
    # (Empirical 2026-05-27. Aldenmere's working pattern = literals.)
    enter_modes = ["third_person_3d", "first_person_3d",
                   "isometric_3d", "top_down_3d"]
    rules = []
    for mode in enter_modes:
        rules.append({
            "id": f"freecam_enter_from_{mode}",
            "trigger": {"type": "input", "action": "toggle_freecam"},
            "query": {"tags_all": ["world_clock"],
                      "state": {"camera_mode_eq": mode}},
            "effect": [
                {"type": "state_set", "target": "self",
                 "field": "previous_camera_mode", "value": mode},
                {"type": "state_set", "target": "self",
                 "field": "camera_mode", "value": "free_cam"},
                # Zero the player velocity on entry — the WASD rules'
                # camera_mode filter excludes free_cam so they stop
                # firing, but last frame's velocity would persist and
                # drift the player while the camera flies.
                {"type": "velocity_set", "target": "actor", "x": 0, "y": 0},
            ]
        })
    rules.append({
        "id": "freecam_exit",
        "_comment": "C while in free_cam → restore saved camera_mode "
                    "(formula reads the literal saved earlier).",
        "trigger": {"type": "input", "action": "toggle_freecam"},
        "query": {"tags_all": ["world_clock"],
                  "state": {"camera_mode_eq": "free_cam"}},
        "effect": [
            {"type": "state_set", "target": "self",
             "field": "camera_mode",
             "value": "self.state.previous_camera_mode"}
        ]
    })
    return {"_comment": "Shell camera control. C toggles free_cam ↔ "
                        "previous mode.", "rules": rules}


def _movement_rules() -> dict:
    return {
        "_comment": "Player movement. Camera-relative WASD via @lib bundle "
                    "(fp variant fires for third_person_3d) + face_motion.",
        "rules": [
            {"$include": "@lib.input_bundles.wasd_with_fp_variant.rules"},
            {"$include": "@lib.motion.face_motion.rules"},
        ]
    }


def _input_map() -> dict:
    return {
        "_comment": "WASD via universal lib. C toggles free-cam, Tab cycles "
                    "cameras, Space/Ctrl ascend/descend (free-cam), Shift "
                    "sprints, ESC releases mouse.",
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


def _singleton_instances(world_w: float, spawn: list | None = None,
                         spawn_clear_y: float = 12.0) -> list[dict]:
    # Camera anchors: positions scale with the world. Top-level position
    # MUST equal state.position for free_cameras (entity.gd clobber).
    cam_overhead = [0.0, max(40.0, world_w * 0.7), 0.1]
    cam_oblique  = [0.0, world_w * 0.35, world_w * 0.40]
    cam_ground   = [0.0, 3.0, world_w * 0.40]
    # Player spawn (config player.spawn, else default). A null/missing Y
    # uses spawn_clear_y — computed by the caller to sit just above the
    # displaced terrain so gravity drops the player cleanly onto the
    # HeightMapShape3D collider (spawning below the surface embeds it in a
    # hill; spawning far above causes a long visible drop).
    sx, sy, sz = (spawn or [0.0, None, 10.0])
    if sy is None:
        sy = spawn_clear_y
    player_pos = [float(sx), float(sy), float(sz)]
    return [
        {"def": "world_clock", "id": "world_clock", "position": [0, 0, 0]},
        {"def": "player_input_anchor", "id": "player_input_anchor",
         "position": player_pos,
         "state": {"position": player_pos, "facing": 0.0}},
        {"def": "free_camera", "id": "camera_overhead",
         "position": cam_overhead,
         "state": {"position": cam_overhead, "yaw": 0.0, "pitch": -1.55}},
        {"def": "free_camera", "id": "camera_oblique",
         "position": cam_oblique,
         "state": {"position": cam_oblique, "yaw": 0.0, "pitch": -0.72}},
        {"def": "free_camera", "id": "camera_ground",
         "position": cam_ground,
         "state": {"position": cam_ground, "yaw": 0.0, "pitch": -0.1}},
    ]


def _tscn(game_name: str, world_w: float) -> str:
    return f"""[gd_scene load_steps=2 format=3]

; Auto-generated by compose_shell.py — 3D scene launcher.
; All directors auto-mount via WorldBoot. Ground+lighting per scene.json.

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


# ============================================================
# COMPOSE SHELL
# ============================================================

def compose_shell(game_name: str, shell_type: str = "third_person_explorer",
                  level_id: str = "level_default") -> Path:
    """Add the playable wrapper to an existing map dir (compose_world
    output). Returns the game dir."""
    if shell_type != "third_person_explorer":
        raise ValueError(f"unknown shell_type: {shell_type} "
                         f"(only 'third_person_explorer' today)")
    game_dir = (DATA_ROOT / game_name).resolve()
    scene_path = game_dir / "scene.json"
    if not scene_path.exists():
        raise FileNotFoundError(
            f"{scene_path} not found — run compose_world (map) first")

    cfg = scfg.load_scene_config(game_dir)

    # 1. Merge camera + lighting into the map's scene.json. The scene's
    # lighting is the built-in cinematic default deep-merged with any
    # scene_config.json "lighting" override (per-scene mood).
    scene = json.loads(scene_path.read_text())
    world_w = float(scene.get("ground", {}).get("mesh", {})
                    .get("size", [80.0])[0])
    scene["camera"] = _camera_block()
    scene["lighting"] = scfg.deep_merge(_lighting_block(), cfg.get("lighting", {}))
    scene_path.write_text(json.dumps(scene, indent=2))

    # Player spawn clearance: just above the max terrain displacement so
    # gravity drops it onto the HeightMapShape3D collider. Max displaced Y =
    # (1 + height_offset) * height_scale (read from the ground shader the
    # map layer wrote). +2m margin.
    sp = scene.get("ground", {}).get("mesh", {}).get("shader_params", {})
    h_scale = float(sp.get("height_scale", 0.0))
    h_off = float(sp.get("height_offset", -0.5))
    spawn_clear_y = (1.0 + h_off) * h_scale + 2.0 if h_scale > 0.0 else 2.0

    # 2. Shell entity defs.
    (game_dir / "entities").mkdir(exist_ok=True)
    (game_dir / "entities" / "player.json").write_text(
        json.dumps(_player_def(), indent=2))
    (game_dir / "entities" / "world_clock.json").write_text(
        json.dumps(_world_clock_def(), indent=2))
    (game_dir / "entities" / "cameras.json").write_text(
        json.dumps(_cameras_def(), indent=2))

    # 3. Shell rules (camera control + movement). Rule JSON is cheap
    # config (not a paid asset), so clean legacy shell-rule files —
    # including the pre-split compose_world names — to avoid duplicate
    # rule ids when re-running over an older map dir.
    rules_dir = game_dir / "world" / "rules"
    rules_dir.mkdir(parents=True, exist_ok=True)
    for legacy in ("01_freecam_toggle.json", "02_movement.json",
                   "10_shell_camera.json", "11_shell_movement.json"):
        (rules_dir / legacy).unlink(missing_ok=True)
    (rules_dir / "10_shell_camera.json").write_text(
        json.dumps(_camera_rules(), indent=2))
    (rules_dir / "11_shell_movement.json").write_text(
        json.dumps(_movement_rules(), indent=2))

    # 4. Input + tests.
    (game_dir / "ui").mkdir(exist_ok=True)
    (game_dir / "ui" / "input.json").write_text(
        json.dumps(_input_map(), indent=2))
    (game_dir / "tests.json").write_text(
        json.dumps({"scenarios": []}, indent=2))

    # 5. Splice the shell singletons into the level's entities.json.
    level_path = game_dir / "levels" / level_id / "entities.json"
    level = json.loads(level_path.read_text())
    objects = [i for i in level.get("initial_instances", [])
               if i.get("def") not in (
                   "world_clock", "player_input_anchor", "free_camera")]
    spawn = (cfg.get("player", {}) or {}).get("spawn")
    level["initial_instances"] = _singleton_instances(
        world_w, spawn=spawn, spawn_clear_y=spawn_clear_y) + objects
    level_path.write_text(json.dumps(level, indent=2))

    # 6. The .tscn launcher.
    tscn_slug = game_name.removeprefix("demo_")
    (ROOT / "godot" / "scenes" / f"{tscn_slug}_3d.tscn").write_text(
        _tscn(game_name, world_w))

    return game_dir


def main() -> None:
    ap = argparse.ArgumentParser(prog="compose_shell")
    ap.add_argument("game_name", help="map dir under godot/data/<name>")
    ap.add_argument("--shell-type", default="third_person_explorer")
    ap.add_argument("--level-id", default="level_default")
    args = ap.parse_args()
    game_dir = compose_shell(args.game_name, args.shell_type, args.level_id)
    print(f"[compose_shell] wrote {args.shell_type} shell into {game_dir}")
    print(f"run with: ./scripts/play.sh {args.game_name.removeprefix('demo_')}")


if __name__ == "__main__":
    main()
