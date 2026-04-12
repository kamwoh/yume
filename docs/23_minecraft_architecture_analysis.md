# Minecraft Architecture Analysis (Luanti + VoxeLibre) → Yume Level 3

## Date: 2026-04-12
## Sources: /mnt/c/Users/kamwoh/Documents/Projects/Personal/luanti + VoxeLibre

## The Key Insight

Minecraft's entire emergent world comes from **5 registration systems**:

1. **Nodes** (blocks) — elements with group properties
2. **Recipes** — combine inputs → outputs
3. **Tools** — capabilities that affect specific groups
4. **Entities** — creatures with AI callbacks
5. **ABMs** — timed world rules (growth, decay, spreading)

Everything else — farming, building, combat, survival — emerges from these interacting.

## System-by-System Breakdown

### 1. Nodes = Elements
```lua
-- Minecraft/VoxeLibre
minetest.register_node("mcl_core:stone", {
    groups = {pickaxey=1, stone=1, building_block=1},
    drop = "mcl_core:cobble",
    _mcl_hardness = 1.5,
})
```

**For Yume JSON:**
```json
{
  "elements": [
    {
      "id": "stone",
      "groups": {"mineable": 1, "stone": 1, "building": 1},
      "drop": "cobblestone",
      "hardness": 1.5,
      "model": "rocks"
    }
  ]
}
```

### 2. Recipes = Crafting Rules
```lua
-- Minecraft: shaped recipe
minetest.register_craft({
    output = "mcl_core:stick 4",
    recipe = {{"mcl_core:wood"}}
})
```

**For Yume JSON:**
```json
{
  "recipes": [
    {"output": "stick:4", "inputs": ["wood"], "type": "shaped"},
    {"output": "axe", "inputs": ["stick:2", "stone:3"], "type": "shaped"},
    {"output": "cooked_food", "inputs": ["food"], "type": "cooking", "fuel": "wood", "time": 5}
  ]
}
```

### 3. Tools = Group Capabilities
```lua
-- Minecraft: wooden pickaxe
minetest.register_tool("mcl_tools:pick_wood", {
    tool_capabilities = {
        groupcaps = {pickaxey = {times={1.5}, uses=60, maxlevel=1}}
    }
})
```

**For Yume JSON:**
```json
{
  "tools": [
    {
      "id": "wooden_pickaxe",
      "affects_groups": {"mineable": {"speed": 1.5, "uses": 60}},
      "damage": 2,
      "model": "weapon-spear"
    }
  ]
}
```

### 4. ABMs = World Tick Rules (THE KEY TO EMERGENCE)
```lua
-- Minecraft: wheat growth
core.register_abm({
    nodenames = {"mcl_farming:wheat_1", ..., "mcl_farming:wheat_7"},
    interval = 5.8,     -- seconds between checks
    chance = 35,         -- 1 in 35 probability
    action = function(pos, node)
        -- Grow if light >= 9 and moisture present
        mcl_farming:grow_plant("wheat", pos, node, 1, false)
    end,
})
```

**For Yume JSON:**
```json
{
  "world_rules": [
    {
      "id": "wheat_growth",
      "targets": ["wheat_seed", "wheat_growing"],
      "interval": 6.0,
      "chance": 0.03,
      "conditions": {"light": ">= 9", "nearby": "water"},
      "effect": {"advance_stage": 1, "stages": ["wheat_seed", "wheat_growing", "wheat_mature"]},
      "final_drop": ["wheat_item", "wheat_seed"]
    },
    {
      "id": "fire_spread",
      "targets": ["fire"],
      "interval": 2.0,
      "chance": 0.1,
      "conditions": {"neighbor_group": "flammable"},
      "effect": {"spread_to_neighbor": "fire"}
    },
    {
      "id": "leaf_decay",
      "targets": ["leaves"],
      "interval": 10.0,
      "chance": 0.05,
      "conditions": {"no_nearby": "tree_trunk", "radius": 6},
      "effect": {"remove": true, "drop_chance": {"sapling": 0.05}}
    }
  ]
}
```

### 5. Mob AI = Entity Brain (already built in Yume!)
```lua
-- Minecraft zombie
local zombie = {
    type = "monster",
    hp_max = 20,
    damage = 3,
    walk_velocity = 0.8,
    run_velocity = 1.8,
    attack_type = "dogfight",
    view_range = 16,
    pathfinding = 1,
    ignited_by_sunlight = true,
}
```

