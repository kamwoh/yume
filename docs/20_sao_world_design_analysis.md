# Sword Art Online — World Design Analysis for Yume

## Date: 2026-04-10

## Core Concept: The Cardinal System

SAO's world is managed by an autonomous AI (Cardinal) that:
- Auto-balances difficulty based on player progression
- Generates quests procedurally from narrative seeds
- Controls weather, time, day/night, events
- Manages economy (prevents inflation/deflation)
- Detects exploits and rebalances spawn rates/drops

**Yume equivalent:** A `world_manager` abstraction layer:
```json
"world_manager": {
  "brain": "cardinal",    // or "static" (no balancing) or "llm" (Claude manages)
  "difficulty_scaling": true,
  "dynamic_spawning": true,
  "economy_balancing": true
}
```

## World Structure: Hierarchical Floors

Each SAO floor: Town (safe) → Field (danger) → Labyrinth (dungeon) → Boss Room

For Yume procedural gen:
```
Dungeon = sequence of rooms with pacing:
  safe_room → corridor → combat_room → puzzle_room → treasure_vault → boss_arena

Each floor/level has:
  - Theme (biome, architecture, lighting mood)
  - Difficulty tier (enemy stats scale with floor number)
  - Unique boss with phase-based AI
  - Safe zones with shops/save points
```

## AI Paradigms

### Top-Down (Scripted) — Our StateMachineBrain
- Pre-written behavior states
- Predictable, exploitable
- Good for common enemies

### Bottom-Up (Emergent) — Our LLMBrain
- Responds dynamically to context
- Learns and adapts
- SAO's "Fluctlight" concept = NPC with persistent memory + LLM decisions
- This IS the future of Yume's NPC system

## Combat Design

### Sword Skills
- Pre-motion (windup) → System-assisted execution → Post-motion (vulnerability)
- Risk/reward: powerful skills have longer recovery
- Cooldown management is tactical

### Boss Thresholds
- HP phases (100% → 75% → 50% → 25%)
- Behavior changes at each threshold
- Minion spawning at phase transitions
- Special attacks unlocked at low HP

For Yume brain_state_machine.gd: add HP-threshold state transitions:
```json
"ai_config": {
  "phase_transitions": [
    {"hp_percent": 0.75, "adds_state": "enraged", "speed_multiplier": 1.3},
    {"hp_percent": 0.50, "adds_state": "spawn_minions"},
    {"hp_percent": 0.25, "adds_state": "desperate", "attack_multiplier": 2.0}
  ]
}
```

## Dungeon Design

### Labyrinth Patterns
- Multi-floor tower dungeons (100m+ height)
- Guaranteed safe rooms for rest/recovery
- Boss room signaling: crude entrance = weak boss, ornate = strong boss
- Anti-escape zones (no teleportation in boss rooms)
- 1 week to fully map = complex enough for extended exploration

### Monster Spawning
- Time-of-day: night = stronger monsters
- Respawn timers: 24h for special NPCs
- Field bosses: unique per area, don't respawn
- Floor bosses: one-time encounters, gate progression

## The World Seed = Yume's Vision

SAO's "World Seed" is literally what Yume aims to be:
- Free, open-source game engine
- Distributed computation
- Built-in Cardinal-like management system
- Templates and presets for world creation
- Cross-world interoperability

Yume IS the World Seed concept — `pip install yume && yume generate` creates worlds.

## Key Abstraction Layers Inspired by SAO

```
World Manager:  "brain": "cardinal" | "static" | "llm"
Floor Theme:    "theme": "forest" | "desert" | "ice" | "volcano" | "castle"
Difficulty:     "floor": 1-100 → auto-scales enemy stats
Boss AI:        "phases": [{hp_pct, behavior_change, minion_spawn}]
Time System:    "time_of_day" → affects spawn strength, lighting
Economy:        "cardinal_balance" → auto-adjusts drops/prices
NPC AI:         "brain": "scripted" | "state_machine" | "fluctlight_llm"
```

## Training Data Value

SAO's world design maximizes the diversity of **agent experiences**:
- Combat: attack timing, cooldowns, vulnerability windows
- Exploration: mapping, pathfinding, secret finding
- Social: party formation, trading, communication
- Survival: resource management, risk assessment
- Boss encounters: phase adaptation, strategy switching

This diversity = rich training data for world models.
