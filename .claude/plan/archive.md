# Yume — An Explicit, Programmable World Model

_Last updated: 2026-05-24_

---

## Tick-rate contract (2026-05-16)

Per CLAUDE.md § "Tick rate is the engine's heartbeat":

- `tick_seconds` defaults to `0.0167` (60Hz) in `world.gd`.
- Per-game override allowed but should be a deliberate, documented
  design choice (e.g., sokoban 0.1 / 10Hz because turn-based; doomarena3d
  0.05 / 20Hz acceptable for shooting). NOT a balance knob.
- Pacing changes happen through rule `interval` fields, not through
  warping `tick_seconds`.
- Input `edge` (`press` / `hold`) is about action INTENT (discrete vs
  continuous), not genre.

The earlier-this-session mistake (reverting `tick_seconds` 0.0167 → 0.5
to fix Aldenmere's broken pacing) prompted this codification. Real fix
was scaling 28 game-time rule intervals by 30× while keeping the tick
at 60Hz.

---

## Strategic shift (2026-05-16) — "small games first, then scale"

Per the world-model game-framework design brief (Downloads/world_model_game_framework_design_brief.md): the goal is no longer "ship one big game first" but "ship many small game shards, then assemble them into a larger world." Aldenmere's 30-day winter saga (Phase 1) has been rescoped to a 3-day FP micro-shard — **Three Days to Eat (TDTE)** — that exercises the same primitive set but in a much tighter loop. Phase 2-4 ambitions (occupations, dynasty, civilization) are deferred indefinitely.

**Practical implications:**
- TDTE = current active game scope. Hidden-rule loop (raw mushroom poison, wet wood, market prices), 3-day win, simple end splash.
- After TDTE ships, pick 2-3 more small shards (per brief §12: Forest That Lied, Tower of Delayed Shadows, Mirror Shrine, etc.) — these test JSON-layer reusability.
- Big-arc systems (schedule director with 9 NPCs, season transitions, dynasty) stay in the engine + lib bundles but no game depends on them for now.
- Research-signal export, trajectory logger, hidden-rule tracker (brief §15-17) become the next-tier engine work once 2-3 shards exist.

**What this is NOT:** a retreat from the framework vision. The framework is the same; the FIRST GAME just got smaller. Each small game proves a reusable pattern.

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

## What Yume Is (restated 2026-05-24)

**Yume is an explicit, programmable world model.**

JSON is the world specification language; the runtime is its
interpreter; Godot is the projection function. The world's state,
mechanics, agents, and aesthetics are all auditable, editable,
version-controllable human-readable JSON — never baked into model
weights, never hidden inside engine code. Every property a player
can perceive is something a future contributor can inspect, modify,
or extend without retraining anything.

This is the foundational technical claim — what Yume IS. See
`docs/guideline/00_what_yume_is.md` for the implicit-vs-explicit world-model
framing (DreamerV3 / MuZero / Genie bake worlds into weights; game
engines + sims keep them explicit; Yume sits in the explicit cell)
and the 4 ADR-extension questions every future framework decision
defers to.

### What an explicit world model is made of

Three layers, all needed:

1. **Design layer**: prose → structured GDD (Mechanics / Dynamics /
   Aesthetics)
2. **Spec layer**: GDD → entity defs + rule specs + assets, ADR-
   tracked
3. **Runtime layer**: seven primitives (Entity, Tag, Rule, Trigger,
   Effect, Query, Relation), all JSON-driven, genre-agnostic. No
   genre-specific engine code, ever.

Plus the invariant that keeps it explicit: **anything the engine
can derive from the world model, the engine MUST derive — no
per-def opt-outs.** Codified in `.claude/rules/data-demo.md`.
Empirical case: `_aabb_intent` escape hatch deleted 2026-05-24.

### Features (non-exhaustive, all flowing from "explicit")

Because the world is fully explicit, Yume can offer features that
implicit world models can't:

- **Genre-agnostic substrate** — one engine, any simulation-shaped
  game. New game = new prose → new JSON. Engine never changes.
- **LLM-authorable end-to-end** — every layer (GDD, world plan,
  entity defs, rules, assets) can be generated, reviewed, and
  edited by an LLM. JSON is the contract.
- **Hot-reloadable, version-controllable** — every change is a
  JSON diff. Worlds live in git. No re-baking, no opaque state.
- **Test-driven worlds** — scenario tests, unit tests, validators
  all check the world model at the JSON layer before runtime.
  Every bug hardens a gate per the post-mortem ritual.
- **Trajectory recording / RL bridge** — explicit state means
  every tick's action + observation + reward can be logged for
  research signal export (task #105 et al).
- **Aesthetic + coherent + cinematic generation** — when the
  output is a 3D scene, Yume aims to produce worlds that LOOK
  filmed: 5-layer soul (writing/visual/audio/kinetic/reactive) +
  10 composition axes (ground variation / focal point / fg-mg-bg
  / palette cohesion / lighting drama / etc.). The current
  pipeline focus.
- **Composable primitives** — new behaviors emerge from existing
  verbs. New game wants gravity / weather / faction politics?
  Compose existing rules + tags + queries — almost never add an
  engine primitive.
- **Cross-renderer** — same JSON runs in 2D and 3D scenes with
  different projection functions. Same world, different views.

Each feature traces back to one structural property: the world is
explicit. Implicit alternatives (neural world models, hand-coded
genre engines) trade some subset of these features for others.

**Honest scope:** simulation-shaped scenes/games. Non-goals:
rhythm, precision platformers, continuous physics, narrative-heavy
adventures. See `docs/guideline/31_text_to_game_pipeline.md` for full
analysis.

---

## Pipeline status (2026-05-24)

Three sibling pipelines under `tools/visual_layout/` follow the same
LLM-as-parser pattern (prompt → image → preprocess → LLM authors
draft → postprocess validates + splices). Their stability differs:

| Pipeline | Category | Status | Owner skill |
|---|---|---|---|
| `compose_hud` + `wireframe_to_hud` | 2D fit-fit | **STABLE** (confirmed 2026-05-24) | `/yume-hud-author` |
| `compose_screen` + `wireframe_to_screen` | 2D fit-fit | **STABLE** (confirmed 2026-05-24) | `/yume-screen-author` |
| `compose_map` + `wireframe_to_map` | 3D | **ACTIVE — not complete** | `/yume-map-author` |

### What "STABLE — 2D fit-fit" means

The 2D pipelines treat input space = output space (wireframe pixels
→ viewport pixels). The LLM does coordinate transform + vocabulary
mapping; there's no semantic interpretation layer. Validators close
all known schema gaps. **The harness is locked: modifying the
workflow requires an ADR + the existing scenario regression tests
in `tools/visual_layout/tests/` must continue to pass.**

The locked surface includes:
- `tools/visual_layout/compose_hud.py` + `compose_screen.py`
- `tools/visual_layout/wireframe_to_hud.py` + `wireframe_to_screen.py`
- `.claude/skills/yume-hud-author/SKILL.md`
- `.claude/skills/yume-screen-author/SKILL.md`
- `tools/visual_layout/tests/test_screen_chain_validator.py`

The locked surface does NOT include the live JSON content the
harness produces. `hud.json` / `screens.json` per-game CAN keep
evolving — that's normal authoring. Open per-game UX work (#102–
#106 in this doc) is content tuning, not pipeline change.

### What "ACTIVE — 3D" means

`compose_map` ships end-to-end (commit `6711a7b`, 2026-05-20) but
is structurally harder than its 2D siblings:

- 2D input (semantic map PNG) → 3D output (world coords + scene)
- Multi-consumer: same map drives entities + ground shader + (TBD)
  lighting + (TBD) audio zones
- Composition concerns (10 axes from soul.md) don't apply to HUDs
  but do apply here
- Camera + framing are part of the deliverable — a 3D scene only
  exists as something the player SEES through a camera

The pipeline is functional but does NOT yet handle: water/path/
biome interpretation as entities (some closed by ADR 0055 shader-
side), composition validation, cinematic scene.json generation
(lighting/fog/camera per-scene), more than 3 hand-authored presets.

**Active development. Modify freely with the usual discipline
(post-mortem ritual, validators, scenario tests). No stability lock
yet — the surface is still settling.**

### Where extension work goes

New work on the 3D map/world pipeline:
- Extend `compose_map.py` presets or generalize them
- Improve `wireframe_to_map.py` preprocess context
- Refine `/yume-map-author` skill
- Add sibling stages (e.g. `compose_scene_cinema` for lighting/fog
  generation from the same map's palette + intent)

Touch the 2D harness ONLY if you have an ADR.

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

**Design contract:** see `docs/guideline/30_framework_primitives.md` for the full spec
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

**Findings that revised the contract** (see `docs/guideline/30_framework_primitives.md`):

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

**Deliverable:** revised `docs/guideline/30_framework_primitives.md`. Spike code
**deleted** per throwaway contract — no carry-over into W1.

### W1 — Primitive schema + 2D baseline (~1 week)

Goal: minimal runnable 2D scene with the new primitive engine. No reactions
yet, but the data shape is final.

- [x] **W1.1** Write `docs/guideline/30_framework_primitives.md` (contract doc).
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
`docs/guideline/31_text_to_game_pipeline.md`._

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
- [x] **2.5e** `docs/guideline/32_mda_for_yume.md` — MDA framework translated for
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
`docs/guideline/30_framework_primitives.md` §"Deferred primitives" — motivated by
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
- Dimension-agnostic template restructure (`godot/`).

These accomplishments proved the ideas work. The **code** is being rewritten
against the new primitive contract; the **lessons** (especially around JSON
flexibility, data-first-gd-second, target-claim systems) inform the redesign.

### Lessons corpus

`~/.yume/lessons/rpg/` — 170+ YAML lessons. Continue logging as redesign
proceeds.

---

## Design Principles (enforced during redesign)

From `docs/guideline/30_framework_primitives.md` — the **invariants** are non-negotiable:

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

From `docs/guideline/30_framework_primitives.md`. Flexibility holds, not refusals:

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
└── docs/guideline/30_framework_primitives.md       ← the contract
```

Per-demo data folders will be added as `data/demo_ecology/`,
`data/demo_farming/`, `data/demo_shooter/`, `data/demo_rpg/`,
`data/demo_chess/`. Engine picks one via `meta.json` `data_root` pointer
(mechanism already exists).

---

## Reference artifacts

- `docs/guideline/30_framework_primitives.md` — **the contract.** Seven primitives,
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
- Edit framework in `~/yume/godot/`
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
- **Phase 2a** — `world/rules.json` + `game/goals.json` + `game/flow.json`
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

- [ ] **Merchant-POV (merchant-game-like)** — NEXT pipeline freshness test.
  1 shop, ~5 traveler types, ~10 items, news as world.signal. Tests
  pipeline + combining-logic skill simultaneously. ~1 session scope.
- [ ] **the raised-AI life-sim anime arc-style life-sim** — second target. Researchers
  raise Fluctlights from infancy in a virtual village. Two POV options
  (Fluctlight or researcher). Needs time-compression engine question
  answered first (year_counter binding? variable tick_seconds?).
- [ ] **life-sim-like** — harvestcore + needs systems + select-direct UI.
  Substrate mostly there.
- [ ] **Pure-combining-magic** — small-scope test for combining-logic
  in isolation. Optional if merchant game doesn't exercise it enough.
- [ ] a 4X strategy — premature without Tier 3 (faction AI).
- [ ] the trapped-in-MMO arc (the trapped-in-MMO setting/ALO/GGO) — unbuildable without picking
  the core mechanic. the raised-AI life-sim is the buildable arc.

### Engine surface findings

- `ui/input.json` covers keys + mouse buttons; mouse position / wheel /
  modifier-combos / touch / gamepad NOT yet wired. Worth adding
  mouse-as-state when a pointer-driven game (RTS, point-and-click)
  comes up.
- Simulation input layer EXISTS via `scenario_runner.queue_input`
  (same code path as live keyboard). Missing for runtime AI: non-headless
  variant + policy interface. Both are Tier 3 (Actors) work.
- Time-compression for long-arc games (the raised-AI life-sim Fluctlight lifespans)
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

#### Twitch platformer (Celeste / a metroidvania / Super Meat Boy)

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

#### Life sim long-arc (the raised-AI life-sim anime arc-style)

- [ ] **Time compression mechanism** — Fluctlights live decades
  while observers see hours. Options: (a) variable `tick_seconds`
  per scene phase, (b) `world.year_counter` binding driven by tick
  rule, (c) compressed via tick interval (1 tick = 1 simulated
  year). Decide via ADR before building.

#### RTS / 4X (a 4X strategy-style)

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
a farming sim, a classic JRPG, an open-world crime sandbox, a farming sim, the proposed JRPG-themed
shop game (an item-shop merchant game-flavor) are all open-world. They share spatial
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

- open-world-shaped open-world top-down (driving + shooting + missions)
- a farming sim / a farming sim (open-world farming sim with town traversal)
- a classic JRPG / JRPG overworld (sword-and-magic 剑与魔法 with
  city/dungeon transitions) — TARGET FOR SHOP GAME
- life-sim-like with control-anyone (multi-actor + crowd)
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

- **Shop tale game** (an item-shop merchant game-flavor): JRPG fantasy / 剑与魔法
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
| Racing sim (a racing sim-shaped) | ADR 0022 (Godot's VehicleBody3D + WheelJoint) |
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
- [x] **#76 ADR 0010** — save/load engine. Landed: SaveState module
  (atomic write-then-rename, JSON via FileAccess, schema version
  refuse-on-mismatch, glob blacklist, persistent-tag filtering).
  `save_state` + `load_state` effects deferred between ticks. Autosave
  on_level_transition. `world.has_save` binding. Reference content:
  sokoban save_policy.json + Continue/Save buttons in screens.json.
  281/281 tests pass.
- [x] **#78 ADR 0012** — tutorial overlay primitive. Phase A landed:
  OverlayManager module + 2 effects (show_overlay, dismiss_overlay) +
  4 advance conditions (action / signal / timer / skip) + freeze_world
  coordination + emit overlay_advanced signal. Reference content:
  data/demo_sokoban/tutorial.json welcome step. 295/295 tests pass.
  Visual gate: capture verifies overlay renders with title/body/dim
  backdrop. Highlight rendering deferred to #100 (Phase B).
- [x] **#79 ADR 0013** — settings schema + Godot ConfigFile. Landed:
  SettingsManager module (loads schema + user://settings.cfg via Godot
  ConfigFile per ADR 0021), 2 new effects (set_audio_bus_volume,
  set_input_mapping), 4 new ControlFactory element types
  (slider/checkbox/option_button/settings_renderer). Reference:
  data/demo_sokoban/settings_schema.json + Settings screen. Visual gate
  passed. 295/295 tests pass. Press-to-rebind + renderer integration
  deferred to #101 (Phase B).
- [ ] **#98** — ADR 0011 Phase B: ui/theme.json → Godot Theme conversion.

### Open-world / multi-actor / macros (ADRs 0014–0020, build order)

Tech-director reviewed; build in this order:

1. [x] **#80 ADR 0017** — spatial-LOD rule scheduling. Landed: rule.gd
   parses `lod` field with shorthand `radius` → `enter_radius`/
   `leave_radius` (5% hysteresis); phase_scheduler `_fire_scan_rule`
   filters by spatial radius; per-(rule, entity) hysteresis state
   prevents boundary flip-flop; `tick_slowed:N` rate-limit fallback;
   `freeze` fallback skips out-of-radius. `env.lod_anchor_position`
   computed once per tick from world.actor_tag. 310/310 tests pass
   (+15 LOD assertions). Independent of ADR 0014 stream radius
   validation (defer to when ADR 0014 lands).
2. [x] **#81 ADR 0019** — rule plugin / macro layer. Landed:
   MacroExpander module + load-time $param substitution + DFS cycle
   detection + depth/count limits + forbidden-name guard. Wired into
   Rule.load_from_file via optional macro_expander param; world.gd
   loads expander once at game start; persists across level transitions.
   332/332 tests pass (+22 macro assertions). api-manifest CI scan
   deferred to Phase B (currently runtime guard only).
3. [x] **#82 ADR 0016** — multi-actor framework. Phase A landed:
   ActorManager module synthesizes default config when actors.json
   absent (single code path; zero-migration for legacy demos). 2 new
   effects (switch_actor deferred to next-tick boundary, queue_input_
   for_actor for AI policies). active_actor_id mirrored in world_state.
   _find_actor_id routes through ActorManager. 348/348 tests pass
   (+16 actor assertions). Backward compat verified: tinypond +
   sokoban scenario tests unchanged. Phase B: per-actor input lists,
   multi-device routing, follow_active_actor camera mode.
4. ~~#83 ADR 0015~~ — DELETED. Superseded entirely by #87 (Godot
   rigid-body exposure) per ADR 0021. Vehicle physics deferred to
   `VehicleBody3D` exposure when the first racing game queues.
5. [x] **#84 ADR 0014** — open-world chunked substrate. Phase A landed
   (2026-05-06): ChunkStreamer module (~280 lines) tracks active-actor
   position via ActorManager, loads `chunks/<x>_<y>/entities.json`
   within stream_radius, despawns beyond unload_radius (hysteresis).
   `chunks/_persistent/entities.json` loaded ONCE at boot — entities
   live in env.entities + spatial_index for the whole session
   regardless of chunk eviction (per ADR § Revisions #1). World.gd
   exposes `load_entities_file()` helper for chunk content; per-tick
   `process_chunk_streaming()` runs after `process_pending_level_
   transition` (no flush ordering changes). SaveState serializes
   `current_chunk` coord; `_apply_saved_chunk()` re-anchors streamer
   on load. Backward compat: world.json absence → null streamer →
   legacy single-chunk mode (verified via sokoban 14/14 scenarios).
   407/407 unit tests pass (+39 from test_chunk_streaming covering
   try_load, chunk_of math, boundary crossing, persistent survival,
   spatial_index hygiene, beyond-stream-radius queries, save+restore).
   Phase B (deferred): yume-open-world-designer skill, per-chunk
   rules.json overrides, boundary_mode "wrap" / "infinite", per-actor
   stream radii.
6. [x] **#85 ADR 0018** — in-process actor policy interface. Phase A
   landed: ScriptedPolicy module (JSON behavior-rule interpreter with
   condition primitives world_state/actor_state/distance_to/nearby_count
   + all/any/not boolean ops + first-match priority semantics).
   ActorManager.load_policies() reads policy_ref per ai_policy actor;
   tick_policies() builds observation from spatial_index radius query +
   world_state + active actor position, calls policy.decide(), queues
   resulting actions onto scheduler input queue. World ticks policies
   BEFORE scheduler.tick so synthesized + human inputs land in same
   tick. 368/368 tests pass (+15 policy assertions). Backward compat
   verified (sokoban scenarios 14/14). Phase B: Path B (godot_resource
   GDScript policies), policy_tick_rate_hz throttling, per-actor
   observation_config in actors.json.
7. [ ] **#86 ADR 0020** — external agent IPC (DEFERRED — proposed,
   activates when first LLM/RL game queues).

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

- [ ] **#104** (was #94+#95, COMBINED) — Refactor ADRs 0004 + 0005
  (`blocks_motion` AABB + `raycast_hit`) to use Godot `PhysicsServer3D`
  + `intersect_ray()`. Blocked by #87.

### Polish + nice-to-haves

- [ ] **#103** (was #98+#100+#101+#102, COMBINED) — Shell-layer
  Phase B polish: `ui/theme.json` → Godot Theme; overlay
  `highlight_tag` shader + Tween pulse; key_binding press-to-rebind
  state machine + accessibility renderer integration; per-actor
  input/camera follow_active_actor. All small individually; combined
  to land in one polish pass after #96 ships.

### Content / pipeline tasks

- [x] **#99** — `reset_world` effect landed. Deferred via
  env._pending_world_reset; world.gd processes between ticks
  (after save/load + actor switch). Despawns non-persistent entities,
  clears world_state in-place, reloads world/state.json initial values,
  re-spawns starting level (multi-level) or root entities (single).
  Refreshes has_save + active_actor_id mirrors. Non-destructive in
  effect chain — [reset_world, transition_screen] works (unlike the
  old reload_scene + transition_screen footgun). 353/353 tests pass.
  Sokoban New Game button now uses [reset_world, transition_screen].
- [ ] **#96** — Build first complete game: JRPG fantasy merchant
  (merchant-shaped). Composes shell-layer + #85 + #99.
- [ ] **#97** — Build deferred genre-extension skills (reactive
  cadence): platformer, td, roguelike, life-sim, rts, merchant.

### Recommended attack order

**Critical-path for merchant game (#96):**
1. #99 reset_world (small; ~50 lines; fixes New Game)
2. #85 in-process policies (NPC behaviors; ADR 0018)
3. #96 merchant game (the goal)

**Parallel track (independent):** #84 open-world

**Reactive (drafted when first game requires):** #87-#93 capability
ADRs + #97 genre skills

**Deferred:** #86 external IPC, #103 polish, #104 compliance

---

### Status tracking convention

When a task changes status:
1. Update `[ ]` ↔ `[x]` here.
2. Update via TaskUpdate in the session.
3. If the task touched architecture, also update the relevant ADR
   status field.

The session TaskList is the working hand; this section is the
durable record. They should not drift.

---

## 2026-05-07 autonomous overnight run — merchant polish

User said: "i wonder why the autonomous cannot run end-to-end without me intervene? i am going to sleep, hope when i wake up everything is done perfectly."

Committed plan for tonight (recorded so it survives compaction):

### Goal
Get demo_merchant from "1% playable" to "feels like a real merchant game" without user intervention. Use scenario tests + --capture-input visual QA at every milestone instead of waiting for user feedback.

### Tasks (priority order)

- [x] #107 customer variety — verified via 3 scenario tests (warrior 75g, townie 30g, noble 120g). Spawn override + b.state.gold_value formula resolves correctly.
- [ ] #112 show_toast formula-detection bug — multi-word toast text like "Debt installment paid" triggers Formula.looks_like_formula because of spaces, then fails as binding lookup. Fix: skip _value() on `text` field for show_toast OR mark literal strings explicitly. Engine fix.
- [ ] #108 real haggle UI — re-enable screens.json, build accept/counter/reject via ADR 0011 Control nodes. On customer contact, suspend tick + show 3-button overlay. Each button triggers a different effect chain (full sale / haggle / walkout).
- [ ] #109 dungeon entry + simple combat — wire up E key + dungeon-portal contact rule → transition_level to level_dungeon_1 with fade_duration. Re-enable enemy spawning + simple HP combat in dungeon.
- [ ] #110 named regulars on schedule — Henrick (warrior) appears day 1+, Garron (mage) day 3+, Vela (noble) day 5+, etc. Tick rule with day_eq filter spawns named entity once per day.
- [ ] #111 visual scene transitions — apply fade_duration: 0.3 to all transition_level effects (already done for shop_door_enter by builder agent). Verify with --capture-input.
- [ ] visual-QA pass — capture-input run through: walk to shop → enter → sale → close shop → night → debt → next morning. Fix any visual issues.
- [ ] commit progressive snapshots so user can review.

### Constraints

- Don't ask for user input.
- If schema bug found: fix, document in `.claude/rules/data-demo.md` under "Schema gotchas".
- If engine wall hit: propose ADR + implement (per ADR 0021 framing — expose Godot capability via JSON).
- Use scenario_runner + capture_runner heavily — they're the autonomous-QA tools.
- Commit on milestones (not too granular).

### Engine prerequisites (already landed by builder agent ac7812f3 tonight)

- `screen_fade` effect (3-phase fade-out → swap → fade-in)
- `scene_change` effect (full Godot scene swap)
- `transition_level` extended with `fade_duration` parameter
- 430 tests passing (was 407)


### Autonomous run results — wake-up summary

What landed tonight (in commit order):

1. **Engine: scenario_runner tag overrides** (commit `9b94d3c`) — setup spawn schema now accepts `tags` + `properties` on instance specs. Required for testing rules that match by override-tag (e.g. dungeon-portal `town_to_dungeon` variant).

2. **Engine: fade primitives** (commit `3c17ea1`, builder agent ac7812f3) — `screen_fade`, `scene_change`, `transition_level fade_duration`. 3 new effects, 23 new tests (407 → 430 passing).

3. **Engine: show_toast bug fix** (commit `3c17ea1`) — multi-word toast text like "Debt installment paid" was tripping `Formula.looks_like_formula` due to spaces. New `_value_text()` helper resolves bare bindings + @-refs only, no formula step.

4. **Engine: --game= cmdline resolved in _enter_tree** (commit `cc7384b`) — children's _ready fires before parent's, so when GameShell + ScreenFlow tried to read scene.json, data_root was still empty. Caused `play.tscn` to render blank gray for any cmdline-driven game. 430/430 tests still pass.

Demo merchant content (gitignored, local only):

- Customer variety (warrior 75g, townie 30g, mage 55g, archer 45g, noble 120g) — verified via 3 scenario tests.
- Dungeon entry via south-walk (portal at 1500, 3000) — fade transition, separate town_to_dungeon vs dungeon_to_town tags.
- Simple combat: walk into enemy → +gold_reward, removed.
- Chest opens on contact: random 30-100g.
- 5 named regulars on schedule (Henrick day 1, Garron day 3, Vela day 5, Tannic day 7, Mireille day 12 + tier 2). Each has gold_value override + a per-day visited flag reset on morning_phase_enter.
- HUD now shows "Where: <current_level>" so player knows location.
- Camera zoom 2.0, lerp 0.18 — entities visible and readable.

Tests: 12 scenario tests pass. 430 engine unit tests pass.

Visual QA captures landed at `captures/merchant_<timestamp>/`. Walkthrough script at `scripts/vqa/merchant_walkthrough.sh` for repeating the QA sweep.

Deferred to next session:

- **#108 Real haggle UI** — needs threaded customer_id through emit signal; explained in task description. Required either (a) world_clock-stored haggle_active_id with custom resolver in `target:`, or (b) transient relation. Both need engine extension. MVP "instant sale on contact" is the current shipping state.
- **#106 Schema gotchas in skill files** — partially done; remaining items in description. Touched data-demo.md + 3 skills already; rest is grunt work.



---

## 2026-05-08 — Session 5 close (Tier B start)

### Landed

- ADR 0026 party primitive (commit `52ac196`) — engine: party_join / party_leave / party_ko effects + PartyDirector node. 488/488 tests pass. Documented in 30_framework_primitives.md.
- Brookhaven Act 1 content (gitignored): 9 villager defs, 50m × 50m village, funeral cinematic + debt-papers screens, 6 cinematic/tutorial rules.
- Forest road Act 3 zone 1 content (gitignored): 4 wilderness enemies (bandit/wolf/harpy/captain), bandit ambush + portal pair.
- Workflow: scripts/play.sh paths now env-overridable (`YUME_GODOT_BIN`, `YUME_TEMPLATE_DST`). CLAUDE.md gains "Running Godot" section sourcing from play.sh. Memory file documents generically.
- Screen-flow validator (`tools/validate_screens.py`) — catches dangling transition_screen.target refs at sync time. Wired into play.sh non-blocking. Strict mode for agents/CI per visual-qa.md screen-flow gate.

### Bugs caught + fixed

- 11 `transition_screen target='_close'` instances in merchant screens.json (and 3 staged backups) — `_close` was never an engine sentinel; correct token is `@previous`. Replaced via sed. User caught at first play; headless tests can't fire on_click chains.
- merchant_2d.tscn was a vestigial stub causing 2D fallback grey-with-dots render — deleted both source + template copies.
- starting_level=level_brookhaven broke 8 Tier A scenarios (they assume default Pendrel). Reverted defaults; Brookhaven now reachable only via temporary flow.json flip until New Game flow is wired.

### Deferred to Session 6

- Brookhaven + forest_road visual QA — need a New Game→Brookhaven flow harness OR scenario_runner --starting-level= override.
- 12 dangling rule-fired transitions to never-built screens (bailiff_dialogue, win_screen, lose_seizure, festival_arrival, tier_up_celebration, settings, etc.) — either build screens or remove the rules.
- Pendrel→forest_road portal (only forest→pendrel currently wired).
- ADR 0026 party-combat content rules (party_join/_ko firing on hp_lte 0; party_revival emit on town entry).
- Mountain pass + ruined fort levels (Act 3 zones 2-3).
- Engine: `--smoke-screens` mode (runtime click-flow smoke test) — walks every screen + every on_click chain, fails on push_warning. See visual-qa.md screen-flow gate Layer 2.


## 2026-05-08 — Soul layer added to design pipeline

Commit `ca734a9` ships **Phase A (soul) + Phase B (mechanical feel)** as
upgrades to the design skills. Caught the bug class "game has features but
no soul" at GDD-review time, not playtest time.

### Skills added / changed

**Added**:
- `yume-flavor-writer` — owns prose density (per-NPC voice profiles, item
  flavor, barker pools, world-text surfaces, reactive prose). Outputs
  `flavor-design.md`.

**Updated** (Phase A — soul layer):
- `yume-game-designer` — GDD now requires "Voice & texture" section. Without
  it, flavor-writer rejects.
- `yume-game-planner` — world-plan now requires per-NPC voice + per-item
  flavor scaffolds.
- `yume-content-designer` — schema canonicalizes `flavor_text` / `voice` /
  `barker_lines` entity fields.
- `yume-game-reviewer` — NEW Axis 14 (voice & texture density). 13 → 14 across
  genre reviewers (merchant, shooter).

**Updated** (Phase B — mechanical-feel layer):
- `yume-systems-designer` — REQUIRED contact-radius vs entity-scale check
  (radius ≤ max(extent_a, extent_b) × 1.2). REQUIRED core-verb multi-tick
  spec (signature interactions get player-readable intermediate states;
  despawn last, never first). Catches "instant-despawn customer on contact"
  at design time.
- `yume-level-designer` — REQUIRED genre density archetypes + camera-
  frustum check. A "city" needs ≥8 buildings of ≥3 distinct shapes visible
  from typical vantage + multiple districts + distance silhouettes. Catches
  "feels like one house" at level-design.md review.
- `yume-juice-designer` — REQUIRED transition-feel timing standards (level
  swap = fade 0.6 + hold 0.2 + fade 0.4 + camera lerp 0.5). REQUIRED
  signature-moment juice spec. Catches "camera shift is abit weird."

### Phase C — applied retroactively to merchant (gitignored content)

- `docs/games/merchant/GDD.md` → "Voice & texture" addendum
- `docs/games/merchant/flavor-design.md` → 5 voice profiles, 23 item
  flavors, 20 barker lines, 12 world-text surfaces, 8 reactive lines,
  5 signature voice moments
- `entities/items.json` → `flavor_text` on all 23 items
- `entities/named_regulars.json` → `voice` + `barker_lines` + `flavor_text`
  on 5 regulars
- `entities/customer_generics.json` → `barker_lines` on 5 archetypes
- `game/goals.json` → 5 barker-on-contact rules + 7 contact-radius
  reductions (attack 3.75→1.5; haggle 2.0→1.2; chest/portal 3.12→1.5)
- Verification: 488/488 unit tests, 12/12 scenarios, 19/19 smoke-screens,
  strict screen-flow validator clean.

### Pattern

Soul/feel gaps are bug classes caught cheapest at design time. Same
logic as `validate_screens.py` (catch at sync, not runtime),
`yume-game-reviewer` (catch at GDD, not build), `yume-tech-director`
(catch at merge, not production). Skill upgrades are the durable
framework win; merchant Phase C is the proof case.

### Open work

- 15 character-arc dialogue screens (5 regulars × 3 beats) — content-
  designer + screen-flow-designer next pass.
- Inventory tooltip widget (engine work) for hover-to-show flavor_text —
  alternative is "barker on item-pickup" using existing show_overlay.
- Per-named-regular loyalty tracking in sale rule (currently only
  generic reputation).
- Camera-lerp post-transition rule (juice-designer's transition-feel
  spec; needs new juice effect or content-rule pattern).

---

## Tier C — Cross-game JSON reuse + city visuals (2026-05-08, in-flight)

User framing: *"we are building something like 'json language system' —
although we use only json, we can build the whole game, and because
these can be done by you/claude/codex/gemini, so we make sure this is
friendly to you."*

The city visual issues (boring ground, scattered town, no minimap)
get parked behind a foundational ADR so subsequent work composes
reusable building blocks instead of re-deriving them per game.

### Build order

1. **ADR 0027 — cross-game JSON reuse system (`@lib.X` + `$extends` +
   `$include`)** — *foundational; blocks the rest*
   - Drafted: `docs/adr/0027-cross-game-json-reuse-system.md`
   - Tech-director review: accept-with-conditions; 8 conditions
     listed in the ADR's review section
   - Next: fold conditions into ADR text → mark accepted →
     implement Phase 1 (resolver + tests) + Phase 2 (initial
     `data/lib/cameras.json` + `data/lib/input_bundles/wasd_with_fp_
     variant.json`) → separate PR for Phase 3 (merchant migration)

2. **#5 Pendrel city redesign** — plaza, road grid, districts,
   perimeter walls. Replaces scatter-pattern placement. ~30 min
   level-designer pass + content-designer entities.json update.
   *Uses ADR 0027 lib refs once landed* (road tile entities).

3. **#3a Distinct house meshes** — 4-6 variants in
   `data/meshes.json` (small_cottage, large_cottage, shop_2story,
   tavern, forge, chapel). Drop into shared lib so all games
   benefit. *Future: package via `@lib.entities.props.*`.*

4. **#3b Tiled ground** — replace single 400×400 dirt plane with
   placed tile entities (cobblestone, grass, plaza, dirt-path)
   along Pendrel's road grid (depends on #5). *Future: package
   tile defs via `@lib.entities.terrain.*`.*

5. **#1b Visual minimap widget** — new `MapWidget` Control type in
   `control_factory.gd`. Per-game declares which tags render as
   dots, colors, "you are here" cursor. ~2h engine work. Per ADR
   0021 expose-don't-reimplement (uses Godot Control + draw
   primitives).

### Why ADR 0027 first

The user's "we always aim big" instinct + LLM-authoring framing.
Once `@lib.X` works, the city redesign + house meshes + tiles +
minimap all compose against shared building blocks instead of
re-derivation per game. ~80% authoring-boilerplate reduction
once the lib catalogs flesh out.

### Reserved / unwritten ADR slots

- 0022, 0023 — multiply-claimed by various docs (rigid-body, dialogue
  tree, quest log, animation) but never drafted. Numbers free to
  reuse for whichever lands first.

### Open Tier A/B still pending (carried from prior tier)

- 15 character-arc dialogue screens (5 regulars × 3 beats)
- Inventory tooltip widget (hover-to-show flavor_text)
- Per-named-regular loyalty tracking in sale rule
- Camera-lerp post-transition rule (juice-designer's transition-feel)

### Future ADR: MultiMeshInstance3D for static decoration (deferred 2026-05-11)

Empirical case: Aldenmere Three Days to Eat with ~480 entities (211
trees + 250 grass + decoration) created ~3000 MeshInstance3D nodes
in the scene tree, each costing its own draw call. User-perceived
slowdown surfaced during demo recording.

Cheap mitigations applied immediately (committed):
- `cast_shadow: false` on grass / cloud / bird mesh defs (halves draw
  cost per cull, since shadow pass is skipped). New engine support:
  mesh-def-level + per-primitive `cast_shadow` flag in
  `mesh_lib.gd::build_primitives_into`.
- Scatter counts reduced ~60% (211 trees → 84, 250 grass → 100).

The real optimization (~10× speedup) is **MultiMeshInstance3D**: per
static mesh-type, one mesh + N transforms in one draw call regardless
of N. Engine work needed:

1. At world load, group entities by `(mesh_id, static-vs-dynamic)`.
   "Static" = entity has no rule mutating position/scale/yaw + no
   `state.velocity`. Trees, grass, rocks, props qualify.
2. For each static group: build one `MultiMeshInstance3D` with one
   instance per entity; per-instance transform reads from the entity's
   position/scale/yaw at spawn time.
3. Skip per-entity `MeshInstance3D` for static entities (visual lives
   in the MultiMesh; Entity stays for game logic + collision AABB).
4. If a "static" entity later becomes dynamic (state.scale changes,
   tick rule sets velocity, etc.), promote it back to its own
   MeshInstance3D and remove from the MultiMesh.

Scope: ~2-3 days engine work. Universal benefit — any Yume game with
dense decoration (forests, crowds, particle-like prop scatter) wins
in proportion to its density. Frame-time profiler under Godot 4.6's
Performance Monitor will quantify the gain before/after.

When to do: next time a game's decoration density crosses ~200
static entities. Aldenmere is already past that line, so this is
worth doing before Phase 2 rolls out.

### Future ADR: procedural-generation primitives (umbrella ADR 0042 drafted 2026-05-11)

**Status update 2026-05-11**: umbrella ADR 0042 landed
(`docs/adr/0042-procedural-generation-primitives.md`),
tech-director-reviewed, status `proposed (accept-with-conditions)`.
Engine session deferred until a game pitch explicitly needs it.

The umbrella declares the three implementable sibling ADRs:

- **ADR 0043** — Terrain noise primitive (terrain heightmap +
  biome zones via zone_store; integrates with scatter
  `place_on_terrain` for forest slopes)
- **ADR 0044** — Streaming procgen extension (extends
  `chunk_streamer.gd` to generate chunks on first visit)
- **ADR 0045** — Dungeon layout generation (BSP / WFC / random-walk
  room generation for roguelikes)

Implementation trigger: a game pitch arrives that EXPLICITLY needs
the primitive, OR the user requests starting a procedural-content
game. Until then the umbrella serves as a validated waiting spec.

## 2026-05-16 — Authoring contract enforcement + Python codegen position

Two-incident bug class (same session): `gather_pickup` signal rule
referenced `self.state._last_slot` (incident 1 — `self` not bound in
require-driven signal rules), then `actor.state._last_slot` after
"fix" (incident 2 — `actor` not in `EffectResolution.formula_context`
entity-id auto-promote allowlist). User caught both at live play;
neither was caught by unit tests (synthesized their own context with
`self` already an Entity) nor scenario tests (don't exercise
crosshair-aim gather flow).

### Root-cause analysis

- Layer 1 (script): formula_context allowlist was an arbitrary
  10-name list (`self, target, a, b, source, from, to, piece,
  from_sq, to_sq`). Custom payload binding names (`actor`,
  `pursuer`, ...) silently dropped on the floor. Fixed
  2026-05-16: any ctx string that names a real entity is now
  auto-promoted to its Entity — allowlist is no longer a
  correctness gate.
- Layer 2 (post-mortem ritual): step 3a (bug-class
  generalization) was skipped after incident 1. The fix patched
  `self → actor` (symptom layer) without investigating "is the
  trigger the wider primitive — that some binding names work in
  formulas and some don't?" The right post-mortem would have
  surfaced the allowlist in one pass. Empirical pattern matches
  the `looks_like_formula` precedent from the rules.
- Layer 3 (skill / authoring contract): no machine-enforced gate
  exists for "formula references a binding the rule binds". The
  guidance lives only in prose (`.claude/rules/data-demo.md`).
  Skill prompts can't enforce; LLM authoring or human authoring
  both slip past until live-play surfaces the bug.

### Decision: validator first, codegen second, runtime Python never

Three options considered for the recurring bug class:

| Option | Where Python runs | Verdict |
|---|---|---|
| **A. Static validator** (tools/validate_rules.py) | sync time | **DO NOW (task #100)** |
| **B. Python codegen library** | build/author time, emits JSON | Deferred (task #101). JSON canonical, Python optional emitter alongside skills + hand-author. ADR 0021 + Invariant #1 preserved. |
| **C. Runtime Python DSL** | engine load / runtime | **NEVER**. Replaces JSON as source of truth → reverses ADR 0021. |

Validator is the smallest thing that closes the bug class for both
authoring paths (LLM-via-skills AND hand-author). It also defines
the contract any future codegen library must conform to.

### Tasks queued

- **#100** (pending) — tools/validate_rules.py. Checks: formula
  binding mismatch (the incident-1 class), destructive-effect-
  chain ordering, modal-pop screen_fade pairing, empty-effect
  rules, sync-derived field state_init coverage, engine_injected
  marker for keyless input actions, 2-binding non-contact
  queries, schema field-name landmines (delta vs amount, def vs
  template). Wired into play.sh as pre-launch gate (strict mode
  exits 1 for CI/agents). Estimated: one afternoon.
- **#101** (deferred) — Python codegen library. Build only if
  human-authored content volume hits "JSON-by-hand pain"
  threshold. Maintenance cost is 2x (every new effect type needs
  engine impl + helper). LLM/skill authoring doesn't benefit.

### Animation primitive — ADR 0046

Decided 2026-05-16: animation_director.gd reimplements Godot's
AnimationPlayer/Animation interpolator (~300 lines of GDScript
that should be C++). Audit was queued under the 2026-05-13 commit
(`856e64a`). Now formalized as ADR 0046 with two phases.

- **#96** (pending) — ADR 0046 draft (Phase A + B) +
  tech-director gate. Phase A: replace
  `_interp_keys`/`_apply_track`/`_cache_baselines` with
  AnimationPlayer + Animation resource translation; keep
  `_pick_state` as the JSON state-rule bridge. Phase B: accept
  `visual.mesh = "res://x.glb"` to load skinned imported meshes
  alongside code-drawn primitives. JSON authoring surface
  unchanged across both phases.
- **#97** (pending, blocked by #96) — Phase A: translator +
  AnimationPlayer plumbing + delete GDScript interp + tests +
  doc updates.
- **#98** (pending, blocked by #97) — Phase B: .glb loader +
  state-rule bridge to imported AnimationPlayer + material
  override decision + asset-designer skill update.

Out of scope across both phases: AnimationTree blend trees,
Mixamo retargeting, ragdoll rigging, rigging code-drawn
primitives. Those are separate-ADR follow-ups.

### TDTE UX polish queue (user feedback 2026-05-16, after Tier A landed)

Live-play feedback after the slot_grid + active-highlight session:

| ID | Issue | Direct quote |
|---|---|---|
| **#102** | Too many keys, not UX | "too many keys and not ux enough" |
| **#103** | Inventory ui is still ugly | "the inventory ui is still ugly" — wants icon-grid (Tier B) not text strings in cells |
| **#104** | HUD is in wrong place + no map open/close | "map open and close. hud location is weird, put at right top" |
| **#105** | Minimap doesn't show camera direction | "map HUD show what camera is 'viewing' (putting the cone thing)" |
| **#106** | Crosshair selection feels off | "the object crosshair selection is abit weird feeling, is the collision box put correctly (wrapping the mesh tight?)" |

Sequence proposal (cheapest → most-impactful per task):

1. **#106 (collision-tightness audit)** — likely a 1-line fix per
   entity def. Highest UX win-per-line. Direct cause of most "this
   verb didn't fire" frustration in playtests.
2. **#102 (input consolidation)** — collapse ~13 verb keys to ~6 by
   making E a context-sensitive "interact" that dispatches by
   crosshair target tag (forageable → gather, animal → attack,
   tree → chop, NPC → talk). Engine: needs either a multi-effect
   dispatch on `world.crosshair_target_tags` or per-tag input rules
   gated by the target's tags. Open question to resolve before
   coding.
3. **#104 (HUD layout + map modal)** — re-anchor primary vitals to
   top-right, strip the verbose bottom controls hint after #102
   reduces what it has to say, add M-key full-screen map modal
   (existing minimap data, freeze_world: true).
4. **#105 (minimap view cone)** — small engine change in
   minimap_widget.gd's _draw() to overlay a wedge from the player's
   facing. Author-configurable (show_view_cone, view_cone_color,
   view_cone_alpha, view_cone_radius).
5. **#103 (UI Tier B — item_icon element)** — closes the "looks like
   help text" gap. New element type that resolves def_id →
   `visual.params.<primary_color>` as a ColorRect inside the slot
   cell. Stack-count overlay optional.

Sequencing rationale:
- #106 is cheapest and unblocks frustration during dev play.
- #102 is the LOAD-BEARING UX fix — too many keys is the dominant
  complaint, and reducing them changes what HUD text is needed
  (which #104 then displays).
- #104 + #105 are layout/wiring work — both build on the
  consolidated input + tighter targeting.
- #103 is the visual polish that completes the inventory look.

OPEN QUESTIONS to surface before each lands:
- #102: hold vs press for "interact"? Examine merge into interact
  or stay separate? Overlapping targets (tree near NPC) → which
  wins?
- #104: map modal freezes sim or stays live? Fog-of-war?
- #106: tighten via per-shape redefine, OR via raycast `intersect_shape`
  near-miss tolerance, OR both?

### UI Tier A landed 2026-05-16 — slot_grid (#99 ✅)

`slot_grid` element added to control_factory.gd: array-bound grid
of bordered cells with per-cell active-slot highlighting. One
primitive serves hotbar (1×N) AND full inventory grid (5×7). HUD
+ inventory screen both consume it. Foundation for Tier B (icon
hotbar) + Tier C (full RPG inventory with tabs + paper-doll +
stats panel). 12 new unit assertions land it (874/0 → 875/0
after the custom-binding-promotion test).

Sequencing for B/C if user pursues:
- Tier B: new `item_icon` element type that swaps the slot_grid
  cell's text Label for a colored swatch / mini-mesh / 2D icon
  derived from a def_id. Lands when items need visual identity.
- Tier C: TabContainer wrapper + equipment_slot single-cell
  primitive + drag-and-drop input handling on cells. Lands when
  a game's GDD actually needs full RPG inventory.

### Rules file layout — reorganize 2026-05-16 (tasks #109, #110)

User feedback: `world/rules.json` is too big (Aldenmere hit 3624
lines) and the rules.json vs goals.json boundary is fuzzy — most of
goals.json is world logic that happened to land there because of
ADR 0009's split.

Audit confirmed: aldenmere's game/goals.json has 14 rules, only 2
of which are actual win/lose ('win_day3_survived',
'lose_player_died'). The other 12 (boot_latch, day_boundary_advance,
6 objective rules, 3 tutorial rules, win_screen_latch_assist) are
world simulation that happens to share scope.

Two separable changes:

**Change B (#109, do first)** — split monolithic rules.json into a
directory of feature modules. Engine: check for `world/rules/`
dir; if exists, glob `*.json` + concatenate `rules` arrays. Falls
back to single `world/rules.json` for backward compat. Aldenmere
splits into ~10 chains (movement, needs, sleep, weather, animals,
inventory, cooking, build, objectives, transitions). Each ~100-400
lines vs the current 3624 monolith. Diff readability up massively.
No ADR change needed — this is just file organization within
ADR 0009's world/ boundary.

**Change A (#110, blocked by B)** — collapse goals.json into
world/rules/. The 12 non-goal rules move to the appropriate
chain module (objective rules → objectives.json, transitions →
transitions.json, etc.). The 2 actual goal rules either move to
transitions.json (recommended: option α — delete goals.json
entirely; HUD already has declarative win:/lose: blocks) OR
keep a tiny declarative-only goals.json (option β: parallel
declarative path, needs new engine plumbing). Recommended: α.
Reverses ADR 0009; yume-game-rules-designer skill scope shrinks
or merges into yume-systems-designer.

Sequence: B is mechanical + low-risk + immediate readability win.
After B lands, A becomes obvious to do (goals.json's contents
clearly don't add anything over the chain modules).

### Skills update (2026-05-16, task #111)

After ADR 0009 revision landed, in-session updates touched only the
three highest-priority skills (yume-systems-designer's
description + global path rename; yume-game-rules-designer's
description + revision banner narrowing scope; yume-design
orchestrator's revision banner + one layout-block patch). 7 reader
skills + deeper sections in the 3 writer skills still reference
legacy paths (goals.json, single-file world/rules.json).

Strategy: ship the banner now (course-corrects LLM-readers
short-term), defer the thorough sweep to before the NEXT game runs
through /yume-design. Until then, the banner says "treat these
sections as legacy; here's the current shape." Empirically: user
flagged this on 2026-05-16 with "are the skills also updated?"

Task #111 tracks the sweep.

## 2026-05-17 — ADR 0046 Phase A + B + framework polish

Major framework completion session. Animation primitive (ADR 0046)
went from "GDScript interpolator + audit flagged" to "Godot
AnimationPlayer-backed, supports both code-drawn meshes AND .glb
skinned meshes." Codegen + asset-gen pipelines landed alongside.

### ADR 0046 Phase A — code-drawn meshes via AnimationPlayer

**Phase A.1** — `animation_translator.gd` bakes the JSON
`animations` block into a Godot AnimationLibrary at mesh-def load.
Per-piece tracks compile into TYPE_VALUE tracks targeting
`<piece>:<position|rotation|scale>` paths. 31 unit assertions cover
empty input, loop modes, baseline preserve/replace semantics,
multi-axis grouping, two-clip libraries, uneven-axis padding.

**Phase A.2 cutover** — `animation_director.gd` shed ~200 LoC of
hand-rolled interpolation (`_interp_keys`, `_apply_track`,
`_cache_baselines`, `_piece_cache`, `_missing_pieces_warned`).
Director is now ~80 lines: state-rule evaluation + Godot
AnimationPlayer dispatch. `entity_mesh_3d` mounts an
AnimationPlayer child per entity at mesh-build time + registers the
translated library + attaches to the director.

**Phase A.3 polish** — per-clip `interp: "cubic"` / `"linear"` /
`"nearest"` controls Godot's interpolation type (default linear).
Per-state `blend_seconds` cross-fade was already wired in A.2.
ADR 0035 status flipped from `proposed` to `accepted` with a 2026-
05-17 follow-up pointer to ADR 0046.

### ADR 0046 Phase B — `.glb` skinned mesh support

**Phase B.1+B.2** — `entity_mesh_3d._load_glb_mesh` detects
`.glb` / `.gltf` suffix in `visual.mesh`, loads via ResourceLoader,
walks the imported scene for the embedded AnimationPlayer (Godot's
GLTF importer creates one). State-rules drive playback via a
`clip_alias` map: `{"state": "walk", "clip_alias": "Walking"}` →
director plays `Walking` clip when the rule resolves to `walk`.
Fallback: state name verbatim when no alias.

**Phase B.3** — `material_overrides` walks every MeshInstance3D
child; for each surface whose material's `resource_name` matches a
key in overrides, DUPLICATES the material (per-entity, not shared)
and applies the override patch. Override values may be either a
bare color string (legacy shorthand) OR a dict with
`{albedo_color, albedo_texture, normal_texture, roughness,
metallic}`. Materials with `resource_name` empty fall back to
`surface_<i>` numeric keys.

`tools/inspect_glb.py` (pure stdlib, no `pygltflib` dep) parses
GLB JSON chunks directly. Prints nodes, meshes, surface→material
mapping, material albedos, animation clips. Authors copy names
verbatim from this output into `material_overrides` and
`clip_alias`.

**Phase B.4** — `tools/synth_test_glb.py` synthesizes a
24-vertex cube `.glb` with 2 materials (`body`/`trim`) + 2 clips
(`Idle`/`Walking`). Pure stdlib GLB generator — reproducible from
source. Output: `data/test_assets/cube_anim.glb` (2924 bytes,
checked in). End-to-end unit test loads the .glb via Godot's
importer + verifies AnimationPlayer + both clip names present.

ADR 0046 fully shipped. Animation reimplementation in Yume is
now Godot's C++ pipeline + a thin JSON contract.

### Test infrastructure — step_runner live-frame mirror

Scripted capture-tests (capture-script JSON via `--capture-script=`)
couldn't observe the screen-toggle close path (I-press to close
inventory) because synchronous step advances never gave
`screen_flow._process` a chance to fire its global_inputs handler.

`step_runner.gd::_tick_screen_flow` synchronously fires
`screen_flow.drain()` + `_handle_global_inputs()` between every
press/hold/wait verb. Plus `_is_world_frozen` check mirrors
world.gd's freeze gate so scripted `Input.action_press` while
inventory is open doesn't fake-fire the open rule. Plus
`_do_screenshot` awaits 2 frames (not 1) so pending queue_free's
of just-popped layers actually destroy before capture.

Net: `i_press_toggle.json` capture-script verifies the OPEN path
cleanly. The CLOSE path is now testable in principle but documented
as requiring real input event lifecycle — Godot's
`is_action_just_pressed` flag persists across synchronous code
between press+release, so the engine sees a spurious "just pressed"
on the next frame yield. Live play unaffected.

### Codegen pipeline (#101 — yume_codegen)

Python composable builders for Yume rule / entity / screen JSON.
JSON remains canonical; codegen is an optional emitter that catches
recurring hand-authoring bug classes at author-time via typed
keyword arguments.

Bugs the typed API prevents:
- Brace-wrapped bindings (`"{world.X}"` vs `world.X`)
- Wrong context-binding names (`self.foo` in a signal rule whose
  binding is `actor.foo`) — `require(actor=..., target=...)` makes
  the binding names visible to the author
- Schema landmines (`state_add` with `delta` vs `amount`)
- Empty effect lists (raises ValueError on emit)

Modules under `tools/yume_codegen/`: rules.py / effects.py /
entities.py / screens.py / lib_refs.py / io.py. ~720 LoC total.
Smoke test (30 assertions across all modules) verifies builder
output round-trips through JSON cleanly.

Co-exists with hand-authored JSON. Both paths emit the same
validator-passing output.

### Asset-gen pipeline (#116 — yume_assetgen)

AI-assisted texture + mesh generation pipeline. Reads
`data/<game>/asset_gen.json` (backend + style config), scans entity
defs for `*_prompt` fields (`albedo_texture_prompt`, `mesh_prompt`),
assembles styled prompts (`global_prefix + raw + <kind>_suffix`),
dispatches to the configured backend, writes output to
`assets/textures/` and `assets/meshes/`, and patches the entity
def with the resolved `res://` path so the engine can find it.

Architecture:
- `tools/yume_assetgen/config.py` — schema for asset_gen.json
- `tools/yume_assetgen/pipeline.py` — orchestration loop
- `tools/yume_assetgen/backends/base.py` — abstract Backend class
- `tools/yume_assetgen/backends/mock.py` — pure-stdlib placeholder
  backend (hash-deterministic gradient PNGs + cube .glbs). No
  external API calls; useful for smoke-testing + filling defaults.
- `tools/yume_assetgen/backends/REGISTRY` — name → class map.
  Real backends (`openai_images`, `stable_diffusion_local`,
  `tripo3d`) slot in by subclassing + adding a registry entry.
- CLI: `python3 -m tools.yume_assetgen <game> [--dry-run|--init|...]`

Idempotent under `skip_existing=true` (default). 19-assertion smoke
test covers scan, prompt assembly, dry-run, generate-with-mock
(PNG + GLB validity), entity-def patching, re-run idempotence.

### Engine: visual.albedo_texture + extended material_overrides (#117)

Companion to asset-gen — without this, generated PNGs would sit on
disk unused.

- `material_overrides` dict-form values: `{albedo_color,
  albedo_texture, normal_texture, roughness, metallic}`. Legacy
  string-color form (`{"body": "#a0c0e0"}`) still works.
- `visual.albedo_texture` on code-drawn meshes: walks every
  primitive's StandardMaterial3D + sets `albedo_texture`. Authored
  flat colors stay as multiplicative tint atop the texture.

Asset-gen → engine → renderer chain is now end-to-end.

### Validator updates

- `validate_scene_directors.py`: AUTO_MOUNTED_DIRECTORS allowlist
  mirrors WorldBoot's `_DEFAULT_DIRECTORS` (ScreenFlow,
  LightingDirector, ScheduleDirector, ...). Validator no longer
  false-positives on these being absent from per-game .tscn since
  WorldBoot mounts them automatically. Aldenmere reports [ok]
  instead of `[WARN] missing LightingDirector`.
- `validate_rules.py`: `engine_injected` check now skips
  override-edge pattern (`{name, edge}` only — inherits key from
  $include'd universal lib). Sokoban's 4 false positives gone.

### Skills update

- `yume-asset-designer` SKILL.md gains Strategy A2 documenting
  `.glb` authoring + `material_overrides` + inspect-glb workflow +
  `clip_alias` convention.

### Tasks shipped this session

| # | Title | Status |
|---|---|---|
| 97 | ADR 0046 Phase A — translator + cutover + polish | ✅ |
| 98 | ADR 0046 Phase B — .glb skinned meshes | ✅ |
| 100 | tools/validate_rules.py — static contract enforcer | ✅ |
| 101 | yume_codegen — Python composable builders | ✅ |
| 113 | ADR 0046 Phase A.3 — polish (cubic interp, docs) | ✅ |
| 114 | I-press toggle end-to-end capture-script test | ✅ |
| 115 | Validator sweep + fresh-bug scan | ✅ |
| 116 | yume_assetgen — pipeline + mock backend | ✅ |
| 117 | Engine: albedo_texture + extended material_overrides | ✅ |

Test bench: 907/0 unit + 19/19 Aldenmere scenarios +
19/19 yume_codegen smoke + 19/19 yume_assetgen smoke.

### Backlog after this session

**Pending — framework complete; remaining tasks are content / art**
- #90 — pick next small game after TDTE (deferred — design discussion)
- Real asset-gen backends (OpenAI Images / Stable Diffusion / Tripo3D)
  — slot into `tools/yume_assetgen/backends/`. Each needs API keys
  + per-backend testing. Mock backend covers the pipeline contract.
- Lighting / mesh / texture aesthetic improvements — separate axis
  per user roadmap (asset-gen first, then those).

## 2026-05-17 (session 2) — backends shipped + ledger + aldenmere asset replacement begun

Catch-up on plan vs reality + next axis of work.

### Backends shipped (closing the prior "pending" bullet)

- `tools/yume_assetgen/backends/nanobanana.py` — Google Gemini 2.5
  Flash Image text-to-image (PNG out). Used for textures + concept
  reference images. Env: `GEMINI_API_KEY`. Alias `gemini_image`.
- `tools/yume_assetgen/backends/tripo3d.py` — Tripo3D text-to-3D +
  image-to-3D. Async (submit task → poll → download .glb). Env:
  `TRIPO_API_KEY`. Endpoint shapes confirmed via live API test
  2026-05-17 (commit cbd36ee): `/v2/openapi/upload` returns
  `{"data": {"image_token": ...}}`; submit body uses
  `{"file": {"type": "png", "file_token": "<image_token>"}}`.
- asset_preview scene (`scenes/asset_preview.tscn`) +
  `--texture=<path>` flag — load .glb assets at full scale and
  preview with optional albedo override (commits 7d176cf, fb99d30).

### Paid-call ledger (#118 — landed this session)

`tools/yume_assetgen/ledger.py` — per-game JSON file at
`data/<game>/.assetgen_ledger.json` recording every successful paid
API call. Skip key: `(backend, kind, sha256(assembled_prompt))`.
Skips re-pay even when the output file was moved/deleted. Mock
backend stays untracked. Backend alias `nanobanana ↔ gemini_image`
treated as equivalent on lookup.

Why this exists: `skip_existing` only checked file presence; if a
.png or .glb got deleted/moved/renamed, the next run silently re-
paid. Ledger persists the "we already paid for this prompt" fact
independently of output-file lifecycle.

To force regen: delete the matching entry (or the whole file), or
edit the prompt (hash changes).

Smoke test extended with 2 new tests covering:
- ledger blocks paid re-run after the output .glb is deleted
- mock-backend run does NOT write to the ledger
- nanobanana ↔ gemini_image alias hit

### Aldenmere asset-replacement (in-flight, started this session)

Goal: replace code-drawn `@lib.meshes.*` primitives with AI-gen
`.glb`s entity-by-entity. Aesthetic target: "earnest, weathered,
folkloric" (GDD §Aesthetics target, line 1115).

State:
- `data/demo_aldenmere/asset_gen.json` authored (nanobanana for
  concepts + textures, tripo3d for meshes, style fields empty for
  now — per-entity prompts carry full aesthetic intent).
- `prop_tree` was the first replaced (Tripo3D, 2026-05-17,
  pre-ledger). Backfilled into ledger with `backfilled: true` flag.
  Underscore convention on its prompt keys (`_mesh_prompt`) dropped;
  prompts now use real keys + are protected from regen by the
  ledger hash. CAVEAT documented in entity `_asset_note`: if the
  ledger entry is ever deleted, regen lands at the entity-id-derived
  path (`prop_tree.glb`) not `conifer_tree.glb`, and material_
  overrides keyed by Tripo3D's UUID would silently no-op.

Active queue (user-directed: architecture first, then NPCs, then
player character):
- shelter_mud_hut + shelter_lean_to — prompts authored; pipeline
  running this session. Mesh+concept × 2 = ~$0.20-0.40.
- Next: NPC visuals (npc_morwen, then player_marken with animation
  clip_alias for walk/idle).
- After: foragables (food_berry_bush, food_red_mushroom, etc.) for
  the moment-to-moment interaction layer.

Per-entity post-gen tasks:
1. Visually QA the .glb via `asset_preview` scene (`scenes/
   asset_preview.tscn --asset=<path>`).
2. Tune `state_init.scale` to match the entity's intended footprint.
3. Inspect via `tools/inspect_glb.py` for material UUIDs; add
   `material_overrides` if recoloring needed.
4. Clean up stale `params` block (params don't apply to .glb meshes).
5. Re-run scenario tests + capture for in-game visual check.

### Asset naming system + no-overwrite directive (#119, 2026-05-17 session 2)

User directive (2026-05-17): **never delete a generated asset to
make room for an iteration.** AI-gen output is a paid artifact;
each iteration must produce a new filename so prior versions stay
on disk for side-by-side comparison.

Pipeline change:
- Output naming pattern: `<entity_id>[_<variant>]_<8char-hash>.<ext>`
  where hash = first 8 hex chars of `sha256(assembled_prompt)`.
- New optional fields per entity visual block:
  - `albedo_texture_variant` — slugified human-readable tag for
    texture iterations
  - `mesh_variant` — slugified tag for concept + mesh iterations
    (paired)
- Editing a prompt produces a new hash → new filename → guaranteed
  no overwrite of prior paid asset.
- `visual.mesh` (and `visual.albedo_texture`) auto-patched to the
  LATEST generation; older variants stay on disk as records.
- Backward compat: pre-existing un-suffixed files (conifer_tree.glb,
  shelter_lean_to.glb, shelter_mud_hut.glb) keep their names;
  ledger lookup is hash-based so their re-skip behavior is intact.

Feedback memory `feedback-never-delete-generated-assets.md` saved
so future sessions inherit the directive.

Smoke test extended to verify the new naming via glob pattern.

### Followup: per-entity scale/position visual QA (2026-05-17 session 2)

Tripo3D meshes have arbitrary internal scale + may include
artifacts (debris around base, off-axis bounding boxes). The bbox-
matching script (`fit-smallest ratio against original code-drawn
mesh`) gives a numerically-correct first-pass scale, but:

- bbox includes any baked-in debris (fallen leaves around lean_to,
  small foliage at mud_hut base) which inflates natural bbox →
  computed scale ends up too small.
- mesh may not be axis-aligned to the entity's intended forward.
- mesh's pivot point may not be at the entity's intended origin
  (mud_hut foundation should sit AT y=0; if the .glb's origin is
  at the geometric center, it floats above ground).

**TODO**: after each batch of new Tripo3D assets lands, do a
visual-QA pass in-game (not just asset_preview) to:
1. confirm scale reads right against player height (~1.6m)
2. confirm mesh sits flush with ground (translate y if needed)
3. confirm forward direction matches entity facing
4. add `state_init.position_offset_y` and/or rotation overrides if
   the mesh's natural orientation doesn't match the intended one.

Engine may need a small extension: per-entity visual offset
(translate + rotate) applied between mesh load and renderer attach.
Currently the mesh sits at the entity's position with no
adjustment. This is fine for code-drawn (author controls the pivot)
but breaks for AI-gen where the pivot is whatever Tripo3D chose.

Logged for the next iteration. For now, scale values come from
the bbox-matching script; expect 10-30% off in either direction
and tune manually after seeing in-game.

### Plan-vs-reality drift acknowledged

Several prior "pending" items shipped without task_plan updates.
Caught up here. Future skill/feature ships should append a brief
section here per `.claude/rules/docs.md` ("Append, don't rewrite").

### Aldenmere scene-1 progress + composition pass (2026-05-17 session 2 cont'd)

**Asset-gen progress** (entity replacements):
- Architecture batch (8): structure_fish_trap, prop_well, prop_log_pile,
  prop_workbench, prop_market_stall, prop_drying_rack,
  prop_wooden_bucket, grave_marker — all generated + scaled
- Tree variants (4): prop_tree_oak, prop_tree_birch, prop_tree_fruit,
  prop_tree_dead — all generated + scaled (4 tree species now
  match each other in height range)
- Foragables + atmospheric (12): generated via Tripo3D text-to-3D
  fallback because **Gemini 403 PERMISSION_DENIED on project
  460871333466** ("Lightning dunning decision is deny"). Meshes
  themselves look acceptable (berry_bush sample inspected). User
  needs to check Google Cloud console; outside Yume framework.

**Pipeline hardening (2026-05-17, post-mortem)**:
- Bug class: when a `mesh_reference_prompt` was declared but the
  concept call failed (nanobanana 403), the pipeline silently fell
  through to Tripo3D's text-to-3D mode + recorded a ledger entry
  that looked like a normal image-to-3D generation. Future runs
  would skip regen.
- Fix: `pipeline.py` now detects missing concept files + skips the
  mesh with `[skip-concept]` log + `skipped_concept_missing` status
  in the summary. User must fix the upstream concept backend OR
  remove `mesh_reference_prompt` to opt into text-to-3D.
- Smoke test still passes.

**Water shader primitive (ADR 0052)**:
- `godot/data/lib/shaders/water_stylized.gdshader` — animated
  value-noise ripples, no external textures
- Engine: `entity_mesh_3d._apply_shader_to_primitives()` reads
  `visual.shader` + `visual.shader_params`, swaps StandardMaterial3D
  for ShaderMaterial across all primitives
- ADR `docs/adr/0052-shader-as-visual-primitive.md` documents the
  pattern; future fire / glass / ice / multi-biome ground shaders
  reuse the same plumbing
- Wired on `prop_water_plane` with autumn river params

**WorldEnvironment polish (composition axes 5, 7, 8)**:
- `lighting_director.gd` extended with `_apply_static_environment()`
- New optional `scene.json` lighting blocks: `fog`, `tonemap`,
  `glow`, `adjustments`, `ssao`
- All applied once at boot (atmospheric mood, not time-of-day curves)
- aldenmere wired: warm gold fog (#c8b890, density 0.004), filmic
  tonemap, subtle bloom (intensity 0.25), saturation +12%, moderate
  SSAO

**Composition pass in flight** (per [[feedback-compose-dont-just-generate]]
+ `.claude/rules/soul.md` §Composition pass):
- ✅ axis 5 (lighting drama) — WorldEnvironment polish
- ✅ axis 7 (depth via fog) — distance haze added
- ✅ axis 8 (palette cohesion) — color adjustments + tonemap
- TODO axis 1 (ground variation / paths) — multi-biome ground shader
- TODO axis 2 (focal point) — level-designer pass on placements
- TODO axis 4 (tree clustering, density falloff) — level-designer pass
- TODO axis 6 (lived-in detail) — small props (cooking pots, lanterns,
  baskets) — needs Gemini fix OR text-to-3D acceptance

**Skill / rule hardening (institutional memory)**:
- Memory: `feedback_compose_dont_just_generate.md` — codifies the
  ChatGPT critique pattern. Asset gen ≠ scene quality past ~10
  entities; composition is the multiplier.
- `.claude/rules/soul.md` §Composition pass — 10-axis checklist
  + table mapping each axis to Yume primitives (existing or TBD).
  Now a behavioral gate, not just memory.


## Third-person mode — known issues (2026-05-19, audited 2026-05-21)

V-toggle FPS↔3rd-person works (ba338b6, 7992d77, 2171792). Original
seven-item issue list, with current status after this session:

- [x] **Pitch (vertical mouse-look) in third-person** — RESOLVED. The
  pitched_height + pitched_dist math in `_camera_third_person_3d`
  orbits the camera vertically around the player; mouse-up/down works.
- [x] **Mode-transition snap** — EFFECTIVELY RESOLVED via `lerp:
  1.0` in scene.json camera config (per user choice for instant-snap
  feel). With lerp=1.0, position snaps to desired each frame, so
  no 0.3-0.5s glide on V-toggle. If a future game wants smoothed
  follow (lerp < 1.0), `set_snap_pending()` would still be needed
  in the mode-change branch.
- [ ] **Animation set is minimal (idle+walk)** — STILL DEFERRED.
  Pressing other actions (sprint, jump, attack) plays idle. The
  jump action shipped this session but no jump CLIP plays. Expand
  morwen+player Tripo3D retargets: add run, jump, hurt clips ($0.30
  each). SDK exposes 11 biped presets per ADR 0053.
- [x] **WASD-strafe rotates player by velocity** — DECIDED. User
  explicitly chose locked-mode (camera + player rotate together,
  Skyrim/GTA-style) over Witcher-style face-motion. A/D strafes;
  body stays facing camera-forward. Not a bug; an explicit
  design call.
- [ ] **Camera collision** — STILL DEFERRED. At distance 4-8m, the
  camera can clip through walls/trees behind the player. Need
  raycast from player to desired-camera-position; if blocked,
  shorten distance. Becomes more important now that scroll-zoom
  goes up to 8m (was 4m fixed).
- [ ] **HUD layout in third-person** — STILL DEFERRED. Minimap,
  vitals, hotbar positioned for FPS framing; 3rd-person view might
  want them repositioned or hidden. Low priority — they're not
  visibly broken.
- [ ] **Crosshair visual feedback** — STILL DEFERRED. Crosshair
  renders at screen center in 3rd-person, but the actual target
  point is in front of the PLAYER, not the camera. Misleading for
  aim-based interactions. Fix: project player-facing-direction-ray
  to screen-space, render crosshair there.

Followups also expected on Tripo3D animation: SDK exposes 11 biped
presets; we only baked 2 (idle+walk). Next characters might want
run/jump/attack — ADR 0053 §Animation presets table has the list.

## Wireframe-to-UI harness: art / visual polish followups (2026-05-20)

Tier 2.7v shipped end-to-end this session — `wireframe_to_hud` +
`wireframe_to_screen` + `yume-hud-author` + `yume-screen-author`
skills produce fit-fit HUD + screen JSON from gemini-3.1 wireframes
via the LLM-as-parser pattern. What's mechanically done; what's
left is **art polish** the harness intentionally doesn't decide:

- [ ] **yume-visual-designer pass on aldenmere HUD + inventory.**
  The harness produces structurally-correct UIs, not aesthetically-
  tuned ones. Colors I chose (#a8c0e0 day, #f0e0a0 objective,
  #c07060 vitals title, #e8d8a0 inventory title, #c0a070 held-item
  label) are reasonable defaults — not curated for the aldenmere
  palette. Run the 7-axis visual review + apply concrete JSON edits.
- [ ] **Inventory item-detail panel content.** Currently shows
  `Held: <item_id>` as a single bound label. Wireframe drew a
  bigger right-side panel that could carry rich item info — name,
  flavor text, cooked/wet state, stats. Requires either richer
  binding paths (`def.<item>.flavor_text` lookup) or a small engine
  extension for "show selected slot's def fields" resolution.
- [ ] **Crosshair aesthetic.** Default `+` glyph 24px white is a
  placeholder. Aldenmere's palette could use a stylized crosshair
  (color-matched, custom glyph). Per-game decision; not a harness
  concern.
- [ ] **Inventory slot proportions.** Wireframe drew portrait tall
  cells (95×239 viewport); the original aldenmere inventory had
  landscape cells (110×65). Both valid; portrait cells are unusual
  but match what gemini drew. May want a "slot-orientation" hint
  in the inventory preset, OR accept that re-rolling produces
  different shapes (fit-fit purity).
- [ ] **Vitals placement drift.** Two HUD rolls produced different
  placements for vitals — center-left (first roll) vs bottom-left
  (second roll, with --crosshair). Both legitimate readings of the
  survival preset prompt. Tighten the preset prompt to pin one
  position, OR accept wireframe-is-spec semantics.
- [ ] **Formalize the "essentials check" idea.** Skill could output
  a report listing FUNCTIONAL elements likely missing from the
  wireframe (no crosshair on an FPS game, no minimap on an
  exploration game, etc.). Different from `--crosshair` — that
  flag is opt-in BEFORE gen; essentials-check is a report AFTER
  gen. Surfaces gaps the user can decide to fix or ignore.
- [ ] **Screen-author regression test.** HUD harness has the
  `test_deep_tree_no_lib_refs` gate. Screen harness doesn't have
  an equivalent regression test yet. Add one to catch
  effect-chain validator regressions.
- [ ] **More screen presets.** Currently 4 (inventory / pause /
  settings / title). Future games will want dialog modal, save-slot
  picker, level-select, achievement screen, ending screens, etc.
  Each is ~30 lines of preset prompt — cheap to add incrementally.
- [ ] **Inventory backup left as `.bak`.** This session's authoring
  replaced aldenmere's hand-authored inventory screen with the
  harness-generated one. Backup at `data/demo_aldenmere/
  screens.json.bak`. If the harness output is acceptable long-term,
  the .bak can be deleted; if the hand-authored richer version is
  preferred, restore from .bak.


## Session wrap (2026-05-21) — audit of today + carry-overs

### Shipped this session ✅

- **Wireframe-to-UI harness** end-to-end: HUD + screen + map authoring
  via LLM-as-parser. 3 new tools (`wireframe_to_*.py`), 3 new skills
  (`yume-*-author`), 3 orchestrators rewired. CV chain deleted.
- **ADR 0055 multi-biome ground** v2 accepted + implemented. New
  shader, `GroundRenderer.rebind_shader_params` engine method, level-
  transition hook (invariant #11 compliant), `gen_ground --biomes`
  texture authoring, aldenmere migrated.
- **Player jump** with gravity + grounding check + soft y-floor clamp
  (covers no-collision-body scenes).
- **Free-cam mode** for cinematic filming. WASD + Space/Ctrl +
  Shift sprint, pitch-aware forward, freeze-world guard.
- **Camera polish**: snap-orientation while position lerps,
  shoulder_offset config (set 0 — Skyrim-centered), scroll-wheel
  zoom (state.camera_distance clamped to [2,8]).
- **Standard FPS ESC behavior**: 1st = release cursor, 2nd = quit,
  click = re-capture. mouse_delta zeroed while released.
- **Shared @lib palettes**: hud.json + screens.json minimaps
  reference `@lib.palettes.wilderness_minimap`. ScreenFlow now
  routes through LibResolver.
- **Aldenmere Phase A flavor**: 4 new defs (log_bridge, water_tile,
  dry_grass_tuft, fallen_leaves), 322 entities in level_test_compose,
  prop_tree_oak + food_berry_bush migrated to y_offset_mesh.
- **mesh_yaw_offset = π/2** for player (Tripo3D rig orientation).
- **input_registrar mouse_button support** (Left/Right/Middle/
  WheelUp/WheelDown/WheelLeft/WheelRight/XButton1/XButton2).
- **Engine shutdown cleanup**: world.gd::_exit_tree clears
  GroundRenderer + Formula static caches.

### Gates hardened (post-mortem ritual) ✅

- `tools/validators/validate_rules.py` — `check_require_bindings`
  catches `require: {clock: ...}`-style mismatches against engine-set
  bindings. + `mouse_button`/`mouse_buttons` accepted as binding
  sources.
- `tools/validators/validate_camera_freeze.py` (new) — every
  `_camera_*` function that captures mouse must reference
  `freeze_world`. yume-tech-director Invariant #10 extended.
- `tools/validators/validate_level_instances.py` (new) — every
  `initial_instances[].def` + `patterns[].def` in level entities.json
  must exist in entities/. Catches stale legacy levels.
- `instance_patterns.gd` — engine-side push_warnings
  `[scatter.bounds_missing]` + `[scatter.under_spawn]`. Unit test
  pins both. Catches ALL call sites, not just harness path.
- `lib_resolver.gd` — depth counter no longer increments on plain
  JSON-tree recursion; only at @lib resolution boundaries. Unit
  test `test_deep_tree_no_lib_refs` pins the discipline.

### Pending / deferred to future sessions ⏭

ADR 0055 acceptance criteria — STATUS as of 2026-05-23:
- ~~FPS comparison capture (single-albedo vs 5biome)~~ — OBSOLETE.
  Per ADR 0058 Phase A (2026-05-23), the single-albedo shader was
  deleted; there's no baseline left to compare against. Replace
  with: per-game perf baseline captured in scene.json's
  `_perf_baseline` block + a future ADR-0058 acceptance gate that
  measures FPS drop between template-rendered shaders.
- [ ] `yume-visual-designer` 7-axis review on the multi-biome render
  — STILL PENDING. Worth one round before declaring ADR 0055 done.
- [ ] Sparse-override unit test in test_runner.gd for
  GroundRenderer.rebind_shader_params — STILL PENDING (cheap;
  ~20 lines).

Third-person mode known issues from 2026-05-19 (carried forward):
- [ ] Animation set expansion (run/jump/attack clips — currently
  idle+walk only). Tripo3D SDK exposes 11 biped presets;
  ADR 0053 §Animation presets table has the list.
- [ ] Mode-transition snap (set_snap_pending on V-toggle).
- [ ] Camera collision (raycast from player to desired-camera-pos;
  shorten on hit).
- [ ] HUD repositioning for 3rd-person (vitals/minimap framing).
- [ ] Crosshair POV in 3rd-person (currently screen-center; user
  expects player-facing-direction projection).
- [ ] **Resolved this session — formerly pending:**
  - ~~Pitch (vertical mouse-look) in 3rd-person~~ — works (pitched_height
    in camera_director).
  - ~~WASD-strafe rotates player by velocity~~ — explicitly chose
    locked-mode (camera + player rotate together, Skyrim-style).
    Witcher/GTA-style strafe-rotates-body deferred indefinitely.

Wireframe-to-UI harness art polish (from earlier this session):
- [ ] yume-visual-designer pass on aldenmere HUD + inventory.
- [ ] Inventory item-detail panel content (richer than `Held: <id>`).
- [ ] Crosshair aesthetic (default + glyph 24px white).
- [ ] Inventory slot proportions (portrait vs landscape).
- [ ] Vitals placement drift (center-left vs bottom-left).
- [ ] Formalize "essentials check" report in the skill.
- [ ] Screen-author regression test in test_runner.gd.
- [ ] More screen presets (dialog, save-slot, level-select, etc.).
- [ ] Decide on inventory backup (`screens.json.bak`).

Nanobanana backend polish:
- [ ] Auto-detect JPEG `inline_data` mime + transcode to PNG at save
  time (currently we manually PIL-convert when Godot rejects). See
  memory `reference_gemini_jpeg_with_png_extension.md`.

Cosmetic warnings on game quit (deferred — Godot internals):
- ~33 StringName orphans + 1 resource still in use at exit. Confirmed
  cosmetic — they're from GDScript's static-class-name table +
  ResourceLoader's internal cache, not from our code. World.gd's
  _exit_tree cleans our known static refs (GroundRenderer + Formula);
  the rest is Godot 4 framework. Accepted as-is.

### Engine surface added this session

- `GroundRenderer.rebind_shader_params(level_id)` — per-level shader
  param override from `levels/<id>/scene.json` (ADR 0055)
- `GroundRenderer.cleanup()` — static cache teardown
- `Formula.clear_cache()` — already existed; now called from
  world._exit_tree
- `character_body_runner._apply_vertical()` + `_writeback_vertical_state()`
  — gravity + grounding (jump support)
- `camera_director._camera_free_cam()` — cinematic mode
- `camera_director._mouse_released_by_user` static latch + ESC
  handler in `update_follow`
- `input_registrar._mouse_button_idx()` — mouse-button keycode lookup

### New ADRs

- ADR 0055 — Multi-biome ground from the semantic map (accepted)

### Files added (new lib content)

- `data/lib/shaders/ground_5biome.gdshader`
- `data/lib/palettes/wilderness_minimap.json`
- `tools/visual_layout/legends/scatter_presets.json` (carried from
  earlier compose_map work, now lib-pathed)


---


## Session wrap (2026-05-22 / 23) — visual_qa Phase A + world-model framing

Two days of work that span a complete arc: identified visual QA as
a generation-gate gap, designed and shipped Phase A (assertion
library + capture-per-test runner), caught a real bug class on the
first run (non-tileable albedos producing tile-grid artifacts),
fixed it at three layers (per-game scene.json, shared default
prompts, static validator), and crystallized Yume's positioning as
an explicit programmable world model.

### Shipped ✅

**Visual QA test-driven gate (ADR 0056 Phase A):**
- 8 starter assertion JSONs under
  `data/lib/visual_qa/assertions/`: relative_size, no_clipping,
  rotation_facing, no_floating, distinct_silhouettes,
  no_orphan_cubes, specular_response, pivot_at_foot.
- `tools/visual_qa/run_plan.py` runner. Reads
  `visual_test_plan.json`, resolves entities → world coords,
  computes camera pose per assertion's framing rule, drives
  Godot once per test (toggles freecam + temp camera), produces
  `visual_test_report.md` with PNG paths + rendered prompts +
  PASS/FAIL slots.
- `tools/visual_qa/sample_plans/aldenmere_smoke.json` — 8-test
  hand-authored plan covering all 8 starter assertions on
  aldenmere/level_proto_village.
- Self-healing for stale Godot `.import` sidecars with
  `valid=false` — runner sweeps them before `--import` so the
  cubes-everywhere bug class can't fool subsequent runs.

**Biome regen with anti-centroid prompts:**
- `gen_ground.py` DEFAULT_BIOME_PROMPTS for water + path rewritten
  with positive 9-thirds composition rule (replaces ignored
  "no central focal point" negative phrasing).
- `biome_water_dfc54f3f.png` + `biome_path_13233ca8.png` generated
  via nanobanana, uniformly distributed (validator passes).
- `tools/validators/validate_tileable_albedo.py` (new) — measures
  radial-concentration intensity diff (center vs edge) on every
  ACTIVE biome albedo referenced by `scene.json.shader_params`.
  Flags > 25 on the 0-255 scale. Old/orphaned PNGs on disk
  skipped (per never-delete-generated-assets discipline).

**Visual QA framing tuning + math fix:**
- look-at yaw formula corrected (previous version pointed camera
  180° away from target). `atan2(cam.x - target.x, cam.z -
  target.z)` per Godot's fwd convention.
- All 7 framing rules tuned: low_angle_profile 6→2.5m,
  eye_level_wide 10→4.5m, etc. Added `_subject_spread_factor` so
  multi-subject framings widen the camera proportionally.

**Visual-QA rule hardening:**
- `.claude/rules/visual-qa.md` extended with Step 0/0a/0b/0c —
  MANDATORY pre-capture protocol: frame the feature (Step 0),
  derive world position from authoritative data (Step 0a — biome
  map / heightmap / entities.json / scene.json lighting), derive
  camera params per feature class (Step 0b — height/pitch/distance
  table), scene sanity sweep (Step 0c — one extra capture per
  session from random vantage). Turns improvised visual QA into a
  data-driven procedure.

**Yume positioning document:**
- `docs/guideline/00_what_yume_is.md` — load-bearing positioning. Yume is an
  EXPLICIT PROGRAMMABLE WORLD MODEL. JSON = world specification
  language. Runtime = interpreter. Godot = projection function.
  Cites the implicit (DreamerV3, MuZero, Genie) vs explicit (game
  engines, sims) split from ML literature. Includes "Implications
  for ADR authors" with 4 cite-able questions every future ADR
  defers to.

**Visual_qa runner robustness:**
- `cp -r` shell call instead of `shutil.copytree` (WSL mount race
  between rmtree-then-copytree).
- `--import` timeout bumped 120 → 360s (asset/shader regen can
  take 2-4 min on first run after changes).
- Stale `valid=false` sidecar cleanup before `--import`.

**New gates / validators:**
- `validate_tileable_albedo.py` — radial-concentration check on
  active biome albedos. 18 validators pass for demo_aldenmere now
  (was 16 last session).
- Visual-qa Step 0/0a/0b/0c gate in `.claude/rules/visual-qa.md`.
- `[[reference-godot-valid-false-import]]` memory entry for the
  stale-.import-sidecar gotcha (manual Godot runs need to clean
  these by hand).

### New ADRs

- **ADR 0056** — Visual assertion library + capture-per-test
  runner. ACCEPTED. Phase A shipped.
- **ADR 0057** — yume-visual-tester skill (auto-generate visual
  test plans). PROPOSED. Implementation deferred to validate ADR
  0056 first.
- **ADR 0058** — Shader as JSON (templates + composable
  primitives). PROPOSED. Two-phase design covering both Jinja2
  templates (Phase A) and DAG-composable primitives (Phase B).
  Seven generality principles baked in from day one.

### Pending / next session ⏭

- [ ] **Task #92** — ADR 0057 Phase B: yume-visual-tester skill
  implementation. Drafts priors library + the skill that auto-
  generates `visual_test_plan.json` from GDD + entities.json + git
  diff. Eliminates per-game hand-authoring of test plans.

- [ ] **ADR 0058 Phase A** — shader templates. Convert
  `ground_5biome.gdshader` to a Jinja2 template; build
  `tools/yume_shadergen/` codegen; migrate aldenmere; gate via
  visual_qa runner. Acceptance: identical render before/after,
  6th biome takes one JSON entry not a GLSL edit.

- [ ] **ADR 0058 Phase B** — composable shader primitives.
  Define primitive interface schema; land 6-8 starter primitives
  (sample_world_uv, biome_blend, vertex_displace, uv_scroll,
  triplanar_sample, ...); DAG compiler.

- [ ] Carry-overs from last session (still valid):
  - FPS comparison capture for ADR 0055 (single-albedo vs 5biome
    @ 1080p, ≤5% drop threshold)
  - yume-visual-designer 7-axis review on multi-biome render
  - Sparse-override unit test for GroundRenderer.rebind_shader_params
  - Animation set expansion (run/jump/attack — Tripo3D 11 biped
    presets, only baked 2)
  - Camera collision in 3rd-person mode
  - HUD repositioning for 3rd-person framing
  - Crosshair POV in 3rd-person (player-facing-direction projection)
  - Nanobanana auto-detect JPEG mime + transcode at save time

### Empirical bug classes caught this arc

- **Stale `.glb.import` `valid=false` sidecars** — once Godot
  fails to import a resource, it marks the sidecar invalid and
  NEVER retries. 10 .glb files in aldenmere were in this state;
  caused cubes-everywhere baseline that initially looked like a
  shader regression. Gate: `tools/visual_qa/run_plan.py` sweeps
  these before `--import`.
- **Non-tileable albedos** — water + path biome textures had
  radial concentration (center 60% brighter than edges) that
  produced visible N×N grid patterns at uv_tile=30 across the
  plane. The radial check is now a static validator.
- **Negative-only prompts ignored by Gemini** — "no central focal
  point" doesn't constrain the model. Positive 9-thirds
  composition rule ("each of the 9 thirds has equal density")
  does. Codified in DEFAULT_BIOME_PROMPTS.
- **Yaw sign error in look-at math** — initial visual_qa runner
  pointed cameras 180° away from targets. Caught by capturing
  with extreme uv_tile + comparing screen content to expected.
- **Improvised visual QA framing** — pre-Step 0/0a/0b/0c, the
  operator picked camera positions by trial and error. ~6
  attempts on a single shader verification before realizing the
  target wasn't even in frame. Codified into the rule.

### Engine surface added

- `camera_director.gd` — ephemeral free-cam pose vars + fallback
  chain so games without `free_camera` entities still get a
  functional cinematic mode (without writing to player.state.
  position and fighting physics)
- `tools/yume_assetgen/gen_ground.py` DEFAULT_BIOME_PROMPTS — new
  positive composition rule prompts for water + path

### Files added (tracked)

- `docs/guideline/00_what_yume_is.md` — positioning document
- `docs/adr/0056-visual-assertion-library.md` — accepted
- `docs/adr/0057-yume-visual-tester-skill.md` — proposed
- `docs/adr/0058-shader-as-json.md` — proposed
- `tools/visual_qa/__init__.py`
- `tools/visual_qa/run_plan.py` — assertion runner
- `tools/visual_qa/sample_plans/aldenmere_smoke.json` — example plan
- `godot/data/lib/visual_qa/assertions/*.json` — 8 starter
  assertions (gitignored under godot/data/ — these are lib content
  treated as content, not engine)
- `tools/validators/validate_tileable_albedo.py` — new validator
- `tools/validators/validate_visual_presence.py` — new validator
  (catches missing visual.hidden on logical entities — added during
  the cube post-mortem mid-session)

### Memory entries added

- `feedback_visual_qa_control_camera.md` — Step 0/0a/0b/0c
  procedure for camera framing during visual QA
- `reference_godot_valid_false_import.md` — the .import sidecar
  gotcha

---

## Session wrap (2026-05-24) — physics derivation cleanup + no-escape-hatches invariant

One day of physics-pipeline cleanup that surfaced a deeper framework
principle. Started with "real ground collider instead of magic
y_floor clamp," ended with "every collider geometry, static or
character, derives from a real .glb mesh — no per-def manual
numbers anywhere." The arc was driven by progressively-stricter user
review of debug-collider captures.

### Shipped ✅

**Real ground collider (task #124, commit `b1b23b2`):**
- Replaced the soft `y <= 0 → snap` convention in
  `character_body_runner._writeback_vertical_state` with a real
  StaticBody3D + BoxShape3D attached by GroundRenderer.build,
  sized to `scene.json.ground.mesh.size`. Critical fix: explicit
  `collision_layer = 1 << 2` ("floor") so the player's mask
  detects it.
- Soft clamp kept as opt-in fallback (entity declares
  `state.floor_y`) for collider-less scenes (2D demos, abstract
  puzzles, headless tests).
- Walk off the visible plane → fall indefinitely. Walk on it →
  Godot's `is_on_floor()` returns true via physics, no convention
  layer needed.

**Debug-collider wireframe pipeline (commits `d6b5426`, `009c59c`,
`ccf87e0`, `8c2a295`, `7234f78`):**
- Static colliders (PhysicsServer3D RIDs) get custom green
  wireframe MeshInstance3Ds — Godot's built-in
  `debug_collisions_hint` only renders scene-node CollisionShape3D
  children. SurfaceTool.PRIMITIVE_LINES, 12 edges per box.
- Wireframe parented to `_world` directly (NOT renderer) and
  positioned in world space — bypasses both `visual.y_offset` lift
  AND `state.scale` propagation that the renderer applies. The
  intermediate attempts (subtract y_offset only / 009c59c)
  surfaced the second transform issue (scale inheritance) that
  required parenting-to-world.
- Proximity cull (15m radius from active Camera3D) + frustum
  cull (`is_position_in_frustum`) + Z-buffer occlusion. Each
  layer reduces the on-screen wireframe count progressively.
- Group `_yume_debug_collider` tags each wireframe; GameShell
  `_cull_debug_colliders_by_distance` runs per-frame.

**Character body honors state.scale (task #126, commit `8c2a295`):**
- PhysicsBodyBuilder.build_character_3d's new
  `_apply_state_scale_to_body` helper sets the CharacterBody3D's
  `transform.scale` from `state.scale`, mirroring
  EntityMesh3D._sync_scale. CollisionShape3D child inherits via
  Godot's scene-tree transform composition.
- Rabbit at `state.scale=0.35` → capsule scaled by 0.35 → bunny-
  sized hitbox. Was human-sized (lib value) before.

**The post-mortem moment — `_aabb_intent` escape hatch killed
(task #128, commit `8f0f175`):**
- Trees + workbench + grave_marker had
  `_aabb_intent: "design"` opting out of validator's mesh-bbox
  derivation. Authors set `aabb_extents` manually, forgot
  `aabb_offset` → colliders sat half-buried. User had to flag
  each individually.
- Fix: deleted the `_aabb_intent` skip entirely from
  `validate_aabb_extents.py`. Engine + data + validator all
  unified: collider derived from mesh, NO escape.
- New top-of-file invariant in `.claude/rules/data-demo.md`:
  **"no per-def escape hatches from automated derivation"**.
  Codifies that every value the engine can derive from the world
  model MUST be derived; per-def manual overrides are an
  anti-pattern. Anywhere we'd reach for one, the fix is to
  improve the derivation OR fix the source data.

**Character lib body sizing convention (task #129,
commit `35ddbf9`):**
- Surfaced when state.scale-on-body made `player_marken` (scale
  1.7) a 3m giant. Cause: lib values authored at inconsistent
  conventions — animal lib sized for natural .glb,
  player/npc libs sized for final world dims (so state.scale
  double-counted).
- Re-authored all character_* libs to a uniform "natural .glb
  mesh at state.scale=1.0" convention. Added explicit
  `_sizing_convention` doc to bodies.json. Deleted dead-code
  `standard_kinematic_*` libs (no references — pre-1.0 just
  delete).
- Converted `player_marken` inline physics block to
  `$extends @lib.physics.bodies.standard_character_player`.

**Option 2: split-mesh visual/collision (task #130, commit
`52f0e92` equiv):**
- After removing `_aabb_intent`, the trees collided as their
  full canopy bbox — couldn't walk between trunks. User asked
  for the principled fix. Discussion converged on "second
  derivation source, not override": new
  `properties.collision_mesh` field points at a different .glb
  whose bbox defines the collider.
- New primitive `data/lib/assets/meshes/primitive_cylinder.glb`
  (radius=0.1, height=1.0, bottom-rooted). Generated by
  `tools/gen_primitive_cylinder.py` (pure-stdlib .glb writer,
  no pygltflib/trimesh).
- Aldenmere's 5 tree species now point at the primitive →
  narrow trunk colliders. Visual canopy stays wide. Player
  weaves between trunks.

**Unified mesh derivation across static + character (task #131,
commit `7286179`):**
- Generalized the .glb-derived-collider pattern to character
  capsules. New primitive
  `primitive_humanoid_capsule.glb` (radius=0.15, height=1.0).
  PhysicsBodyBuilder.`_build_collision_shape_node` reads optional
  `mesh` field on every shape type; new `_glb_bbox` helper parses
  .glb header directly in GDScript (mirrors Python validator),
  cached per path.
- Lib character templates ditched manual radius/height values
  entirely — all reference the humanoid primitive. To change
  humanoid proportions: regenerate the primitive .glb.
- Result: every collider geometry — static box, character
  capsule, trunk cylinder — derives from a real .glb. No manual
  dimension numbers anywhere in any per-game def or per-game
  lib reference.

### Framework invariant crystallized

**Anything the engine can derive from the world model, the
engine MUST derive — every time, no per-def opt-outs.**

Codified at `.claude/rules/data-demo.md` top-of-file. Empirical
case: `_aabb_intent` (the escape hatch this session killed) is the
template. Applies forward to every derivation: aabb sizing,
y_offset, material UUIDs, scale, body shape, director mounting.
Codified in memory as `feedback_no_escape_hatches.md`.

### New files (tracked)

- `tools/gen_primitive_cylinder.py` — pure-stdlib .glb emitter
  for collision primitives
- `godot/data/lib/assets/meshes/primitive_cylinder.glb` —
  narrow trunk primitive
- `godot/data/lib/assets/meshes/primitive_humanoid_capsule.glb` —
  humanoid capsule primitive
- `data/lib/assets/` directory established for framework-shared
  collision/visual primitives

### Memory entries added

- `feedback_no_escape_hatches.md` — invariant + empirical case

### Tasks completed this session

124 (real ground collider), 125 (frustum-cull wireframes), 126
(state.scale on character bodies), 127 (design-intent offset
defaults; later superseded by 128), 128 (delete `_aabb_intent`
entirely), 129 (lib body sizing convention), 130 (option 2 —
properties.collision_mesh), 131 (unified mesh-derived capsule).

All commits + tests green: 941/941 unit tests, 19/19 aldenmere
scenario tests, all validators pass --strict.

---

## Yume identity restated (2026-05-24)

**Yume IS an explicit, programmable world model.**

This is the foundational claim — what Yume actually IS. Every
game world Yume runs is a fully-explicit specification: state,
mechanics, agents, aesthetics, all in auditable JSON the runtime
interprets. The world isn't baked into a neural net (implicit
world models like DreamerV3, MuZero, Genie); it lives where a
human (or another LLM, or another program) can read it, modify
it, version-control it, ADR it.

**Aesthetic + coherent + cinematic generation is ONE of Yume's
features** — current focus when the output is a 3D scene. Other
features (all flowing from the same "explicit world" property)
include: genre-agnostic substrate, LLM-authorable end-to-end,
hot-reloadable + version-controllable worlds, test-driven via
validators/scenarios, trajectory recording for RL research,
composable primitives, cross-renderer (2D/3D). Each traces back
to the same structural property: the world is explicit.

Next session resumes on the scene/map generation pipeline (the
aesthetic-cinematic feature). The physics derivation work is
done; the visual/composition pipeline still has open work
(visual_qa Phase B / ADR 0057, shader templates / ADR 0058
Phase A, composition pass automation per soul.md §Composition).

---

## Proposed pipeline: text-to-world scene generation (2026-05-25)

Default backend: OpenAI (gpt-image-2-2026-04-21 for image gen,
gpt-4.1-mini for vision). nanobanana / imagen remain available
for ad-hoc use.

### 7-stage pipeline

```
SCENE BRIEF
  ↓
Stage 1  REFERENCE         photoreal top-down aerial
Stage 2  CLASS CATALOG     per-scene class list (dynamic)
Stage 3  SEMANTIC MAP      flat-color, conditioned on reference
Stage 4  HEIGHTMAP         grayscale, TERRAIN ONLY (no building height)
Stage 5  EXTRACTION SCRIPT LLM writes custom Python per-map
Stage 6  ASSET PROMPTS     per object, style-anchored to reference
Stage 7  ENGINE WIRING     shader + objects + heightmap
  ↓
PLAYABLE SCENE
```

### Mapping to existing vs new

| Stage | Existing | New |
|---|---|---|
| 1 | `/yume-topdown-prompt` + `openai_images.generations` | — |
| 2 | — | `yume-scene-class-catalog` skill |
| 3 | `openai_images.edits` route (shipped 2026-05-25, commit c11645b) | per-scene prompt template |
| 4 | `ADR 0052` engine support | gpt-image-2 grayscale heightmap test |
| 5 | — | `yume-extract-author` skill (LLM-as-script-author) + `compose_semantic_extract` harness |
| 6 | `yume-asset-designer` writes prompt fields | style-consistency anchor (pass reference image to every asset gen) |
| 7 | ADR 0055 multi-biome shader, ADR 0052 heightmap, `compose_map` placement | orchestration wiring auto-gen outputs |

### Terrain vs object split (load-bearing design)

Class catalog (stage 2) tags each class with an intent-type
that routes its consumption:

| Intent | Examples | How it manifests |
|---|---|---|
| `terrain_shader` | grass, dirt, cobblestone, sand, water_shallow | one big ground plane, biome shader (ADR 0055) |
| `terrain_displacement` | hill, valley, ridge, riverbed | heightmap.png drives vertex displacement (ADR 0052) |
| `object_placement` | house, townhall, market, well, tree, statue | spawned as Yume entities at extracted positions |

"River" might be `terrain_shader` (blue ground biome) OR
`object_placement` (with fish + current entities) depending on scene
needs — the catalog is where the decision lives.

### Open design questions

1. **Object rotation** — semantic colors don't encode orientation.
   Three options: (a) infer at extraction time from spatial context
   ("house faces nearest road"), (b) per-class default rotation, or
   (c) separate pass: Claude reads photoreal ref + per-object bbox
   and infers rotation.

2. **Heightmap conditioning** — does gpt-image-2 emit a clean
   grayscale heightmap when image-conditioned on a photoreal aerial?
   First test on the medieval-town reference. If no, consider depth-
   estimation model (MiDaS) or default flat terrain.

3. **Class catalog source** — pure auto vs library+override vs
   user-specified. Lean toward LIBRARY+OVERRIDE: base catalog
   of common classes (forest/grass/water/dirt + house/wall/road) so
   terrain-shader biomes stay consistent for the engine; LLM adds
   per-scene object classes (townhall/market/temple/etc.).

4. **Style anchor for assets** — pass photoreal aerial via /edits
   to every asset-gen call (strong style transfer, expensive) vs
   extract a "style sheet" text once (palette + material vibe) and
   inject into every asset prompt (cheap, weaker). Probably hybrid:
   style sheet for cheap iter, /edits for hero assets.

5. **Heightmap = TERRAIN ONLY** — need the model to "ignore
   building tops, render only ground elevation." Building footprint
   should be SAME color as surrounding ground. Test prompt:
   two-pass or explicit instruction.

### First concrete piece (de-risk)

Stage 4 is the most uncertain — does gpt-image-2 actually emit a
clean grayscale heightmap? Everything else is orchestration of
patterns already proven. Test:
- Reference: existing photoreal medieval-town aerial
- /v1/images/edits, gpt-image-2, grayscale-only prompt
- Verify output: grayscale, river dark, ground mid, buildings
  blend with footprint (not rendered as elevated)

If yes → lock the rest of the design.
If no → swap to depth-estimation model OR flat-default terrain.

---

## Text-to-world pipeline — implementation log (2026-05-25 → 2026-05-26)

Status as of 2026-05-26:

```
Stage 1 ✓ /yume-topdown-prompt + openai_images.generations
Stage 2 ✓ /yume-scene-class-catalog (v2 dynamic)
Stage 3 ✓ openai_images.edits (image-conditioned semantic map)
Stage 4 ✓ openai_images.edits (grayscale heightmap, terrain only)
Stage 5 ✓ /yume-extract-author + lib_extract.py
Stage 6 ⏸ DEFERRED — asset gen per class with style anchor
Stage 7 ✓ MINIMAL — compose_world.py + 3 unit primitives
              (proves structural pipeline; aesthetic via stage 6 later)
```

End-to-end milestone proven on medieval-town test scene
(`godot/data/demo_pipeline_v1/`): prose brief → photoreal aerial
→ catalog → semantic map → heightmap → 260 extracted instances
→ runnable Yume scene with primitive boxes/cylinders/spheres.
Layout fidelity preserved; aesthetic is crude but structurally
correct. Total wall-clock ≈ 8 minutes API calls + seconds of CPU.

### Stage 6 — DEFERRED (asset gen per class with style anchor)

Skipped to prove the pipeline structurally first. When ready:

- For each `object_placement` class in extracted.json, generate
  a per-class asset (.glb mesh or photoreal billboard) sized per
  the class's expected dimensions.
- Pass the stage-1 photoreal aerial as a STYLE ANCHOR to every
  asset gen call so all classes share visual language (medieval
  town's wooden+stone vs sci-fi colony's chrome+neon).
- Output: replace each class's prim_unit_* mesh in `entities/
  auto_gen.json` with the generated .glb path; engine wiring is
  identical to stage 7 minimal.
- Probable backend: tripo3d for meshes (already shipped) OR
  openai_images.edits + Yume's billboarding for low-cost iteration.
- Style consistency choice: pass photoreal aerial via /edits to
  every call (strong, expensive) vs extract a style-sheet text
  once and inject (cheap, weaker). Likely hybrid: text sheet
  for default; /edits for "hero" classes (townhall, focal anchor).

### Stage 7 — open follow-ups (when we resume)

Ranked by visual impact per effort:

1. **Ground texture wiring** — semantic map's color regions
   (blue river, dark green forest, tan cobblestone) aren't
   currently variegating the ground; only the fallback flat
   color shows. Fix: route the semantic map through
   `ground.mesh.shader_params.biome_map` per ADR 0055 instead
   of `albedo_texture`. ~30 lines of compose_world tweak.
   Highest visual return per minute.

2. **Extraction count drift** — 216 houses extracted vs 60
   catalog-expected. The stage-3 semantic map painted dense
   small rectangles where the catalog imagined fewer unified
   blocks. Two fixes possible:
   - Tighten stage-3 prompt to ask for fewer larger building
     clusters (prompt-side fix)
   - Add a `merge_within_meters` post-process at stage 5 that
     collapses adjacent same-class instances (extraction-side
     fix; the yume-extract-author skill mentions this in its
     "multi-color family classes" section)

3. **Stage 6 — asset gen** (see above)

4. **Per-game .tscn auto-gen** — compose_world.py now generates a
   per-game .tscn launcher (`<name>_3d.tscn`) so the universal
   play.tscn's 2D-default renderer doesn't break 3D scenes.
   Works but worth considering: should play.tscn auto-detect
   2D vs 3D from scene.json's renderer block? Future cleanup.

5. **River-edge bridge noise** — 6 bridges extracted vs 2 expected.
   Color thresholding picked up river-bank brown pixels as
   bridges. Fix: filter bridge instances by "adjacent to water"
   check at extraction time. ~5 lines of per-scene script
   tweak when re-running the medieval-town extraction.

### Tasks completed this 2-session arc (2026-05-25 to 2026-05-26)

Commits in order:

- `e9f65d7` — openai_images backend (gpt-image-2-2026-04-21)
- `92d0761` — /yume-topdown-prompt skill (stage 1)
- `c11645b` — openai_images /edits route (multipart, multimodal)
- `b564406` then `ef24d42` v2 — /yume-scene-class-catalog skill
  (stage 2; v2 made it fully dynamic, 6-32 classes per scene)
- `31129d5` — task_plan: 7-stage pipeline design
- (heightmap-test, in-place commit) — verified gpt-image-2 emits
  clean grayscale heightmap (stage 4 proven)
- (stage-5 commit) — /yume-extract-author skill + lib_extract.py
- `31c9e4c` — compose_world.py + 3 unit primitives (stage 7 minimal)

End-to-end smoke test at
`godot/data/demo_pipeline_v1/`. Run via:
```
./scripts/play.sh pipeline_v1 --capture
# or
godot --path . scenes/demo_pipeline_v1_3d.tscn -- --capture-after=3 --capture-output='user://test.png'
```

Pipeline next-step: ground texture wiring (#1 above) is the
highest visual return per minute. Stage 6 asset gen is the
biggest commit but unblocked.

---

## Stage 7 — 2026-05-26 iteration: 3D camera + free-cam wiring

End-to-end milestone updated. Scene now starts in `isometric_3d`
at 45° for an immediate 3D view (commit `152f168`). Open
follow-ups added below.

### Empirical bugs caught this session

Three engine-convention surprises surfaced when running the
generated demo end-to-end. None are compose_world bugs — they're
existing engine conventions the auto-gen pipeline didn't know
about. Worth codifying as gates:

1. **`world/state.json` does NOT hold entity definitions.** That
   file is for env-level non-entity state (per data-demo.md). Entity
   defs (including singletons like `world_clock` + utility entities
   like `free_camera`) MUST live in `entities/<name>.json`. Engine
   silently skipped my defs in state.json — the symptom was "only
   6 defs loaded" instead of the expected 8+.

   **Gate**: compose_world's docstring + a static validator that
   warns if a `definitions` block exists in `world/state.json`.
   Future generators should never put defs there.

2. **Input action names are engine-canonical.** camera_director.gd
   reads `Input.is_action_pressed("sprint")` / `"cam_up"` /
   `"cam_down"` — not `"cam_sprint"` etc. The engine errors at
   runtime ("action sprint doesn't exist") if the names mismatch.

   **Gate**: codify the canonical action name list somewhere
   accessible — likely a static validator + a section in the
   `data/lib/input/universal.json` docstring listing all
   engine-expected action names.

3. **`camera_mode: "free_cam"` as the boot-time default produces
   blank frames.** Starting in iso/top_down/third_person works
   fine; toggling into free_cam mid-session works fine; but BOOTING
   directly in free_cam shows nothing (race in entity state load
   vs camera_director's first tick? mouse-capture transition?
   investigation needed).

   **Workaround**: compose_world starts in isometric_3d, user
   presses C to enter free_cam.

   **Investigation TBD**: identify why free_cam-at-boot fails.
   Likely the camera_director runs its handler BEFORE the
   free_camera entity's initial_instances state is fully applied,
   so `cam_ent.get_state("position", null)` returns null → cam_pos
   falls back to the TSCN-pinned Camera3D position, which is
   off-screen for the freshly-spawned town. Fix: defer free_cam
   activation until after the first full spawn pass, OR set the
   tscn Camera3D's default position to a sensible default ((0,
   60, 0)) so the fallback path also looks at the town.

### Open follow-ups (deferred, ranked by impact)

1. **Investigate free_cam-as-boot-default** (small, optional) —
   debug why starting in free_cam produces a blank frame. Once
   fixed, compose_world could default to free_cam directly so
   the user has full WASD/mouse control from frame 1 instead of
   having to press C.

2. **Stage 6 — asset gen per class with style anchor** (medium) —
   replace the unit primitives (prim_unit_box / cylinder / sphere)
   with actual generated .glb meshes per class, style-anchored to
   the stage-1 photoreal aerial. Plan covered in the earlier
   "Stage 6 DEFERRED" section above.

3. **Ground texture wiring via shader_params.biome_map** (small,
   high impact) — semantic map currently shows as the ground albedo
   but in a flat way. Route it through ADR 0055's 5-biome shader
   for proper biome variation + heightmap displacement combined.
   ~30 lines of compose_world tweak.

4. **Try the pipeline on a non-medieval scene end-to-end** (medium)
   — run a full text→world pass on a sci-fi colony or alien
   world brief, verify the pipeline really IS scene-agnostic at
   every stage (catalog adapts, semantic map renders, extraction
   handles different palettes, compose_world produces correct
   primitive scene).

5. **House clustering / extraction count drift** (small) —
   medieval town extraction got 216 houses vs 60 catalog-expected
   because the semantic map painted dense fine rectangles. Add
   `merge_within_meters` post-process at stage 5 to collapse
   adjacent same-class instances.

6. **Per-game .tscn naming convention** (already fixed in
   `50a6a87` but worth codifying) — the data folder uses
   `demo_<name>/` prefix; the .tscn / play.sh arg drops the
   prefix. Codify in a CLAUDE.md / data-demo.md note.

7. **--import automation** — after compose_world generates a new
   demo with new PNGs, the user must run `--headless --import`
   before launching or textures fail to load. Bake into the
   script (subprocess Godot --import call) so end-to-end runs
   are one command.

### Pipeline status after 2026-05-26

```
Stage 1 ✓ /yume-topdown-prompt + openai_images.generations
Stage 2 ✓ /yume-scene-class-catalog (dynamic per genre, 6-32 classes)
Stage 3 ✓ openai_images.edits (image-conditioned semantic map)
Stage 4 ✓ openai_images.edits (grayscale heightmap, terrain only)
Stage 5 ✓ /yume-extract-author + lib_extract.py
Stage 6 ⏸ DEFERRED — asset gen per class with style anchor
Stage 7 ✓ MINIMAL — compose_world.py + 3 unit primitives + iso/
              free_cam wired
```

Test scene `godot/data/demo_pipeline_v1/` runnable via
`./scripts/play.sh pipeline_v1`. Starts in isometric_3d showing
the 3D medieval town; C toggles free_cam; Tab cycles 3 anchors.

### Two more engine-convention surprises (added 2026-05-26 evening)

**4. Camera-mode toggling requires JSON RULES, not just input.**
The engine reads `world_clock.state.camera_mode` but doesn't
toggle it on input — that's per-game rules' job. compose_world's
initial output shipped with empty rules. C key fired the input
but nothing matched it, mode never changed.

Fixed in commit `9ba3db4`: compose_world now generates
`freecam_enter` + `freecam_exit` rules. Pattern mirrors
aldenmere's `world/rules/17_freecam_toggle.json` but generalized
(not hardcoded to fp/tp source modes).

**5. The engine query language does NOT support `_neq`.**
Supported operators: `_eq`, `_gt`, `_lt`, `_gte`, `_lte`,
`_has`, `_in`. Trying `camera_mode_neq: "free_cam"` silently
never matches — the rule loads, the query just always returns
false, the effect never fires.

Use `camera_mode_in: ["isometric_3d", "top_down_3d", ...]`
listing all allowed source modes. Future engine work could
add `_neq` as a first-class operator.

**Gate** (for both 4 and 5): a validator could detect rules
that use unsupported operators OR rules that depend on
state-changes (like camera_mode) without complementary
toggle/exit logic. yume-systems-designer skill should also
codify the canonical operator list.

### Free_cam rendering bug (separately deferred)

Even WITH the toggle rules working — and even with
`camera_mode = "free_cam"` set directly at boot — the camera
renders a solid dark-brown frame instead of the expected 3D
view. iso/top_down/third-person all work fine.

Possible causes (investigation needed):
- Camera position/rotation Euler math in
  `_camera_free_cam` produces an orientation that points away
  from the scene
- Mouse-capture transition fails in headless mode
- Active free_camera entity's state.position is being read but
  the result isn't being applied to Camera3D
- Sky/lighting setup in scene.json is too minimal for
  perspective rendering (works for iso ortho, fails for
  perspective)

Workaround: keep iso as the boot mode. The C-toggle rules are
in place; user can press C in-game (real keypresses may work
better than scripted capture-input). If free_cam blanks, press
C again to return to iso.

Investigation queued; not blocking the rest of the pipeline.

### Engine surprise #6 (2026-05-26 late night)

**Input routing requires an actor entity, even for "look at the
world" scenes.**

After fixing the toggle rules (#4) and the _neq operator (#5),
the C key STILL did nothing. Real cause: world.gd::_poll_input
→ InputRegistrar.poll(actor_id, ...) → actor_manager.
resolve_active_entity() returns "" when no entity is tagged
`player`. InputRegistrar.poll then EARLY-RETURNS on
`if actor_id == "":`. NO input actions ever get queued onto
the scheduler.

So input rules silently never fire when the scene has no
player.

Fix (commit `5c70f2c`): compose_world now emits a minimal
hidden `player_input_anchor` entity (tags: [player, actor,
persistent], visual.hidden: true, no physics, no movement
rules). Just an input target.

After this: C-key toggle WORKS — confirmed by capture showing
the camera_mode flip to free_cam (which then renders the
separately-deferred dark-brown blank bug). Pressing C again
fires the freecam_exit rule, restoring isometric_3d.

**Gate**: a static validator should warn when a generated
game has input rules + no entity tagged `player` (or
whatever the configured actor tag is). The combination is a
silent footgun for auto-gen pipelines.

Cumulative engine-convention surprises caught this session: 6.

### Engine surprise #7 — top-level `position` clobbers state.position

Resolved 2026-05-26 with full post-mortem + 3 gates (commit 44311de):
- Static validator `tools/validators/validate_position_consistency.py`
- Engine push_warning in `entity.gd::_apply_overrides`
- Docs section at top of `.claude/rules/data-demo.md`

Empirical case: free_camera entities in compose_world were silently
spawning at world origin instead of their camera-pose state.position
because the top-level `position: [0, 0, 0]` field overwrites
state.position regardless of dict order in JSON. Aldenmere's
convention is to set BOTH fields to the same value.

The user's framing question "this is just same as aldenmere right?"
was decisive — every wrong theory I chased (rules, _neq operator,
input routing, lighting) was actually "I'm not matching aldenmere's
exact convention." Lesson worth keeping: when an auto-gen pipeline
produces something that should work like a known-good demo, DIFF
the JSON field-by-field against the working demo BEFORE iterating
on engine theories.

Cumulative engine-convention surprises this two-day arc: 7.

### Deferred follow-ups added in this iteration

1. **world/state.json drop-test** (small, low priority) —
   compose_world currently emits a comment-only placeholder
   matching aldenmere's pattern. Test whether
   `world_loader::load_world_file` actually no-ops when the
   file is missing. If yes, compose_world could drop the
   placeholder entirely (one less file to scaffold). If no,
   the file IS required and the placeholder is correct.
   Revisit when convenient; not a blocker.

2. **File-layout consistency now matches aldenmere** (done,
   commit 44311de): world/rules/<NN>_*.json directory pattern
   instead of single world/rules.json; no per-level rules.json
   placeholder. Validates the established convention from
   aldenmere's 17-rule split.

---

## Stage 5 v2 — class-semantic extraction (started 2026-05-26)

User insight: each class has a CANONICAL POSE + CONTEXT-RELATIVE
ROTATION RULE. "House in canonical space is front-facing cube,
rotate face against road path." Stage 5 needs class-semantic
awareness, not just blob detection. AND Yume principle:
everything reusable — no new engine primitives, all polygons
decompose to rotated/scaled prim_unit_box / cylinder / sphere.

### Architecture

Strategy library at `data/lib/extraction_strategies.json` —
keyed by class name. Fixed vocabulary (the only engine-level
surface):

- 6 extraction_methods: single_instance / cluster_extract /
  snap_to_anchor / scatter_in_mask / polygon_decompose /
  llm_gestalt
- 6 rotation_rules: no_rotation / face_nearest_road / face_anchor
  / along_tangent / perpendicular_to_water / random_seeded
- 4 y_anchors: heightmap_sample / water_level / anchor_floor /
  constant
- 3 primitives: prim_unit_box / prim_unit_cylinder / prim_unit_sphere

New class = JSON entry pointing at existing strategy methods.
New strategy method = engine ADR (rare).

### Pipeline

```
5a CV pass (deterministic):
  - terrain biome masks (existing)
  - structural polygons: wall_ring, road_mask, water_polygon, focal_anchor
5b strategy dispatch (per class):
  - per extraction_method
  - per rotation_rule (CV-side road extraction; radial heuristic first,
    Zhang-Suen skeleton fallback for non-radial)
5c heightmap-aware Y (phase E):
  - sample heightmap.png at instance (x,z), set position.y
5d polygon decompose for walls (phase F):
  - contour → Ramer-Douglas-Peucker → series of rotated unit_boxes
5e LLM-gestalt for dense classes (e.g. house):
  - single OpenAI vision call, returns instances with gestalt grouping
5f validation pass:
  - count vs expected, spatial plausibility, anomaly flags
```

### Tasks

Tracked in TaskCreate list:
- #132 Wire heightmap through shader_params.heightmap
- #133 Entity Y-anchor from heightmap sample (E)
- #134 Strategy library schema
- #135 yume-scene-class-catalog learns strategy assignment
- #136 lib_extract v2 — dispatcher + structural polygons
- #137 F — polygon_decompose for walls
- #138 LLM-gestalt single OpenAI call
- #139 Validation pass

Locked design decisions:
- Strategy library in `data/lib/`, shared by class name ✓
- Single LLM call for all object_placement classes ✓
- CV for road extraction (LLM not reliable yet) ✓
- Polygons → rotated/scaled prim_unit_box (no new engine primitive,
  Yume reuse principle) ✓

## Kit-of-parts procedural variants (long-term, 2026-05-26)

Origin: user-stated vision after Option-A variant_buckets shipped
(commit 08482eb). For visual variety without per-tile Tripo3D
spending, generate a SMALL set of base PARTS once, then compose
each variant procedurally at runtime.

Today's variant_buckets pattern is the stepping stone: each bucket
(small_house / medium_house / large_house) has ONE entity def with
ONE primitive-box mesh + albedo. The bucket CONTRACT (def name,
canonical_size, albedo) is stable across the kit upgrade — only
the visual backing changes.

### Roadmap

1. **Base part catalog** in `data/lib/meshes.json`:
   - `wall_panel` (1m × 3m × 0.3m exterior)
   - `gable_roof` (triangular profile, 4m × 2m)
   - `hip_roof` (pyramidal, 4m × 4m)
   - `door_v1`, `door_v2` (timber, stone)
   - `window_v1`, `window_v2` (shuttered, leaded)
   - `chimney`, `balcony`, `porch`
   Tripo3D cost: 1 call per part = ~10-15 total for any genre.

2. **Composite-mesh recipe schema** (extension of meshes.json
   support for composite definitions):
   ```json
   {
     "id": "small_house_mesh",
     "compose": [
       {"part": "wall_panel", "count": 4, "arrangement": "box_perimeter"},
       {"part": "gable_roof", "rotate_y_deg": 0,    "y_offset": 2.0},
       {"part": "door_v1",    "wall_index": 0, "x_offset": 0.0},
       {"part": "window_v1",  "wall_index": 1, "count": 2}
     ]
   }
   ```
   Engine composes the primitive children at spawn time (similar
   to existing meshes.json composite path).

3. **Bucket → recipe mapping** in `extraction_strategies.json`:
   ```json
   "variant_buckets": [
     {"def": "small_house",
      "max_area_px": 1500,
      "canonical_size_meters": [2.4, 3.0, 2.4],
      "mesh_recipe": "small_house_mesh"},  // ← new field
     ...
   ]
   ```
   When `mesh_recipe` is present, compose_world writes
   `visual.mesh = <recipe id>` instead of `prim_unit_box`.

4. **Stochastic recipe variants per bucket** (later): each bucket
   can have N recipes; per-instance hash picks one. Gives true
   variety from the same kit:
   - `small_house_mesh_a` = gable roof + 1 chimney
   - `small_house_mesh_b` = hip roof + porch
   - `small_house_mesh_c` = gable + balcony + 2 chimneys
   Tripo3D cost stays at the 10-15 base parts; variants come from
   composition.

### Generalization

Applies to ANY object_placement class with multiple visually-
distinct instances:
- tower → base_part: round_tower_section, conical_roof, crenellation
- bridge → base_part: arch_span, railing, support_pillar
- wall_segment (already canonical) → could gain crenellation parts,
  banner parts, watch_step parts as compositions

### Engine support needed

- `meshes.json` composite recipes (mostly exists per ADR 0046
  composite-mesh path; needs param-driven count + arrangement
  primitives like "box_perimeter")
- compose_world.py: when bucket carries `mesh_recipe`, emit
  `visual.mesh = <recipe id>` (NOT prim_unit_box) — one-line change
- yume-asset-designer skill: extends to author recipe variants per
  bucket from the same base-part library

### Tasks (deferred, ranked)

1. ADR: composite-mesh recipe schema extension (count + arrangement
   primitives). Tier 2.9.
2. Base-part catalog content: author the first 10 parts for a
   medieval theme (gen via Tripo3D, ledger them).
3. Bucket.mesh_recipe field plumbed through compose_world.
4. Stochastic per-instance recipe picker (hash-deterministic).
5. yume-asset-designer skill recipe-authoring section.

### Why this matters

The variant_buckets pattern locks in TODAY without a single Tripo3D
call (primitive boxes only). When the kit lands, the entities.json
output doesn't change — only the entity def's visual.mesh field.
Every existing demo upgrades to the kit by re-authoring the def's
mesh, not the level's instances. That's the Yume reuse principle
applied to art: instances are data; meshes are reusable parts;
parts are the only thing AI-generated.


## Pipeline layering: static / dynamic / presentation (2026-05-27)

The text-to-world output is generated in three CLEANLY SEPARATED
layers. This is the framework's guiding model — keep them apart so
adding gameplay never touches the map, and re-skinning never touches
gameplay.

| Layer | What | Lifetime | Producer |
|---|---|---|---|
| **Static** | map geometry — buildings, walls, towers, bridges, fountain, terrain (biomes/water/roads) | placed at level load, never mutated | `compose_world.py` |
| **Dynamic** | player, NPCs, random/ambient props, mission objects | created/destroyed at RUNTIME | `spawn` / `despawn` rules (engine primitive) + the player instance |
| **Presentation** | camera, input, lighting, .tscn | the wrapper; not content | `compose_shell.py` |

Key points:

- **The dynamic layer needs NO new engine code.** Yume already
  spawns runtime entities generically via the `spawn` effect keyed
  on tick (random/ambient), signal (mission/event), or zone
  (area) triggers, and removes them via `despawn`. A game adds
  dynamic content by adding spawn rules — the static map is
  untouched.

- **Static = level `initial_instances`.** Whatever a game places at
  load that never moves/despawns. The map generator owns only this.

- **Don't bake game-specific entities into the map generator.** The
  compose_world (static) / compose_shell (presentation) split already
  enforces this. A future `compose_dynamic` (player + spawn-point
  markers + spawn rules) can split the player out of the shell when a
  real game needs dynamic content — NOT before (avoid churn).

- **Loose coupling by tag.** The presentation camera references the
  player via `follow_tag: "player"`; it doesn't care which layer
  spawned it. Spawn rules reference spawn-point markers by tag. No
  layer hard-codes another's entity ids.

Current state (2026-05-27): we are still validating MAP GENERATION
(the static layer). The player lives in the presentation shell for
now (it's the only dynamic entity and it works); it moves to a
dedicated dynamic layer only when a game introduces real dynamic
content (NPCs/missions/spawns). Until then: no speculative dynamic
code.

## Text-to-world 3D pipeline — state + asset-resolution tiers (2026-05-27)

The 3D map/world pipeline (compose_world + compose_shell, distinct from
the GDScript-game /yume-design pipeline) is now end-to-end for the
deterministic half + tier-2 assets. Session landed:

- Extraction + kits: floor-tiered houses, townhall/bridge/wall, bird-
  totem/ruin/tree/fountain kits; fit-to-mask; generalize-tested on a
  fantasy totem-hills scene (new classes = pure JSON).
- compose_world (map) / compose_shell (presentation) split; per-scene
  `scene_config.json` (dataclasses); `lib_extract_dispatch` rename.
- Engine fixes (all gated): free-cam toggle, HeightMapShape3D collider
  (player no longer floats on displaced terrain), duplicate-def guard.
- Cinematic defaults + painterly grass (slope/height shading + SSAO +
  flower specks + detail texture + wind; blades opt-in toggle).
- Asset-gen tier 2: Tripo3D `.glb` via concept image, AND engine
  **auto-normalize** of static `.glb` (unit-height, base-on-ground) so
  AI meshes drop into the fitted placement with no per-def tuning.

### Asset-resolution tiers (the target workflow)
text → hero ref → orthographic → semantic+heightmap → extract →
**resolve each class to an asset by complexity** → place → aesthetic →
visual-qa.

| Tier | Mechanism | Status |
|---|---|---|
| 0 reuse kit | look up existing `meshes.json` kit | kits exist; **no auto "do we have one?" check** |
| 1 procedural/code | param-driven kit-of-parts | exists; **randomized geometry + procedural PBR (Blender-node) = future** |
| 2 Tripo via concept image | bg-stripped concept → image_to_model → auto-normalized | **done** |

### Next (in progress)
- **(1) `asset_source` tier policy** — each class declares kit /
  procedural / tripo (in strategy or catalog); compose_world resolves
  accordingly instead of the implicit `strategy.mesh` vs `mesh_prompt`.
- **(2) kit-reuse check** — before queuing a tripo gen, check the kit
  registry (meshes.json keys) for a fitting kit; reuse if present.
- (later) procedural materials; a single `compose_scene` orchestrator
  chaining gen → compose_world → compose_shell.

## DEFERRED (2026-05-27): procedural-material asset tier (tier-1 "stone + PBR")

The asset-resolution vision's **simple → procedural/code + PBR** tier (a
Blender-node-style generator that makes e.g. random stones WITH procedural
PBR materials) is **deferred** — it's a separate, ADR-worthy subsystem
(procedural geometry + procedural material graphs), not needed until a
scene actually calls for it. User decision: don't build speculatively;
revisit when a real scene needs cheap procedural props.

The other two tiers cover current needs:
- tier 0/1 → existing kit-of-parts (code-composite meshes), `asset_source: kit`
- tier 2 → Tripo via hero-conditioned concept → image_to_model, `asset_source: tripo`

Still open (NOT deferred, just not yet built): package the front half
(hero→ortho→semantic→heightmap) into a tool/skill; real Tripo-PARTS kits
(vs debug primitives); a systematic composition/aesthetic pass; a single
compose_scene orchestrator; visual-qa wired into the loop.

## BUILT (2026-05-27): one-button orchestrator + /yume-create-scene skill

The "no one-button pipeline" gap is closed:
- `tools/visual_layout/compose_scene.py` — from catalog + prose, builds the
  4 image prompts (hero / hero-conditioned ortho / ortho-conditioned
  semantic / heightmap), generates them via openai (idempotent), then
  chains compose_world → compose_shell (+ optional --assets) by subprocess.
- `.claude/skills/yume-create-scene/SKILL.md` — the skill: author catalog
  (the one LLM step) → run compose_scene → visual-qa loop.

Remaining "make it perfect" items (from the asset-resolution vision):
- real Tripo-PARTS kits (vs debug primitives) — combine generated part
  meshes procedurally + visual-qa the combination.
- systematic composition/aesthetic pass (focal point, paths, fg/mg/bg).
- visual-qa wired INTO the orchestrator loop (currently manual).
- (deferred) procedural-material tier.

## Ground: single-biome opt-out (2026-05-28)

User reaction to the multi-biome splatmap on the stylized totem_hills
scene: "dont use that splatmap, i dont like, it is very ugly." The
dirt-path biome painted ugly brown lines on the grass. Decision (user
picked): clean uniform grass ground, KEEP the water (water is a
separate ADR-0059 plane, not the splatmap).

Added `scene_config.terrain.single_biome` (default false). When true,
compose_world `_build_biome_arrays` keeps ONLY the dominant grass biome
(biome_count=1 → uniform grass + the painterly slope-shading/detail/
flowers); the dirt_path / region splatmap painting is dropped. The
water plane keys on the catalog `water*` class independently, so it
survives. demo_totem_hills now sets `single_biome: true`. Town-style
scenes (cobblestone/dirt districts) keep multi-biome by leaving it
false. NOT a bug → no post-mortem gate (the splatmap worked as
designed; this is an aesthetic per-scene choice). Verified: overview
capture shows clean grass everywhere + blue water pools, no paths.

## Hero-fidelity pass: ortho re-prompt + ortho-as-ground-albedo (2026-05-28)

After the single-biome fix the user judged the scene "nothing similar
to the hero reference" and asked: was the hero→ortho stage losing the
hero's richness? Side-by-side compare showed the ortho was actually
faithful (painterly grass, rocks, river) — the richness was being
DISCARDED downstream: semantic → flat-color classification → primitive
gray meshes + flat green ground + harsh lighting.

Done in two phases.

### Phase 1 — hero→ortho prompt tuning

`compose_scene._ortho_prompt` was actively flattening hero atmosphere
("minimal shadows / uniform illumination / flattened tops / clean
readable map" — all anti-hero). Rewrote to "PRESERVE the painterly
art direction, palette, warm sunlight, cast shadows, atmospheric
depth" + "the attached image IS the visual contract; only the camera
angle changes" + "one DOMINANT hero focal-anchor structure" +
"painterly grass tonal variation, mossy rock clusters, dirt path
brushwork, water reflections." Catalog `composition_notes` upgraded
to encode the focal-anchor principle (ONE colossal central totem +
5 peripheral) and `heightmap_hints.low_regions` got an explicit
"streams MUST carve VISIBLE channels — these pixels are the darkest
in the whole image" instruction.

Result: regenned ortho + semantic + heightmap (3 paid OpenAI gens).
The new ortho has cast shadows, one dominant hero totem (bird shape
actually readable from the near-iso angle), 5 peripheral totems,
warm sunlight, painterly grass. The new heightmap has VISIBLE DARK
CHANNELS — the streams now sink into proper riverbeds.

### Phase 2 — render-side improvements

Four changes:

**2.1 Ortho as ground albedo.** New `ground_ortho_displace.gdshader`
samples the orthographic painting itself as the ground albedo (planar
UV, sRGB→linear via `source_color` hint). Heightmap displacement
preserved. `albedo_attenuate=0.55` uniform compensates for the baked
GI in the ortho (otherwise engine lighting double-brightens to washed
yellow). Selected via new `scene_config.terrain.albedo_image` field
in TerrainConfig; compose_world emits the alternate shader + params
when set. Replaces multi-biome classification with literally painting
the hero's brushwork onto the floor — biggest single visual lever.

**2.2 Rocks class.** The hero shows mossy rock clusters EVERYWHERE,
but the catalog never had a rock class so none extracted. Added:
new `rock_cluster_kit` mesh (4-sphere boulder pile, mesh-unit space,
per-instance scale jitter); `rock` strategy in extraction_strategies
(`scatter_in_mask` with own-mask fallback, `asset_source: kit`,
canonical 1.4×0.9×1.4m, scale 0.6-1.6); aliases for `stone` /
`boulder` / `mossy_rock`; `rock` class added to catalog (#888080,
expected_count=35). One paid semantic regen (catalog → semantic
needed the new class hex). 41 rock instances extracted across the
scene.

**2.3 Lighting tune** (per-scene `scene_config.lighting` override).
The ortho carries its own warm GI + saturated colors, so the global
defaults (aerial_perspective 0.8, saturation 1.34, contrast 1.18,
fog density 0.0075) over-amplified everything to a washout from any
distant angle. Per-scene override pulls back to aerial_perspective
0.4, density 0.005, saturation 1.15, contrast 1.08 — the hero
painting reads through cleanly.

**2.4 Carved riverbeds** (came free from phase 1's heightmap regen).
Water plane now sits IN the river channels instead of floating on
grass. `derive_water_level` produced -1.314m → -1.627m as the
heightmap got deeper channels.

### Open gaps to fully match hero

- **Trees still primitive cones.** 49 instances; Tripo `.glb` is a
  perf wall at that count until the MultiMesh-for-`.glb` engine
  feature lands.
- **Grass slightly muted** vs the hero's lush version (the
  `albedo_attenuate` brightness-trade-off).
- **Lighting could go more dramatic** if a more cinematic look is
  desired (more contrast, warmer sun).

### Files / framework deltas

- NEW `godot/data/lib/shaders/ground_ortho_displace.gdshader`
- `godot/data/lib/extraction_strategies.json` — added `rock` strategy + 3 aliases
- `godot/data/meshes.json` — added `rock_cluster_kit` (4-sphere)
- `tools/visual_layout/scene_config.py` — added `terrain.albedo_image`
  field (plus the single_biome from prior turn)
- `tools/visual_layout/compose_world.py` — threaded `albedo_image` →
  alternate shader emission
- `tools/visual_layout/compose_scene.py` — re-prompted `_ortho_prompt`

Yume-principle note: the ortho-albedo path is OPT-IN per scene
(albedo_image config). Town/dungeon scenes that want multi-biome
splatmap or single-grass biome are unaffected. The new shader is a
sibling to the biome shader, not a replacement.

## Pipeline polish: versioning + FPS + dynamic prompts + path carving (2026-05-28)

Several quality-of-life and correctness wins on the text-to-world
pipeline.

### Auto-versioning of paid artifacts

User flagged: "the original reference is being replaced" — the
canonical files were getting overwritten on each gen even though
prior snapshots were stashed in `_snapshots/`. Fixed in
`compose_scene._gen`: before each new gen, the existing canonical
content is content-hashed; if no `_vN` sibling already represents
it, archive canonical → next available `_vN` slot. Then gen → next
`_vN` (different slot), mirror to canonical. Paid artifacts now
live side-by-side as `<stem>_v1.png`, `_v2.png`, ... in the same
dir. Downstream tools unchanged (they keep reading the canonical
name). Historical iterations of orthographic / semantic_map /
heightmap restored to `_vN` siblings.

### FPS mode (per-scene camera config)

`scene_config.player.camera_mode` (default "third_person_3d");
compose_shell threads it into world_clock's `state_init`. Other
modes (first_person_3d, isometric_3d, top_down_3d) are already
supported by the engine; this just exposes the knob.

### Dynamic ground-paint prompt

`_ground_paint_prompt` was hardcoded to mention "totem, ruin, tree,
rock" — specific to one scene. Now reads `catalog.classes` filtered
by `intent_type`: REMOVE = object_placement, KEEP =
terrain_shader. Works for ANY scene's class list. A town scene's
prompt would say "remove house/wall/tower/fountain, keep
cobblestone/grass/water"; an alien scene gets its own list.

### Deterministic path carving

User wanted dirt paths to be slightly depressed in the heightmap
("worn footpath ruts"). Tried LLM-driven (catalog hint
"footpaths SLIGHTLY depressed") — produced subtle but unreliable
depressions that depended on LLM mood. Switched to deterministic
post-process: `carve_paths_into_heightmap` reads the semantic
map's path-class pixels, soft-matches each by hex with RGB
distance, Gaussian-blurs the combined mask, subtracts a
configurable depth (default ~0.25m). Writes
`<textures>/heightmap_carved.png`; downstream (shader_params,
water_level derivation, sample_y) uses this carved version. The
raw LLM heightmap stays in place.

Pipeline pattern this codifies: **LLM for hero-style terrain shape
+ deterministic post-process for layout-precise carving**. No drift
between heightmap path positions and semantic path positions (the
3D extraction's source of truth). Generalizes to other class-driven
modifications (e.g., add `carve_*` for "objects sink slightly into
soil", "stairs cut steps", etc.).

### Splatmap skip in ortho-albedo mode

`compose_world` no longer writes `terrain_splatmap.png` when the
scene is in ortho-albedo mode — the file is unused and was just
sitting on disk.

### Tree + rock → Tripo hero-conditioned

Both class strategies upgraded from `asset_source: kit` to
`asset_source: tripo` with `mesh_reference_prompt` (for the
hero-conditioned concept) + `mesh_prompt` (for image_to_model).
Single Tripo `.glb` per class, shared across all instances via
Godot 4 Forward+ auto-instancing — the "perf wall at 49 instances"
concern didn't materialize (steady ~48-54 FPS).

### Open papercuts (not blockers)

- `compose_world` resets Tripo `.glb` paths to kit fallback every
  run; need to call `yume_assetgen` (or `compose_scene --assets`)
  after every recompose to re-patch. Should probably default
  `--assets` on or add a "re-patch only" mode.
- `/tmp/_fantasy_catalog.json` lives in /tmp; should probably
  graduate to `godot/data/<game>/catalog.json` as the canonical
  per-game recipe.

## Water system — DEFERRED (2026-05-28)

Took a long detour iterating on water visual quality. Landed real
framework gains then user called time on further water polish.

What landed (preserved in framework):
- **Deterministic water-mask carving** in `carve_paths_into_heightmap`:
  the heightmap is post-processed to dig a soft trench under the
  semantic water_mask region. Combined with the existing path-carving
  pass it ensures all terrain inside the mask sits below water_level —
  water plane no longer "floats" above unflattened terrain.
- **Box-mesh water volume** (replaces flat PlaneMesh). compose_world
  emits `water.mesh.box_depth`; engine `ground_renderer.build_water`
  creates a `BoxMesh` (top face at water_level, bottom buried below
  the deepest carve). Older demos without `box_depth` keep the legacy
  flat plane.
- **FRONT_FACING underwater split** in the shader. With
  `render_mode cull_disabled`, the box's interior faces render when
  the camera descends below water_level. Inside the shader,
  `if (FRONT_FACING)` runs the surface look (foam, ripples, refraction);
  `else` runs an underwater look (deep_color via EMISSION so PBR
  lighting doesn't wash it). **The underwater effect comes for free
  from being inside the box** — no overlay, no post-process needed.
- **FastNoiseLite normal-map texture** (`godot/data/lib/textures/
  water_normal.tres`): NoiseTexture2D resource with 5 fractal
  octaves, seamless, as_normal_map, bump_strength 8.0. Same setup
  as the YouTube stylized-water tutorial. Shader samples it at two
  scales scrolled in different directions → no visible tiling.
- Refraction `0.012 → 0.05` + depth_fade `1.0 → 0.45` for stronger
  3D look (you see refracted scene more through the water; depth
  gradient is more pronounced).
- gitignore now allows `*.tres` under `lib/textures/` (source-
  controlled Godot resources, not generated binaries).

Bug-gates discovered (would-be-good-to-add):
- Godot 4 fragment shaders cannot use `return;` — must restructure
  via `if/else` at the bottom. (Worth a Yume rule entry.)
- `entity.position_clobber`: top-level `position` always wins over
  `state.position`. Already documented in `data-demo.md`; the
  warning fired during this work confirms the gate is doing its
  job (just easy to ignore in iteration).

Open items for when water comes back:
- The water surface still doesn't look fully painterly-cinematic
  (it reads as "Godot-tutorial stylized" not "hero painting").
  Would need a hand-painted normal texture or a more aggressive
  stylized shader (cel-shaded crests, painted highlights).
- Walking into water still bisects the player view at the moment
  their head crosses water_level. The FRONT_FACING branch hides
  this AFTER they're submerged; the transition itself is abrupt.
  Could add a smooth "wading" / partial-submerge effect later.
- Water region in totem_hills is a winding river — the box-mesh
  approach is over-broad (we have a big box clipped to a thin
  river). A pond/lake scene would fit a box more naturally.

## Camera intrinsics — TODO (2026-05-28)

User wants two extensions to scene.json camera control. Both are
small engine changes in `camera_director._apply_ortho`.

1. **Projection-mode override**: today the projection (perspective
   vs orthographic) is hardcoded per camera_mode — FPS / TP /
   free_cam always perspective; iso / top_down always orthographic.
   Add an optional `projection: "perspective" | "orthographic"`
   field in cam_cfg that `_apply_ortho` honors when set, with the
   mode default as fallback. Enables e.g. orthographic FPS for a
   stylized-art-direction scene, or perspective top-down for a
   cinematic.

2. **Clip planes + focal-length-in-mm**: expose
   `clip_near` / `clip_far` (default 0.05 / 4000) and an optional
   `focal_length_mm` (converted to FOV via `fov = 2*atan(36/
   (2*focal_mm))` using a 36mm sensor assumption). Authors can
   then write film-camera-language in cam_cfg.

Scope: ~20 lines in `_apply_ortho`, plus lib camera preset docs.
No new validators needed (fields default to current behavior).

Defer until tiny_village tuning is done.

## Session 2026-06-08 — bug sweep on dev branch (5 commits)

Worked the fixable-bug queue from the backlog; all on branch `dev` (not
master, not pushed). Done items deleted from backlog.md per the
delete-when-shipped rule; full detail in the commit messages.

- **compose_world .glb re-resolution** (`a1ddac0`). compose_world's
  wholesale rewrite of `auto_gen.json` re-emitted tripo classes with the
  kit FALLBACK mesh + mesh_prompt, wiping assetgen's resolved `res://…glb`
  paths (silent revert to fallback meshes). Fix: compose_world chains an
  idempotent, key-free `run_pipeline(patch_only=True)` after writing defs
  (asks the Assets layer to re-resolve; stays a pure function of inputs).
  Gate: `validate_mesh_paths_resolved.py` (tripo def + generated .glb on
  disk + visual.mesh not a .glb → fail). New assetgen `--patch-only` flag.
- **pytest collection fix** (`fcc1b04`). `tools/yume_assetgen/tests/`
  test_smoke.py + test_glb_merge.py are script-style (own main(), _check+
  return, stateful) — pytest mis-collected them (12 errors + 2 false
  greens). Added `conftest.py` collect_ignore; the canonical
  `python3 -m …` runners stay green. `pytest tools/` now clean (15 real
  tests pass).
- **scatter expected_count cap + overflow gate** (`6bde593`).
  `lib_extract_dispatch._extract_scatter` sized purely by density×area,
  ignoring catalog expected_count → lanterns shipped 1510 instances
  (1220 rocks + 239 trees) for a ~30 catalog; ~11 FPS. Fix: cap target_n
  at expected_count × SCATTER_SPREAD_FACTOR (1.5). Gate: lib_extract_
  validate "overflow" verdict (actual > expected × 3) → compose_world
  hard-fails. Trimmed shipped lanterns 1510→141 (farthest-point sampling);
  FPS recovered 11→37. 5 regression tests.
- **shell jump/gravity generation knob** (`1d9ca80`). compose_shell
  hardcoded jump impulse 7.0 / gravity 18.0. Added scene_config `shell`
  block (ShellConfig dataclass); defaults unchanged so existing scaffolds
  emit identical JSON. 4 tests + skill doc.
- **aldenmere determinism — verified already fixed** (`656df77`). The
  parked nondeterminism bug was resolved by the per-pattern seeded RNG in
  instance_patterns.gd (with the order-independence regression test at
  test_runner.gd:2026). Oracle re-run confirmed: DETERMINISTIC, 3×
  identical 652-tick hashes. Backlog item closed.
- **jump bug resolved** (`fd07555`). "y_velocity never reaches integrator"
  was a capture-harness artifact, not a real race — jump works in live
  play (user-confirmed). Now also config-driven (see shell knob above).
- Also: deleted parked `open-source-v0.1.md` (OSS v0.1 released).
