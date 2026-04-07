# Game Design & Level Design for RPGs

## Part 1: Essential Game Design Knowledge

### The Must-Read Books
1. **"The Art of Game Design: A Book of Lenses" by Jesse Schell** — THE gold standard. 100+ "lenses" (perspectives) for analyzing game design. Covers player psychology, mechanics, narrative, aesthetics.
2. **"Level Up! The Guide to Great Video Game Design" by Scott Rogers** — Practical, hands-on approach to game design with focus on level design.
3. **"A Theory of Fun for Game Design" by Raph Koster** — Why games are fun, how learning = fun, when games stop being fun.

### The Most Important Game Design Concepts

#### 1. The MDA Framework
```
Mechanics → Dynamics → Aesthetics

Mechanics:  The rules (HP, damage formula, ATB gauge)
Dynamics:   What happens when players interact with mechanics (strategy emerges)
Aesthetics: How it FEELS to the player (excitement, discovery, narrative)

We build Mechanics. Players experience Aesthetics.
Dynamics are the bridge — they emerge from Mechanics.
```

#### 2. Flow State (Csikszentmihalyi)
```
              Anxiety (too hard)
             /
  Difficulty |  ★ FLOW ZONE ★
             |  (challenge matches skill)
             \
              Boredom (too easy)

              Skill Level →

RPG application:
- Early enemies: easy, teach mechanics
- Mid enemies: challenging, require strategy
- Bosses: peak difficulty, require mastery
- After boss: brief easy section (reward/rest)
```

#### 3. Player Motivation (Bartle Types)
| Type | Wants | RPG feature |
|------|-------|-------------|
| Achiever | Complete everything | Quests, achievements, 100% |
| Explorer | Discover secrets | Hidden chests, optional areas |
| Socializer | Interact with characters | Rich NPC dialogue, party bonds |
| Killer | Master combat | Boss fights, optimal builds |

Yume should generate content for ALL four types.

---

## Part 2: Level Design for 2D RPGs

### The Level Design Process
```
1. Define Purpose    → What is this location FOR? (story beat, shop, dungeon, rest)
2. Sketch Layout     → Top-down map with rooms, paths, key positions
3. Place Landmarks   → Distinctive elements that orient the player
4. Add Encounters    → Enemies, puzzles, NPCs at appropriate spots
5. Hide Rewards      → Chests off the main path, secrets for explorers
6. Test Flow         → Walk through it. Is it boring? Confusing? Too long?
```

### 6 Level Design Patterns (applicable to 2D RPGs)

#### 1. Guidance
Lead the player without telling them where to go.
```
Methods:
- NPCs facing toward the objective
- Wider path toward the main route
- Light/color drawing eye toward goal
- "Breadcrumb" items along the path

In Yume: quest NPCs positioned further from entrance than ambient NPCs
```

#### 2. Safe Zones
Areas with no threats where player can prepare.
```
RPG examples:
- Towns (no random encounters)
- Save points before boss rooms
- Inn/shop near dungeon entrance

In Yume: towns are always safe. Place save crystal before boss areas.
```

#### 3. Foreshadowing
Show upcoming challenges before the player faces them.
```
RPG examples:
- NPC warns "the forest is dangerous at night"
- See boss silhouette before fighting it
- Find a locked door early, get key later

In Yume: ambient NPC dialogue hints at what's ahead
```

#### 4. Layering
Introduce complexity gradually.
```
RPG examples:
- First dungeon: just enemies
- Second dungeon: enemies + simple puzzle (lever opens door)
- Third dungeon: enemies + puzzle + environmental hazard

In Yume: early locations simple, later locations more complex
```

#### 5. Branching
Multiple paths to objectives.
```
RPG examples:
- Dungeon with 2 paths: one shorter with harder enemies, one longer with treasure
- Town with multiple NPCs to talk to (any order)

In Yume: location JSON can define multiple areas within a location
```

#### 6. Pace Breaking
Alternate intensity.
```
RPG flow:
Town (safe) → Field (light encounters) → Dungeon (hard encounters) →
Boss (peak) → Cutscene (rest) → New town (safe) → ...

In Yume: location_type determines the pace. town→field→dungeon→boss→town.
```

### JRPG Town Design Principles

A JRPG town needs:

```
1. IDENTITY
   - Unique visual feel (color, architecture style)
   - Distinctive music
   - A "thing" it's known for (Lindblum = airships, Burmecia = rain)

2. FUNCTIONAL LAYOUT
   - Inn near entrance (rest after travel)
   - Shop accessible (but not right at entrance — explore first)
   - Key story NPC deeper in town (reward for exploring)
   - Exit(s) clearly visible but at far end

3. NPCs THAT BREATHE LIFE
   - 3-5 ambient NPCs with unique dialogue
   - Dialogue changes based on story progress
   - At least one NPC gives a hint about what to do next
   - Children playing, merchants hawking, guards patrolling

4. PROPS AND DECORATION
   - Tables, chairs, barrels, crates (interior feel)
   - Trees, flowers, fountains (exterior feel)
   - Signs with text (shop signs, direction signs)
   - Lighting (warm torches in interior, sunlight exterior)

5. SECRETS
   - One hidden chest off the beaten path
   - Optional NPC with bonus dialogue
   - Visual detail that rewards careful observation
```

### JRPG Dungeon Design Principles

