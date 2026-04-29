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

**Design contract:** see `docs/30_framework_primitives.md` for the full spec
of the seven primitives, JSON schema, and invariants. Everything below traces
back to that doc.

---

## Conceptual Ladder (where we are)

| Level | What it is | Status |
|---|---|---|
| **L0 — Engine primitives** | Seven composable primitives (Entity, Tag, Rule, Trigger, Effect, Query, Relation), all JSON-driven, genre-agnostic. | 🟡 in progress (Tier 2, this plan) |
| **L1 — Rich world** | 40+ entities, 30+ reactions. Cascades: wet wood resists fire, dry heat ignites, rain soaks, crops rot. Observable without agents. | 📋 Tier 2 final phase |
| **L2 — Acid-tested framework** | Five genre demos (ecology, farming, shooter, RPG, chess) all run from identical engine, different JSON. | 📋 Tier 2 gate |
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

### W2 — Triggers beyond tick + motion (~1 week)

- [ ] **W2.1** `signal` trigger: named broadcast. Any rule's effect can include
  `{type: "emit", signal: "X", payload: {...}}`. Rules with `trigger: {type:
  "signal", name: "X"}` fire on receipt. Signals emitted in `react` phase
  queue into the **next tick's** `input` phase.
- [ ] **W2.2** `input` trigger: binds to Godot input action names. `input:
  "move_left"` fires the rule while the action is pressed.
- [ ] **W2.3** `spawn` / `despawn` triggers: fire once per entity at lifecycle
  points. Useful for setup/cleanup effects.
- [ ] **W2.4** `relation_changed` trigger: fires when an edge is added/removed
  matching a pattern (`{relation: "held_by", event: "added"}`). Dispatched
  in the `react` phase right after the commit that produced it.
- [ ] **W2.5** `velocity_set` effect + motion tick rule (engine-registered,
  ticks every entity with `velocity` state). Unifies player movement, projectile
  motion, knockback.
- [ ] **W2.6** Reserved hooks for future triggers (document in code comments,
  no impl): `scheduled` (rhythm games), `world_clock.paused` (turn-based).
- [ ] **W2.7** Demo: player entity with input-driven velocity. WASD moves a
  sprite. Press Space emits signal; a rule listens and spawns a particle.
  **Proof of universal input/signal channel.**
- [ ] **W2.8** **Tests (ship-with-phase):**
  - Integration fixture per new trigger type: `signal_roundtrip/`,
    `input_velocity/`, `spawn_despawn_hook/`, `relation_changed_fires/`.
  - Engine-unit: signal cross-tick queueing; input press/release edge cases.

### W3 — Spatial index + contact reactions (~1.5 weeks)

- [ ] **W3.1** `scripts/engine/spatial_index.gd` — grid-bucket hash. Updates
  on entity move. Query API: `entities_in_radius(pos, r)`,
  `entities_matching(query, origin, r)`.
- [ ] **W3.2** `contact` trigger: pair matcher over spatial index. Query has
  separate `a` / `b` clauses + `radius`. Dispatcher iterates candidate pairs,
  applies effect with `a` and `b` roles bound. **Fires in the `react` phase**
  (after motion has been committed this tick).
- [ ] **W3.3** Effect lists (JSON sugar: `effect: {...}` and `effect: [{...},
  {...}]` both valid). `before`/`after` hints sort rules within a phase;
  integer `priority` field is **not** introduced.
- [ ] **W3.4** Demo: three entities (fire, tree, water). Fire ignites nearby
  trees via `contact`. Water adjacent to fire lowers `burning` state. Tree
  with `burning` > 0 increments a damage counter via `tick` rule; when
  `durability <= 0`, `transform` to `ash`. **Proof of cascades without agents.**
- [ ] **W3.5** **Tests (ship-with-phase):**
  - Integration fixtures: `fire_spread_wet_resistance/`, `bullet_hit_removes_both/`.
  - Engine-unit tests: `spatial_index` radius correctness + rebalance on move;
    contact pair generation uniqueness (no dup pairs); `react`-phase ordering
    interlock with `commit`.

### W4 — Formula layer (~1 week)

- [ ] **W4.1** `scripts/engine/formula.gd` — wraps Godot's `Expression`.
  Bindings: `self`, `source`, `target`, `a`, `b`, `world`, plus **relation
  traversal** (`self.held_by`, `self.contains`, `self.part_of`,
  `self.parent_of.state.hp`) and **spatial helpers** (`self.nearest({...})`,
  `self.nearby({...})` with `.count`/`.sum`/`.avg`/`.max`/`.min`
  aggregates). Math helpers: `clamp`, `min`, `max`, `abs`, `sin`, `cos`,
  `randf`, `lerp`.
