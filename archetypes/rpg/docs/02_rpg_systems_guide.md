# RPG Game Systems — Technical Guide

## The Three Pillars of RPGs
1. **Exploration** — moving through the world, discovering things
2. **Combat** — fighting enemies, using abilities, gaining rewards
3. **Questing** — following story objectives, making progress

Everything else (inventory, dialogue, shops, save/load) serves these three pillars.

---

## 1. Character System

### Stats
Every character (party + enemies) has numerical stats:
| Stat | What it affects |
|------|----------------|
| HP (Hit Points) | Health — 0 = dead |
| MP (Magic Points) | Resource for spells/abilities |
| STR (Strength) | Physical damage dealt |
| MAG (Magic) | Magical damage dealt |
| DEF (Defense) | Physical damage reduced |
| SPR (Spirit) | Magical damage reduced |
| SPD (Speed) | Turn order / ATB fill rate |
| LVL (Level) | Overall power tier |
| XP (Experience) | Progress toward next level |

### Level Up Formula
```
XP needed = base * growth_rate ^ (level - 1)
Example: 100 * 1.5^(level-1)
  Level 1→2: 100 XP
  Level 5→6: 506 XP
  Level 10→11: 3,844 XP
```

On level up: all stats increase by class-appropriate amounts. HP/MP fully restored.

### Character Classes (RPG archetypes)
| Class | High stats | Low stats | Role |
|-------|-----------|-----------|------|
| Fighter/Knight | STR, DEF, HP | MAG, SPD | Tank, physical damage |
| Mage | MAG, MP | HP, DEF | Magical damage, AoE |
| Thief/Rogue | SPD, STR | HP, DEF | Fast, steal, dodge |
| Healer/White Mage | MAG, SPR, MP | STR, SPD | Healing, buffs |
| Summoner | MAG, MP | STR, DEF | Powerful summon spells |

---

## 2. Combat System — Active Time Battle (ATB)

### How ATB Works (FF4-FF9 style)
```
Each combatant has an ATB gauge (0% → 100%):

  Fill rate = base_rate * (speed / average_speed)

  When gauge hits 100%:
    - Player character: show command menu
    - Enemy: AI picks action

  After action executes:
    - Reset gauge to 0%
    - Start filling again
```

### Battle Flow
```
1. Battle starts
   - Party enters from left, enemies from right
   - All ATB gauges start at 0 (or random 0-50%)

2. ATB gauges fill in real-time
   - Faster characters fill faster
   - Can optionally pause when menu is open ("Wait" mode)

3. Character's turn (gauge full)
   - PLAYER: show command menu
     - Attack → select enemy target → physical damage
     - Magic → select spell → select target → magical damage (costs MP)
     - Item → select item → select target → use item effect
     - Defend → reduce incoming damage by 50% until next turn
     - Flee → 50% chance to escape (not bosses)
   - ENEMY: AI decides
     - Basic enemies: attack random party member
     - Bosses: use abilities at HP thresholds

4. Damage Calculation
   Physical: damage = (ATK * 2) - DEF, ± 15% variance, minimum 1
   Magical:  damage = (MAG + spell_power) * 2 - SPR, ± 10% variance
   Healing:  heal = (MAG * heal_power) / 10

   Element multiplier:
     - Weak: 2.0x
     - Resist: 0.5x
     - Neutral: 1.0x

5. Victory condition: all enemies HP = 0
   - Award XP (split among alive party members)
   - Award Gil
   - Roll item drops (each enemy has drop table with probabilities)
   - Return to exploration

6. Defeat condition: all party HP = 0
   - Game Over screen
   - Options: Retry (reload last save) / Title Screen
```

### Battle UI Layout
```
┌─────────────────────────────────────────────┐
│ Battle Background (location-specific)        │
│                                              │
│  [Party]              [Enemies]              │
│  Zidane ████░ ATB     Fang (HP: ███░░)      │
│  Vivi   ██░░░ ATB     Goblin (HP: █░░░░)    │
│  Steiner█████ ATB                            │
│                                              │
├─────────────────────────────────────────────┤
│ ┌─────────┐  Zidane's Turn                  │
│ │ Attack  │  HP: 105/105                    │
│ │ Magic   │  MP: 35/35                      │
│ │ Item    │                                  │
│ │ Defend  │                                  │
│ │ Flee    │                                  │
│ └─────────┘                                  │
└─────────────────────────────────────────────┘
```

---

## 3. Dialogue System

### Components
- **Dialogue trees:** branching conversations with choices
- **Speaker identification:** name + portrait
- **Typewriter effect:** text appears letter by letter
- **Choices:** player selects response → different dialogue branch
- **Flags:** dialogue can set/check game state flags
- **Triggers:** interact (press button near NPC) or auto (on enter area)

### Data Format
```json
{
  "id": "garnet_intro",
  "location_id": "alexandria_castle",
  "trigger_condition": "auto",
  "sets_flag": "garnet_joined",
  "lines": [
    {"speaker": "Zidane", "text": "Well well...", "expression": "happy"},
    {"speaker": "Garnet", "text": "Please take me away...", "expression": "sad"}
  ],
  "branches": [
    {"prompt": "Help her", "next_node": "help_garnet"},
    {"prompt": "Refuse", "next_node": "refuse_garnet"}
  ]
}
```

