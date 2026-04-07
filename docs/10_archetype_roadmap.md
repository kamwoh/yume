# Yume Archetype Roadmap

## Current: RPG (turn-based JRPG)
- Status: Engine complete, content expanding, 52 rooms, FF9 reference game
- Templates: LocationManager, BattleManager (ATB), DialogueManager, QuestManager, etc.

## Planned Archetypes

| Priority | Archetype | Example Games | Shared with RPG | Unique Systems |
|----------|-----------|--------------|----------------|----------------|
| 1 | **Visual Novel** | Ace Attorney, Danganronpa | Dialogue, choices, save/load, UI theme | Scene transitions, character display, evidence system |
| 2 | **Action RPG** | Zelda, Diablo | Characters, inventory, quests, dialogue | Realtime combat, dodge, loot drops, hitboxes |
| 3 | **Platformer** | Mario, Celeste | Save/load, audio, UI | Physics, level scroll, jump mechanics, enemies |
| 4 | **Tactics** | FF Tactics, Fire Emblem | Characters, stats, inventory, story | Grid map, turn order, unit placement, terrain |
| 5 | **Roguelike** | Hades, Dead Cells | Combat, items, enemies | Procedural generation, permadeath, run system |
| 6 | **Simulation** | Stardew Valley | NPCs, dialogue, save/load | Time system, farming/building, relationships |
| 7 | **Puzzle** | Tetris, Portal | UI, save/load, audio | Grid logic, scoring, level progression |

## What's Shared (core/)
- GDD schema (characters, story, progression)
- Dialogue + cutscene system
- Save/load system
- Audio manager (BGM + SFX)
- UI theme system
- Validator
- Game dev docs + lessons
- Prompt templates (story → structured data)

## What's Unique per Archetype (archetypes/{type}/)
- Player controller
- Combat/interaction system
- Level/world structure
- Camera behavior
- Genre-specific UI
- Genre-specific data schemas

## Adding a New Archetype
1. Create `archetypes/{type}/templates/godot/` with engine scripts
2. Create `archetypes/{type}/docs/` with genre-specific knowledge
3. Create `archetypes/{type}/prompts/` for content generation
4. Create `archetypes/{type}/data/examples/` with a reference game
5. Update `yume init --type {type}` to scaffold from new templates
6. Build reference game → test → accumulate lessons

## 2D vs 3D
Each archetype can have both:
```
archetypes/rpg/templates/
├── godot-2d/    ← current (ColorRect, Node2D, Camera2D)
└── godot-3d/    ← future (MeshInstance3D, Camera3D, CharacterBody3D)
```
Same data, different renderer. `yume init my-game --type rpg --3d`
