# 3D Level Design Fundamentals — What We Learned

## Sources
- [The Level Design Book](https://book.leveldesignbook.com) — FREE, comprehensive
- [Composition in Level Design](https://www.gamedeveloper.com/design/composition-in-level-design)
- [In-Game Proportions and Scale](https://www.gamedeveloper.com/design/design-tips-in-game-proportions-and-scale)
- [Lighting & Color in Games](https://medium.com/my-games-company/using-light-and-color-in-game-development-a-beginners-guide-400edf4a7ae0)
- [Dungeon Theory & Design](https://tiendil.org/en/posts/how-to-design-a-dungeon)

---

## Rule 1: Scale from the Character

Player character = your ruler. Everything relates to it.
- Character height: ~1.8 units (our Knight at 0.4 scale ≈ 1.0 unit — TOO SHORT)
- Doorway: 1.2x character width, 1.3x character height
- Hallway: minimum 2x character width
- Room: minimum 5x5 character heights for "comfortable"
- Ceiling: 1.5-2x character height

**Our problem:** Character is 1.0 unit, walls are 1.1 unit. Room feels like crawling in a box.

## Rule 2: Camera Needs Space

Third-person camera sits BEHIND and ABOVE the player. It needs clearance.
- Camera distance: 3-5x character height behind
- Camera height: 1.5-2x character height above
- Room must be big enough for camera to NOT hit walls
- Minimum room size for third-person: 10x10 character heights

**Our problem:** 10x10 grid of 1-unit tiles = 10x10 meter room. Camera at 5 units back means it sees OVER the walls.

**Fix:** Either bigger rooms (20x20) or closer camera (2-3 units).

## Rule 3: Three-Layer Composition

Every camera view should have:
1. **Foreground** — dark frames (pillars, doorway edges, nearby walls)
2. **Focal point** — bright, clear, draws the eye (treasure, NPC, door to next room)
3. **Background** — calm, less detail (distant walls, sky, fog)

**Our problem:** Everything is the same brightness. No focal points. No depth layers.

## Rule 4: Lighting Creates Atmosphere

- **Contrast > color.** Bright + dark areas create interest. Uniform lighting = boring.
- **Zebra lighting:** alternate pools of light and shadow
- **Torches/point lights** create warm circles — guide the player
- **Dark = tension, bright = safety**
- Never use blue sky for indoor dungeons — use dark fog or ceiling

**Our problem:** Uniform ambient light, blue sky background, no point lights.

## Rule 5: Rooms Tell Stories

A good room answers: "Who lives here? What do they do?"
- Hot soup on table → someone was just eating
- Weapons on rack near door → guards patrol here
- Broken furniture → battle happened
- Books + candles → scholar's study

**Our problem:** Random barrels and columns with no narrative logic.

## Rule 6: Asymmetry Feels Alive

- Symmetrical rooms feel artificial
- Offset doorways from center
- L-shapes, T-junctions, alcoves > perfect rectangles
- One wall with more detail than others (focal wall)

**Our problem:** Perfect 10x10 symmetric grid. Dead feeling.

## Rule 7: Vertical Variation

- Raised platforms, sunken areas, stairs between levels
- Even small height changes (0.5 units) create visual interest
- Players look UP at impressive things, DOWN at treasure

**Our problem:** Completely flat floor. No elevation.

## Rule 8: Guide the Eye

- Place bright/large objects where you want players to go
- Use NPC gaze direction — players look where NPCs look
- Corridors FUNNEL toward focal points
- "Weenies" — visible distant landmarks pull players forward (Disney term)

## Rule 9: Prop Placement Has Logic

| Location | What goes there | Why |
|----------|----------------|-----|
| Against walls | Shelves, barrels, weapon racks | Storage goes along edges |
| Room corners | Chests, beds, desks | Personal spaces |
| Near doors | Guards, torches, signs | Entry/security |
| Room center | Fountain, table, campfire | Gathering/focal point |
| Along paths | Coins, breadcrumbs, torches | Guide movement |
| Dead ends | Treasure, secrets | Reward exploration |

## Immediate Fixes for Our Room

1. **Make room 20x20 tiles** (not 10x10) — player needs space
2. **Character scale 0.5** (not 0.4) — taller relative to room
3. **Camera distance 3.0** (not 5.0) — closer, more immersive
4. **Background: dark brown/black** — NOT blue sky
5. **Add point lights** at torch positions — zebra lighting
6. **Asymmetric layout** — L-shape or offset doorways
7. **Props along walls** — not scattered in the middle
8. **One focal point** — chest at far end, lit by torch
9. **Vertical variation** — raised platform or sunken area
10. **Story logic** — this is a guard post: weapon rack, patrol path, torch
