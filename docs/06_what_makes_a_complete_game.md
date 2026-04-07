# What Makes a Complete RPG Game

## The Full Player Journey

A player's experience from launch to credits:

```
1. LAUNCH
   - Company logo (optional)
   - Title screen with game art/music
   - Menu: New Game, Continue, Settings

2. OPENING
   - Opening cutscene/narration (sets the world, tone)
   - Introduce the protagonist
   - First playable moment (usually simple — walk somewhere)
   - Tutorial woven into first area (teach movement, interaction)

3. INCITING INCIDENT (Act 1)
   - Something happens that forces the player to act
   - First companion joins
   - First quest begins
   - First town explored (learn: shop, inn, NPCs, chests)
   - First dungeon/danger area (learn: encounters, combat basics)
   - First boss (test player has learned combat)

4. RISING ACTION (Act 2)
   - New locations with increasing complexity
   - New party members with different abilities
   - Harder enemies, new mechanics (elements, status effects)
   - Story revelations (twists, betrayals, discoveries)
   - Multiple towns → dungeons → boss cycles
   - Side quests available
   - Equipment upgrades matter

5. MIDPOINT SHIFT
   - Major story twist (changes the player's understanding)
   - Stakes escalate dramatically
   - New region/continent opens up

6. CLIMAX (Act 3)
   - Final dungeon (longest, hardest)
   - Point of no return (game warns player)
   - Final boss sequence (often multi-phase)
   - Emotional peak

7. RESOLUTION
   - Ending cutscene
   - Character fates resolved
   - Credits
   - Optional: post-credits scene, new game+
```

## What's Missing from Our Game

### Critical (game feels broken without these)
- **Title screen** — first impression, sets the tone
- **Game over screen** — defeat needs consequences
- **Ending** — beating the final boss needs resolution
- **Sub-areas** — a "town" should have multiple rooms/screens
- **Story gating** — can't access everything from the start

### Important (game feels amateur without these)
- **Tutorial** — first area teaches mechanics naturally
- **Party join moments** — party members join at story beats, not all at start
- **Inn/rest mechanic** — heal without potions
- **Equipment visible in stats** — player sees gear impact
- **Level up notification** — celebration when character levels
- **Map/minimap** — orientation within and between areas

### Polish (game feels professional with these)
- **Screen transitions** — not just fade to black, different transitions per context
- **Damage numbers floating** — visual feedback in combat
- **Status effects** — poison, haste, etc.
- **Environmental interaction** — push objects, read signs
- **Weather per location** — rain in Burmecia, snow in Ice Cavern
- **Time of day** — visual change (already have lighting in atmosphere)
- **Footstep sounds** — different per terrain type
- **Menu cursor sound** — navigation feels responsive

## Sub-Area Architecture

Current: 12 locations, each one flat room
Target: 30-50 "rooms" organized into regions

```
Region: Alexandria (Act 1 start)
├── alexandria_gate         ← entrance, guards, first cutscene
├── alexandria_courtyard    ← fountain, theater, ambient NPCs
├── alexandria_market       ← shop, inn, side quest NPC
├── alexandria_castle_hall  ← story NPC (Garnet), quest trigger
└── alexandria_dungeon      ← hidden chest, optional area

Region: Evil Forest (Act 1 dungeon)
├── evil_forest_entrance    ← transition from Alexandria, first encounter
├── evil_forest_depths      ← harder encounters, treasure
├── evil_forest_clearing    ← save point, rest
└── evil_forest_exit        ← mini-boss, transition to Ice Cavern

Each "room" = separate location JSON
Rooms within a region share:
- Same background color family
- Same music
- Same encounter table
- Connected via exits (just like current locations)
```

This doesn't require ANY engine changes — LocationManager already handles it. We just need more location JSONs.

## Game State Machine (Full)

```
                    ┌──────────────┐
                    │ TITLE SCREEN │
                    └──────┬───────┘
                           │
                    ┌──────┴───────┐
                    │   NEW GAME   │──→ Opening cutscene → First location
                    │  CONTINUE    │──→ Load save → Resume location
                    └──────────────┘
                           │
              ┌────────────┴────────────┐
              │      EXPLORATION        │
              │                         │
              │  Walk → Interact → Talk │
              │  Open chests → Read signs│
              │  Enter buildings/rooms  │
              └────┬────────┬───────┬───┘
                   │        │       │
          ┌────────┴─┐  ┌──┴───┐  ┌┴────────┐
          │ DIALOGUE  │  │BATTLE│  │  MENU   │
          │ typewriter│  │ ATB  │  │party/inv│
          │ choices   │  │ cmds │  │save/load│
          └────┬──────┘  └──┬───┘  └┬────────┘
               │            │       │
               │     ┌──────┴──────┐│
               │     │   VICTORY   ││
               │     │  XP + Gil   ││
               │     └──────┬──────┘│
               │            │       │
               └────────────┴───────┘
                           │
                    ┌──────┴───────┐
                    │  GAME OVER   │──→ Retry / Title
                    └──────────────┘
                           │
                    ┌──────┴───────┐
                    │   ENDING     │──→ Cutscene → Credits → Title
                    └──────────────┘
```

## What Yume's GDD Generator Should Produce

The LLM (Pass 1-4) should generate:
1. **Regions** (not just "locations") with sub-areas
2. **Room connections** within regions (which door leads where)
3. **Story gates** (you can't enter region B until quest A is done)
4. **Per-room content** (props, NPCs, chests specific to each room)
5. **Tutorial sequence** (first few rooms teach mechanics)
6. **Title screen data** (game name, tagline, background mood)
7. **Ending data** (final cutscene steps, credits text)

## Priority for Implementation

1. Title screen + Game over + Ending (frames the experience)
2. Sub-areas for Alexandria (prove the pattern with 4-5 rooms)
3. Update GDD prompt to generate regions with sub-areas
4. Generate sub-areas for all 12 current locations
5. Story gating (lock regions behind quest completion)
6. Tutorial in first area
