# Yume Game Design Knowledge Base

Consolidated from: Level Design Book, MIT Game Design courses, GDC talks, roguelike dev research.

## 1. Core Frameworks

### MDA (Mechanics-Dynamics-Aesthetics)
- Designers work bottom-up: rules → behavior → feelings
- Players experience top-down: feelings → behavior → rules
- Procedural rules must produce emergent dynamics that feel good

### Flow Theory
- Challenge must match player skill (and evolve with it)
- Empty rooms = boredom. Overwhelming complexity = anxiety. Discovery = flow.
- Immediate feedback, clear goals, sense of control

### Intrinsic Motivation
- Autonomy (freedom to choose), Mastery (sense of progress), Curiosity (reward discovery)
- Tangible rewards (loot) are extrinsic — wear off fast
- Environmental mysteries, hidden connections, architectural details sustain engagement

## 2. Room Metrics

All dimensions scale from character height (1.8m real → 0.72 Godot units at 0.4x scale).

| Element | Ratio | Godot Units |
|---------|-------|-------------|
| Character height | 1.0x | 0.72 |
| Doorway width | 1.2x char width | ~0.9 |
| Doorway height | 1.3x char height | ~1.0 |
| Corridor width | 2-3x char width | 1.5-2.2 |
| Wall height (interior) | 1.5-2x char | 1.1-1.4 |
| Ceiling height | 2-3x char | 1.4-2.2 |
| Minimum comfortable room | 10x10 char heights | 7x7 |
| Third-person camera room | 14x14 tiles | 14x14 |
| Combat arena minimum | 8-12x char heights | 6-9 |
| Boss arena minimum | 16x16 char heights | 12x12 |
| Camera distance behind | 3-5x char height | 2.2-3.6 |
| Camera height above | 1.5-2x char height | 1.1-1.4 |

## 3. Composition Rules

### Three-Layer Composition (every camera view)
1. **Foreground** (dark frame): Pillars, doorway edges, nearby walls → create depth
2. **Focal Point** (bright): ONE dominant element that draws the eye → treasure, NPC, light
3. **Background** (calm): Distant walls, dim details, atmospheric fade

### Focal Point Properties
- Contrast with surroundings (brightest in dark room, unique shape)
- Rule-of-thirds positioning (1/3 from edge, not dead center)
- Only ONE dominant focal point per view
- Interactive objects at secondary focal points

### Sight Lines
- Player MUST see objective from entrance
- "Weenies" (Disney term): visible distant landmarks pull players forward
- If lost → add a light or unique object at destination

## 4. Lighting

### Zebra Lighting
- Alternate bright and dark zones — never uniform illumination
- Creates visual rhythm, guides movement, emphasizes character

### Color Psychology
| Color | Association | Game Use |
|-------|------------|----------|
| Warm (red/orange/yellow) | Danger, energy, warmth | Enemy areas, torches, safe hearths |
| Cool (blue/purple) | Calm, mystery, cold | Magic, water, night |
| Gold | Importance, treasure | Rewards, objectives |
| Gray/Black | Fear, void | Dungeons, corruption |

### Mood Lighting
| Mood | Approach |
|------|----------|
| Safety | Bright, warm, multiple sources |
| Tension | Dark, sparse highlights, cool + red accents |
| Mystery | Fog, backlighting, blue/purple + dim yellow |
| Warmth | Golden, broad illumination |
| Dread | Very dark, harsh red/purple accents |

### Rules
- Contrast > brightness. One bright pool in darkness > distributed uniform light
- Torches at decision points and objectives (psychological safety)
- Mood first, realism second
- No blue sky for indoor dungeons (outdoor cue)

## 5. Layout Typologies

### Single Room Types
| Type | Use | Properties |
|------|-----|-----------|
| Corridor | Transitions, pacing | Min 2 tiles wide, max 5 without decision point |
| Switchback | Treasure, mini-boss | Dead-end with visible exit on return |
| Combat Bowl | Melee encounters | Central cover, circular movement |
| Arena | Boss, ranged combat | 12x12+, multiple lanes, scattered cover |

### Multi-Room Layouts
| Type | Structure | Best For |
|------|-----------|----------|
| Hub-and-Spoke | Central room + 3-4 branches | Exploration, procedural gen (ideal) |
| Linear/String of Pearls | Sequential rooms | Story-driven progression |
| Loopback | Linear that circles back | Prevents backtracking tedium |
| Branching Chokepoints | Multiple paths → bottleneck | Skill gates, narrative gates |

### Mix Rule
60% linear + 20% hub + 20% branching for balanced exploration.

## 6. Environmental Storytelling

### Room Story Roles
Every room answers: "Who lives here? What do they do?"

