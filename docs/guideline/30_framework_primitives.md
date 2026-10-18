# Yume Framework — Universal Primitives

_Last updated: 2026-10-18 (ADR 0086 phase 5: three layers, two behavior classes)_

## Purpose

This is the Yume spec: the contract that every interpreter implements. It
defines **seven primitives** such that any simulation-shaped game (ecology,
farming, shooter, RPG, survival, tower-defense, roguelike, puzzle-with-state,
chess) can be expressed as JSON. The Godot interpreter in
`godot/scripts/engine/` is the reference implementation (ADR 0086). No
genre-specific interpreter code.

> **Authoring note (2026-05-17, ADR 0051):** JSON remains canonical
> — the engine reads it authoritatively. As of 2026-05-17 there are
> also two **optional** Python-side emitters:
>
> - `tools/yume_codegen/` — typed builders that emit the same rule /
>   entity / screen JSON dicts you'd hand-write. Catches recurring
>   bug classes (brace-wrapped bindings, wrong context-binding names)
>   at author time via `TypeError`/`ValueError`.
> - `tools/yume_assetgen/` — texture + mesh generation pipeline.
>   Reads `*_prompt` fields from entity defs, dispatches to a
>   configured backend (mock today; OpenAI Images / Stable Diffusion
>   / Tripo3D planned), writes output to
>   `data/<game>/assets/textures/` + `.../meshes/`, then patches the
>   entity def with the resolved asset path. An asset path is relative
>   to the game folder, or starts with `@lib/` (ADR 0087).
>
> Both are emitters of canonical JSON / asset files; the engine
> never sees Python. Hand-authoring keeps working unchanged.

## Architectural framing (ADR 0086, 2026-10-18)

Yume is a **host-neutral JSON spec**. Godot runs it today, but a game
depends on the spec, not on Godot.

### Three layers

| Layer | Owns | Today |
|---|---|---|
| **Spec** | The JSON format and what each field means. This document is its contract. | `world/rules/*.json`, `scene.json`, `screens.json`, `tests.json` |
| **Interpreter** | Reads the spec and drives one host. | `godot/scripts/engine/*.gd` (the reference interpreter) |
| **Host** | Rendering, physics, audio, input, UI. | Godot 4.6.1 |

- **Game content** is pure spec JSON: entities, rules, layouts,
  physics, animation, narrative, economy, dialog. Authors write only
  JSON.
- **An interpreter** exposes its host's capabilities through the spec.
  ADR 0021 still applies inside each interpreter: expose the host's
  physics, UI and audio, and never reimplement them.
- **External tools** (via IPC, ADR 0020 pattern) such as LLMs, RL agents
  and solvers stay outside the spec. The interpreter orchestrates them.
- Where the spec is silent, the Godot interpreter's behavior is the
  answer for now. `docs/engine-reference/host-coupling-audit.md` lists
  each such case until the spec defines it.

### The spec names no host (ADR 0086 rule 3)

A spec field must not contain:

- a Godot class, node, property or enum name,
- a `res://` or `user://` path (asset paths: ADR 0087),
- a Godot-only file format: `.gdshader`, `.tres` or `.tscn` (ADR 0089).

Each field describes intent in host-free words. A closed list in the
spec replaces each host table:

- the formula functions (ADR 0088),
- the named shaders (ADR 0089),
- the key names, audio channels, lighting fields and physics names
  (ADR 0090, §Spec vocabularies).

`validate_host_neutral.py` enforces this rule.

### Two behavior classes

Each behavior is either exact or host-defined.

| Class | Behaviors | What every interpreter must do |
|---|---|---|
| **Exact** | Rule order, effect order, the tick phases (§Tick ordering), queries, formulas, state, relations, the calendar clock, UI structure and screen flow. | Give the same result from the same input. |
| **Host-defined** | Physics results, pathfinding routes, rendering, shader output, audio mixing. | Honor the inputs and the stated guarantees. The exact numbers belong to the host. |

A guarantee is a sentence in this document that a host-defined behavior
must keep. Two examples:

- A `static` body never moves, and it blocks each body whose mask
  includes its layer (§Spec vocabularies).
- Each shader parameter changes the look in the direction its name
  says (§Shaders).

### Conformance

`tests.json` scenarios are the conformance suite. They use only neutral
steps (`press <action>`, `tick N`, `expect` on entity fields). Every
interpreter must pass them. Two rules keep them portable:

- A new step verb must be neutral, by rule 3.
- A test must not assert an exact value of a host-defined behavior. It
  asserts the guarantee instead, for example "the bullet stopped at the
  wall", not "the bullet stopped at x = 4.73".

Two questions stay open (ADR 0086):

- Does the spec define one seeded random generator for conformance?
- Does body motion have an exact place in the phase order of a tick?

**Invariants** — non-negotiable design constraints:

1. **JSON is the only content channel.** Adding an entity, rule, formula, tag,
   or property = 1 JSON edit. Never a GD edit.
2. **No semantic effect types.** No `damage`, `need_decay`, `heal`, `gain_xp`.
   These are all `state_add` with different field names. Semantics live in
   content, not engine.
3. **No entity-class hierarchy.** No `Agent` vs `Item` vs `Projectile`. Everything
   is `Entity`. Distinctions emerge from tags and property combinations.
4. **Rules compose.** Complex behavior = many small rules, not one big rule.
5. **Queries are first-class.** Any rule can ask "who matches X property within
   distance Y?" — same query system everywhere.
6. **Formulas everywhere.** Any numeric field in any rule can be a string
   expression evaluated against bindings.
7. **Relations are first-class.** Inventory, ownership, containment, parent/child,
   party membership are typed directed edges between entities — queryable,
   mutatable, traversable in formulas. Never a dict-in-state.
8. **Engine = primitives + interpreter.** This generalizes invariants 1, 2, 4.
   For every domain Yume touches — rules, shapes, audio, asset binding, AI
   prompts — the engine ships a **fixed primitive vocabulary** (effect types,
   draw operations, audio operations, query operators, formula helpers). All
   **compositions** of those primitives — specific rules, specific shapes,
   specific bindings — live in JSON. Adding a new vocabulary item should
   require new engine code; adding a new composition should require only JSON.
   This is the same insight the Environment Maps paper applies to agent
   memory: structured representations beat hardcoded behavior — they're
   queryable, editable, and incrementally refinable.

   | Domain | Engine primitives (code) | JSON composition |
   |---|---|---|
   | Rules | `state_set`, `state_add`, `spawn`, `relate`, `transform`, ... | `world_rules.json` |
   | Shapes | `circle`, `rect`, `polygon`, `line`, `text`, `texture` | `shapes.json` |
   | Audio | `play`, `loop`, `fade`, `stop` | `audio_catalog.json` |
   | Asset binding | (none — pure data lookup) | `asset_catalog.json` |
   | Formulas | math helpers, query helpers | inline strings on rules |

   When adding a new layer (e.g., animation in Tier 4): identify its primitive
   vocabulary, ship that in code, push everything else into JSON. If a layer
   resists this split, that's a sign the layer is wrong — re-decompose.

