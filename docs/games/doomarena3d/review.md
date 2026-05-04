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

---

## Round 4 — post-engine-cleanup re-review (2026-05-04)

_Reviewer: yume-game-reviewer (13-axis) + yume-shooter-reviewer (10-axis)_
_Trigger: engine cleanup landed — creature_bounds + projectile_floor_despawn content rules dropped, replaced by scene.ground primitive (clamp creatures + despawn projectiles below ground.y). Walls already handle XZ via blocks_motion. 3 mechanisms → 2._

### Verdict: **accept**

No regressions. The cleanup makes the design CLEANER without changing mechanics. GDD updated to reflect:
- Rule inventory refreshed (was stale — listed 17 rules from v2 implementation; v2.6 has ~25 rules with weapons + signatures + ranger AI).
- "Boundary unification" added to in-scope list to document the engine-level move.

### Per-axis check

All 13 generic + 10 shooter axes still pass. The cleanup affects:

- **Axis 6 (Scope honesty)** — IMPROVED. GDD now says "engine handles XZ via blocks_motion, Y via ground primitive" rather than maintaining redundant content rules.
- **Axis S5 (Projectile-obstacle policy)** — UNCHANGED. Bullets stop dead at walls (post-tunneling-fix); below-ground bullets despawn (post-cleanup ground primitive replaces the lifetime-zero formula).
- **Axis S6 (Y-axis policy)** — IMPROVED. "Creatures locked at Y=0" now an engine guarantee (ground.clamp_tags), not a per-game rule.

### Note for future

The `ground` primitive is now part of Yume's engine surface. Future shooters get Y-clamp + projectile-despawn-below for free via scene.json. TD games can use it for "off-the-edge" elimination. Sim games can use it for "fish below water surface" cleanup. Worth adding to docs/30_framework_primitives.md alongside blocks_motion as engine-recognized scene config.

---

## Round 5 — multi-chamber campaign (v3.0) review (2026-05-04)

_Reviewer: yume-game-reviewer (13-axis)_
_Trigger: GDD updated to v3.0. ADR 0006 multi-level architecture landed; doomarena3d expands from single-arena 90s loop into 3 sequential containment chambers with persistent player loadout. Per-chamber clear conditions: score=5 (Outer), score=20 (Foundry), boss-kill (Core)._

### Verdict: **accept with notes**

The multi-chamber expansion is a structural upgrade, not feature creep. Total play time stays in the same 90-120s envelope; what changes is *shape* — three named beats with different layouts + enemy compositions instead of one uniform loop. The v2.5 base is preserved as Chamber 2 ("The Foundry"); chambers 1 and 3 frame it. Theme alignment IMPROVES (3 sealed containment chambers fits the fiction tighter than 1 generic arena did). 5 notes for revision before content-designer stage — none are blockers.

### Per-axis findings (round 5)

| Axis | Verdict | Notes |
|---|---|---|
| 1. Mechanical depth | ✓ PASS | 4 enemies + 3 weapons + 3 chambers with different enemy mix. Chamber 1 (imps only) gates chamber 2's mixed composition naturally — depth revealed gradually instead of front-loaded. Genre-honest: still a Doom-style shooter. |
| 2. Strategic depth | ✓ PASS, IMPROVED | Persistent-no-refill loadout adds a meta-resource decision: "do I burn shotgun on chamber 1 imps or save for chamber 2 demons?" New axis of strategy v2.5 didn't have. |
| 3. Pacing | ✓ PASS WITH NOTE | See note #1 (wave-phase ambiguity across chambers). |
| 4. Feedback | ✓ PASS WITH NOTE | See note #2 (chamber-transition needs its own audio+visual beat). |
| 5. Aesthetic match | ✓ PASS WITH NOTE | See note #3 (Submission aesthetic vs chamber-context-switching). |
| 6. Scope honesty | ✓ PASS | "Multiple arenas / level progression — single chamber" REMOVED from out-of-scope list. Honestly notes "v3.0 REV" on the in-scope entry citing ADR 0006. Clean. |
| 7. Adversarial pokes | ✓ PASS | Score thresholds can't be gamed (imps spawn on cooldown; player must kill). No softlock from low HP between chambers (pickups still spawn per-chamber). Persistent state across transitions is by design (engine handles teardown — see note #4). |
| 8. Content scope | ✓ PASS | Total estimated playtime: chamber 1 (~15-20s @ 1.5s spawn × 5 kills) + chamber 2 (~45s @ 2s × 15 more) + chamber 3 (~20-40s boss) = ~90-120s. Same envelope as v2.5's 90s arcade. NOT feature creep — it's restructured time, not added time. |
| 9. Signature moments | ✓ PASS | 3 named beats: Outer-Containment-clear (first transition), The-Foundry-tactical-flank (mid-game), Core-Containment-boss (climax). Each chamber's spatial signature differentiates them. |
| 10. Theme / identity | ✓ PASS, STRENGTHENED | "Three sealed containment chambers" fits the Containment-Chamber-7 fiction tighter than a single arena did. Ascending threat tier (Outer → Foundry → Core) maps to industrial-facility containment logic. STRONG PASS. |
| 11. Replay value | ✓ PASS WITH NOTE | See note #5 (per-chamber stats / speedrun framing). |
| 12. Real-UX | ✓ PASS WITH NOTE | See note #4 (death-restart policy across chambers — checkpoint or full restart?). |
| 13. Spatial design | ✓ PASS | Each chamber's layout (28×28 simple / 44×44 tactical / 44×44 sparse) matches its enemy mix. Defers concrete coordinates to per-chamber level-design files (correct — GDD shouldn't have coordinates). |

