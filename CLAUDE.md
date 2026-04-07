# Yume (夢) — Game Development Framework

You are helping build an RPG game using the Yume framework. Yume provides reusable components, knowledge, and tools for creating 2D RPGs in Godot 4.

## Quick Start

To create a new RPG game project:

```bash
pip install yume
yume init my-game
# Then open my-game/ in Godot 4.x and press F5
```

Or manually: copy `archetypes/rpg/templates/godot/` into a new Godot project, then add your game data to `data/`.

## Framework Structure

```
yume/
├── core/docs/              ← Game dev fundamentals (read first)
├── archetypes/rpg/
│   ├── templates/godot/    ← WORKING Godot project (copy this)
│   │   ├── scripts/        ← GDScript RPG engine
│   │   ├── scenes/         ← Main scene
│   │   └── project.godot   ← Godot config with autoloads
│   ├── data/examples/ff9/  ← Reference game data
│   ├── docs/               ← RPG-specific knowledge
│   ├── prompts/            ← LLM prompt templates for content generation
│   ├── schemas/            ← Data format definitions
│   └── lessons/            ← Known pitfalls and solutions
├── core/validator/         ← Post-generation project checks
├── tools/                  ← Testing & utility tools
│   ├── validate_game_data.py    ← Data integrity checker
│   ├── test_game_systems.py     ← Game system tests (party, quests, combat)
│   └── simulate_playthrough.py  ← Automated full playthrough simulation
└── examples/ff9/           ← Complete example (story + GDD + art bible)
```

## How the Engine Works

The RPG engine uses a **runtime data-driven architecture**:
- ONE main scene with a Player, Camera, UI, and LocationRoot
- **LocationManager** reads JSON from `data/locations/` and spawns everything at runtime
- ALL game content lives in `data/*.json` — characters, items, enemies, quests, dialogues
- Scene transitions = destroy old objects → load new location JSON → spawn new objects
- No editor scripting needed — just data files + the engine scripts

## Key Data Files

| File | What it defines |
|------|----------------|
| `data/characters.json` | All characters (party + NPCs + bosses) with stats, abilities |
| `data/items.json` | All items (consumables, weapons, armor, key items) |
| `data/enemies.json` | All enemies with stats, abilities, drop tables |
| `data/quests.json` | All quests with steps, triggers, rewards |
| `data/dialogues.json` | All dialogue sequences |
| `data/progression.json` | Starting party, starting location, level curve |
| `data/locations/*.json` | Rich per-location data (layout, props, NPCs, atmosphere) |

## Creating a New Game

1. **Write or generate game data** — fill in the JSON files above
2. **Use prompt templates** in `archetypes/rpg/prompts/` to generate data from a story:
   - `pass1_structure.md` — Story → characters, locations, plot
   - `pass2_content.md` — → quests, items, enemies, dialogues
   - `pass3_balance.md` — → stat balancing
   - `pass4_locations.md` — → rich location design
3. **Validate** — run `python core/validator/validator.py <project_path>`

## RPG Systems Included

| System | Script | What it does |
|--------|--------|-------------|
| Location Manager | `scripts/autoload/location_manager.gd` | Loads locations from JSON, spawns objects, handles transitions |
| Dialogue | `scripts/autoload/dialogue_manager.gd` + `scripts/ui/dialogue_ui.gd` | Typewriter text, branching choices, quest triggers |
| Party | `scripts/autoload/party_manager.gd` | Party stats, level up, XP |
| Inventory | `scripts/autoload/inventory_manager.gd` | Items, equipment, use/equip |
| Quests | `scripts/autoload/quest_manager.gd` | Quest tracking, triggers, rewards, chain progression |
| Combat | `scripts/autoload/battle_manager.gd` + `scripts/ui/battle_ui.gd` | ATB battle system, damage calc, enemy AI |
| Shops | `scripts/ui/shop_ui.gd` | Buy/sell with themed UI |
| Save/Load | `scripts/autoload/save_manager.gd` | 3 save slots, full state persistence |
| UI Theme | `scripts/autoload/ui_theme.gd` | Consistent styled panels, colors, fonts |
| HUD | `scripts/ui/hud.gd` | Location name, gil, party HP, quest objective |
| Menu | `scripts/ui/menu.gd` | Party stats, inventory, save/load |

## Known Pitfalls (from lessons/)