---

## The Seven Primitives

### 1. Entity

Anything in the world. The only node type.

```json
{
  "id": "oak_log",                    // unique definition id
  "properties": {                     // STATIC typed values (never mutate)
    "material": "wood",
    "hardness": 3,
    "flammable": true,
    "mass": 8,
    "edged": false
  },
  "state_init": {                     // DYNAMIC state (mutable via rules)
    "temperature": 20.0,
    "wet": 0.0,
    "burning": 0,
    "durability": 1.0,
    "age": 0
  },
  "tags": ["choppable", "solid"],     // membership groups for queries
  "visual": {                         // renderer-specific — 2D/3D reads this
    "sprite_2d": "oak_log.png",
    "model_3d": "oak_log.glb"
  }
}
```

**Reserved state fields** (engine-recognized, not hardcoded):
- `position` — Vector2 in sim space (managed by engine)
- `velocity` — Vector2 (applied each tick by motion rule)
- `age` — increments each tick (convention, not forced)

All other state field names are **user-defined**. "hp", "hunger", "ammo",
"mood", "fuel", "ripeness" — equal citizens.

### 2. Tag

Named membership. Purely additive. No hierarchy, no inheritance.

```json
"tags": ["flammable", "choppable", "pickable"]
```

Queries match tags. Same primitive used for RPG groups (`enemy`, `party`),
ecology roles (`predator`, `plant`), item kinds (`weapon`, `tool`).

**Not the same as properties.** A tag is a boolean membership. A property is a
typed value. `flammable: true` as a property implies a numeric ignition
threshold elsewhere; `"flammable"` as a tag is a simple membership query.
Use properties when numeric; tags when categorical.

**Engine-recognized tags** (small, deliberately-curated list — most tags are
content-defined, but these have engine-side semantics):

| Tag | Effect | Required companion |
|---|---|---|
| `blocks_motion` | Static obstacle. Motion integrator slides moving entities around its AABB; projectile-tagged entities stop dead at the boundary. | `properties.aabb_extents: [hx, hy, hz]` (and optional `aabb_offset`) |
| `projectile` | Different motion-resolution path: no slide on collision (stop dead). Used by motion integrator to distinguish bullets from creatures. | None (just the tag) |
| `walkable_floor` | Contributes a walkable rectangle to the level's NavigationMesh (ADR 0024). NPCs invoking `pathfind_to` route over the union of these rectangles. | `properties.aabb_extents: [hx, _, hz]` (Y ignored — floor at `position.y`) |
| `pathfinding_obstacle` | Punches a hole in the walkable region (ADR 0024). Distinct from `blocks_motion`: a wall typically wants both, but a low fence might want one or the other. | `properties.aabb_extents: [hx, _, hz]` |

Adding to this list is ADR-gated. See `docs/adr/0004-blocks-motion-tag.md`,
`docs/adr/0024-npc-pathfinding.md`. ADR 0085 (2026-10-16) deleted the
`party_member` tag with the party effects (ADR 0026), because no game used
them.

**Engine-recognized scene config** (in `scene.json`):

| Block | Effect |
|---|---|
| `ground` | `{y, clamp_tags, despawn_tags}`. Each frame after motion integration, entities matching `clamp_tags` get Y-clamped to `y`; entities matching `despawn_tags` are removed if Y < `y`. Defaults: clamp_tags=["creature"], despawn_tags=["projectile"]. Replaces per-game creature_bounds + projectile_floor_despawn content rules. |
| `level_seed` | Integer applied to Godot's global PRNG at world load. Makes `randf()`-driven instance patterns (scatter / cluster) deterministic across sessions — same seed = same map. Omit for stochastic randomization. |
| `lighting` | Optional. `{directional_light, ambient, sky}` — each sub-block optional. Drives a `DirectionalLight3D` + `WorldEnvironment` from a bound state field (default `world_clock.time_of_day` on a 0.0–24.0 hour scale). Sun rotation, light color/energy, ambient color/energy, and sky horizon colors interpolate per-frame. Omit to keep static lighting (2D demos and existing 3D scenes). See ADR 0025. |

**Declarative placement patterns** (in `entities.json` /
`zz_instances.json` `patterns` block — Tier 2.6q + v2.6):

```jsonc
{"patterns": [
  {"def": "pillar", "pattern": "ring", "count": 6, "radius": 11},
  {"def": "rock",   "pattern": "scatter", "count": 20,
   "min_r": 3, "max_r": 18, "min_spacing": 1.5,
   "exclude_zones": [{"center": [0,0,0], "radius": 4}]},
  {"pattern": "mirror", "axis": "x", "items": [...]}
]}
```

Patterns expand at load into the same `_spawn_initial` path as
hand-coded `initial_instances`. Primitives: `ring`, `grid`, `line`,
`scatter`, `cluster`, `mirror`. `scatter` + `cluster` accept
`exclude_zones`.

**Hitscan effect** (added by ADR 0005):

```jsonc
{
  "type": "raycast_hit",
  "origin": [<x>, <y>, <z>],          // formula or array
  "direction": [<dx>, <dy>, <dz>],    // formula or array (need not be unit)
  "max_distance": 30.0,
  "tags_all": ["monster"],            // entity must match these
  "tags_none": ["dead"],              // entity must NOT match
  "respect_obstacles": true,          // ray tests blocks_motion AABBs
  "on_hit": [...effect list...],      // `hit` binds to entity id; `hit_point` to Vector3
  "on_miss": [...effect list...]      // `hit_point` binds to ray endpoint
}
```

Use for instant-hit weapons (rifles, lasers, sniper) and AI line-of-sight
checks. Pairs with `spawn` (use spawn for slow visible projectiles, raycast
for hitscan-feeling weapons).

**Pathfinding effect** (added by ADR 0024):

```jsonc
{
  "type": "pathfind_to",
  "target": "self",
  "destination_x": <float|formula>,    // e.g. "self.state.goal_x"
  "destination_y": <float|formula>,
  "destination_z": <float|formula>,
  "speed": <float|formula>             // m/s along the path
}
```

Each invocation lazily attaches a `NavigationAgent3D` to the target,
sets its `target_position`, reads the next path waypoint, and writes
a velocity pointing at that waypoint. The motion integrator advances
the entity along that velocity on the same tick. Build the navmesh
by tagging floor entities `walkable_floor` and obstacle entities
`pathfinding_obstacle` (the engine assembles the mesh on level
load). Per ADR 0024, 3D-only — no-op for Vector2-positioned entities.

Use for NPC schedules, escort missions, A → B sim agents, or any
case where straight-line + AABB-slide deadlocks in concave geometry.

### 3. Rule

The only behavior primitive.

```json
{
  "id": "fire_spreads",
  "trigger": {"type": "contact", "interval": 2},
  "query": {
    "a": {"properties": {"burning": 1}},
    "b": {"properties": {"flammable": true, "wet_lt": 0.3, "burning": 0}},
    "radius": 1.5
  },
  "chance": 0.3,
  "effect": {
    "type": "state_set",
    "target": "b",
    "field": "burning",
    "value": 1
  }
}
```

