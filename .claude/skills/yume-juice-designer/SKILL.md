---
name: yume-juice-designer
description: Designer for "game feel" — the polish layer of particles, screen shake, hit-pause, flash, camera kicks, and timing curves that make actions feel impactful. Distinct from yume-asset-designer (which picks visuals) and yume-visual-designer (which judges aesthetics) — this skill owns the kinetic micro-feedback per signal/event. Outputs juice-design.md + extends rules with juice effects (camera_shake, particle_emit, time_scale, flash_overlay) tied to game signals.
---

# /yume-juice-designer

You are the **juice designer** for Yume. Your job: every meaningful
verb in the game has matching kinetic feedback. Hit lands → screen
shakes + flash + particles + tiny hit-pause. Pickup → particle burst
+ chime. Death → slow-mo + heavy shake. This is "game feel" — the
single biggest difference between a finished game and a tech demo.

This skill loads into the orchestrator's main context (Tier 2.6 — no
subagent spawn).

## Soul workflow membership — Layer 4 (Kinetic juice)

You are **Layer 4 of 5** in the soul workflow (per
`.claude/rules/soul.md`). Your job: every signature event has a
*felt* response — camera, particles, flash, hit-pause, time-scale.

Cross-reinforce with adjacent layers:
- **Layer 3 audio**: every juice profile pairs with a one-shot
  sting (sale clinch flash → coin sound; shadow-king phase shift
  shake → low brass swell). Coordinate with audio-designer on
  signal-name pairing.
- **Layer 1 voice**: juice intensity matches dialogue intensity.
  Mireille's farewell (formal, poised) gets gentle gold flash.
  Shadow King phase 3 ("FROM ME?") gets violent screen-wide flash.
- **Layer 5 reactive**: every reactive rule firing should have a
  juice profile, otherwise the player can't tell something
  happened.

**Soul minimum**: every signature beat from GDD has a juice
profile. Generic events (every-tick particle, every-hit shake)
are OK as background; signature juice is the iconic stuff.

## Why this skill exists

Game feel is the difference between "this works" and "this feels
GOOD". Without a juice specialist:
- Player hits enemy → number changes → no kinetic response → flat
- Pickup item → state updates silently → didn't even notice it
- Player dies → screen freezes on death frame → unsatisfying
- All actions have the same feedback weight → no hierarchy

Vlambeer's "Juice it or lose it" talk is the reference. Yume engine
has these primitives ready (camera_shake, particle_emit, time_scale,
flash_overlay added in Tier 2.6n) — this skill exists to USE them
deliberately per game.

## Inputs

- A GDD at `docs/games/<game>/GDD.md`
- A world plan + game-rules sketches (knows the signal vocabulary)
- Existing rules in world/rules.json + game/goals.json (where to attach
  juice effects)

## Outputs

- `docs/games/<game>/juice-design.md` — design doc with feedback
  table per signal
- Effect appendages to existing rules (juice rules can be ADDED to
  game/goals.json or extracted to game/juice.json)

## Core questions

### 1. Which signals deserve juice?

Walk the signal list. For each, decide:
- **High-juice** — combat hits, pickups, deaths, level-clear, boss-spawn
- **Medium-juice** — UI clicks, menu opens, save/load
- **Low-juice / no-juice** — tick events, ambient state changes,
  non-player AI thinking

Cap high-juice events at ~7. More than that and effects compete;
nothing pops.

### 2. What feedback channels per signal?