### Notes for revision (none blocking)

#### Note 1 — Wave-phase beats across chambers (Axis 3)

The v2.5 GDD has 3 named phase beats (Calm 0-30s / Mixed 30-60s / Rush 60-89s) tied to a single 90-second timer. v3.0 adds 3 chambers, each with its own internal pacing.

Question the GDD doesn't answer: do the Calm/Mixed/Rush beats apply per-chamber, only to chamber 2 (the original arena), or are they retired in v3.0?

Most likely intent: chamber 1 = Calm-equivalent (imps only), chamber 2 = Mixed-equivalent (composition pressure), chamber 3 = Rush-equivalent (density + boss). The 3-phase wave structure maps naturally onto the 3-chamber structure — this should be made explicit.

Recommendation: add a sentence to the Campaign-structure section: "Chambers map to wave-beat archetypes — Outer = Calm (onboarding), Foundry = Mixed (composition pressure), Core = Rush + Boss (climax). Per-chamber spawn intervals retire the original elapsed-time-based phase rules."

This also clarifies that v3.0 REPLACES the phase-beat rules with per-chamber structure — they're the same idea expressed differently, not duplicated systems.

#### Note 2 — Chamber-transition beat (Axis 4)

Each chamber transition is a moment the player should FEEL: a score threshold hit, the room reconfigures, fight resumes. v2.5 specified audio cues per cascade. v3.0 doesn't specify what happens at transition.

Recommendation: add a row to the audio-per-cascade table:
| Chamber clear / transition | `chamber_breach` (NEW: low descending tone + reverb tail, 0.8s) | "Containment broken — next chamber" |

And a brief "Chamber transition beat" subsection: HUD shows "CHAMBER 1 CLEARED" message for ~1.5s before next chamber loads; brief screen flash; persistent state visible (HP/ammo/score retained on HUD).

Without this, transitions feel like load screens. With it, they feel like climax moments — supporting the Sensation aesthetic.

#### Note 3 — Submission aesthetic vs context-switching (Axis 5)

GDD claims "Submission" alongside Challenge + Sensation. Submission = trance-state, repeating loop, low decision overhead. Multi-chamber introduces context-switches (different layout, different enemy mix) that BREAK trance.

Two ways to resolve:
- **a) Drop Submission from v3.0's aesthetic targets.** Multi-chamber is intrinsically structured, not loop-based. Replace with **Challenge + Sensation + Discovery** (each new chamber reveals new spatial composition). This is honest.
- **b) Justify Submission per-chamber.** Each chamber INTERNALLY is a trance loop (continuous spawns, repetitive aim-fire-pivot). The transitions are brief beats between trance segments. The Submission claim survives if reframed as "trance within each chamber" rather than "trance across the whole game."

I lean (b) — it's accurate and preserves the v2.5 aesthetic continuity. Just add one sentence: "Submission applies within each chamber (continuous spawn loop, aim-fire-pivot rhythm); chamber transitions are brief Sensation beats between trance segments."

#### Note 4 — Death/restart policy across chambers (Axis 12)

v2.5 had a clean death-loop: HP=0 → lose screen → R retries from clean state. v3.0's persistent-loadout architecture creates a question: where does the player respawn after death in chamber 2?

Options:
- **a) Full restart from chamber 1** (matches arcade-pure framing)
- **b) Checkpoint per chamber** (player respawns at start of current chamber with full HP/ammo)
- **c) Lose-screen offers a choice** (R = full restart, C = retry-current-chamber)

