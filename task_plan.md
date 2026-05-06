# Yume — Universal Simulation Framework

_Last updated: 2026-04-22_

---

## Motivation

Game engines are plumbing — scene graph, physics, rendering. **Game logic** is
rebuilt from scratch in every project: needs, HP, damage, XP, crops, fire,
projectiles, dialogue triggers. Same five patterns with different nouns.

We want a framework where:

1. **Game logic is content, not code.** Adding hunger, HP, ammo, XP, fire
   spread, crop growth, projectile damage is a JSON edit. Never a script edit.
2. **The same engine runs every simulation-shaped game.** Ecology, farming,
   shooter, RPG, survival, tower-defense, roguelike, puzzle-with-state — all
   on one GDScript substrate, differing only in `data/`.
3. **Things really live.** When you give the engine a property-driven world and
   walk away, it keeps simulating. Fire spreads, crops ripen, iron rusts.
   Agents (later) operate on a world that was already alive.

This inverts the usual game-dev process: instead of writing a shooter then a
farming game then an RPG, we write **one engine** whose primitives can express
all of them. Game = `data/`.

---

## North Star

> Describe a game in natural language. Yume produces the JSON. The same
> engine runs it. Any simulation-shaped game, any data-driven rules,
> discrete-tick physics.

Three layers, all needed:

1. **Design layer** (Tier 2.5): prose → structured GDD (Mechanics / Dynamics
   / Aesthetics)
2. **Spec layer** (Tier 2.5): GDD → entity defs + rule specs, ADR-tracked
3. **Runtime layer** (Tier 2): seven primitives (Entity, Tag, Rule, Trigger,
   Effect, Query, Relation), all JSON-driven, genre-agnostic. No genre-
   specific engine code, ever.

**Success smell test:** user types *"a farming game where crops grow faster
in moonlight and rot in direct sun"*. Yume produces validated JSON that runs
immediately. Then: ecology, shooter, RPG, chess all generate the same way.
Engine never changes. New games = new prose, which becomes new JSON.

**Honest scope:** simulation-shaped games only. Non-goals: rhythm, precision
platformers, continuous physics, narrative-heavy adventures. See
`docs/31_text_to_game_pipeline.md` for full analysis.

---

## Strategic reframe (2026-04-22)

Earlier framing positioned this as "agent simulation" with a world as the
playground. We inverted it. **The world engine is the primary deliverable.**
Agents are just one kind of entity expressible on top of it — Tier 3 work,
not Tier 2.

This simplifies everything:
- Combat, farming, survival, shooter, chess — all the same seven primitives,
  different content.
- No distinction between "agent logic" and "world logic" — it's all rules.
- Player, AI, LLM brain all emit the same `input` trigger stream. Engine
  treats them identically.

The original agent substrate (5 brains, inventory, needs, recipes) is being
**redesigned, not preserved**. Git keeps the old code; Tier 3 rebuilds agent
content from the new primitive vocabulary.

