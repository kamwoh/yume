# Task Plan: Yume — Procedural Game Generation for World Modeling Data

## Vision
Generate UNLIMITED diverse 3D game worlds from text descriptions.
Each world produces training data: camera trajectories, agent actions, physics, scene graphs.
Open source → researchers use Yume instead of scraping AAA games.

Target: DeepMind Genie team. Solve the DATA bottleneck for world models.

## The Pitch
```
World models need: diverse 3D environments + camera control + agent actions + physics
Currently: scrape YouTube (noisy) or license AAA games (expensive, limited)
Yume: text → 3D game → unlimited labeled training data

"A medieval town"     → town with NPCs, shops, physics
"A space station"     → sci-fi corridors, zero-gravity, tech
"A dungeon crawler"   → procedural rooms, traps, enemies, combat
"A racing game"       → tracks, vehicles, speed physics

Each generates: frames + camera poses + action labels + scene graph
```

---

## Current State (2026-04-15)

| Area | State | Visual grade |
|---|---|---|
| 3D engine core (entity + brain + camera + HP + minimap + A*) | ✅ working | — |
| Dungeon world (multi-room, proc-gen, multi-floor) | ✅ playable | ~65% |
| Simulation world (heightmap + 7 zones + day/night + camp) | 🟡 playable, rough | **~55%** |
| Fantasy town kit (167 GLBs) | ⚠️ **extracted but unused** | — |
| Needs-driven brain + recipes + world rules | 🟡 JSON designed, not wired | — |
| Data export pipeline | ❌ not built | — |
| LLM brains (`claude -p`) | ❌ not built | — |

**Blocker on visual grade:** village zone places flowers + 5-piece camp only. Town kit is **parts, not buildings** (walls, roofs, doors) — needs a composite layer in the engine to become houses.

---

## Four parallel tracks

### 🏗️ Track 1 — Fantasy town kit → real villages

Town kit GLBs are parts, not buildings. Need composite layer.

- [ ] **1.1** Add `composite_element` type to `elements.json` schema — element = list of GLB parts with local offsets/rotations
- [ ] **1.2** Define starter buildings: `house_small`, `house_medium`, `market_stall`, `fountain_plaza`, `windmill`, `watermill`
- [ ] **1.3** Add `road` tile system to `generate_sim_world.py` — replace tinted-dirt paths with `road.glb` + `road-bend.glb`
- [ ] **1.4** Rework `village` zone: fountain centerpiece + 4-6 houses + 2-3 stalls, connected by roads
- [ ] **1.5** Windmill landmark on outskirts, watermill next to lake zone

**Risk:** composite placement on heightmap — parts must snap per-part OR flatten terrain under the building.

**Visual grade target after Track 1:** 70%+

### 🧠 Track 2 — Emergent world (Level 3)

- [ ] **2.1** Wire `brain_needs_driven.gd` to a spawned agent
- [ ] **2.2** Implement `world_rules.json` ABMs in engine (wheat growth, fire spread, need decay)
- [ ] **2.3** Inventory + recipes applied to agents (chop tree → wood → craft)
- [ ] **2.4** First emergent loop: agent hungry → finds wheat_mature → eats
- [ ] **2.5** Multi-agent (5-10) with resource competition
- [ ] **2.6** Time acceleration (100x) for rapid evolution

### 🎥 Track 3 — Data export pipeline (the DeepMind pitch)

- [ ] **3.1** `episode_recorder.gd` — per-frame dump: camera pose, agent action, scene graph
- [ ] **3.2** Action label schema (move, attack, interact, chop, eat, …)
- [ ] **3.3** Scene graph format (object IDs, positions, states per frame)
- [ ] **3.4** Export to WebDataset + mp4 + annotations
- [ ] **3.5** Benchmark demo: 10 worlds → N hours labeled data

### 🤖 Track 4 — LLM brains

- [ ] **4.1** `brain_llm.gd` — `claude -p` + screenshot → action
- [ ] **4.2** NPC LLM brain (guard with reasoning)
- [ ] **4.3** Camera LLM brain (picks cinematic angle)
- [ ] **4.4** World manager brain (events, difficulty, weather)

---

## Dependency graph

```
Track 1 (houses + village)
    ↓ enables
Track 2 (agents have HOMES, market, places to defend/repair)
    ↓ enables
Track 3 (recorded episodes show civilization in a real-looking town)
    ↓ enables
Track 4 (LLM brain has rich context: "guard patrolling market at dusk")
```

