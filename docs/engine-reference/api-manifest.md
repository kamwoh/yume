# Yume Engine API Manifest

**Auto-generated** by `tools/gen_api_manifest.py` — do not hand-edit.
_Generated: 2026-05-05T22:05:33+00:00_
_Source: `archetypes/core/templates/godot/scripts/engine`_

This manifest is the canonical list of what verbs the engine supports.
Agents (`yume-content-designer`, `yume-systems-designer`, `yume-tech-director`)
should reference this file instead of hand-edited markdown.

## Primitives (7)

`Entity`, `Tag`, `Rule`, `Trigger`, `Effect`, `Query`, `Relation`

**Deferred** (Tier 3): `Plan`, `Knowledge`

## Triggers

Valid `rule.trigger.type` strings:

`tick`, `contact`, `signal`, `input`, `spawn`, `despawn`, `relation_changed`, `scheduled`

## Effect types

20 effect types (used as `rule.effect[].type`):

- `state_set` — `effect_apply.gd`
- `state_add` — `effect_apply.gd`
- `state_mul` — `effect_apply.gd`
- `state_clamp` — `effect_apply.gd`
- `spawn` — `effect_apply.gd`
- `remove` — `effect_apply.gd`
- `transform` — `effect_apply.gd`
- `relate` — `effect_apply.gd`
- `unrelate` — `effect_apply.gd`
- `transfer_relation` — `effect_apply.gd`
- `tag_add` — `effect_apply.gd`
- `tag_remove` — `effect_apply.gd`
- `velocity_set` — `effect_apply.gd`
- `velocity_lerp` — `effect_apply.gd`
- `velocity_set_relative` — `effect_apply.gd`
- `velocity_add_relative` — `effect_apply.gd`
- `raycast_hit` — `effect_apply.gd`
- `transition_level` — `effect_apply.gd`
- `emit` — `effect_apply.gd`
- `emit_shell_event` — `effect_apply.gd`

## Query clauses

Top-level keys allowed in a `query` spec:

`tags_all`, `tags_any`, `tags_none`, `properties`, `state`, `relations`, `radius`, `order_by`, `limit`

### Operator suffixes

Used in `state` / `properties` filters (e.g. `"hp_lt": 50`):

`_eq`, `_ne`, `_gt`, `_lt`, `_gte`, `_lte`, `_atleast`, `_atmost`

## Formula bindings

**Entity roles** (use as `<role>.state.<field>`):

`self`, `target`, `a`, `b`, `source`, `world`

**Math helpers** (Godot Expression built-ins):

`sin`, `cos`, `tan`, `sqrt`, `pow`, `abs`, `floor`, `ceil`, `round`, `clamp`, `min`, `max`, `lerp`, `randf`

**Formula syntax notes** (Godot 4.6.1 quirks):

- Ternary: **Python-style** `a if cond else b`. C-style `cond ? a : b` does NOT parse.
- Bitwise `<<`, `&`, `|` — supported.
- Vector2 / Vector3 / Array subscript `v[0]` — supported.
- Vector2 / Vector3 component access `v.x`, `v.y`, `v.z` — supported via path resolver.
- Empirically verified during harvestcore QA (2026-05-02).

## Error codes (Tier 2.6a)

26 stable codes for matching in retry loops:

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

## Reserved state fields

Fields the engine reads by name (everything else is content vocabulary):

`position`, `velocity`, `age`

## Invariants

8 contract invariants — see `docs/30_framework_primitives.md`.
