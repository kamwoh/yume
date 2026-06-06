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

def _camera_block(camera_mode: str = "third_person_3d") -> dict:
    """Choose the lib camera preset to match the scene's starting
    camera_mode. The preset carries mode-specific tuning (eye_height
    for FPS; distance/height for third-person; ortho_size for
    iso/top-down). Mouse-pitch (look up/down) is ON by default for both
    first- and third-person (2026-06-06: engine `use_pitch` defaults to
    true + the third_person_default preset sets it explicitly). A
    fixed-pitch follow opts out with `use_pitch: false`.
    """
    if camera_mode == "first_person_3d":
        return {
            # FPS — eye-height + mouse yaw AND pitch. Press C → free-cam.
            "$extends": "@lib.cameras.fps_default",
            "follow_tag": "player",
            "fov": 70.0,
        }
    if camera_mode == "isometric_3d":
        return {
            "$extends": "@lib.cameras.iso_top_down",
            "follow_tag": "player",
        }
    if camera_mode == "top_down_3d":
        return {
            "$extends": "@lib.cameras.top_down_3d",
            "follow_tag": "player",
        }
    # Default: third-person, behind-shoulder follow.
    return {
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
        # SSAO — soft contact shadows in terrain creases + where objects
        # meet the ground. This is most of the hero reference's "velvet
        # lawn" 3D form (the grass looks sculpted because of AO, not blades).
        "ssao": {
            "enabled": True,
            "radius": 2.5,
            "intensity": 2.5,
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
                    "sprint_t": 0,
                    "facing": 0.0,
                    "pitch": 0.0,
                    "y_velocity": 0.0,
                    "on_floor": 1,
                    "gravity": 18.0,
                    "camera_distance": 4.0,
                    "scale": 1.7,
                },
                "physics": {"$extends": "@lib.physics.bodies.standard_character_player"},
                "visual": {
                    "mesh": "res://data/demo_aldenmere/assets/meshes/player_marken_animated_0b249fa7.glb",
                    "animation_clips": ["idle", "walk", "run", "jump"],
                    # First-match-wins, default last. jump = airborne
                    # (on_floor==0); run = sprint speed (walk≈3.0, sprint≈5.4).
                    "animation_state_rules": [
                        {"if_state_eq": {"on_floor": 0}, "state": "jump"},
                        {"if_velocity_gt": 4.5, "state": "run"},
                        {"if_velocity_gt": 0.1, "state": "walk"},
                        {"default": "idle"}
                    ]
                }
            }
        ]
    }


