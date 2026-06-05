---
description: Path-scoped rules for Yume demo data folders
globs: godot/data/**
---

# Demo data — schema discipline

Demos under `data/` are CONTENT — JSON only, no `.gd` files. Many of the
rules below have a static validator under `tools/validators/` that fails
sync at `play.sh` time; those are the load-bearing gate. Prose here
documents the rule + a one-line empirical case so future authors know
WHY the gate exists.

## Backups live in `_snapshots/`, NEVER in globbed dirs

`world_loader.gd` globs `<root>/entities/*.json` AND `world/rules/*.json`
and merges every definition by id. Duplicate id across files → the
alphabetically-LAST file silently wins (no error). Put renamed/backup
copies in `<game>/_snapshots/` — the engine never scans there.
`scene.json` + level `entities.json` are read by exact name (siblings
don't load), but keep them in `_snapshots/` too for cleanliness.

**Gate**: `validate_duplicate_defs.py` flags any def id in 2+ files
within a globbed set.

**Empirical 2026-05-27**: a manual `entities/auto_gen.preBuckets.json`
backup re-declared `fountain` etc. with old `prim_unit_*` meshes →
fountain rendered as a magenta sphere instead of `fountain_kit`.

## Top-level `position` clobbers `state.position` in initial_instances

`entity._apply_overrides` runs the `state` block first then applies
top-level `position` LAST — top-level wins. Silent footgun.

For entities where `state.position` IS the spawn (free_cameras,
camera anchors, logical entities the renderer reads via state):
**set BOTH fields to the same value**, OR omit the top-level.

```json
{"def": "free_camera", "id": "camera_oblique",
 "position": [0, 28, 32],
 "state": {"position": [0, 28, 32], "yaw": 0.0, "pitch": -0.66}}
```

**Gate**: engine warning `[entity.position_clobber]` at spawn +
`validate_position_consistency.py` (sync-time).

**Empirical 2026-05-26**: compose_world emitted free_cameras with
`position: [0,0,0]` AND `state.position: [actual]` → cameras spawned
at origin (inside a building), rendering as solid dark brown for ~2
hours of debugging. Lesson: when auto-gen looks wrong, diff JSON
against a working demo field-by-field BEFORE iterating on theories.

## No per-def escape hatches from automated derivation (INVARIANT)

Anything the engine can DERIVE — colliders from mesh bbox × scale,
y_offset from mesh bbox, material UUIDs from .glb authored materials,
director mounting — the engine MUST derive every time. No per-def
opt-outs. Every escape hatch creates silent drift (author sets one
override field, forgets the others, geometry desyncs).

**When proposing a "manual override for THIS def" field, REJECT**.
Either (a) fix the derivation for all cases of this class, or (b)
fix the source data (re-author the mesh, change the bbox) so the
existing derivation produces the right thing.

**Empirical 2026-05-24**: `_aabb_intent: "design"` was an escape
hatch in validate_aabb_extents.py — 7 aldenmere defs abused it
(set aabb_extents but forgot aabb_offset → colliders half-buried).
Fix: deleted the field entirely. Collider is now 100% mesh-derived,
no opt-out path exists.

## NEVER drop a `.gd` file under `godot/data/`

`data/` is content-only; engine code lives at `scripts/engine/`. A
stray `.gd` declaring `class_name X` collides with an engine class
in Godot's global registry — dispatch silently routes to whichever
copy registered first. Symptom: feature stopped working, no error.

**Gate**: `validate_no_stray_scripts.py` (wired into `play.sh`)
scans `data/` + the sync target for any `*.gd` and fails the
pre-launch. After deleting a stray, rebuild Godot's class cache:
`godot --path <template> --headless --import`.

**Empirical 2026-05-15**: stale `data/demo_aldenmere/effect_apply.gd`
won the `class_name EffectApply` registry race over the real engine
file. Its match-arm predated `velocity_add_relative` → silent WASD
no-op. User reported as "drift / pulls sideways."

## Formula context bindings depend on trigger type

Formulas (`"value": "X.state.Y"`) get their bindings from how the
rule fires. Wrong binding name = `self can't be used because instance
is null` at runtime — no soft-fail.

| Trigger | Available bindings |
|---|---|
| `tick` flat query | `self`, `self_entity` |
| `tick` `query: {a:..., b:...}` | named sub-bindings (`a`, `b`, ...) |
| `contact` | `a`, `b` (pair-matched) |
| `signal` with `require: {actor:..., target:...}` | `actor`, `target` (the require names) — **NO `self`** |
| `signal` with `query` | `self` from the query match |
| `input` with `query.tags_all` | `self` (matched actor) |
| `spawn` / `despawn` | `self` |

Signal rules with `require:` cannot reference `self.state.X` in
formula — use the require-binding name (`actor.state.X`).

**Gate**: `validate_rules.py` checks formula bindings against the
trigger's available context.

**Empirical 2026-05-16**: TDTE `gather_pickup` formula used
`self.state._last_slot` under signal+require — crashed on first
live pickup. Unit tests passed (synthesized their own context).
Same session also surfaced: ctx values that are entity-id strings
auto-promote to Entity (no allowlist needed for custom binding
names like `actor`/`pursuer`/etc.).

## Sync-derived fields used as filters must be pre-initialized

If tick rule X derives state.foo (via `array_sync_to_field`,
`array_count_matching`, `state_set`), and another rule filters on
state.foo, then state_init MUST include foo with a sentinel default.
Reason: phase ordering — input rules run BEFORE decide-tick (where
sync rules fire). Strict-missing query semantics fail the filter at
tick 1.

```json
"state_init": {
  "inventory": ["", "", "", ""],
  "active_slot": 0,
  "held_item": "",                  // pre-init derived
  "inventory_empty_count": 4
}
```

**Empirical 2026-05-16**: TDTE gather_pickup `require: {actor:
{state: {inventory_empty_count_gt: 0}}}` refused the first E press —
the derived field was unset at tick 1.

## NEVER ship a rule with `effect: []`

Engine `_load_rules_file` errors `[rule.effect_empty]` at load.
Typically a cleanup pass removed the last effect without removing
the now-no-op rule. Fix: delete the rule. If a placeholder is
needed for future wiring, use a trivial `state_set` of an unused
counter.

## Engine-injected input actions need `engine_injected: true`

Actions queued by the engine internally (e.g. `stop_x` / `stop_y`
queued by `_poll_input` on per-axis idle) aren't bound to keys.
Without the marker, InputRegistrar warns + skips them.

```json
{"name": "stop_x", "edge": "press", "engine_injected": true}
```

Marker preserves typo detection for normal actions (`jjjump` still
warns) while permitting legitimate keyless ones.

## Schema field-name landmines (memorize)

Wrong field name = silent failure (rule registers, never fires, no
error). Caught during the merchant build at ~30-50 occurrences each:

| Effect | Engine reads | Common wrong name |
|---|---|---|
| `state_add` | `amount` | ❌ `delta` |
| `state_mul` | `amount` | ❌ `factor` / `delta` |
| `spawn` | `template` | ❌ `def` |
| `state_clamp` | `min`/`max` | (correct) |

`validate_rules.py` checks the common ones.

## `self.nearest({...})` is NOT IMPLEMENTED

The formula evaluator returns null for it → downstream `.state.X`
crashes with "self ... instance is null". Use `trigger: contact` +
`query: {a, b, radius, once_per_a}` for pair-matching (engine
pre-binds both; formula references `b.X` directly). Tier 3 work
would need spatial-index integration + an ADR.

## 2-binding `{a, b, radius}` queries are CONTACT-only

`tick` / `signal` / `input` triggers fire via `_fire_scan_rule`,
which doesn't pair-match — the engine binds only `self` to the
FIRST sub-binding. Effects referencing `a` / `b` crash.

Three correct patterns:
1. `trigger: contact` if pair-matching IS the intent
2. Single-binding tick + `self.nearest({...})` formula (deferred —
   see above; not actually implemented)
3. Drop the partner condition if it was a soft proximity hint

**Gate**: `validate_rules.py` catches non-contact 2-binding queries.

## `query` vs `require` — NOT interchangeable

`query` SEARCHES for matching entities and binds them. `require`
VALIDATES bindings ALREADY in context against a filter — if the
binding isn't set elsewhere, `require` always fails.

To gate a tick rule on a singleton's state, use `query` (flat
pattern with `tags_all` + `state` filter), not `require`.

**Gate**: `validate_rules.py` flags `require:` keys not populated
by the trigger.

## `state_set` / `show_toast` values: human text vs formulas

`_value()` routes strings through `Formula.looks_like_formula()` →
`evaluate()` if it looks formula-shaped. Heuristic: requires a
formula-START char (lowercase / digit / `(` / `-` / `+` / `_` /
`@`). Capital-letter starts bypass parsing.

Safe (passes through as literal): `"Find your shop in Pendrel."`,
`"→ Open the shop"`, `"Day 6 — bailiff returns."`.

Treated as formula: `"world.gold"`, `"signal.sale_price"`,
`"a.state.hp + 10"`.

To make formula-shaped text literal, prefix with capital or `→`.

## Bindings in payload values are BARE, not `{...}`

❌ `"new_tier": "{world.reputation_tier}"` — formula parse fails on
the braces.
✅ `"new_tier": "world.reputation_tier"` (bare).

The merchant build had ~57 brace-wrapped bindings → 31,000+
formula.parse_failed per session.

## `velocity_add_relative` requires deceleration

Camera-relative WASD (FP + iso variants) uses `velocity_add_relative`.
Without decay, the previous tick's velocity in the OLD facing
direction lags the camera when the player mouse-turns mid-walk
(player feels "something pulling").

Any actor whose movement comes from `velocity_add_relative` MUST
declare ONE of:
- `state.zero_velocity_pretick: true` (engine zeros each tick →
  tight FPS feel)
- `state.drag > 0` (motion integrator decays each frame →
  momentum-glide feel)

Required for `isometric_3d` and `first_person_3d` camera modes;
world-frame `top_down_3d` / `third_person_3d` don't need it
(last-writer-wins per-axis).

## Logical/singleton entities need `visual: {hidden: true}`

Entities without a `visual.mesh` / `model_3d` / `shape` block fall
through to entity_mesh_3d.gd's tier-3 fallback = colored box at
`state.position`. For logical-only entities (clocks, score
trackers, camera anchors, zone markers, spawners), set
`visual: {"hidden": true}` so spawn_manager skips the renderer
attach.

| Entity purpose | visual block |
|---|---|
| Player / NPC / animal / prop | mesh / model_3d / shape REQUIRED |
| Singleton (world_clock, game_state) | `{"hidden": true}` |
| Camera anchor (`free_camera`) | `{"hidden": true}` |
| Zone marker / spawner | `{"hidden": true}` |

**Empirical**: 2026-05-21 free_cameras spawned as visible cubes
(no hidden flag); user noticed in free_cam mode.

## Mode-transition rules must reset state mutated by the OLD mode

When a state_set flips a field that gates downstream rules' queries
(e.g. `camera_mode`, `game_phase`), the transition rule MUST also
reset any field the old-mode's rules WROTE that:
1. The new mode's filter excludes from writing further, AND
2. Has no automatic decay (drag=0, no zero_velocity_pretick), AND
3. No queryable `stop_*` rule reaches in the new mode.

Canonical case: `velocity` from `velocity_add_relative` — survives
freecam transition because the WASD filter no longer matches +
ADR-0048 auto-reset doesn't fire + drag=0.

Fix: add `velocity_set actor x:0 y:0` to the transition's effect
list (input-triggered rules bind `actor` to the input source).

Common state fields needing reset: `velocity`, `facing`, `aim_target`,
`charge_progress`, `pending_action`.

**Empirical 2026-05-21**: freecam_enter from FPS without velocity
reset → player drifted while W held until release.

## `state.velocity` dimensionality — Vector2 for floor-walkers

WASD lib bundle uses `velocity_set y:` meaning "second component of
velocity." Renderer + character_body_runner lift Vector2(x, y) →
Vector3(x, 0, y). Vector3 velocity makes `y` world-UP — W launches
the player upward.

✅ Floor-walking actor (player, NPC, animal): `"velocity": [0, 0]`.
✅ Vector3 OK for 3D-movers (projectiles, flying mobs, elevators).

**Empirical 2026-05-10**: aldenmere player + 8 villagers + 3 animals
shipped with `[0,0,0]` velocity → W made the player fly up. User
feedback: "why is my 'w' up and down not on the floor."

## World-state singleton pattern

Engine does NOT query `env.world_state` directly. For global state,
use a singleton entity tagged `world_clock`/`game_state`/etc. with
all global fields in `state_init`. Rules query via
`tags_all: ["world_clock"]`; effects mutate via
`target: "<entity_id>"`.

HUD bindings work BOTH ways but for different stores:
- `world.X` reads `env.world_state` dict (set by
  `state_set target=world`)
- `<entity_tag>.X` reads the first entity with that tag

Pick ONE source-of-truth per piece of state — mixing means
mutations on one store don't show up reading the other.

## DON'T

- ❌ Hardcode entity ids in engine code or formula evaluator
  shortcuts. Use documented bindings: `self`, `target`, `a`, `b`,
  `world`, plus payload fields.
- ❌ Add semantic effect type strings (`damage`, `need_decay`,
  `heal`, `gain_xp`, `attack`). Express as `state_add`/`state_set`
  with semantic field names in JSON.
- ❌ Hardcode coordinates assuming a specific renderer. Use the W5.0
  convention: same JSON works in both 2D and 3D via `position_scale`.
- ❌ Reach into engine source paths from data. `mesh`/`shape`/`model_3d`
  reference `res://data/...` only, never `res://scripts/...`.

## DO

- ✅ **Tag liberally.** Tags are free; queries depend on them.
  Anti-tag with `tags_none` for exclusion.
- ⚠️ **`blocks_motion`** (ADR 0004) requires `properties.aabb_extents:
  [hx, hy, hz]`. Motion integrator slides around the AABB. Example:
  `tags: ["wall", "blocks_motion"], properties: {"aabb_extents":
  [22, 1.5, 0.25]}`.
- ✅ **`state_init`** holds both static initial values AND mutable
  state — engine doesn't enforce the split.
- ✅ **`_comment` keys** are ignored by the engine; use them for
  design intent.
- ✅ **Formula whitelist**: bindings, math helpers (`clamp`, `min`,
  `max`, `abs`, `sin`, `cos`, `sqrt`, `pow`, `floor`, `ceil`,
  `lerp`, `randf`), arithmetic, comparison, bitwise, Vector2/Array
  subscript. No function calls outside the math helpers.
- ⚠️ **Ternary `a if cond else b` is BROKEN** in Godot 4.6.1's
  Expression — parses but always returns the IF branch. Workaround:
  `move * clamp((cond_lhs - cond_rhs) * 1e6, 0, 1)`. Older demos
  (harvestcore, tinypond) using ternary silently took IF.

## Schema sketch

```jsonc
{
  "definitions": [
    {
      "id": "wheat_seed",                    // unique
      "tags": ["plant", "crop", "seed"],     // membership
      "properties": {"material": "wheat", "max_growth": 100},  // STATIC
      "state_init": {"growth": 0, "wet": 0.0},                  // DYNAMIC
      "visual": {"sprite_2d": "res://...", "shape": "tree",
                 "color": "#a0c050"}
    }
  ],
  "initial_instances": [
    {"def": "wheat_seed", "id": "w1", "position": [10, 5]}
  ],
  "initial_relations": [
    {"type": "on_square", "from": "wp1", "to": "sq_a2"}
  ]
}
```

Rules JSON (per `docs/guideline/30_framework_primitives.md` §3):

```jsonc
{
  "rules": [{
    "id": "unique_rule_id",
    "trigger": {"type": "tick", "interval": 1},
    "query": {"tags_all": ["plant"], "state": {"wet_lt": 0.5}},
    "require": {"context_role": {"tags_all": [...]}},  // optional
    "chance": 0.3,                                       // optional
    "effect": {...} | [{...}, {...}],
    "before": ["other_rule"], "after": ["another_rule"]  // optional
  }]
}
```

## Validation

When adding a demo, verify:
1. `Rule.validate_all()` (structural)
2. Tags consistent (no typos in `tags_all` / `tags_none`)
3. Formulas parse
4. Demo runs in both 2D and 3D scenes (if applicable)
5. Goal-state cascade reaches expected end state in soak test