For a 90-120s campaign, (a) is fine and maintains the v2.5 arcade flow. (b) reduces frustration but trivializes the persistent-loadout strategic depth (you'd just suicide if low on ammo entering chamber 2 to get a fresh fill).

Recommendation: state explicitly in Restart-UX subsection: "Death = full campaign restart. Persistent loadout is a single-life challenge across all 3 chambers — supports Challenge aesthetic." This reads as a deliberate design choice, not an oversight.

#### Note 5 — Per-chamber replay stats (Axis 11)

GDD's replay-framing subsection mentions "Best score (this session) / Best score ever / Fastest boss kill" — but these are written for the v2.5 single-arena framing. v3.0's chamber structure begs natural per-chamber stats:

- Best total clear time (chambers 1+2+3)
- Per-chamber best time (speedrun framing)
- Lowest HP entering chamber 3 (challenge run)
- Total damage taken across run

Recommendation: extend the replay-framing subsection to cover per-chamber stats. Speedrun is the natural framing for multi-stage campaigns (Doom 1993 had per-level par times). Even just "best total clear time" + "best chamber 3 boss-kill time" is enough.

### Specific axis-deep-dives requested by orchestrator

#### Axis 1 — Still genre-honest with 3-chamber expansion?

Yes. A multi-arena Doom-shaped game IS still a Doom-shaped game (Doom 1 had 3 episodes × 9 levels). The chamber count doesn't pull the genre claim into RPG/adventure territory. Combat loop preserved (look-fire-pivot-pickup); only the surrounding arena geometry changes. Genre-claim minimums (≥3 enemies, ≥2 weapons) still met. PASS.

#### Axis 8 — Reasonable scope or creep?

Reasonable. The 3-chamber structure DOES NOT add total content — it restructures existing 90s of content into 3 named acts. Engine work is also zero-new-primitive (ADR 0006 already landed). The asset-cost is 2 new chamber layouts (chamber 1 small + chamber 3 sparse) plus 1 transition cue. Far less than adding a fourth weapon or a fifth enemy. Wise scope move.

#### Axis 9 — Each chamber memorable?

Per the GDD's Beat column:
- Chamber 1: "Onboarding — learn movement + plasma" — DELIBERATELY subtle; this is the warm-up beat. Memorable as the "calm before the storm" beat — fine.
- Chamber 2: "Tactical signature — weapons + cover decisions matter; rangers force pillar-flanking" — this IS the signature chamber. The Foundry's divider + machinery + ranger-flank dynamic is what players will describe to a friend. STRONG.
- Chamber 3: "Climax — boss-rocket showdown" — pre-existing v2.5 boss beat, now isolated in its own chamber. Open arena + sparse cover + boss = a clean climactic beat. STRONG.

Three distinct, complementary beats. PASS.

#### Axis 11 — Replay value with chambers?

Improved over v2.5 if per-chamber stats are added (note 5). The v2.5 single-score replay was decent; multi-chamber unlocks speedrun framing which is intrinsically richer. With note 5 addressed: STRONG PASS.

### Reasoning summary

v3.0 is a structural enhancement that preserves the v2.5 design while leveraging ADR 0006 to give the game more shape. The 3-chamber framing tightens theme alignment, adds a meta-strategic axis (resource carry-over between chambers), and unlocks speedrun-style replay — all without inflating total play time or asset cost.

The 5 notes are tuning items, not architectural concerns. The pipeline can proceed to content-designer stage with these notes addressed during the GDD-update pass:
1. Clarify wave-beat → chamber mapping (1 sentence)
2. Add chamber-transition audio cue + 1.5s "CHAMBER N CLEARED" beat
3. Reframe Submission as per-chamber-internal (1 sentence)
4. State death = full-campaign-restart explicitly
5. Extend replay-framing with per-chamber + speedrun stats

Total revision effort: ~8 lines of GDD edits. No engine work, no scope changes.

### What round 5 validates about the design pipeline

This is the ideal review cadence: a major architectural feature lands (ADR 0006 multi-level), the GDD updates to use it (v3.0), reviewer applies all 13 axes again (not a rubber-stamp), surfaces tuning gaps (none blocking), pipeline moves forward. The "round 2 deferral trap" (accept-with-future-deferred-features) is fully closed — v3.0 doesn't defer anything; it ships the campaign architecture in one piece.

Compare to history:
- v1 → revise (12-axis): 8 gaps flagged
- v2 → accept-with-deferral (12-axis, too lenient)
- v2.5 → accept (13-axis, retroactive correction)
- v2.6 → accept (post-engine-cleanup, minor)
- **v3.0 → accept-with-notes (5 tuning items, multi-chamber upgrade clean)**

Pipeline can proceed: address notes 1-5 in a quick GDD pass, then content-designer refactors data/demo_doomarena3d/ into the levels/ structure with persistent player at root.
