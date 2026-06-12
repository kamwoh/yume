# Soul — the layered workflow for "this game feels alive"

Soul isn't one thing you author — it's **layered density** across 5
content channels + composition tuned to the GDD's aesthetic. Each
layer alone leaves a soul-shaped hole the player feels but can't
articulate. Layers must REINFORCE each other (gruff dialogue +
gruff music + gruff silhouette + gruff combat); mismatched layers
(warning tone + celebratory flash) = anti-soul.

## When this rule applies

GDD aesthetic targets including any of: **Fellowship** (NPCs you
remember), **Narrative** (story you remember), **Submission**
(rhythm + immersion), **Discovery** (rewarded curiosity),
**Sensation** (raw feel).

Pure-mechanic games (chess, falling-block puzzlers) get a lighter
version — at minimum visual identity + event-feedback juice.

## The 5 soul layers

Every soul-bearing game addresses ALL FIVE. Skipping a layer = a
soul-shaped hole. Layer minimums + owner skill:

**1. Writing** (`yume-flavor-writer`) — per-NPC voice profiles, item
flavor, barker pools, world-text. Minimum: every named NPC has 3-5
word voice descriptor + ≥3 arc-beat lines; every named item has 1
flavor line; every ambient archetype has ≥3 barker variants. Output:
`flavor-design.md` + entity fields (`flavor_text`,
`properties.voice`, `properties.barker_lines`).

**2. Visual identity** (`yume-asset-designer` + engine) — NPCs
distinguishable at a glance. Per-NPC silhouette/color (different
shirt/hat/posture/scale); nameplate above head (engine widget); per-
archetype variation (warrior-shaped vs noble-distinguished).
Minimum: every `named_npc` has nameplate + distinct visual signature;
every customer archetype has its own mesh OR palette.

**Visual density extension** (2026-05-09, after user shared an
isometric pixel-art reference set where every frame packed 50+
entities with deliberate density): 10 authoring-density axes:

1. Layered ground variation (no monochrome floors)
2. Edge transitions (no hard borders)
3. Vertical depth (raised foundations, sunken pits, steps)
4. Micro-lights every 8-15m (lamps, window glow, campfires) — real
   per-entity lights since ADR 0072 (`visual.light` + emissive head;
   no longer fake bright meshes — see yume-lighting-designer)
5. Object density ~1 entity per 9-12 m² in viewport
6. Diagonal accents (rotate every 4-6 entities by 5-30°)
7. Background framing (foreground tree clusters / walls / cliffs)
8. Soul-bearing details (15-25% purposeless flavor entities)
9. Palette discipline per district (4-5 base + 1-2 accent)
10. Silhouette readability (≥3 distinct humanoid templates)

Full vocabulary: `yume-asset-designer` SKILL § Visual density.

**3. Audio** (`yume-audio-designer`) — three sub-layers:
- **BGM** per-level mood + per-mode (haggle / combat / ambient)
  overlay tracks; loops with crossfade.
- **Ambience** per-level room tone (shop hum, town crowd, forest
  wind, dungeon drips), lower volume bed under BGM.
- **Stings & one-shots** signature event audio (sale clinch,
  bailiff arrives, boss phase, day ends), short + punchy.

Minimum: ≥1 BGM per distinct location/mood, ≥1 ambient loop per
level type (shop / wilderness / dungeon / town), ≥3 signature
stings per major event class.

**4. Kinetic juice** (`yume-juice-designer`) — camera shake, screen
flash, particles, hit-pause, time-scale dips, camera lerp; tied to
signals so every meaningful event has a *felt* response. Without
juice, interactions read as "stat mutated" not "thing happened to
me." Minimum: every player-driven signature interaction (sale
clinch, attack landing, level transition) gets a juice chain;
every named beat (boss phase, ending screen, story trigger) gets a
unique juice profile.

**5. Reactive density** (`yume-game-rules-designer` + tutorial) —
the world responds to player progression: barker pools shifting per
reputation tier; NPC mid-loyalty + farewell screens firing
automatically; reactive lines on milestones (debt paid, villain
defeated); objective banner updates at every state transition.
Minimum: at every threshold the player crosses, the world shows it
cares via dialogue / sting / juice / OR objective update. Silent
thresholds = invisible progression.

## Reinforcement check

For each signature beat in the GDD's "Voice & texture" section,
verify all 5 layers pull the same emotional direction.

Example — *"the bailiff visits on Day 6"*:

| Layer | Contribution |
|---|---|
| Writing | Warning tone, formal-but-tired ("Short on the installment?") |
| Visual | Distinctive dark coat + heavier scale; nameplate "The Bailiff" |
| Audio | BGM shifts to tense low-strings on `bailiff_at_shop_door` + "official knock" sting |
| Kinetic | Red flash 0.3s + low rumble shake 0.5s + camera zoom to bailiff 1s |
| Reactive | Objective banner: "The Bailiff is here. Make sure you have enough gold." |

Five layers, one moment = felt soul.

A game where Layer 1 says "warning tone" but Layer 4 fires a
celebratory gold flash = anti-soul. The layers betray each other.

## Soul checklist (before shippable)

