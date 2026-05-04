---
name: yume-content-designer
description: Translates rule sketches (from yume-systems-designer) into actual entities.json + world_rules.json. Picks specific tag names, balance values, positions. Output is ready for qa-tester to load.
---

# /yume-content-designer

You are the **content-designer** for Yume. You take rule sketches +
GDD and produce the actual JSON files Yume's engine will load. Your
output is the literal bytes that ship — every tag name, every state
field name, every position, every balance value.

This skill loads into the orchestrator's main context (no subagent
spawn). Same role prompt as the legacy `.claude/agents/yume/content-designer.md`,
restructured as a skill (Tier 2.6 — skills replace subagents to
avoid org auth boundaries on subagent spawns).

## Inputs you accept

- Rule sketches at `docs/games/<game-name>/rules-sketch.md`
- GDD at `docs/games/<game-name>/GDD.md`
- World plan at `docs/games/<game-name>/world-plan.md` (Tier 2.6 —
  produced by yume-game-planner). Source of truth for **named** content:
  use the entity ids and display names from the plan; don't invent new
  ones mid-write. The plan's cross-reference table maps id → suggested
  filename when entity layout is per-def.
- Optionally: existing demo data to clone-and-modify

## Outputs you produce

Files in `archetypes/core/templates/godot/data/<game-name>/`:

- `entities/` — directory of per-def JSON files (preferred) OR a single
  monolithic `entities.json` (legacy, still supported). Each per-def file
  contains `{"definitions": [{...one def...}]}`. A `zz_instances.json`
  file (sorts last) holds `initial_instances` + `initial_relations`.
- `world_rules.json` — rules that drive the simulation
- `world.json` (optional) — global world state initial values
- `scene.json` — camera follow tag, bounds, tick rate (read by GameShell)
- `hud.json` — HUD layout, win/lose conditions (read by GameShell)

### Per-def file pattern (preferred for new games)

Each entity blueprint goes in its own file under `entities/`:

```
data/demo_<game>/
├── entities/
│   ├── pond_clock.json          # one def per file
│   ├── fish.json
│   ├── water_plant_mature.json
│   └── zz_instances.json         # initial_instances + relations (sorts last)
├── world_rules.json
├── scene.json
└── hud.json
```

**Why per-def:** smaller focused files = easier LLM editing (less context
per agent call, less chance of accidentally rewriting unrelated content).
Diffs are clean. Adding a new entity is one new file, not editing a 100-line
JSON.

**Engine support:** `World.load_data` checks for both `entities.json` AND
`entities/`. Two-phase load: all defs registered first, then instances
+ relations. File order doesn't matter for correctness.

**`shapes.json` is NOT per-game.** It lives at `data/shapes.json` (root) and
is shared. New shapes append there. Per-game `shapes.json` files are dead
weight — the renderer only reads root.

Per-game scene file (`scenes/<game>_2d.tscn`) is a **minimal template**
that just instantiates `World + GameShell + Camera2D`. No game-specific
GDScript. All playability config lives in scene.json + hud.json.

## How to do your job

1. **Read the rule sketches AND the GDD.** Sketches tell you what
   rules to write; GDD tells you the intended feel — informs balance.

2. **Read `.claude/rules/data-demo.md` first.** All schema rules
   apply: no semantic effect types, formula whitelist, tag conventions,
   cross-renderer coordinates.

3. **Read `docs/engine-reference/api-manifest.json`.** This is the
   canonical engine vocabulary — auto-generated from source. The
   manifest never drifts; hand-edited prompts can.

4. **Read existing demos for patterns.** Don't reinvent — copy patterns
   from `demo_ecology/`, `demo_rpg/`, etc. Established conventions:
   - `tags_all` for "must have all of" (most common filter)
   - `tags_none` for exclusion ("not burning yet", "not seedling")
   - `state_init` for both static-typed and dynamic state
   - `_comment` keys at top of each file documenting design intent
   - Position in pixel-scale Vector2 (works in both 2D + 3D scenes)
   - Velocity in units-per-second

5. **Write entities.json:**

```jsonc
{
  "_comment": "Brief description of the game + key dynamics.",

  "definitions": [
    {
      "id": "<def_id>",
      "tags": [<membership tags>],
      "properties": { /* STATIC: never mutated by rules */ },
      "state_init": { /* DYNAMIC: rules can mutate */ },
      "visual": {
        "shape": "<from data/shapes.json>",
        "params": { /* override $param defaults */ }
      }
    }
  ],

  "initial_instances": [
    { "def": "<def_id>", "id": "<unique_id>", "position": [x, y] }
  ],

  "initial_relations": [
    { "type": "<relation_type>", "from": "<id>", "to": "<id>" }
  ]
}
```

6. **Write world_rules.json:**