- [ ] **W4.2** Any effect numeric field accepts formula strings. E.g.
  `amount: "-(a.state.temperature - 100) * 0.1"`.
- [ ] **W4.3** Query operators accept formulas: `hardness_atleast:
  "world.difficulty * 2"`.
- [ ] **W4.4** **Parsed-expression caching.** Each Rule struct holds its
  compiled `Expression` instances, parsed once at load. Zero re-parse per tick.
- [ ] **W4.5** **Load-time AST whitelist.** Walk each parsed expression,
  allow only: identifiers from the binding set, numeric/string literals,
  arithmetic/comparison/logical/ternary operators, calls into the math-helper
  and query-helper lists, member access on bindings. Reject everything else
  at load. Document the whitelist in `formula.gd` header.
- [ ] **W4.6** Load-time validator: parse every formula at startup, report
  unresolved bindings, whitelist violations, and syntax errors per-rule.
- [ ] **W4.7** `world.*` bindings: `world.tick`, `world.time_of_day`,
  `world.weather`. Exposed by `world.gd` singleton.
- [ ] **W4.8** Formula perf pass. Micro-benchmark `Expression` eval cost;
  confirm per-pair-per-tick contact eval is sustainable at target scene
  size. Document numbers in a comment header.
- [ ] **W4.9** Demo: heat falls off as `1/distance^2`; fire spread chance =
  `clamp(a.state.burning / (1 + b.state.wet), 0, 0.9)`. Tuning rich dynamics
  via JSON edits only. **Proof of formula compositionality.**
- [ ] **W4.10** **Tests (ship-with-phase):**
  - Engine-unit: formula eval per binding (`self`, relation traversal, spatial
    helpers, aggregates), cache hit-rate test (compile once), whitelist
    rejection fixtures (arbitrary call, unknown binding, attribute escape).
  - Load-time validator tests: bad formulas fail load with specific rule id +
    position in the error message.

### W5 — Genre acid test (~1–2 weeks)

Five demos. Identical engine. Different `data/<demo>/` folders. No GD edits
permitted during this phase except to fix genuine engine bugs.

- [ ] **W5.1 Ecology demo** (`data/demo_ecology/`) — 10+ entities (tree, grass,
  water, fire, rain_cloud, bird, rabbit, fox, stone, ash). 15+ rules. No
  player. Run for 10 minutes; forest state changes. Predators eat prey
  (contact + state_add on hp < 0 + remove).
- [ ] **W5.2 Farming demo** (`data/demo_farming/`) — player entity with
  input-driven velocity. Inventory via `held_by` relation. Till ground
  (transform dirt → farmland via `input` trigger + nearby query), plant
  seed (spawn + `held_by` unrelate), harvest crop (contact + remove +
  `relate held_by`).
- [ ] **W5.3 Shooter demo** (`data/demo_shooter/`) — player, enemies, bullets.
  Bullet = entity with velocity + damage state. Contact rule: bullet + enemy
  → state_add hp + remove bullet. Enemy AI = periodic velocity_set toward
  player (tick rule with query for player position).
- [ ] **W5.4 RPG demo** (`data/demo_rpg/`) — player with hp/xp/level. Attack =
  input-triggered contact query + state_add hp to target. Kill = xp gain.
  Level up = rule on xp_gte 100 → level++, xp -= 100, hp_max *= 1.1.
- [ ] **W5.5 Chess demo** (`data/demo_chess/`) — **non-spatial acid test.**
  64 `square` entities (properties `file`, `rank`, `color`), 32 piece
  entities each tagged by type (`king`, `queen`, `rook`, `bishop`,
  `knight`, `pawn`) and side (`white`/`black`), all related to their
  starting squares via `on_square`. Legal-move rules per piece tag fire on
  `signal` triggers emitted by `input` rules. Turn state in
  `world.turn_to_move`. Check/checkmate detection via query over all
  opposing pieces' move sets. No spatial continuous motion; no tick-driven
  decay. **Proves Relation + phase ordering carry turn-based, board-graph
  games.**
- [ ] **W5.6** If any demo required engine GD changes: those changes must be
  universal additions, not demo-specific. Re-run all **five** to verify no
  regression. **This phase is not complete until all five pass a clean run.**
