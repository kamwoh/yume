# Design Team Review — What Makes Our FF9 Prototype Feel Incomplete

## Date: 2026-04-05
## Reviewers: Game Designer, Story Designer, Level Designer (AI agents)
## Scope: 52-room FF9 prototype vs. real FF9 walkthrough ground truth (45 chapters, 492KB)

---

## Executive Summary

**The engine is done. The content is a skeleton.**

All three experts converge on one conclusion: the Yume RPG engine (ATB combat, dialogue, quests, cutscenes, shops, save/load, party joins, visual helpers) is functionally complete. The problem is **content density** — our 52 rooms have the structure of a game but not the flesh. A real JRPG room has 3-6 hidden treasures, 3-5 NPCs with personality, quest-state dialogue, environmental storytelling, and a clear purpose. Ours average 1 treasure, 2 ambient NPCs with single-line dialogue, and often no story events.

**The fix is 100% data authoring.** Zero engine rewrites needed.

---

## The Three Diagnoses

### Game Designer: "Tech demo, not a game"
The gameplay loop is hollow. Walk → walk → fight (same enemy) → walk → boss. No reward curve, no equipment progression, no meaningful choices in combat.

- **8 bosses** across the entire game vs. **78 in real FF9** (9.75x gap)
- **3 abilities per character** vs. **15-30** in real FF9
- **Enemies have 0-1 abilities** — dominant strategy is always "Vivi hits weakness, everyone else presses Attack"
- **No story gating** — player can walk to Crystal World at level 1
- **Level curve 1→5→15→25** vs. real FF9's **1→15→35→60+**
- **Sparse drops** — 25% chance of Potion. Real FF9 has steal lists, rare drops, boss-specific loot

**Critical insight:** "The minute-to-minute experience is: walk through colored rectangles, fight Fangs that die in 2 hits, read a cutscene, walk more. There's no tension curve, no 'I need to buy better gear before this dungeon,' no 'what can I steal from this boss?'"

### Story Designer: "Tour, not a journey"
The story is told *at* the player, not experienced *with* them. Cutscenes explain plot, but the party never reacts, grows, or questions together.

- **22 of 52 rooms (42%) are completely silent** — no NPCs, no dialogue, no events
- **11 dialogue sequences** for 52 rooms vs. **150+** in real FF9
- **Character arcs told in 1 scene** each vs. **10+ scenes** weaving across the game
- **Zero tonal variety** — relentless exposition pacing. No humor → tension → grief → hope rhythm
- **No POV switches** — always Zidane. Real FF9 switches between Zidane, Steiner, Garnet, Vivi
- **No player choices** — real FF9 has dialogue options, ATE (Active Time Events), mini-games

**Critical insight:** "The player has no reason to CARE about what happens next. Vivi's 'Am I just a weapon?' scene should be devastating — but it's the only Vivi scene. You can't build emotional investment in 4 lines of dialogue. The game needs 40+ quiet moments (party banter, NPC reactions, environmental details) between the 6 big plot moments."

### Level Designer: "Corridors, not places"
Rooms are connected in a chain but don't feel like real locations. A castle feels the same as a forest feels the same as an alien world.

- **Treasure density: 0-1 per room** vs. real FF9's **3-6 hidden items** per screen. Alexandria chapter alone has 20+ items.
- **Room flow is mostly linear** — few branches, no backtracking, no locked doors, no shortcuts
- **Prop variety is limited** — ~10 prop types repeated across all 52 rooms
- **Many rooms exist just to walk through** — no clear purpose (shop? puzzle? boss arena? story scene?)
- **No hidden items** — "hidden" field rarely used. Real FF9 has items in walls, chimneys, barrels, bushes
- **Shops are sparse** — real FF9 places shops at the start of each new region for gear progression
- **No dungeon design** — no dead ends, optional paths, save points, or healing spots

