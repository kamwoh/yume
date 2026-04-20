# Yume Level 3: Emergent World Vision

> **STATUS (2026-04-19): Historical vision doc.** Substrate (Phases A–C —
> elements, properties, rules, needs, NeedsDrivenBrain) is built. Phases
> D (multi-agent: trade, cooperation, conflict) and E (time acceleration,
> recording) have been folded into the active roadmap at
> `~/yume/task_plan.md` (Tier 2 and Tier 4). Read this doc for the
> conceptual ladder and original framing; read `task_plan.md` for what's
> actually being worked on.

## The Insight

The creator defines **elements and rules**, not behaviors. Agents discover how to combine them.

```
Creator defines:          Agents discover:
─────────────            ────────────────
tree exists              chop tree → wood
axe exists               wood + stack → shelter
rain makes cold          shelter blocks rain
hunger decreases HP      plant seed → grow food
food restores HP         farm → surplus → trade
fire cooks food          cooked food > raw food
mountain has ore         ore + fire → metal
metal + shape → tools    better tools → faster work
```

Nobody programs "build a house" or "start farming." Survival pressure + element combinations = emergent civilization.

## The 4 Levels

### Level 1: Fixed World (DONE)
- Designer places every room, prop, enemy
- Agent walks through prescribed content
- Training data: visual prediction, basic navigation

### Level 2: Procedural World (CURRENT TARGET)
- Generator creates rooms from templates + algorithms
- State machine NPCs, scripted interactions
- Training data: diverse environments, combat, exploration

### Level 3: Elemental Rules + Agent Needs (NEXT BIG STEP)
- Define: materials, tools, crafting recipes, agent needs (hunger, shelter, safety)
- Agents discover: farming, building, trading, cooperation
- Training data: causal reasoning, planning, goal-directed behavior

### Level 4: Full Simulation (LONG TERM)
- Define: physics, biology, social rules, reproduction
- Agents create: language, culture, economy, war, art
- Training data: emergent society, long-term planning, social dynamics

## Level 3 Design — What We'd Build

### Core: Elements + Properties + Rules

```json
{
  "elements": {
    "tree":     {"properties": ["choppable", "burnable", "solid"], "model": "tree"},
    "rock":     {"properties": ["mineable", "solid", "throwable"], "model": "rocks"},
    "water":    {"properties": ["drinkable", "extinguishes_fire"], "model": "water"},
    "seed":     {"properties": ["plantable"], "model": "coin"},
    "wood":     {"properties": ["stackable", "burnable", "craftable"], "model": "barrel"},
    "ore":      {"properties": ["smeltable", "craftable"], "model": "rocks"},
    "food":     {"properties": ["edible", "perishable"], "model": "chest"},
    "fire":     {"properties": ["hot", "cooks", "smelts", "spreads"], "model": "trap"}
  },

  "rules": [
    {"action": "chop",  "input": ["tree"],         "output": ["wood", "wood", "seed"], "requires_tool": "axe"},
    {"action": "mine",  "input": ["rock"],          "output": ["ore", "stone"],         "requires_tool": "pickaxe"},
    {"action": "plant", "input": ["seed"],          "output": ["growing_plant"],        "time": 60},
    {"action": "grow",  "input": ["growing_plant"], "output": ["food", "seed"],         "auto": true, "time": 120},
    {"action": "cook",  "input": ["food", "fire"],  "output": ["cooked_food"]},
    {"action": "smelt", "input": ["ore", "fire"],   "output": ["metal"]},
    {"action": "craft", "input": ["wood", "wood"],  "output": ["shelter_frame"]},
    {"action": "craft", "input": ["metal", "wood"], "output": ["axe"]},
    {"action": "craft", "input": ["metal", "wood"], "output": ["pickaxe"]},
    {"action": "build", "input": ["shelter_frame", "wood", "wood"], "output": ["shelter"]},
    {"action": "eat",   "input": ["food"],          "effect": {"hunger": +30}},
    {"action": "eat",   "input": ["cooked_food"],   "effect": {"hunger": +60, "hp": +10}},
    {"action": "drink", "input": ["water"],          "effect": {"thirst": +50}},
    {"action": "rest",  "input": ["shelter"],        "effect": {"hp": +20, "energy": +50}}
  ],

  "agent_needs": {
    "hunger":   {"decreases": 1.0, "per_second": true, "at_zero": "lose_hp"},
    "thirst":   {"decreases": 0.5, "per_second": true, "at_zero": "lose_hp"},
    "energy":   {"decreases": 0.3, "per_second": true, "at_zero": "slow_movement"},
    "hp":       {"max": 100, "at_zero": "die_and_respawn"},
    "safety":   {"near_shelter": "+regen", "near_enemy": "-regen"}
  },

  "world_effects": {
    "rain":     {"schedule": "random", "effect": "cold_damage_without_shelter"},
    "night":    {"schedule": "cycle_300s", "effect": "stronger_enemies, reduced_visibility"},
    "fire":     {"spreads_to": ["tree", "wood"], "blocked_by": ["water", "stone"]}
  }
}
```

