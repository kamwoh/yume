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

## What Exists
- 2D engine (complete, pushed to GitHub)
- game_state.json architecture (story phases, triggers)
- 6 LLM prompts (generate any game from text)
- 25 free GLB models (Kenney)
- 556 more GLBs in /tmp/yume_3d_assets/
- 4-layer test suite
- Asset manager UI

## Priority: 3D + Actions first, dialogue secondary

### Phase 1: 3D World from JSON ← START HERE
- [ ] Godot 3D project: floor + walls + props from location JSON
- [ ] Load GLB models for props (barrel, chest, rock, tree)
- [ ] CharacterBody3D player with third-person camera
- [ ] WASD movement, collision, physics
- [ ] Load ANY location JSON → different 3D room
- **Goal:** one JSON file = one 3D room with physics

### Phase 2: Procedural World Generation
- [ ] Script: generate N random location JSONs with varied layouts
- [ ] Different room types: indoor, outdoor, cave, town, dungeon
- [ ] Different prop sets, lighting, atmosphere per type
- [ ] Connect rooms via exits → traversable world
- **Goal:** "generate 100 unique rooms" → instant diverse environments

### Phase 1.5: Perfect One Scene ✅ DONE
- [x] Combat (entity + brain abstraction, state machine AI, player attack)
- [x] Interactions (chest open, coin collect, trap trigger)
- [x] Seamless multi-room (3 rooms physically adjacent, no loading)
- [x] Minimap + HP bar UI
- [x] A* pathfinding (nav_grid.json, auto-agent navigates through doors)
- [x] Camera brain abstraction (follow, orbital, random_smooth, cinematic)

### Phase 2: Procedural World Generation ← IN PROGRESS
- [x] Basic generator: 5 room templates, varied sizes, props, enemies, lighting
- [x] 2D layout: rooms connect N/S/E/W randomly (not just vertical stack)
- [ ] **Irregular room shapes**: L-shape, T-shape, alcove, plus cellular automata caves
- [ ] **Multi-floor**: stairs connecting floor 1 → floor 2 → floor 3 (SAO Aincrad style)
- [ ] **Diagonal/organic connections**: corridors at angles, not just grid-aligned
- [ ] **Biome variety**: dungeon, town, forest, cave — different model sets + lighting
- [ ] **Room interior variation**: asymmetric layouts, vertical platforms, water features
- [ ] Scale test: generate 20, 50, 100 rooms and verify playability

### Phase 2a: Irregular Room Shapes
Room shape is another abstraction: `"shape": "rectangle" | "L" | "T" | "cave" | "circular"`
- [ ] L-shape: main rectangle + side extension (random direction)
- [ ] T-shape: main rectangle + branch in the middle
- [ ] Alcove: rectangle with cut-out section
- [ ] Cave: cellular automata (40% random walls → iterate → organic shape)
- [ ] Circular: round room with columns around perimeter
- Each shape has different gameplay feel and visual variety

### Phase 2b: Multi-Floor (Vertical Dungeon)
Like SAO's Aincrad — floors stacked vertically with stair connections.
- [ ] Stairs prop connects floor N to floor N+1
- [ ] Each floor = separate set of rooms at different Y heights
- [ ] Floor themes: floor 1 = easy dungeon, floor 2 = harder, floor 3 = boss
- [ ] Auto-agent navigates stairs (pathfinding in 3D, not just 2D)
- [ ] Minimap shows current floor only
- [ ] `dungeon.json` gains `"floors"` array, each with rooms + offsets

### Phase 2c: Biome Variety
Same engine, different model sets + lighting + atmosphere:
- [ ] Dungeon biome: stone walls, torches, dark — current models
- [ ] Town biome: buildings, fences, fountains, bright — town/ models (167)
- [ ] Forest biome: trees, bushes, rocks, natural light — forest_nature/ models (105)
- [ ] Cave biome: irregular shapes (cellular automata), rocks, dim — dungeon + rocks
- [ ] Castle biome: castle walls, gates, flags, dramatic — props/ models (72)
- [ ] Interior biome: furniture, rugs, lamps, warm — furniture/ models (53)
- Each biome = different `model_set` + `lighting_mood` + `room_shape` preference

### Phase 2d: Diagonal & Organic Connections
Not just grid-aligned rooms:
- [ ] Corridors at 45° angles connecting rooms
- [ ] Rooms with fractional offsets (not snapped to grid)
- [ ] Winding paths (multiple-segment corridors with turns)
- [ ] Open areas connecting to multiple rooms (hub rooms)

### Phase 3: Agent Actions + Recording
- [x] Player controller records: position, rotation, action per frame (auto_agent.gd)
- [x] Random agent: walks around rooms automatically (auto_agent.gd)
- [ ] Action types: move, interact, attack, jump, turn
- [ ] Export per-episode: {frames[], camera_poses[], actions[], scene_graph}
- **Goal:** automated data generation without human playing

