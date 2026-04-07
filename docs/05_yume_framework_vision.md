# Yume Framework Vision

## What Yume Is

Yume is **React for RPG games** — a reusable framework of components, knowledge, and tools that makes building RPGs easy for both humans and LLMs.

## The Gap in Game Dev

```
Web development:
  HTML/CSS/JS (raw) → too hard for most people
  React/Vue/Next.js → drop in components, build fast
  Result: millions of websites, lowered barrier massively

Game development:
  Godot/Unity (raw) → build everything from scratch
  RPG Maker → too limited, can't customize
  ??? → nothing in between
  Result: most indie devs give up before finishing

Yume fills the ???
```

## Three User Types

### 1. Human Developer (no LLM)
```
Uses Yume as a Godot addon/framework:
  - Copy yume/templates/godot/ into their project
  - Edit data/characters.json, data/locations/ etc.
  - The engine scripts (combat, dialogue, quests) just work
  - Read docs/ when stuck
  - Customize individual components as needed
```

### 2. Developer + LLM (Claude Code, Cursor, Copilot)
```
Opens project with their LLM:
  - LLM reads CLAUDE.md → understands the framework
  - Developer says "add a new quest" or "change combat to action RPG"
  - LLM reads docs/ + schemas/ + templates/ → makes correct changes
  - Validator catches mistakes
  - Lessons prevent known pitfalls
```

### 3. Non-developer + LLM (the dream)
```
"Make me an RPG about a young thief who kidnaps a princess"
  - LLM reads Yume knowledge
  - Generates GDD from story
  - Generates complete Godot project using Yume templates
  - Validator checks output
  - User opens Godot → Play
```

## Framework Structure

```
yume/
├── CLAUDE.md                    ← Entry point for any LLM
├── README.md                    ← Entry point for humans
│
├── docs/                        ← Knowledge (for humans AND LLMs)
│   ├── 01_game_dev_cycle.md
│   ├── 02_rpg_systems_guide.md
│   ├── 03_godot_rpg_ecosystem.md
│   ├── 04_game_design_level_design.md
│   └── 05_gdscript_patterns.md  ← GDScript best practices + pitfalls
│
├── schemas/                     ← Data format definitions
│   ├── gdd.schema.json          ← Game Design Document format
│   ├── location.schema.json     ← Rich location data format
│   └── art_bible.schema.json    ← Asset generation prompts format
│
├── templates/                   ← Reference implementation (WORKING CODE)
│   └── godot/                   ← Complete Godot RPG engine
│       ├── project.godot
│       ├── scenes/main.tscn
│       ├── scripts/
│       │   ├── autoload/        ← Singleton managers
│       │   │   ├── game_manager.gd
│       │   │   ├── location_manager.gd
│       │   │   ├── dialogue_manager.gd
│       │   │   ├── party_manager.gd
│       │   │   ├── inventory_manager.gd
│       │   │   ├── quest_manager.gd
│       │   │   ├── battle_manager.gd
│       │   │   ├── save_manager.gd
│       │   │   └── ui_theme.gd
│       │   ├── player_controller.gd
│       │   ├── screen_fader.gd
│       │   └── ui/
│       │       ├── dialogue_ui.gd
│       │       ├── hud.gd
│       │       ├── menu.gd
│       │       ├── battle_ui.gd
│       │       └── shop_ui.gd
│       └── data/                ← Example game data (FF9)
│           ├── characters.json
│           ├── items.json
│           ├── enemies.json
│           ├── quests.json
│           ├── dialogues.json
│           ├── progression.json
│           └── locations/       ← Rich location data
│
├── lessons/                     ← Growing knowledge base
│   └── rpg/
│       ├── architecture/
│       ├── combat/
│       ├── ui/
│       ├── godot/
│       └── workflow/
│
├── prompts/                     ← LLM prompt templates
│   ├── pass1_structure.md       ← Story → characters/locations/plot
│   ├── pass2_content.md         ← → quests/items/enemies/dialogues
│   ├── pass3_balance.md         ← → stat balancing
│   └── pass4_locations.md       ← → rich location design
│
├── validator/                   ← Post-generation checks
│   └── validator.py
│
└── examples/                    ← Example stories + generated games
    └── ff9/
        ├── story.txt
        ├── gdd.json
        └── ART_BIBLE.md
```

## How It Works Like React

| React concept | Yume equivalent |
|--------------|----------------|
| Components (Button, Form, Modal) | RPG systems (combat, dialogue, inventory, quests) |
| Props (data passed to components) | JSON data files (characters, items, locations) |
| State management (Redux/Context) | GameManager + autoload singletons |
| Hooks (useEffect, useState) | Godot signals + _ready()/_process() |
| npm install react | Copy yume/templates/godot/ into project |
| Create React App | yume create story.txt |
| Storybook (component docs) | docs/ + lessons/ |
| ESLint (code quality) | validator.py |
| Component library (Material UI) | Theme system (ui_theme.gd) |

## Why This Works for LLMs

LLMs are good at:
- Reading documentation and following patterns
- Generating code that matches existing examples
- Modifying existing code based on instructions

LLMs are bad at:
- Inventing correct game architecture from scratch
- Knowing Godot/GDScript quirks
- Maintaining consistency across many files
- Debugging without seeing the running game

Yume solves the "bad at" list:
- Architecture is pre-built (templates/)
- Quirks are documented (docs/ + lessons/)
- Consistency enforced by schemas + validator
- Visual QA can close the debugging loop (future)

## Competitive Landscape

| Tool | For | Limitation |
|------|-----|-----------|
| RPG Maker | Non-programmers | Can't customize, proprietary |
| Godot + addons | Programmers | Must assemble from parts, no unified framework |
| Godogen | LLMs | Per-game code gen, no reusable framework |
| **Yume** | **Humans + LLMs** | **Reusable framework + knowledge + validator** |

## The Moat

Every game built with Yume makes Yume better:
- New lessons added to lessons/
- Templates refined from debugging experience
- Docs updated with new patterns
- Validator catches more edge cases
- New game types (action RPG, tactics) add new templates

This is a flywheel that competitors can't easily replicate because the knowledge is accumulated through real game building, not just documentation.