**Yume3D test instance as 3D reference (interim, terminates at W5.0c).**
The pre-redesign 3D farming sim lives at
`/mnt/c/Users/kamwoh/Documents/Projects/Godot/Yume3D/` (not git-tracked).
It runs today and shows the visual target — terrain, named agents,
composite buildings, GLB models. It is **not** being merged back into the
new framework (its substrate violates invariant #8). **Termination:** the
moment W5.0c lands `world_3d.tscn` and runs the proof-of-life demo, drop
this note. Two reference points = drift; one is the framework's own 3D
demo from then on.

**Design contract:** see `docs/30_framework_primitives.md` for the full spec
of the seven primitives, JSON schema, and invariants. Everything below traces
back to that doc.

---

## Conceptual Ladder (where we are)

| Level | What it is | Status |
|---|---|---|
| **L0 — Engine primitives** | Seven composable primitives (Entity, Tag, Rule, Trigger, Effect, Query, Relation), all JSON-driven, genre-agnostic. | 🟡 in progress (Tier 2, this plan) |
| **L1 — Rich world** | 40+ entities, 30+ reactions. Cascades: wet wood resists fire, dry heat ignites, rain soaks, crops rot. Observable without agents. | 📋 Tier 2 final phase |
| **L2 — Acid-tested framework** | Five genre demos (ecology, farming-3D, shooter, RPG, chess) all run from identical engine, different JSON, **including one 3D demo via renderer_3d (W5.0)**. Tests universality across genres AND renderers. | 📋 Tier 2 gate |
| **L2.5 — Text-to-game pipeline** | Prose → GDD → entity+rule JSON via specialist agents + ADR discipline. Cheap pulls alongside W2+; full build after Tier 2 exit. | 📋 Tier 2.5 (new, 2026-04-23) |
| **L3 — Actors** | Entities that observe and emit inputs. Player, scripted AI, LLM — same channel. Agent content rebuilt on new primitives. | 📋 Tier 3 |
| **L4 — Persistence + scale** | Save/load, time acceleration, host/client, episode recorder. | 📋 Tier 4 |

We are starting **L0**. Previous work on Tier 1 (agent-farming loop, 5 brains,
Vector2 pivot) is the proof that the underlying ideas work — but the code
needs redesign to honor the universality invariant.

---

## Current Objective (2026-04-22) — World Engine Redesign

Build the seven primitives. No agents. No game goal. No driver. Pure engine.

Two reasons to redesign rather than extend:
1. Current rules engine has **semantic effects** (`damage`, `need_decay`,
   `advance_stage`). That's the exact anti-pattern we want gone.
2. Agent-side code (brains, inventory, recipes, needs) is intertwined with
   world-side code. Clean separation is easier as a rebuild than a refactor.

**The 2D track is the new active track.** 3D is deferred to later renderer work
(same primitives, just different visualization). 2D is easier to debug the
reaction cascades in, and removes the Kenney-pivot/GLB friction tax.

---

## Roadmap — Tier 2 World Engine

### W0 — Throwaway spike — **COMPLETE (2026-04-22)**

The acid test used to sit at the end of a 5–7 week push. That violates
goal-driven-execution: universality would go unverified until week 5, and
any discovery of a missing primitive would cost weeks. W0 shrank the
discovery loop to hours.

Built a single-file GDScript prototype (~700 lines) running in Godot 4.6
headless. Nine demos ran against one engine.

- [x] **W0.1** Single-file GDScript evaluator (`spike/engine.gd`): entity dict,
  rule list, relation store, four-phase tick loop, formula eval via Godot
  `Expression`.
- [x] **W0.2** JSON schemas for entities + rules + relations.
- [x] **W0.3** Trivial smoke test — tick loop + `state_add`. ✅ PASS
- [x] **W0.4** Ecology mini — `contact` trigger + `wet_lt 0.3` property match. Dry
  tree ignited, wet tree resisted. ✅ PASS
- [x] **W0.5** RPG mini — state thresholds + `signal` chain. Level-up triggered
  from xp ≥ 100, hp/xp/hp_max all updated. ✅ PASS
- [x] **W0.6** Farming mini — `input` trigger + `emit` → signal + `relate`
  (`held_by`). Harvest input removed wheat, spawned item, related to player. ✅ PASS
- [x] **W0.7** Shooter mini — `velocity_set` + engine motion + `contact` +
  mutual `remove`. Bullet flew, hit, both entities removed. ✅ PASS
- [x] **W0.8** Chess mini — Relation + turn flow + illegal-move rejection.
  Exposed the `require` primitive gap (see below); fixed and re-ran. ✅ PASS
- [x] **Bonus stress_physics** — real formula (`(a.T - b.T) * 0.5`) via
  `Expression`, `transform` effect, contact radius excluded distant entity. ✅ PASS
- [x] **Bonus stress_ordering** — rule definition order + formula-at-apply-time.
  `10 + 5 + (15 * 0.1) = 16.5` confirmed. ✅ PASS
- [x] **Bonus stress_lifecycle** — `spawn`/`despawn`/`relation_changed` triggers.
  Initial load fired 3 spawn events; runtime spawn + destroy counted; pickup
  triggered `relation_changed` → `tag_add`. ✅ PASS
- [x] **W0.9 Exit criterion:** 9/9 demos pass on one engine.

**Findings that revised the contract** (see `docs/30_framework_primitives.md`):

1. **`require` clause** (new rule field). Chess exposed this. Rules carrying
   entity references in payload (input/signal/relation_changed) couldn't
   filter on those entities' properties. `require: {ctx_name: query_spec}`
   validates each named context entity. Without it, white-turn rule matched
   black-piece inputs. Generalized to all context-carrying triggers.

2. **Formula timing = apply-time, not queue-time.** Within commit, formulas
   in later effects read state mutated by earlier effects. Documented as the
   intended sequential-write semantics.

3. **Effect target resolution.** `target: "self"` → context binding;
   `target: "tracker_1"` → literal entity id. Same field, both meanings.

4. **Lifecycle flush at load.** Spawn triggers fire for initial entities;
   their effects must flush before first tick (not at tick 1).

**What wasn't stress-tested (deferred to W1+):**
- `scheduled` trigger (reserved for rhythm; post-W5 per contract).
- Formula AST whitelist + parsed-expression caching (W4 tasks).
- O(n²) contact at scale (W3 spatial index).

**Deliverable:** revised `docs/30_framework_primitives.md`. Spike code
**deleted** per throwaway contract — no carry-over into W1.

### W1 — Primitive schema + 2D baseline (~1 week)

Goal: minimal runnable 2D scene with the new primitive engine. No reactions
yet, but the data shape is final.

- [x] **W1.1** Write `docs/30_framework_primitives.md` (contract doc).
- [x] **W1.2** Strip agent-side code. Deleted via `git rm`:
  5 brain_*.gd + inventory.gd + hp_bar.gd + needs_hud.gd + agent_needs_panel.gd
  + world_rules_engine.gd (rewritten in W1.7) + entire `renderer_3d/` folder
  (brain-dependent; rebuilt in Tier 4.3 from new primitives).
  Kept: `sim_pos.gd`, `world_clock.gd`, `pathfinding_astar.gd`, `minimap.gd`.
  `recipes.json`/`needs.json` live downstream in Yume3D test instance — not
  framework-tracked.
- [x] **W1.3** Write `scripts/engine/entity.gd` — generic Node2D subclass.
  Holds `def_id`, `instance_id`, `properties`, `state`, `tags`, `visual`. Factory
  `Entity.create(def, inst_id, overrides)` handles spawn-time merges. No subclasses.
- [x] **W1.4** Write `scripts/engine/rule.gd` — Rule class with `from_dict`,
  `load_from_file`, `validate_all` (structural checks: id/trigger type/chance
  range/effect list). Before/after hints as typed `Array[String]`, `runs_before`/
  `runs_after` for phase-scheduler use. Expression cache slots (`cache_expression`/
  `cached_expression`) for W4.
- [x] **W1.5** Write `scripts/engine/query.gd` — QueryLib class. `matches(ent,
  spec, env, context)` for single-entity test; `run(spec, env, context)` for
  scan. Supports `properties`, `state`, `tags_all/any/none`, operators
  `_eq/_ne/_gt/_lt/_gte/_lte/_atleast/_atmost`, `relations` clause (string or
  nested query target), `radius` + origin resolution (`_origin_position` →
  `context.self` → zero), `order_by` (`distance_asc/desc`), `limit`. Strict:
  missing field = no match. env carries `entities` map + `relations` store.
- [x] **W1.6** Write `scripts/engine/effect_apply.gd` — EffectApply.apply(effect,
  env, context) dispatches to 13 handlers: `state_set/add/mul/clamp`, `spawn`/
  `remove`/`transform` (preserves state via overrides), `relate`/`unrelate`/
  `transfer_relation` (to/from swaps), `tag_add/remove`, `velocity_set` (W2 wires
  motion integrator). `emit` routed by phase_scheduler, not here. Target
  resolution per contract: context binding first, literal id fallback. Value
  resolution is literal-only in W1 (W4 adds formula wrapper).
- [x] **W1.7** Write `scripts/engine/relation_store.gd` — directed multigraph
  with both-direction indexes (`_from_idx`, `_to_idx`). Dedup at insert.
  API: `relate`/`unrelate`/`transfer_to`/`transfer_from`, `targets`/`sources`/
  `has_edge`/`count`/`all_of_type`, `clear_entity` (despawn cleanup),
  `snapshot`/`restore`. Signals `relation_added`/`relation_removed` for
  `relation_changed` trigger dispatch (W2). Pulled forward from W1.7 → before
  W1.5 since query's `relations` clause depends on it.

- [x] **W1.8** Write `scripts/engine/phase_scheduler.gd` — four-phase tick
  loop (`input` / `decide` / `commit` / `react`). Effect write-buffer +
  `flush_effects()` between phases. Rules bucketed by trigger type;
  within-bucket bubble-sort via `runs_before`/`runs_after` with cycle
  warning. W1 wires tick rules in `_phase_decide`; input/react are W2
  extension points (stubs). Require-clause validation integrated.
- [x] **W1.9** Write `scripts/engine/world.gd` (replaces old `world_rules_engine.gd`
  naming per contract) — top-level Node2D orchestrator. Owns entities map,
  defs map, RelationStore, PhaseScheduler, WorldClock, world_state. Exports
  `data_root`, `auto_start`, `tick_seconds`, `verbose`. `load_data()` loads
  rules → world → entities (order honors W0 lifecycle-flush finding).
  `start()` wires clock → scheduler.tick. `queue_input`, `entity(id)`,
  `count_entities_matching`, `count_relations_of` public API. Also moved
  `world_clock.gd` into `scripts/engine/` with `class_name WorldClock` and
  programmatic `tick_seconds` (no more global meta.json read).
- [x] **W1.10** Write `scripts/renderer_2d/entity_sprite_2d.gd` — Node2D
  child of Entity. Reads `entity.visual.sprite_2d` → draw_texture, or falls
  back to colored circle via `visual.color` / `visual.radius`. Swappable
  (World.renderer_script export; "" disables for headless tests).
- [x] **W1.11** Minimal `scenes/world_2d.tscn` — root `World` Node2D with
  script, Camera2D child. Also added `project.godot` (framework now a
  runnable Godot project, not just a template). **Verified with first
  headless run.**
- [x] **W1.12** Demo: one `wheat_seed` entity, one `crop_grows` tick rule.
  Ran headless in Godot 4.6 for 600 frames (5s real). Output:
  `[tick 2] growth=2.0 ... [tick 8] growth=8.0`. **Proof of life — Entity +
  Rule + QueryLib + EffectApply + PhaseScheduler + World + WorldClock all
  work end-to-end.**
- [x] **W1.13** **Tests (ship-with-phase):**
  - `scripts/engine/tests/test_runner.gd` + `scenes/test_main.tscn` —
    consolidated unit tests across all 7 primitives.
  - Coverage: Entity (create/tags/state/velocity/snapshot/overrides), Rule
    (from_dict/effect-list normalization/before-after/validate_all),
    RelationStore (relate/unrelate/transfer/dedup/clear_entity/snapshot),
    QueryLib (tags all/any/none, property + state operators incl strict
    missing-field, radius+origin, limit, order_by, matches single-entity),
    EffectApply (state_set/add/mul/clamp, tag_add/remove, target as literal
    id, relate/unrelate, spawn with forced id, remove, transform with state
    preservation), Schema validator smoke (Rule.validate_all rejects empty
    id, missing effect type, out-of-range chance).
  - **Run: `godot --headless --path . scenes/test_main.tscn`**
  - **Result: 77/77 pass.** Proof-of-life demo (world_2d.tscn) still green
    post-test addition. Python schema validator (`yume test` CLI) deferred
    to W2.8 — in-engine smoke validates the same paths.

- [x] **W1.14** **Renderer-agnostic Entity refactor** — surfaced by W5.0
  review (2026-05-01). Paid the architectural debt at W1 instead of carrying
  it as hidden cost into W5.0.
  - W1.14a `entity.gd` now `extends Node`; position lives in
    `state.position` as Vector2 or Vector3. Helpers: `get_position()`,
    `set_position()`, `get_planar_position()` (XZ projection for 2D radius
    queries on 3D positions). Snapshot serializes Array of length 2 or 3.
  - W1.14b `renderer_2d/entity_sprite_2d.gd` is now a Node2D child of an
    Entity (plain Node parent — no parent transform). Reads
    `entity.get_planar_position()` each `_process` to update its own
    `position`. Sprite/circle drawing unchanged.
  - W1.14c `effect_apply.gd` updated: transform preserves position via
    `state.position` (no separate `pos` field needed); `_position()` returns
    Variant (Vector2 or Vector3); spawn position override flows through
    state.
  - W1.14d query.gd uses `get_planar_position()` for radius + order_by;
    handles Vector3 origin in `_resolve_origin`.
  - W1.14e new `test_renderer_agnostic` (W1.14e) section in test_runner —
    9 new assertions: Entity is `Node` (not Node2D/Node3D), position
    round-trips Vector2 + Vector3, planar projection works, state-position
    round-trips through snapshot. **86/86 tests pass** (77 + 9 new).
  - **Farm demo still runs identically** post-refactor (same tick output).

  Reviewer's call was right: W2 is about to add motion + input + signal/
  contact triggers. Each touches position. Refactoring later would have cost
  weeks. ~1 day actual work to pay it now.

### W2 — Triggers beyond tick + motion (~1 week, COMPLETE except W2.7a + W2.8)

- [x] **W2.1** `signal` trigger: named broadcast. Any rule's effect can include
  `{type: "emit", signal: "X", payload: {...}}`. Rules with `trigger: {type:
  "signal", name: "X"}` fire on receipt. Signals emitted in `react` phase
  queue into the **next tick's** `input` phase.
- [x] **W2.2** `input` trigger: binds to Godot input action names. `input:
  "move_left"` fires the rule while the action is pressed.
- [x] **W2.3** `spawn` / `despawn` triggers: fire once per entity at lifecycle
  points. Useful for setup/cleanup effects.
- [x] **W2.4** `relation_changed` trigger: fires when an edge is added/removed
  matching a pattern (`{relation: "held_by", event: "added"}`). Dispatched
  in the `react` phase right after the commit that produced it.
  *(Status: ✅ done — RelationStore signals connected to scheduler;
  `_relation_changes` buffer drained in react.)*
- [x] **W2.5** `velocity_set` effect + **per-frame** motion integrator
  (decoupled from tick rate for smooth visuals — motion runs in
  `World._process(delta)`, velocity in units/sec; tick is rules only).
  Dimension-agnostic — works for Vector2 + Vector3 positions/velocities.
- [x] **W2.6** Reserved hooks documented in code comments. `scheduled` and
  `world_clock.paused` remain valid trigger types in VALID_TRIGGERS list,
  not yet dispatched.
- [x] **W2.7** Demo: WASD moves a player; space emits sparkle signal;
  spawn rule spawns sparkle at player position; tick rule decays sparkle's
  life; despawn rule increments counter. `data/entities.json` + `data/world_rules.json`
  + project.godot input map (W/S/D/A + arrows + space). World polls
  `Input.is_action_pressed` per frame and queues input events with
  `actor` resolved by `actor_tag`. **End-to-end verified via W2 integration
  test (94/94 pass) — input → emit → spawn → counter++ → tick decay →
  remove → despawn → counter++.**
- [x] **W2.7a** Config-driven shape library + three-tier fallback.
  - `scripts/engine/shape_lib.gd` — loads `data/shapes.json`, `has(name)` /
    `get_shape(name)` / `merge_params(shape_def, instance_params)`.
  - `scripts/renderer_2d/entity_sprite_2d.gd` — three-tier interpreter:
    Tier 1 sprite_2d file → Tier 2 shape from library → Tier 3 bare circle.
  - Engine knows DRAW primitives only: `circle`, `rect`, `polygon`, `line`
    (text + texture stubbed). Adding "lantern" or "scarecrow" is a
    `shapes.json` edit; engine code never changes.
  - `$param` substitution: shape defaults overridable per-entity via
    `visual.params`. Resolves at draw time.
  - `data/shapes.json` ships 16 shapes: tree, rock, person, water, fire,
    building, weapon, food, crop_seed, crop_young, crop_mature, crop_rotten,
    sparkle, marker, square, triangle.
  - Player demo (`data/entities.json`) updated to use shape names —
    12 entities now render as recognizable visuals instead of colored
    circles.
  - `meshes.json` (3D equivalent) lands in W5.0 with renderer_3d.
- [x] **W2.8** **Tests (ship-with-phase):** mostly through W2 consolidated
  integration test (input→signal→spawn→despawn cascade) + W2.7a shape_lib
  test. Per-trigger integration fixtures (`signal_roundtrip/`,
  `input_velocity/`, `spawn_despawn_hook/`, `relation_changed_fires/`) as
  separate folders deferred to W3 ship-with-phase. Current coverage:
  102/102 assertions pass.

### W3 — Spatial index + contact reactions (COMPLETE)

- [x] **W3.1** `scripts/engine/spatial_index.gd` — grid-bucket hash,
  configurable `cell_size`. API: `update_entity(id, pos)`, `remove_entity(id)`,
  `query_radius_ids(origin, r)`, `query_radius(origin, r, entities)`. Wired
  into env; updated by World on spawn/motion/despawn. QueryLib uses
  spatial_index to narrow radius queries (avoids full O(n) scan).
- [x] **W3.2** `contact` trigger pair matcher in scheduler. `query: {a, b,
  radius}`. For each entity matching `a`, queries spatial index within
  `radius` for entities matching `b`; fires effect for each pair with `a`/`b`
  context bindings. Fires in `react` phase. Chance + require both supported.
- [x] **W3.3** Effect lists already supported via `Rule._normalize_effects`
  from W1.4. `effect: {...}` and `effect: [{...}, {...}]` both work.
- [x] **W3.4** Demo: ecology cascade. 1 fire + 12 trees + 1 water + 3 rocks.
  Fire ignites tree → tree transforms to burning_tree → spreads to neighbors
  (radius 75, chance 0.4) → fuel decays → burns out to ash → water
  extinguishes nearby burning trees. Verified: 24 ticks (~12s real), 11
  trees → ash, 1 saved by water. **Proof of cascades without agents.**
- [x] **W3.5** **Tests (ship-with-phase):**
  - `test_spatial_index` — 5 assertions: update/move/remove/empty
  - `test_contact_rules` — 5 assertions: ignite within radius, no-ignite
    outside, water extinguish, multi-rule order
  - **112/112 unit tests pass total** (was 102 before W3).

### W4 — Formula layer (COMPLETE — minimum viable; advanced features deferred)

- [x] **W4.1** `scripts/engine/formula.gd` — wraps Godot's `Expression`.
  Path-substitution approach: dotted paths in formulas (`self.state.hp`,
  `world.tick`, `a.properties.hardness`) get rewritten to placeholder vars
  before parsing; values resolved per-call. Bindings supported: `self`,
  `target`, `a`, `b`, `source`, `world`. Math helpers (`clamp`, `min`, `max`,
  `abs`, `sin`, `cos`, `sqrt`, `pow`, `floor`, `ceil`, `lerp`, `randf`)
  come from Godot's built-in Expression — no extra registration needed.
- [x] **W4.2** Effect numeric fields accept formula strings via
  `EffectApply._value()`. State fields, amounts, factors, velocity components
  all flow through `Formula.evaluate`. Detection via `Formula.looks_like_formula`
  heuristic (operators or dotted paths present).
- [ ] **W4.3** Query operators accept formulas — *deferred*. Current path
  resolves literal values only in `_match_fields`. Formula support requires
  threading `env` into `_match_fields` for context. Workaround: per-tick
  rule with formula-driven `state_set` then `state` query reads result.
- [x] **W4.4** **Parsed-expression caching.** Static `Formula._cache`
  keyed by rewritten-formula + input-name signature. Compile once, execute
  many. Verified by test (3 evals → cache size delta ≤ 1).
- [ ] **W4.5** **AST whitelist** — *deferred to W6 / Tier 2.5*. Documented
  in `formula.gd` header as known security gap. Yume is single-user, content
  is trusted; whitelist becomes essential when sharing JSON across users.
- [x] **W4.6** Load-time validation — `Formula.validate_syntax(formula)`
  returns "" on success or error string. Used opportunistically; full
  pass-over-all-formulas at load is W6 polish.
- [x] **W4.7** `world.*` bindings — `world.tick` already set by scheduler
  (`world_state["tick"] = tick_count`). `world.time_of_day` etc. are
  user-defined keys in `world_state` from `data/world.json`. Tested.
- [ ] **W4.8** Formula perf pass — *deferred to W6*. Cache hit ratio and
  per-eval timing should be measured before scaling to ~500-pair contact
  scenes. Current scale (~50 entities, ~10 contact rules) is well within
  budget on a desktop.
- [ ] **W4.9** Heat-falloff demo — *deferred*. Cascade demo (W3.4) already
  exhibits formulaic-style emergent behavior via state thresholds + chance;
  pure formula-driven heat falloff (`1/d²`) waits for spatial helper
  bindings (`self.nearest`) which are Tier 3.
- [x] **W4.10** **Tests (ship-with-phase):**
  - 13 assertions in `test_formulas`: heuristic detector, basic arithmetic
    paths, math helpers (clamp, abs), world bindings, multi-role (a/b)
    formulas, missing-field strict semantic, cache hit, end-to-end
    `state_add` with formula amount.
  - **125/125 unit tests pass total** (was 112 before W4).

### W5 — Genre acid test (~3–4 weeks)

Five demos. Identical engine. Different `data/<demo>/` folders + (for one)
a different renderer. **No GD edits permitted during demo authoring** except
to fix genuine engine bugs and to land the prerequisite renderer_3d.

**Strategic revision (2026-05-01):** the acid test must prove **two
independent claims** — and they should be tested separately:

1. **Rule-genre-agnostic** (invariant #1, 2): one engine expresses ecology /
   farming / shooter / RPG / chess via JSON only. Tested by W5.1–W5.5.
2. **Renderer-agnostic** (invariant #8): the same engine + same JSON renders
   under different renderers. Tested by W5.0e parity hot-swap.

These are separate. A failure of one doesn't imply a failure of the other.
Conflating them was a draft mistake.

The 3D farming demo (W5.2) is the **visual capability proof** — answers "can
the new framework do what Yume3D did?" — but is independent from the
acid-test claims above.

**Cost:** +2-4 weeks honest (originally said +2; reviewer flagged that
optimistic). Reimplementation work in W5.0 is bigger than "harvest patterns"
language suggested. Tier 2.5 timing slips by the same delta — flagged
explicitly so we're not surprised.

#### W5.0 — Renderer parity prerequisite (~2-3 weeks)

**Layout note:** renderers live at `scripts/renderer_2d/` and
`scripts/renderer_3d/` — **siblings of `scripts/engine/`**, not under it.
The renderer is not engine; it reads engine data and projects it to a view.

**Coordinate convention for shared 2D/3D demos:** sim-space coordinates are
**XZ-planar**. 2D `Vector2(x, y)` maps to 3D `Vector3(x, 0, y)`. Y in 3D is
height (decorative — terrain heightmap output). Distance and contact queries
operate on planar XZ projection. This means a `radius: 1.5` in ecology means
1.5 planar units in either renderer. **Any demo authored against Y-axis
distances is inherently 3D-only and not subject to W5.0e parity.**

- [x] **W5.0a** `scripts/renderer_3d/entity_mesh_3d.gd` — Node3D host that
  attaches `MeshInstance3D` children to an Entity. Three-tier fallback:
  `model_3d` file (PackedScene/Mesh) → `mesh` from meshes.json composite →
  bare colored box. `position_scale` export (default 0.05) maps 2D pixel
  positions to 3D world units. Falls back to `visual.shape` if `visual.mesh`
  absent — lets shared data files work in both renderers.
- [x] **W5.0b** `data/meshes.json` — 9 composite meshes (tree, rock, person,
  water, fire, building, ash, burning_tree, marker). Mesh primitive
  vocabulary in renderer code: `box`, `sphere`, `cylinder`, `capsule`,
  `plane`, `prism`, `torus`, `quad` — Godot's `PrimitiveMesh` types.
  `$param` substitution for color/size, same as `shapes.json`.
  `mesh_lib.gd` mirrors `shape_lib.gd` API.
- [x] **W5.0c** `scenes/world_3d.tscn` — Node-based scene with Camera3D
  (positioned at (0, 8, 8) angled-down), DirectionalLight3D with shadows,
  WorldEnvironment + ProceduralSky, ground plane. **`World` script is now
  `extends Node` (was Node2D)** — both `world_2d.tscn` and `world_3d.tscn`
  share the same orchestrator script, differing only by `renderer_script`
  export and scene-tree siblings.
- [ ] **W5.0d** Yume3D pattern reimplementation — *deferred*. Camera3D in
  world_3d.tscn is static (no orbit/follow yet); terrain is a flat plane
  (no heightmap); GLB part composition not yet implemented (Tier 1 covers
  PackedScene loading but not the multi-part tinting Yume3D had). These
  land when first 3D demo demands them.
- [x] **W5.0e** **Renderer parity test.** `test_renderer_parity` in
  test_runner: runs identical engine + rules + data twice with no renderer
  attached, asserts state identical. Plus runtime confirmation: both
  `world_2d.tscn` and `world_3d.tscn` load same `data/` and produce
  identical tick output. **Engine is renderer-blind — invariant #8 verified.**
- [x] **W5.0f** **Tests:** `test_mesh_lib` (5 assertions — load/has/get/
  param-merge), `test_renderer_parity` (8 assertions — state identity
  across runs, plain-Node guarantee). **138/138 unit tests pass total**
  (was 125 before W5.0).

#### Demo set (one is 3D)

- [x] **W5.1 Ecology demo** (`data/demo_ecology/`) — 11 entity types,
  28 instances, 18 rules. No player. Self-sustaining cycles:
  - **Fire cascade:** fire ignites adjacent trees (radius 50, chance 0.5);
    burning_trees spread (radius 70, chance 0.35); fuel decays per tick;
    burns out to ash. Water extinguishes burning trees. ~9 trees → ~6 ash
    in first ~40s.
  - **Plant regeneration:** ash ages, then transforms to grass with chance
    after age≥8. Closes the carbon cycle.
  - **Animal life:** 4 rabbits, 2 foxes. Hunger decays per tick; hunger≤0 →
    starve damage; hp≤0 → remove. Rabbits eat grass (contact+remove);
    foxes eat rabbits (contact+remove); both drink water (contact+heal).
    Random wander via velocity_set with formula `(randf() - 0.5) * 50`.
  - **Verified end-to-end:** 2.5min headless run shows trees 9→3, ash
    cycle through grass, predation reduced rabbit count (fox catches
    occurred). Both `world_2d.tscn` and `world_3d.tscn` load same data —
    invariant #8 confirmed at the demo level.
- [x] **W5.2 Farming demo** (`data/demo_farming/`) — primary visual
  reference for Yume3D-equivalent capability. **Runs identically in 2D
  (`scenes/farming_2d.tscn`) and 3D (`scenes/farming_3d.tscn`).** 16 defs,
  27 instances, 10 rules.
  - **Player + 3 named villagers** (Iris/Bjorn/Elara — different shirt colors)
    with WASD movement (player) + random wander (villagers).
  - **Crops at staggered growth stages** auto-cycling seed → young → mature
    via tick rules + state thresholds.
  - **Harvest mechanic**: player contacts mature crop within radius 35 →
    spawns `food_wheat` at player + removes crop. Crop respawns on next tick
    if seeds remain.
  - **Three buildings** (oak house, pine house, barn) using composite shape
    "building" with custom `params` for wall/roof colors.
  - **Trees, water pool, campfire, rocks** for environmental context.
  - Verified: 30s headless run shows crop maturation cascade (young→mature),
    27 entities load identically in both renderers.
  - **Deferred:** buildings via explicit `part_of` relations (currently each
    building is a single composite); GLB model loading; orbit camera. These
    land when Tier 4.3 polish demands them. Current shape-composition gets
    most of the visual fidelity Yume3D had.
- [x] **W5.3 Shooter demo** (`data/demo_shooter/`) — top-down arcade
  shooter, 12 entities, 16 rules. WASD = move, IJKL = fire bullets in
  cardinal directions. Bullets travel via velocity, age out (lifespan
  state), damage enemies on contact (formula `"-a.state.damage"`),
  remove themselves. Enemies die at hp ≤ 0; despawn trigger increments
  score counter.
  - **Enemy AI** via contact-pair rule with radius 1000 (effectively
    omniscient): each tick, sets enemy velocity toward player using
    formulas `"(b.state.position.x - a.state.position.x) * 0.4"`. Required
    extending `Formula._resolve_path` to support Vector2 `.x`/`.y` access
    (Vector3 too, for 3D scenes).
  - **Input edge handling.** Movement = HOLD (`is_action_pressed`); fire =
    PRESS (`is_action_just_pressed`). Split via `input_actions_hold` /
    `input_actions_press` exports on World — prevents bullet-spam when
    fire keys are held.
  - **Verified end-to-end** by `test_shooter_cascade`: queue_input fire →
    bullet spawns → contact fires same tick → enemy hp drops by formula
    amount → 3 hits → enemy removed.
  - Both `shooter_2d.tscn` and `shooter_3d.tscn` load same data.
  - **145/145 tests pass** (was 138 → +7 for shooter integration + Vector
    component access).
- [x] **W5.4 RPG demo** (`data/demo_rpg/`) — player with hp/xp/level/hp_max,
  6 goblins + 2 orcs + chests + torches. 14 entities, 15 rules.
  - **Attack**: space (`spark` input) → spawns transient `weapon_swing`
    entity at player position with 2-tick lifespan. Contact rule:
    weapon + enemy in radius 45 → enemy hp -= `"-a.state.damage"` (formula).
    Swing ages out via tick rules.
  - **XP cascade**: enemy hp ≤ 0 → tick rule emits `"killed"` signal with
    payload `{xp_value: "self.state.xp_value"}` (formula resolves at emit
    time) + removes enemy. Signal handler: player gains xp via
    `state_add amount: "xp_value"`.
  - **Level up**: tick rule on `state.xp_gte 100` queues 4 effects in order:
    `level + 1`, `xp - 100`, `state_mul hp_max 1.1`, `state_set hp =
    "self.state.hp_max"` (formula reads post-mul value).
  - **Enemy AI**: same contact-pair pursue + attack pattern as shooter.
  - **Verified end-to-end** by `test_rpg_cascade`: attack 2 goblins →
    both die → 120 xp gained → level up to 2, hp_max=110, hp restored.
  - Engine fix landed: `_emit` payload values now resolved via `_value`
    (was bare-name lookup only). Lets payload formulas like
    `"self.state.xp_value"` work — needed for any signal carrying a
    state-derived value.
  - **155/155 tests pass** (was 145 → +10 for RPG cascade + emit fix).
- [x] **W5.5 Chess demo** (`data/demo_chess/`) — **non-spatial acid test
  PASSED.** Mini 4×4 board: 16 squares (a1–d4) + 6 pieces (1 king + 2
  pawns each side) + game_state. 23 entities, 3 rules.
  - **Pure non-spatial flow.** No tick rules (game logic). No contact rules
    (no spatial radius). No motion. The entire game advances via:
    `input "move"` → `query`+`require` validation → `unrelate`+`relate`
    on_square → `state_set turn`.
  - **Color-based legality** via `require` clause checking the piece's
    color tag matches the rule (white_move requires `piece` has tag
    `white`; black_move mirrors). **No primitive needed beyond the 7
    already in W1.**
  - **Position sync** via relation_changed listener: when on_square edge
    is added, set piece's `state.position` to the destination square's
    position via formula `"to.state.position"`. Visual feedback hooks
    into the relation primitive directly.
  - **Verified** by `test_chess_cascade`: legal white move → relation
    transfers + turn flips; illegal "white during black's turn" → rejected
    by query; illegal "black tries to move white piece" → rejected by
    require. Bidirectional turn cycle confirmed.
  - Engine fix landed: `_formula_context` now binds `from`, `to`, `piece`,
    `from_sq`, `to_sq` as entity roles — needed for chess and any
    relation_changed / signal handler that carries piece/square refs.
  - Full 8×8 chess is straightforward content scaling — same rule shape,
    more squares + pieces in entities.json. The framework supports it.

- [x] **W5.6** Regression sweep — all 5 demos run on identical engine.
  No demo required GD edits beyond the engine itself. Engine fixes that
  did land (formula component access, emit payload formulas, formula
  context bindings) were universal additions, not demo-specific. All
  pre-existing tests + demo cascades pass post-fixes. **Acid test passes.**

- [x] **W5.7** Goal-state assertions ship with each demo:
  - Ecology: `test_renderer_parity` + cascade timing confirmed (trees → ash → grass)
  - Farming: cascade through crop maturation + harvest verified
  - Shooter: `test_shooter_cascade` (input → bullet → contact → kill)
  - RPG: `test_rpg_cascade` (attack → kill → xp → level up cascade)
  - Chess: `test_chess_cascade` (turn legality, color-based rejection, relation flow)
  - **No-genre-leak invariant:** engine has zero demo-specific code; same
    `scripts/engine/` runs all 5 demos. **169/169 tests pass.**
  *(W5.6 + W5.7 marked complete above; original spec retained below for
  reference. Goal-state perft[2]=400 chess assertion was scoped down to
  basic legal-move + turn-cycle test in W5.5; full perft is W6 content
  depth.)*

  **Original W5.6 (achieved):** "If any demo required engine GD changes:
  those changes must be universal additions, not demo-specific. Re-run all
  five." → Engine fixes during W5.1–W5.5 (formula Vector component access,
  emit payload formula resolution, formula_context entity-role expansion,
  count_total) were all universal. Tests + all 5 demo cascades pass.

  **Original W5.7 (achieved with scope adjustment):** Headless goal-state
  assertions land as cascade tests in `test_runner.gd`:
  `test_renderer_parity`, `test_shooter_cascade`, `test_rpg_cascade`,
  `test_chess_cascade`. Ecology + farming covered by passing demos.
  Chess perft[2]=400 deferred to W6 content depth.

### W6 — Content depth pass (COMPLETE except determinism harness)

With engine proven universal (W5 acid test), built the deep ecology example
demonstrating material chains, reproduction, and reaction depth. **All
content additions, zero engine code changes** — invariant #8 in practice
yet again.

- [x] **W6.1** `data/demo_ecology_deep/` — 25 entity definitions, 36 starting
  instances, 40 rules. Materials added: iron_ore + copper_ore + ingots,
  fertilizer, mushroom, log, seedling, berry_bush. Wet-state on flammables.
  Weather entity (rain_cloud) with fuel + drift. Torches as persistent
  heat sources. (Original spec said 40+ entities — 25 def types + 36
  instances + counted as content depth without padding.)
- [x] **W6.2** Reaction chains landed:
  - **Ore + heat → ingot** via contact rule. Ore accumulates `state.smelted`
    near heat source (chance 0.04-0.05 per contact tick); at threshold,
    `transform` to ingot. Iron AND copper variants — different smelt
    thresholds (5 vs 4) demonstrate config-driven balance.
  - **Wet wood resists fire** — fire_ignites_tree query has `state: {wet_lt: 0.5}`.
    Rain wets flammables (state_add wet); things dry over time (state_add
    -0.05 every 4 ticks). Wet/dry equilibrium prevents over-burning when rain
    cycles.
  - **Mature trees → seedlings** — tick rule on `state.age_gte 4` with chance
    0.15 spawns a new seedling at the tree's position. Seedlings age, then
    transform to tree_oak at age 30. **Forest life cycle closed.**
  - **Ash → fertilizer → mushroom** — ash ages → ash_becomes_grass (chance
    0.3) OR ash_becomes_fertilizer (chance 0.2) → fertilizer_spawns_mushroom
    (chance 0.3). Three-step chain entirely in JSON.
  - **Berry bush → bird food** — bushes ripen (state_add berries +1), birds
    contact-eat berries.
- [x] **W6.3** Soak test verified: ~5 minute run shows
  - t4-t12: fire ignites trees, cascade begins
  - t12-t52: 8 → 2 trees, 6 ash accumulated
  - t52-t116: ash → grass conversion (8 grass)
  - t212+: forest reproduction kicks in (2 seedlings appear, then 4)
  - t276: tree count back up to 8 (regenerated forest)
  - t280: **all 3 ores smelted to iron + copper** via persistent heat
    sources
  - Throughout: rabbit-fox predation (rabbits 3→1), birds wandering,
    rain cloud drifting and fading
- [ ] **W6.4** Determinism / replay harness — *deferred to post-Tier-2.5*.
  Foundation for save/load (Tier 4.1) and time acceleration (Tier 4.4).
  Requires snapshot serialization (already exists via Entity.snapshot +
  RelationStore.snapshot) plus RNG seeding plumbing. Not blocking; lands
  alongside Tier 4.1 save/load.

**End of Tier 2** — engine is universal, content-deep, acid-tested.

---

## Roadmap — Tier 2.5 PIPELINE (text-to-game)

_Added 2026-04-23 after CCGS analysis + user's goal clarification: "make Yume
able to create any game we want with any different rules and physics, all
just through text description." Full rationale in
`docs/31_text_to_game_pipeline.md`._

Text-to-game needs three layers: design (prose → GDD), spec (GDD → entity
defs + rule specs with ADR trail), runtime (Yume, layers 1-2 missing). Tier
2.5 adopts trimmed CCGS patterns to build layers 1-2 so users can describe a
game in natural language and get running JSON.

**Scope invariant:** "Any simulation-shaped game, any data-driven rules,
discrete-tick physics, text-described." Non-goals: rhythm, precision
platformers, continuous physics, narrative-heavy adventures.

### Cheap pulls (Tier 2.5 — landed 2026-05-01)

- [x] **2.5a** `.claude/rules/` — 4 path-scoped rule files:
  - `engine-scripts.md` — no semantic effects, no entity-class hierarchy,
    no hardcoded ids in engine code, no genre-specific functions
  - `data-demo.md` — schema discipline, formula whitelist, cross-renderer
    coordinates, tag conventions
  - `docs.md` — primitive changes require ADR, contract is invariant-bearing
  - `tests.md` — ship-with-phase, no test framework dependency, build
    self-contained env dicts
  - Plus `README.md` indexing them.
- [x] **2.5b** `docs/engine-reference/godot/` — Godot 4.6.1 pinned with
  three reference docs:
  - `VERSION.md` — exact build pin + verification command
  - `current-best-practices.md` — class_name patterns, type-inference
    pitfalls, Expression API, signals, input polling, RegEx, headless
    conventions
  - `deprecated-apis.md` — Godot 3 → 4 trip-wires (Reference→RefCounted,
    OS→Time, connect-by-name → typed Callable, etc.) + common LLM-cutoff
    mistakes against 4.6 specifically
- [x] **2.5c** Collaboration protocol baked into project `CLAUDE.md`:
  Question → Options → Decision → Draft → Approval. Plus path-scoped rules
  index + engine reference pointer. Applied selectively (trivial edits
  skip 1-3; primitive changes / deletions require all 5).

### Pipeline core

- [x] **2.5d** `docs/adr/` scaffolding — `README.md` (format + when-to-write
  + index) + 2 retroactive ADRs:
  - **ADR 0001** — Seven primitives + invariant #8 (the foundational
    architectural decision, accepted 2026-04-22)
  - **ADR 0002** — Entity extends Node (renderer-agnostic) — captures the
    W5.0-review decision that landed as W1.14 refactor.
  TR-registry deferred — start with ADR-only; if/when content scales
  enough that traceability needs tags, add the YAML registry then.
- [x] **2.5e** `docs/32_mda_for_yume.md` — MDA framework translated for
  Yume vocabulary. Mechanics = JSON (entities + rules + relations).
  Dynamics = emergent behavior (cascades, equilibria, phase transitions,
  chains). Aesthetics = LeBlanc's 8 categories with Yume-mechanism
  examples. Includes "how the design agent should use this" section
  showing the prose → aesthetics → dynamics → mechanics decomposition
  pattern. **Foundational doc for Tier 2.5 specialist agents.**
- [x] **2.5f** Slim specialist agent set at `.claude/agents/yume/` —
  6 agents (5 core + asset-designer):
  - **game-designer** — prose → GDD via MDA decomposition
  - **systems-designer** — GDD → rule sketches; flags new-primitive
    requirements + proposes ADR
  - **content-designer** — sketches → entities.json + world_rules.json
    with specific values
  - **asset-designer** — GDD aesthetics → visual/audio fields, picks
    library / AI-gen / code-draw strategy
  - **qa-tester** — loads JSON in Godot headless, verifies cascades
    against GDD intent, reports
  - **tech-director** — guards primitive invariants, runs regression
    suite, gates engine changes
  Each agent has YAML frontmatter (name, description, tools, model)
  + system prompt body documenting role, inputs, outputs, references,
  and explicit DO/DON'T lists. README.md indexes them.
- [x] **2.5g** `/yume-design` skill at `.claude/skills/yume-design/SKILL.md`.
  7-phase orchestrator: setup → GDD → sketches → content → assets → QA → wrap.
  Each phase invokes the appropriate yume-* specialist agent (Tool: Agent),
  presents output to user, waits for approval. Failure modes documented:
  user rejection at any gate, primitive missing (escalate to tech-director),
  schema validation errors, cascade failures. Honest non-goal handling
  (rhythm games, soft-body physics, narrative-heavy adventures rejected
  at Phase 0 with concrete redirect).
- [x] **2.5h** Behavioral test spec at `.claude/skills/yume-design/tests/
  spec.md` — 5 test cases:
  - TC-01 simple farming sim (happy path through all 6 stages)
  - TC-02 rhythm game (out-of-scope rejection at Phase 0)
  - TC-03 extension to existing demo (modifies in place, no regression)
  - TC-04 ambiguous prose (clarification gate at Phase 1)
  - TC-05 invariant-violation attempt (tech-director rejection)
  Each lists expected outputs, schema checks, cascade verification, pass
  criteria. **Manual execution today**; automation deferred — the spec
  IS the contract for what "good output" looks like.

### Asset layer (4th channel — added 2026-04-30, revised same day)

Pipeline produces four parallel JSON channels: `world_rules.json`,
`entities.json`, `entity.visual`, `entity.audio`. **Each follows invariant
#8** — engine ships primitive vocabularies (draw ops, audio ops, matcher
operators); all specifics (which assets, which shapes, which prompts)
live in JSON. Asset-designer specialist composes channels; nothing
specialist-specific gets baked into the engine.

