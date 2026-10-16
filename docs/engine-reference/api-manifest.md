# Yume Engine API Manifest

**Auto-generated** by `tools/gen_api_manifest.py` — do not hand-edit.
_Generated: 2026-10-16T09:15:56+00:00_
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

**Math helpers** (Godot Expression built-ins):

`sin`, `cos`, `tan`, `sqrt`, `pow`, `abs`, `floor`, `ceil`, `round`, `clamp`, `min`, `max`, `lerp`, `randf`

**Formula syntax notes** (Godot 4.6.1 quirks):

- No ternary. Godot 4.6.1 Expression returns `a` for `a if cond else b`, and C-style `cond ? a : b` does not parse. Formula rejects `if`. Write `b + (a - b) * float(cond)`.
- Bitwise `<<`, `&`, `|` — supported.
- Vector2 / Vector3 / Array subscript `v[0]` — supported.
- Vector2 / Vector3 component access `v.x`, `v.y`, `v.z` — supported via path resolver.
- Empirically verified during harvestcore QA (2026-05-02).

## Error codes (Tier 2.6a)

38 stable codes for matching in retry loops:

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
