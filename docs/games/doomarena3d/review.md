# DoomArena3D — design review (round 3, 13-axis)

_Date: 2026-05-03_
_Reviewer: yume-game-reviewer (13-axis)_
_GDD: docs/games/doomarena3d/GDD.md (v2.5)_

## Verdict
**accept** (with 4 minor housekeeping notes — not blockers)

Round 2 (12-axis) accepted v2 with multi-weapons "deferred to v3" — a
deferral the round-3 reviewer-skill (Axis 1 hardened, Axis 13 added)
now explicitly forbids when the genre claim is "Doom-style." v2.5
closes the gap (3-weapon arsenal + functional walls/pillars via ADR
0004). The GDD now passes all 13 axes.

## Per-axis findings (round 3)

| Axis | Verdict | Notes |
|---|---|---|
| 1. Mechanical depth | ✓ PASS | 4 enemies + 3 weapons. Genre-claim minimum (≥3 enemies, ≥2 weapons for shooter) **finally** met. The deferral trap is closed. |
| 2. Strategic depth | ✓ PASS | Real decisions emerge: which weapon for which enemy, when to swap mid-fight, ammo budgeting (1/3/5 cost per shot type) |
| 3. Pacing | ✓ PASS | 3 named beats + boss spawn beat (unchanged from r2) |
| 4. Feedback | ✓ PASS | Audio cues per cascade + shake + flash + HUD weapon indicator |
| 5. Aesthetic match | ✓ PASS | Challenge real (weapons + enemies + cover decisions); Sensation supported (effects against real walls now); Submission via score-chase loop |
| 6. Scope honesty | ✓ PASS | New scope explicit (weapons in v2.5, blocks_motion in v2.5, future deferrals named) |
| 7. Adversarial pokes | ✓ PASS WITH NOTE | See housekeeping note #1 (rocket-vs-wall frustration) |
| 8. Content scope | ✓ PASS | Score-chase 90s arcade with weapon-mastery learning curve |
| 9. Signature moments | ✓ PASS | Boss spawn, Rush siren, slow-mo win, plus emergent "I should have had rocket out" mid-fight moments |
| 10. Theme / identity | ✓ PASS WITH NOTE | "Plasma bolt" name reads generic for industrial mining colony — minor (note #2) |
| 11. Replay value | ✓ PASS | Best-stats + score chase + weapon-mastery curve |
| 12. Real-UX | ✓ PASS WITH NOTE | Weapon-switch keys need controls-hint visibility (note #3) |
| 13. Spatial design | ✓ PASS | level-design.md is the source of truth; GDD correctly defers spatial detail. blocks_motion now functional. |

All 13 axes meet bar.

## Housekeeping notes (not blockers)

### 1. Rocket-vs-wall frustration vector

The GDD says rockets cost 5 ammo and reload in 15 ticks (0.75s).
With pillars + walls now solid (ADR 0004), a misfired rocket that
hits a pillar instead of an enemy is a real failure mode — 5 ammo
gone, weapon on cooldown, target still alive. That can feel cheap.

Recommendations (any one is fine):
- **a)** Make rocket explosion visually impactful when it hits a
  wall (big spark, screen shake, audio thud) so the player FEELS
  the wasted shot rather than just seeing it disappear. Acceptance
  via spectacle.
- **b)** Future `ignores_obstacles` tag for projectiles, applied
  only to rockets in v2.5. The GDD already flagged this as v3
  scope — could be promoted if frustration testing shows it.
- **c)** Slight ammo refund on wall hit (e.g. -2 instead of -5)
  via a contact rule. Mechanical but cheap.