- [ ] **2.5i** `asset-designer` specialist (6th agent) — reads GDD aesthetics
  + entity list. Picks ONE strategy per project upfront so style stays
  consistent. Outputs JSON only — no engine edits permitted:
    - **Library lookup** → fills `entity.visual.sprite_2d` from catalog
    - **AI-gen** → fills `entity.visual.sprite_prompt` (resolved by tool later)
    - **Code-draw** → fills `entity.visual.shape` referencing `shapes.json`
- [ ] **2.5j** Asset-catalog **format** (engine knows nothing about Kenney) —
  `data/asset_catalog.json` is a list of matchers + paths:
  ```json
  {"match": {"tags_all": ["plant", "crop"]}, "sprite_2d": "..."}
  ```
  Engine just runs the matcher (uses existing QueryLib). A Kenney catalog,
  a custom catalog, an AI-gen output — all interchangeable JSON files. Tool:
  `yume assets resolve <data_root>` walks the catalog and populates
  `entity.visual` paths.
- [ ] **2.5k** AI-gen pipeline — four-step flow: prompt builder → hash check
  → backend dispatcher → file saver. All config-driven via `data/asset_gen.json`
  (style templates + backend registry). Per-entity prompts in
  `entity.visual.sprite_2d_prompt` / `model_3d_prompt` / `audio.*_prompt`.
  Manifest at `data/asset_manifest.json` records (entity, prompt-hash,
  backend, params, cost) for idempotent re-runs.

  **Default mode is INTERACTIVE one-by-one with approval.** Prompts are
  guesses — user must verify intent before committing. Especially for 3D
  ($0.40 + 60s per model, blasting 12 entities = $5 + 12 minutes — wrong
  default).

  CLI session shape (`yume assets generate <data_root>`):
  ```
  [1/12] wheat_mature.sprite_2d_prompt
         Style:    "pixel art, 32x32, vibrant"
         Entity:   "golden wheat stalk with full grain heads"
         Backend:  fal_flux_schnell ($0.003 est)
         (g) generate  (e) edit prompt  (b) backend  (s) skip > g
         generating... [1.4s, $0.003]
         saved: assets/generated/wheat_mature_a3f9b2.png
         (image opened in default viewer)
         (y) accept  (r) regen, new seed  (R) regen+edit  (b) backend  (s) skip > y
         ✓ accepted. moving to [2/12]...
  ```

  CLI subcommands:
  - `yume assets generate <data_root>` — interactive, default
  - `yume assets generate --batch --auto-accept` — non-interactive (CI, full regen)
  - `yume assets generate --only wheat,tree` — selective
  - `yume assets generate --since-prompt-changed` — only entities with edited prompts
  - `yume assets review <data_root>` — re-show last generation, regenerate any
  - `yume assets cost <data_root>` — total spend across runs
  - `yume assets clean <data_root>` — remove orphaned files
