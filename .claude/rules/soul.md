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

Pure-mechanic games (chess, Tetris, abstract puzzlers) get a
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

**Skill responsible**: `yume-asset-designer` (visual styling) +
engine (nameplate widget)

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

## What this rule is NOT

- Not "add more particles." That's juice without intent.
- Not "play music constantly." That's audio without curation.
- Not "every NPC has a name." Names without per-NPC voice +
  visual distinction is decoration.
- Not "more dialogue." Dialogue without audio + juice is text-
  adventure-grafted-onto-a-3D-game.

The 5 layers must be designed together to reinforce, not
accumulated separately and stacked.