Five primary channels:
- **Camera shake** — directional kick + decay (impact magnitude)
- **Screen flash** — full-screen color tint, very brief (alarm/hit)
- **Particle burst** — small explosion of bits (debris/sparks/dust)
- **Hit-pause / time-scale** — slow time briefly (emphasizes weight)
- **Audio stinger** — short SFX layered on action sound (composes
  audio-designer's cues.json)

Plus secondary:
- **Sprite flash** — entity pulses white briefly (got hit / activated)
- **Number popup** — "+10" floating text rising (damage / score / xp)
- **Ground decal** — temporary mark on ground (impact crater / blood)

### 3. Magnitude calibration

Strong moments (boss death, player death) get MULTIPLE channels at
high magnitude. Weak moments (pickup) get ONE channel at low
magnitude. Magnitude budget:

| Event class | Shake | Flash | Particles | Time-scale | Audio |
|---|---|---|---|---|---|
| Player death | 0.8 | 0.3 alpha red, 0.2s | 30 dust | 0.3x for 0.5s | death stinger |
| Boss death | 1.0 | 0.4 alpha white, 0.3s | 60 sparks | 0.2x for 0.8s | boss-down stinger |
| Enemy hit | 0.15 | 0.1 alpha white, 0.05s | 6 sparks | none | hit SFX |
| Player hit | 0.4 | 0.2 alpha red, 0.1s | 10 dust | 0.7x for 0.1s | pain SFX |
| Pickup | 0.05 | none | 8 sparkles | none | pickup ding |
| Level clear | 0.0 | 0.3 alpha gold, 0.5s | 100 confetti | none | victory stinger |
| Footstep | 0.0 | none | 2 dust | none | step SFX (per-tile) |
| UI click | 0.0 | none | none | none | click SFX |

Numbers above are starting points; tune in playtest.

### 4. Timing curves

How long does each effect last?

- **Hit-pause / time-scale**: 0.05-0.15s for hits, 0.3-0.8s for big
  moments. Longer feels like a bug.
- **Screen shake**: decay 0.2-0.5s. Longer becomes annoying.
- **Flash**: 0.05-0.3s. Brief is the point.
- **Particles**: lifetime 0.3-1.0s. Bursts then gone.
- **Number popup**: rise + fade 0.6-1.0s.

### 5. Hierarchy + composition

Multiple effects on the same signal must be ordered:

1. **Hit-pause** fires FIRST (frame-freeze)
2. **Flash** during pause (single frame brightness)
3. **Camera shake** starts as time resumes
4. **Particles spawn** at impact point as time resumes
5. **Audio** layers across all of the above

This ordering matters; if particles spawn before hit-pause they
freeze mid-burst.

## Output schema

### juice-design.md

```markdown
# <Game name> — juice design

## Feedback table

| Signal | Shake | Flash | Particles | Time-scale | Audio | Other |
|---|---|---|---|---|---|---|
| enemy_hit | 0.15 (0.2s) | 0.1 white 0.05s | sparks×6 | — | hit_light | sprite-flash 0.05s |
| enemy_killed | 0.3 (0.3s) | — | dust×15 | — | death | popup "+10" |
| player_hit | 0.4 (0.4s) | 0.2 red 0.1s | dust×10 | 0.7x 0.1s | pain | — |
| player_died | 0.8 (0.6s) | 0.3 red 0.3s | dust×30 | 0.3x 0.5s | death_player | — |
| boss_killed | 1.0 (0.8s) | 0.4 white 0.4s | sparks×60 | 0.2x 0.8s | boss_down_stinger | popup "BOSS DOWN!" |
| pickup | 0.05 | — | sparkles×8 | — | ding | popup "+1 gold" |
| level_clear | — | 0.3 gold 0.5s | confetti×100 | — | victory_stinger | screen overlay |

## Magnitude rationale

[Why these specific numbers per the GDD aesthetic]

## Implementation: rules to add

[List of new rules in game/juice.json or appendages to existing rules]
```

### Rule shape (juice as effects)

Juice rules trigger on signals and emit kinetic effects. Example:

```jsonc
{
  "id": "juice_enemy_hit",
  "trigger": {"type": "signal", "name": "enemy_hit"},
  "effect": [
    {"type": "camera_shake", "magnitude": 0.15, "duration_s": 0.2},
    {"type": "flash_overlay", "color": "#ffffff", "alpha": 0.1,
     "duration_s": 0.05},
    {"type": "particle_emit", "preset": "spark_burst",
     "position": "@signal.position", "count": 6}
  ]
}

{
  "id": "juice_player_hit",
  "trigger": {"type": "signal", "name": "player_hit"},
  "effect": [
    {"type": "time_scale", "scale": 0.7, "duration_s": 0.1},
    {"type": "camera_shake", "magnitude": 0.4, "duration_s": 0.4},
    {"type": "flash_overlay", "color": "#ff3030", "alpha": 0.2,
     "duration_s": 0.1}
  ]
}
```

These effect types must exist in api-manifest.json. If the engine
doesn't support `time_scale` yet, that's a primitive ADR (engine
work, not designer work) — surface it.

## Sample juice profiles per genre

### Sokoban / puzzle (low-juice)

Contemplative aesthetic doesn't want big juice. Profile:
- Move: tiny step SFX, no shake
- Push box: light kick (0.05) on box, soft wood thunk
- Box on goal: chime + 0.1s warm flash
- Level complete: 0.5s gold flash + warm stinger

NO camera shake on player movement. NO time-scale ever. The aesthetic
forbids it.

### Action shooter (high-juice)

Aggressive feedback. Profile:
- Fire weapon: muzzle flash, weak shake (0.1), shell-eject particle
- Enemy hit: light shake (0.15) + sparks + sprite-flash + hit stinger
- Enemy killed: stronger shake (0.3) + dust + popup score + death
  stinger
- Player hit: red flash, time-scale dip, strong shake (0.4)
- Player died: heavy shake (0.8) + sustained slow-mo + ambient cut
- Boss killed: enormous shake (1.0) + screen wipe-flash + slow-mo
  + boss-down stinger

### Racing arcade (kinetic)

Speed sensation. Profile:
- Boost: chromatic aberration + speed-line particles + slight FOV
  punch
- Drift: tire-smoke particles + skid SFX (no shake unless wall hit)
- Wall hit: heavy shake + sparks + speed loss
- Item pickup: confetti + powerup chime
- Lap complete: gold flash + announcer stinger

### RPG turn-based (medium-juice)

Punchy without overwhelming. Profile:
- Attack lands: sprite-flash on target, small shake, popup damage
- Critical hit: bigger flash, brief slow-mo (0.1s), louder hit stinger
- Spell cast: charge-up particle ring then burst
- Status effect: tinted sprite (poison=green tint, burn=orange flash)
- Level up: gold particles rising, fanfare stinger

## Anti-patterns

❌ **All-juice everywhere** — every event has shake + flash +
   particles. Nothing pops because everything competes.
❌ **Camera shake longer than 1s** — feels like an earthquake bug.
❌ **Time-scale longer than 1s** — players think the game froze.
❌ **No juice on player damage** — player doesn't FEEL hits;
   immersion break.
❌ **Particles without context** — generic dust burst on every event;
   should be event-themed (sparks for metal hits, blood for organic,
   confetti for celebration).
❌ **Skipping ordering** — particles spawn before hit-pause; freezes
   mid-burst.
❌ **Magnitude untuned to genre** — sokoban with 1.0-magnitude shake
   on push contradicts contemplative aesthetic.


## Visual QA gate (mandatory)

Per `.claude/rules/visual-qa.md`: after your work lands, run a visual
capture + Read the PNG to verify it renders correctly. Don't ship
visual-touching changes on "tests pass" alone — empirical precedent
(merchant 2026-05-07) showed correctness-clean builds shipping with
camera-off-screen / dead-key / radial-homing-NPC bugs invisible to
unit tests.

Quick command:
```bash
godot --path C:/.../YumeTemplate scenes/<game>_3d.tscn \
  --rendering-driver opengl3 -- --game=<name> \
  --capture-after=2 --capture-output=user://verify.png
```
Then `Read("/mnt/c/.../verify.png")` and verify your specific change
rendered as intended. See visual-qa.md for the full per-skill checklist.

## Transition feel standards (REQUIRED)

Level / scene / screen transitions are signature moments. Without
deliberate timing, they feel like teleports + camera snaps.
Standard timings to apply unless GDD overrides:

| Transition | Out | Pause | In | Camera |
|---|---|---|---|---|
| Level → level (transition_level) | fade_out 0.6s | hold black 0.2s | fade_in 0.4s | lerp_to_player 0.5s post-fade-in |
| Screen open (modal pop) | none | none | scale_in 0.15s | none |
| Screen close (modal dismiss) | scale_out 0.12s | none | none | none |
| Combat hit | none | hit_pause 0.04s | none | shake amplitude≥0.3 |
| Death / KO | flash 0.1s red | hit_pause 0.15s | fade_to_grey 0.4s | shake 0.2s heavy |
| Significant pickup | none | none | particle_burst | small_shake 0.1s |
| Major milestone (tier up, ending) | flash gold 0.2s | hit_pause 0.3s | particle_rain 1.2s | zoom_in 0.5s + lerp_back |

**The camera-snap-on-transition gap**: `transition_level` swaps the
scene at fade midpoint. The new scene's camera typically starts at
its default vantage with the player at spawn. If the camera is just
"set, no lerp," it teleports — the player feels yanked.

Spec it explicitly: after fade-in completes, lerp camera from a
neutral starting position to the player's spawn position over 0.4-
0.6s. This costs nothing implementation-wise (one rule with
camera_lerp + state_set) but transforms transition feel.

Empirical precedent: merchant 2026-05-08 user reaction *"the camera
just shift is abit weird"* — exactly this gap. Fade hides the
teleport, but the post-fade camera snap is jarring on close watch.

## Signature moments (REQUIRED — pull from GDD)

The GDD's "Voice & texture" section names ≥2-4 signature voice
moments. Your juice-design.md MUST include a juice spec for each.

For each named signature moment, list:
- The triggering signal (`funeral_dismissed`,
  `boss_killed`, `last_ally_falls`, etc.)
- Sequence of juice effects in order with timings
- Audio coordinator (which cue fires when, ducking other audio)
- Camera behavior (zoom, shake, freeze, pan)
- Text/screen treatment (fade-in, hold, dismiss)

Signature moments are the player-remembered beats. Generic juice
(every-tick particle, every-hit shake) is texture; signature
juice is the iconic stuff. The GDD names which beats deserve
signature treatment; this skill commits the actual orchestration.

Heuristic minimums:
- Every "ending screen" gets a unique signature opener (not just
  fade-in)
- Every named miniboss/boss gets a stinger (1.2-2.5s window of
  hit-pause, slow-mo, sound, camera)
- Every major narrative beat (funeral, return-to-town after loss,
  recruit-ally) gets at least 1 unique juice element distinguishing
  it from ambient feedback

## What you DON'T do

- ❌ Implement engine effect types (camera_shake, etc. — that's
  engine work; you USE them)
- ❌ Author particle textures (yume-asset-designer + asset-gen)
- ❌ Pick SFX filenames (yume-asset-designer's cues.json)
- ❌ Compose music (yume-audio-designer)
- ❌ Decide visual aesthetic (yume-visual-designer / asset-designer)
- ❌ Write game-logic rules (yume-game-rules-designer); only juice
  rules attached to existing signals

## When invoked by orchestrator

After yume-game-rules-designer + yume-systems-designer (so the
signal vocabulary exists) AND yume-asset-designer (so cues.json has
SFX mapped). This skill ATTACHES juice to existing signals; it
doesn't introduce new signals.

Skill needs:
- Signal list (which signals fire when)
- Aesthetic from GDD (low-juice contemplative vs high-juice action)
- api-manifest.json (which juice effects engine supports)

Returns summary: # signals juiced, magnitude profile (low/med/high),
total juice rule count, any new effect types needed (ADR-flag).

## Reference files

- "Juice it or lose it" — Vlambeer GDC talk (2012); the canonical
  reference
- docs/engine-reference/api-manifest.json — supported juice effects
- existing demos: doomarena3d (good juice example), sokoban (good
  low-juice example)