### Phase 4: Camera Control Data
- [ ] Multiple camera modes: third-person, first-person, top-down, cinematic
- [ ] Record camera pose per frame (position, rotation, FOV)
- [ ] Cutscene camera paths from game_state.json = labeled trajectories
- **Goal:** camera control ground truth for video generation models

### Phase 5: Diverse Game Types
- [ ] Action game: combat, enemies, attack patterns
- [ ] Exploration: navigate rooms, find items
- [ ] Platformer: jumping, moving platforms (different physics)
- [ ] Social: NPCs walking, talking, schedules
- Each type = different action space + physics rules
- **Goal:** not just RPG — diverse game mechanics in one framework

### Phase 6: Export Pipeline
- [ ] Export to WebDataset (standard ML format)
- [ ] Export to video (mp4 + annotations)
- [ ] Scene graph per frame (JSON: what objects, where, state)
- [ ] Action labels per frame (what agent did)
- **Goal:** plug into any world model training pipeline

### Phase 7: Level 3 — Emergent Worlds (The Sims + SAO Alicization)
The big vision: define elements + rules → agents discover civilization.
- [ ] Needs system: hunger, energy, safety (decay per second, critical effects)
- [ ] Object ratings: each object advertises what needs it satisfies
- [ ] Autonomy scoring: urgency × rating → agent picks best action
- [ ] Elements: tree, rock, water, fire, seed, wood, ore, metal
- [ ] Recipes: chop tree → wood, plant seed → food, smelt ore → metal
- [ ] NeedsDrivenBrain: scans nearby → plans action chain → satisfies most urgent need
- [ ] Multi-agent: 5-10 agents in same world, competing for resources
- [ ] Emergent discovery: nobody scripts "farm" — agents discover it from hunger + seeds
- [ ] Time acceleration: run simulation at 100x for rapid world evolution
- See: docs/21_emergent_world_vision.md, docs/22_sims_architecture_analysis.md

### Phase 7b: LLM Brains
- [ ] brain_llm.gd: calls `claude -p` + screenshot for decisions
- [ ] NPC brain: guard "sees" intruder → decides to attack
- [ ] Player brain: Claude plays the game by looking at screenshots
- [ ] Camera brain: Claude picks most cinematic angle
- [ ] World manager brain: Claude decides events, difficulty, weather

### Phase 8: Open Source Release
- [ ] Clean README with research positioning
- [ ] Demo: "10 diverse worlds generated from 10 text prompts"
- [ ] Benchmark: compare data diversity vs existing datasets
- [ ] pip install yume && yume generate && yume record && yume export
- [ ] Blog post / paper draft

## Data Format (what we export)

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

## Why This Wins

| vs Scraping YouTube | vs AAA Game Licensing | vs Minecraft |
|---|---|---|
| Perfect labels (not noisy) | Free and unlimited | Any environment (not just blocks) |
| Controllable camera | Any game type | Rich physics + diverse aesthetics |
| Diverse environments | Open source | GLB models, not voxels |
| Action annotations | Reproducible | Story/NPC/quest structure |

## Completed (2026-04-10)
- [x] Phase 1: 3D World from JSON (grid rooms, GLBs, player, camera, collision)
- [x] Harness engineering (5 hooks, 3 agents, visual regression, 116 lessons)
- [x] Game design study (docs/18, 33 rules, metrics, algorithms)
- [x] First good room (guard_post — dark bg, zebra lighting, focal point, story props)
- [x] Point lights from JSON, spawn_on_grid, auto-agent from config
- [x] Visual QA loop proven (gl_compatibility, auto-capture, Claude reads screenshots)

## Visual QA Command (STANDING RULE — never ask human to test)
```bash
rm -f /mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume3D/captures/frame_000*.png
timeout 20 /mnt/c/Users/kamwoh/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe --path C:/Users/kamwoh/Documents/Projects/Godot/Yume3D --rendering-method gl_compatibility
# Then Read frame_*.png captures. NEVER use --headless.
```

## 5-Question Reboot Check
| Question | Answer |
|----------|--------|
| Where am I? | First good room done. Design rules proven. Visual QA loop working. |
| Where am I going? | Templates → procedural gen → agent recording → export → open source |
| What's the goal? | Generate 100+ diverse rooms that look like real game levels. DeepMind portfolio. |
| What have I learned? | Dark bg + point lights + focal point + asymmetry + story props = real dungeon. Never ask human to test — use auto-capture. |
| What have I done? | 2D engine, 3D engine, 116 lessons, harness, design study, first good room, visual QA |
