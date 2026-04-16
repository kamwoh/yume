# Task Plan: Yume — Autonomous Agent Simulation Engine

## North Star (honest)

Build a simulation engine where agents — driven by needs, rules, or LLMs —
actually **live** in a 3D world: hunger decays, crops grow, wood rots, fires
burn out. Everything data-driven from JSON.

Eventual research goal (DeepMind-adjacent training data) is far away. Focus
stays on the simulation foundation.

## Current frontier (2026-04-16)

**Tier 1 complete. Sim self-sustains.** But it's AIMLESS — just homeostasis
forever. User observation: "feels kind of empty, we should have a game goal".

See `docs/27_game_goal_discussion.md` for the 4 candidate directions:
- **(a) Survive the night** ⭐ recommended — low effort, high drama, ~1-2 hours
- (b) Build a village — medium effort, slow progression
- (c) Tech tree — high effort, stat progression
- (d) Agent individuality — medium-high effort, story-driven

Next session: pick a direction from (a-d) and build toward the feeling, not
the mechanic.

---

## Current State (2026-04-16)

### ✅ Done — simulation foundation

| Layer | State |
|---|---|
| 3D engine modules | sim_world.gd 135-line orchestrator. WorldEnvironment/Terrain/Elements/Agents/RulesEngine/ModelHelpers as focused files |
| Tick clock | world_clock.gd. 0.5s default. Drives brains + rules. Movement stays continuous. |
| Rules engine | Global + per-entity rules. Effects: need_decay/restore, damage, remove, transform, advance_stage, spread, state_add, state_set. Conditions: need_below, nearby_element, agent_near_group, neighbor_group, state_below, state_above |
| Brain abstraction (4 working) | human, auto_agent, state_machine, needs_driven, llm (claude -p) |
| Data-driven | elements.json, needs.json, recipes.json, world_rules.json, asset_config.json, meta.json |
| Composites | Multi-part buildings (house_small, fountain_plaza, windmill) from JSON parts |
| HUD | Reusable agent_needs_panel auto-creates per agent |
| Target claim system | Prevents agent-on-agent stacking |
| Animation pipeline | Kenney rigs → AnimationLibrary |
| Entity lifecycles | Every object has state + local rules. Water evaporates/rains, seeds grow, wheat rots, campfire burns fuel |

### ✅ Validated labs

- `data/sim/` — 100×100 real village, 3 agents, 7 zones, 788 elements
- `labs/house/` — composite pipeline
- `labs/agent/` — multi-agent
- `labs/craft/` — crafting chain (mine → craft → chop)
- `labs/llm/` — claude-driven agent full survival loop

### 🟡 Observed but not fixed

- Food scarcity — 4 wheat can't sustain 3 agents
- Agents don't plant seeds they harvest
- Rain/evaporation balance net-negative (water slowly drains)
- Straight-line pathfinding (no A* in sim)

### ❌ Not done

Grid system, A* for sim, async LLM, agent vision, farming behavior, multi-step
planning, combat in sim, day/night behavior affecting decisions, save/load,
data export.

---

## The plan — tiers of work remaining before "foundation complete"

### Tier 1 — SELF-SUSTAINING SIM (required before anything else)

Goal: a sim that runs indefinitely without hand-feeding. Agents survive via
their own production, not hardcoded resource piles.

- [ ] **1.1** Farming behavior in brain: `wheat_seed_item` in inventory +
  near farmland OR bare ground → plant action → wheat_seed element spawned
- [ ] **1.2** Balance pass: hunger/thirst decay rates, rain vs evaporation,
  wheat lifespan. Goal: 3 agents survive 10+ min without intervention
- [ ] **1.3** Bootstrap fix: agent should be able to get both wood AND
  cobblestone with ONE tool (currently axe ≠ pickaxe blocks crafting loop).
  Options: punch-tree fallback, or start with both tools
- [ ] **1.4** Agent reproduction / lifespan? (open question — do we want
  agents to die + be replaced for true long-term sim? or just survive?)

**When done:** can leave the sim running for 30+ min and agents are still alive.

### Tier 2 — DEPTH (after Tier 1 green)

- [ ] **2.1** Day/night affects behavior — agents seek shelter at night
- [ ] **2.2** Combat in sim — hostile brain entity spawns, agents defend/flee
- [ ] **2.3** Tile grid refactor (per docs/26_grid_system_proposal.md)
  — enables real pathfinding, territory, save/load
- [ ] **2.4** More composites — market stall, watermill, more house variants
- [ ] **2.5** Stockpiles / containers — agents store food for later

### Tier 3 — POLISH

- [ ] **3.1** A* pathfinding for sim agents (via NavigationAgent3D or grid)
- [ ] **3.2** Agent vision — per-agent viewport capture for LLM brain
- [ ] **3.3** Async LLM brain — non-blocking `claude -p` via OS.create_process
- [ ] **3.4** Tune village visual density — more trees/flowers in forest zones
- [ ] **3.5** Single-cam option for human viewing vs multi-cam for capture

### Tier 4 — INFRA (later)

- [ ] **4.1** Save/load — snapshot entity state + plan + world rules state
- [ ] **4.2** Data export — per-frame scene graph + action labels to disk
- [ ] **4.3** Multi-LLM agents — requires async first
- [ ] **4.4** Episode recorder for research pipeline

---

## Core Principles (enforced)

Behavioral posture (karpathy-guidelines skill): think before code, simplicity
first, surgical changes, goal-driven execution.

- **Everything from JSON** — if you write hardcoded numbers in engine scripts,
  extract to config
- **No backward-compat scaffolding while in active dev** — fix forward, don't
  layer defensive defaults
- **Reusable components** — build per-agent panel, manager composes
- **Data-first, GD-second** — only touch GDScript when JSON can't express the
  feature. See: `data_first_gd_second` lesson
- **Skill before build** — design pattern in skill FIRST, implement following
  it (e.g. karpathy-guidelines, visual-qa, godot-api)
- **Visual QA via forked skill** — my self-grading is biased; use visual-qa
  skill for unbiased reads
- **Stop framing as DeepMind deliverable** — focus on sim foundation. The
  research framing is a long-term outcome, not a next-step milestone

---

## Lessons corpus

~/.yume/lessons/rpg/ — 170+ YAML lessons across 3d, assets, architecture,
workflow, combat, dialogue, etc. Load via lookup when debugging.

---

## Where we were before this session

Session 2026-04-14: Dungeon done, sim world rough (~55%), fantasy town kit
extracted but unused, needs/recipes/rules designed but not wired.

## Where we are now (2026-04-16)

- Real village runs with 3 named AI agents (Iris, Bjorn, Elara)
- Entity lifecycle unified across agents and elements
- 4 brain types working
- 5 labs validated
- Campfire burns, water evaporates/rains, seeds grow, wheat rots
- Agents claim targets — no more stacking

**Honest status: foundation is ~70% complete. Tier 1 missing to call it "done".**

---

## Visual QA Command (standing rule)

```bash
rm -f /mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume3D/captures/frame_000*.png
timeout 20 /mnt/c/Users/kamwoh/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe \
  --path C:/Users/kamwoh/Documents/Projects/Godot/Yume3D --rendering-method gl_compatibility
# Then Read frame_*.png captures. NEVER use --headless for visual QA.
```
