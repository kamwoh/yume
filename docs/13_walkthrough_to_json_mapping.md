# Walkthrough-to-JSON Mapping — Reverse-Engineering Content Density

## Purpose
Map real FF9 walkthrough chapters to our JSON schema to determine exactly what prompt instructions produce walkthrough-level content. Each section shows: walkthrough ground truth, our current data, the gap, and the prompt instruction needed.

---

## Case Study 1: Alexandria (Chapter 2) — TOWN

### What the walkthrough describes (7 sub-areas, ~27 items, 8+ NPCs, 2 mini-games):

| Sub-area | Items Found | NPCs | Events | Purpose |
|----------|-------------|------|--------|---------|
| Main Street + Statue Square | Zombie Card, Lizard Man Card, Sahagin Card, Potion (4 items, ALL hidden in environment) | None | Vivi starts here, walks south | Exploration intro |
| Pathway + Rat Kid | 2 Potions (hidden on left side) | Rat Kid (recurring story NPC) | Meet Rat Kid | Story encounter |
| Residence | 9 Gil (bed baseboard), Potion (table), Fang Card (drawers upstairs) — 3 items in 1 house | NPC sewing | Enter building, search furniture | Interior exploration |
| Noble Street | 33 Gil (bushes right), Goblin Card (bushes left) | Treno nobles (cutscene) | Noble scene plays | World-building |
| Tavern/Pub | 27 Gil (wall left), Flan Card (barrel left), Potion (barrel right) — 3 items | Bartender/patrons implied | Enter building | Interior exploration |
| Item Shop | 38 Gil (floor corner) | Shopkeeper | Shop available | Shop |
| Town Square | Phoenix Pinion, Ether (in Synthesis Shop), 3 cards from Ticketmaster — 5 items | Ticketmaster, Hippaul, Jump Rope girls, Guards | Fake ticket scene, Jump Rope mini-game | Hub + mini-game |
| Alley | None | Dante the Signmaker | Vivi trips, Rat Kid returns, dialogue choice x2 | Story progression |
| Steeple area | Eye Drops, Potion, Tent, 3 cards from bell pull — 6 items | Moogle Kupo | Bell puzzle, Mognet intro, save point | Puzzle + save |
| Rooftops | 29 Gil (chimney 1), 63 Gil (chimney 2), 92 Gil (chimney 3) — 3 items | Puck (Rat Kid) | Name Vivi, cross rooftops | Traversal + story |
| Theater | Prizes: Ether/Elixir/Silk Shirt/Moonstone + up to 10,000 Gil | King Leo, Zeneros, Blank | Boss battle (scripted), Sword Fight mini-game | Boss + mini-game |

**Totals: 11 sub-areas, ~27 items, 8+ named NPCs, 2 mini-games, 2 dialogue choices, 1 boss, 1 puzzle**

### What our game has for Alexandria (3-4 rooms, ~2 items, 4 NPCs):

| Room | Items | NPCs | Events |
|------|-------|------|--------|
| castle_gate | 1 Potion | 2 Guards, 1 Child, 1 Merchant | First-visit cutscene (tutorial) |
| castle_courtyard | ? | Garnet, Steiner (story NPCs) | Garnet join scene |
| castle_interior | ? | ? | ? |
| castle_garden | ? | ? | ? |

### The Gap

| Metric | Walkthrough | Our Game | Multiplier |
|--------|-------------|----------|------------|
| Sub-areas | 11 | 3-4 | 3x |
| Items/treasures | 27 | ~2 | 13x |
| Named NPCs | 8+ | 4 | 2x |
| Hidden items | 20+ (in bushes/barrels/chimneys/drawers/beds) | 0 | infinity |
| Dialogue choices | 2 | 0 | missing |
| Mini-games | 2 | 0 | missing |
| Shops | 2 (Item + Synthesis) | 0 | missing |
| Save points | 1 (Moogle) | 0 | missing |
| Puzzles | 1 (bell pull) | 0 | missing |

---

## Case Study 2: Evil Forest (Chapter 4) — DUNGEON

### What the walkthrough describes (~15 sub-areas, 10+ items, 4 bosses, 1 shop, steal lists):