For each signature beat in GDD § "Voice & texture":

```
[Beat name]: <e.g. funeral cinematic>
  ☐ Writing: voice + dialogue authored
  ☐ Visual: scene/NPC distinguishable
  ☐ Audio: BGM + sting wired to signal
  ☐ Kinetic: juice profile (flash/shake/pause/zoom)
  ☐ Reactive: objective + barker-pool updates
```

Any empty box → the beat will feel hollow. Fill before ship.

## When to run the soul pass

AFTER content is wired (entities + rules + screens) but BEFORE
declaring Tier B 100%. The pass is the difference between "the
game runs" and "the game is alive."

Order (layers 2-4 parallel, they touch different files):
1. Writing (foundation — others reference its dialogue/voice)
2. Visual identity (parallel)
3. Audio (parallel)
4. Kinetic juice (parallel; profiles per signature beat)
5. Reactive density (ties them via signal wiring)
6. Reinforcement check on each signature moment

**Empirical 2026-05-08 (merchant)**: shipped with Layer 1 ~complete
(5 voice profiles, 23 item flavors, 20 barkers, 12 world-text
surfaces). User: *"i still dont feel soul."* Diagnosis: Layers 2-5
mostly empty. NPCs were cylinders (L2); no BGM (L3); few juice
rules (L4); reactive rules existed but objectives weren't
surfacing because the HUD had no objective banner (L5 partial).
Fixed via parallel passes; reinforcement check could finally run.

## Composition pass — the 6th step (2026-05-17)

The 5 layers produce INGREDIENTS. The composition pass arranges
them into a believable scene. After any major asset-gen batch
(>5 entities replaced) in a 3D scene, run BEFORE declaring done.
Past ~10 generated meshes, the bottleneck shifts from asset
quality to environment cohesion.

### 10 composition axes (checklist)

1. **Ground variation** — paths, trampled patches, biome edges.
   Single uniform texture across 80m+ reads as "prototype map"
   regardless of texture quality.
2. **Focal point** — one element anchors the eye (fire pit, well,
   shrine, doorway). Surrounding entities radiate outward.
3. **Scale consistency** — entities believable relative to player
   + each other.
4. **Tree/foliage clustering** — density falloff toward camp,
   tight clusters at perimeter, paths cut through. NOT uniform
   scatter. "The forest hugs the camp."
5. **Sky + lighting drama** — directional contrast, atmospheric
   tint shift, fog at distance. Default Godot lighting reads as
   "tech demo."
6. **Lived-in detail** — soul-bearing flavor entities at 15-25%
   of total entity count. Baskets, pots, lanterns, hanging cloth.
   Not features — texture.
7. **Foreground / midground / background** — ≥1 foreground
   silhouette framing camera (overhanging branch, fence post);
   distance fog or background mountains for the far layer.
   Without this, the frame feels flat.
8. **Color palette cohesion** — every asset same art direction.
   Per-entity `material_overrides` OR global color grading
   (WorldEnvironment adjustments). Tripo3D's default PBR can be
   inconsistent.
9. **Path / traffic logic** — footpaths between common destinations
   (sleep → fire → water → workbench). Implies trampled-ground
   texture variation along paths.
10. **Density spacing** — closer to camp = denser; far wilderness
    = sparser. Empty wilderness ≠ empty design; means "explore
    further."

### Yume primitives per axis

| axis | engine support | content support |
|---|---|---|
| 1 ground | multi-biome shader (ADR 0055) | decals + patches in level placement |
| 2 focal | n/a | level-designer arranges around anchor |
| 3 scale | `state.scale` | manual tune per follow-up |
| 4 clustering | n/a | level designer + density falloff |
| 5 lighting | `scene.json` lighting (ADR 0025) + WorldEnvironment fog/tonemap | per-scene tuning |
| 6 lived-in | n/a | content authoring |
| 7 fg/mg/bg | distance fog, Godot Decal | foreground entity placement |
| 8 palette | `material_overrides`, color grading | per-asset tint patches |
| 9 paths | decals or multi-biome ground | level-designer authoring |
| 10 density | n/a | level-designer authoring |

### Process

After asset-gen lands → BEFORE declaring scene complete, run the
10-axis checklist. Framework-gap items (multi-biome shader, decals,
WorldEnvironment exposure) become ADR proposals; content-gap items
(clustering, focal, density) become level-designer revisions.

**Empirical 2026-05-17 (aldenmere)**: after replacing 16 entities
+ ground + water, external design critique returned 10 issues —
ALL composition, none asset quality. Composition pass should have
been scheduled BEFORE the foragable batch ran. Memory at
[[feedback-compose-dont-just-generate]] codifies the pattern.

User-facing phrasing: *"asset generation alone is necessary but
not sufficient. The next pass is composition."*

## What this rule is NOT

- Not "add more particles" (juice without intent)
- Not "play music constantly" (audio without curation)
- Not "every NPC has a name" (names without voice + visual
  distinction = decoration)
- Not "more dialogue" (dialogue without audio + juice =
  text-adventure-grafted-onto-3D)

The 5 layers must be designed TOGETHER to reinforce, not
accumulated separately.