**Critical insight:** "Exploration is pointless. The player walks in one direction until they hit the next exit. There's nothing to discover, nothing to miss, nothing to come back for. A good JRPG room rewards curiosity — check behind that waterfall, talk to that weird NPC, examine that bookshelf. Our rooms reward only forward movement."

---

## Unified Gap Analysis

| Dimension | Prototype Now | Real FF9 | Gap | Severity |
|-----------|--------------|----------|-----|----------|
| Rooms | 52 | 215 | 4x (OK for Act 1 demo) | 2/5 |
| Bosses | 8 | 78 | 9.75x | 5/5 |
| Treasures/room | 0-1 | 3-6 | 5x | 4/5 |
| Dialogue sequences | 11 | 150+ | 14x | 5/5 |
| Ambient NPC lines | ~25 single-line | Hundreds w/ quest state | 10x+ | 4/5 |
| Silent rooms | 22 (42%) | ~0 | Critical | 5/5 |
| Character abilities | 3 per char | 15-30 per char | 5-10x | 4/5 |
| Enemy types | ~8 | 100+ | 12x | 3/5 |
| Enemy abilities | 0-1 | 3-5 w/ status effects | 4x | 4/5 |
| Equipment items | ~15 | 200+ | 13x | 3/5 |
| Side quests | 0 | 20+ | Missing entirely | 3/5 |
| Mini-games | 0 | 5+ (Tetra Master, Chocobo, etc.) | Missing entirely | 2/5 |
| Story gating | None | Full gate system | Critical | 5/5 |
| Emotional beat variety | Exposition only | Humor/tension/grief/hope | Missing entirely | 5/5 |
| Hidden/discoverable items | 0 | 50+ | Missing entirely | 4/5 |
| NPC quest-state dialogue | 1 state | 3-5 states | Missing | 4/5 |
| Shop placement | Sparse | Every region entry | Weak | 3/5 |

---

## Priority Action Plan (Convergence of All 3 Experts)

### Tier 1: CRITICAL (Makes it feel like a game, not a demo)

**1. Story Gating** [Severity: 5/5, Scope: M]
- Exits to later regions require quest flags
- Player cannot walk to Crystal World at level 1
- Progression.json defines the unlock chain
- *All 3 experts flagged this as broken*

**2. Fill Silent Rooms with Life** [Severity: 5/5, Scope: L]
- 22 rooms have zero NPCs/dialogue/events
- Add 2-3 ambient NPCs per room minimum
- Add at least 1 on_enter_event or story NPC interaction per region
- *Story Designer: "42% of your game is empty hallways"*

**3. Triple Treasure Density** [Severity: 4/5, Scope: M]
- Every room should have 2-4 treasures (mix of visible and hidden)
- Hidden items in environmental props (barrels, bookshelves, chimneys, bushes)
- Treasures reward exploration off the main path
- *Level Designer: "Exploration is pointless without discovery"*

**4. Expand Dialogue to 40+ Sequences** [Severity: 5/5, Scope: L]
- Expand existing 11 dialogues to 10-20 lines each
- Add 30+ new dialogues: party banter, NPC reactions, quiet character moments
- Key missing scenes: Steiner's loyalty conflict, Garnet's growth, Freya's grief, "You're Not Alone"
- Add emotional beat variety: humor between Zidane/Steiner, Vivi's wonder, Garnet's determination
- *Story Designer: "You can't build emotional investment in 4 lines"*

**5. NPC Quest-State Dialogue** [Severity: 4/5, Scope: M]
- Every ambient NPC needs 3 dialogue states (early/mid/late game minimum)
- "I wanna see the play!" should become "What happened to the castle?" after Act 1
- This single change makes the world feel alive and responsive
- *Game Designer: "NPCs that never react to the plot make the world dead"*

### Tier 2: IMPORTANT (Makes it feel like a GOOD game)

