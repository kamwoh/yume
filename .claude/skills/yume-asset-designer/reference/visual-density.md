# Visual density vocabulary — full reference

_Moved from `yume-asset-designer/SKILL.md` on 2026-10-15 so that the skill loads faster. The skill links here._

## Visual density vocabulary (added 2026-05-09)

Per analysis of an isometric pixel-art RPG reference set
(`docs/games/<game>/style-references-*.md` when authored): soul
isn't asset fidelity, it's **authoring density per square meter**.
A pixel-art mobile game beats a photoreal mesh on a flat plane
every time — because of decisions per pixel, not pixels per inch.

Apply these 10 axes per game when authoring scene.json + entity
defs + initial placements:

### 1. Layered ground variation
No single-color floors. Any visible ground patch ≥10m² gets a
distinct material: grass / dirt-path / cobblestone / plaza-stone
/ wheat-field / water. Author 4-6 ground-tile mesh defs at
project start, place them in zones.

### 2. Edge transitions (no hard borders)
Every ground-tile boundary gets a darker 1m fringe OR a row of
small props (rocks, grass tufts) along the seam. Hard cuts read
as "two unrelated tiles," fringed cuts read as "one continuous
world."

### 3. Vertical depth
≥1 vertical break per significant landmark. Fountain on 0.5m
raised stone disc. Buildings have 0.3m foundation rims. Dungeon
entries are SUNKEN (player descends visibly). Steps and railings.

### 4. Micro-lights
Every dark area gets lights every 8-15m. Lights are FAT (radius
0.3+ for the lamp head, NOT 0.05) with bright warm color
(`#ffe0a0`). Window-glows on cottages at night. Campfires in
residential corners. The constellation of small warm dots IS the
ambient.

**Real lights since ADR 0072 (2026-06-12)** — micro-lights are no
longer fake bright meshes. Author BOTH halves per lamp def:
`visual.light` (`{type: omni|spot, color, energy, range, position:
[local head offset], shadow: false}` — per-light shadows are the
expensive half, default off; spots add `angle` + `direction`) AND
`primitives[].emission` (+ `emission_energy`) on the lamp-head
primitive so the head BLOOMS under glow. Emission-without-light =
glow that illuminates nothing (anti-soul); light-without-emission =
head reads "off" at distance. Lights follow their entity — carried
lanterns and headlights come free. gl_compatibility caps per-mesh
light influence (~8 omni): dozens of scattered lamps fine, hundreds
not. Scene-level budget + mood: yume-lighting-designer § ADR
0071/0072 vocabulary.

### 5. Object density
Target ~1 entity per 9-12 m² visible from typical camera frustum.
A 30×30m plaza area = 50-80 entities. If your level has 20
entities in that area, it WILL feel empty.

### 6. Diagonal accents
Every 4-6 entities, rotate one by 5-30° on the Y axis. Leaning
fence posts, tilted crates, slightly off-square stalls. Strict
grid reads "videogame test scene"; broken grid reads
"inhabited space."

**Authoring pattern (added 2026-05-09)**: set `state.yaw`
(radians, Y-axis rotation) on instance overrides. The 3D + 2D
renderers read this and apply rotation when set; idempotent
when unset.

```jsonc
{"def": "prop_cottage", "id": "townie_house_1",
 "position": [20, 0, 25], "state": {"yaw": 0.26}}  // ~15°
```

Apply via Python: hash the id deterministically into a small
pool of varied angles (mix positive + negative + a few zeros so
~30% stay axis-aligned). Empirical case: 14 of 16 buildings
across pendrel rotated, 2026-05-09.

### 7. Background framing
Every district has foreground framing on ≥2 sides — clusters of
trees, walls, cliffs, or large props that visually contain the
camera frustum. Without framing, the eye falls into the empty
horizon and the world feels like a flat plane.