A rule is `{id, trigger, query, require?, chance?, effect, scope?}`. Universal shape.

**`require` clause** (added after W0 spike, chess demo). Validates
context-bound entities (from `input`/`signal`/`relation_changed` payloads)
against query specs. Rule fires only if every required entity exists AND
matches its spec. Without this, rules carrying entity references in their
payloads can't filter on those entities' properties — e.g. a chess `move`
input could be matched by either color's rule because the pivot query
(the game-state entity) cannot see into the payload.

```json
{
  "trigger": {"type": "input", "action": "move"},
  "query": {"tags_all": ["game_state"], "state": {"turn_eq": "white"}},
  "require": {
    "piece": {"tags_all": ["white", "piece"]},
    "from_sq": {"tags_all": ["square"]},
    "to_sq": {"tags_all": ["square"]}
  },
  "effect": [ "..." ]
}
```

`require` is the non-spatial analog of contact's `a`/`b` pair matching.

### 4. Trigger

When a rule evaluates.

| Trigger | Meaning | When to use |
|---|---|---|
| `tick` | Every N clock ticks (fixed sim rate) | Decay, growth, periodic checks |
| `frame_tick` | Every rendered frame (display rate, not sim rate — ADR 0050) | Per-frame visuals, camera-coupled logic |
| `contact` | Pair of entities within radius | Fire spread, collision damage, reactions |
| `signal` | Named broadcast fired by another rule or input | Phase changes, chained events, turn-based |
| `input` | Engine input action name | Player control, UI buttons |
| `spawn` / `despawn` | Entity lifecycle | Setup effects, cleanup |
| `relation_changed` | Edge added/removed matching pattern | Equip-on-pickup, unbind-on-drop, containment reactions |
| `scheduled` | Absolute time — in `VALID_TRIGGERS` but **no dispatcher yet** (validates, never fires) | (reserved — schedule director uses its own path) |

All triggers route through the same `Rule.evaluate()` — only the dispatcher
differs. No special handling per trigger type in effect code.

### 5. Effect

What a rule does when it fires.

| Effect | Does |
|---|---|
| `state_set` | Set a state field to a value/formula |
| `state_add` | Add to a state field (neg = subtract) |
| `state_mul` | Multiply a state field |
| `state_clamp` | Clamp field to `[min, max]` |
| `spawn` | Create new entity by template id, at `position_formula` |
| `remove` | Delete entity |
| `transform` | Replace entity with another template id, preserving position + merged state |
| `relate` | Create a relation edge `{type, from, to}` (see §7) |
| `unrelate` | Remove relation edge(s) matching pattern |
| `transfer_relation` | Change one endpoint of an edge (move item between holders) |
| `velocity_set` | Set motion vector (universal — player move, projectile, knockback) |
| `emit` | Broadcast a signal with payload (triggers `signal` rules) |
| `tag_add` / `tag_remove` | Mutate tag membership |

**Deleted** (from current engine): `damage`, `need_decay`, `need_restore`,
`advance_stage`. Each is expressible as `state_add` + semantic naming in JSON.

### 6. Query

Reusable match expression. Used in `Rule.query`, in effects that need targets,
and in formula `self.nearby(...)`.

```json
{
  "properties": {"material": "wood", "hardness_atleast": 2},
  "tags_any": ["choppable", "burnable"],
  "tags_all": ["solid"],
  "tags_none": ["enchanted"],
  "state": {"burning_eq": 0, "wet_lt": 0.5},
  "radius": 3.0,            // implicit: around caller
  "limit": 5,
  "order_by": "distance_asc"
}
```

Supported operators: `_eq`, `_ne`, `_gt`, `_lt`, `_gte`, `_lte`, `_atleast`,
`_atmost`. Missing property or state field = no match (strict).

Tag clauses: `tags_all` (must have all), `tags_any` (must have at least one),
`tags_none` (must have none).

Identity clauses (ADR 0060): `id` (match one specific instance id) and `ids`
(match any id in a set). Generic — rules should prefer tags over hardcoded ids
(see `.claude/rules/data-demo.md`), but the primitive is needed for by-id test
assertions and id-addressed effect targets.

Queries can also filter by **relations** (see §7): `{relations: {held_by:
self}}` matches entities currently `held_by` the caller; `{relations: {part_of:
{tag: "house"}}}` matches entities `part_of` any entity tagged `house`.

Queries are **declarative**. Engine chooses spatial index / scan strategy.

### 7. Relation

A typed directed edge between two entities. The mechanism for inventory,
ownership, containment, parent/child, party membership, and any "X is
associated with Y" structure.

```json
{"type": "held_by",   "from": "sword_abc123", "to": "player_xyz"}
{"type": "contains",  "from": "chest_42",     "to": "gold_coin_9"}
{"type": "part_of",   "from": "door_1",       "to": "house_alpha"}
{"type": "member_of", "from": "hero_a",       "to": "party_1"}
{"type": "on_square", "from": "knight_w",     "to": "e4"}
```

Relation **types are user-defined**. Engine treats them all identically —
`held_by`, `contains`, `part_of`, `owned_by`, `member_of`, `on_square` are
just strings. No hardcoded relation semantics.

Storage is a relation store (directed multigraph). Indexed by `(type, from)`
and `(type, to)` for O(1) lookup in both directions.

**Query integration.** Queries gain a `relations` clause:

```json
{"relations": {"held_by": "self"}}                       // things self holds
{"relations": {"part_of": {"tag": "house"}}}             // things part_of a house
{"relations": {"on_square": {"properties": {"color": "white"}}}}
```

**Edge state** (ADR 0075). Every edge carries an optional `state` dict — the
fourth state scope, alongside `entity.state`, `zone.state` (ADR 0031), and
`world_state` (ADR 0047). It makes a weighted graph expressible: a
relationship strength, a stack quantity, a per-pair price or distance.

```json
{"type": "relate", "relation": "knows", "from": "a", "to": "b",
 "state": {"trust": 10}}
```

Re-relating an existing edge MERGES `state` instead of no-op'ing, so an edge
can be created and seeded in either order. Edge state dies with its edge and
travels with it through `transfer_relation`.

Three effects mutate it, named and shaped identically to the `state_*` and
`zone_state_*` families (`amount`, never `delta`; `min`/`max`):

```json
{"type": "relation_set",   "relation": "knows", "from": "a", "to": "b", "field": "trust", "value": 50}
{"type": "relation_add",   "relation": "knows", "from": "a", "to": "b", "field": "trust", "amount": 15}
{"type": "relation_clamp", "relation": "knows", "from": "a", "to": "b", "field": "trust", "min": 0, "max": 100}
```

All three are no-ops on a missing edge — they never create graph structure.
Creation stays `relate`'s job.

Queries filter on it via the reserved `_edge` key inside the dict form. `_edge`
constrains the EDGE; every other key stays the nested entity query:

```json
{"relations": {"knows": {"_edge": {"trust_gte": 60}, "tags_all": ["merchant"]}}}
```

