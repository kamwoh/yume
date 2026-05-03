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