- [ ] **W5.7** **Tests (ship-with-phase):**
  - Goal-state assertions for each demo (headless-runnable):
    Ecology → ≥N trees burned + rain extinguished fire.
    Farming → scripted input track fills inventory via `held_by`.
    Shooter → scripted track eliminates all enemies.
    RPG → scripted combat reaches `level == 2`.
    Chess → perft[1] = 20, perft[2] = 400 from start; Fool's Mate detected.
  - **No-genre-leak invariant** (meta-test): `grep` over `scripts/engine/`
    fails CI if any of {`damage`, `need_decay`, `need_restore`, `gain_xp`,
    `advance_stage`, `heal`, `attack`} appears as an effect `type` literal
    or class name. Snapshot-diff the engine tree before/after each demo
    write; non-zero diff fails.

### W6 — Content depth pass (~1 week)

With engine proven universal, build the deep ecology example (original
compositionality vision).

- [ ] **W6.1** Expand `data/demo_ecology/` to 40+ entities, 30+ reactions.
  Materials: wood, stone, iron, copper, fiber, water, dirt, sand.
  Properties: flammable, wet, temperature, durability, nutrition.
- [ ] **W6.2** Reaction chains: ore + heat → ingot; wet wood resists fire;
  fire melts ice; rotting organic matter → fertilizer; fertilizer near
  seedling → faster growth.
- [ ] **W6.3** 10-minute soak test: world changes visibly. Forest partially
  burns, rain extinguishes, crops ripen and rot, ore smelts near persistent
  fire, iron rusts in wet areas.
- [ ] **W6.4** **Tests (ship-with-phase):**
  - **Determinism / replay harness.** Seed RNG, record input stream for a
    scripted 600-tick ecology run, snapshot the final entity+state+relation
    graph. Re-run with the same seed and input → assert identical snapshot
    byte-for-byte. This is the foundation for save/load and time
    acceleration. If it ever flakes, the ordering model is broken — this
    test is the canary.
  - Soak-test regression: record a golden snapshot of W6.3's 10-minute run
    and gate future engine changes on matching it (within a documented
    tolerance for floating-point + RNG).

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

### Cheap pulls (can land alongside W1.13 / W2, non-blocking)

- [ ] **2.5a** `.claude/rules/` — path-scoped rules per directory:
  `engine-scripts.md` (no semantic effects, no genre assumptions),
  `data-demo.md` (JSON validates against schema, formulas whitelisted),
  `docs.md` (primitive changes require ADR).
- [ ] **2.5b** `docs/engine-reference/godot/` — `VERSION.md` (Godot 4.6.1
  pinned), `deprecated-apis.md`, `current-best-practices.md` (GDScript
  idioms), `breaking-changes.md`. Read-first for any agent touching engine.
- [ ] **2.5c** Bake "Question → Options → Decision → Draft → Approval"
  collaboration protocol into builder/designer/tester agent prompts.

### Pipeline core (blocked on Tier 2 exit)

- [ ] **2.5d** `docs/adr/` + `docs/architecture/tr-registry.yaml` — each
  primitive change logged as ADR; requirements tracked with TR-IDs. JSON
  content references `"_tr": "TR-042"` for traceability.
- [ ] **2.5e** `docs/32_mda_for_yume.md` — MDA framework translated for
  Yume (Mechanics = rules + entities; Dynamics = emergent behavior from
  rule composition; Aesthetics = player experience).
- [ ] **2.5f** Slim specialist agent set under `.claude/agents/yume/`:
  `game-designer` (prose → GDD), `systems-designer` (rules/mechanics),
  `content-designer` (entity defs/values), `qa-tester` (validates JSON
  runs), `tech-director` (primitive invariant guard). 5 agents, not 49.
- [ ] **2.5g** `/yume-design` skill — the pipeline entry point. Prose →
  GDD (designer) → rule sketches + ADRs (systems) → entities + values
  (content) → Yume JSON + validated run (qa). User-approval gates between
  phases.
- [ ] **2.5h** `.claude/skills/*/test_spec.md` — behavioral tests. "Given
  prompt X, does `/yume-design` produce valid entities.json that runs?"
  THE acid test for the whole pipeline.

### Non-deliverables (explicit)

- Not building 49-agent hierarchy. 3-agent core + 5-specialist pipeline
  matches Yume's scope.
- Not building 7-phase full production workflow. 3 phases (design, spec,
  runtime) sufficient.
- Not replicating CCGS `production/` folder (sprints, milestones) — Yume
  isn't a project manager.

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
- [ ] **4.3** 3D renderer parity — `scripts/renderer_3d/` reads same entity
  data, different visual. Proves the separation works.
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