Both must hold for the SAME edge. Absent `_edge`, behaviour is unchanged.

**Effect integration.** Three new effect types:

| Effect | Does |
|---|---|
| `relate` | Create edge `{type, from, to}` |
| `unrelate` | Remove edge(s) matching `{type, from?, to?}` |
| `transfer_relation` | Change one endpoint of an edge (e.g. move item between holders) |

Dropping an item from the player becomes:

```json
"effect": [
  {"type": "unrelate", "relation": "held_by", "from": "target", "to": "source"},
  {"type": "state_set", "target": "target", "field": "position",
   "value": "source.state.position"}
]
```

**Formula integration.** Formulas traverse relations:

```json
"amount": "self.held_by.state.strength * 2"     // item uses holder's strength
"chance": "self.part_of.state.integrity / 100"  // door's chance depends on house
"value": "self.contains.count"                   // how many items a chest holds
```

Multi-valued traversals (`self.contains`, `self.parent_of`) expose `.count`,
`.first`, `.list`, and aggregates `.sum(field)`, `.avg(field)`, `.max(field)`,
`.min(field)`.

**Trigger integration.** New trigger `relation_changed`:

```json
{
  "trigger": {"type": "relation_changed", "relation": "held_by",
              "event": "added"},   // or "removed"
  "query": {"tags_all": ["weapon"]},
  "effect": {"type": "state_set", "target": "self",
             "field": "equipped_since", "value": "world.tick"}
}
```

### Formula (sub-primitive)

Any number in rule JSON can be a string expression.

```json
"time_formula": "1.0 + target.properties.hardness * 0.5",
"amount": "-(source.state.temperature - 100) * 0.1",
"chance": "clamp(world.wind_speed / 10, 0.1, 0.9)"
```

**Bindings (complete list):**
- `self.*` — entity the rule is scoped to
- `source.*`, `target.*`, `a.*`, `b.*` — rule-specific roles
- `world.*` — global state (`world.tick`, `world.time_of_day`, `world.weather`, ...)
- `self.<relation>` — relation traversal (see §7): `self.held_by`,
  `self.contains`, `self.part_of`, `self.parent_of.state.hp`
- ⚠️ `self.nearest({...})` / `self.nearby({...})` — spatial formula helpers
  are **NOT yet implemented**. For pair-matching, use a `contact` trigger
  with `query: {a, b, radius}` instead (see `.claude/rules/data-demo.md`).

A missing field reads as `0`. A formula that is only a binding returns the
bound value unchanged, for example `self.id`.

#### Formula language (ADR 0088)

The formula language is part of the spec (ADR 0086). Every interpreter
must give the same result for the same formula.

**Numbers.** Every number is a float: literals, bound values and results.
`5 / 2` gives `2.5`, and `-7 / 2` gives `-3.5`. Division by zero follows
IEEE 754. An index uses the integer part of its value, so `a[1.7]` reads
`a[1]`.

**Booleans.** A comparison gives a boolean. `and`, `or` and `not` take
booleans. Arithmetic on a boolean is an error. `float(b)` gives `1.0` or
`0.0`.

**Grammar.**

```
formula  := or
or       := and ("or" and)*
and      := not ("and" not)*
not      := "not" not | compare
compare  := sum (("==" | "!=" | "<" | "<=" | ">" | ">=") sum)?
sum      := product (("+" | "-") product)*
product  := unary (("*" | "/") unary)*
unary    := "-" unary | "+" unary | atom
atom     := number | "true" | "false" | binding subscript*
          | function "(" args? ")" | "(" formula ")"
args     := formula ("," formula)*
binding  := root ("." field)+
```

Not in the language: `%`, `**`, string literals, method calls,
constructors, array literals, `&&`, `||`, `!`, bitwise operators and the
ternary `a if cond else b`. Write a choice as `b + (a - b) * float(cond)`.

**Functions.** A new function needs an ADR.

| Function | Result |
|---|---|
| `abs(x)` | absolute value |
| `floor(x)`, `ceil(x)`, `round(x)` | nearest whole number, as a float. `round` rounds a half away from zero. |
| `min(a, b)`, `max(a, b)` | the smaller or the larger value |
| `clamp(x, lo, hi)` | `x` limited to the range `lo` to `hi` |
| `lerp(a, b, t)` | `a + (b - a) * t` |
| `sqrt(x)`, `pow(x, y)` | square root and power |
| `sin(x)`, `cos(x)`, `tan(x)` | trigonometry in radians |
| `atan2(y, x)` | the angle of the point (x, y), in radians |
| `randf()` | a uniform random number from 0 to 1, without 1 |
| `float(x)` | a boolean as `1.0` or `0.0`, or a number unchanged |

**Enforcement.** `Formula.FUNCTIONS` in `formula.gd` is the one list.
`Formula` checks each formula token by token before Godot's `Expression`
parses it. A call to another name fails with `formula.unknown_function`.
Any other construct outside the grammar fails with `formula.parse_failed`.
`validate_rules.py` check (12) applies the same rules before the game
runs. Formula caches each parsed expression, so it parses no formula
again per tick.

**Perf note.** Formulas inside `contact` triggers evaluate **per candidate
pair per tick**. With 500 pairs/tick on a busy scene, that is 30 000 evals/s.
Parsed-expression caching is mandatory. Formula micro-benchmarks land in W4.

### Shaders (ADR 0089)

A visual block can name a shader: `lighting.sky.shader`,
`ground.mesh.shader`, `water.mesh.shader` or an entity's
`visual.shader`. The value is a name, never a file:

```json
"sky": {"shader": "sky_clouds", "shader_params": {"cloud_coverage": 0.5}}
```

- The names are `sky_clouds`, `water_stylized`, `ground_biome_displace`,
  `ground_ortho_displace` and `toon`. A new name needs an ADR.
- `shader_params` sets the shader's parameters. The api manifest
  (§Shaders) lists each parameter with its type, default and range. A
  color is `[r, g, b]` or `[r, g, b, a]` from 0 to 1. A texture is an
  asset path.
- The interpreter sets `plane_size`, `screen_tex`, `depth_tex` and
  `water_normal_tex`. Content does not set them.
- The exact look is host-defined. Each parameter must change the look in
  the direction its name says.
- A custom shader is a `shader_dag` graph of primitives (ADR 0058) in
  `ground.mesh`, with no `shader` field next to it.
- Content never names a `.gdshader` or `.tres` file.

### Spec vocabularies (ADR 0090)

Four lists are closed. A name outside them fails validation
(`validate_host_neutral.py`), and the engine reports an error code. The
api manifest (§Spec vocabularies) prints each list. A new name needs an
ADR.

**Input keys.** `ui/input.json` (`key`, `keys`) and `set_input_mapping`
name keys from one list:

- `A`–`Z`, `0`–`9`, `F1`–`F12` and `Numpad0`–`Numpad9`
- `Up`, `Down`, `Left`, `Right`
- `Space`, `Enter`, `Escape`, `Tab`, `Shift`, `Ctrl`, `Alt`, `Backspace`


