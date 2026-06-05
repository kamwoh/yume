# ADR 0006 — Multi-level architecture

_Date: 2026-05-04_
_Status: accepted_

## Context

Yume's data-driven simulation has, until now, treated each game as
**one map**. `data/<game>/` contains entities + rules + scene config
+ instances; the engine loads it all at startup; the simulation runs
in that one world. This works for arena-style games (doomarena3d,
fpsgarden) and small simulations (tinypond, harvestcore).

It doesn't work for **multi-level games**. Sokoban's GDD specifies
8 hand-designed puzzles; a TD might want a sequence of maps; an RPG
needs town → dungeon → boss-arena progression; a roguelike has
floors. None of these can be expressed in a single-map data folder.

The lack has been visible: sokoban's GDD + level-design.md have been
in `docs/games/sokoban/` since 2026-05-02 with no implementation,
because Yume's engine couldn't host the 8-level structure.

## Decision

Add **levels-as-data-subfolders** to the engine surface. New
conventions:

```
data/<game>/
├── scene.json                  # global (camera, ground, hud, level_seed)
├── hud.json                    # global UI
├── inputs.json                 # global input bindings
├── progression.json            # NEW — level order + start
├── persistent_entities.json    # NEW (optional) — entities surviving transitions
└── levels/                     # NEW — each subfolder is one level
    ├── level_1/
    │   ├── entities.json       # level-scoped entity defs
    │   ├── zz_instances.json   # per-level placements
    │   └── world_rules.json    # level-specific rules (or omit for inherited)
    ├── level_2/
    └── ...
```

Plus engine additions:

1. **New effect type**: `transition_level`
   ```jsonc
   {"type": "transition_level", "target": "level_2"}
   {"type": "transition_level", "target": "next"}    // shorthand
   ```
   Sets `env._pending_level_transition` to the target name. The
   engine processes the transition AFTER the current rule's effects
   complete (between ticks) so the simulation isn't mid-mutation.

2. **New world state**: `world.current_level` — string name of the
   active level. Available in formulas via `world.current_level`.
   Set by the engine on transition.

3. **Persistent vs level-scoped split**: entities tagged
   `persistent` survive level transitions. Everything else gets
   removed. Convention: player + score/inventory entities tag
   themselves persistent; all level content (boxes, goals, walls,
   enemies, pickups) is level-scoped (default).

4. **`progression.json` schema**:
   ```jsonc
   {
     "_comment": "Level progression for sokoban-style games",
     "levels": ["level_1", "level_2", "level_3", ..., "level_8"],
     "starting_level": "level_1",
     "on_all_complete": {
       "win_message": "🌟 ALL CHAMBERS CLEARED 🌟"
     }
   }
   ```
   `levels` declares order; `starting_level` is where the game
   begins; `on_all_complete` is the message shown if the player
   transitions PAST the last level (game won).

5. **Backwards-compatibility**: games without `progression.json`
   load as single-level (existing behavior). Adding multi-level is
   opt-in.

## Engine flow

### World load (initial)

```
1. Read scene.json, hud.json, inputs.json (globals — same as before)
2. If progression.json exists:
   - Load level order, set world.current_level = starting_level
   - Load persistent_entities.json if present (entities flagged persistent)
   - Load levels/<starting_level>/ as the active level
   Else:
     # Backwards-compatible single-level game
     Load entities.json + world_rules.json + zz_instances.json from root
3. Continue normal world startup
```

### Level transition

```
When env._pending_level_transition is set (e.g. "level_2") at end
of tick:
1. For each entity in world.entities:
   - If has tag "persistent": keep
   - Else: remove (relations.clear_entity, spatial_index.remove,
     entities.erase, queue_free)
2. Reset rules (clear scheduler, re-load level world_rules)
3. Load new level's entities/zz_instances.json
4. world.current_level = new_level_name
5. Emit signal "level_loaded" with new level name
6. Clear env._pending_level_transition
```

### "next" shorthand

When `transition_level` target is "next":
- Engine looks up world.current_level in progression.levels
- target = next entry; if at end, fires "all-complete" path
  (e.g. shows win screen, no further transition)

## Consequences

**Enables:**
- Sokoban (8 puzzles) — finally can ship.
- TD games with sequential maps.
- RPG town → dungeon flow.
- Roguelike floor progression.
- Linear FPS missions.
- Any game where "level" is a meaningful concept.

**Costs:**
- Per-game file count grows (one game = multiple level subfolders).
  Mitigation: small games keep root-folder pattern; multi-level is
  opt-in.
- Authoring complexity (per-level entities + transition rules).
  Mitigation: skills updated to handle the levels/ pattern.
