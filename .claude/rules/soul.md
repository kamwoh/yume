# Soul — the layered workflow for "this game feels alive"

Soul isn't a single thing you author. It's the **layered density**
across writing, visual, audio, kinetic, and density channels —
specifically tuned to the GDD's stated aesthetic. A game with strong
writing but no audio feels hollow. A game with juicy combat but
characterless NPCs feels arcade. A game with all five layers loses
soul if the LAYERS DON'T REINFORCE EACH OTHER (NPC's gruff voice
needs gruff music + gruff visual silhouette + gruff combat feel).

This rule documents the soul checklist as a workflow. Skills that
contribute to a layer reference this rule.

## When this rule applies

Any GDD whose aesthetic target includes any of:

- **Fellowship** (NPCs you remember)
- **Narrative** (story you remember)
- **Submission** (rhythm + immersion)
- **Discovery** (rewarded curiosity)
- **Sensation** (raw feel)

Pure-mechanic games (chess, a falling-block puzzle, abstract puzzlers) get a
lighter version — at minimum the visual identity layer and
event-feedback juice layer.

## The 5 soul layers

Every soul-bearing game must address ALL FIVE layers. Skipping a
layer = a soul-shaped hole the player will feel without being able
to articulate.

### Layer 1 — Writing (yume-flavor-writer)

Per-NPC voice profiles, item flavor text, barker pools, world-text
surfaces, reactive prose. Output: `flavor-design.md` + entity
fields (`flavor_text`, `properties.voice`, `properties.barker_lines`).

**Soul minimum**: every named NPC has a 3-5 word voice descriptor
+ ≥3 arc-beat lines. Every named item has 1 flavor line. Every
ambient archetype has ≥3 barker variants.

**Skill responsible**: `yume-flavor-writer`

### Layer 2 — Visual identity (yume-asset-designer + engine)

NPCs distinguishable at a glance. Players must be able to look at
the screen and say "that's Garron, that's Vela, that's a generic
townie" without reading anything. Includes:

- Per-NPC silhouette/color distinction (different shirt, hat,
  posture, scale)
- **Nameplate above NPC head** showing display_name (engine widget
  — see nameplate_renderer.gd)
- Per-archetype visual variation so "warrior class customer" looks
  warrior-shaped, "noble class" looks distinguished

**Soul minimum**: every `named_npc` has nameplate + distinct visual
signature. Every customer archetype has its own mesh OR distinctive
color palette.

**Soul EXTENSION (added 2026-05-09 — visual density vocabulary)**:
NPC distinction is necessary but not sufficient. The world itself
must feel inhabited via 10 axes of authoring density (not asset
fidelity):

1. Layered ground variation (no monochrome floors)
2. Edge transitions (no hard borders)
3. Vertical depth (raised foundations, sunken pits, steps)
4. Micro-lights (FAT lamps, window glow, campfires every 8-15m)
5. Object density (~1 entity per 9-12 m² in viewport)
6. Diagonal accents (rotate every 4-6 entities by 5-30°)
7. Background framing (foreground tree clusters / walls / cliffs)
8. Soul-bearing details (15-25% purposeless flavor entities)
9. Palette discipline per district (4-5 base + 1-2 accent)
10. Silhouette readability (≥3 distinct humanoid templates)

Empirical case: 2026-05-09 user provided an isometric pixel-art
mobile-RPG reference set (12 screenshots). Even with simple pixel
assets, every frame packs 50+ entities with deliberate density.
Yume's clean code/JSON pipeline makes the framework strong; this
extension makes the OUTPUT actually inhabited.

Per-game analysis lives at `docs/games/<game>/style-references-
*.md`. Full vocabulary in `yume-asset-designer` SKILL § Visual
density vocabulary.

**Skill responsible**: `yume-asset-designer` (visual styling +
density audit) + engine (nameplate widget) + content-designer
(actually placing the soul-bearing flavor entities).

### Layer 3 — Audio (yume-audio-designer)

Three sub-layers, each non-negotiable:

- **BGM**: per-level mood music + per-mode (haggle / combat /
  ambient) overlay tracks. Loops with crossfade.
- **Ambience**: per-level room tone (shop hum, town crowd, forest
  wind, dungeon drips). Lower volume bed under BGM.
- **Stings & one-shots**: signature event audio (sale clinch,
  bailiff arrives, boss phase shift, day ends). Short + punchy.