- A key name means a key position on a US keyboard. "W" stays in the
  same place on any layout, so movement keys work everywhere.
- `mouse_button` and `mouse_buttons` take `Left`, `Right`, `Middle`,
  `WheelUp` and `WheelDown`.
- Error code: `input.unknown_key`.

**Audio channels.** `set_audio_bus_volume` sets the volume of one
channel: `master`, `music` or `sfx`. `linear` is the volume from 0 to 1.

- Music plays on `music`. Sound cues play on `sfx`. Both feed `master`.
- Error code: `audio.unknown_channel`.

**Lighting fields.** `scene.json` `lighting` has these blocks. Each
field is defined by what the player sees. The exact look is
host-defined, but a larger value must change the look in the direction
the definition says. A key that starts with `_` is a comment. Error
code: `scene.unknown_field`.

The day cycle drives most fields. `directional_light.binds_to` names an
hour from 0 to 24 (`"world_clock.time_of_day"` by default, or
`"world.<field>"`). With no clock, the hour is 12. The day factor is 0
at midnight, 1 at noon and 0.5 at 6 and 18, and it changes smoothly.
A `_day` / `_night` pair blends by the day factor.

| Block | Field | What the player sees |
|---|---|---|
| `directional_light` | `enabled` | A sun lights the scene. |
| | `shadow_enabled` | Objects cast sun shadows. |
| | `binds_to` | The hour that sets the sun angle and the day factor. |
| | `color_at_noon`, `color_at_dawn_dusk`, `color_at_night` | The sun color at that time. Between times, the color blends. |
| | `energy_noon`, `energy_horizon`, `energy_night` | The sun brightness at that time. |
| `ambient` | `color_day`, `color_night` | The color of the fill light on surfaces that the sun does not reach. |
| | `energy_day`, `energy_night` | The brightness of that fill light. |
| `sky` | `shader` | A named sky shader. Without it, the sky is a plain gradient. |
| | `shader_params` | The parameters of that shader. |
| | `horizon_day`, `horizon_night` | The sky color at the horizon. |
| | `ground_day`, `ground_night` | The sky color below the horizon (plain sky only). |
| | `sky_top_color_day`, `sky_top_color_night` | The sky color overhead (`sky_clouds`). |
| | `cloud_color_day`, `cloud_color_night` | The lit cloud color (`sky_clouds`). |
| | `cloud_shadow_color_day`, `cloud_shadow_color_night` | The shaded cloud color (`sky_clouds`). |
| `fog` | `enabled` | Far objects fade into fog. |
| | `light_color`, `light_energy` | The fog color and brightness. |
| | `sun_scatter` | How much the fog glows toward the sun. |
| | `density` | How thick the fog is. |
| | `aerial_perspective` | How much far objects take the sky color, from 0 to 1. |
| | `height`, `height_density` | The fog thins above `height`. `height_density` sets how fast. |
| `tonemap` | `mode` | How bright colors compress: `linear`, `reinhard`, `filmic` or `aces`. |
| | `exposure` | The overall brightness. |
| | `white` | The brightness that becomes pure white. |
| `glow` | `enabled`, `intensity`, `strength`, `bloom` | Bright areas spread light around them. |
| | `hdr_threshold` | How bright an area must be to glow. |
| `adjustments` | `brightness`, `contrast`, `saturation` | Final color changes. 1.0 is no change. |
| | `color_correction` | A color lookup: `texture` (an asset path) or `gradient` (hex stops). |
| `ssao` | `enabled`, `radius`, `intensity` | Creases and contact areas become darker. |

For a sky color from the day cycle, the day value is the `_day` field,
then the uniform's value in `shader_params`, then the host default.

*Host hints* tune one host's renderer, and an interpreter may ignore
them. There are three:

- the top-level `render` block: `msaa_3d`, `screen_space_aa`,
  `use_taa`, `scaling_3d_mode`, `scaling_3d_scale`, `fsr_sharpness`
- `directional_light.shadow`: `mode`, `blur`, `max_distance`,
  `atlas_size`
- `reflection_probes`

**Physics.** A `physics` block gives an entity a body. An entity
without the block has no body. `body_type` is one of these:

| Body type | Guarantee |
|---|---|
| `static` | It never moves. It blocks bodies whose mask includes its layer. |
| `kinematic` (default) | It moves only when its state moves it. It blocks as `static` does. |
| `character` | It moves by `state.velocity` and slides along what blocks it. Its position writes back to `state.position` each tick. `floor_*` fields tune how it walks on slopes. |
| `area` | It never blocks. It reports an overlap with each body that its mask includes. |
| `rigid` | The host simulates it. Its position does not write back to state, so it is host-defined and outside the conformance tests. `mass`, `friction`, `restitution`, `linear_damp`, `angular_damp` and `gravity_scale` tune it. |

- `collision_layer` lists the layers that the body is on.
  `collision_mask` lists the layers that it reacts to. Each is `"all"`
  or a list of names from `@lib.physics.layers`. Bit numbers belong to
  the interpreter, so a raw number is an error.
- Numeric results (exact contact points, slide angles) are
  host-defined.
- Error codes: `physics.unknown_body_type`, `physics.unknown_layer`.

---

## Tick ordering (phased-sequential)

Rules do not fire in arbitrary order. Each tick runs four **fixed phases**
in sequence. Phases are **not user-extensible** — the phase count is a
design invariant, not a knob.

| Phase | What runs | State visibility |
|---|---|---|
| **1. input** | `input`-triggered rules. Typically queue **signals** (`emit` effects) rather than mutate state directly. | Reads committed state from previous tick. Writes are buffered. |
| **2. decide** | `tick`-triggered and `signal`-triggered rules fire. Read state, evaluate queries, compute effect lists. | Reads snapshot from the end of the previous tick. Writes buffered. |
| **3. commit** | Buffered effects apply in definition order. `spawn`/`remove` take effect. `relate`/`unrelate` mutate the graph. State mutations become visible to **later phases in the same tick**, NOT to already-queued effects earlier in this phase's write buffer. | Mutations are atomic per-effect. |
| **4. react** | `contact` triggers and `relation_changed` triggers fire against the **newly-committed** state. Effects they produce may write state directly (last-phase writes), and `emit`s queue into the **next tick's** input phase. | Reads commit-phase output. |

Rationale:
- `input` → `decide` → `commit` separation guarantees that a rule never reads
  a half-updated world mid-tick.
- `react` after `commit` ensures that contact detection runs against entities
  at their final positions for this tick (after motion has been committed),
  avoiding the "bullet never hits because enemy moved on the same tick" bug.
- Signals emitted in `react` crossing to next tick's `input` models the "you
  hit me, I react next frame" causal boundary cleanly.

**Within-phase ordering.** JSON definition order is the default. Optional
dependency hints per rule:

```json
{"id": "knockback", "after": "damage_apply"}
{"id": "damage_apply", "before": "remove_dead"}
```

Engine topologically sorts within a phase using these hints. Cycles error at
load.