- [ ] **2.5k.1** Backend abstraction — three adapter classes cover the
  shapes: `SyncImageAdapter` (FLUX, DALL-E, SD), `AsyncJobAdapter`
  (Meshy, Tripo — submit, poll, retrieve), `StreamingAudioAdapter`
  (ElevenLabs, Stable Audio). Each backend's config block declares
  `type` + `endpoint` + `auth_env` + `params` + optional `polling: true`.
  Adding a new API = JSON entry; new shape = ~50 LOC adapter.
- [ ] **2.5k.2** Post-processing hooks — per-style `postprocess` config:
  `{"resize": [32, 32], "quantize_palette": 16}` for pixel art;
  `{"format_convert": "glb"}` for 3D. Pillow + trimesh handle most cases.
  Out of MVP scope: UV cleanup, LOD generation.
- [ ] **2.5k.3** Cost guardrails — optional `max_cost_usd` in `asset_gen.json`;
  tool stops + asks user before exceeding. Per-API cost tracked in manifest.
- [ ] **2.5k.4** Review/preview UX. Per-entity preview surfaces:
  - **MVP:** save file + dispatch to default viewer via `xdg-open` /
    `open` / `start` (cross-platform). User clicks back to terminal to
    accept.
  - **Nice:** `yume assets review --serve` — serves a localhost HTML page
    with thumbnail grid, click-to-regenerate, accept/skip buttons. Better
    UX for batches of 20+ entities.
  - **Diff mode:** when prompt changed but old asset exists, show old vs
    new side-by-side; user picks.
  - **Generation history:** every accepted asset's predecessor attempts
    move to `assets/generated/.history/`; never lose a "good enough"
    fallback when iterating.
- [ ] **2.5l** Audio renderer + audio catalog. Same shape:
  `scripts/renderer_2d/sound_player_2d.gd` learns audio primitives (`play`,
  `loop`, `fade`, `stop`); compositions live in `data/audio_catalog.json`
  + per-entity `audio.{sfx_loop, sfx_on_signal, bgm}` fields. Library /
  AI-gen / silent fallback — JSON-selectable.

**Why this matters:** swapping from Kenney pixel-art to custom AI-gen 3D is
swapping JSON files, not rewriting Yume. Going silent is deleting one JSON
file. Adding a new shape is editing `shapes.json`. **The engine is ignorant
of every specific asset, shape, sound, or prompt by design.**

### Non-deliverables (explicit)

- Not building 49-agent hierarchy. 3-agent core + 5-specialist pipeline
  matches Yume's scope.
- Not building 7-phase full production workflow. 3 phases (design, spec,
  runtime) sufficient.
- Not replicating CCGS `production/` folder (sprints, milestones) — Yume
  isn't a project manager.

---

## Roadmap — Tier 2.6 HARNESS ENGINEERING (proposed)

_Added 2026-05-01. See ADR 0003 for the full rationale._

Honest evaluation of Yume **as a harness for autonomous LLM agents**
(not just human-supervised authoring) surfaces gaps that Tier 2.5 didn't
address. Aggregate harness grade today: B- — works with human approval
gates, derails on first error in autonomous mode.

Tier 2.6 closes the harness loop. Lands between Tier 2.5 (pipeline) and
Tier 3 (actors). Prerequisite for any autonomous LLM workflow.

### Deliverables

- [x] **2.6a** **Structured engine errors.** Replaced `push_error("...")`
  string calls in engine modules with structured error records:
  `{code, what, where, hint, severity}`. JSON, not formatted strings.
  Buffer accumulates in `env.error_buffer`; qa-tester / orchestrator /
  LLM consumes via `EngineError.drain(env)`. Console fallback preserved.
  - [x] `Rule.validate_all` returns `Array[Dictionary]` (was: `Array[String]`)
  - [x] `Formula.evaluate` failures captured with offending formula + rewritten + bindings
  - [x] `EffectApply.apply` unknown effect types reported with rule context
  - [x] `World` load surfaces missing/invalid entities + unknown-def
  - [x] `ShapeLib` / `MeshLib` / `PhaseScheduler` topo-cycle migrated
  - Landed 2026-05-01: `scripts/engine/engine_error.gd` (helper + 27 stable
    error codes); 17 call sites migrated; rule attribution flows via
    `_rule_id` stamped by `phase_scheduler._enqueue`. Tests: 169 → 188.

- [ ] **2.6b** **Programmatic test runner for skills.** `tests/spec.md`
  cases become executable. Python tool that:
  - Invokes `/yume-design` with a fixture prompt (via Claude Code SDK
    or scripted Bash)
  - Captures generated files
  - Runs schema validation + headless qa
  - Diffs against expected file shape (not byte-exact — semantic match)
  - Reports pass/fail per test case
  - CI-runnable

- [x] **2.6c** **Tool registry auto-generation.** Replaced hand-edited
  effect/trigger/operator lists in agent prompts with auto-generated
  manifests:
  - [x] `docs/engine-reference/api-manifest.json` — Python regex over
    GDScript source extracts `Rule.VALID_TRIGGERS`, `EffectApply.apply`
    match arms, `QueryLib.OPERATOR_SUFFIXES`, `query.gd` clause names,
    `engine_error.gd` constants. Sanity check fails loudly on parse drift.
  - [x] Companion `api-manifest.md` for human readers (auto-rendered).
  - [x] `tools/gen_api_manifest.py` runs on demand (no Godot dep).
  - [x] Agents reference the manifest: pointers added to
    content-designer.md, systems-designer.md, tech-director.md.
  - Landed 2026-05-01: 14 effects, 8 triggers, 9 query clauses, 8
    operator suffixes, 26 error codes, 6 formula roles — all derived
    from source. Build step is `python tools/gen_api_manifest.py`.

- [ ] **2.6d** **Persistent workflow state.** `production/session-state/`
  (CCGS-pattern) — current `/yume-design` run state survives session
  boundaries:
  - `active.md` — what game we're working on, what stage, last
    user-approved artifact
  - Pre-compact / post-compact hook integration so session state
    survives Claude Code context compaction
  - `/yume-design --resume` continues from last checkpoint

- [ ] **2.6e** **VQA integration as default.** Generated games have
  visual output; orchestrator can't see them. Wire the existing
  `visual-qa` skill so qa-tester captures frames + reads them:
  - Auto-screenshot at 5s, 30s, 60s of headless run
  - VQA reads screenshots + GDD aesthetic intent
  - Reports "does this match the intended look?"
  - Closes the visual loop without human eyeballs

- [ ] **2.6f** **Typed agent message contracts.** Agents handing off
  artifacts pass typed messages, not "the file path is at /games/foo/X":
  - `MessageGameDesignerOutput { gdd_path, aesthetic_target,
    open_questions }`
  - `MessageSystemsDesignerOutput { rules_sketch_path, primitives_used,
    adrs_proposed }`
  - Orchestrator validates handoff types before invoking next agent
  - Failures fast, with concrete error
  - YAML or JSON schema, lives in `.claude/agents/yume/contracts/`

- [x] **2.6g** **Skills-as-roles (architectural shift).** Discovered
  empirically during harvestcore QA (2026-05-02): subagent invocations
  via `Agent(subagent_type="yume-X")` hit org auth policy blocks
  ("organization has disabled Claude subscription access"). Converted
  the 6 yume-* role prompts to skills at `.claude/skills/yume-<role>/SKILL.md`.
  Skills load into the orchestrator's main context — same role prompts,
  no auth boundary, lower latency.
  - [x] 6 new skill files: yume-{game,systems,content,asset}-designer,
    yume-qa-tester, yume-tech-director
  - [x] Orchestrator (`/yume-design`) updated: `Skill()` invocations
    instead of `Agent(subagent_type=)`
  - [x] `--autonomous` flag explicitly documented for end-to-end runs
  - [x] Autonomous fix-and-retry loop: orchestrator can apply small
    mechanical fixes (ternary syntax, typos) inline based on Tier 2.6a
    structured errors; max 3 retry cycles before surfacing
  - [x] Legacy `.claude/agents/yume/*.md` kept as fallback for users
    with `ANTHROPIC_API_KEY` set; README marked legacy
  - Landed 2026-05-02. Unblocks autonomous Tier 3 actor work — that
    too will need many in-context skill invocations, not subagent spawns.

