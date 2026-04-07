# Godot RPG Ecosystem — Assets, Tools & References

## Key Godot 4 RPG Assets (from Asset Library)

### Complete RPG Frameworks
| Asset | Version | What it provides |
|-------|---------|-----------------|
| [Top-down Action RPG Template](https://godotengine.org/asset-library/asset/487) | Godot 4.2 | Full RPG starter: combat, inventory, quests, keyboard+touch+gamepad |
| [Topdown Pixelart Starter](https://godotengine.org/asset-library/asset/2397) | Godot 4.x | 2 levels, tilesets, quests, combat, talking NPCs, collectibles |
| [Godot Open RPG](https://github.com/gdquest-demos/godot-open-rpg) | Godot 4.5 | Turn-based combat, inventory, character progression, grid movement, dialogues |
| [Indie Blueprint RPG](https://godotengine.org/asset-library/asset/3779) | Godot 4.4 | RPG scripting foundation |
| [Skelerealms - Open World RPG](https://godotengine.org/asset-library/asset/3296) | Godot 4.3 | Open-world RPG framework |
| [DRPG Framework](https://godotengine.org/asset-library/asset/3329) | Godot 4.2 | Dungeon RPG structural template |

### Dialogue Systems (most important for story-driven RPGs)
| Asset | Version | Notes |
|-------|---------|-------|
| [Dialogic 2](https://github.com/dialogic-godot/dialogic) | Godot 4.3+ | **The standard.** Visual dialogue editor, timelines, characters, choices, conditions. Files: .dtl (timelines), .dch (characters) |
| [Dialogue Manager 3](https://godotengine.org/asset-library/asset/1207) | Godot 4.4 | Lightweight alternative to Dialogic. Uses .dialogue text files. Popular. |
| [Dialogue Nodes](https://godotengine.org/asset-library/asset/2185) | Godot 4.3 | Graph-based visual editor |
| [Clyde Dialogue](https://godotengine.org/asset-library/asset/1801) | Godot 4.4 | Script-based, inspired by Ink |
| [NobodyWho - Local LLMs](https://godotengine.org/asset-library/asset/3837) | Godot 4.5 | **AI dialogue!** Uses local LLMs for dynamic dialogue |

### Inventory Systems
| Asset | Version | Notes |
|-------|---------|-------|
| [GLoot (Universal Inventory)](https://godotengine.org/asset-library/asset/2296) | Godot 4.4 | **Most popular.** Grid, list, and custom layouts. Equipment support. |
| [Wyvernbox](https://godotengine.org/asset-library/asset/2091) | Godot 4.0 | Full inventory with stacking, filtering, drag-drop |
| [Inventory Manager](https://godotengine.org/asset-library/asset/2694) | Godot 4.2 | Simple slot-based system |
| [P0nni Inventory](https://godotengine.org/asset-library/asset/3869) | Godot 4.5 | Data-driven core with editor tools |

### Combat Systems
| Asset | Version | Notes |
|-------|---------|-------|
| [2D Tactical RPG Demo](https://godotengine.org/asset-library/asset/2185) | Godot 4.1 | Grid-based tactical combat, skills, flying units |
| [Godot Tactical RPG](https://godotengine.org/asset-library/asset/1295) | Godot 4.3 | Tactical RPG framework |
| [Jrpg Fragment - Turn-Based](https://godotengine.org/asset-library/asset/970) | Godot 3.2 | Turn-based JRPG combat (older but reference-worthy) |
| [Wyvernshield](https://godotengine.org/asset-library/asset/1620) | Godot 3.5 | RPG combat stat framework |

### Audio
| Asset | Notes |
|-------|-------|
| [Kenney's RPG Audio](https://godotengine.org/asset-library/asset/1840) | Free RPG sound effects (attacks, UI, ambient) |

---

## What Yume Should Learn From These

### From Dialogic 2
- **Architecture:** Event-driven timelines, not just JSON arrays
- **Characters:** Separate .dch files with portraits, display names
- **Visual editing:** Users can edit dialogues in Godot's editor
- **Yume opportunity:** Generate Dialogic-compatible .dtl files instead of our custom JSON

### From GLoot
- **Data-driven:** Items defined as resources, inventory is just a container
- **Equipment slots:** Named slots with type constraints
- **UI components:** Pre-built inventory grid/list widgets
- **Yume opportunity:** Generate GLoot-compatible item definitions

### From Godot Open RPG
- **State machines:** Every system uses explicit state machines
- **Scene structure:** Overworld + Combat are separate scene trees
- **Grid movement:** Top-down movement snaps to grid (classic RPG feel)
- **Yume opportunity:** Study their code for combat implementation

### From Dialogic's NobodyWho
- **AI dialogue at runtime!** Uses local LLMs for dynamic NPC conversation
- **Yume opportunity:** NPCs could have personality + context from GDD, generate dialogue on the fly

---

## Godot 4 RPG Architecture Patterns

### Autoload Singletons (what we use)
```
GameManager     — global state, flags, gil
PartyManager    — party members, stats, level up
InventoryManager — items, equipment
QuestManager    — quest tracking, triggers
DialogueManager — dialogue playback
BattleManager   — combat state
SaveManager     — save/load game state
LocationManager — runtime location loading
UITheme         — consistent styling
```

### State Machine Pattern (recommended for everything)
```gdscript
# Base state
class_name State extends Node
func enter() -> void: pass
func exit() -> void: pass
func update(delta: float) -> void: pass
func handle_input(event: InputEvent) -> void: pass

# State machine
class_name StateMachine extends Node
var current_state: State
func transition_to(state_name: String) -> void:
    current_state.exit()
    current_state = get_node(state_name)
    current_state.enter()
```

### Signal-Based Communication
```gdscript
# Manager emits signals, UI listens
signal quest_completed(quest_id)
signal item_obtained(item_id)
signal party_member_joined(character_id)

# UI connects to signals
QuestManager.quest_completed.connect(_on_quest_completed)
```

### Data Loading Pattern
```gdscript
# All game data loaded from JSON at startup
func _ready():
    var file = FileAccess.open("res://data/items.json", FileAccess.READ)
    var data = JSON.parse_string(file.get_as_text())
    for item in data:
        item_db[item["id"]] = item
```

---

## Future Considerations for Yume

### Should Yume generate Dialogic-compatible files?
**Pros:** Users get a visual editor for dialogue, large community support
**Cons:** Adds a dependency, more complex generation
**Decision:** Not for v1. Our custom dialogue system works. Consider for v2.

### Should Yume use GLoot?
**Pros:** Battle-tested inventory UI, equipment system
**Cons:** Adds dependency, our simple system works fine for data-driven approach
**Decision:** Not for v1. Our JSON-based inventory is sufficient.

### Should Yume support grid-based movement?
**Pros:** Classic RPG feel (FF, Pokemon, Dragon Quest)
**Cons:** More complex, requires tilemap integration
**Decision:** Future improvement. Free movement works for v1.

Sources:
- [Godot Asset Library - RPG](https://godotengine.org/asset-library/asset?filter=rpg)
- [Dialogic GitHub](https://github.com/dialogic-godot/dialogic)
- [GLoot](https://godotengine.org/asset-library/asset/2296)
- [Godot Open RPG](https://github.com/gdquest-demos/godot-open-rpg)
- [Godot State Machine Tutorial](https://codingquests.io/blog/godot-4-state-machine-tutorial)