def _world_clock_def(camera_mode: str = "third_person_3d") -> dict:
    return {
        "_comment": f"Shell singleton. Starts {camera_mode}. C → free_cam.",
        "definitions": [
            {
                "id": "world_clock",
                "tags": ["world_clock", "persistent"],
                "properties": {},
                "state_init": {
                    "camera_mode": camera_mode,
                    "previous_camera_mode": camera_mode,
                    "active_camera_id": "camera_oblique",
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
    # Mouse-wheel zoom: each wheel tick is one press. state_add nudges the
    # player's camera_distance; state_clamp keeps it in the camera's
    # [distance_min, distance_max] band so the value can't drift unbounded
    # (the camera ALSO clamps on read, but clamping the state too avoids a
    # "scroll back many ticks" lag after over-scrolling). camera_director
    # reads state.camera_distance for the third-person orbit radius.
    rules.append({
        "id": "camera_zoom_in",
        "_comment": "Mouse wheel up → camera closer.",
        "trigger": {"type": "input", "action": "zoom_in"},
        "query": {"tags_all": ["player"]},
        "effect": [
            {"type": "state_add", "target": "self",
             "field": "camera_distance", "amount": -1.5},
            {"type": "state_clamp", "target": "self",
             "field": "camera_distance", "min": 3.0, "max": 40.0},
        ],
    })
    rules.append({
        "id": "camera_zoom_out",
        "_comment": "Mouse wheel down → camera farther.",
        "trigger": {"type": "input", "action": "zoom_out"},
        "query": {"tags_all": ["player"]},
        "effect": [
            {"type": "state_add", "target": "self",
             "field": "camera_distance", "amount": 1.5},
            {"type": "state_clamp", "target": "self",
             "field": "camera_distance", "min": 3.0, "max": 40.0},
        ],
    })
    return {"_comment": "Shell camera control. C toggles free_cam ↔ "
                        "previous mode. Mouse wheel zooms.", "rules": rules}


def _jump_rules() -> dict:
    return {
        "_comment": "Space → jump. Sets actor.y_velocity; character_body_runner "
                    "mirrors it into body.velocity.y and gravity brings the "
                    "player back. Grounded-only (require on_floor==1) = no "
                    "double-jump. Gated to first/third-person (free_cam uses "
                    "Space for cam_up).",
        "rules": [
            {
                "id": "player_jump",
                "trigger": {"type": "input", "action": "jump"},
                "query": {"tags_all": ["world_clock"],
                          "state": {"camera_mode_in":
                                    ["first_person_3d", "third_person_3d"]}},
                "require": {"actor": {"tags_all": ["player"],
                                      "state": {"on_floor_eq": 1}}},
                "effect": [
                    {"type": "state_set", "target": "actor",
                     "field": "y_velocity", "value": 7.0},
                    {"type": "state_set", "target": "actor",
                     "field": "on_floor", "value": 0},
                ],
            }
        ]
    }


def _sprint_rules() -> dict:
    # Shift → faster walk. The FP-variant WASD bundle scales its per-tick
    # forward/strafe by actor.state.speed_multiplier, so sprint just raises
    # that. Reset-on-release is handled by a countdown (sprint_t): the hold
    # rule refreshes it to 2 each tick held; a decide-tick rule applies the
    # multiplier while sprint_t>0 and decrements it; another resets to 1.0
    # when it hits 0. The countdown survives the input→decide phase ordering
    # (the move rule reads the PREVIOUS tick's multiplier), so there's no
    # intra-phase race — ~1-2 ticks (≈30ms) of ramp on start/stop, imperceptible.
    return {
        "_comment": "Hold Shift to run (scales speed_multiplier via a "
                    "release-safe countdown). 1.0 walk → 1.8 run.",
        "rules": [
            {
                "id": "sprint_arm",
                "trigger": {"type": "input", "action": "sprint"},
                "query": {"tags_all": ["player"]},
                "effect": [{"type": "state_set", "target": "self",
                            "field": "sprint_t", "value": 2}],
            },
            {
                "id": "sprint_apply",
                "trigger": {"type": "tick", "interval": 1},
                "query": {"tags_all": ["player"], "state": {"sprint_t_gt": 0}},
                "effect": [
                    {"type": "state_set", "target": "self",
                     "field": "speed_multiplier", "value": 1.8},
                    {"type": "state_add", "target": "self",
                     "field": "sprint_t", "amount": -1},
                ],
            },
            {
                "id": "sprint_reset",
                "trigger": {"type": "tick", "interval": 1},
                "query": {"tags_all": ["player"], "state": {"sprint_t_lt": 1}},
                "effect": [{"type": "state_set", "target": "self",
                            "field": "speed_multiplier", "value": 1.0}],
            },
        ]
    }


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
        "_comment": "WASD + camera/freecam controls. Space-as-jump fires "
                    "outside free-cam (the engine's character_body_runner "
                    "consumes it as a vertical impulse); Space-as-cam_up "
                    "holds for the free-cam vertical ascent. Same key, "
                    "different edge + gated by camera_mode — matches "
                    "aldenmere convention. ESC releases mouse capture.",
        "actions": [
            {"$include": "@lib.input.universal.actions"},
            {"name": "jump",                  "key": "Space",    "edge": "press"},
            {"name": "toggle_freecam",        "key": "C",        "edge": "press"},
            {"name": "cam_up",                "key": "Space",    "edge": "hold"},
            {"name": "cam_down",              "key": "Ctrl",     "edge": "hold"},
            {"name": "sprint",                "key": "Shift",    "edge": "hold"},
            {"name": "cycle_camera",          "key": "Tab",      "edge": "press"},
            {"name": "toggle_help",           "key": "H",        "edge": "press"},
            {"name": "toggle_mouse_capture",  "key": "Escape",   "edge": "press"},
            {"name": "zoom_in",   "mouse_button": "WheelUp",   "edge": "press"},
            {"name": "zoom_out",  "mouse_button": "WheelDown", "edge": "press"},
        ]
    }


def _screens() -> dict:
    """A built-in HELP overlay every shell game gets for free: press H to
    toggle a screen listing the controls (key → action) + the objective.
    No `starting_screen` → the game boots straight into the world; H opens
    the modal, H/again (or the Close button) pops it. The toggle is
    declared via `global_inputs` with paired `if_screen` filters
    (engine-native, no rules needed — see screen_flow.gd _handle_global_inputs).

    The objective label binds `world.objective` — a game sets
    `world_state.objective` (state_set target=world) and it shows here; if
    unset it's blank. Controls below are the shell's fixed bindings.
    """
    ctl = lambda s: {"type": "label", "text": s, "font_size": 22,
                     "color": "#e8e8e8", "halign": "center"}
    return {
        "_comment": "Built-in HELP overlay from compose_shell. H toggles a "
                    "controls + objective screen (global_inputs paired "
                    "if_screen filters). No starting_screen → boots in-world. "
                    "A game with its own screens APPENDS to `screens` + keeps "
                    "`global_inputs` (don't overwrite this file — ADR 0067).",
        "global_inputs": [
            {"action": "toggle_help", "if_screen": "",
             "on_press": [{"type": "transition_screen", "target": "help"}]},
            {"action": "toggle_help", "if_screen": "help",
             "on_press": [{"type": "transition_screen", "target": "@previous"}]},
        ],
        "screens": [
            {
                "id": "help",
                "freeze_world": True,
                "background_color": "#0a0c10",
                "background_alpha": 0.9,
                "elements": [
                    {"type": "label", "text": "Controls", "anchor": "top_center",
                     "y_offset": 56, "font_size": 40, "color": "#ffd479",
                     "halign": "center"},
                    {"type": "vbox", "anchor": "center", "y_offset": -6,
                     "separation": 10, "children": [
                         ctl("Move — W A S D"),
                         ctl("Look — Mouse"),
                         ctl("Sprint — Shift"),
                         ctl("Jump — Space"),
                         ctl("Free camera — C    ·    Cycle cameras — Tab"),
                         ctl("Help — H    ·    Release mouse — Esc"),
                     ]},
                    {"type": "label", "binds": "world.objective",
                     "format": "Objective: {}", "anchor": "bottom_center",
                     "y_offset": -120, "font_size": 24, "color": "#a0e0a0",
                     "halign": "center"},
                    {"type": "label", "text": "Press H to close",
                     "anchor": "bottom_center", "y_offset": -56, "font_size": 18,
                     "color": "#909090", "halign": "center"},
                ],
            }
        ],
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

def compose_shell(game_name: str,
                  shell_type: str = "third_person_explorer") -> Path:
    """Add the playable wrapper to an existing scene dir (compose_world
    output). Returns the game dir. Produces a FLAT, runnable scene (no
    levels/ or flow.json) per ADR 0067."""
    if shell_type != "third_person_explorer":
        raise ValueError(f"unknown shell_type: {shell_type} "
                         f"(only 'third_person_explorer' today)")
    game_dir = (DATA_ROOT / game_name).resolve()
    scene_path = game_dir / "scene.json"
    if not scene_path.exists():
        raise FileNotFoundError(
            f"{scene_path} not found — run compose_world (map) first")

    cfg = scfg.SceneConfig.load(game_dir)

    # 1. Merge camera + lighting into the map's scene.json. The scene's
    # lighting is the built-in cinematic default deep-merged with any
    # scene_config.json "lighting" override (per-scene mood).
    scene = json.loads(scene_path.read_text())
    world_w = float(scene.get("ground", {}).get("mesh", {})
                    .get("size", [80.0])[0])
    # Camera block: lib preset (chosen by player.camera_mode) deep-merged
    # with scene_config.camera overrides — same pattern as lighting.
    scene["camera"] = scfg.deep_merge(
        _camera_block(cfg.player.camera_mode), cfg.camera
    )
    scene["lighting"] = scfg.deep_merge(_lighting_block(), cfg.lighting)
    scene_path.write_text(json.dumps(scene, indent=2))

    # Player spawn height: sample the LOCAL terrain height at the spawn x/z
    # and add a small margin, so the player drops ~0.5m and lands almost
    # immediately. (Was `max_terrain_displacement + 2m` — on a hilly map
    # that's many metres above the local ground; the long fall let a game
    # that moves-on-spawn drift the still-falling player into a TALL prop
    # box mid-air, where collision depenetration ejected it DOWN through the
    # floor — looked like the player "fell through" / "launched". Spawning
    # on the local ground removes that airborne window. 2026-06-06, ADR 0067.)
    sp = scene.get("ground", {}).get("mesh", {}).get("shader_params", {})
    h_scale = float(sp.get("height_scale", 0.0))
    h_off = float(sp.get("height_offset", -0.5))
    sp_xz = cfg.player.spawn or [0.0, None, 10.0]
    spawn_x = float(sp_xz[0])
    spawn_z = float(sp_xz[2]) if len(sp_xz) > 2 else 10.0
    local_ground_y = 0.0
    if h_scale > 0.0:
        try:
            from tools.visual_layout.lib_extract_dispatch import HeightmapSampler
            hm_path = game_dir / "assets" / "textures" / "heightmap_carved.png"
            if not hm_path.exists():
                hm_path = game_dir / "assets" / "textures" / "heightmap.png"
            if hm_path.exists():
                _s = HeightmapSampler(hm_path, world_w, h_scale, h_off)
                local_ground_y = float(_s.y_at(spawn_x, spawn_z))
        except Exception as _e:
            print(f"[compose_shell] heightmap spawn-sample failed ({_e}); "
                  f"using flat ground. Player may drop from a small height.")
    # +0.1m only: the player origin is at its feet, so this drops ~0.1m and
    # is grounded within ~2 physics frames. A bigger margin (was +0.5) left
    # the player airborne long enough that moving on spawn sent it into a
    # tall prop collider mid-air → depenetrated through the floor. Small
    # margin = no airborne window = colliders block cleanly. 2026-06-06.
    spawn_clear_y = local_ground_y + 0.1

    # 2. Shell entity defs.
    (game_dir / "entities").mkdir(exist_ok=True)
    (game_dir / "entities" / "player.json").write_text(
        json.dumps(_player_def(), indent=2))
    (game_dir / "entities" / "world_clock.json").write_text(
        json.dumps(_world_clock_def(cfg.player.camera_mode), indent=2))
    (game_dir / "entities" / "cameras.json").write_text(
        json.dumps(_cameras_def(), indent=2))

    # 3. Shell rules (camera control + movement). Rule JSON is cheap
    # config (not a paid asset), so clean legacy shell-rule files —
    # including the pre-split compose_world names — to avoid duplicate
    # rule ids when re-running over an older map dir.
    rules_dir = game_dir / "world" / "rules"
    rules_dir.mkdir(parents=True, exist_ok=True)
    for legacy in ("01_freecam_toggle.json", "02_movement.json",
                   "10_shell_camera.json", "11_shell_movement.json",
                   "12_shell_jump.json", "13_shell_sprint.json"):
        (rules_dir / legacy).unlink(missing_ok=True)
    (rules_dir / "10_shell_camera.json").write_text(
        json.dumps(_camera_rules(), indent=2))
    (rules_dir / "11_shell_movement.json").write_text(
        json.dumps(_movement_rules(), indent=2))
    (rules_dir / "12_shell_jump.json").write_text(
        json.dumps(_jump_rules(), indent=2))
    (rules_dir / "13_shell_sprint.json").write_text(
        json.dumps(_sprint_rules(), indent=2))

    # 4. Input + tests.
    (game_dir / "ui").mkdir(exist_ok=True)
    (game_dir / "ui" / "input.json").write_text(
        json.dumps(_input_map(), indent=2))
    (game_dir / "tests.json").write_text(
        json.dumps({"scenarios": []}, indent=2))

    # 4b. Built-in HELP overlay (H toggles controls + objective). Only
    # WRITE if absent — a game may have authored its own screens.json
    # (with the help screen appended); don't clobber it (ADR 0067).
    screens_path = game_dir / "screens.json"
    if not screens_path.exists():
        screens_path.write_text(json.dumps(_screens(), indent=2))

    # 5. Shell singletons (world_clock, player, free cameras) → their own
    # flat entities file (ADR 0067). compose_world's map content lives in
    # entities/auto_gen.json; the engine globs entities/*.json and spawns
    # both, so the scene boots FLAT — no levels/ or flow.json needed.
    (game_dir / "entities" / "shell_singletons.json").write_text(
        json.dumps({
            "_comment": "Shell singletons (world_clock, player, free "
                        "cameras) spliced by compose_shell. Flat layout.",
            "initial_instances": _singleton_instances(
                world_w, spawn=cfg.player.spawn,
                spawn_clear_y=spawn_clear_y),
        }, indent=2))

    # 6. The .tscn launcher.
    tscn_slug = game_name.removeprefix("demo_")
    (ROOT / "godot" / "scenes" / f"{tscn_slug}_3d.tscn").write_text(
        _tscn(game_name, world_w))

    return game_dir


def main() -> None:
    ap = argparse.ArgumentParser(prog="compose_shell")
    ap.add_argument("game_name", help="scene dir under godot/data/<name>")
    ap.add_argument("--shell-type", default="third_person_explorer")
    args = ap.parse_args()
    game_dir = compose_shell(args.game_name, args.shell_type)
    print(f"[compose_shell] wrote {args.shell_type} shell into {game_dir}")
    print(f"run with: ./scripts/play.sh {args.game_name.removeprefix('demo_')}")


if __name__ == "__main__":
    main()