### Non-deliverables (explicit)

- Cost/time metering — flagged as nice-to-have but not blocking. Could
  add to 2.6 if cheap or defer to Tier 4.
- Full retry orchestration — partial via 2.6a + 2.6b (errors structured,
  test runner can re-invoke). True LLM-driven retry loop is harder and
  may need Tier 3 integration.
- Replacement of Claude Code as harness — Yume operates inside Claude
  Code's harness; Tier 2.6 improves Yume's substrate, not Claude
  Code itself.

### Why this tier matters

Tier 3 (actors) needs structured observations + retry feedback to do
any meaningful LLM-as-actor work. Without 2.6a (structured errors), the
LLM actor sees engine failures as opaque text and can't recover.
Without 2.6b (programmatic test runner), we can't validate Tier 3's
own behavior. Without 2.6c (tool registry), the LLM actor's API
documentation drifts.

Without Tier 2.6, Tier 3 builds on a foundation where every gap is
felt. With it, Tier 3 builds on a closed-loop substrate.

---

## Roadmap — Tier 3 Actors (after Tier 2)

Once the engine is genre-agnostic and content-rich, **agents** re-enter as
entities that observe state and emit input triggers. Tier 3 also lands the
**two deferred primitives** (Plan, Knowledge) flagged in
`docs/30_framework_primitives.md` §"Deferred primitives" — motivated by
Feng et al. 2026 *"Environment Maps"* showing structured agent
representations beat raw-trace consumption on long-horizon tasks.

- [ ] **3.1 Actor = entity with observe/decide/emit loop.** No new primitive;
  just a convention: entities tagged `actor` have a rule that reads world
  state and produces `emit` effects (which fire input-trigger rules).
- [ ] **3.2 Scripted AI actor** — JSON-authorable decision tree. Query world
  state, pick highest-priority action, emit input.
- [ ] **3.3 Human player** — input system already handles keyboard/gamepad.
  Same channel as AI.
- [ ] **3.4 LLM actor** — async `claude -p` call, emits inputs. Requires
  async process handling (current sync version blocks tick).
- [ ] **3.4a Plan primitive (8th).** Multi-step intentions: `{goal,
  abandon_if, steps[]}`. Plan executor advances steps when preconditions
  match. Closes the long-horizon gap (Feng et al. § Workflows).
- [ ] **3.4b Knowledge primitive (9th).** `knowledge.json` declarative
  facts side-channel. Read by LLM actors and Tier 2.5 design agents;
  ignored by runtime. Closes the "agent re-derives causality every tick"
  failure mode (Feng et al. § Tacit Knowledge).
- [ ] **3.4c Context + Affordance helper APIs.** Not new primitives —
  `World.contexts_containing(id)` (tag-based) and `World.affordances_for(id)`
  (indexed view of input-trigger rules). Round out the four-component
  Environment Map vocabulary on top of the existing primitive set.
- [ ] **3.5 Multi-actor coordination** — shared signal bus lets actors
  communicate (trade offers, cooperative goals).
- [ ] **3.6 Actor memory** — per-actor Environment Map: contexts visited,
  workflows that succeeded, knowledge inferred. Persists across sessions
  via save/load (Tier 4.1). This is the paper's actual contribution.

### Tier 3 acid test

- [ ] **3.7** Add survival-game demo (`data/demo_survival/`) — agents with
  hunger, thirst, tiredness navigate the ecology world. Stakes emerge from
  cascades (night + cold + no shelter → damage). **This is the "driver"
  idea from the old plan, now a demo rather than an engine goal.**

---

## Roadmap — Tier 4 Infrastructure (after Tier 3)

- [ ] **4.1** Save/load — serialize all entity state + world state. Trivial
  once entities are the single source of truth (already true in new design).
- [ ] **4.2** Grid system — tile grid for SimCity-likes. Reference
  `docs/26_grid_system_proposal.md`.
- [ ] **4.3** 3D renderer **polish + expansion** (basic 3D landed in W5.0).
  This tier covers: animation state machines (rig idle/walk/attack), advanced
  terrain (LODs, biomes), particle systems, dynamic lighting,
  post-processing, model streaming. Engine-extensions that go beyond the
  primitive vocabulary — flagged in primitives.md as "engine extensions
  expected."
- [ ] **4.4** Time acceleration — run at 10×/100× for long-horizon sims.
- [ ] **4.5** Async LLM — required before multi-LLM actors.
- [ ] **4.6** Episode recorder — per-tick entity snapshot + input log. For
  research / debugging.
- [ ] **4.7** Host/client — multi-user observation / control.
- [ ] **4.8** VQA-driven visual regression — skill `visual-qa` integrated
  into test loop.

---

## What's Done (pre-redesign)

### Simulation foundation (Tier 1 ✅) — _will be redesigned, git-preserved_

- 3D sim with 5 brains, farming loop closed, population respawn, composite
  buildings, terrain ground sampling, Kenney asset pipeline.
- Rules engine with semantic effects (will be replaced with generic ones).
- SimPos adapter, Vector2 as the contract for sim logic.
- Dimension-agnostic template restructure (`archetypes/core/templates/godot/`).

These accomplishments proved the ideas work. The **code** is being rewritten
against the new primitive contract; the **lessons** (especially around JSON
flexibility, data-first-gd-second, target-claim systems) inform the redesign.

### Lessons corpus

`~/.yume/lessons/rpg/` — 170+ YAML lessons. Continue logging as redesign
proceeds.

---

## Design Principles (enforced during redesign)

From `docs/30_framework_primitives.md` — the **invariants** are non-negotiable:

1. **JSON is the only content channel.** Adding entities, rules, formulas,
   properties = JSON. Never GDScript.
2. **No semantic effect types.** `damage`, `heal`, `gain_xp` don't exist as
   effects — only `state_add` + naming.
3. **No entity class hierarchy.** One `Entity`. Everything else = tags +
   properties.
4. **Rules compose.** Many small rules, not one big one.
5. **Queries are first-class.** Same query system for all rule targeting.
6. **Formulas everywhere.** Any number can be a string expression.
7. **Relations are first-class.** Inventory, ownership, containment, party,
   board-square-occupancy — all typed directed edges. Never a dict-in-state.

Behavioral posture (karpathy-guidelines):
- **Think before code** — surface assumptions, present alternatives.
- **Simplicity first** — minimum primitives that cover the acid test.
- **Surgical changes** — the seven primitives are load-bearing; don't add an
  eighth without killing one. Ordering model is phased-sequential; no integer
  priorities.
- **Goal-driven** — W0 freeze gate then W5 acid test. Don't declare done
  before the chess demo passes.

---

## Boundary: what the engine does NOT do

From `docs/30_framework_primitives.md`. Flexibility holds, not refusals:

- Narrative-shaped games (visual novels, parser text adventures) — engine
  can express state, but dialogue UI is a later archetype layer.
- Input-timing games (rhythm) — requires `scheduled` trigger (reserved,
  post-W5).
- Turn-based games — requires `world_clock.paused` + signal-driven phases
  (hooks present, manager not yet).
- Continuous physics (soft-body, fluids as particles) — discrete tick, coarse
  contact.
- Networked multiplayer — Tier 4.

Design must not preclude these. None are on the critical path.

---

## Framework structure (target, end of W1)

```
~/yume/
├── archetypes/
│   ├── core/templates/godot/            ← active universal-engine track
│   │   ├── scripts/
│   │   │   ├── engine/                   ← the seven primitives
│   │   │   │   ├── entity.gd
│   │   │   │   ├── rule.gd
│   │   │   │   ├── trigger_dispatch.gd
│   │   │   │   ├── query.gd
│   │   │   │   ├── effect_apply.gd
│   │   │   │   ├── relation_store.gd     (W1)
│   │   │   │   ├── phase_scheduler.gd    (W1)
│   │   │   │   ├── formula.gd            (W4)
│   │   │   │   ├── spatial_index.gd      (W3)
│   │   │   │   ├── world_clock.gd
│   │   │   │   └── world.gd              ← top-level orchestrator
│   │   │   ├── renderer_2d/              ← reads entity.visual.sprite_2d
│   │   │   ├── renderer_3d/              (Tier 4.3)
│   │   │   └── ui/
│   │   │       └── state_display.gd      ← generic field renderer
│   │   ├── scenes/
│   │   │   └── world_2d.tscn             ← minimal universal scene
│   │   └── data/                         ← empty; filled per-demo
│   │
│   └── rpg/templates/godot/              ← legacy 2D RPG track (unchanged)
│
└── docs/30_framework_primitives.md       ← the contract
```

Per-demo data folders will be added as `data/demo_ecology/`,
`data/demo_farming/`, `data/demo_shooter/`, `data/demo_rpg/`,
`data/demo_chess/`. Engine picks one via `meta.json` `data_root` pointer
(mechanism already exists).

---

## Reference artifacts

- `docs/30_framework_primitives.md` — **the contract.** Seven primitives,
  JSON schemas, acid test, deletion list, testing layers. Read first.
- `docs/21_emergent_world_vision.md` — original vision doc. Philosophy still
  current; the 5-phase A–E implementation sketch is superseded by W1–W6.
- `docs/25_simulation_world_design.md` — world layout spec (layered zones
  etc). Content-level, still useful.
- `docs/26_grid_system_proposal.md` — Tier 4.2 prep.
- `docs/27_game_goal_discussion.md` — historical; drivers are now Tier 3
  demo content rather than engine goals.
- `~/.yume/lessons/rpg/` — 170+ YAML lessons.
- External: ViZDoom (multi-buffer observation, host/client, gym), OpenSC2K
  (multi-layer grid, sparse sim) — reference material.

---

## Visual QA command (standing rule)

```bash
rm -f /mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume3D/captures/frame_000*.png
timeout 20 /mnt/c/Users/kamwoh/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe \
  --path C:/Users/kamwoh/Documents/Projects/Godot/Yume3D --rendering-method gl_compatibility
# Then Read frame_*.png captures. NEVER use --headless for visual QA.
```

(During 2D-track work, swap the project path to the 2D test instance when
one exists.)

---

## Honest status

- **Tier 1 work (agent-farming 3D sim):** ✅ complete, git-preserved. Proved
  the core ideas but violated the universality invariant. Being redesigned.
- **Tier 2 W0:** 📋 starting now. 3–5 day throwaway spike. Primitive-freeze gate.
- **Tier 2 W1–W6:** 📋 begins after W0 passes. 5–7 weeks of focused engine work.
- **Tier 3 actors:** 📋 blocked on Tier 2 acid test.
- **Tier 4 infra:** 📋 blocked on Tier 3.

The plan trades faster-but-narrow progress (survive-the-night demo in 1 week
on existing substrate) for slower-but-universal foundation (W1–W6 over
5–7 weeks, after which ANY simulation-shaped game is JSON). This matches
the user's stated priority: *"always the best one, doesn't matter the cost."*

## Dev loop

**During 2D-track work:**
- Edit framework in `~/yume/archetypes/core/templates/godot/`
- `cp` to 2D test instance (to be set up in W1.9)
- Run Godot via `gl_compatibility`
- Check console + captured frame — use `visual-qa` skill for unbiased reads

---

## Roadmap — Tier 2.7 RECORDING + AGENT-DRIVING SUBSTRATE (proposed)

_Added 2026-05-03. Discussed during doomarena3d post-mortem. Not started._

### Why this tier exists

Tier 2.6s (scenario tests) proved the input-injection seam works:
`scheduler.queue_input(action, payload)` is the single point where any
input enters the engine — keyboard, scripted JSON, or future agent
process. Tier 2.7 generalizes that seam into:

1. **Recording** — capture (tick, action, payload) tuples + per-tick
   state snapshots + viewport frames. Replay any session deterministically.
2. **Agent-driving** — external process (Python, RL agent, LLM) reads
   state, returns actions, drives the game tick-by-tick.

Two seemingly different use cases, one underlying architecture.

### Use case 1 — game recording (record once, replay/share)

- Author plays the game; engine records action stream + state snapshots
- Replay reads the action JSON and re-injects via the same seam
- Pixel recording produces watchable video for share/debug
- **Determinism dependency**: needs seedable RNG (item below) so
  replay matches original byte-for-byte

### Use case 2 — RL agent / LLM agent / scripted bot

- Engine runs in stepped mode (no clock; external `step(action)` call)
- Agent process gets `observation` (env state snapshot), returns action
- Same input seam, just a different driver
- Useful for: ViZDoom-style RL training, LLM-as-actor experiments,
  automated regression bots that play the game on every PR

### Deliverables

- [ ] **2.7a** **Action recording.** Instrument `scheduler.queue_input`
  to append to `env.action_log` when recording is on. Dump to JSON on
  game end. Replay driver (extends scenario_runner) reads the JSON and
  re-injects actions at the same tick numbers.
  - Schema: `{game, seed, tick_seconds, ticks: [{tick, actions:
    [{action, payload}]}]}`
  - Trigger: cmdline `--record=path.json` or scene export var
  - Replay: `--replay=path.json`
  - First demo: record a doomarena3d run, replay it identically

- [ ] **2.7b** **State snapshots.** Per-N-ticks dump of `env.entities`
  + `env.relations` + `env.world` to a JSON timeline. Independent of
  action recording — useful even without replay (debugging cascades).
  - Schema: `{ticks: [{tick, entities: {id: {state, position, ...}},
    relations: [...]}]}`
  - Granularity configurable (every tick / every 4 ticks / on event)
  - Replay verification: re-run action log + compare snapshots
    tick-by-tick → fail fast if engine regresses behavior