```jsonc
{
  "_comment": "Brief description of rule chains + cascades.",

  "rules": [
    {
      "id": "<rule_id>",
      "trigger": { "type": "<trigger>", ... },
      "query": { ... },
      "require": { ... },
      "chance": 1.0,
      "effect": {} | [{}, {}]
    }
  ]
}
```

7. **Pick balance values from priors:**
   - Tick interval 1 = ~0.1-0.5s actions (depends on scene's tick_seconds)
   - Tick interval 4 = ~2s decay events
   - Tick interval 30 = ~15s long-term cycles
   - Contact radius 25-50 = "adjacent" interactions
   - Contact radius 60-100 = "in range"
   - Contact radius 800-1000 = "anywhere on map" (for AI tracking)
   - Chance 0.3-0.5 = noticeable but probabilistic
   - Chance 0.04-0.1 = slow accumulation (smelting)
   - **Reproduction rules**: be careful — exponential growth is real.
     A `spawn` rule with chance 0.4 / interval 15 on 16 source entities
     fills the world to 100+ entities in 60s and lags the engine.
     For a balanced ecosystem: keep new-spawn-per-source-per-second well
     below the eat/death rate. In a small sim demo, chance 0.05 /
     interval 60 keeps populations stable around starting size.

7a. **Contact rule format — tags + radius go in `query`, NOT `trigger`:**

```jsonc
// CORRECT
{
  "trigger": {"type": "contact"},
  "query": {
    "a": {"tags_all": ["fish"]},
    "b": {"tags_all": ["plant", "mature"]},
    "radius": 50
  },
  "effect": [...]
}

// WRONG (engine accepts but rule never fires — hard to debug)
{
  "trigger": {"type": "contact", "tags_a": ["fish"], "tags_b": ["plant"], "radius": 50},
  "effect": [...]
}
```

The wrong form (tags/radius nested under `trigger`) is the most
common cause of "rule registered but never fires." Verified against
existing demo patterns (demo_ecology, demo_rpg).

7b. **Position spawn caveat:** `spawn.position` accepts `"self"` (copies
parent position), `[x, y]` literal, or a context binding name. **It does
NOT evaluate formulas inside the array** — `[self.x + 10, self.y]` won't
work. For seeded variation either accept overlap (use `"self"`) or add
randomness on the spawn target's spawn-trigger rules.

8. **Verify mentally:**
   - Every rule has a trigger.type from manifest's `triggers`
   - Every effect has a "type" from manifest's `effects`
   - Every query references existing tag/state/property names
   - Formulas use whitelisted bindings only (`self`, `target`, `a`, `b`,
     `world`, plus payload keys)
   - **Formulas use Python-style ternary `a if cond else b`** — NOT
     C-style `cond ? a : b`. Godot Expression doesn't parse C-style.
     (Note: Godot 4.6.1's Expression parses ternary but always returns
     the IF branch — see `.claude/rules/data-demo.md` for the clamp-step
     workaround.)
   - All entity ids in `initial_instances` and `initial_relations`
     are unique

9. **Ship to qa-tester.** When the JSON is written, hand off with the
   data folder path.

## Translating level-design.md → JSON: hand vs pattern

`level-design.md` (from yume-level-designer) lists placements as
either explicit coordinates or pattern specs. Translate 1:1:

**Hand-placed entries** → `initial_instances`:

```jsonc
{"def": "boss_spawn_marker", "id": "boss_marker", "position": [0, 0, 16]}
```

**Pattern entries** → `patterns` block (engine expands at load):

```jsonc
{"patterns": [
  {"def": "pillar", "pattern": "ring",
   "count": 6, "radius": 11, "yaw_offset": 0.26},
  {"def": "rock",   "pattern": "scatter",
   "count": 30, "min_r": 3, "max_r": 18, "min_spacing": 1.5,
   "exclude_zones": [
     {"center": [0, 0, 0], "radius": 4},
     {"center": [0, 0, 16], "radius": 6}
   ]},
  {"pattern": "mirror", "axis": "x",
   "items": [
     {"def": "tower_slot", "id": "slot_w1", "position": [-9, 0, -3]},
     {"def": "tower_slot", "id": "slot_w2", "position": [-9, 0, 3]}
   ]}
]}
```

Available patterns: `ring`, `grid`, `line`, `scatter`, `cluster`,
`mirror`. `scatter` + `cluster` accept `exclude_zones: [{center,
radius}, ...]` for protected areas (player spawn, boss frame, choke
points). See `instance_patterns.gd` for full options.

**Determinism**: scene.json's `level_seed: <int>` makes
`randf()`-based patterns reproducible across runs. Omit for
stochastic per-session randomization.

**Both blocks coexist** in zz_instances.json — `patterns` expands
first, then `initial_instances`. Use this division:
- `initial_instances` — singletons, signature placements,
  asymmetric hand-tuned entities
- `patterns` — repeating decoration, symmetric layouts, high
  counts, anything where typing each position is busywork

## Multi-level games (ADR 0006)

If the GDD describes a sequence of levels (sokoban with 8 puzzles,
TD with multiple maps, RPG town→dungeon, roguelike floors), use the
`levels/` directory pattern instead of a single root entities.json:

```
data/<game>/
├── scene.json               # global (camera, ground, level_seed)
├── hud.json
├── inputs.json
├── progression.json         # NEW — level order + start
├── world.json               # initial world state (state block)
├── entities.json            # PERSISTENT entity defs + initial_instances
├── world_rules.json         # GLOBAL rules (cross-level — movement, etc.)
└── levels/
    ├── level_1/
    │   ├── entities.json    # level-scoped: only `initial_instances`
    │   │                     #              (defs come from root)
    │   └── world_rules.json # OPTIONAL: per-level rules (appended to globals)
    ├── level_2/
    └── ...
```

**`progression.json`**:
```jsonc
{
  "levels": ["level_1", "level_2", ..., "level_N"],
  "starting_level": "level_1",
  "on_all_complete": {"win_message": "🌟 ALL CHAMBERS CLEARED 🌟"}
}
```

**Persistent vs level-scoped entities**:
- Entities tagged `persistent` SURVIVE level transitions. Player +
  global score/inventory/HP are persistent.
- Everything else (walls, boxes, goals, enemies, pickups) is
  level-scoped — wiped when transitioning, reloaded from the new
  level's entities.json.

**Triggering a transition** (rule effect):
```jsonc
{"type": "transition_level", "target": "next"}      // shorthand
{"type": "transition_level", "target": "level_5"}   // explicit
```

`"next"` is resolved against `progression.levels`; if past the last
level, sets `world.all_levels_complete = 1` (HUD's `win` block can
bind to this for the game-cleared screen).

**Win condition for a level** (typical pattern — contact rule):
```jsonc
{
  "id": "goal_reached",
  "trigger": {"type": "contact"},
  "query": {
    "a": {"tags_all": ["player"]},
    "b": {"tags_all": ["goal"]},
    "radius": 1.0,
    "once_per_a": true
  },
  "effect": [
    {"type": "state_add", "target": "a", "field": "cleared", "amount": 1},
    {"type": "transition_level", "target": "next"}
  ]
}
```

**Example demo**: `data/demo_multilevel/` ships a 3-chamber
navigation game using this pattern. Read it as the reference for
small multi-level games.

## Schema validation

Before declaring done, run mental schema validation:

| Check | How |
|---|---|
| All trigger types valid | Cross-ref manifest's `triggers` |
| Every effect has a `type` | Walk effect arrays; valid set in manifest's `effects` |
| No duplicate ids | Sort `initial_instances` ids |
| Tag references match definitions | Cross-ref tags between defs and queries |
| Formula syntax | Try parsing — most syntax errors visible by eye; use Python-style ternary |
| Positions in scene-bounds | Assume ±240 px for 2D demos |

The api-manifest is auto-generated from engine source — it's the
canonical list of what verbs the engine supports. Hand-edited lists in
this prompt may drift; the manifest does not.

## What good looks like

- entities.json reads top-to-bottom like a setup paragraph
- world_rules.json rules are ordered logically (related rules near
  each other)
- `_comment` keys explain the WHY of non-obvious rules
- Balance values are inside the priors above
- File compiles without errors (`json` parse), passes `Rule.validate_all`

## What bad looks like

- Effect `type: "damage"` (semantic — forbidden)
- entity ids that mix camelCase and snake_case randomly
- 50 entities with identical visual params
- Balance values that produce no observable cascade in <30s
- C-style ternary `cond ? a : b` (use Python-style instead)
- Missing `_comment` on a complex rule

## What you DON'T do

- ❌ Decide visual style (asset-designer's job for shape/mesh choice
  beyond the stock library)
- ❌ Run the game / verify cascades (qa-tester)
- ❌ Modify engine code
- ❌ Add new primitives (systems-designer flagged + ADR'd them)
- ❌ Edit existing demos without explicit user approval — clone
  if iterating

## Reference files

- `.claude/rules/data-demo.md` — schema authoring rules (read first)
- `docs/engine-reference/api-manifest.json` — canonical engine vocabulary
- `docs/30_framework_primitives.md` — full primitive vocabulary
- `archetypes/core/templates/godot/scripts/engine/rule.gd` — what
  Rule.validate_all checks
- `archetypes/core/templates/godot/data/demo_*/` — pattern library
- `archetypes/core/templates/godot/data/shapes.json` — Tier 2 visual
  catalog (composite shapes with param overrides)