Track 1 is the **foundation**. Without it: Track 2 agents wander empty grassland; Track 3 data looks like a tech demo, not a world.

---

## Recommended order

1. **Track 1.1 + 1.2 (partial)** — composite_element system + 1 house + fountain. Validate the pattern. ~45 min.
2. **Visual QA stop** — user review: right direction?
3. **Track 1.3–1.5** — roads, village rework, landmarks. → 70% visual.
4. **Track 2.1 + 2.4** — wire NeedsDrivenBrain, first emergent loop.
5. **Track 3.1–3.3** — episode recorder + scene graph. Every playthrough = training data.
6. **Track 2.5 + 2.6** — multi-agent + time acceleration. Emergent civilization.
7. **Track 4** — LLM brains.

---

## Not doing (deferred)

- Rebuilding dungeon (done, stable)
- Reworking characters/combat
- New biomes beyond village sim
- 3D asset generation from text (use free GLBs first)

---

## Available asset inventory (Kenney + KayKit, 1,285 GLBs total)

| Kit | GLBs | Purpose |
|---|---|---|
| assets_library/nature_kit | 329 | Trees, plants, rocks, flowers, terrain |
| assets_library/survival | 80 | Campfire, tents, tools, resources |
| **assets_library/town** | **167** | **Fantasy town parts (walls, roofs, fountain, mill)** |
| assets_library/dungeon | ~100 | Dungeon tiles + props |
| assets_library/characters | 6 | Knight, Barbarian, Mage, Ranger, Rogue, Orc |
| assets_library/forest_nature | ~100 | Stylized forest props |
| assets_library/platformer | ~50 | Platformer kit (deferred) |
| assets_library/props, furniture, resourcebits | ~80 each | Misc |

---

## Completed history

### 2026-04-08 → 04-09
- 2D engine complete (FF9 2D archetype)
- 3D engine: world_builder.gd, player_3d.gd, JSON-driven GLB loading
- 876 free GLBs organized
- Auto-capture + auto-agent + visual QA loop proven

### 2026-04-10
- Harness engineering: 5 hooks, 3 agents, visual regression, 116 lessons
- Game design study: docs/18, 33 rules, metrics, algorithms
- First good room: L-shape dungeon_guard_post with point lights + zebra lighting + focal point
- Visual QA loop proven from WSL via gl_compatibility

### 2026-04-10 → 04-14 (Simulation Phase)
- Dungeon: multi-room seamless, A*, proc-gen shapes + biomes + multi-floor
- Simulation: heightmap terrain (SurfaceTool + HeightMapShape3D), 7 zones, day/night cycle
- Brain abstraction extended: state_machine, human, auto_agent, needs_driven (designed)
- Elements system: object_type + material + collision + light + tint from JSON
- Python generator: `generate_sim_world.py` → full JSON world (zero runtime gen)
- Multi-camera QA with FOV cone on minimap
- 155+ lessons in ~/.yume/lessons
- Kenney fantasy-town-kit (167 GLBs) extracted to assets_library/town/

---

## Data Format (export goal)

```json
{
  "episode_id": "medieval_town_ep_042",
  "world_config": "locations/medieval_town.json",
  "frames": [
    {
      "timestep": 0,
      "camera": {"pos": [1.2, 2.0, 3.5], "rot": [0, 45, 0], "fov": 75},
      "agent": {"pos": [1.0, 0, 3.0], "action": "move_forward", "velocity": [0, 0, 1.5]},
      "objects": [
        {"id": "barrel_01", "pos": [3, 0, 2], "state": "intact"},
        {"id": "npc_guard", "pos": [5, 0, 4], "state": "patrol"}
      ]
    }
  ],
  "metadata": {"game_type": "rpg", "environment": "medieval_town", "duration_sec": 30}
}
```

---

## Visual QA Command (STANDING RULE — never ask human to test)
```bash
rm -f /mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume3D/captures/frame_000*.png
timeout 20 /mnt/c/Users/kamwoh/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe --path C:/Users/kamwoh/Documents/Projects/Godot/Yume3D --rendering-method gl_compatibility
# Then Read frame_*.png captures. NEVER use --headless for visual QA.
```

## Why This Wins

| vs Scraping YouTube | vs AAA Game Licensing | vs Minecraft |
|---|---|---|
| Perfect labels (not noisy) | Free and unlimited | Any environment (not just blocks) |
| Controllable camera | Any game type | Rich physics + diverse aesthetics |
| Diverse environments | Open source | GLB models, not voxels |
| Action annotations | Reproducible | Story/NPC/quest structure |