### Dialogue State Machine
```
IDLE → (trigger) → SHOWING_LINE → (space) →
  if typing: finish typing → wait for space
  if done typing:
    if more lines: next line → SHOWING_LINE
    if branches: SHOWING_CHOICES → (select) → jump to node
    if no more: END → set flag → unfreeze player
```

---

## 4. Inventory System

### Item Types
| Type | Properties | Usage |
|------|-----------|-------|
| Consumable | heal_amount, buff | Use from menu or battle |
| Weapon | stat_modifiers (STR+5) | Equip on character |
| Armor | stat_modifiers (DEF+8) | Equip on character |
| Accessory | stat_modifiers, special effects | Equip on character |
| Key Item | quest flag | Cannot sell, triggers events |

### Equipment System
```
Character has 3 equipment slots:
  - Weapon → adds to STR (and sometimes MAG, SPD)
  - Armor → adds to DEF (and sometimes SPR, HP)
  - Accessory → various bonuses

Effective stat = base_stat + equipment_bonus + buff_bonus

When equipping:
  1. Remove old equipment → return to inventory
  2. Apply new equipment → remove from inventory
  3. Recalculate character stats
```

### Economy
```
Tier 0 (start):     Potion (50g), basic weapon (100-300g)
Tier 1 (early):     Hi-Potion (200g), mid weapon (500-800g)
Tier 2 (mid):       Ether (500g), good weapon (1000-1500g)
Tier 3 (late):      Elixir (1000g), best weapon (2000-5000g)

Enemy Gil drops should allow buying next tier between areas
Gil income = (enemies killed per area) × (average drop) ≈ 1.5x cost of next weapon
```

---

## 5. Quest System

### Quest Types
- **Main quests:** drive the story, must complete to progress
- **Side quests:** optional, provide rewards and world-building

### Quest Structure
```json
{
  "id": "kidnap_princess",
  "name": "The Princess and the Thieves",
  "quest_type": "main",
  "steps": [
    {"trigger": "reach:alexandria_castle", "description": "Enter Alexandria Castle"},
    {"trigger": "talk_to:garnet", "description": "Find Princess Garnet"},
    {"trigger": "reach:evil_forest", "description": "Escape through Evil Forest"}
  ],
  "prerequisite": null,
  "rewards": ["potion", "potion"],
  "xp_reward": 50,
  "gil_reward": 100
}
```

### Quest Chain
```
Quest A (no prerequisite) → complete → Quest B (prerequisite: A) → complete → Quest C
```
When A completes, the system scans all quests and auto-starts any whose prerequisite just became met.

### Trigger Types
| Trigger | When it fires |
|---------|--------------|
| reach:location_id | Player enters a location |
| talk_to:character_id | Player talks to an NPC (or dialogue with that character ends) |
| defeat:enemy_id | Player defeats a boss/enemy in combat |
| collect:item_id | Player obtains a specific item |

---

## 6. Save/Load System

### What to Save
```json
{
  "location": "evil_forest",
  "player_position": [120, 80],
  "gil": 350,
  "flags": {"garnet_joined": true, "visited_dali": true},
  "party": [
    {"id": "zidane", "level": 5, "hp": 95, "mp": 30, "xp": 230,
     "weapon": "mythril_dagger", "armor": "leather_vest", "accessory": null}
  ],
  "inventory": [{"id": "potion", "qty": 3}, {"id": "ether", "qty": 1}],
  "active_quests": {"kidnap_princess": {"current_step": 2}},
  "completed_quests": ["through_the_ice"],
  "opened_chests": ["alexandria_chest_1", "evil_forest_chest_1"]
}
```

### Save Slots
Typically 3 slots. Player chooses slot from menu. JSON file per slot.

---

## 7. Scene/Location Management

### Location Types and What They Contain
| Type | Contains | Encounters? | Shop? |
|------|---------|-------------|-------|
| Town | NPCs, shops, inn, save point, chests | No | Yes |
| Dungeon | Monsters, chests, puzzles, boss at end | Yes (random) | No |
| Field | Travel between areas, some monsters | Yes (random) | No |
| Special | Story events, unique mechanics | Maybe | No |

### Location Transition
```
Player walks to exit trigger →
  fade out (0.3s) →
  destroy current location objects →
  load new location JSON →
  spawn new objects →
  position player at entrance →
  fade in (0.3s)
```

---

## 8. Game State Machine

### Overall Game States
```
TITLE_SCREEN → (New Game) → EXPLORATION → (encounter) → COMBAT
                                        → (menu) → MENU → (close) → EXPLORATION
                                        → (cutscene) → CUTSCENE → EXPLORATION
             → (Continue) → LOAD_SAVE → EXPLORATION
COMBAT → (victory) → EXPLORATION
COMBAT → (defeat) → GAME_OVER → (retry) → LOAD_SAVE
                              → (title) → TITLE_SCREEN
```

### Player Can Always:
- Move (during EXPLORATION)
- Open menu (during EXPLORATION, not during DIALOGUE or COMBAT)
- Interact with NPCs/chests (during EXPLORATION)
- Advance dialogue (during DIALOGUE)
- Select commands (during COMBAT, when it's their turn)

Sources:
- [Active Time Battle - Wikipedia](https://en.wikipedia.org/wiki/Active_Time_Battle)
- [Final Fantasy Battle Systems](https://finalfantasy.fandom.com/wiki/Battle_system)
- [Godot Open RPG](https://github.com/gdquest-demos/godot-open-rpg)
- [RPG Game Design Fundamentals](https://gamedesignskills.com/game-design/rpg/)