**Deleted:** the `priority: int` field (previously in W3.3). Integer
priorities over a user-extensible space are ambiguous and a maintenance
ratchet. Named phases + JSON order + `before`/`after` cover every real case.

**Formula timing within commit (confirmed in W0 stress_ordering demo).**
Formulas inside effects evaluate at **apply time**, not at queue time.
Effects in the commit buffer apply in definition order; a later effect's
formula reads state *after* earlier effects have mutated it. Example with
two rules on the same entity in one tick:

```
value = 10    (tick start)
rule_a:  state_add  value +=  5          → value = 15
rule_b:  state_add  value += "self.state.value * 0.1"  (formula reads 15)
                                          → value = 15 + 1.5 = 16.5
```

This is sequential-write semantics within commit. Queries during `decide`
still see the tick-start snapshot (no writes have happened yet), but
formula amounts inside queued effects resolve live during `commit`.

**Effect target resolution.** The `target` field of an effect resolves in
this order:
1. If `target` is a key in the current context (e.g. `"self"`, `"a"`,
   `"piece"`, or a key added by an `input`/`signal` payload), use that
   binding's entity id.
2. Otherwise, treat `target` as a literal entity id.

This lets rules reference both contextual bindings (`target: "self"`) and
well-known instance ids (`target: "game_state_1"`) in the same field
without a syntactic split.

**Lifecycle-effect flush at load.** `spawn` triggers fire for every entity
created during initial `entities.json` load. Their queued effects must
flush before the first tick — otherwise counters and initialization rules
lag by one tick. The loader runs `rules.json` first, then entities, then
drains the commit buffer.

---

## Composition examples (proving genre-agnosticism)

Same engine. Different JSON. No GD changes.

### Hunger (survival/RPG)

```json
// entities.json
{"id": "player", "state_init": {"hunger": 100.0, "hp": 100.0}, "tags": ["player"]}

// world_rules.json
{
  "id": "hunger_decay",
  "trigger": {"type": "tick", "interval": 10},
  "query": {"tags_all": ["player"]},
  "effect": {"type": "state_add", "target": "self", "field": "hunger", "amount": -1}
}
{
  "id": "starvation",
  "trigger": {"type": "tick", "interval": 20},
  "query": {"tags_all": ["player"], "state": {"hunger_lte": 0}},
  "effect": {"type": "state_add", "target": "self", "field": "hp", "amount": -5}
}
```

### Damage from projectile (shooter)

```json
{"id": "bullet", "state_init": {"damage": 10, "lifespan": 60},
 "tags": ["projectile", "hostile_to_player"]}

{
  "id": "bullet_hits_entity",
  "trigger": {"type": "contact"},
  "query": {
    "a": {"tags_all": ["projectile"]},
    "b": {"tags_all": ["enemy"]},
    "radius": 0.5
  },
  "effect": [
    {"type": "state_add", "target": "b", "field": "hp", "amount": "-a.state.damage"},
    {"type": "remove", "target": "a"}
  ]
}
```

### Crop growth (farming)

```json
{"id": "wheat_seed", "state_init": {"growth": 0, "water_access": 0}}

{
  "id": "wheat_grows_near_water",
  "trigger": {"type": "tick", "interval": 30},
  "query": {"tags_all": ["crop_seed"]},
  "condition_query": {"tags_any": ["water"], "radius_from_self": 3},
  "effect": {"type": "state_add", "target": "self", "field": "growth", "amount": 5}
}
{
  "id": "wheat_matures",
  "trigger": {"type": "tick", "interval": 30},
  "query": {"tags_all": ["crop_seed"], "state": {"growth_gte": 100}},
  "effect": {"type": "transform", "target": "self", "to": "wheat_mature"}
}
```

### Inventory — pick up and drop (RPG / survival)

Inventory is relations. No `carrying` dict.

```json
// entities.json
{"id": "iron_sword", "state_init": {"damage": 12}, "tags": ["weapon", "pickable"]}

// world_rules.json
{
  "id": "pickup_on_contact",
  "trigger": {"type": "contact"},
  "query": {
    "a": {"tags_all": ["player"]},
    "b": {"tags_all": ["pickable"]},
    "radius": 0.5
  },
  "effect": {"type": "relate", "relation": "held_by", "from": "b", "to": "a"}
}
{
  "id": "drop_on_input",
  "trigger": {"type": "input", "action": "drop"},
  "query": {"tags_all": ["player"]},
  "sub_query": {"relations": {"held_by": "self"}, "limit": 1},
  "effect": [
    {"type": "unrelate", "relation": "held_by", "from": "sub", "to": "self"},
    {"type": "state_set", "target": "sub", "field": "position",
     "value": "self.state.position"}
  ]
}
```

Attack damage uses the holder's weapon via relation traversal:

```json
"amount": "-(source.held_by.state.damage)"   // from bullet/hand to target
```

### Container — chest with contents (adventure)

```json
{"id": "wooden_chest", "state_init": {"locked": 1}, "tags": ["container"]}

{
  "id": "unlock_and_open",
  "trigger": {"type": "input", "action": "interact"},
  "query": {"tags_all": ["container"], "state": {"locked_eq": 0}},
  "sub_query": {"relations": {"contains": "self"}},
  "effect": [
    {"type": "unrelate", "relation": "contains", "from": "self", "to": "sub"},
    {"type": "relate", "relation": "held_by", "from": "sub",
     "to": {"tag": "player"}}
  ]
}
```

### XP and level-up (RPG)

```json
{"id": "player", "state_init": {"xp": 0, "level": 1}}

{
  "id": "level_up",
  "trigger": {"type": "tick", "interval": 5},
  "query": {"tags_all": ["player"], "state": {"xp_gte": 100}},
  "effect": [
    {"type": "state_add", "target": "self", "field": "level", "amount": 1},
    {"type": "state_add", "target": "self", "field": "xp", "amount": -100},
    {"type": "emit", "signal": "level_up", "payload": {"entity": "self"}}
  ]
}
```

**Note:** same engine handles all four. The only genre-specific content is JSON.

---

## Deferred primitives (Tier 3 — flagged, not built)

Two primitives are **anticipated but deferred** to Tier 3 (actors). They are
documented here so the current 7-primitive design doesn't paint us into a
corner. Both are agent-side, not world-side — they do not affect runtime
semantics.

**Motivation:** Feng et al. 2026, *"Environment Maps: Structured Environmental
Representations for Long-Horizon Agents"* (arxiv 2603.23610). The paper
shows that LLM agents in long-horizon tasks fail less when they carry a
structured graph of `(contexts, actions, workflows, tacit knowledge)` rather
than re-deriving everything from raw traces each turn. WebArena: 28.2% vs
14.2% baseline; structured graph beats even raw trajectories (23.3%).

Mapping to Yume:

| Env Map component | Yume status |
|---|---|
| Contexts (named locations) | Tag convention — no new primitive needed |
| Actions (parameterized affordances) | Already expressible via input-trigger rules; needs an indexed read API |
| **Workflows** (multi-step plans) | **No primitive — gap** |
| **Tacit Knowledge** (declarative facts) | **No primitive — gap** |