### 8. Soul-bearing details (purposeless flavor)
15-25% of entities should have ZERO mechanical purpose. Drinking
patrons at tavern tables. Sleeping cat near fireplace. Hanging
laundry between cottages. Posted notices on walls. A wooden cart
with goods. The world feels INHABITED when the camera sees things
that aren't tied to quests.

### 9. Palette discipline per district
Each district picks 4-5 base tones + 1-2 accent colors. Heroes
and important UI ALWAYS use the accent — guarantees pop. Examples:
- Pendrel = warm earth (brown/tan/green) + red flag/sign accent
- Brookhaven = cool grey-blue + autumn-orange roofs
- Dungeon = stone-blue + torch-orange

NPC clothing follows district palette except heroes (red cape /
blue armor — consistent pop across all districts).

**Authoring pattern (added 2026-05-09)**: don't author one mesh
def per district variant — use `visual.params` overrides on
instances. The engine deep-merges `params`, so an instance only
specifies the keys it wants to override; the def's other params
survive.

```jsonc
// def (entities/buildings.json) — neutral default
{
  "id": "prop_cottage",
  "visual": {"mesh": "merchant_cottage_3d"}  // mesh has its own params
}

// instance (levels/town/entities.json) — district override
{
  "def": "prop_cottage",
  "id": "townie_house_1",
  "position": [20, 0, 25],
  "visual": {"params": {
    "wall": "#d8b890",  // warm cream (NW residential)
    "roof": "#a04830",  // terracotta
    "window": "#f0d878"
  }}
}
```

Apply via small Python script that buckets by (x, z) into NW/NE/
SW/SE/C and writes the palette dict. Empirical case: 23 buildings
recolored across 4 districts in pendrel, 2026-05-09.

**Audit gate**: every multi-district game must demonstrate at
least 3 distinct district palettes via per-instance visual.params
overrides on cottages / props / signs. Single-palette across the
whole town = "videogame test scene" feel; failing this axis.

**Anti-cartoon albedo discipline (2026-06-12)**: pure-hue albedos
(#c8362a fire-truck red, neon greens) read as TOYS regardless of
lighting quality. Stylized-realistic = weathered tones (brick
#9e3f35, bone #cfc9bc, olive) + saturation grading ~1.0-1.1
(`lighting.adjustments.saturation`; 1.3 = candy). And grading
without warmth reads dead: an autorace desaturation pass that also
cooled fog + ambient went overcast-grey and had to be re-warmed.
yume-visual-designer now flags pure-hue albedos and grading
saturation >1.2 at review (its Axis 3).

### 10. Silhouette readability
≥3 distinct silhouette templates per game. Within humanoids:
hero (cape + larger), shopkeeper (apron + behind counter),
townie (plain), guard (helmet + spear), child (smaller).
Hats / capes / staffs / belts differentiate roles at-glance —
before nameplates load, before colors register.

### Application discipline

- LOW-COST, HIGH-PAYOFF first: axes 4 (lights radius), 9
  (palette per district), 6 (rotate some entities), 10
  (silhouette variants).
- INCREMENTAL: axes 1 (ground tiles), 8 (purposeless details).
- LATER (needs engine work): axes 2 (edge fringes), 3 (vertical
  geometry), 5 (full density push), 7 (background framing).

Audit existing games for these 10 axes BEFORE declaring an
asset-designer pass complete. The visual gate (`--capture` + read
PNG) should explicitly check density: count entities visible in
viewport, count distinct ground colors, count micro-lights.

### What soul is NOT (budget discipline)

- NOT photorealism. Pixels are fine.
- NOT particle volume. Reference set has zero particles.
- NOT animation count. Static screenshots can carry soul.
- NOT high poly count. Voxels work.
- NOT screen-space effects (bloom, AO, lens flare).
- NOT extensive UI. UI in refs is minimal — gameplay does the work.

Soul is authoring density + deliberate asymmetry + palette
discipline + purposeless flavor. Achievable without a single new
mesh primitive — just deliberate placement of what's already there.