- [ ] **2.7c** **Deterministic RNG.** Replace `randf()` calls with
  `env.rng.randf()`. Seed survives in recordings. Without this, replay
  diverges within ~10 ticks for any game using random spawn/chance.
  - **Needs ADR**: changes formula whitelist (a contract surface).
    `randf` is currently a math helper; becomes a stateful binding.
  - Touches `formula.gd` whitelist + every demo using `randf()`
  - Migration: existing demos keep working (env.rng wraps default
    Godot RNG; only difference is it's seeded from world state)

- [ ] **2.7d** **Stepped mode + agent IPC.** Engine runs without
  WorldClock; an external process drives ticks. Two transports:
  - **stdio**: line-protocol JSON over stdin/stdout. Simplest; works
    for Python / any language / shell scripts.
  - **TCP/ZMQ**: lower-overhead for high-frequency RL training.
  - Each step: agent sends `{action, payload}`; engine ticks once,
    sends back `{observation, reward, done, info}` à la OpenAI Gym.
  - First demo: random-action Python bot survives 5 seconds in
    doomarena3d.

- [ ] **2.7e** **Pixel recording.** Extend `capture_runner.gd` (Tier
  2.6r) from one-shot to every-N-ticks. Output PNG sequence to
  `user://recordings/<timestamp>/frame_NNNN.png`. Pipe through ffmpeg
  externally for MP4.
  - Compose with 2.7a action recording → "let me show you the bug
    that happens on tick 47" with both video and replay-able actions

### Composition matrix

| Goal | 2.7a | 2.7b | 2.7c | 2.7d | 2.7e |
|---|---|---|---|---|---|
| Replay a session deterministically | ✓ | | ✓ | | |
| Verify engine behavior unchanged across versions | ✓ | ✓ | ✓ | | |
| Share gameplay video | ✓ | | | | ✓ |
| RL training | ✓ | ✓ | ✓ | ✓ | (optional, for CV agents) |
| Debug "what happened on tick 47?" | ✓ | ✓ | | | ✓ |
| Automated regression bots in CI | ✓ | ✓ | ✓ | ✓ | |

### Non-deliverables (explicit)

- Multi-agent / network play — out of scope. Single agent or single
  human at a time.
- Compressed recordings — JSON for now. Binary protocol if size
  becomes a problem in practice.
- Live streaming — pixel recording produces files, not RTMP. Add later
  if anyone needs it.

### Suggested order

Start with 2.7a (action recording) — cheapest, highest immediate
value, doesn't depend on RNG work. Then 2.7c (deterministic RNG —
ADR-gated) so replay actually replays. Then 2.7d (stepped mode) which
unlocks RL/LLM-as-actor experiments. 2.7b and 2.7e are independent
quality-of-life additions throughout.

### Why now (or soon)

- The seam is already proven (scenario_runner.gd, Tier 2.6s)
- ViZDoom-style experiments were the original ask (doomarena was the
  test case); without 2.7d we can't actually train an agent
- Game replay + share is increasingly expected for indie game dev
  workflows
