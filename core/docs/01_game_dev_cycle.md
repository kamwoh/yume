# Game Development Cycle — Complete Guide

## The 7 Stages

### 1. Planning / Concept
**What:** Define the game's identity — genre, core mechanic, target audience, scope.
**Deliverables:** Game Design Document (GDD), proof of concept, project roadmap.
**Yume equivalent:** User provides a story → Yume generates the GDD (characters, locations, quests, items, enemies, dialogues, progression).

### 2. Pre-Production / Prototyping
**What:** Build the smallest possible version that proves the core loop works.
**Deliverables:** Playable prototype with placeholder art, technical architecture.
**Key principle:** "Find the fun" — the core gameplay loop must be satisfying before adding anything else.
**Yume equivalent:** Generate a Godot project with colored rectangles, verify movement + interaction + transitions work.

### 3. Production
**What:** Build all game content. The longest phase.
**Sub-phases:**
- **Systems programming:** Combat, dialogue, inventory, save/load, quest tracking
- **Content creation:** All levels/maps, all NPCs, all dialogues, all items, all enemies
- **Art production:** Character sprites, backgrounds, UI elements, animations, effects
- **Audio:** Music (BGM per area), sound effects (actions, UI, ambient), voice (optional)
- **Level design:** Layout of each area, placement of NPCs/chests/enemies/transitions

**Production order (what depends on what):**
```
Core systems (movement, interaction) → must work first
     ↓
Game state (save/load, flags) → everything else depends on this
     ↓
Content systems (dialogue, inventory, quests) → can be built in parallel
     ↓
Combat → depends on character stats, items, enemy data
     ↓
Content population (all maps, all NPCs, all quests) → needs all systems working
     ↓
Art + Audio → can be done in parallel with programming, swapped in later
```

### 4. Testing / QA
**What:** Find and fix bugs, balance gameplay, polish player experience.
**Types of testing:**
- **Functional:** Does every feature work? (buttons, menus, transitions)
- **Integration:** Do systems work together? (quest + dialogue + combat)
- **Balance:** Is combat too easy/hard? Is economy fair? Is progression smooth?
- **Playtest:** Is it fun? Does the player understand what to do?
- **Regression:** Did fixing bug A break feature B?

**Key insight:** Testing should happen CONTINUOUSLY, not just at the end. Test after every phase.

### 5. Pre-Launch
**What:** Marketing, beta testing, final polish.
**Yume context:** Not relevant for v1 — we're building the engine, not shipping a product.

### 6. Launch
**What:** Release the game.
**Yume context:** For us, "launch" = the user runs `yume create` and gets a working game.

### 7. Post-Launch
**What:** Bug fixes, DLC, community support.
**Yume context:** The lesson system — each game built teaches Yume to make the next one better.

## The Core Loop (Most Important Concept)

Every game has a **core loop** — the activity the player repeats most often. For an RPG:

```
Explore → Discover (NPC/chest/event) → React (dialogue/combat/reward) → Progress → Explore again
```

The core loop MUST be fun before anything else matters. If walking around and talking to NPCs isn't satisfying, no amount of combat or quests will save the game.

## For Yume Specifically

Yume's development cycle is:
```
1. Planning:     GDD generation from story (done)
2. Pre-production: Generate Godot project with placeholders (done)
3. Production:   Build all RPG systems (in progress — phases 3-8)
4. Testing:      Test each system, then full playthrough (phase 8)
5. Polish:       Art bible → image gen → replace placeholders (future)
```

Sources:
- [7 Stages of Game Development](https://magicmedia.studio/news-insights/the-7-stages-of-the-game-development-pipeline/)
- [Indie Game Development Guide 2025](https://www.meshy.ai/blog/indie-game-development)
- [Game Development Process](https://gdkeys.com/game-development-process/)