| Role | Props | Mood |
|------|-------|------|
| guard_post | Weapon racks, torches, banners, patrol markers | Alert, organized |
| treasure_vault | Chests, columns, accent light on treasure | Rich, rewarding |
| living_quarters | Barrels, personal items, beds, scattered props | Cozy, lived-in |
| ritual_chamber | Central altar/gate, columns in circle, dark | Mystical, ominous |
| boss_arena | Large open space, perimeter cover, dramatic light | Dramatic, threatening |
| natural_cave | Scattered rocks, irregular floor, warm torches | Organic, mysterious |

### Prop Placement Logic
| Location | What | Why |
|----------|------|-----|
| Against walls | Barrels, shelves, weapon racks | Storage/utility |
| Corners | Chests, beds, desks | Personal/private |
| Near doors | Torches, guards, signs | Entry/security |
| Room center | Fountain, table, campfire | Gathering/focal |
| Along paths | Coins, torches | Guide movement |
| Dead ends | Treasure, secrets | Reward exploration |

### Prop Density Formula
```
prop_count = ceil(room_area / 30) + random(0, 2)
```

## 7. Asymmetry & Vertical Variation

### Asymmetry
- Offset doorways from center by 2-3 tiles
- Use L-shapes, T-junctions, alcoves — not perfect rectangles
- One focal wall with more detail than others
- Never place two identical props side-by-side

### Vertical Variation
| Height Change | Effect |
|---------------|--------|
| 0.2-0.5 units | Subtle, easy to navigate |
| 0.5-1.0 units | Noticeable, requires jump |
| 1.0-2.0 units | Significant, requires stairs |
| 2.0+ units | Major, dramatic (balconies, towers) |

- Flat floors feel dead — always include at least one height change per room
- Players look UP at impressive things, DOWN at treasure
- Ascending = hope/achievement. Descending = mystery/danger.

## 8. Pacing

### Emotional Rhythm
- Peaks (action, tension, discovery) + Valleys (rest, exploration, calm)
- Repetition = boredom. Variation = engagement.
- Never string 5 combat rooms in a row

### Room Type Distribution (Classic)
- 1/3 empty or minimal (rest, corridors)
- 1/3 encounters (combat, puzzles)
- 1/6 traps/tricks
- 1/6 special (treasure, story moments)

### Sequence Rule
Bad: Combat → Combat → Combat
Good: Exploration → Combat → Safe Room → Puzzle → Treasure

### Breathing Room
- Safe rooms are structural tools, not decoration
- Without relief, tension becomes meaningless
- After every peak, provide a valley

## 9. Procedural Generation Algorithms

### BSP (Binary Space Partition)
1. Start with large rectangle
2. Recursively split vertically/horizontally until MIN_SIZE (6x6)
3. Place room in each leaf
4. Connect with corridors
- Good for: dungeons, castles, organized structures

### Cellular Automata
1. Fill map with 40-55% random walls
2. Iterate 4-5 times: "become wall if 5+ neighbors are walls"
3. Flood-fill to connect isolated areas
- Good for: caves, organic environments

### Wave Function Collapse
1. Define adjacency rules from reference designs
2. Generate only valid tile combinations
- Good for: coherent tiling that matches an art style

### Spelunky Method (Chunk-Based)
1. Pre-design room chunks with entry/exit points
2. Procedurally arrange chunks ensuring connectivity
- Good for: guaranteed playability + variety

### Hybrid Approach (Recommended for Yume)
- Handcraft 5-10 room templates per story_role
- Use BSP to divide dungeon into regions
- Assign story_role to each region
- Select matching template
- Vary content within template (enemies, treasure, lighting)

## 10. "Feels Hand-Crafted" Checklist

- [ ] Props follow placement logic (walls, corners, doors, center, dead ends)
- [ ] Every prop has a neighbor (clusters near structures, not alone on floor)
- [ ] Asymmetric layout (offset doors, L-shapes, focal wall)
- [ ] Visible objective from entrance (weenie/focal point)
- [ ] Three-layer composition (foreground frame + focal + background)
- [ ] Zebra lighting (alternating light/dark pools)
- [ ] Story role drives prop selection (guard_post ≠ treasure_vault)
- [ ] Height variation (at least one platform/stairs/dip)
- [ ] Room type sequencing respects pacing (no 5 combat rooms)
- [ ] Color palette matches location type and mood
- [ ] Camera doesn't clip walls or see over them
- [ ] Character fits comfortably (not crawling)

## Sources

- The Level Design Book (book.leveldesignbook.com) — metrics, layout, blockout, lighting
- MIT CMS.611J Creating Video Games — MDA framework, game feel
- MIT CMS.608 Game Design — mechanics, aesthetics, player motivation
- Composition in Level Design (gamedeveloper.com) — three-layer, focal points
- Dungeon Theory (tiendil.org) — story through environment
- Spelunky, Binding of Isaac — procedural generation patterns
- PCG research — BSP, cellular automata, WFC algorithms