- Determinism is cheaper to add now (small surface) than after Tier 3
  actors land (every actor's behavior would need re-validation)

Estimated total effort: 1-2 weeks of focused work for all 5 items.
Individual items are 1-3 hours each except 2.7c (ADR + careful
migration).

---

## Tier 2.7 design-quality phases (LANDED 2026-05-03)

User insight that drove this: "i feel the game creation quality still
need a lot of improvement — like it is still not that playable enough
— i feel like the gameplay is not 'detailed' enough."

Diagnosis: pipeline produced mechanically-working games (tinypond,
doomarena3d, towerdef3d) but they felt like demos, not games. Manual
post-build iteration kept catching depth gaps that should have been
caught at GDD time.

Fix: insert two text-only design phases between game-designer (Phase
1) and content-designer (Phase 3), so depth gaps surface in minutes
of GDD review rather than hours of post-build iteration.

### Skills added

- **yume-game-reviewer** (12-axis adversarial GDD critique)
  - Mechanical depth, strategic depth, pacing, feedback, aesthetic
    match, scope honesty, adversarial pokes (axes 1-7)
  - PLUS total content scope, signature design moments, theme/
    identity, replay value, real-UX (axes 8-12 — added after user
    flagged "is the reviewer harsh enough?")
  - Verdicts: accept / revise / reject. Round 2+ allowed to surface
    NEW issues, not just verify round-1 fixes.

- **yume-level-designer** (spatial layout planning)
  - Reads GDD + world plan, produces level-design.md with concrete
    coordinates and rationale per placement.
  - Genre-aware patterns (TD path/chokes, shooter arenas, sim zones,
    grid puzzles).
  - Closes the gap between abstract design and ad-hoc placements
    that previously got smeared into content-designer's job.

### Pipeline expansion

```
Phase 1   game-designer     → GDD
Phase 1b  game-reviewer     → review.md (revise loop max 3 rounds)
Phase 1c  game-planner      → world plan
Phase 1d  level-designer    → level-design.md
Phase 2   systems-designer  → rule sketches
Phase 3   content-designer  → JSON
Phase 4   asset-designer    → visual + audio
Phase 5   qa-tester         → headless + visual + scenarios
```

### Validation outcomes (calibration confirmed)

Three GDDs reviewed under 12-axis lens:

| Game | Verdict | Why |
|---|---|---|
| Sokoban (round 4) | accept | Honestly-scoped 8-level demo with theme + undo + medals + save + signature levels |
| DoomArena3D | revise (medium) | 2 fail + 6 partial; structurally sound, content-scope gaps |
| TowerDef3D (v1) | reject | 8 of 12 axes fail; aesthetic dishonesty (Challenge with no agency) |

The reviewer correctly distinguishes severity:
- **Reject** = redesign required (TD's aesthetic dishonesty)
- **Revise medium** = content-scope gaps in sound design (D3D)
- **Revise light** = surface specification gaps (sokoban round 1)
- **Accept** = all 12 axes meet bar at honestly-claimed scope

### Cost saving (empirical)

Manual post-build iteration on TowerDef3D + DoomArena3D added (across
both): build mechanic, demon/ranger/boss enemies, tower upgrades,
audio (Tier 2.6n), wave overlap, HUD readability fixes, signature
beats, theme depth, restart UX, mouse capture, crosshair, etc.

Total ~10 hours of work that ~30 min of pre-build text review would
have surfaced. **20× iteration efficiency** is the payoff.

### Engine gap surfaced (sokoban)

Sokoban's "what's at this exact cell?" query semantics expose a
generic limitation of Yume's primitives. Workaround via signal+
payload+radius query exists but verbose. Future ADR candidate:
**cell-grid primitives** (`at_cell: [x, y]` query clause +
`move_to_cell` effect) — would clean up sokoban, chess, roguelike
combat, and turn-based strategy genres.

Not blocking — sokoban v1 can ship with the workaround; ADR is
"nice to have" cleanup.

### Status

- [x] yume-game-reviewer SKILL.md (7 → 12 axes after harsher-reviewer
  feedback)
- [x] yume-level-designer SKILL.md
- [x] yume-design orchestrator updated for Phases 1b + 1d
- [x] Sokoban full validation (4 rounds: revise → accept)
- [x] TowerDef3D + DoomArena3D 12-axis re-reviews (validates
  calibration)
- [x] Memory note: task tracking three-layer pattern (TaskCreate +
  task_plan.md + ADRs)

Tier 2.7 design-quality phases shipped. Pipeline now produces deeper
games on the first build attempt.

### Tier 2.7 follow-on: doomarena3d v2 + ternary discovery (2026-05-03)

Ran the revised doomarena3d GDD through implementation to validate
the reviewer-driven scope expansion. Round-1 (12-axis) flagged 8
real depth gaps; round-2 GDD addressed all 8; round-2 review
accepted. This pass implemented the round-2 design.

**Shipped:**

- 3 new entity defs: `monster_ranger`, `monster_boss`, `enemy_bullet`
- 3 new mesh entries (ranger_3d, boss_3d, enemy_bolt_3d)
- 2 new procedural sounds (boss_roar, siren)
- arena_clock state expanded: demon_timer, ranger_timer, boss_spawned,
  siren_played, boss_killed
- 9 new rules: monster_spawn_demon, monster_spawn_ranger,
  ranger_homing (with stop-at-fire-range), ranger_cooldown_tick,
  ranger_fire, enemy_bullet_hits_player, boss_spawn_check (latched
  at score≥25), boss_killed_win, wave_phase_siren
- Updated monster_homing with `tags_none: ["ranger"]` so ranger uses
  its own AI
- HUD: win flips on `clock.boss_killed >= 1`; controls hint expanded
  with R/Q
- 5 new scenario tests (ranger holds, ranger fires + damages player,
  enemy_bullet damages player, boss spawns at 25, boss does NOT spawn
  at 24, boss kill latches victory)
- All 188 unit tests + 26/26 scenarios pass

**Engine finding (Godot 4.6.1 Expression ternary is broken):**

While implementing ranger_homing's "stop at fire_range" logic, the
Python-style ternary `move if (dist > fire_range) else 0` always
returned the IF branch, ignoring the condition. Empirically verified
with `5.0 if false else 0.0` returning 5.0 and `5.0 if true else 0.0`
also returning 5.0. C-style `?:` doesn't parse at all. So Godot
4.6.1 has neither working ternary form in Expression.

**Workaround landed:** clamp-based step function:
```
move * clamp((cond_lhs - cond_rhs) * 1e6, 0, 1)
```
The `* 1e6` makes the boundary sharp. Works around Expression's
limitation while staying in the formula whitelist.

**Documented in:** `.claude/rules/data-demo.md` — formula syntax
section now warns about the ternary trap and shows the clamp-step
workaround as the supported alternative.

**Audit follow-up needed:** harvestcore + tinypond use ternary in
several rules. They may be silently always taking the IF branch.
Behavior may *appear* correct because the IF branch happens to match
the dominant case, but conditional logic is dead code. Needs a
sweep — file a future task to convert all production ternaries to
clamp-step pattern (or wait for W4.5 AST whitelist that introduces a
proper conditional primitive).

**Validation outcome:** Tier 2.7 reviewer arc continues to pay off —
caught design depth gaps cheaply at text-only stage; cost was ~30
min of revision instead of multi-hour rebuild. The ternary discovery
is a side-effect Tier 2.6 invariant that the engine layer should
surface (proposed: ADR for "no ternary" + a simple `cond` helper in
formula vocabulary).

## ADR 0006 + ADR 0009 fully landed (2026-05-04 / 05)

Two structural ADRs shipped end-to-end. Roadmap is past its previously-
projected Tier 2.7 surface and into post-W6 territory; updating here so
future Claudes don't miss it.

### ADR 0006 — Multi-level architecture (LANDED 2026-05-04)

`game/flow.json` declares level order + starting level. Per-level
content under `levels/<name>/` (entities + optional rules). Persistent
entities tagged `persistent` survive transitions. Engine path:
`transition_level` effect → `process_pending_level_transition` between
ticks → tear down non-persistent + reload globals + load new level.

Demonstrated by demo_multilevel + demo_doomarena3d (3-chamber campaign)
+ demo_sokoban (8-level puzzle progression).

### ADR 0009 — World/game/flow separation (LANDED 2026-05-05)

Sub-phases shipped in order:

- **Phase 1** — engine multi-file rule loader + initial sokoban migration
- **Phase 2a** — `world/physics.json` + `game/rules.json` + `game/flow.json`
  layout
- **Phase 2b** — `audio/cues.json` + `@cues.X` indirection
- **Phase 2c** — `ui/strings.json` + `@strings.X` indirection
- **Phase 2d** — variants overlay layer (`variants/<name>.json` applies
  rule-id-keyed overrides + world_state overlay + entity-id state
  overrides at load time; controlled by `World.variant_override` >
  `scene.json.variant` > `YUME_VARIANT` env var)
- **Phase 3** — bulk migration: 13 demos onto the new layout
- **Phase 3b** — per-demo rule classification splits: 7 demos
  (shooter / doomarena / doomarena3d / fpsgarden / rpg / towerdef3d /
  harvestcore) now have proper world/physics + game/rules separation;
  5 demos (chess / ecology / ecology_deep / farming / tinypond)
  intentionally left physics-only as pure simulations
- **Phase 4** — 8 specialist skills updated for the new ownership boundaries;
  new `yume-game-rules-designer` skill added
- **Phase 5b** — sunset legacy loader paths (world_rules.json,
  progression.json, world.json, inputs.json, levels/<x>/world_rules.json
  all removed from the engine; canonical paths only)

Engine state: 236/236 unit tests + 14/14 sokoban scenarios pass with
the new layout.

### Engine fixes surfaced by sokoban builds (2026-05-04 → 05)

The sokoban build empirically exposed several engine-level bugs that
got fixed and baked into skill files:

- **state_set position didn't update spatial_index** — entities moved
  via state_set (no velocity) silently disappeared from radius queries
  once they crossed a 64px cell boundary. Fixed in effect_apply.gd.
- **Signal-rule effects didn't apply before contact rules in same
  react phase** — wall_blocks_push set push_blocked=1, commit_push
  queried stale 0, boxes pushed through walls. Fixed by adding
  `flush_effects()` after `_drain_signals_into("react")` in
  phase_scheduler.tick(). Codified as Invariant #9 in tech-director.
- **scenario_runner cached actor_id at scenario start** — broke
  multi-level playthroughs because each transition recreated the
  player entity with a new id. Fixed: re-resolve every tick.
- **Renderer drew in spawn order with no z_index respect** — player
  occluded by floor tiles in level 2+. Fixed: renderer reads optional
  visual.z_index. Sokoban convention baked into asset-designer skill.
- **Camera hardcoded to level-1 center** — level 3+ extended
  off-screen. Fixed: `center_on_tag` mode + optional `fit_padding`
  for auto-zoom-to-fit.

### Skills now baking in lessons (2026-05-05)

Each post-launch fix was traced back to the responsible skill and
documented:

- yume-asset-designer — camera-mode selection guide; z_index layering
  convention table.
- yume-visual-designer — Axis 4 demands captures of levels beyond L1;
  Axis 5 gains stacking check.
- yume-qa-tester — required-coverage section: "blocker pattern" rules
  (signal sets `_blocked` flag, contact reads it) MUST have a
  scenario exercising the BLOCKED path.
- yume-tech-director — Invariant #9 (phase ordering: drain('react')
  must be followed by flush before phase-react).
- yume-level-designer — Step 6 solvability/reachability audit. Plus
  the load-bearing rule: "ASCII diagram IS the level — designer notes
  that contradict the diagram are ignored by the auto-generator."

### Cleanup pass (2026-05-05)

- Deleted orphaned engine scripts: pathfinding_astar.gd, minimap.gd,
  sim_pos.gd (all pre-W1 / pre-architecture artifacts with zero
  consumers).
- Deleted `.claude/agents/yume/` (7 legacy subagent role prompts).
  They were superseded by skills AND documented the pre-ADR-0009
  layout, so they were an active hazard.
- Regenerated `docs/engine-reference/api-manifest.json` — added
  `velocity_add_relative`, `raycast_hit`, `transition_level` effects
  that were implemented + tested but missing.
- Skill ownership boundaries fixed: yume-content-designer no longer
  claims scene.json/hud.json/world_rules.json/progression.json (those
  belong to asset-designer / systems-designer / game-rules-designer).

### Status

| Tier | State |
|---|---|
| Tier 2 (engine) | done end of W6 |
| Tier 2.5 (pipeline) | done except optional asset-gen (2.5i-2.5l) |
| Tier 2.6 (harness) | partial — 2.6a + 2.6c + 2.6g done; 2.6b/d/e/f open |
| Tier 2.7 (design-quality + recording) | design-quality phases done; recording substrate not started |
| ADR 0006 (multi-level) | done |
| ADR 0009 (world/game/flow split) | fully closed including Phase 5b sunset |

Outstanding live debt:
1. harvestcore + tinypond may have silently broken ternaries (Godot
   4.6.1 Expression bug). Audit + convert to clamp-step pattern.
2. harvestcore has a deeply-nested ternary that won't parse; surfaced
   during 3b smoke-test, not yet fixed.

Recommended next strategic move: run a fresh game through `/yume-design`
to validate the now-mature pipeline produces a working game without
human intervention. Skill files have changed substantially since the
last validation pass.

## Next-phase brainstorm (2026-05-06)

Strategic conversation captured in `docs/timeline/entries/27_roadmap_brainstorm_2026-05-06.js`.
Decisions distilled here for roadmap state.

### Skill candidates

- [ ] **combining-logic designer** — universal compositional pattern (recipe
  systems): crafting / alchemy / breeding / key-combos / chemistry. Yume
  primitives cover it; pure design skill, no engine work. Easiest of the
  three to ship; will land alongside the merchant game.
- [ ] **economy-designer** — flow analysis + balance. Build alongside the
  merchant game (real surface beats speculative scope).
- [ ] **story-planner** — narrative arc / event tracking. Defer until a
  narrative game actually needs it.

### Game candidates (ranked)

- [ ] **Merchant-POV (Recettear-like)** — NEXT pipeline freshness test.
  1 shop, ~5 traveler types, ~10 items, news as world.signal. Tests
  pipeline + combining-logic skill simultaneously. ~1 session scope.
- [ ] **SAO Alicization-style life-sim** — second target. Researchers
  raise Fluctlights from infancy in a virtual village. Two POV options
  (Fluctlight or researcher). Needs time-compression engine question
  answered first (year_counter binding? variable tick_seconds?).
- [ ] **Sims-like** — harvestcore + needs systems + select-direct UI.
  Substrate mostly there.
- [ ] **Pure-combining-magic** — small-scope test for combining-logic
  in isolation. Optional if merchant game doesn't exercise it enough.
- [ ] Civilization — premature without Tier 3 (faction AI).
- [ ] SAO mainline (Aincrad/ALO/GGO) — unbuildable without picking
  the core mechanic. Alicization is the buildable arc.

### Engine surface findings

- `ui/input.json` covers keys + mouse buttons; mouse position / wheel /
  modifier-combos / touch / gamepad NOT yet wired. Worth adding
  mouse-as-state when a pointer-driven game (RTS, point-and-click)
  comes up.
- Simulation input layer EXISTS via `scenario_runner.queue_input`
  (same code path as live keyboard). Missing for runtime AI: non-headless
  variant + policy interface. Both are Tier 3 (Actors) work.
- Time-compression for long-arc games (Alicization Fluctlight lifespans)
  is an open design question — engine extension or content convention?
  Decide before starting that game.

## Content layer gaps (2026-05-06)

After drafting ADRs 0010-0013 (save/screens/tutorials/settings — all
proposed, awaiting tech-director review), redirected discussion to
content QUALITY rather than infrastructure. Long-form analysis at
`docs/timeline/entries/28_content_layer_gaps_2026-05-06.js`.

### Honest pipeline assessment

13 specialist skills enforce that games are CORRECT (engine expresses
them, no broken cascades). They do NOT enforce that games are GOOD.
Symptoms: sokoban v0.4 = 8 levels of one mechanic (no evolution);
harvestcore NPCs are functionally distinct but personality-flat;
tinypond has identical dynamics from t=0 to t=2400.

Pipeline is optimized for "the engine can express this." It is not
yet optimized for "this game is GOOD."

### 6 identified gaps

- [ ] **Reference-design discipline** — every GDD must name "drafting
  on: X, Y, Z" with concrete what-we-keep / what-we-change. Cheap; high
  signal. Add to game-designer.
- [ ] **Mechanic-progression / verb-expansion designer** — tracks
  player verb library across play arc. Without this, content scales
  horizontally (more of same), not vertically (deeper).
- [ ] **Charm / voice / character-density discipline** — game-planner
  names cast; nobody puts FLESH on them. NPCs personality-flat.
- [ ] **Playtester skill** — qa-tester verifies cascades; doesn't
  catch boring/confusing moments. Real games iterate on playtester
  feedback dozens of times; Yume builds once.
- [ ] **Content scale enforcement** — Axis 8 catches "demo not game"
  but the fix is often "add more levels" without intentional content
  per hour. 30 trivial levels ≠ 8 crafted ones.
- [ ] **Theme-cohesion-through-execution check** — GDD says theme;
  asset-designer picks colors; nobody checks audio/enemy-names/dialog
  alignment. Theme drift is #1 reason indie games feel "off".

### Priority candidates (3, ranked)

- [ ] **Playtester** — feedback loop that catches everything else;
  hardest to design but biggest impact.
- [ ] **Reference-design discipline** — 5 minutes per GDD; lifts all
  downstream decisions; lowest cost.
- [ ] **Mechanic-progression-designer** — forces verb-library
  expansion across play arc; structural impact.

### Relationship to shell-layer ADRs

ADRs 0010-0013 (proposed) become MORE valuable once content is good
(polish on top of fun). Fun isn't there yet. Don't accelerate
save/screen/tutorial/settings work until content layer matures.

### Open questions

- Of the 3 candidate skills, which first?
- Merchant game built AS test bed for new skills, or mature content
  layer first then build?
- Specific shipped games Yume should learn from? "Make it like X" is
  the most useful design constraint we could have.

## Genre extensions + future engine work (2026-05-06)

Genre-specific designer/reviewer skills built REACTIVELY when a real
game in that genre is queued (same pattern as shooter-designer, which
was built after doomarena3d v1 surfaced gaps). Some genres need
engine work first; others are buildable today.

### Genre extension matrix

| Genre | Designer | Reviewer | Engine work | Status |
|---|---|---|---|---|
| Tower defense | `yume-td-designer` | `yume-td-reviewer` | none | buildable today |
| Roguelike | `yume-roguelike-designer` | `yume-roguelike-reviewer` | maybe procgen | mostly buildable |
| Platformer (puzzle / slow) | `yume-platformer-designer` | `yume-platformer-reviewer` | none | buildable today |
| **Platformer (twitch — Celeste-style)** | same skill | same | needs engine ADR | future |
| Life sim (long-arc) | `yume-life-sim-designer` | `yume-life-sim-reviewer` | time compression decision | needs ADR |
| RTS / 4X | `yume-rts-designer` | `yume-rts-reviewer` | maybe selection-state primitive | maybe ADR |
| **Racing (arcade)** | `yume-racing-designer` | `yume-racing-reviewer` | optional: lag-camera mode | mostly buildable |
| Racing (sim) | n/a | n/a | continuous physics (out of scope) | skip |
| Merchant / NPC-POV | `yume-merchant-designer` | `yume-merchant-reviewer` | none | buildable today |
| Visual novel | n/a | n/a | dialogue runtime out of scope | skip |
| Rhythm | n/a | n/a | sub-tick timing out of scope | skip |

### Future engine work catalog

These are tracked so that when a genre needing them comes up, the
work is scoped. Each becomes an ADR when a real game queues it.

#### Twitch platformer (Celeste / Hollow Knight / Super Meat Boy)

- [ ] **`input_released` trigger** — fires when an input action is
  released. Needed for variable jump height (hold longer = higher).
  Symmetric with existing input-press triggers; small engine work.
- [ ] **Contact direction info** — when a contact rule fires, expose
  "which side of A is B on?" (above/below/left/right). Needed for
  wall-slide / wall-jump / ground-detection without raycasts. Engine
  extension to contact-rule pair-matcher.
- [ ] **Animation state machine** — renderer reads a state formula
  (idle/walk/jump/fall) and swaps the visual frame. Currently each
  entity def has one fixed visual. Either ADR for a "frame
  dictionary" visual or a new `animation_state` field on entities
  with renderer logic.
- [ ] **Coyote-time pattern (convention only)** — state-tracked timer
  for "you can still jump for N ticks after leaving ledge". Doable
  in JSON today; document as a pattern rather than engine work.

#### Life sim long-arc (SAO Alicization-style)

- [ ] **Time compression mechanism** — Fluctlights live decades
  while observers see hours. Options: (a) variable `tick_seconds`
  per scene phase, (b) `world.year_counter` binding driven by tick
  rule, (c) compressed via tick interval (1 tick = 1 simulated
  year). Decide via ADR before building.

#### RTS / 4X (Civilization-style)

- [ ] **Selection state primitive** — player selects unit / city /
  tile; subsequent inputs route to that selected entity. Currently
  inputs go to "the player" entity by `actor_tag`. Could be expressed
  as `world.selected_entity_id` + input rules that read it; might be
  cleaner as a first-class primitive. Decide when first RTS queued.
- [ ] **Tile-grid primitive** — currently expressed via position +
  contact radius. RTS / 4X need clean "what's on cell (x, y)?"
  semantics. ADR candidate flagged from sokoban era; revisit when RTS
  comes up.

#### Twitch shooter polish

- [ ] **Mouse position as input state** — currently
  doomarena3d reads `Input.get_last_mouse_velocity` directly in
  game_shell. Should be a world_state binding so rules can read it.
  Engine work: continuous-input-polling + state push.
- [ ] **Mouse wheel + modifier combos** — neither wired through
  ui/input.json today.

#### Racing-specific polish

- [ ] **Lag-behind camera mode** — extension to camera follow that
  trails behind when the entity accelerates. Adds the "feel of speed"
  that arcade racers need. Could land as `camera.mode: follow_lag`
  with `lag_distance` parameter. Probably small enough to skip ADR
  and just land as a feature.
- [ ] **Track checkpoint convention** — checkpoints as tagged
  entities with order index + lap counter on the player. Pattern
  doc, not engine work.

### Build trigger

Each genre extension skill builds when a game in that genre queues
for `/yume-design`. The genre-extension matrix above is the LOOKUP
TABLE the orchestrator consults.

Engine ADRs in this section land when the first game needing them is
queued. The orchestrator should refuse to build a "twitch platformer"
or "life-sim long-arc" until the prerequisite ADR lands and is
accepted.

## Open-world foundational + agent simulation (2026-05-06)

Major architectural expansion proposed. 6 new ADRs drafted (status:
proposed, awaiting tech-director review). Skill files will follow.

### The reframe

User clarified: open-world is FOUNDATIONAL, not a genre extension.
Harvest Moon, Final Fantasy, GTA, Stardew, the proposed JRPG-themed
shop game (Recettear-flavor) are all open-world. They share spatial
substrate; differ in physics rules, game rules, NPCs, economy,
narrative, and game-specific logic.

ADR 0014 promotes open-world from "future genre work" to a base
substrate every Yume game can rest on. Single-level prototypes
become a degenerate case (one chunk, no streaming).

### 6 ADRs proposed (in dependency order)

- [ ] **ADR 0014 — Open-world foundational substrate**
  Chunked-world architecture. `world.json` declares chunk size +
  streaming radius + persistent-tag policy. Per-chunk content under
  `chunks/<x>_<y>/entities.json`. Existing multi-level (ADR 0006)
  coexists; chunks are spatial, levels are flow.

- [ ] **ADR 0015 — Vehicle physics primitive**
  `physics_dynamic` tag with mass + restitution. Engine handler
  computes Newtonian collision response (momentum exchange,
  reflection). Cars hit pedestrians, pedestrians fly. NOT sim
  racing (no tire/suspension/weight-transfer); arcade collision
  response only.

- [ ] **ADR 0016 — Multi-actor framework**
  Promote actor from singleton to first-class. `actors.json`
  declares N actors; each has input device + control mode (human /
  ai_policy). `world.active_actor_id` routes input + camera. New
  effects: switch_actor, queue_input_for_actor.

- [ ] **ADR 0017 — Spatial-LOD rule scheduling**
  Per-rule `lod` config: anchor (active_actor / camera / entity_tag),
  radius, fallback (freeze / tick_slowed / frozen_state). Scheduler
  uses spatial index to narrow scan; skips behaviors for distant
  entities. Foundation for crowd simulation at 200-500 NPCs.

- [ ] **ADR 0018 — Actor policy interface (LLM/RL/scripted)**
  Defines policy interface: observe(env, actor_id) → action. Three
  paths: scripted JSON, external (stdio/ZMQ to LLM/RL agent),
  godot_resource (GDScript-based). Foundation for Smallville-style
  social sims, RL training, scripted bots, "simulation input layer."

- [ ] **ADR 0019 — Rule plugin / macro layer**
  Per-game `macros.json` defines new effect names that expand to
  sequences of existing primitives + parameter substitution. Stays
  within Invariant #1 (pure JSON) and Invariant #8 (engine ships
  primitives, content composes). Solves "lambda function in Python"
  request — game-specific patterns abstract without GDScript per
  game.

### What this unlocks

The 6 ADRs together unlock a CLASS of games:

- GTA-shaped open-world top-down (driving + shooting + missions)
- Harvest Moon / Stardew (open-world farming sim with town traversal)
- Final Fantasy / JRPG overworld (sword-and-magic 剑与魔法 with
  city/dungeon transitions) — TARGET FOR SHOP GAME