**Already in Yume as brain_state_machine.gd with JSON config!**

## The Farming Loop (How Emergence Works)

Minecraft wheat farming is NOT hardcoded. It emerges from:

1. **Hoe** (tool) + **dirt** (node) → **farmland** (recipe/interaction)
2. **Wheat seed** (item) + **farmland** (node) → **planted wheat** (on_place)
3. **ABM** checks every 5.8s: if light >= 9 AND moisture nearby → advance growth stage
4. **Moisture** = water source within 4 blocks (another ABM/check)
5. **Mature wheat** (node) → **wheat item + seeds** (drop on harvest)
6. **Wheat item** → satisfies hunger (food system)

Nobody coded "farming". These 6 rules + hunger pressure = farming emerges.

## VoxeLibre Specific Patterns

### Hunger System
```
Exhaustion accumulates from: digging(5), jumping(50), sprinting(100), attacking(100), swimming(10)
When exhaustion >= threshold → hunger decreases
When hunger <= 0 → take starvation damage
When hunger >= 18 → regenerate health
Food restores hunger + saturation points
```

### Mob Spawning Rules
```
Light level < 7 → hostile mobs spawn
Light level >= 7 → passive mobs spawn
Spawn caps per category (monster, animal, water)
Biome-specific mob lists
Group spawning (cows spawn in groups of 2-4)
```

### Tool Progression
```
Wood pickaxe → mines stone (level 1)
Stone pickaxe → mines iron (level 3)
Iron pickaxe → mines diamond (level 4)
Diamond pickaxe → mines obsidian (level 5)
Each tier unlocks new resources → gates progression
```

## Architecture Principles to Adopt

### 1. Everything is a Registration
No hardcoded content. Every element, recipe, tool, rule is registered via data.

### 2. Groups Are the Universal Interface
Nodes belong to groups. Tools affect groups. ABMs target groups. This is THE abstraction.

### 3. ABMs Are the Heartbeat
Active Block Modifiers run every N seconds on matching nodes. This is how the world "lives" — crops grow, fire spreads, leaves decay.

### 4. Modular Content
Each system (farming, combat, building) is a separate "mod" — independent, composable, replaceable.

## Mapping to Yume's Architecture

```
Luanti System        →  Yume Equivalent
─────────────────       ─────────────────
register_node()      →  elements.json (element definitions)
register_craft()     →  recipes.json (crafting rules)
register_tool()      →  tools.json (capabilities)
register_entity()    →  npcs with brain (already done!)
register_abm()       →  world_rules.json (timed world rules) ← NEW
register_biome()     →  biomes in generate_dungeon.py (already done!)
groups system        →  "groups" field on elements ← NEW
formspec UI          →  minimap.gd / hp_bar.gd (already done!)
```

## What Yume Needs to Build for Level 3

1. **Element System** — nodes/blocks with group properties (JSON)
2. **Recipe System** — crafting rules: inputs → outputs (JSON)
3. **Tool System** — tools that affect specific groups (JSON)
4. **World Rules (ABMs)** — timed rules: if conditions → effect (JSON)
5. **Inventory** — player carries items (GDScript)
6. **Interaction System** — use tool on element → apply recipe (GDScript)

The brain system, camera system, combat, and procedural gen are already done.

## The Minimum for Emergence

```json
{
  "elements": ["tree", "stone", "water", "dirt", "fire"],
  "tools": ["axe", "pickaxe", "hoe"],
  "recipes": [
    {"chop tree": ["wood", "wood", "sapling"]},
    {"mine stone": ["cobblestone"]},
    {"craft axe": ["wood:2", "stick:2"]},
    {"hoe + dirt": ["farmland"]},
    {"plant seed on farmland": ["growing_wheat"]},
    {"cook food + fire": ["cooked_food"]}
  ],
  "world_rules": [
    {"wheat grows": "if light + moisture, advance stage every 6s"},
    {"fire spreads": "to flammable neighbors every 2s"},
    {"leaves decay": "if no tree trunk nearby"}
  ],
  "agent_needs": {
    "hunger": {"decay": 1.0, "restored_by": "food"}
  }
}
```

This + NeedsDrivenBrain = emergent farming, building, tool-making.
