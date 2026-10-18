# Yume Engine API Manifest

**Auto-generated** by `tools/gen_api_manifest.py` — do not hand-edit.
_Generated: 2026-10-18T13:05:59+00:00_
_Source: `godot/scripts/engine`_

This manifest is the canonical list of what verbs the engine supports.
Agents (`yume-content-designer`, `yume-systems-designer`, `yume-tech-director`)
should reference this file instead of hand-edited markdown.

## Primitives (7)

`Entity`, `Tag`, `Rule`, `Trigger`, `Effect`, `Query`, `Relation`

**Deferred** (Tier 3): `Plan`, `Knowledge`

## Triggers

Valid `rule.trigger.type` strings:

`tick`, `frame_tick`, `contact`, `signal`, `input`, `spawn`, `despawn`, `relation_changed`, `scheduled`, `overlap`

## Effect types

50 effect types (used as `rule.effect[].type`):

- `state_set` — fields: `field`, `target`, `value`
- `state_add` — fields: `amount`, `field`, `target`
- `state_mul` — fields: `amount`, `field`, `target`
- `state_clamp` — fields: `field`, `max`, `min`, `target`
- `zone_state_set` — fields: `field`, `value`, `zone`
- `zone_state_add` — fields: `amount`, `delta`, `field`, `zone`
- `zone_state_clamp` — fields: `field`, `max`, `min`, `zone`
- `spawn` — fields: `overrides`, `position`, `template`
- `remove` — fields: `target`
- `transform` — fields: `target`, `to`
- `relate` — fields: `from`, `relation`, `state`, `to`
- `unrelate` — fields: `from`, `relation`, `to`
- `transfer_relation` — fields: `from`, `new_from`, `new_to`, `relation`, `to`
- `refresh_screen` — fields: none
- `advance_time` — fields: `units`
- `level_call` — fields: `args`, `level`, `return_signal`
- `level_return` — fields: `result`
- `relation_set` — fields: `field`, `from`, `relation`, `to`, `value`
- `relation_add` — fields: `amount`, `field`, `from`, `relation`, `to`
- `relation_clamp` — fields: `field`, `from`, `max`, `min`, `relation`, `to`
- `tag_add` — fields: `tag`, `target`
- `tag_remove` — fields: `tag`, `target`
- `velocity_set` — fields: `target`, `x`, `y`, `z`
- `velocity_lerp` — fields: `rate`, `target`, `x`, `y`
- `velocity_set_relative` — fields: `facing`, `forward`, `strafe`, `target`
- `velocity_add_relative` — fields: `facing`, `forward`, `strafe`, `target`
- `pathfind_to` — fields: `destination_x`, `destination_y`, `destination_z`, `speed`, `target`
- `raycast_hit` — fields: `direction`, `max_distance`, `on_hit`, `on_miss`, `origin`, `respect_obstacles`, `tags_all`, `tags_none`
- `transition_level` — fields: `color`, `fade_duration`, `target`
- `emit` — fields: `payload`, `signal`
- `array_set_at` — fields: `field`, `index`, `target`, `value`
- `array_insert_first_empty` — fields: `field`, `on_full`, `result_field`, `sentinel`, `target`, `value`
- `array_sync_to_field` — fields: `array_field`, `default`, `dest_field`, `index_field`, `target`
- `array_count_matching` — fields: `array_field`, `dest_field`, `sentinel`, `target`
- `emit_shell_event` — fields: `event` (open: passes the dict on, so other keys can matter)
- `transition_screen` — fields: `target`
- `quit_app` — fields: none
- `show_toast` — fields: `duration`, `text`
- `reload_scene` — fields: `args`
- `scene_change` — fields: `target`
- `screen_fade` — fields: `alpha`, `color`, `duration`
- `save_state` — fields: `slot`
- `load_state` — fields: `slot`
- `show_overlay` — fields: none (open: passes the dict on, so other keys can matter)
- `dismiss_overlay` — fields: `id`
- `set_audio_bus_volume` — fields: `bus`, `linear`
- `set_input_mapping` — fields: `action`, `key`
- `switch_actor` — fields: `target`, `target_id`
- `queue_input_for_actor` — fields: `action`, `actor_id`
- `reset_world` — fields: none

## Query clauses

Top-level keys allowed in a `query` spec:

`tags_all`, `tags_any`, `tags_none`, `id`, `ids`, `properties`, `state`, `relations`, `radius`, `order_by`, `limit`

### Operator suffixes

