# ADR 0047 — `world_state` is the `_engine` singleton entity's state

_Date: 2026-05-14_
_Status: accepted_
_Supersedes: none (refines `.claude/rules/data-demo.md` § world-state singleton pattern)_

## Context

Yume historically had **two parallel stores** for runtime state:

1. **`world_state: Dictionary`** on World — addressed by `state_set
   target=world, field=X` and HUD `world.X` bindings.
2. **Singleton entities** like `world_clock` — tagged entities holding
   global game state, queried via `tags_all: ["world_clock"]` and HUD
   `world_clock.X` bindings.

The contract was "engine bookkeeping in `world_state`; game state on
entities." Enforcement was via:

- A path-scoped rule in `.claude/rules/data-demo.md`
- An `_comment` boilerplate in each demo's `world/state.json`

Neither is load-bearing from the engine's perspective. A content author
writing `state_set target=world, field=gold` succeeds silently, defeating
the discipline. The filename `world/state.json` actively invited the
antipattern.

The two stores also created friction:

- Saves serialized `world_state` separately from entities (special
  filter list `world_state_keys`).
- Queries had to choose: search entities with a tag, or read a magic
  dict key.
- Debug dumps required two paths (`world_state` print + entity dump).

## Decision

**Make `world_state` the state dict of a singleton entity tagged
`_engine`.** WorldBoot auto-spawns this entity early, sharing
`world.world_state` and `_engine.state` by Dictionary reference — every
read/write through either name updates the same data.

```gdscript
func _spawn_engine_entity() -> void:
    if _world.entities.has("_engine"):
        return
    var ent := Entity.new()
    ent.name = "_engine"
    ent.def_id = "_engine"
    ent.instance_id = "_engine"
    ent.tags = ["_engine"]
    ent.state = _world.world_state  # SAME dict ref
    _world.add_child(ent)
    _world.entities["_engine"] = ent
```

`_engine` has no def, no renderer, no position, no spatial-index entry.
It is a passive Node holder for the engine's bookkeeping state. It does
not appear in radius queries, tag probes for actor/creature/etc., or
visual scans — only in explicit `tags_all: ["_engine"]` queries.

## Consequences

### Enabled

- **One store, two names.** `state_set target=world` and `state_set
  target=_engine` write to the same data. HUD `world.X` and HUD
  `_engine.X` bindings read the same data. Queries like `tags_all:
  ["_engine"]` work uniformly with every other entity query.
- **Saves come along for free** when `_engine` is added to
  `entity_tags_persistent` in `save_policy.json` (opt-in per game).
  Engine-flag persistence stops being a special-case schema field.
- **Debuggable.** Dumping `env.entities["_engine"].state` shows every
  engine flag in one place.
- **Reset, variant overlays, save-load merges** continue to work
  unchanged — they mutate the shared dict in place.

### What remains

- `world_state` field on `World.gd` stays as a public alias for
  `_engine.state`. Existing code reading `_world.world_state[...]`
  works unchanged. The field's docstring states the contract.
- Save schema is unchanged: `world_state` is still a top-level key in
  the save payload. Migration to entity-only persistence is a future
  ADR if/when needed.
- The convention "engine flags only — game state goes on a content
  singleton like `world_clock`" still holds. ADR 0047 doesn't change
  what *belongs* in `world_state`; it changes *where* `world_state`
  lives (a real entity, not an orphan Dictionary).

### Forbidden by the new structure

A content author can no longer write game state to `world_state`
without it appearing as `_engine.state` to entity queries. If `_engine`
shows up with `score=N` or `gold=N`, the gate flags it: those values
belong on a content singleton, not engine flags.

## Alternatives considered

### Replace `world_state` field entirely with `_engine.state` access

Cleaner in principle: drop the `world_state` field, force all code to
go through `entities["_engine"].state` (or `entity("_engine").state`).
~30 call sites across the engine to update; high churn, breaking
existing per-game saves (still need a migration anyway).

Rejected for **MVP — keep the shared-dict approach** which is a
no-behavior-change refactor with full backward compatibility. If the
field becomes confusing in a year, deprecate then.

### Use a sentinel ID like `"world"` instead of `"_engine"`

`tags_all: ["world"]` reads naturally but collides with the binding
prefix `world.X` and risks accidental query matches. `_engine` is
unambiguous and the leading underscore signals "engine-owned."

## References

- `.claude/rules/data-demo.md` § "world-state singleton pattern (no
  env.world_state queries)"
- `godot/scripts/engine/coordinators/world_boot.gd` —
  `_spawn_engine_entity()`
- `godot/scripts/engine/core/world.gd` — `world_state` field docstring

## Tech-director review

Accepted. Net engine LOC delta: +20 lines (1 WorldBoot phase + 1
docstring expansion). Zero call-site changes. 841 unit tests + 14
sokoban scenarios + aldenmere visual capture all clean. Save/load
unchanged (shared-dict approach preserves the world_state save key).

Invariants verified:
- #1 (JSON-only content channel): no engine-game leakage.
- #5 (queries first-class): `tags_all: ["_engine"]` works exactly
  like every other entity query.
- #8 (engine = primitives + interpreter): no new effect type, no
  new query operator. Just a new singleton entity that the engine
  auto-spawns.

Approved.