| Sub-area | Items | Bosses | Events |
|----------|-------|--------|--------|
| Crash Site | Phoenix Down | — | ATE scenes, Moogle save |
| Trail | — | — | Random encounters, equip tutorial |
| Prison Cage area | — | Prison Cage x2 (HP:513, steals: Broadsword, Leather Wrist) | Trance tutorial, Garnet/Vivi trapped |
| Prima Vista Bridge | Bronze Gloves | — | 3 ATE scenes |
| Bottom Floor | Wrist | — | — |
| Cabin | Ether, 116 Gil (hidden in bed sheets) | — | Talk to Vivi, story branch |
| Hallway room | Ether | — | — |
| Cargo Room | Rubber Helm (hidden) | — | — |
| South Room | Leather Hat | — | — |
| Baku's Room | Potion | Baku (HP:202, steals: Hi-Potion, Iron Sword) | Boss fight |
| Steiner's Room | Ether | — | Steiner joins party |
| Exit Hallway | Blank's Medicine (key item) | — | Cinna shop, Moogle letter |
| Forest (random encounters) | — | — | ATE "Orchestra in the Forest", leveling area |
| Spring | — | — | Moogle save, Mognet letter delivery, HP/MP heal, steal Tents from Dendrobium |
| Plant Brain area | — | Plant Brain (HP:916, steals: Eye Drops, Iron Helm) | Blank joins mid-battle |
| Chase scene | — | Plant Spiders (mandatory) | De-equip Blank before he leaves, escape cinematics |

**Totals: ~16 sub-areas, 10+ items, 4 bosses with steal lists, 1 shop, 2 save points, 1 healing spring, 4 ATE scenes**

### What our game has for Evil Forest (4 rooms, 2 items, 0 bosses):

| Room | Items | Bosses | Events |
|------|-------|--------|--------|
| evil_forest_edge | ? | — | ? |
| evil_forest_path | 0 | — | 1-line narration |
| evil_forest_clearing | 2 (Ether, Leather Hat) | — | 2-line cutscene |
| evil_forest_deep | ? | — | ? |

### The Gap

| Metric | Walkthrough | Our Game | Multiplier |
|--------|-------------|----------|------------|
| Sub-areas | 16 | 4 | 4x |
| Items/equipment | 10+ (incl. Bronze Gloves, Rubber Helm, etc.) | 2 | 5x |
| Bosses | 4 (with steal lists, HP, tactics) | 0 | missing entirely |
| Steal lists | 6 items across 3 bosses | 0 | missing entirely |
| Shop | 1 (Cinna) | 0 | missing |
| Save points | 2 (Moogles) | 0 | missing |
| Healing spots | 1 (spring) | 0 | missing |
| ATE/optional scenes | 4 | 0 | missing |
| Party changes | Blank joins/leaves, Steiner joins | 0 | missing |
| Hidden items | 2 (Gil in bed, Rubber Helm) | 1 | close |
| Enemy variety | Fangs, Goblins, Dendrobium, Plant Spiders, Prison Cage | Fang + Goblin only | 2.5x |

---

## What This Tells Us About Prompt Instructions

### Current prompt produces:
```
For each room: 1 description, 3-4 areas, 5-8 props, 0-2 treasures, 0-4 ambient NPCs with 1 line, 0-1 on_enter events
```

### Prompt MUST produce:
```
For each room:
- 1 rich description (2-3 sentences, specific sensory details)
- 3-5 layout areas with distinct purpose
- 8-12 props (some interactive, some environmental)
- 3-6 treasures (mix of visible and hidden)
  - Hidden items MUST be in specific props: "in the barrel", "behind the bookshelf", "in the chimney"
  - Include Gil finds (small amounts: 9-92)
  - Include equipment/cards/consumables
- 2-5 ambient NPCs with personality dialogue (not generic)
  - Each NPC needs 3 quest-state dialogue variants
- 0-2 story NPCs with multi-line dialogue sequences
- 1+ on_enter events (cutscene, narration, or party dialogue)
- For DUNGEONS specifically:
  - Boss encounter with HP, steal list, tactics note
  - Save point (Moogle NPC)
  - At least 1 equipment treasure (not just Potions)
  - Enemy variety (2-3 unique types per dungeon)
  - Optional side paths with extra treasure
- For TOWNS specifically:
  - Shop NPC (items appropriate to story point)
  - 1-2 interactive buildings with interior items
  - Story NPCs that advance or react to the plot
  - World-building NPCs (gossip, foreshadowing, humor)
  - Optional mini-game or puzzle reference
```

---

## Key Design Patterns Extracted

### 1. "Hidden Item Density" Pattern
Real FF9 hides 3-6 items per screen in environmental props. The walkthrough literally says:
- "Check the left side of the room to find 9 Gil hidden near the baseboard"
- "The barrel in the bottom left corner contains a Flan Card"
- "There is a chimney you can examine to collect 29 Gil"

**Prompt instruction:** "For each room, place 2-4 hidden items inside specific props. Use language like 'hidden in [prop]' or 'inside the [container]'. Include small Gil amounts (9-92) and cards/consumables."