I lean (a) for v2.5 — preserves the design tension ("aim well or
waste a shot") without engine work.

### 2. Weapon-theme alignment

Theme is "Containment Chamber 7 / corrupted miner-drones in a
derelict mining colony." Weapon names:
- **Plasma bolt** — reads generic sci-fi, weak theme tie-in
- **Shotgun** — fine, fits industrial-blue-collar marine
- **Rocket** — fine, fits demolition/breach-charge fiction

Minor improvement: rename "plasma bolt" to something that grounds
in the mining-colony fiction. Suggestions: **rivet gun** (matches
industrial theme), **induction beam** (mining tool repurposed),
**arc lance** (energy weapon adapted from welding equipment).

Not blocking — current name is functional. Strengthens identity if
addressed.

### 3. Controls hint must include weapon keys

The GDD specifies `controls_hint` as "WASD walk · Mouse aim · SPACE
fire · ESC release cursor · R restart · Q quit." After v2.5, this
needs the weapon hotkeys: **"1/2/3 swap weapon"** appended.

Without this, players who don't read the GDD will never discover the
shotgun or rocket exist. New-player onboarding fail.

Trivial fix at content/HUD-config time. Just a reminder.

### 4. Shotgun pellet visual distinction

5 pellets fired simultaneously in a ±15° spread can look noisy
overlapping with the crosshair. Recommend pellet visual differs from
plasma bolt: smaller core (radius 0.10 vs 0.18), paler color (off-
white instead of yellow), shorter trail. So the player can read at
a glance what they fired.

Not in the GDD — will need to be specified during asset-designer
phase or content-designer phase.

## Reasoning summary

Round 2 was the ideal "revise → accept" arc (theme + enemies +
phases addressed round-1 gaps). But round 2 also accepted a "v3
deferral" of multi-weapons that turned out to be the user's first
playtest reaction ("where are the weapons? it's a doom game right?").
That triggered the reviewer-skill update: Axis 1 genre-claim
minimums declared NOT deferrable. Axis 13 added because the same
GDD also passed v2 review with no spatial design and shipped as a
flat void.

Round 3 (this review) verifies that v2.5 closes BOTH gaps. It does:
3 weapons specified with distinct ballistic profiles + tactical
roles + ammo costs + cooldowns; walls/pillars now physically
solid via the ADR 0004 engine primitive. Both changes preserve the
v2 aesthetic intent (Challenge / Sensation / Submission) while
deepening the play.

The 4 housekeeping notes are polish not blockers. Designer can ship
the GDD to systems-designer + content-designer for v2.5
implementation.

**Pipeline can proceed**: systems-designer (per-weapon fire rules,
weapon-switch input rules, fire-cooldown decrement) → content-
designer (3 bullet entity defs, updated player state, weapon-switch
input mappings, HUD weapon indicator) → asset-designer (pellet
visual subtle differentiation per note #4) → qa-tester (scenarios:
shotgun fires 5 pellets, rocket cooldown enforced, weapon-switch
state changes).

## What round 3 validates about the reviewer

This is the case the reviewer-skill update was designed to catch:
- v2 reviewer accepted with 1 weapon → user playtest reaction caught it
- Reviewer skill updated → Axis 1 hardened
- v2.5 GDD revised to add weapons → v3 review verifies fix lands

The deferral trap is now a permanent guardrail. Future GDDs that
claim genre-X but punt the genre-X minimums will be rejected at the
text stage instead of being discovered at "where is the {iconic
genre-X mechanic}?" playtest.

Compare to history:
- doomarena3d v1 → revise (12-axis): 8 gaps flagged
- doomarena3d v2 → accept (12-axis): too lenient on weapon deferral
- doomarena3d v2.5 → accept (13-axis): the version we should have
  had at v2 if the reviewer had been correctly calibrated then

---

## Genre review (shooter, 10-axis)

_Date: 2026-05-03_
_Reviewer: yume-shooter-reviewer (10-axis FPS-strictest layer)_
_Generic 13-axis status: ACCEPT (round 3 above)_

### Verdict: **revise** (4 axes need GDD updates — implementation
already covers most, but the GDD doesn't reflect)

This is a **retroactive** review. The doomarena3d v2.5 GDD predates
the shooter-reviewer skill. The 10-axis check finds 4 places where
the GDD is silent or stale on FPS-specific concerns that an FPS-aware
reviewer would have caught at GDD time. Most of these were fixed
reactively at runtime (walk speed tune, bullet-stuck-on-wall bug,
diagonal motion fix). The genre-strict reviewer would have caught
them at text time.

### Per-axis findings

| Axis | Verdict | Notes |
|---|---|---|
| S1. Movement profile | ✗ REVISE | GDD's "Player verbs" table still cites `velocity_set_relative forward=4.5` (the v2.0 design); actual implementation uses `velocity_add_relative forward=2.0` post diagonal-fix + speed-tune. No top-speed equilibrium target stated, no diagonal handling spec. |
| S2. Weapon distinctness | ✗ REVISE | All 3 weapons emit the same `shoot` audio cue per the audio table (line 264). Plasma + shotgun + rocket are visually different but **acoustically identical** — fails the "weapons must FEEL different" check. |
| S3. Weapon-enemy matchup | ✓ PASS | Implicit but coherent: rocket→demons/boss (3 dmg vs 2/10 HP), plasma→imps (1 HP), shotgun close-range. Could be made explicit as a matchup table (note for v2.6). |
| S4. Ammo economy | ✓ PASS WITH NOTE | Numbers are present (start 30, +5/7s, costs 1/3/5) but no math line showing income vs expenditure. Math checks out (income 0.71/s, peak fire ~5/s plasma → tension at ~7s). Add the math line for clarity. |
| S5. Projectile-obstacle policy | ✗ REVISE | GDD references `blocks_motion` (ADR 0004) for walls + pillars but is **silent on what bullets do at a wall**. Empirically caused the "bullet floats up against wall" bug at v2.5 playtest; engine fix landed (3D AABB) but the GDD still doesn't specify the policy. |
| S6. Y-axis policy | ✗ REVISE | Y locked at 0 for creatures ✓, pitch-aim documented ✓, bullet Y velocity formula in implementation ✓ — but the GDD doesn't say bullets at altitude clear walls (the 3D-AABB behavior we just shipped). Future readers see "blocks_motion" and assume 2D blocking. |
| S7. Hit / kill feedback | ✓ PASS | Audio table (line 262) cleanly separates shoot / hit / kill / hurt. Camera shake on kill, red flash on damage, score increment animation. |
| S8. Sightline + cover | ✓ PASS | Cover handled in `level-design.md`; pillars + walls described as both visual landmarks AND ranger-flank break-cover opportunities. Bullet-vs-pillar interaction implicit (same as walls per S5). |
| S9. Threat differentiation | ✓ PASS | Ranger has a behaviorally distinct AI (stops + fires) — not just stat-distinct. Imp + demon are stat-distinct (rusher / tank), which is acceptable since ranger + boss provide AI variety. |
| S10. Restart UX | ✓ PASS | R/ESC/Q lose screen + <1s retry target + best-stats persistence. Standard FPS arcade flow. |

