# Yume — Autonomous Agent Simulation Engine

_Last updated: 2026-04-19_

---

## Motivation

Most "living worlds" in games are scripted performances. Agents repeat canned
routines, state resets between sessions, and the world doesn't really change.
We want a sim where **things actually live**: hunger decays, crops grow, wood
rots, fires burn out, agents die if unattended, the world keeps moving when
no one is watching.

Two reasons that matters:

1. **Something to simulate, not just render.** Indie sims usually pick
   mechanics (farming, crafting, combat) and wire them together. We want a
   substrate where mechanics emerge from a small set of primitives (needs,
   rules, entities with state) so new behaviors can be added in JSON instead
   of code.
2. **Long-horizon agent behavior is interesting on its own.** Once the
   world is believable, swapping in smarter brains (needs-driven → LLM →
   VLM-with-eyes) becomes a real test of agent capability, not a puppet show.

The eventual training-data / world-model research angle is downstream of this.
It is **not** the current objective. Foundation first.

---

## North Star

> A 3D world where agents — driven by needs, rules, or LLMs — live
> indefinitely without hand-holding. Every object has state. Every behavior
> is data-driven. Adding a new entity, need, rule, or goal is a JSON edit,
> not a code change.

Success smell test: _run the sim for 30+ minutes, walk away, come back, and
something has genuinely changed — a house got built, an agent died, a forest
got chopped, a new seed sprouted. The world was busy while you were gone._

---

## Conceptual Ladder (where we are)

From the original emergent-world vision (`docs/21_emergent_world_vision.md`,
now folded into this plan):

| Level | What it is | Status |
|---|---|---|
| **L1 — Fixed world** | Designer places every room, prop, enemy. | ✅ done (FF9 2D track) |
| **L2 — Procedural world** | Generators + state-machine NPCs. Diverse environments. | ✅ done (dungeon labs) |
| **L3 — Elemental rules + agent needs** | Define materials, tools, recipes, needs. Agents _discover_ farming, building, cooperation. Causal chains. | 🟡 mid — substrate done, driver pending |
| **L4 — Full simulation** | Physics, biology, social rules, reproduction. Agents create language, culture, economy. | ❌ long-term |

We are inside **L3**. Substrate (elements, properties, rules, needs, brains)
is built. What's missing for L3 to "feel alive" is multi-agent dynamics
(trade, cooperation, conflict), persistent agent memory (discovered recipes),
and a driver that creates arc (Tier 2 below).

---

## Current Objective (2026-04-19)

**Tier 1 is done.** The sim self-sustains. But user observation stands:
_"feels empty — what am I simulating?"_ Homeostasis alone has no arc.

**Next objective: give the sim a driver.** Pick one direction from the game
goal discussion (`docs/27_game_goal_discussion.md`) and ship the _feeling_,
not just the mechanic. The leading candidate — from the recent discussion —
is **multi-agent cooperation + per-agent cameras + VLM observation**, which
combines drama (agents doing things together), observability (you can see
through their eyes), and sets up the long-horizon capability ladder.

See "Tier 2 — Driver & Depth" below.

---

## What's Done

### Simulation foundation (Tier 1 ✅)

| Layer | State |
|---|---|
| **3D engine orchestrator** | `sim_world.gd` (135 lines). Delegates to `WorldEnvironment` / `WorldTerrain` / `WorldElements` / `WorldAgents` / `WorldRulesEngine` / `ModelHelpers`. |
| **Tick clock** | `world_clock.gd`, 0.5s default. Drives brains + rules. Movement stays continuous between ticks. |
| **Rules engine** | `world_rules_engine.gd`. Global rules + per-entity rules. Effects: `need_decay`, `need_restore`, `damage`, `remove`, `transform`, `advance_stage`, `spread`, `state_add`, `state_set`. Conditions: `need_below`, `nearby_element`, `agent_near_group`, `neighbor_group`, `state_below`, `state_above`. |
| **Brain abstraction** | 5 working brains: `human`, `auto_agent`, `state_machine`, `needs_driven`, `llm` (claude -p via WSL bridge). Swappable per-agent. |
| **Entity model** | Every object (agent, wheat seed, campfire, water) carries `meta.state`. Rules engine treats agents and elements uniformly. |
| **Composites** | Multi-part buildings (`house_small`, `fountain_plaza`, `windmill`) built from Kenney GLB parts via JSON `parts[]` with per-part tint + rotation. |
| **Data-driven config** | `elements.json`, `needs.json`, `recipes.json`, `world_rules.json`, `asset_config.json`, `meta.json`. Per-entity `state`, `rules`, `groups`, `satisfiers`, `drops`, `size`, `ground_mode`, `physics`. |
| **Target claim system** | `meta.claimed_by` prevents multiple agents piling on the same wheat / tree / water source. |
| **Animation pipeline** | Kenney rigs → `AnimationLibrary`. Documented in lessons. |
| **Population manager** | `population_manager.gd` respawns dying agents every 10s if below initial count. |
| **Ground placement** | `ground_mode` (center / min / max / avg) samples terrain under the footprint. Composites default to `min` so buildings don't float on slopes. |
| **Physics opt-in** | `"physics": static / dynamic / kinematic` per entity. Most things static; only opt in where needed. |
| **HUD** | Reusable `agent_needs_panel` auto-creates per agent. Manager composes; no hardcoded per-agent wiring. |
| **Entity lifecycles** | Water evaporates/rains, wheat seeds grow, wheat ripens + rots, campfires burn fuel. All in JSON per-entity rules. |
| **Farming loop (closed)** | Agents harvest wheat → collect seed drop → plant near water → seed grows → regrown wheat harvested. 90s soak: 0 deaths, 28 wheat maturations. |
| **Bootstrap fix** | Punch action (no-tool harvest, slow, 1 drop) so agents can't get stuck when missing a tool. |
| **Rain self-regulates** | Conditional on `state_below amount: 70` — water no longer net-drains. |

