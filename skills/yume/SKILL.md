---
name: yume
description: "Game development framework — React for RPGs. Scaffold projects, generate game content from stories, test games automatically. Claude is the brain, Yume Python tools are the hands."
user-invocable: true
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion"
---

# Yume (夢) — Game Development Framework

Yume is a knowledge framework for building RPG games in Godot 4. Claude is the brain that orchestrates everything. Yume provides the tools, templates, prompts, and tests.

## Framework Location
- **Yume root:** `~/yume/`
- **Templates:** `~/yume/archetypes/rpg/templates/godot/` (real .gd files)
- **Prompts:** `~/yume/archetypes/rpg/prompts/` (instructions for what JSON to generate)
- **Docs:** `~/yume/core/docs/` + `~/yume/archetypes/rpg/docs/` + `~/yume/docs/`
- **Tools:** `~/yume/tools/` (validators, test suite, playthrough simulator)
- **Lessons:** `~/.yume/lessons/` (50+ known pitfalls)
- **CLAUDE.md:** `~/yume/CLAUDE.md` (full framework guide)
- **FF9 reference:** `/mnt/c/Users/kamwoh/Documents/Projects/Godot/FF9/`

## How It Works

```
Claude (brain) orchestrates everything:
  ├── reads prompts     → knows WHAT to generate
  ├── writes JSON files → creates game data
  ├── calls yume init   → scaffolds Godot project
  ├── calls yume test   → verifies everything works
  ├── reads test output → fixes issues automatically
  └── calls yume learn  → saves lessons for next time
```

All game content is JSON. The Godot engine reads JSON at runtime. Claude generates the JSON.

## Commands

### `/yume create` — Create a new game from scratch

**Full flow:**
1. Ask user: "What's your game about? Tell me the story."
2. Scaffold: `source ~/yume/venv/bin/activate && yume init <game-name>`
3. Read the prompts and generate data in this order:
   - Read `pass1_structure.md` → write `characters.json`, `progression.json`, `meta.json`
   - Read `pass2_content.md` → write `items.json`, `enemies.json`, `quests.json`, `dialogues.json`
   - Read `pass3_balance.md` → review and fix stat balance across all files
   - Read `pass0_game_state.md` → write `game_state.json` (THE story flow — phases, triggers, cutscenes)
   - Read `pass4_locations.md` → write `locations/*.json` (visual only — layout, props, treasures, NPCs)
4. Test: `source ~/yume/venv/bin/activate && yume test <game-path>`
5. Read test output → fix any failures → re-test (up to 3 rounds)
6. Tell user: "Done! Open `<game-path>` in Godot 4 → F5"

**Key: game_state.json controls ALL story logic. Location JSONs are visual only.**

### `/yume test` — Test an existing game

```bash
source ~/yume/venv/bin/activate
yume test <game-path>              # all layers
yume test <game-path> -l data      # JSON integrity only
yume test <game-path> -l systems   # game logic only
yume test <game-path> -l playthrough  # simulate full game
```

**4 test layers:**
| Layer | What | Tool |
|-------|------|------|
| data | JSON parse, exit refs, reachability, content density | `validate_game_data.py` |
| systems | Party joins, quest chain, damage formulas, shops | `test_game_systems.py` |
| playthrough | Walks every room, fights bosses, verifies checkpoints | `simulate_playthrough.py` |
| godot | Spawn structure, battle math via Godot headless | `tests/test_runner.gd` |

### `/yume fix` — Fix bugs in an existing game

1. Read the error (user describes it or provides log)
2. Find the root cause in JSON data or GDScript
3. Fix it
4. Run `yume test` to verify
5. Save lesson: `source ~/yume/venv/bin/activate && yume learn -p "problem" -f "fix" -s "system"`
6. If fix was in engine scripts: sync back to `~/yume/archetypes/rpg/templates/godot/`

### `/yume content` — Generate more content for existing game

1. Read what exists (data/*.json)
2. Read what's needed (test output shows gaps)
3. Generate missing content following pass4_locations.md density requirements
4. Run `yume test` to verify

### `/yume learn` — Record a lesson

```bash
source ~/yume/venv/bin/activate && yume learn -p "what went wrong" -f "how it was fixed" -s "system_area"
```

## Key Architecture

- **Runtime data-driven:** ONE main scene, LocationManager loads from JSON at runtime
- **No editor scripting:** Everything is code + data, no Godot editor setup
- **Autoloads:** GameManager, LocationManager, DialogueManager, PartyManager, InventoryManager, QuestManager, BattleManager, SaveManager, AudioManager, CutsceneManager, UITheme
- **Story gating:** Exits can have `requires_flag` + `locked_message` — engine checks flags before transition

## Content Density Requirements (from walkthrough analysis)

Every room must have:
- 3-6 treasures (half hidden in props: barrels, bookshelves, chimneys)
- 2-5 ambient NPCs with `dialogue_states` (early/mid/late)
- On-enter events with party dialogue (not just narration)
- Bosses with `steal_list` (2-3 items with rarity tiers)
- Moogle save point before every boss
- Shop at every region entrance

## Design Docs

| Doc | What |
|-----|------|
| 01-04 | Game dev cycle, RPG systems, Godot ecosystem, level design |
| 05 | Yume framework vision |
| 06-08 | Complete game analysis, design reviews, unified plan |
| 11 | FF9 walkthrough analysis (ground truth benchmarks) |
| 12 | Design team review (3 expert agents) |
| 13 | Walkthrough-to-JSON mapping (density spec) |
| 14 | Automated testing plan |

## Rules

1. **Test after every change:** `yume test` must pass before telling user "done"
2. **Save lessons after debugging:** `yume learn` after every fix
3. **Sync engine fixes:** FF9 project → `~/yume/archetypes/rpg/templates/godot/`
4. **Read prompts before generating:** prompts define quality standards
5. **Verify with playthrough.json:** checkpoints define the expected experience
6. **GDScript quirks:** no duplicate var names, explicit types for `:=` with max()/get(), process_mode=ALWAYS for paused UI