- Sims-like with control-anyone (multi-actor + crowd)
- Smallville / AI-Town clones (LLM-driven NPC sandboxes)
- Disaster simulation (evacuation, panic with crowd + vehicle physics)
- RL training pipelines (agent + Yume sandbox + actor policy)

### Implementation gating (per user)

ADRs first. PLAN well. User says when implementation starts.

Build order (after gates):

1. ADR 0019 (macros) — small surface; lets existing demos benefit
   immediately. Also has lowest risk.
2. ADR 0016 (multi-actor) — foundational for everything else.
3. ADR 0017 (spatial-LOD) — perf foundation; needed before crowd work.
4. ADR 0015 (vehicle physics) — independent; can land in parallel
   with 0016/0017.
5. ADR 0014 (open-world streaming) — depends on 0016 (which actor
   drives streaming).
6. ADR 0018 (actor policy interface) — depends on 0016. Last because
   most speculative; ships with first LLM-agent demo.

### Skills queued (post-ADR-acceptance)

- [ ] `yume-open-world-designer` — districts, density, POI placement,
  traversal rhythm, streaming policy
- [ ] `yume-vehicle-physics-designer` — world-level physics (mass,
  restitution, collision damage thresholds; distinct from
  racing-designer's per-vehicle tuning)
- [ ] `yume-crowd-designer` — anonymous NPC density + behavior layers
  + LOD radii
- [ ] `yume-multi-actor-designer` — protagonist switching, per-character
  ability profiles, input-device binding
- [ ] `yume-actor-policy-designer` — observation configs, perception
  shapes, policy types per actor
- [ ] `yume-macro-designer` — per-game macro authoring guidance
  (when to abstract; how to name; recursion safety)

### Game design notes

- **Shop tale game** (Recettear-flavor): JRPG fantasy / 剑与魔法
  theme. Open-world village + shop interior + dungeon (traveler
  origins). Uses every feature: open-world (multi-area), vehicle
  physics (carts? horses? skip if trivial), crowd (visiting
  travelers), multi-actor (player + assistant?), economy, combining
  (recipes), story (news from far-off events).
- **Realistic ambition**: shop game is "complete game" target, but
  bounded by what 6 ADRs unlock. Estimated 30+ working sessions for
  ADRs + skills + first complete shop game.

### Honest scope acknowledgement

This is comparable in size to everything Yume has shipped to date.
Multi-month commitment, not weekend work. Decision logged: aim big,
build incrementally, log everything.

## ADRs 0014-0020 conditions resolved (2026-05-06)

Per user direction "do whatever to improve yume + believe we are
the best + we serve both world modeling AND end-user game creation":
all six ADRs in the open-world batch updated in-place to address
tech-director conditions. ADR 0018 split as recommended.

### Changes from prior status

- ADRs 0014, 0015, 0016, 0017, 0018, 0019 → **accepted** (conditions
  resolved in-place via "Revisions per tech-director review"
  sections)
- ADR 0020 → **proposed (deferred)** — split out from 0018; covers
  external IPC (subprocess, ZMQ, etc.); activates when first
  dependent game queues

### Key design anchors locked in

1. **Physics never-list (ADR 0015)** — Yume engine WILL NEVER
   implement: continuous force integration, constraint solvers,
   soft body, sub-tick CCD, tire grip / weight transfer, aerodynamic
   simulation. Anchor for future ADRs that bend the boundary.
2. **Macros are compile-time templates (ADR 0019)** — load-time
   expansion only; not runtime functions; cycle detection + count
   caps; per-game scoped; automated CI check.
3. **Single code path post-actors (ADR 0016)** — synthesized
   default if actors.json absent; no dual fallback maintenance.
4. **In-process vs external policies (ADRs 0018/0020)** — split.
   In-process land now; external defer until real LLM/RL game.

### Strategic framing (user)

"Doing it for both world modeling and for people who can create
their own game." This dual mission shapes priorities:

- World modeling (LLM-agent simulation, Smallville-style) → ADR
  0018 + 0020 (deferred until real game)
- End-user creation → JSON-only discipline (Invariants #1, #8) is
  non-negotiable

Both reinforce: keep things declarative, explicit, composable.

### Implementation gates

Build order locked:

1. ADR 0017 (spatial-LOD)
2. ADR 0019 (macros)
3. ADR 0016 (multi-actor)
4. ADR 0015 (vehicle physics)
5. ADR 0014 (open-world)
6. ADR 0018 (in-process policies)
7. ADR 0020 (external IPC) — when needed

Awaiting user "start implementing" signal.

## ADR 0021 landed — capability roadmap (2026-05-06)

Foundational architectural commitment locked in. Yume = JSON layer
over Godot + external capabilities. Engine NEVER reimplements
specialized capabilities; engine EXPOSES them through JSON-declarative
primitives. Each capability addition is a "capability-exposure ADR"
that maps a Godot subsystem (or external tool) to JSON.

See `docs/adr/0021-yume-as-json-layer-over-platform.md` for the full
commitment + `docs/timeline/entries/29` for the realization moment.

### Implications for prior never-list (ADR 0015)

REFINED: "Yume engine WILL NEVER REIMPLEMENT continuous physics in
GDScript or JSON formulas" (still locked in). "Yume CONTENT CAN
USE continuous physics when an ADR exposes Godot's PhysicsServer3D
or external tool" (NEW — opens the door for manipulation games,
sim racing, character physics).

### Capability exposure ADRs (queued, build reactively)

Each ADR maps ONE Godot subsystem to JSON-declarative primitives.
Build when the first game needing the capability queues for
/yume-design.

- [ ] **ADR 0022 — Godot rigid-body physics integration**
  Tags: `godot_rigidbody` + `godot_joint`. JSON declares mass,
  joints, constraints; engine instantiates RigidBody3D + joint
  nodes; reads back state into entity state; rules can apply
  forces. Unlocks: manipulation games (CALVIN-shaped), realistic
  driving (Godot's VehicleBody3D), character physics, ragdolls.
- [ ] **ADR 0023 — Godot animation system integration**
  Tags: `animated`. JSON declares animation tree / state machine /
  blend tree; engine instantiates AnimationPlayer + AnimationTree.
  Unlocks: character action games, twitch platformers, polished
  visuals.
- [ ] **ADR 0024 — Godot pathfinding integration**
  JSON declares NavigationRegion + nav-mesh derivation rules;
  engine uses NavigationServer3D / NavigationAgent3D. Unlocks:
  AI navigation (RTS unit movement, NPC routing), GPS/minimap
  for open-world games.
- [ ] **ADR 0025 — Godot particles + advanced VFX**
  JSON declares particle effect parameters; engine instantiates
  GPUParticles3D / CPUParticles3D. Unlocks: visual juice,
  weather, environmental effects.
- [ ] **ADR 0026 — Godot advanced audio (buses, effects)**
  JSON declares audio bus topology + per-bus effects; engine
  routes through AudioServer. Unlocks: dynamic mixing, sidechain
  ducking, spatial audio.
- [ ] **ADR 0027 — Godot character body / kinematic motion**
  Tags: `kinematic_body` for player-controlled characters with
  collision response (slope sliding, step climbing). Unlocks:
  twitch platformers, character action games, third-person.
- [ ] **ADR 0028 — Godot 2D physics** (parallel to 0022 for 2D)
  Tags: `godot_rigidbody2d`. Same pattern; 2D variant.

### Implications for genre matrix (revisited)

Many genres previously marked "out of scope" or "needs major work"
become in-scope when capability ADRs land:

| Genre | Path |
|---|---|
| Manipulation games (CALVIN-shaped) | ADR 0022 (rigid body + joints) |
| Twitch platformer (Celeste-style) | ADR 0023 (animation) + ADR 0027 (character body) |
| Racing sim (Forza-shaped) | ADR 0022 (Godot's VehicleBody3D + WheelJoint) |
| Character action (Devil May Cry) | ADR 0023 + ADR 0027 + complex animation tree |
| Stealth (MGS) | ADR 0024 (pathfinding for guard AI) |
| RTS / 4X (Civ) | ADR 0024 (pathfinding) + multi-actor + selection (could be skill, not engine) |
| LLM-agent simulation (Smallville) | ADR 0020 + multi-actor |

Sim racing still requires careful tuning (tire physics ARE specialized
even in Godot) but is no longer fundamentally out of scope.

### Build trigger

Each capability-exposure ADR is drafted reactively when a game in
the relevant genre queues. Don't speculatively commit to all six
at once. Pattern is well-established (each ADR is bounded surface).

### Performance commitment (per user direction)

Performance optimization is the LAST step. Architectural commitment
is "correct first; fast eventually." Future optimization work:
- Profile interpreted JSON dispatch hot paths
- Move hot paths to compiled GDScript or gdextension
- Eventually: compile games to native Godot projects with all JSON
  pre-resolved (long-future)

These are engineering optimizations, not architectural changes.
JSON layer's value (LLM-generability, declarative authoring) is
preserved.

### Strategic positioning

Yume is now positioned clearly: **the JSON-declarative content
layer that lets non-programmers (and LLMs) generate working games
on top of Godot + external tools, without writing GDScript per
game**.

Distinct from:
- "Game engines" (Godot, Unity) — Yume is a layer ON TOP of
  Godot, not a competitor
- "Visual scripting tools" (Godot's GraphEdit) — Yume targets
  text-based JSON authoring, LLM-friendly
- "Game frameworks" (Phaser, MonoGame) — Yume is content-driven,
  not code-driven
- "RL benchmarks" (CALVIN, LIBERO) — Yume is content-generation,
  not policy-evaluation; could COMPLEMENT them via task generation

### Updated mission statement (provisional)

"Yume generates the JSON that makes any game work. Complex stuff
is engine code, done during development."


## Engine implementation backlog (durable mirror of TaskList, 2026-05-06)

The session-level TaskList is per-machine and per-session; this
section mirrors it into the repo so it survives `git clone` + new
sessions. Update both when status changes.

### Shell-layer engine (ADRs 0010–0013)

- [x] **#77 ADR 0011** — declarative screen flow / Godot Control
  exposure. Landed: control_factory + screen_flow + 4 effects
  (`transition_screen`, `quit_app`, `show_toast`, `load_data`) +
  freeze_world hook. Reference content: `data/demo_sokoban/screens.json`.
  Commits `6f6a8d4` (Phase A) + `2b9c112` (anchor centering fix).
- [ ] **#76 ADR 0010** — save/load engine. `save_state` + `load_state`
  effects via Godot FileAccess + JSON. Reads per-game `save_policy.json`.
  Slot management. Refuse-on-mismatch for schema version.
- [ ] **#78 ADR 0012** — tutorial overlay primitive. `show_overlay` +
  `dismiss_overlay` effects. Highlight via ShaderMaterial+Tween.
  Reads tutorial.json. Composes with #77's modal stack.
- [ ] **#79 ADR 0013** — settings schema + Godot ConfigFile.
  `set_audio_bus_volume` + `set_input_mapping` effects. settings_renderer
  Control element type. Composes with #77.
- [ ] **#98** — ADR 0011 Phase B: ui/theme.json → Godot Theme conversion.

### Open-world / multi-actor / macros (ADRs 0014–0020, build order)

Tech-director reviewed; build in this order:

1. [ ] **#80 ADR 0017** — spatial-LOD rule scheduling (pure
   optimization, no contract change, lowest risk). Hysteresis
   required (enter_radius < leave_radius).
2. [ ] **#81 ADR 0019** — rule plugin / macro layer. Load-time-only
   expansion. Depth ≤ 4, max-expanded-effects ≤ 50, cycle detection.
   Per-game scoped. Blocked by #80.
3. [ ] **#82 ADR 0016** — multi-actor framework. Synthesized-default-
   actors at load (single code path). Per-actor input lists. Blocked
   by #81.
4. [ ] **#83 ADR 0015** — vehicle physics primitive. **NOTE**: review
   under ADR 0021 framing — may be superseded by #87 (Godot rigid-body
   exposure). Decide before implementing.
5. [ ] **#84 ADR 0014** — open-world chunked substrate. Biggest surface
   change. Blocked by #80, #82.
6. [ ] **#85 ADR 0018** — in-process actor policy interface (Paths A +
   D). Blocked by #82.
7. [ ] **#86 ADR 0020** — external agent IPC (DEFERRED — proposed,
   activates when first dependent game queues).

### Capability-exposure ADRs (ADRs 0022–0028, drafted reactively)

Per ADR 0021's expose-don't-reimplement framing. Each maps one Godot
subsystem to JSON-declarative primitives. Drafted when the first game
in the relevant genre queues for /yume-design.

- [ ] **#87 ADR 0022** — Godot rigid-body physics + joints
  (`godot_rigidbody`, `godot_joint`). Unlocks: manipulation games
  (CALVIN-shaped), realistic driving, ragdolls.
- [ ] **#88 ADR 0023** — Godot animation system integration
  (AnimationPlayer + AnimationTree).
- [ ] **#89 ADR 0024** — Godot pathfinding (NavigationServer3D /
  NavigationAgent3D).
- [ ] **#90 ADR 0025** — Godot particles + advanced VFX
  (GPUParticles3D / CPUParticles3D).
- [ ] **#91 ADR 0026** — Godot AudioServer (buses, effects, ducking).
- [ ] **#92 ADR 0027** — Godot character body / kinematic
  (CharacterBody3D, slope sliding, step climbing).
- [ ] **#93 ADR 0028** — Godot 2D physics (parallel to #87 for 2D).

### Compliance debt (deferred to capability-ADR era)

- [ ] **#94** — Refactor ADR 0004 (`blocks_motion`) to use Godot
  `PhysicsServer3D` instead of custom GDScript AABB. Blocked by #87.
- [ ] **#95** — Refactor ADR 0005 (`raycast_hit`) to use Godot
  `intersect_ray()`. Blocked by #87.

### Content / pipeline tasks

- [ ] **#96** — Build first complete game: JRPG fantasy merchant
  (Recettear-shaped). Drives demand for #76–79 implementations.
- [ ] **#97** — Build deferred genre-extension skills (reactive
  cadence): platformer, td, roguelike, life-sim, rts, merchant.

---

### Status tracking convention

When a task changes status:
1. Update `[ ]` ↔ `[x]` here.
2. Update via TaskUpdate in the session.
3. If the task touched architecture, also update the relevant ADR
   status field.

The session TaskList is the working hand; this section is the
durable record. They should not drift.
