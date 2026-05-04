# Yume Framework — Universal Primitives

_Last updated: 2026-04-22_

## Purpose

This is the contract the engine is built against. It defines **seven primitives**
such that any simulation-shaped game (ecology, farming, shooter, RPG, survival,
tower-defense, roguelike, puzzle-with-state, chess) can be expressed as JSON
config over a single GDScript engine. No genre-specific engine code.

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

Adding to this list is ADR-gated. See `docs/adr/0004-blocks-motion-tag.md`.

**Engine-recognized scene config** (in `scene.json`):

| Block | Effect |
|---|---|
| `ground` | `{y, clamp_tags, despawn_tags}`. Each frame after motion integration, entities matching `clamp_tags` get Y-clamped to `y`; entities matching `despawn_tags` are removed if Y < `y`. Defaults: clamp_tags=["creature"], despawn_tags=["projectile"]. Replaces per-game creature_bounds + projectile_floor_despawn content rules. |
| `level_seed` | Integer applied to Godot's global PRNG at world load. Makes `randf()`-driven instance patterns (scatter / cluster) deterministic across sessions — same seed = same map. Omit for stochastic randomization. |

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
| `tick` | Every N clock ticks | Decay, growth, periodic checks |
| `contact` | Pair of entities within radius | Fire spread, collision damage, reactions |
| `signal` | Named broadcast fired by another rule or input | Phase changes, chained events, turn-based |
| `input` | Engine input action name | Player control, UI buttons |
| `spawn` / `despawn` | Entity lifecycle | Setup effects, cleanup |
| `relation_changed` | Edge added/removed matching pattern | Equip-on-pickup, unbind-on-drop, containment reactions |
| `scheduled` | Absolute time (reserved, post-W5) | Rhythm games, timed events |

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

Bindings:
- `self.*` — entity the rule is scoped to
- `source.*`, `target.*`, `a.*`, `b.*` — rule-specific roles
- `world.*` — global state (time, weather, tick count)
- Math helpers: `clamp`, `min`, `max`, `abs`, `sin`, `cos`, `randf`, `lerp`

Evaluated via Godot's built-in `Expression` with a **whitelisted syntax** at
load time (see §Formula layer below). Parsed expressions are **cached** on the
Rule struct — never re-parsed per tick.

**Bindings (complete list):**
- `self.*` — entity the rule is scoped to
- `source.*`, `target.*`, `a.*`, `b.*` — rule-specific roles
- `world.*` — global state (`world.tick`, `world.time_of_day`, `world.weather`, ...)
- `self.<relation>` — relation traversal (see §7): `self.held_by`,
  `self.contains`, `self.part_of`, `self.parent_of.state.hp`
- `self.nearest({...query...})` — spatial single-result helper
- `self.nearby({...query...})` — spatial multi-result helper (supports
  `.count`, `.sum(field)`, `.avg(field)`, `.max(field)`, `.min(field)`)
- Math helpers: `clamp`, `min`, `max`, `abs`, `sin`, `cos`, `randf`, `lerp`

**Whitelist.** At load time, each formula's AST is walked. Allowed:
identifiers from the binding set, numeric/string literals, arithmetic/
comparison/logical operators, **Python-style ternary `a if cond else b`**
(C-style `cond ? a : b` is NOT supported by Godot 4.6.1 Expression —
empirically verified during harvestcore QA, 2026-05-02), bitwise ops
(`<<`, `&`, `|`), Vector2/Array subscript, and calls to the math helper
set and the query helpers (`nearest`, `nearby`, traversal-aggregates).
**Rejected:** any call whose callee is not in the whitelist; attribute
access on non-bindings; bytecode-level escapes. A formula that fails the
whitelist errors at load, not at tick.

**Perf note.** Formulas inside `contact` triggers evaluate **per candidate
pair per tick**. With 500 pairs/tick on a busy scene, that is 30 000 evals/s.
Parsed-expression caching is mandatory. Formula micro-benchmarks land in W4.

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
- **Continuous physics simulation** (car physics, soft-body, fluids as particles)
  — discrete-tick engine with coarse contact detection. Not a Box2D/Bullet
  replacement.
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

## File layout after redesign

```
archetypes/core/templates/godot/
├── scripts/
│   ├── engine/                       ← all 7 primitives live here
│   │   ├── entity.gd                 ← Entity node (generic, no subclasses)
│   │   ├── rule.gd                   ← Rule struct + cached Expression
│   │   ├── trigger_dispatch.gd       ← tick / contact / signal / input / spawn / relation_changed routing
│   │   ├── query.gd                  ← query compiler + spatial matcher + relation filter
│   │   ├── effect_apply.gd           ← all effect implementations
│   │   ├── formula.gd                ← Expression wrapper + bindings + whitelist
│   │   ├── spatial_index.gd          ← grid-bucket hash
│   │   ├── relation_store.gd         ← typed directed-edge store, bi-indexed
│   │   ├── phase_scheduler.gd        ← input/decide/commit/react phase loop
│   │   ├── world_clock.gd            ← unchanged
│   │   └── world.gd                  ← top-level orchestrator
│   ├── renderer_2d/                  ← reads entity.visual, draws
│   ├── renderer_3d/                  ← reads entity.visual, draws
│   └── ui/
│       └── state_display.gd          ← generic renderer for any state field
└── data/
    ├── meta.json                     ← world config, data_root pointer
    ├── entities.json                 ← all entity definitions
    └── world_rules.json              ← all rules (self, contact, signal, etc)
```

Per-genre content lives in `data/<game>/` with the same schema — swap `data_root`
to switch games.

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