**6. Enemy Variety + Abilities** [Severity: 4/5, Scope: M]
- Each region needs 2-3 unique enemy types (not Fangs everywhere)
- Enemies need abilities: status effects (poison, sleep, slow), elemental attacks, buffs
- Boss encounters need steal lists, multi-phase patterns, unique mechanics
- *Game Designer: "Dominant strategy is always 'press Attack'. No adaptation required."*

**7. Equipment Progression Path** [Severity: 3/5, Scope: M]
- Weapon/armor tiers per act (Broadsword → Mythril Sword → Diamond Sword)
- Shops at region entrances sell next-tier gear
- Boss drops/dungeon treasures include equipment
- *Game Designer: "No 'I need better gear before this dungeon' moment"*

**8. Character Ability Depth** [Severity: 4/5, Scope: M]
- Expand from 3 to 8-10 abilities per character
- Abilities learned at level-up milestones across the full level curve
- Support abilities (status heal, buffs, party protect) not just damage
- *Game Designer: "3 abilities means zero build variety"*

**9. Room Purpose Clarity** [Severity: 3/5, Scope: S]
- Tag every room with its purpose: hub, shop, puzzle, boss_arena, story_scene, exploration, transition
- Ensure each region has a clear rhythm: arrival → explore → discover → challenge → reward
- Add save points / rest spots at natural pacing breaks
- *Level Designer: "Many rooms exist just to walk through"*

**10. Branching Paths + Secrets** [Severity: 3/5, Scope: M]
- Add optional side rooms in dungeons (dead ends with treasure/lore)
- Add "locked" exits that require key items or quest flags
- Backtracking rewards (new NPC dialogue, new treasures after story events)
- *Level Designer: "Room flow is a straight line. Zero reason to deviate."*

### Tier 3: POLISH (Makes it feel COMPLETE)

**11. Side Quests** — 5-7 optional quests (monster hunts, fetch quests, NPC stories)
**12. Boss Encounter Design** — Steal lists, weakness patterns, multi-phase fights
**13. Mini-games** — Even 1 simple card game or arena challenge adds replay value
**14. POV Switches** — Steiner interlude, Garnet solo section (already supported by engine)
**15. Ending Depth** — Final cutscene should reference player's journey, callback to key scenes

---

## The Core Realization

All three experts independently arrived at the same conclusion:

> **The engine is the easy part. The content is the product.**

Our Godot engine handles everything: ATB combat, cutscenes, dialogue trees, party management, save/load, shops, quests, visual helpers. The JSON schema supports all the features listed above WITHOUT any engine changes.

What's missing is **authored game content** — and this is exactly what Yume's prompt templates need to produce. The walkthrough data (45 chapters, 492KB) gives us the ground truth for what "complete" looks like. The gap between our data and that ground truth is the specification for our prompt engineering.

**Next step:** Use this gap analysis to reverse-engineer the prompts that would produce walkthrough-density content from a simple story description. That's the real Yume product.

---

## What This Means for Yume Prompts

Each prompt pass needs to produce:

| Pass | Must Generate | Current Output | Target Output |
|------|---------------|----------------|---------------|
| Pass 1 (Structure) | Locations, characters, plot | 12 regions, 5 chars, 6 beats | 12 regions w/ 4-5 sub-rooms each, 5+ chars w/ arcs, 20+ story beats |
| Pass 2 (Content) | Items, enemies, quests, dialogue | ~15 items, 8 enemies, 7 quests, 11 dialogues | 50+ items, 25+ enemies, 10+ quests, 40+ dialogues |
| Pass 3 (Balance) | Stats, curves, drops | Basic level curve | Per-region difficulty curve, steal lists, equipment tiers |
| Pass 4 (Locations) | Rich room data | Props + NPCs | Props + NPCs + 3-6 treasures + hidden items + quest-state dialogue + on-enter events |

The walkthrough IS the answer key. Each chapter shows exactly what density, variety, and emotional texture a room needs.