### Agent Brain for Level 3: NeedsDrivenBrain

```
The agent doesn't follow scripts. It has NEEDS:
1. Observe: what's nearby? (scan for elements)
2. Assess: what need is most urgent? (hunger? safety? tools?)
3. Plan: what sequence of actions satisfies that need?
4. Act: execute the plan step by step
5. Learn: remember what worked (persistent memory)

Example emergent behavior:
  hunger=20 → need food → look around → see tree →
  no axe → look for rock → mine rock → get ore →
  need fire → rub sticks? → discover fire → smelt ore →
  craft axe → chop tree → get wood + seed →
  plant seed → wait → harvest food → eat → hunger=80 →
  NOW build shelter before night comes
```

### The Brain Interface (same abstraction!)

```gdscript
# brain_needs_driven.gd — implements same decide() interface
func decide(entity, world_state) -> Dictionary:
    var needs = entity.get_needs()  # {hunger: 20, thirst: 50, energy: 70}
    var nearby = world_state.get("nearby_elements")  # what's around me
    var known_recipes = entity.get_memory("recipes")  # what I've discovered

    # Most urgent need
    var urgent = _most_urgent_need(needs)

    # Plan: what chain of actions satisfies this need?
    var plan = _plan_for_need(urgent, nearby, known_recipes)

    # Execute next step in plan
    return plan[0]  # {"action": "move_to", "target": nearest_tree}
```

### Why This Is Killer for World Modeling

| What traditional games produce | What Level 3 produces |
|-------------------------------|----------------------|
| Walk → fight → loot (scripted) | Chop → build → farm → trade (emergent) |
| Same behavior every playthrough | Different behavior every run |
| Agent follows script | Agent reasons about goals |
| Objects are decorative | Objects have causal properties |
| No real physics understanding | Real cause → effect chains |

**World models trained on Level 3 data would understand:**
- Causality (axe + tree → wood, not just "tree disappears")
- Planning (need shelter → need wood → need axe → need ore)
- Agent intentions (moving toward tree BECAUSE hungry, not random walk)
- Object affordances (tree is choppable, water is drinkable)
- Emergent behavior (farming isn't scripted — it's discovered)

### Implementation Path

```
Phase A: Element system
  - Elements with properties (JSON)
  - Rules for combining elements (JSON)
  - World spawns elements at runtime
  - Visual: elements are GLB models (already have tree, rocks, barrel, chest)

Phase B: Agent needs
  - Needs that decrease over time (hunger, thirst, energy)
  - Needs affect HP and behavior
  - Agent must satisfy needs to survive

Phase C: NeedsDrivenBrain
  - Scans nearby elements
  - Plans action chains to satisfy needs
  - Executes plans step by step
  - Remembers discovered recipes

Phase D: Multi-agent
  - Multiple agents in same world
  - Trade: surplus food for tools
  - Cooperation: group hunting, shared shelter
  - Conflict: resource competition

Phase E: Time acceleration
  - Run simulation at 100x speed
  - Observe emergent patterns
  - Record everything for training data
```

### The Demo That Gets DeepMind's Attention

```
"Watch 10 AI agents survive in a procedurally generated world.
 Nobody told them how to farm. Nobody told them to build shelters.
 Nobody told them to trade.
 We defined: trees, rocks, water, hunger, cold, crafting rules.
 They figured out the rest."

 → 30-second video showing agents:
   - Chopping trees, building shelters
   - Farming food, cooking over fire
   - Trading surplus between agents
   - Cooperating to hunt dangerous enemies
   - Different strategies emerging per run

 All recorded as training data:
   frames + camera poses + agent actions + scene graph + causal chains
```

This is the pitch. This is what makes Yume unique.

## References
- SAO Alicization: Fluctlight AI grown through world simulation
- Smallville paper (arxiv 2304.03442): LLM agents in simulated town
- DeepMind Genie (arxiv 2402.15391): World models from game data
- Game data for world models (arxiv 2604.02329): Using games as training source
