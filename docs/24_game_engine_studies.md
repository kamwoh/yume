# Open Source Game Engine Studies — Veloren, OpenMW, Freedom-Hunter

## Date: 2026-04-12

## Veloren (Rust) — THE blueprint for emergent NPC simulation

### rtsim Architecture
NPC simulation runs INDEPENDENTLY of loaded chunks. NPCs exist and act even when player isn't nearby.

### NPC Data Model
```
Npc:
  body: Humanoid/BirdLarge/etc
  role: Civilised/Wild/Monster/Vehicle
  profession: Farmer/Hunter/Merchant/Guard/Adventurer/Blacksmith/Chef/etc (12 types)
  personality: 5 dimensions (openness, conscientiousness, extraversion, agreeableness, neuroticism)
  sentiments: HashMap<Target, Sentiment> (relationships toward others, -1.0 to +1.0)
  home: Optional site
  faction: Optional faction
  job: Optional (Hired or Quest)
  brain: Action tree (coroutine-like decision system)
  inbox: Message queue (reports, interactions, dialogue)
```

### Action Composition (THE secret sauce)
Actions are like async/await for AI — chainable, interruptible:
```
action.then(other)           → sequential
action.and_then(|result| ..) → chain with output
action.repeat()              → loop
action.stop_if(condition)    → conditional exit
action.interrupt_with(check) → priority interrupts
action.choose()              → decision tree
```

### NPC Decision Priority
```
1. Vehicle riding (pilot airship)
2. Job execution (hired/quest)
3. Profession behavior (farmer tends fields, merchant trades)
4. Reactive interrupts (enemies, dialogue, inbox)
5. Default idle/wander
```

### Sentiment System (relationships)
```
HERO (+0.8)    → cult-like devotion
FRIEND (+0.6)  → will join as companion
ALLY (+0.3)    → actively helps
POSITIVE (+0.1)→ better trades
NEUTRAL (0.0)  → default
NEGATIVE (-0.1)→ worse trades
RIVAL (-0.3)   → avoidance
ENEMY (-0.6)   → confrontation
VILLAIN (-0.8) → hunt down aggressively
```
Sentiments decay over time: POSITIVE fades in ~26 min, FRIEND fades in ~21 hours.

### Two-Tier Pathfinding
- Intersite: A* on world sites graph (roads/tracks)
- Intrasite: A* on site tiles (road=1.0, field=8.0, building=5.0, hazard=50.0)

### Report/Gossip System
- NPCs witness events (deaths, theft) → broadcast reports
- Other NPCs receive reports → update sentiments
- Creates emergent alliance/conflict without scripting

---

## OpenMW (C++) — NPC schedules and dialogue

### Stack-Based AI Packages
```
[Combat]   ← pushed when enemy detected (highest priority)
[Escort]   ← pushed by quest
[Travel]   ← pushed when going somewhere
[Wander]   ← default (always at bottom)
```
Top package runs. When complete, popped. Next resumes.

### Wander State Machine (makes NPCs feel alive)
```
ChooseAction → IdleNow (play random idle animation)
           → MoveNow (pathfind to destination)
           → Walking (follow path)
```

### What Creates NPC Personality
1. AI Settings: Hello distance, Fight%, Flee%, Alarm%
2. Idle probabilities: 8 animation slots with random chances
3. Wandering distance: radius from spawn
4. Greeting system: turn toward player, acknowledge
5. Reaction timers: 250ms between decisions (natural feel)
6. Disposition tracking: relationships change through dialogue

### Dialogue System
Topic-based with conditions:
```
DialInfo:
  mSelects: conditions (quest state, faction, race, class)
  mActor: which NPC
  mResponse: text shown
  mResultScript: script runs when selected
  mQuestStatus: journal update
```

### Lua Modding
Mods can: control stance, manage inventory, cast spells, create NPCs, query world objects. Scripts run in parallel thread.

---

## Freedom-Hunter (Godot/GDScript) — Combat patterns we can directly use

### Entity Base Class
```gdscript
CharacterBody3D:
  HP: current + recoverable + max
  Stamina: current + max (200) + regen rates per state
  AnimationTree: state machine (idle/movement/attack/rest/death)
  Equipment: weapon + 5 armor slots
```

### Combat Flow
- AnimationTree drives states
- Attack triggered by input → animation plays → collision check → damage
- Damage = input - defense, with element ailments (fire, poison, etc.)
- Stamina costs per action: dodge(10), jump(15), run(5/frame)

### Monster AI (simple but effective)
```
_physics_process:
  if has_target: check_target (still visible?)
  if no_target: find_new_target (nearest visible player)
  if has_target: hunt_target (navigate + attack when close)
  else: scout (random patrol via NavigationAgent3D)
```

### Directly Usable in Yume
- AnimationTree state machine for combat
- NavigationAgent3D for pathfinding
- Stamina as resource with per-state regen
- BoneAttachment3D for equipping weapons
- RPC multiplayer pattern for multi-agent sync

---

## Synthesis: What Yume Should Adopt

| System | Source | Yume Implementation |
|--------|--------|-------------------|
| Action composition | Veloren rtsim | brain actions: .then().stop_if().interrupt_with() |
| 5D personality | Veloren | personality in NPC JSON config |
| Sentiment/relationships | Veloren | sentiment HashMap on entities |
| Report/gossip | Veloren | event bus + NPC inbox |
| Stack-based AI packages | OpenMW | brain package stack (combat > job > wander) |
| Reaction timers | OpenMW | 250ms between AI decisions |
| Idle animation variety | OpenMW | multiple idle anims with probabilities |
| Dialogue with conditions | OpenMW | topic-based dialogue from JSON |
| AnimationTree combat | Freedom-Hunter | already similar to our system |
| NavigationAgent3D | Freedom-Hunter | replace our direct walk-to |
| Stamina resource | Freedom-Hunter | energy need already similar |

### Priority for Simulation Game
1. **Veloren's action composition** — most impactful, enables complex behavior from simple pieces
2. **Sentiment system** — makes NPC relationships feel real
3. **Report/gossip propagation** — creates emergent social dynamics
4. **NavigationAgent3D pathfinding** — replaces our weak random walk
5. **Stack-based AI packages** — clean priority system for interrupts
