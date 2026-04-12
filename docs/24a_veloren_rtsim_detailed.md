# Veloren rtsim — Detailed NPC Simulation Architecture

## Source: /mnt/c/Users/kamwoh/Documents/Projects/Personal/veloren/rtsim/

## Core Architecture: Event-Based Rule System
- Rules bind event handlers to events
- Events: OnTick, OnDeath, OnHelped, OnHealthChange, OnTheft, OnMountVolume
- Default pipeline: Migrate → Architect → ReplenishResources → ReportEvents → SyncNpcs → SimulateNpcs → NpcAi → CleanUp

## NPC Data Structure
```
Npc:
  uid: unique id
  seed: deterministic RNG seed
  wpos: Vec3<f32> world position
  body: Humanoid/BirdLarge/etc
  role: Civilised/Wild/Monster/Vehicle
  profession: Farmer/Hunter/Merchant/Guard/Adventurer/Blacksmith/Chef/Alchemist/Pirate/Cultist/Herbalist/Captain
  home: Optional site
  faction: Optional faction
  personality: 5D (openness, conscientiousness, extraversion, agreeableness, neuroticism) 0-255 each
  sentiments: HashMap<Target, Sentiment> relationships
  known_reports: HashSet of witnessed events
  job: Optional (Hired or Quest)
  controller: Action controller (activity + one-time commands)
  inbox: VecDeque<NpcInput> messages
  mode: Simulated (not loaded) or Loaded (in-world)
  brain: Optional Action tree
```

## Action Composition System (THE secret sauce)
Actions are coroutine-like chainable behaviors:
- `.then(other)` — sequential
- `.and_then(|result| ..)` — chain with output
- `.repeat()` — loop indefinitely
- `.stop_if(condition)` — conditional exit
- `.interrupt_with(check)` — priority interrupts
- `.choose()` — decision tree

## Humanoid Decision Priority
1. Vehicle riding (pilot airship, sail boat)
2. Job execution (Hired or Quest-related)
3. Profession-specific behavior
4. Reactive interrupts (enemies, dialogue, inbox)
5. Default idle/wander

## Personality Traits (5D → behavioral modifiers)
- Openness: risk-taking, exploration
- Conscientiousness: rule-following, diligence
- Extraversion: social behavior
- Agreeableness: cooperation
- Neuroticism: anxiety, emotional stability

## Sentiment System
```
HERO (+0.8)    → cult-like devotion
FRIEND (+0.6)  → companion
ALLY (+0.3)    → actively helps
POSITIVE (+0.1)→ better trades
NEUTRAL (0.0)  → default
NEGATIVE (-0.1)→ worse trades
RIVAL (-0.3)   → avoidance
ENEMY (-0.6)   → confrontation
VILLAIN (-0.8) → hunt down
```
Decay: POSITIVE ~26 min, FRIEND ~21 hours. Stored as i8, max 128 per NPC.

## Two-Tier Pathfinding
- Intersite: A* on world sites graph (roads/tracks between towns)
- Intrasite: A* on site tiles (road=1.0, field=8.0, building=5.0, hazard=50.0)

## Report/Gossip System
- NPCs witness events → create reports (Death, Theft)
- Reports stored in global registry
- Other NPCs receive reports via proximity → update sentiments
- Creates emergent alliance/conflict

## Crafting
- Recipe: output item + quantity, inputs (specific item, tagged item, or list), optional craft sprite
- RecipeBook tracks learned recipes per NPC
- YAML/RON asset files define recipes

## Simulation Modes
- Simulated: NPC not in loaded chunk, rtsim physics, update every 10 ticks
- Loaded: NPC in loaded chunk, game server physics, update every tick

## Key Files
- rtsim/src/lib.rs — core system
- rtsim/src/data/npc.rs — NPC data
- rtsim/src/ai/mod.rs — action system
- rtsim/src/rule/npc_ai/mod.rs — decision making
- rtsim/src/rule/npc_ai/movement.rs — navigation
- rtsim/src/data/sentiment.rs — relationships
- common/src/recipe.rs — crafting