Used in `state` / `properties` filters (e.g. `"hp_lt": 50`):

`_eq`, `_ne`, `_gt`, `_lt`, `_gte`, `_lte`, `_atleast`, `_atmost`

## Formula bindings

**Entity roles** (use as `<role>.state.<field>`):

`self`, `target`, `a`, `b`, `source`, `world`

**Functions** (ADR 0088, `Formula.FUNCTIONS`). A call to any other name fails with `formula.unknown_function`:

`abs`, `floor`, `ceil`, `round`, `min`, `max`, `clamp`, `lerp`, `sqrt`, `pow`, `sin`, `cos`, `tan`, `atan2`, `randf`, `float`

**Formula language** (ADR 0088):

- Every number is a float. `5 / 2` gives `2.5`.
- Allowed: numbers, bindings, `+ - * /`, `== != < <= > >=`, `and or not`, `true false`, parentheses, and an index such as `self.state.position[0]`.
- Not allowed: `%`, `**`, strings, method calls, constructors, array literals, `&& || !`, bitwise operators.
- No ternary. Write `b + (a - b) * float(cond)`. `float(b)` gives 1.0 or 0.0.
- Vector component access `v.x`, `v.y`, `v.z` works through the binding path.

## Shaders (ADR 0089)

Content names a library shader by name (`"shader": "sky_clouds"`) and sets its parameters in `shader_params`. A custom shader is a `shader_dag` graph (ADR 0058). The exact look is host-defined. The interpreter sets `plane_size`, `screen_tex` and `depth_tex` itself.

### `sky_clouds` (sky)

| Parameter | Type | Default | Range | Note |
|---|---|---|---|---|
| `sky_top_color` | color | [0.35, 0.55, 0.85] | — |  |
| `sky_horizon_color` | color | [0.70, 0.82, 0.92] | — |  |
| `cloud_color` | color | [0.95, 0.95, 0.92] | — |  |
| `cloud_shadow_color` | color | [0.55, 0.60, 0.65] | — |  |
| `cloud_coverage` | number | 0.45 | 0.0,1.0 |  |
| `cloud_softness` | number | 0.40 | 0.0,1.0 |  |
| `cloud_speed` | number | 0.012 | 0.0,0.1 |  |
| `cloud_scale` | number | 5.0 | 1.0,20.0 |  |
| `mountain_enabled` | number | 0.0 | 0.0,1.0 |  |
| `mountain_base_color` | color | [0.40, 0.48, 0.62] | — |  |
| `mountain_peak_color` | color | [0.70, 0.74, 0.80] | — |  |
| `mountain_height` | number | 0.15 | 0.0,0.4 | peak amplitude (radians of altitude) |
| `mountain_jaggedness` | number | 8.0 | 1.0,30.0 | higher = more peaks per 360° |

### `water_stylized` (spatial)

| Parameter | Type | Default | Range | Note |
|---|---|---|---|---|
| `deep_color` | color | [0.03, 0.10, 0.20, 1.0] | — |  |
| `shallow_color` | color | [0.30, 0.62, 0.74, 0.85] | — |  |
| `foam_color` | color | [0.97, 0.99, 1.0, 1.0] | — |  |
| `normal_tile_m` | number | 6.0 | 0.5,30.0 |  |
| `ripple_strength` | number | 0.85 | 0.0,1.5 |  |
| `flow_dir` | [x, y] | [0.72, 0.32] | — |  |
| `flow_speed` | number | 0.045 | 0.0,0.5 |  |
| `depth_fade_m` | number | 0.45 | 0.05,8.0 |  |
| `refraction_strength` | number | 0.05 | 0.0,0.15 |  |
| `fresnel_power` | number | 3.5 | 0.5,8.0 |  |
| `foam_distance_m` | number | 0.65 | 0.0,3.0 |  |
| `foam_softness` | number | 0.40 | 0.01,1.0 |  |
| `foam_animation` | number | 1.8 | 0.0,4.0 |  |
| `water_mask` | texture (asset path) | — | — |  |
| `use_water_mask` | bool | false | — |  |

### `ground_biome_displace` (spatial)