**Soul minimum**: ≥1 BGM per distinct location/mood, ≥1 ambient
loop per level type (shop / wilderness / dungeon / town), ≥3
signature stings per major event class.

**Skill responsible**: `yume-audio-designer`

### Layer 4 — Kinetic juice (yume-juice-designer)

Camera shake, screen flash, particles, hit-pause, time-scale dips,
camera lerp. Tied to signals so every meaningful event has a
*felt* response. Without juice, all interactions read as "stat
mutated" rather than "thing happened to me."

**Soul minimum**: every player-driven signature interaction
(sale clinch, attack landing, level transition) gets a juice
chain. Every named beat (boss phase, ending screen open, story
trigger) gets a unique juice profile.

**Skill responsible**: `yume-juice-designer`

### Layer 5 — Reactive density (yume-game-rules-designer)

The world responds to the player's progression. Includes:

- Barker pools that change per reputation tier
- NPC mid-loyalty + farewell screens that fire automatically
- Reactive lines on milestones (debt paid, villain defeated)
- Objective banner updates at every state transition (per
  `.claude/rules/visual-qa.md` and yume-tutorial-designer's
  player-perspective requirement)

**Soul minimum**: at every threshold the player crosses, the world
shows it cares — via dialogue, audio sting, juice, OR objective
update. Silent thresholds = invisible progression.

**Skill responsible**: `yume-game-rules-designer` (rules wiring)
+ `yume-tutorial-designer` (objective updates)

## The reinforcement check

Soul comes from layer cross-reinforcement. When designing a
signature moment, all 5 layers should pull the same emotional
direction.

Example — *"the bailiff visits on Day 6"*:

| Layer | Contribution |
|---|---|
| Writing | Bailiff dialogue = warning tone, formal-but-tired ("Short on the installment, are you?") |
| Visual | Bailiff NPC has distinctive dark coat + heavier scale than ambient townies; nameplate "The Bailiff" |
| Audio | BGM shifts to tense low-strings on `bailiff_at_shop_door` signal; one-shot "official knock" sting |
| Kinetic | Red flash 0.3s + low rumble shake 0.5s + camera zoom to bailiff for 1s |
| Reactive | Objective banner updates: "The Bailiff is here. Make sure you have enough gold." |

Five layers, one moment. THAT is felt soul.

A game where Layer 1 says "warning tone" but Layer 4 fires a
celebratory gold flash = anti-soul. The layers betray each other.

## The soul checklist (run before declaring a game shippable)

For each signature beat in the GDD's "Voice & texture" section,
verify all 5 layers are wired:

```
[Beat name]: <e.g. funeral cinematic>
  ☐ Writing: voice + dialogue authored
  ☐ Visual: scene/NPC distinguishable
  ☐ Audio: BGM + sting wired to signal
  ☐ Kinetic: juice profile (flash/shake/pause/zoom)
  ☐ Reactive: objective + barker-pool updates
```

If any box is empty, the beat will feel hollow. Fill it before
ship.

## Empirical case (2026-05-08)

Merchant game shipped with Layer 1 (writing) ~complete: 5 voice
profiles, 23 item flavors, 20 barkers, 12 world-text surfaces.
User played and said *"i still dont feel soul."*

Diagnosis: Layers 2-5 mostly empty. NPCs all looked like cylinders
(L2 missing). No BGM (L3 missing). Few juice rules (L4 thin).
Reactive rules existed but objectives weren't surfacing because
the HUD didn't have an objective banner (L5 partial).

Fix sequence (parallel):
- L2: nameplate widget → see commit log
- L3: yume-audio-designer pass → see commit log
- L4: yume-juice-designer pass → see commit log
- L5: already addressed earlier with objective HUD banner

After all 4 layers landed, the reinforcement check could finally
be run on each signature moment.

## Process: when to run the soul pass

Run AFTER content is wired (entities + rules + screens) but BEFORE
declaring Tier B 100% [R]. The soul pass is the difference between
"the game runs" and "the game is alive."

Order of operations within the soul pass:
1. yume-flavor-writer authors writing (Layer 1)
2. yume-asset-designer wires visual identity + nameplates (Layer 2)
3. yume-audio-designer authors music + ambient + stings (Layer 3)
4. yume-juice-designer authors juice profiles per signature beat (Layer 4)
5. yume-game-rules-designer wires reactive density (Layer 5)
6. **Reinforcement check** on each signature moment

Layers 2-4 can run in parallel (they touch different files). Layer
1 is foundation (others reference its dialogue + voice). Layer 5
ties them together via signal wiring.