- GDScript `var` in if/else branches shares function scope — use unique names
- `:=` type inference fails with `max()`, `instantiate()`, dictionary access — use explicit types
- `process_mode = PROCESS_MODE_ALWAYS` needed for UI that works while paused
- ATB fill rate of 30 is too slow — use 100 for playable speed
- Location JSON must have `"layout"` key for rich rendering (falls back to simple mode without it)
- Boss encounters trigger via quest steps with `defeat:enemy_id` triggers

## Yume Design Principles

### 1. Data drives everything
All game content is JSON. The engine never changes — only the data does.
```
game_state.json  → story flow (cutscenes, party joins, bosses)
locations/*.json → visual rooms (layout, props, treasures, NPCs)
characters.json  → party members and NPCs
items/enemies/quests.json → gameplay content
```

### 2. Asset abstraction layers
ALL visuals AND audio go through abstraction layers. Engine auto-detects files:
```
Visual:  visual_helpers.gd checks sprites/ → uses image if exists, code-drawn if not
Audio:   audio_manager.gd checks audio/   → plays if exists, silent if not
3D:      swap visual_helpers.gd for 3D version → same data, different renderer
```
Asset folders (drop files here, engine auto-detects):
```
sprites/characters/{id}.png     audio/bgm/{mood}.ogg
sprites/npcs/{name}.png         audio/sfx/{action}.ogg
sprites/props/{type}.png        audio/ambience/{type}.ogg
sprites/enemies/{id}.png        audio/voice/{character}/{line}.ogg
```
JSON data contains generation prompts for each asset (pass5_assets.md):
```
characters.json  → sprite_prompts, portrait_prompt, voice_prompt, battle_sfx_prompts
locations/*.json → atmosphere.bgm_prompt, ambience_prompt, ambience_layers
enemies.json     → sfx_prompts (appear, attack, hurt, death)
game_state.json  → per-phase bgm_override, bgm_prompt, sfx_cues
```

### 3. Story state machine
`game_state.json` is the single source of truth for story flow. Locations are visual-only.
```
game_state.json phases → triggers (reach/defeat) → cutscenes, party joins, flags, exits
locations/*.json       → layout, props, treasures, ambient NPCs (no story logic)
```

### 4. Test-driven game development
```
yume test → data validation + system tests + full playthrough simulation + Godot headless
```
If tests pass, the game works. Generated data is verified automatically.

## Modifying the Engine

The scripts are plain GDScript — edit them directly:
- **Change combat** → edit `battle_manager.gd` (damage formulas, AI behavior)
- **Change UI** → edit `ui_theme.gd` (colors, sizes) or individual UI scripts
- **Change visuals** → edit `visual_helpers.gd` or drop sprites in `sprites/` folder
- **Add new systems** → create new autoload script, register in `project.godot`
- **Change movement** → edit `player_controller.gd`

## Testing Your Game

Yume includes a 4-layer automated test suite. Run after every content change:

```bash
# Full test suite (data + systems + playthrough)
yume test /path/to/your-game/

# Individual layers
yume test /path/to/your-game/ -l data         # JSON integrity, refs, density
yume test /path/to/your-game/ -l systems      # Party, quests, combat, shops
yume test /path/to/your-game/ -l playthrough  # Simulates playing the entire game

# With Godot headless (optional, needs Godot CLI)
yume test /path/to/your-game/ -l godot -g /path/to/godot
```

| Layer | What it tests | Time |
|-------|--------------|------|
| **data** | JSON parse, exit refs, reachability, content density, steal lists | <1s |
| **systems** | Party joins, quest chain, damage formulas, shop economy, game flow | <1s |
| **playthrough** | Walks every room, fights every boss, completes every quest, verifies the game is finishable | <1s |
| **godot** | Spawn structure, battle math, exit connectivity in Godot headless mode | ~3s |

The playthrough simulator is the most powerful — it literally plays through the game from title to credits, collecting items, fighting bosses, and verifying quest progression.

## Read More

- `core/docs/01_game_dev_cycle.md` — Game development stages
- `archetypes/rpg/docs/02_rpg_systems_guide.md` — All RPG systems in detail
- `archetypes/rpg/docs/04_game_design_and_level_design.md` — Level design patterns
- `core/docs/05_yume_framework_vision.md` — Why Yume exists
