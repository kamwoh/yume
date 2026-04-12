# Yume Simulation World — Visual Design Document

## Date: 2026-04-12
## Based on: 100+ reference images from 15+ games + 8 codebase studies

## Target Feel: "Stonehearth + FF9 Black Mage Village + SAO Alicization + BotW openness"

## Visual Design

### Color Palette
- Ground: Bright green grass (#5a8f3c)
- Wood: Warm brown (#8b6914)
- Sky: Light blue (#78a7ff) day, deep blue (#0a0a2e) night
- Water: Clear blue (#3a7bd5) with shimmer
- Wheat: Golden (#d4a017) when mature
- Stone: Gray-brown (#7a7a6a)
- Fire: Warm orange (#ff6b1a) with glow
- Fog at edges: soft white (#cccccc80)

### World Layout (40x40 open field)
```
Not grid rooms. Natural scatter:

    🌲🌲    ⛰️        🌲
  🌲  🌲   ⛰️   💧💧  
        ·path·   💧💧  🌲
  🏠🏠  ·   ·         
  🔥   ·   ·  🌾🌾🌾  🌲
  🏠   ·   ·  🌾🌾🌾  
       ·   ·          ⛰️
  🌲    · ·    🌲  🌲  
```

### Element Placement Rules
- Trees: clusters of 3-5, min 3 tiles apart between clusters
- Stones: clusters of 2-3, near each other (outcrops)
- Water: 1-2 pools, each 3-5 tiles, clustered
- Dirt: scattered patches, potential farm spots
- Empty grass: 60% of world should be OPEN (not cluttered)

### Camera
- Third-person, slightly elevated (25-30 degree angle)
- Distance: 8-10 units behind character (see more world)
- Character ~10% of screen height
- Smooth follow with slight lag

### Lighting
- Day: sun_energy 0.8, warm golden directional light, soft shadows
- Dusk: sun_energy 0.4, orange-pink sky, long shadows
- Night: sun_energy 0.05, blue ambient, only campfire light pools visible
- Cycle: 300 seconds (5 min) = 1 full day

### Atmosphere
- bg_color shifts: blue sky → orange sunset → dark blue night
- Fog at world edges (hides boundary, suggests larger world)
- Ambient: birds during day (future audio), crickets at night

## Gameplay Systems (from codebase studies)

### Core Loop (Don't Starve style)
```
Day:   Gather resources, farm, build, explore
Dusk:  Return to base, prepare
Night: Stay near fire, craft, manage inventory
```

### NPC Architecture (from Veloren + OpenMW + Sims)
```
Agent:
  needs: {hunger, thirst, energy}           ← Sims
  personality: {openness, agreeableness}     ← Veloren
  sentiments: {target → -1.0 to +1.0}       ← Veloren
  profession: farmer/gatherer/builder        ← Veloren
  ai_packages: stack [wander, gather, eat]   ← OpenMW
  actions: composable .then().stop_if()      ← Veloren
  inventory: items with stack counts         ← Minecraft
  inbox: reports/events from other agents    ← Veloren
```

### Decision Making (Sims scoring + Veloren actions)
```
Every 500ms:
  1. Evaluate needs urgency
  2. Score available actions: urgency × satisfaction
  3. Pick best action → push to action stack
  4. Execute action steps (.then chains)
  5. Interrupt if higher priority (combat, critical need)
```

### World Rules (Minecraft ABMs)
```
Every N seconds, for matching elements:
  - Wheat grows if light + water nearby
  - Fire spreads to flammable neighbors
  - Campfire decays over time
  - Hunger/thirst/energy decay on agents
  - Starvation damages agents
  - Shelter restores energy
```

### Crafting (Minecraft recipes)
```
axe = wood(2) + stone(1)
pickaxe = wood(2) + stone(3)
shelter = wood(8) + stone(4)
campfire = wood(3)
farmland = hoe + dirt
cooked_food = food + fire nearby
```

## Implementation Priority

### Phase A: World Renderer
- [ ] sim_world.gd: reads world_config.json, creates flat green ground plane
- [ ] Scatter elements (trees, stones, water, dirt) naturally (not grid)
- [ ] Bright outdoor lighting (sun, sky, shadows)
- [ ] Day/night cycle (smooth transition)

### Phase B: Agent + Needs
- [ ] Agent spawns with inventory (starting axe)
- [ ] Needs decay over time (hunger, thirst, energy)
- [ ] NeedsDrivenBrain evaluates and acts
- [ ] Agent chops trees, collects resources
- [ ] Agent eats food, drinks water

### Phase C: Building + Farming
- [ ] Agent crafts tools from resources
- [ ] Agent builds campfire (fire element spawns)
- [ ] Agent tills dirt → farmland → plants seeds
- [ ] Wheat grows through stages (ABM world rules)
- [ ] Agent harvests mature wheat → food

### Phase D: Multi-Agent
- [ ] 3-5 agents in same world
- [ ] Each has different personality
- [ ] Sentiments develop through interaction
- [ ] Agents trade surplus resources
- [ ] Emergent cooperation/conflict

### Phase E: Polish + Recording
- [ ] Smoke particles from campfire
- [ ] Crop growth visually staged
- [ ] Camera brains for diverse training data
- [ ] Export episode data (frames + actions + scene graph)

## Models We'll Use (from 876 available)

| Element | Model | Scale | Notes |
|---------|-------|-------|-------|
| Tree | column (tall) or wood-structure | 2.0x | Green tint, clustered |
| Stone | rocks | 1.5x | Gray, clustered |
| Water | floor-detail | 1.0x | Blue tint, sunken |
| Dirt | dirt | 1.0x | Brown patch |
| Farmland | floor-detail | 1.0x | Brown, tilled look |
| Wheat seed | coin | 0.3x | Tiny, just planted |
| Wheat growing | coin | 0.6x | Getting bigger |
| Wheat mature | banner | 0.5x | Golden, harvestable |
| Campfire | trap | 1.0x | With orange point light |
| Shelter | wood-structure | 2.0x | Scaled up |
| Agent | Knight/Barbarian/Mage | 0.4x | KayKit characters |
| Barrel | barrel | 1.5x | Storage prop |

## Reference Images That Define The Feel

Best references (save these):
- stonehearth-1.jpg — THE closest to our tech/style (low-poly village with farms)
- openworld-1.jpg — village feel (thatched roofs, warm, animals)
- openworld-4.jpg (BotW) — clean readable open world, green field, NPCs
- craftopia-3.jpg — characters under tree, peaceful outdoor
- ff9-20.jpg — Black Mage Village, cozy garden path
- sao-5.jpg — medieval town square, fountain, lived-in
- valheim-1.png — rustic survival base with campfire
- monsterhunter-8.jpg — proof MH works in stylized low-poly too