| Parameter | Type | Default | Range | Note |
|---|---|---|---|---|
| `biome_map` | texture (asset path) | — | — |  |
| `heightmap` | texture (asset path) | — | — |  |
| `height_scale` | number | 3.0 | — |  |
| `height_offset` | number | -0.5 | — |  |
| `biome_count` | integer | 1 | — |  |
| `biome_key` | list of [x, y, z] | — | — |  |
| `biome_albedo` | list of [x, y, z] | — | — |  |
| `biome_roughness` | list of number | — | — |  |
| `blend_softness` | number | 0.12 | 0.01,0.6 |  |
| `noise_amount` | number | 0.06 | 0.0,0.5 |  |
| `grass_detail` | texture (asset path) | — | — |  |
| `grass_biome_index` | integer | -1 | — | -1 = no grass |
| `detail_tile` | number | 24.0 | — | tiles across plane |
| `detail_strength` | number | 0.30 | 0.0,1.0 |  |
| `wind_dir` | [x, y] | [0.7, 0.7] | — |  |
| `wind_speed` | number | 0.9 | — |  |
| `wind_gust_freq` | number | 0.08 | — | gust-band spacing |
| `wind_gust_strength` | number | 0.11 | 0.0,0.3 |  |
| `wind_flow` | number | 0.035 | — | detail-UV drift |
| `crown_lift` | number | 0.16 | 0.0,0.4 | hilltop brighten |
| `crease_darken` | number | 0.22 | 0.0,0.5 | slope/dip darken |
| `crown_warm` | color | [1.08, 1.04, 0.84] | — |  |

### `ground_ortho_displace` (spatial)

| Parameter | Type | Default | Range | Note |
|---|---|---|---|---|
| `ortho_albedo` | texture (asset path) | — | — |  |
| `heightmap` | texture (asset path) | — | — |  |
| `height_scale` | number | 3.0 | — |  |
| `height_offset` | number | -0.5 | — |  |
| `crown_lift` | number | 0.06 | 0.0,0.25 |  |
| `crease_darken` | number | 0.10 | 0.0,0.35 |  |
| `albedo_attenuate` | number | 0.55 | 0.2,1.0 |  |

### `toon` (spatial)

| Parameter | Type | Default | Range | Note |
|---|---|---|---|---|
| `albedo_color` | color | [1.0] | — |  |
| `albedo_texture` | texture (asset path) | — | — |  |
| `bands` | integer | 3 | 2,6 |  |
| `rim_color` | color | [1.0] | — |  |
| `rim_power` | number | 3.0 | 0.5,8.0 |  |
| `rim_strength` | number | 0.35 | 0.0,1.0 |  |
| `fill_color` | color | [0.5, 0.55, 0.65, 1.0] | — |  |
| `fill_strength` | number | 0.7 | 0.0,1.5 |  |

## Spec vocabularies (ADR 0090)

Each list is closed. `validate_host_neutral.py` rejects other names, and the engine reports an error code. The contract document defines each name.

### Input keys

A key name means a key position on a US keyboard. Use it in `ui/input.json` (`key`, `keys`) and in `set_input_mapping`:

`A`, `B`, `C`, `D`, `E`, `F`, `G`, `H`, `I`, `J`, `K`, `L`, `M`, `N`, `O`, `P`, `Q`, `R`, `S`, `T`, `U`, `V`, `W`, `X`, `Y`, `Z`, `0`, `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`, `F1`, `F2`, `F3`, `F4`, `F5`, `F6`, `F7`, `F8`, `F9`, `F10`, `F11`, `F12`, `Up`, `Down`, `Left`, `Right`, `Space`, `Enter`, `Escape`, `Tab`, `Shift`, `Ctrl`, `Alt`, `Backspace`, `Numpad0`, `Numpad1`, `Numpad2`, `Numpad3`, `Numpad4`, `Numpad5`, `Numpad6`, `Numpad7`, `Numpad8`, `Numpad9`

Mouse buttons (`mouse_button`, `mouse_buttons`): `Left`, `Right`, `Middle`, `WheelUp`, `WheelDown`

### Audio channels

`set_audio_bus_volume` `bus`: `master`, `music`, `sfx`. Music plays on `music`, sound cues on `sfx`. Both feed `master`.

### Lighting fields

The fields of `scene.json` `lighting` and `render`. A key that starts with `_` is a comment. Host hints tune one host's renderer, and an interpreter may ignore them.