### Concrete revision requests

#### Axis S1 — Movement profile

Replace the "Player verbs" table's movement rows with:
```
| Walk forward | input move_north (HOLD) | velocity_add_relative forward=2.0 (per-tick add) |
| Walk back    | input move_south (HOLD) | velocity_add_relative forward=-2.0 |
| Strafe right | input move_east  (HOLD) | velocity_add_relative strafe=-2.0 |
| Strafe left  | input move_west  (HOLD) | velocity_add_relative strafe=2.0 |
```

Add a "Movement profile" subsection BEFORE Player verbs:
```
- **Top speed**: 3.0 m/s equilibrium under sustained input (drag=8.0,
  tick_seconds=0.05 → eq = add * (1−drag*dt) / (drag*dt) = 2.0 * 1.5 = 3.0)
- **Diagonal**: W+A both fire each tick; contributions sum
  (additive); √2-factor diagonal slightly slower than cardinal
- **Y-axis**: locked at 0 for creatures (no jumping/falling), pitch-aim
  free for camera (clamped ±π/2 - 0.05)
```

#### Axis S2 — Weapon audio distinctness

Update audio table (line 262) to assign distinct sounds:
```
| Plasma fire | shoot         | snappy energy bolt |
| Shotgun fire | shotgun_blast (NEW: low-frequency boom, ~120Hz, 0.18s) | thunky industrial blast |
| Rocket fire | rocket_launch (NEW: rising whoosh + thump, ~80→200Hz, 0.3s) | heavy launch |
```

Add the 2 new sounds to `data/sounds.json` during implementation.

#### Axis S5 — Projectile-obstacle policy

Add a "Projectile-obstacle policy" subsection in Combat loop:
```
- Player bullets vs walls: STOP at wall (Doom-feel — aim matters, no
  shoot-through-cover exploits)
- Rocket on wall hit: removed via lifetime expiration; visual
  spark feedback so wasted shots are visible
- Bullets at altitude > wall height (3m): clear walls naturally
  (3D AABB engine behavior per ADR 0004 v2)
- Enemy bullets vs walls: STOP at wall (cover protects player from
  rangers — supports tactical pillar-flank pattern)
```

#### Axis S6 — Y-axis policy

Add a "Y-axis policy" subsection:
```
- Pitch aim: free, clamped ±π/2 - 0.05
- Bullet velocity Y component: sin(pitch) * weapon.speed
- Bullets at altitude > 3m clear walls (3D AABB blocks_motion check)
- Creatures: Y locked at 0 (creature_bounds rule)
- No jumping, no gravity, no falling — flat XZ combat for v2.5
```

### Reasoning summary

The shooter-reviewer's value-add over the generic 13-axis is
visible here. Generic accepted v2.5 with 4 latent gaps that all
became runtime bugs OR will become readability bugs:
- S1 → diagonal movement reactive fix (engine work)
- S2 → "all weapons sound the same" — playtest hasn't surfaced yet
  but will
- S5 → bullet-stuck-on-wall bug (3D AABB reactive engine fix)
- S6 → bullet behavior at altitude not documented (future
  contributors / level designers won't know what to expect)

If shooter-reviewer had run on the v2.5 GDD, all 4 would have been
caught at text-time. Engine work for #1 and #5 still required, but
the GDD revision would have flagged the need pre-implementation
instead of post-playtest.

### What this validates about the genre-strict architecture

This is the empirical case for genre-specific reviewers. The
generic 13-axis correctly accepted (the GDD passed all 13 generic
axes). But "shooter" has 10 additional concerns that need a genre-
aware checker. The 4 REVISE items here are not generic-reviewer
failures — they're shooter-specific gaps the generic reviewer can't
see by definition.

The pipeline now has the structure to catch this at GDD time:
1. yume-game-reviewer (13-axis floor) → accept
2. yume-shooter-reviewer (10-axis ceiling, strictest) → must also accept

Both layers must accept before systems-designer touches the GDD.