- State management split: persistent vs level-scoped is a contract
  the content author has to follow. Mitigation: documented in
  data-demo rule + content-designer skill; default is "everything
  level-scoped" so omitting the persistent tag = safe.
- Transition tick has a small pause (entity teardown + new level
  load). Acceptable for puzzle/RPG/roguelike; maybe not for
  fast-paced FPS (but FPS games are typically single-arena anyway).

**Updates needed:**
- `effect_apply.gd` — add transition_level effect dispatch.
- `world.gd` — extend load_data + add _process_pending_transition.
- `entity.gd` — no change (tags already drive everything).
- `docs/guideline/30_framework_primitives.md` — document the convention.
- `.claude/rules/data-demo.md` — multi-level authoring rules.
- `.claude/skills/yume-content-designer/SKILL.md` — translation
  guide.
- `.claude/skills/yume-design/SKILL.md` — pipeline notes about
  multi-level games.
- Tests: scenario tests for level transitions (sokoban serves as
  the integration test).

## Alternatives considered

**A) Levels as separate Godot scenes.** `change_scene_to_file()` for
each level. Pros: native Godot. Cons: reloads renderer + camera per
transition (jarring); hostile to Yume's data-driven philosophy
(scene structure becomes per-game code instead of JSON); persistent
state needs an autoload to survive scene swaps. Rejected.

**B) Levels as world.json variants.** A "reset world to level N"
command that wipes everything and re-loads. Pros: simple. Cons: no
persistent state mechanism; player progress dies between levels.
Rejected — persistent state is fundamental.

**C) Single-map with content-swap rules.** Use rule effects to
spawn/remove entire level configurations within one ongoing world.
Pros: no engine change. Cons: massive rule complexity per level;
entities/rules don't cleanly separate; hits scheduler limits;
authors hate writing level-as-rules. Rejected.

**D) Defer entirely.** Sokoban stays unimplemented; multi-level
genres (RPG, roguelike) are out of scope. Cost: Yume's coverage of
the "simulation-shaped games" claim is incomplete. Rejected — the
genre coverage promise needs multi-level support.

## Implementation sketch (~150 lines + tests)

```gdscript
# world.gd additions

var current_level: String = ""
var level_order: Array = []
var levels_root: String = ""
var _pending_level_transition: String = ""

func load_data() -> void:
    var root := data_root.rstrip("/")
    # ... existing input/seed/ground setup ...
    var prog_path = root + "/progression.json"
    if FileAccess.file_exists(prog_path):
        _load_progression(prog_path)
        levels_root = root + "/levels"
        # Load globals (no level-scoped content yet)
        _load_persistent_entities(root)
        # Load starting level
        if current_level != "":
            _load_level(current_level)
    else:
        # Single-level (backwards-compatible)
        _load_rules_file(root + "/world_rules.json")
        _load_world_file(root + "/world.json")
        _load_entities_path(root)
    scheduler.flush_effects()

func _process(delta: float) -> void:
    # ... existing tick, motion ...
    if _pending_level_transition != "":
        _do_level_transition(_pending_level_transition)
        _pending_level_transition = ""

func _do_level_transition(target: String) -> void:
    # Resolve "next" shorthand
    if target == "next":
        var idx = level_order.find(current_level)
        if idx >= 0 and idx + 1 < level_order.size():
            target = level_order[idx + 1]
        else:
            _emit_all_levels_complete()
            return
    # Remove non-persistent entities
    var to_remove: Array[String] = []
    for id in entities.keys():
        var ent = entities[id]
        if ent is Entity and not (ent as Entity).has_tag("persistent"):
            to_remove.append(id)
    for id in to_remove: _remove_entity(id)
    # Reload rules + content for new level
    scheduler.clear_rules()
    var lvl_dir = levels_root + "/" + target
    _load_rules_file(lvl_dir + "/world_rules.json")
    _load_entities_path(lvl_dir)
    current_level = target
    world_state["current_level"] = target
    scheduler.flush_effects()
    if verbose: print("[World] transitioned to level: ", target)
```

```gdscript
# effect_apply.gd additions

static func _transition_level(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
    var target := str(_value(e.get("target", "next"), ctx, env))
    if target == "": return
    env["_pending_level_transition"] = target
```

## Future extensions (not in this ADR)

- **Level metadata**: per-level title, par-move count, hints — stored in
  `levels/<name>/level_meta.json`. Loadable for HUD display.
- **Level state in save**: which levels are completed. Persists
  across game sessions via user:// save file.
- **Branching progression**: progression.json with conditional
  transitions ("if score ≥ 100, go to bonus level"). v1 keeps it
  linear; ADR for non-linear can come later.
- **Mid-level checkpoints**: save state inside a level. Defer.

These compose on top of the v1 multi-level engine surface.
