---
description: Path-scoped rules for Yume demo data folders
globs: godot/data/**
---

# Demo data — schema discipline

Demos live as JSON folders under `data/`. They are **content**, not code —
no GDScript files belong here.

## ⚠ CRITICAL: never ship a rule with `effect: []`

The engine's `_load_rules_file` reports `[rule.effect_empty]` as a
hard error when a rule's effect list is empty. Empty-effect rules
are a code-smell pattern — typically the result of removing the
last effect during cleanup ("audio not shipped → remove play_music")
without removing the now-no-op rule itself.

❌ **WRONG**:
```jsonc
{"id": "bgm_proto_village",
 "trigger": {"type": "tick", "interval": 60},
 "query": {"tags_all": ["world_clock"]},
 "effect": []}      // CRASH at load: rule.effect_empty
```

✅ **RIGHT** — delete the entire rule if it's no-op. If a rule MUST
exist as a placeholder (e.g. for future audio wiring), use a
trivial state-touch:
```jsonc
"effect": {"type": "state_set", "target": "world_clock",
           "field": "_bgm_tick_count", "value": "world_clock.state._bgm_tick_count + 1"}
```

**Empirical case 2026-05-10**: Aldenmere `bgm_proto_village` shipped
with `effect: []` after `play_music` was stripped (no audio assets
yet). World load reported `rule.effect_empty` error. Fix: deleted
the placeholder rule until audio-designer ships BGM.

**Gate**: yume-content-designer + yume-game-rules-designer skills
must NEVER ship a rule with `"effect": []`. If the cleanup pass
removes the last effect, also remove the rule. Add to those skills'
"final pass before declaring done" checklists.

## ⚠ CRITICAL: engine-injected input actions need `engine_injected: true`

Some input actions are not bound to keys — the engine queues them
directly from internal state. Examples: `stop_x` / `stop_y` queued
by `world.gd::_poll_input` on per-axis idle (when neither E nor W
is held → queue stop_x).

❌ **WRONG** — InputRegistrar warns + skips (action never reaches
InputMap; scenario_runner can't fire it):
```jsonc
{"name": "stop_x", "edge": "press"}        // no key, no marker → warning
```

✅ **RIGHT** — explicit opt-in marker tells InputRegistrar to
register a keyless action silently:
```jsonc
{"name": "stop_x", "edge": "press", "engine_injected": true}
```

The marker preserves typo detection for ordinary actions (`{"name":
"jjjump"}` still warns) while supporting the legitimate
engine-injected case.

**Empirical case 2026-05-10**: Aldenmere shipped stop_x / stop_y /
stop without the marker; three warnings per world load. Fix:
added `engine_injected: true` to all three; updated InputRegistrar
to handle the field.

## ⚠ CRITICAL: schema field-name landmines (memorize, then verify)

These are exact field names the engine reads. Wrong name = silent failure
(rule registers but never fires; no error). Empirically caught all of these
during the merchant game build (2026-05-06) — each had ~30-50 occurrences
across the data files before being fixed.

| Effect | Engine reads | Common wrong name | Where verified |
|---|---|---|---|
| `state_add` | `amount` | ❌ `delta` | `effect_apply.gd:120` `e.get("amount")` |
| `state_mul` | `amount` | ❌ `factor` / `delta` | `effect_apply.gd:126` |
| `spawn` | `template` | ❌ `def` | `effect_apply.gd:148` `e.get("template")` |
| `state_clamp` | `min` / `max` | (correct) | `effect_apply.gd:133-134` |

**Verify before writing**: `grep -A 4 '"type": "<effect>"' godot/data/demo_doomarena3d/world/physics.json` — if a working demo uses different names, follow the demo, not your intuition.

## ⚠ CRITICAL: `self.nearest({...})` is NOT IMPLEMENTED — use contact-pair

`formula.gd`'s top docstring declares `self.nearest({...})` as **deferred
to Tier 3** — the formula evaluator does NOT actually resolve it.
Writing it in any formula context (effect `value`, `destination_x`,
`payload.X`, etc.) makes evaluate() see `self.nearest(...)` as a
bare path lookup, returns null, and the downstream `.state.position`
or `.id` access crashes with `"self can't be used because instance
is null"`.

❌ **WRONG**:
```jsonc
{"type": "pathfind_to",
 "destination_x": "self.nearest({tags_all: [villager]}).state.position[0]",
 "destination_z": "self.nearest({tags_all: [villager]}).state.position[2]"}
```

✅ **RIGHT** — use a CONTACT-pair query with `a` (the pursuer) +
`b` (the target). The engine pre-binds both, formulas reference `b.X`
directly:
```jsonc
{"trigger": {"type": "contact"},
 "query": {
   "a": {"tags_all": ["wolf"]},
   "b": {"tags_all": ["villager"], "tags_none": ["in_shelter"]},
   "radius": 40,
   "once_per_a": true
 },
 "effect": {
   "type": "pathfind_to",
   "target": "a",
   "destination_x": "b.state.position[0]",
   "destination_z": "b.state.position[2]"
 }}
```

Drawback: contact-pair fires per-tick (no `interval` field), and the
binding picks "any matching b within radius" rather than `order_by`-
sorted (e.g. lowest health). For most pursuer AI nearest-in-cone is
acceptable; if priority sorting is essential, gate on additional
state filters in `b`'s query (e.g. `state: {health_lt: 30}` → only
chases wounded).

**Empirical case 2026-05-11**: Aldenmere `wolf_pursue_villager` used
the broken `self.nearest(...).state.position[0]` formula. Loaded
fine (no parse error), then crashed at runtime the first tick a
wolf existed — `formula.exec_failed` → "self can't be used because
instance is null". Stack trace from world.gd::_on_tick. Fixed by
collapsing to contact-pair + `once_per_a`.

**The gate**: yume-systems-designer skill must NEVER author
`self.nearest({...})` in any formula context. The three "find me a
related entity" patterns the engine supports today:

1. **Contact-pair** (`trigger: contact`, `query: {a, b, radius}`) —
   the most common.
2. **Single-binding tick** + a separate signal/contact rule that
   sets `state.X_target_id` for later rules to bind via.
3. **Spatial query inside a single-binding query** (`tags_all` +
   `radius`) — but only ONE entity is bound (`self`), not "find
   related to self."

Until Tier-3 spatial helpers land, those three cover every real use.
A new ADR is required before adding `nearest()` to the formula
evaluator (it would need spatial-index integration + scoring/order
semantics).

## ⚠ CRITICAL: 2-binding `{a, b, radius}` queries are CONTACT-only

Pair-matching (find pairs of entities (a, b) within radius) is ONLY
supported on `trigger: {type: "contact"}`. The engine's
`_fire_contact_rule` walks pairs; `_fire_scan_rule` (used by tick /
input / signal triggers) does NOT.

If you write a tick / signal / input rule with a 2-binding query:

```jsonc
// ❌ WRONG — engine treats this as single-entity scan; b never binds
{
  "trigger": {"type": "tick", "interval": 5},
  "query": {
    "a": {"tags_all": ["mud_hut", "under_construction"]},
    "b": {"tags_all": ["fire_pit", "burning"]},
    "radius": 10.0
  },
  "effect": [
    {"type": "tag_add", "target": "a", "tags": ["built"]},
    {"type": "emit", "payload": {"id": "a.id"}}  // CRASH: a not bound
  ]
}
```

The engine fires this as a single-entity scan: matches the FIRST sub-
binding (`a`'s tags) and binds `self` to each match. **`a` and `b`
are never bound** — `target: "a"` resolves to literal id "a" (no
entity), and formulas `a.id` / `b.id` evaluate against null Entity →
"self can't be used because instance is null" runtime error.

✅ **Three correct patterns**:

1. **Use `contact` trigger** if pair-matching is the intent (rare for
   "complete construction"-style rules; common for combat / pickup):
   ```jsonc
   {"trigger": {"type": "contact"},  // engine pair-matches per tick
    "query": {"a": {...}, "b": {...}, "radius": 5.0}, ...}
   ```

2. **Single-binding tick** + use `self.nearest({...})` formula to
   resolve the partner inline:
   ```jsonc
   {"trigger": {"type": "tick", "interval": 5},
    "query": {"tags_all": ["mud_hut", "under_construction"]},
    "effect": [
      {"type": "tag_add", "target": "self", "tags": ["built"]},
      {"type": "state_set", "target": "world",
       "field": "nearby_fire_id",
       "value": "self.nearest({tags_all: [fire_pit]}).id"}
    ]}
   ```

3. **Drop the partner condition** if it's a soft proximity hint and
   exact pair semantics aren't required (acceptable when the radius
   was vibes, not a hard constraint).

**Empirical case 2026-05-10**: Aldenmere Phase 1 shipped with 15
tick rules using broken `{a, b, radius}` queries — `wolf_despawn_dawn`,
`mudhut_construction_complete`, `warmth_decay_*`, etc. All crashed at
tick 1 with formula-exec errors. yume-systems-designer skill
generated them; the gate below didn't exist. Bulk-fixed by
collapsing each rule to single-binding `self` query.

**The gate**: `yume-systems-designer` skill must NEVER write a 2-
binding query under a non-contact trigger. Both:
- The skill's role spec calls this out under "Common rule shapes"
- A static validator check in `tools/validate_rules.py` (future)
  can grep for `(tick|signal|input).*"a":\s*{.*"b":\s*{` shape and
  fail at sync time

## ⚠ CRITICAL: query vs require — they are NOT interchangeable

Wrong assumption (the merchant build cost ~40 broken rules to this):

❌ **WRONG** — `require` is NOT a state-search filter:
```jsonc
{
  "trigger": {"type": "tick", "interval": 10},
  "require": {"clock": {"tags_all": ["world_clock"], "state": {"phase_eq": "shop"}}}
  // expectation: rule fires when world_clock entity has phase=shop
  // reality: require validates that ctx["clock"] (a binding from elsewhere)
  // matches; ctx["clock"] is NEVER set, so require always fails, rule never fires
}
```

✅ **RIGHT** — to gate on a singleton's state, put it in `query`:
```jsonc
{
  "trigger": {"type": "tick", "interval": 10},
  "query": {"tags_all": ["world_clock"], "state": {"phase_eq": "shop"}}
  // engine searches for entities matching this filter; rule fires per match
}
```

**`require` semantics**: validates that bindings ALREADY set in context match
the filter. Used when query has named sub-bindings (chess `piece`, `from_sq`,
`to_sq`) and require enforces extra constraints on those existing bindings.
The engine code is `phase_scheduler.gd::_require_ok` — it reads
`ctx.get(binding_name, null)`; if null → require FAILS regardless of
your filter.

**`query` with named sub-bindings**: `query: {clock: {...}, a: {...}}` sets
multiple context bindings via search. Rule fires per (clock × a) combination.
For pure tick rules wanting state-gating, use FLAT pattern:
`query: {tags_all: ["world_clock"], state: {field_op: value}}`.

## ⚠ CRITICAL: state_set / show_toast values are HUMAN TEXT vs FORMULAS

`_value()` routes string values through `Formula.looks_like_formula()`
→ `Formula.evaluate()` if it looks formula-shaped. As of 2026-05-08
the heuristic requires a formula-START char (lowercase / digit /
`(` / `-` / `+` / `_` / `@`), so capital-letter-starting English
text bypasses parsing safely.

When authoring `state_set value: "..."` or `show_toast text: "..."`:

**Safe — passes through as literal text**:
- `"Find your shop in Pendrel."`     (starts capital)
- `"Day 6 — bailiff returns soon."`  (starts capital)
- `"→ Open the shop"`                (starts arrow / non-letter)
- `"Eugene joins your party."`       (starts capital)

**Treated as formula — must evaluate cleanly or it crashes**:
- `"world.gold"`                     (starts lowercase, has `.`)
- `"signal.sale_price"`              (lowercase + `.`)
- `"a.state.hp + 10"`                (lowercase + math)
- `"(a.state.hp - 5) * 2"`           (paren start, math)

If you want literal text that LOOKS formula-like, prefix with a
capital letter or `→` to opt out:

- `"→ world.gold"`         ← treated as text
- `"World.gold"`           ← treated as text (capital W)

Empirical: 2026-05-08 the `current_objective` field set to
`"Find your shop in Pendrel. Walk to the shop door (south-west of
the fountain)."` crashed `Expression.parse` because the old
`looks_like_formula` only checked for any-of `[space + - * / ( ) .]`
without a start-character filter. Fixed in formula.gd; this gate
documents the convention so future authors don't have to discover it.

## ⚠ CRITICAL: bindings in payload values are BARE, not `{...}`

❌ **WRONG**: `"new_tier": "{world.reputation_tier}"` — engine sends the
literal string through the formula evaluator, fails to parse `{world.X}` as
a Godot Expression.

✅ **RIGHT**: `"new_tier": "world.reputation_tier"` (bare binding) OR
`"new_tier": {"binds": "world.reputation_tier"}` if your effect supports
binding objects. Check the specific effect's spec.

The merchant build had ~57 of these brace-wrapped bindings causing 31,000+
formula.parse_failed errors per session.

## ⚠ CRITICAL: `velocity_add_relative` requires deceleration mechanism

Camera-relative WASD rules use `velocity_add_relative` (lib bundle's
FP + iso variants). The effect ADDS to existing velocity each tick;
speed-clamp normalizes magnitude to `state.max_speed`. When the actor's
`state.facing` changes between ticks (e.g., player mouse-turning
mid-walk), the previous tick's velocity points in the OLD facing
direction; this tick adds in the NEW facing direction; sum-then-clamp
lands BETWEEN old and new facing. Velocity LAGS the camera — player
feels "something pulling" them back from where they're looking.

❌ **WRONG** — `velocity_add_relative` actor with no decay:
```jsonc
"state_init": {
  "facing": 0,
  "max_speed": 3,
  // missing: BOTH drag AND zero_velocity_pretick → facing-lag bug
}
```

✅ **RIGHT** — pick ONE (or both) deceleration mechanism:
```jsonc
"state_init": {
  "facing": 0,
  "max_speed": 3,
  "zero_velocity_pretick": true  // engine zeros vel each tick →
                                  // tight FPS feel, instant direction match
}
// OR
"state_init": {
  "facing": 0,
  "max_speed": 3,
  "drag": 5.0  // motion integrator decays vel each frame →
                // momentum-glide feel, converges over a few ticks
}
```

**The rule**: any actor whose movement comes from `velocity_add_relative`
rules MUST declare ONE of:
- `state.zero_velocity_pretick: true` (engine zeros at start of each tick)
- `state.drag > 0` (motion integrator decays each frame)

Without either, velocity accumulates in stale-facing direction and produces
the "pulling" feel when the mouse turns.

**Camera mode → required check:**

| Camera mode | Movement rules | Deceleration check |
|---|---|---|
| `top_down_3d`, `third_person_3d` | world-frame `velocity_set` per-axis | n/a (last-writer-wins handles direction) |
| `isometric_3d` | iso variant `velocity_add_relative` (facing=π/4) | **MANDATORY**: zero_velocity_pretick=true OR drag>0 |
| `first_person_3d` | FP variant `velocity_add_relative` (state.facing) | **MANDATORY**: zero_velocity_pretick=true OR drag>0 |

**Empirical case 2026-05-10**: Aldenmere FP rollout shipped with player
`drag: 0` + no `zero_velocity_pretick`. User reported "movement laggy as
if something pulling it" on mouse-turn-mid-walk. Fix: re-enabled
`zero_velocity_pretick: true`.

**Gate**: skills authoring `entities/<actor>.json` (yume-content-designer)
AND skills writing world/physics.json with WASD lib bundle splice
(yume-systems-designer) MUST verify the actor's state_init satisfies
this rule. The yume-asset-designer skill's camera-mode-pick must
FLAG the requirement to the content-designer downstream.

## ⚠ CRITICAL: state.velocity dimensionality — Vector2 NOT Vector3 for floor-walkers

The WASD lib bundle (`@lib.input_bundles.wasd_with_fp_variant.rules`)
uses `velocity_set` with field name `y` to mean **"the second component
of velocity"**. The renderer (entity_mesh_3d.gd:127) lifts a Vector2
velocity into world Vector3 via:

```gdscript
position = Vector3(p.x, 0, p.y) * position_scale
```

So when velocity is Vector2 `(x, y)`, `y` becomes world-Z (north/south
on the floor). When velocity is Vector3 `(x, y, z)`, `y` is the
world-UP axis — pressing W literally launches the player upward.

❌ **WRONG** for floor-walking actors (player, NPCs):
```jsonc
"velocity": [0, 0, 0]    // Vector3 — y is world-up, W makes player jump
```

✅ **RIGHT** for floor-walking actors:
```jsonc
"velocity": [0, 0]       // Vector2 — y is renderer-Z = north, W walks
```

✅ **Vector3 IS appropriate** for entities that legitimately move
in 3D space (projectiles with arc trajectories, flying mobs, vertical
elevators). Those entities' rules use `velocity_set z:` for horizontal
+ `y:` for vertical separately.

**Empirical case 2026-05-10**: Aldenmere player + 8 villagers + 3
animals shipped with Vector3 `[0,0,0]` velocity (11 entities total).
Pressing W made the player float upward instead of walking north.
User feedback: "why my 'w' is not on the floor, but is up and down?"

**ADR 0045 follow-up (2026-05-13)**: actors with `physics.body_type:
"character"` ALSO use Vector2 for floor-walkers — the runner script
mirrors state.velocity to its `CharacterBody3D.velocity` via
`sync_body_velocity`, which lifts Vector2(x, y) → Vector3(x, 0, y)
exactly like the renderer. Same convention; same rule.

**The check**: any entity tagged `actor`, `villager`, `ambient_walker`,
`prey`, `wolf` (or any other ground-mover) MUST have 2-component
velocity. Verify with grep before declaring content done:

```bash
# Find all 3-component zero-velocity inits on ground-walker entities:
grep -B 6 '"velocity": \[\s*0,\s*0,\s*0\s*\]' entities/*.json
```

Each match needs to be either (a) collapsed to `[0, 0]` if the entity
walks on the floor, or (b) explicitly justified as a 3D-mover (with
a `_comment` so future readers know it's intentional).

## ⚠ CRITICAL: world-state singleton pattern (no env.world_state queries)

The engine does NOT support querying `env.world_state` directly:
- ❌ `query: {world_state: {phase_eq: "shop"}}` — engine doesn't recognize
  `world_state` as a query target
- ✅ Create a singleton entity tagged `world_clock` (or `level_clock`,
  `game_state`) with all your global state fields in `state_init`. Rules
  query it via `tags_all: ["world_clock"]`; effects mutate via
  `target: "<world_clock_entity_id>"`.

**HUD bindings work BOTH ways** but for different stores:
- `world.X` → reads `env.world_state` dict (set by `state_set target=world`)
- `<entity_tag>.X` → finds first entity with that tag, reads its state

**Don't duplicate**: pick ONE source-of-truth. Either use env.world_state
(`target=world`, HUD binds `world.X`) OR singleton entity
(`target=<entity_id>`, HUD binds `<tag>.X`). Mixing both means mutations on
one don't affect reads from the other.

Working demos:
- chess: `game_state` singleton entity, queries via `tags_all: ["game_state"]`
- sokoban: `level_clock` singleton, same pattern
- harvestcore: hybrid (some env.world_state, some singletons) — the messier path

## DON'T

- ❌ **Reference engine internals.** No `state.entities[N]`,
  `world.scheduler`, or any non-public field. Use the documented context
  bindings: `self`, `target`, `a`, `b`, `world`, plus payload fields.
- ❌ **Use semantic effect type strings.** Forbidden: `damage`,
  `need_decay`, `heal`, `gain_xp`. Express as `state_add` /
  `state_set` with field naming in JSON.
- ❌ **Hardcode coordinates that assume a specific renderer.** Use the
  W5.0 convention: 2D positions live in pixel-scale; 3D scenes scale
  via `position_scale` export. Same JSON works in both.
- ❌ **Reach into engine source paths.** `sprite_2d`, `model_3d`, and
  `mesh` keys reference asset/library paths — `res://data/...` only,
  never `res://scripts/...`.
- ❌ **Mix bare-id and context-binding in the same target.** Pick one:
  `target: "self"` (context) or `target: "specific_id"` (literal).
  Effect resolution does both, but mixing in one rule confuses readers.

## DO

- ✅ **Tag liberally.** Tags are free; queries depend on them. Anti-tag
  with `tags_none` for exclusion (e.g. flammable but not burning yet).
- ⚠️ **`blocks_motion` is engine-recognized** (ADR 0004). Entities with
  this tag must also declare `properties.aabb_extents: [hx, hy, hz]`
  (half-extents on each axis). Motion integrator slides moving entities
  around their AABB on the XZ plane. Example: `tags: ["wall",
  "blocks_motion"], properties: {"aabb_extents": [22, 1.5, 0.25]}`.
  Don't reuse the name for other meanings.
- ✅ **Use `state_init` for both static initial values AND dynamic state
  to be mutated.** The engine doesn't enforce a static/dynamic split;
  it's a content convention.
- ✅ **Comment heavily.** JSON has no real comments, but `_comment` keys
  are ignored by the engine. Use them for design intent.
- ✅ **Whitelist formula syntax.** Formulas are `Expression` strings.
  Allowed: bindings (`self.state.X`, `target.X`, `world.tick`), math
  helpers (`clamp`, `min`, `max`, `abs`, `sin`, `cos`, `sqrt`, `pow`,
  `floor`, `ceil`, `lerp`, `randf`), arithmetic, comparison, bitwise
  (`<<`, `&`, `|`), Vector2/Array subscript (`v[0]`, `a[1]`).
  No function calls outside the math helpers — defer to W4.5 AST
  whitelist when it lands.
- ⚠️ **Ternary `a if cond else b` is BROKEN.** Godot 4.6.1's
  `Expression` parses it without error but **always returns the IF
  branch**, ignoring the condition. C-style `cond ? a : b` doesn't
  parse at all. Empirically verified during doomarena3d v2 QA
  (2026-05-03) — `5.0 if false else 0.0` returns 5.0; `5.0 if true
  else 0.0` also returns 5.0. **Workaround**: use a clamp-based
  step function:
  ```
  // step = 1 if (x > threshold) else 0
  clamp((x - threshold) * 1e6, 0, 1)
  // result = move if (cond) else 0
  move * clamp((cond_lhs - cond_rhs) * 1e6, 0, 1)
  ```
  The `* 1e6` makes the boundary sharp (<1 µunit transition zone).
  Older demos (harvestcore, tinypond) that use ternary may have
  silently been taking the IF branch always — audit on next pass.
- ✅ **Keep demos cross-renderer.** If a rule's `radius` only makes sense
  in 2D pixels, document why; same for 3D world units. Default: pick
  values that work both with `position_scale=0.05` for 3D and pixel
  positions for 2D.

## Schema sketch

```jsonc
{
  "definitions": [
    {
      "id": "wheat_seed",                    // unique def id
      "tags": ["plant", "crop", "seed"],     // membership
      "properties": {                         // STATIC
        "material": "wheat",
        "max_growth": 100
      },
      "state_init": {                         // DYNAMIC
        "growth": 0,
        "wet": 0.0,
        "position": [0, 0]                    // optional override
      },
      "visual": {                             // RENDERER input
        "sprite_2d": "res://...",             // tier 1
        "shape": "tree",                      // tier 2
        "color": "#a0c050"                    // tier 3 fallback
      }
    }
  ],
  "initial_instances": [
    { "def": "wheat_seed", "id": "w1", "position": [10, 5] },
    { "def": "wheat_seed", "id": "w2", "position": [20, 5], "state": {"growth": 50} }
  ],
  "initial_relations": [
    { "type": "on_square", "from": "wp1", "to": "sq_a2" }
  ]
}
```

Rules JSON shape (per `docs/30_framework_primitives.md` §3):

```jsonc
{
  "rules": [
    {
      "id": "rule_id_unique",
      "trigger": {"type": "tick", "interval": 1},
      "query": {"tags_all": ["plant"], "state": {"wet_lt": 0.5}},
      "require": {                              // optional
        "context_role": {"tags_all": [...]}
      },
      "chance": 0.3,                            // optional, default 1.0
      "effect": {...} | [{...}, {...}],
      "before": ["other_rule"],                 // optional ordering
      "after": ["another_rule"]
    }
  ]
}
```

## Validation

When adding a demo, verify:
1. `Rule.validate_all()` passes (structural — id/trigger/effect/chance)
2. All entities tagged consistently (no typos in `tags_all`/`tags_none`)
3. Formulas parse (no syntax errors)
4. Demo runs in both 2D and 3D scenes (if applicable)
5. Goal-state cascades reach expected end state in soak test