## Composition pass — the missing 6th step (added 2026-05-17)

The 5 layers above are CONTENT channels (writing, visual, audio,
kinetic, reactive). They produce ingredients. The **composition
pass** arranges those ingredients into a believable scene.

### When this applies

After any major asset-gen batch (>5 entities replaced) in a 3D
scene, run the composition pass BEFORE declaring scene done. Pure
asset upgrades produce "better ingredients" but not automatically
"better scenes" — past ~10 generated meshes the bottleneck shifts
from asset quality to environment cohesion.

### The 10 composition axes (run as a checklist)

For each playable scene, verify:

1. **Ground variation** — paths, trampled patches, biome edges,
   forest floor. Single uniform texture across 80m+ reads as
   "prototype map" no matter how nice the texture is.
2. **Focal point** — one element anchors the eye (fire pit, well,
   shrine, doorway). Surrounding entities radiate outward from it.
3. **Scale consistency** — every entity reads at a believable size
   relative to the player + each other. Per-entity visual QA pass
   per task_plan followup.
4. **Tree/foliage clustering** — density falloff toward the camp,
   tight clusters at perimeter, paths cut through. NOT uniform
   scatter. "The forest hugs the camp."
5. **Sky + lighting drama** — directional contrast, atmospheric
   tint shift through the day, fog at distance. Default Godot
   lighting reads as "tech demo."
6. **Lived-in detail** — soul-bearing flavor entities (axis 8)
   need to be 15-25% of total entity count. Baskets, cooking pots,
   lanterns, hanging cloth, small piles. Not features — texture.
7. **Foreground / midground / background** — at least ONE
   foreground silhouette frames the camera view (overhanging
   branch, fence post). Distance fog or background mountains
   create the far layer. Without this, the frame feels flat.
8. **Color palette cohesion** — every asset reads as the same art
   direction. Achieved either via per-entity material_overrides OR
   global color grading (WorldEnvironment adjustments). Tripo3D's
   default PBR may produce inconsistent palettes across assets.
9. **Path / traffic logic** — actor footpaths between common
   destinations (sleep → fire → water → workbench). Implies
   trampled-ground texture variation along those paths.
10. **Density spacing** — closer to camp = denser placement; far
    wilderness = sparser. Empty wilderness ≠ empty design; it
    means "explore further."

### Yume primitives that support composition

| axis | engine support | content support |
|---|---|---|
| 1 ground variation | multi-biome shader (ADR-worthy, extends ADR 0052) | level entity placement of decals / patches |
| 2 focal point | n/a | level designer arranges entities around anchor |
| 3 scale | `state.scale` per entity | manual tune per task_plan followup |
| 4 clustering | n/a | level designer + density falloff |
| 5 lighting | `scene.json` lighting block (ADR 0025) + WorldEnvironment fog/tonemap (TBD ADR) | per-scene tuning |
| 6 lived-in | n/a | content authoring (more entity types + denser placement) |
| 7 fg/mg/bg | distance fog (TBD), Godot Decal (TBD) | level placement of foreground entities |
| 8 palette | `material_overrides`, WorldEnvironment color grading (TBD) | per-asset tint patches |
| 9 paths | decals (TBD) OR multi-biome ground | level designer authoring |
| 10 density | n/a | level designer authoring |

### Process: when to invoke

After asset-gen batch lands → BEFORE declaring scene complete,
run the 10-axis checklist. Items with concrete framework gaps
(multi-biome shader, decals, WorldEnvironment exposure) become
new ADR proposals if not already queued. Items with content gaps
(clustering, focal point, density) become level-designer revision
requests.

The user-facing phrasing: *"asset generation alone is necessary
but not sufficient. The next pass is composition."*

### Empirical case (2026-05-17 aldenmere)

After replacing 16 entities + ground + water in aldenmere scene 1,
external design critique returned 10 issues. ALL were composition,
none were asset quality. Composition pass should have been
scheduled BEFORE the foragable batch ran. Memory at
[[feedback-compose-dont-just-generate]] codifies the pattern.

## What this rule is NOT

- Not "add more particles." That's juice without intent.
- Not "play music constantly." That's audio without curation.
- Not "every NPC has a name." Names without per-NPC voice +
  visual distinction is decoration.
- Not "more dialogue." Dialogue without audio + juice is text-
  adventure-grafted-onto-a-3D-game.

The 5 layers must be designed together to reinforce, not
accumulated separately and stacked.