| Block | Fields |
|---|---|
| `lighting` | `directional_light`, `ambient`, `sky`, `fog`, `tonemap`, `glow`, `adjustments`, `ssao`, `reflection_probes` |
| `lighting.directional_light` | `enabled`, `shadow_enabled`, `binds_to`, `color_at_noon`, `color_at_dawn_dusk`, `color_at_night`, `energy_noon`, `energy_horizon`, `energy_night`, `shadow` |
| `lighting.directional_light.shadow` (host hint) | `mode`, `blur`, `max_distance`, `atlas_size` |
| `lighting.ambient` | `color_day`, `color_night`, `energy_day`, `energy_night` |
| `lighting.sky` | `shader`, `shader_params`, `horizon_day`, `horizon_night`, `ground_day`, `ground_night`, `sky_top_color_day`, `sky_top_color_night`, `cloud_color_day`, `cloud_color_night`, `cloud_shadow_color_day`, `cloud_shadow_color_night` |
| `lighting.fog` | `enabled`, `light_color`, `light_energy`, `sun_scatter`, `density`, `aerial_perspective`, `height`, `height_density` |
| `lighting.tonemap` | `mode`, `exposure`, `white` |
| `lighting.glow` | `enabled`, `intensity`, `strength`, `bloom`, `hdr_threshold` |
| `lighting.adjustments` | `enabled`, `brightness`, `contrast`, `saturation`, `color_correction` |
| `lighting.adjustments.color_correction` | `texture`, `gradient` |
| `lighting.ssao` | `enabled`, `radius`, `intensity` |
| `lighting.reflection_probes[]` (host hint) | `position`, `size`, `intensity`, `box_projection`, `update_mode`, `enable_shadows` |
| `render` (host hint) | `msaa_3d`, `screen_space_aa`, `use_taa`, `scaling_3d_mode`, `scaling_3d_scale`, `fsr_sharpness` |

### Physics

Body types: `static`, `kinematic`, `rigid`, `area`, `character`, `articulated`. `kinematic` is the default.

Fields of a `physics` block: `body_type`, `collision_shape`, `collision_layer`, `collision_mask`, `mass`, `friction`, `restitution`, `linear_damp`, `angular_damp`, `gravity_scale`, `floor_block_on_wall`, `floor_snap_length`, `floor_constant_speed`, `floor_max_angle_deg`, `root`, `links`, `joints`

Collision layer names (`collision_layer`, `collision_mask`, or `"all"`): `world`, `wall`, `floor`, `ceiling`, `player`, `npc`, `enemy`, `animal`, `ally`, `projectile`, `pickup`, `trigger`, `decoration`, `vehicle`, `fluid`, `sensor`

### Articulated bodies (ADR 0091)

A `physics` block with `"body_type": "articulated"` has `root`, `links` and `joints`.

- Joint types: `hinge`, `ball`, `fixed`. Only a `hinge` has `axis`, `limit`, `motor` and `report`.
- Link fields: `shape`, `mass`, `friction`, `restitution`, `visual`. A link `shape` takes `axis` (`x`, `y` or `z`) and `offset`.
- Joint fields: `type`, `parent`, `child`, `at`, `axis`, `limit`, `motor`, `report`
- Motor fields: `target_velocity`, `max_torque`. `target_velocity` is a formula in radians per second, and `max_torque` is in N·m.
- Readback: the root writes `state.position`, `state.yaw` and `state.velocity`. A hinge with `report: "x"` writes `state.x_angle` and `state.x_speed`.

### Sensors (ADR 0092)

A def's `sensors` list casts rays each tick, before the rules. Types: `ray`, `lidar`.

- Fields: `type`, `link`, `at`, `direction`, `range`, `rays`, `fov`, `report`, `collision_mask`. Only a `lidar` has `rays` and `fov`.
- `at` and `direction` are in the frame of `link` (an articulated body), or else of the entity position and yaw.
- A `ray` with `report: "x"` writes `state.x_distance` (`range` when nothing is hit) and `state.x_hit` (0 or 1).
- A `lidar` writes `state.x_ranges` (an array), `state.x_min` and `state.x_min_angle` (radians from `direction`, positive to the left).

### Camera heading (ADR 0094)

A `third_person_3d` or `first_person_3d` camera aims along `heading`: `facing`, `yaw`. `facing` (the default) is the mouse look. `yaw` is the body heading, for a vehicle or a robot.

## Error codes (Tier 2.6a)

49 stable codes for matching in retry loops:

| Code | Constant |
|---|---|
| `rule.file_missing` | `EngineError.RULE_FILE_MISSING` |
| `rule.invalid_json` | `EngineError.RULE_INVALID_JSON` |
| `rule.list_not_array` | `EngineError.RULE_LIST_NOT_ARRAY` |
| `rule.not_instance` | `EngineError.RULE_NOT_INSTANCE` |
| `rule.missing_id` | `EngineError.RULE_MISSING_ID` |
| `rule.duplicate_id` | `EngineError.RULE_DUPLICATE_ID` |
| `rule.trigger_missing` | `EngineError.RULE_TRIGGER_MISSING` |
| `rule.trigger_invalid` | `EngineError.RULE_TRIGGER_INVALID` |
| `rule.effect_empty` | `EngineError.RULE_EFFECT_EMPTY` |
| `rule.effect_not_dict` | `EngineError.RULE_EFFECT_NOT_DICT` |
| `rule.effect_missing_type` | `EngineError.RULE_EFFECT_MISSING_TYPE` |
| `rule.chance_out_of_range` | `EngineError.RULE_CHANCE_OUT_OF_RANGE` |
| `rule.once_conflict` | `EngineError.RULE_ONCE_CONFLICT` |
| `effect.unknown_type` | `EngineError.EFFECT_UNKNOWN_TYPE` |
| `effect.spawn_no_def` | `EngineError.EFFECT_SPAWN_NO_DEF` |
| `effect.transform_no_def` | `EngineError.EFFECT_TRANSFORM_NO_DEF` |
| `effect.emit_no_buffer` | `EngineError.EFFECT_EMIT_NO_BUFFER` |
| `formula.parse_failed` | `EngineError.FORMULA_PARSE_FAILED` |
| `formula.exec_failed` | `EngineError.FORMULA_EXEC_FAILED` |
| `formula.unknown_function` | `EngineError.FORMULA_UNKNOWN_FUNCTION` |
| `shader.unknown` | `EngineError.SHADER_UNKNOWN` |
| `shader.not_compiled` | `EngineError.SHADER_NOT_COMPILED` |
| `input.unknown_key` | `EngineError.INPUT_UNKNOWN_KEY` |
| `audio.unknown_channel` | `EngineError.AUDIO_UNKNOWN_CHANNEL` |
| `scene.unknown_field` | `EngineError.SCENE_UNKNOWN_FIELD` |
| `physics.unknown_body_type` | `EngineError.PHYSICS_UNKNOWN_BODY_TYPE` |
| `physics.unknown_layer` | `EngineError.PHYSICS_UNKNOWN_LAYER` |
| `physics.bad_articulation` | `EngineError.PHYSICS_BAD_ARTICULATION` |
| `sensor.bad_config` | `EngineError.SENSOR_BAD_CONFIG` |
| `camera.unknown_heading` | `EngineError.CAMERA_UNKNOWN_HEADING` |
| `world.entities_missing` | `EngineError.WORLD_ENTITIES_MISSING` |
| `world.entities_invalid_json` | `EngineError.WORLD_ENTITIES_INVALID` |
| `world.def_unknown` | `EngineError.WORLD_DEF_UNKNOWN` |
| `shape.file_missing` | `EngineError.SHAPE_FILE_MISSING` |
| `shape.invalid_json` | `EngineError.SHAPE_INVALID_JSON` |
| `mesh.file_missing` | `EngineError.MESH_FILE_MISSING` |
| `mesh.invalid_json` | `EngineError.MESH_INVALID_JSON` |
| `scheduler.topo_cycle` | `EngineError.SCHEDULER_TOPO_CYCLE` |
| `level.return_empty_stack` | `EngineError.LEVEL_RETURN_EMPTY_STACK` |
| `level.return_orphaned` | `EngineError.LEVEL_RETURN_ORPHANED` |
| `time.reentrant_advance` | `EngineError.TIME_REENTRANT_ADVANCE` |
| `animation.no_default` | `EngineError.ANIMATION_NO_DEFAULT` |
| `step.unknown_verb` | `EngineError.STEP_UNKNOWN_VERB` |
| `step.unknown_action` | `EngineError.STEP_UNKNOWN_ACTION` |
| `step.click_not_found` | `EngineError.STEP_CLICK_NOT_FOUND` |
| `step.click_ambiguous` | `EngineError.STEP_CLICK_AMBIGUOUS` |
| `step.expect_failed` | `EngineError.STEP_EXPECT_FAILED` |
| `step.release_not_held` | `EngineError.STEP_RELEASE_NOT_HELD` |
| `step.invalid_duration` | `EngineError.STEP_INVALID_DURATION` |

## Reserved state fields

Fields the engine reads by name (everything else is content vocabulary):

`position`, `velocity`, `age`

## Invariants

8 contract invariants — see `docs/guideline/30_framework_primitives.md`.
