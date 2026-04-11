# The Sims Architecture Analysis (via OpenTS2) — Lessons for Yume Level 3

## Date: 2026-04-11
## Source: /mnt/c/Users/kamwoh/Documents/Projects/Personal/OpenTS2

## The Sims' Core Pattern: 3 Decoupled Systems

### System A: Need Decay
8 needs decrease over time: hunger, energy, hygiene, bladder, comfort, fun, social, room.
At zero: bad things happen (starvation, fainting, peeing).

### System B: Object Advertisement
Every object broadcasts what needs it satisfies:
```
Fridge:  hunger +60, fun +0
Bed:     energy +80, comfort +40
TV:      fun +50, comfort +20
Toilet:  bladder +100
```
Each object is just 7 numbers (ratings). That's it.

### System C: Autonomy Scoring
```
For each nearby object:
  score = sum over all needs:
    urgency(need) × object_rating(need)
    where urgency = (100 - current_value) / 100

Pick highest scoring object → interact with it.
```

Nobody scripts "go eat." The math does it.

## For Yume Level 3: Minimum Viable Emergence

### 3 Needs (minimum for interesting behavior)
```json
{
  "hunger": {"decay_per_second": 1.0, "critical_at": 20, "critical_effect": "hp_loss_2"},
  "energy": {"decay_per_second": 0.5, "critical_at": 10, "critical_effect": "movement_0.5x"},
  "safety": {"decay_per_second": 0.2, "boosted_by": ["shelter", "fire", "weapon"]}
}
```

### Object Ratings (advertisement)
```json
{
  "bed":     {"energy": 80, "safety": 20},
  "food":    {"hunger": 60},
  "cooked_food": {"hunger": 90},
  "shelter": {"safety": 100, "energy": 10},
  "fire":    {"safety": 30}
}
```

### Autonomy Algorithm (same decide() interface)
```gdscript
func decide(entity, world_state) -> Dictionary:
    var best_score = -1
    var best_object = null

    for obj in world_state.nearby_objects:
        var score = 0
        for need_name in entity.needs:
            var urgency = (100.0 - entity.needs[need_name].current) / 100.0
            var effect = obj.effects_on_needs.get(need_name, 0)
            score += urgency * effect

        if score > best_score:
            best_score = score
            best_object = obj

    if best_object:
        return {"action": "use", "target": best_object.position}
    return {"action": "idle"}
```

### Recipe System (replaces SimAntics VM)
```json
{
  "recipes": [
    {"action": "chop", "inputs": ["tree"], "tool": "axe", "outputs": ["wood:3", "seed:1"], "energy_cost": 15},
    {"action": "plant", "inputs": ["seed"], "duration": 60, "outputs": ["growing_plant"]},
    {"action": "harvest", "inputs": ["growing_plant"], "outputs": ["food:2", "seed:1"]},
    {"action": "cook", "inputs": ["food", "fire"], "outputs": ["cooked_food"]},
    {"action": "craft", "inputs": ["wood:2", "stone:1"], "outputs": ["axe"]},
    {"action": "build", "inputs": ["wood:5", "stone:3"], "outputs": ["shelter"], "energy_cost": 50}
  ]
}
```

## What The Sims Gets Right (steal these)
1. **Object ratings** — each object is just 7 numbers
2. **Autonomy scoring** — urgency × rating, pick highest
3. **Decay creates pressure** — needs drop, forcing action
4. **Decentralized** — no central "AI director", just math
5. **Idle + interrupt** — Sims sleep until something interesting happens

## What to Skip (too complex for Level 3)
1. SimAntics VM — use JSON recipes instead
2. Relationship graphs — Level 4
3. Skill system — assume known recipes
4. Personality traits — all agents equal initially
5. 8 needs — 3 is enough

## OpenTS2 Stats
- 88K LOC C#, Unity 2020
- SimAntics VM with 7/~100 primitives implemented
- Needs system designed but NOT implemented
- Autonomy scoring NOT implemented
- BHAVs (behavior trees) parsed and executable
- Lua scripting integration via MoonSharp