### 2. "NPC with Personality" Pattern
Every named NPC has a distinct voice and role:
- Rat Kid: Scheming, streetwise kid who talks fast
- Dante the Signmaker: Grumpy shopkeeper who yells at Vivi
- Ticketmaster: Sympathetic, gives consolation cards
- Moogle Kupo: Tutorial NPC, explains saving

**Prompt instruction:** "Each NPC must have a NAME, a PERSONALITY TRAIT, and a FUNCTION (information, shop, quest, world-building). Dialogue should reflect their personality, not be generic."

### 3. "Steal List" Pattern
Every boss has stealable items that reward engaged players:
- Prison Cage: Broadsword (common), Leather Wrist (uncommon)
- Baku: Hi-Potion (common), Iron Sword (rare)
- Plant Brain: Eye Drops (common), Iron Helm (rare)

**Prompt instruction:** "Every boss must have 2-3 stealable items with rarity tiers (common/uncommon/rare). Include at least 1 equipment piece as a rare steal. This rewards players who use Steal instead of just attacking."

### 4. "Pacing Rhythm" Pattern
Evil Forest chapter follows: explore → boss → explore (safe) → boss → shop → explore → save → boss → chase
Town Square chapter follows: explore → discover → shop → mini-game → story choice → puzzle → traversal → boss

**Prompt instruction:** "Each region must follow a pacing curve: intro (safe) → exploration (items/NPCs) → rising tension (harder encounters) → climax (boss) → resolution (story scene/rest). Towns add: shops, mini-games, NPC interaction before departure."

### 5. "Quest-State World" Pattern
NPCs and environments change based on story progress. The walkthrough explicitly notes returning to areas:
- "Return to the Alley once more to find Rat Kid again"
- Steeple items only accessible after specific story flag

**Prompt instruction:** "NPCs must have 3 dialogue states keyed to quest progress. Items/areas can be locked behind story flags. The world must REACT to the player's progress."

---

## Revised Prompt Template (v2)

Based on this analysis, here's what Pass 4 (Location Generation) must instruct:

```
For the location "{location_name}" ({location_type}):

ROOM DATA:
- Write a 2-3 sentence description with specific sensory details (sounds, smells, light)
- Define 3-5 layout areas, each with a distinct name and purpose
- Place 8-12 props. At least 3 must be containers (barrel, chest, bookshelf, drawer)

TREASURES (critical — this is what makes exploration rewarding):
- Place 3-6 treasures per room
- At least 2 must be HIDDEN inside specific props ("hidden": true, describe location in prop label)
- Include a mix: Gil (small: 9-92), consumables (Potion, Ether), equipment, cards/key items
- Place valuable items in harder-to-reach or less-obvious locations
- At least 1 treasure should be equipment appropriate to the current act

NPCs:
- Place 2-5 ambient NPCs with NAME, personality, and meaningful dialogue
- Each ambient NPC needs 3 dialogue variants keyed to quest state:
  - "early": before major event
  - "mid": after regional boss defeated
  - "late": after act completion
- For story-critical rooms: include 1-2 story NPCs with 5-10 line dialogue sequences

ENCOUNTERS (dungeons only):
- Define 2-3 unique enemy types appropriate to the biome
- Boss encounters must include: HP, level, steal list (2-3 items with rarity), drop table, tactical note
- At least 1 enemy should have a status-inflicting ability

EVENTS:
- First-visit cutscene (3-8 steps, not just narration — include party dialogue)
- At least 1 conditional event tied to quest progress
- For towns: include at least 1 dialogue choice

SERVICES:
- Towns: at least 1 shop NPC with act-appropriate inventory
- Dungeons: 1 save point (Moogle) and optionally 1 healing spring
```

---

## Comparison: Current vs Target JSON Size

| Room | Current JSON | Target JSON | Content Multiplier |
|------|-------------|-------------|-------------------|
| evil_forest_path | 65 lines (0 treasures, 0 NPCs) | ~180 lines (4 treasures, 2 NPCs, boss, save point) | 2.8x |
| evil_forest_clearing | 67 lines (2 treasures, 0 NPCs) | ~150 lines (4 treasures, 1 NPC, hidden items) | 2.2x |
| alexandria_castle_gate | 112 lines (1 treasure, 4 NPCs) | ~200 lines (5 treasures, 6 NPCs w/ quest-state, shop) | 1.8x |

Average current room: ~80 lines of JSON
Average target room: ~170 lines of JSON
**Content needs to roughly double per room, and MANY rooms need new content from scratch.**
