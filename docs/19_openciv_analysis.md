# OpenCiv Codebase Analysis — Lessons for Yume

## Source: /mnt/c/Users/kamwoh/Documents/Projects/Personal/OpenCiv
## Date: 2026-04-10

## What OpenCiv Is
Web-based Civilization clone. TypeScript, 21K LOC. Turn-based 4X strategy with hex grid, procedural map gen, multiplayer WebSocket.

## Key Patterns to Adopt

### 1. Procedural Landmass Generation (HIGH PRIORITY)
Algorithm: random walk + circles → land/ocean → height sorting → mountains/hills → temperature gradient → biomes → resource clustering

Adaptable to Yume rooms:
- Random walk → floor layout (where walkable tiles go)
- Height map → platform placement (elevation variation)
- Temperature → lighting mood (warm/cool zones)
- Resource clustering → prop/enemy placement (grouped, not scattered)

### 2. Event Bus Architecture (MEDIUM)
All actions emit events, listeners subscribe independently. Decoupled recording.
- Agent emits "moved", "attacked", "collected" → DataRecorder subscribes
- No coupling between brain logic and data export

### 3. A* Pathfinding with Movement Costs (MEDIUM)
Hex grid A* with terrain-dependent movement costs. Queued multi-tile paths.
- Apply to NPC navigation: find path to target, follow it over multiple frames
- Movement cost from JSON: floor=1.0, rocks=2.0, water=impassable

## Abstraction Layers (Yume Pattern)

ALL of these should be swappable via JSON:

```
Room Generation:
  "generator": "grid"           ← current (hand-designed ASCII grid)
  "generator": "random_walk"    ← OpenCiv-style procedural
  "generator": "bsp"            ← binary space partition
  "generator": "cellular"       ← cellular automata (caves)
  "generator": "wfc"            ← wave function collapse

Pathfinding:
  "pathfinding": "direct"       ← current (walk straight to target)
  "pathfinding": "astar"        ← A* with movement costs
  "pathfinding": "navmesh"      ← Godot NavMesh (future)

Entity Brains:
  "brain": "state_machine"      ← current (patrol/guard/chase/attack)
  "brain": "behavior_tree"      ← complex decision trees
  "brain": "llm"                ← LLM-based decisions

Camera Brains:
  "brain": "follow"             ← current gameplay camera
  "brain": "orbital"            ← circles around POI
  "brain": "random_smooth"      ← diverse training data
  "brain": "cinematic"          ← scripted paths

Player Brains:
  "brain": "human"              ← keyboard/mouse
  "brain": "auto_agent"         ← AI exploration + combat
  "brain": "llm"                ← Claude plays
```

## Where Yume Is Already Better

| Yume | OpenCiv |
|------|---------|
| Brain abstraction (swappable AI) | Hardcoded unit logic |
| Asset abstraction (auto-detect GLBs) | Hardcoded sprite coords |
| Runtime data-driven (change JSON, reload) | Needs server restart |
| Training data export (actions + camera + scene) | None |
| 3D rendering (GLB models) | 2D canvas only |

## OpenCiv Stats
- 21K LOC TypeScript
- 65 files (server + client)
- YAML configs for game data
- Docker deployment
- Jest testing
- No AI implementation yet (behavior trees planned)