### Validated labs

- `data/sim/` — 100×100 real village, 3 named AI agents (Iris / Bjorn / Elara), 7 zones, 788 elements
- `labs/house/` — composite pipeline
- `labs/agent/` — multi-agent
- `labs/craft/` — crafting chain (mine → craft → chop)
- `labs/llm/` — claude-driven agent, full survival loop

### Lessons corpus

`~/.yume/lessons/rpg/` — 170+ YAML lessons (assets, architecture, workflow,
combat, dialogue, kenney pivots, godot rotation convention, VQA bias,
data-first-gd-second, …). Loaded via lookup when debugging.

---

## What's Observed But Not Fixed

- Food scarcity at low agent counts — 4 wheat can't sustain 3 agents for long without farming kicking in early.
- Rain/evaporation balance is stable but slow — drought recovery takes minutes.
- Pathfinding is straight-line in the sim (A* exists in `pathfinding_astar.gd` but isn't wired to sim agents).
- LLM brain is synchronous — blocks the tick while `claude -p` runs.

---

## What's Not Done

Grid system, A* in sim, async LLM, per-agent vision (SubViewport + Camera3D
attached to entities), farming tuned for scale, multi-step planning, combat
in sim, day/night behavior driving decisions, save/load, data export,
multi-agent cooperation, host/client multiplayer.

---

## Roadmap

### Tier 2 — DRIVER & DEPTH (current focus)

Goal: break the "empty" feeling. Give agents a reason to do things, and
give the observer something to watch.

**Game goal direction** — pick one from `docs/27_game_goal_discussion.md`:

- [ ] **2.0** Pick and ship a driver. Leading candidate (from recent
  discussion): **multi-agent cooperation + per-agent cameras + VLM feed**.
  Alternatives: (a) survive the night (lowest effort, highest drama),
  (b) build a village, (c) tech tree, (d) agent individuality.

**Multi-agent + per-agent observation (the direction user likes)**

- [ ] **2.1** Per-agent `SubViewport` + `Camera3D` attached to entity head.
  Eye-level view, capturable to disk or into a VLM prompt. Pattern similar
  to ViZDoom's multi-buffer observation.
- [ ] **2.2** Labels buffer (ViZDoom pattern): render mask tagging nearby
  entities with their `element_id`, so a VLM call can be grounded ("there's
  a `wheat_mature` 3m ahead") without the model having to guess.
- [ ] **2.3** Cooperative task primitives: shared plan slot on entities
  (`meta.shared_goal`), so two agents can commit to "build a house" or
  "hunt the deer" together. Driver for the brain's action selection.
- [ ] **2.4** Host/client multiplayer scaffold (ViZDoom pattern, using
  Godot's `MultiplayerAPI`). Not for humans joining — for decoupling
  brain processes from the sim process so LLM/VLM brains can run out of
  band without blocking ticks.
- [ ] **2.4a** Trade primitive (from L3 vision phase D): agent A has
  surplus food, agent B has surplus wood → swap. Brain reads inventory
  + nearby agents' inventory, proposes exchange. Foundation for emergent
  economy.
- [ ] **2.4b** Conflict primitive: resource competition when scarcity
  hits. Hostile claim — steal from another agent's stockpile, or fight
  over the last wheat patch. Pairs with combat (2.6).

**Depth items (independent of game goal)**

- [ ] **2.5** Day/night drives behavior. Agents seek shelter at night.
  Needs only ~1 rule addition + brain hook; `world_environment.gd` already
  has the cycle.
- [ ] **2.6** Combat in sim. Hostile brain spawns (orc reuse from dungeon),
  agents defend/flee. Hook into target-claim + damage effects.
- [ ] **2.7** Stockpiles / containers. Agents store food for later instead
  of eating everything at source.
- [ ] **2.8** More composites — market stall, watermill, more house variants.
- [ ] **2.9** Fire spread (L3 vision world-effects). Fire propagates to
  adjacent burnable elements (`tree`, `wood`); `water`/`stone` block it.
  Existing `spread` effect in rules engine can express this directly —
  just needs a campfire-overflow rule and per-tree `burning` state.
- [ ] **2.10** Cold / weather damage when exposed (L3 vision). Rain or
  night without shelter ticks an HP penalty. Reuses `agent_near_group`
  condition + `damage` effect.

### Tier 3 — POLISH

- [ ] **3.1** A* pathfinding for sim agents (wire existing `pathfinding_astar.gd` or switch to `NavigationAgent3D`).
- [ ] **3.2** Async LLM brain — non-blocking `claude -p` via `OS.create_process`. Required before multi-LLM agents.
- [ ] **3.3** Tune village visual density — more trees/flowers in forest zones.
- [ ] **3.4** Single-cam option for human viewing vs multi-cam for capture.
- [ ] **3.5** VQA-driven visual regression — capture + grade on each change (skill `visual-qa` already exists).
- [ ] **3.6** Persistent agent memory / discovered recipes (L3 vision
  phase C). Right now brains re-derive plans from data each tick. Add
  `meta.memory.recipes` so an agent that succeeds at `chop tree → wood`
  remembers it cheaper next time, and never-tried recipes are tried
  opportunistically. Foundation for "agents learn".

### Tier 4 — GRID & INFRA (later)

- [ ] **4.1** Tile grid refactor per `docs/26_grid_system_proposal.md`.
  OpenSC2K analysis validates this: multi-layer grid + multi-cell buildings
  is how SimCity-likes stay fast and enable save/load + territory.
- [ ] **4.2** Save/load — snapshot entity `meta.state` + plan + world rules state. Trivial once entities are the single source of truth (already true).
- [ ] **4.3** Episode recorder — per-frame scene graph + action labels to disk. Foundation for any downstream research use.
- [ ] **4.4** Multi-LLM agents — requires 3.2 async first.
- [ ] **4.5** Time acceleration (L3 vision phase E). Run sim at 10–100×
  for emergent-pattern observation. Already feasible in principle (tick
  clock is the only time source); needs a clamped tick rate + headless
  capture path.

---

## Design Principles (enforced)

Behavioral posture (karpathy-guidelines skill): **think before code,
simplicity first, surgical changes, goal-driven execution.**

- **Everything from JSON.** Hardcoded numbers in engine scripts get extracted to config. Engine is substrate; content is data.
- **Data-first, GD-second.** Only touch GDScript when JSON can't express the feature. Lesson: `data_first_gd_second`.
- **No backward-compat scaffolding while in active dev.** Fix forward. Don't layer "preserves existing behavior" defaults.
- **Reusable components.** Build the per-agent panel once; the manager composes. No bespoke per-agent wiring.
- **Skill before build.** Design the pattern in a skill first, implement against it (karpathy-guidelines, visual-qa, godot-api).
- **Visual QA via forked skill.** Self-grading is biased; use the `visual-qa` skill for unbiased reads. Lesson: `self_grading_is_biased_use_vqa`.
- **Don't frame as DeepMind deliverable.** Focus on sim foundation. Research framing is a long-term outcome, not a next-step milestone.

---

## Reference artifacts

- `docs/21_emergent_world_vision.md` — **historical vision doc** (4 levels, elements+rules+needs JSON sketch, NeedsDrivenBrain pseudocode, 5-phase implementation A–E). Substrate (A–C) is built. Phase D/E folded into Tier 2/4 above.
- `docs/26_grid_system_proposal.md` — future grid design
- `docs/27_game_goal_discussion.md` — four game-goal candidates + recommendation
- `docs/25_simulation_world_design.md` — world layout spec
- `~/.yume/lessons/rpg/` — full lessons corpus (170+ YAMLs)
- External study: **ViZDoom** (multi-buffer observation, labels, host/client, gym wrapper), **OpenSC2K** (multi-layer grid, multi-cell buildings, sparse simulation) — in `/mnt/c/Users/kamwoh/Documents/Projects/Personal/`

---

## Visual QA command (standing rule)

```bash
rm -f /mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume3D/captures/frame_000*.png
timeout 20 /mnt/c/Users/kamwoh/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe \
  --path C:/Users/kamwoh/Documents/Projects/Godot/Yume3D --rendering-method gl_compatibility
# Then Read frame_*.png captures. NEVER use --headless for visual QA.
```

---

## Honest status

Foundation is **~75% complete**. Tier 1 is green — sim self-sustains, farming
loop closed, population respawns, entities share a unified state model. What
it lacks is a _driver_: a reason for the world to have arc, stakes, or
visible accumulation. That's Tier 2. Everything else (grid, save/load,
research export) sits behind that wall.