```
1. STRUCTURE
   Linear for first dungeon (teach the player)
   Branching for later dungeons (reward exploration)

   Simple dungeon:
   ┌────────────────────────┐
   │ Entrance               │
   │ ↓                      │
   │ Room 1 (2-3 encounters)│
   │ ↓                      │
   │ Chest (reward)         │
   │ ↓                      │
   │ Room 2 (harder enemies)│
   │ ↓          ↘           │
   │ [Shortcut] [Dead end + │
   │  back to    treasure]  │
   │  entrance]             │
   │ ↓                      │
   │ Save Point             │
   │ ↓                      │
   │ Boss Room              │
   │ ↓                      │
   │ Exit to next area      │
   └────────────────────────┘

2. PACING
   - Encounter every 15-30 seconds of walking
   - Chest every 2-3 rooms
   - Rest point (save/heal) before boss
   - Boss fight at climax

3. LENGTH
   - Early dungeons: 5-10 minutes
   - Mid dungeons: 15-20 minutes
   - Late dungeons: 20-30 minutes
   - Never more than 30 min without a save point
```

### Field/Overworld Design

```
Fields connect towns and dungeons. They should:
- Be shorter than dungeons (2-5 minutes to cross)
- Have lighter encounter rate than dungeons
- Show visual transition between biomes
- Occasionally have a chest or optional NPC
- Feel like traveling through a world, not a corridor
```

---

## Part 3: What This Means for Yume

### Current Yume Locations (what they are)
```
Flat ground + objects in a line. Every location identical layout.
No sense of space, no landmarks, no exploration, no secrets.
```

### What Yume Should Generate (per location type)

#### Town Layout
```
┌─────────────────────────────────────────────┐
│  ┌─────┐                        ┌─────┐    │
│  │ Inn │ ← near entrance        │ Shop│    │
│  └─────┘                        └─────┘    │
│                                              │
│     [NPC] [NPC]    ┌──────────┐             │
│                    │ Fountain │ ← landmark  │
│  [Player enters]   └──────────┘             │
│      here ↑                                  │
│                                              │
│  [Sign: "Welcome"]    [NPC walking around]  │
│                                              │
│            [Key story NPC] ← deeper in town │
│                                              │
│  [Hidden chest] ← off main path             │
│                                              │
│              ┌──────────────────┐            │
│              │ Exit → next area │            │
│              └──────────────────┘            │
└─────────────────────────────────────────────┘
```

#### Dungeon Layout
```
┌─────────────────────────────────────────────┐
│  [Entrance] ← from previous area            │
│      ↓                                       │
│  ┌────────────┐                              │
│  │ Room 1     │ ← 2-3 random encounters     │
│  │ [enemies]  │                              │
│  └─────┬──────┘                              │
│        ↓                                     │
│  ┌─────┴──────┐  ┌──────────┐               │
│  │ Corridor   ├──│ Dead end │               │
│  │            │  │ [Chest!] │               │
│  └─────┬──────┘  └──────────┘               │
│        ↓                                     │
│  ┌────────────┐                              │
│  │ Room 2     │ ← harder encounters         │
│  │ [enemies]  │                              │
│  └─────┬──────┘                              │
│        ↓                                     │
│  [Save Point]                                │
│        ↓                                     │
│  ┌────────────┐                              │
│  │ Boss Room  │ ← boss encounter            │
│  └─────┬──────┘                              │
│        ↓                                     │
│  [Exit] → next area                          │
└─────────────────────────────────────────────┘
```

### Implementation Plan for Yume

The location JSON needs a **layout system** — not just a list of objects, but a spatial design:

```json
{
  "id": "alexandria_castle",
  "layout": {
    "width": 800,
    "height": 600,
    "entrance": {"x": 400, "y": 550},
    "zones": [
      {"type": "open_area", "x": 400, "y": 300, "w": 600, "h": 400},
      {"type": "building", "name": "Inn", "x": 100, "y": 150, "w": 80, "h": 60},
      {"type": "building", "name": "Shop", "x": 650, "y": 150, "w": 80, "h": 60}
    ],
    "props": [
      {"type": "fountain", "x": 400, "y": 300},
      {"type": "sign", "text": "Welcome to Alexandria", "x": 350, "y": 480},
      {"type": "tree", "x": 200, "y": 350},
      {"type": "barrel", "x": 120, "y": 200}
    ],
    "npc_positions": {
      "garnet": {"x": 500, "y": 200},
      "steiner": {"x": 550, "y": 220}
    },
    "exit_positions": {
      "evil_forest": {"x": 400, "y": 20, "direction": "north"},
      "alexandria_harbor": {"x": 780, "y": 300, "direction": "east"}
    }
  }
}
```

This layout data can be:
1. Generated by the LLM (story parser creates layout based on description)
2. Generated procedurally (algorithm based on location_type)
3. Hand-designed (user provides layout)

**Recommendation:** Start with procedural generation based on location_type, then upgrade to LLM-generated layouts later.

Sources:
- [The Art of Game Design - Book of Lenses](https://gamedesigning.org/game-design-books/)
- [Level Design Patterns in 2D Games](https://www.gamedeveloper.com/design/level-design-patterns-in-2d-games)
- [The Level Design Book](https://book.leveldesignbook.com/process/overview)
- [Crafting the Perfect JRPG Town](https://www.tapnjoy.com/article/crafting-the-perfect-jrpg-town-why-theyre-more-than-safe-havens)
- [Simpler Checklist for Engaging Dungeon Maps](https://slyflourish.com/simpler_jaquay_style_maps.html)