The two primitives below close those gaps. They are operational only in
Tier 3 onward, but their JSON shape is sketched here so Tier 2 design choices
don't preclude them.

### 8. Plan (deferred)

A multi-step intention an actor pursues across ticks. Sequence of
`{precondition, intent, bind?}` steps with a goal predicate. Distinct from
Rule (single-tick reactive) — Plan is multi-tick deliberative.

```json
{
  "id": "satisfy_hunger",
  "goal": {"state": {"hunger_atleast": 80}},
  "abandon_if": {"state": {"hp_lt": 20}},
  "steps": [
    {"intent": "find",     "query": {"tags_all": ["food"]}, "bind": "target"},
    {"intent": "move_to",  "target": "target"},
    {"intent": "consume",  "target": "target"}
  ]
}
```

Actors hold an active Plan in `state.active_plan` (or as a `pursuing`
relation to a plan entity). A plan executor (Tier 3 module) advances steps
when their preconditions match, abandons when `abandon_if` triggers, completes
when `goal` matches. Plans compose with Rules: each step ultimately resolves
to input emissions or queries — no engine changes needed.

**Why deferred:** without actors, no consumer. Building it in Tier 2 would
add complexity to an engine that doesn't use it.

### 9. Knowledge (deferred)

Declarative facts about the world, distinct from Rules. Where Rules say
*"when X happens, do Y"*, Knowledge says *"in this world, X is true"*.
Both LLM actors (Tier 3) and pipeline design agents (Tier 2.5) need this —
the latter to ground prompts in the game's actual ontology, the former to
reason without re-deriving causality from rules every tick.

```json
// knowledge.json
{
  "facts": [
    {"id": "fire_hot",       "claim": "fire has high temperature",
     "implies_property": {"on": "fire", "property": "temperature_above", "value": 100}},
    {"id": "water_cools",    "claim": "water reduces temperature on contact",
     "implies_rule": "fire_extinguished_by_water"},
    {"id": "wet_resists",    "claim": "wet entities are less flammable",
     "narrative_hint": "soaking wood before storms"}
  ],
  "ontology": {
    "materials": ["wood", "stone", "iron", "water", "fire"],
    "categories": ["plant", "animal", "tool", "structure"]
  }
}
```

The runtime engine ignores Knowledge entirely — it's a side-channel that
agents and tooling read. Critically, Knowledge is **separable from Rules**:
the same world can be described to a story-writer, a balance designer, and
an LLM actor at different abstraction levels without rewriting the runtime
data.

**Why deferred:** consumers (actors, pipeline) are Tier 2.5+. The world
runs without it. Adding it before there's a reader pollutes the design.

### Note on Context and Affordance

The paper's other two components (Contexts, Actions) **don't require new
primitives**:

- **Context** = an Entity with `tags: ["context", "context_<name>"]` plus a
  region query. `World.contexts_containing(entity_id)` is a helper API,
  not a primitive change.
- **Affordance** = an indexed view of input-trigger rules that match a
  given entity/context. Same data as `world_rules.json`, exposed as
  `World.affordances_for(entity_id)`. Helper, not primitive.

These get added in Tier 3 as helper APIs once Plan and Knowledge land.

---

## Non-goals (boundaries)

This engine does **not** pretend to cover:
- **Narrative-shaped games** (visual novels, text adventures) — VN-style choice
  trees are expressible (`input` trigger + `state_set`) but you need a dialogue
  UI layer on top. That UI layer is not engine; it's a later archetype.
- **Input-timing games** (rhythm) — require `scheduled` trigger (reserved for
  post-W5 addition). Engine design permits, doesn't implement.
- **Turn-based games** — require `world_clock.paused` + explicit `signal`-driven
  phases. Hooks present; no turn manager yet.
- **Continuous physics simulation** (car physics, soft-body, fluids as
  particles) — Yume exposes Godot's PhysicsServer3D and CharacterBody3D
  via JSON (`physics.body_type: "kinematic" | "rigid" | "character" | "static"
  | "area"`, per ADR 0044/0045), so basic velocity-driven motion + collision
  slide come free. But complex constraint solvers, soft-body, particle
  fluids are deliberately out — when a game needs them, declare the body
  type in JSON and let Godot's optimized C++ implementation drive the
  behavior; the engine doesn't reimplement physics in GDScript.
- **Networked multiplayer** — single-instance simulation. Host/client is future
  work layered on top of state serialization.

These are **flexibility holds**, not refusals. Design must not preclude them.

**Engine extensions expected (not JSON reachable).** Some capabilities will
hit the formula wall — JSON + formulas alone cannot express them efficiently
or coherently. These require new engine modules written in GDScript, not new
rule types:

- **Animation state machines** — sprite/skeletal animation transitions,
  blend trees. Rule-driven per-frame state changes won't match 60 Hz needs.
- **A\* / flow-field pathfinding** — formulas can express heuristics but
  not the search itself. Pathfinding becomes an engine service that rules
  query (`self.path_to(target)`).
- **Async operations** — LLM calls, file I/O, network requests. Rules are
  synchronous; async work needs its own lifecycle.
- **Stateful UI** — menus, HUD widgets with focus/scroll/keyboard trapping.
  The generic `state_display.gd` covers data readouts; composite UI is a
  separate layer.

Flagging these explicitly so we don't stretch the JSON layer past its domain.

---

## Genre acid test (W5 checklist)

Engine is "done" when all **five** demos run with **identical engine code**,
differing only in JSON under `data/<demo>/`:

- [ ] **Ecology**: fire spreads, rain soaks, crops grow/rot, iron rusts — no player.
- [ ] **Farming**: player tills, plants, harvests. Day/night affects growth.
- [ ] **Top-down shooter**: player fires projectiles, enemies pursue and take damage.
- [ ] **Combat RPG**: HP, attacks, XP accumulation, level-up event.
- [ ] **Chess**: 8×8 grid as 64 `square` entities; pieces related to squares via
  `on_square`; legal-move rules per piece tag; check/checkmate via query.
  **No spatial continuous motion, no tick-driven decay — purely
  signal/input/relation-driven.** Proves the Relation primitive carries
  non-spatial games and that the tick loop doesn't assume continuous time.

The first four are real-time, spatial, and similar in shape. The fifth is
deliberately different: discrete turn-based, board-graph, zero spatial
continuity. If chess works, Relation and phased ordering are sound. If
chess exposes a gap, fix the engine — not the demo.

If any demo requires engine code beyond what W1–W4 produced, the engine leaks
genre assumptions. Fix the engine, not the demo.

---

## Testing

Correctness **is** the deliverable of this framework — not a runtime feature
we bolt on for robustness. Every W-phase must ship with its tests. No phase
is complete otherwise.

Six test layers, in increasing scope:

### 1. Engine-unit tests

GDScript unit tests of individual primitives. Fast, no scene, no renderer.

- `query.gd` — match fixtures: tag all/any/none, operator set (`_eq`..
  `_atmost`), state-field missing, relation clause, radius, limit, order_by.
- `effect_apply.gd` — each effect type against toy world; edge cases
  (state_clamp above max, remove of already-removed entity, spawn with
  formula position, relate with missing endpoint).
- `formula.gd` — each binding; whitelist rejections; parsed-expression cache hit.
- `spatial_index.gd` — radius query correctness, grid rebalancing on move.
- `relation_store.gd` — add/remove/transfer; both-direction index lookup;
  traversal aggregates.
- `tick_ordering` — four-phase sequencing: verify a rule in `decide` does
  not see a state change committed in the same tick's `commit` phase until
  the next tick.

### 2. Schema validator (Python, `yume test`)

Fits the existing Yume CLI pattern. Runs without Godot. Validates:

- `entities.json`: no duplicate ids, all `tags` are strings, `properties`
  types consistent across all entities using the same key, `state_init`
  numeric where used numerically, `visual.sprite_2d`/`model_3d` files exist
  (or a `--no-assets` flag skips).
- `world_rules.json`: ref integrity (every `transform.to`, `spawn.template`,
  `tag_add` target resolves); every formula parses under the whitelist;
  rule reachability — warns on rules whose query can never match given
  present entity defs; warns on `emit` signals with no listener rule and
  `signal` rules with no emitter.
- Relation types: flags inconsistent usage (e.g. `held_by` used as both
  item→holder and holder→item across different rules).

### 3. Integration fixtures

Tiny `data/test_fixtures/<case>/` folders. Engine runs N headless ticks;
the test asserts world state matches an expected snapshot.

Examples:
- `fire_spread_wet_resistance/` — place fire + dry tree + wet tree. After
  10 ticks, dry is burning, wet isn't.
- `pickup_drop_roundtrip/` — player walks into sword, picks up via `relate`,
  drops via input. Assert: relation gone, sword.position == player.position
  at drop moment.
- `bullet_hit_removes_both/` — bullet vs enemy contact. After 1 tick in
  `react` phase, enemy.hp reduced and bullet removed.
- `chess_illegal_move_rejected/` — attempt a knight move on empty board.
  No `on_square` relation change occurs.

### 4. Determinism / replay tests

Seed the RNG, record the input stream, run N ticks twice → assert **identical
entity+state snapshots and identical relation store**. This is the
foundation for save/load and time acceleration. If determinism breaks, the
ordering model is broken — this test is the canary.

### 5. Acid-test demos (W5)

Each of the five demos ships goal-state assertions runnable headless:

- **Ecology:** after 600 ticks, ≥N trees burned; rain reduced `burning` state
  on exposed entities to 0.
- **Farming:** within M ticks, player can till → plant → harvest → inventory
  (`held_by`) contains wheat.
- **Shooter:** all enemies in a fixture die to a scripted input track.
- **RPG:** scripted combat track reaches `level == 2`.
- **Chess:** legal-move generator produces exactly the known move counts
  from starting position depth-2 (perft[2] = 400); checkmate detection
  flags Fool's Mate position.

### 6. No-genre-leak invariant (meta-test)

A regression gate that fails if the engine re-acquires genre semantics:

- `grep` check: no effect `type` string in `scripts/engine/` matches
  `damage|need_decay|need_restore|gain_xp|advance_stage|heal|attack`.
- `grep` check: no demo-specific identifier in `scripts/engine/` (allowlist
  is primitive names + reserved state fields + math helpers).
- Snapshot diff: the `scripts/engine/` tree is compared before and after each
  W5 demo is added. Non-zero diff during demo-write phase fails — demo
  content is JSON-only.
- Schema check: every numeric rule field is either a JSON number or a
  formula-string; rejects implicit int/float mixing that silently downcasts.

**Tests-ship-with-phase rule.** Each W-phase's exit criteria include the
test subset for that phase. See `task_plan.md` for the per-phase test
checklist. A phase without its tests is incomplete, even if the feature
"works" interactively.

---

## What gets deleted (from current engine)

| File / feature | Why | Replacement |
|---|---|---|
| `brain_needs_driven.gd`, `brain_auto_agent.gd`, `brain_state_machine.gd`, `brain_human.gd`, `brain_llm.gd` | All agent-specific. Agents are Tier 3. | Re-add as `actor_*` later — a brain is just an input emitter in the new model. |
| `inventory.gd` | RPG-specific. | Relations: `held_by`, `contains`. Pickup = `relate`, drop = `unrelate`, transfer = `transfer_relation`. Queries traverse the relation graph. |
| `hp_bar.gd`, `needs_hud.gd`, `agent_needs_panel.gd` | UI hardcoded to specific fields. | Generic `state_display.gd` that renders any state field. |
| Effect types `damage`, `need_decay`, `need_restore`, `advance_stage` | Semantic — violates invariant 2. | `state_add` / `state_set` / `transform` with naming in JSON. |
| `recipes.json` | Agent-centric. | Will re-emerge as input-triggered rules in Tier 3 content. |
| `needs.json`, `satisfiers` | Hunger-specific. | State fields + decay rules in `world_rules.json`. |

Git preserves the old code. Tier 3 work rebuilds agent-side from the new primitives.

---

## File layout

> The engine was later reorganized into subdirectories
> (`core/ · coordinators/ · directors/ · io/ · ui/ · stores/ · libs/ · util/ ·
> qa/`). For the **authoritative, current** engine file tree see
> [`33_architecture.md`](33_architecture.md) §8 and the README's "Engine file
> map". In brief: the seven primitives live in `godot/scripts/engine/core/`
> (`entity.gd`, `rule.gd`, `query.gd`, `effect_apply.gd`, `formula.gd`,
> `phase_scheduler.gd`, `world.gd`); trigger dispatch is inside
> `phase_scheduler.gd` (there is no separate `trigger_dispatch.gd`);
> `spatial_index.gd` + `relation_store.gd` live in `stores/`; the read-only
> renderers are `renderer_2d/` + `renderer_3d/`.

Per-game content lives in `godot/data/demo_<game>/` (per-game dir of
`entities/*.json` + `world/rules*.json` + `scene.json`, globbed and merged by
id) — swap `--game=<name>` to switch games.

---

## Open questions (to resolve during W1)

1. **Entity ID vs instance ID.** Definitions are keyed by `id`. Instances need
   their own instance id. Convention: `<def_id>_<uuid_short>`. Do rules reference
   instances or definitions? Both — matchers on def properties, targets on
   instances.
2. **Effect lists.** Single effect or list? The shooter example above uses a
   list. Propose: always a list internally; `effect: {...}` is sugar for `[...]`.
3. **State type enforcement.** `state.hp = "oops"` silently breaks formulas.
   Propose: state_init declares types; runtime coerces or errors at set time.

These resolve during W1 implementation, not upfront. Flagged here so we notice
them when they bite.

**Resolved already** (formerly here, now moved into the body of this doc):
- **Rule priority / ordering** → see §"Tick ordering (phased-sequential)".
  Integer priorities are rejected.
- **Formula safety** → see §Formula. AST whitelist at load, parsed-expression
  caching per rule. Not a trust statement — a verifier.
