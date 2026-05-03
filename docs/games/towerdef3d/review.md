# TowerDef3D — design review (12-axis re-run)

_Date: 2026-05-03_
_Reviewer: yume-game-reviewer (12-axis revision)_
_GDD: docs/games/towerdef3d/GDD.md_

## Verdict
**reject**

This is not a "revise (heavy)" — multiple fundamental issues compound
to make the GDD as-written unshippable. Either redesign with player
agency at the core OR rescope as "tech demo of TD pipeline" with
honest aesthetic claims.

(Note: previous 7-axis review verdict was "revise heavy" with 5
critical issues. The 12-axis lens finds **8 of 12 axes failing**
plus reveals fundamental aesthetic dishonesty that pushes verdict
from revise → reject.)

## Per-axis findings

### Axis 1 — Mechanical depth — CRITICAL FAIL

> "10 defs: ... `enemy_grunt` (the only enemy type for v1)"
> "`tower_basic` (auto-firing)"

**1 enemy + 1 tower** for a TD. TD heuristic minimum is ≥3+3. This
is a category violation. Confirmed by GDD's own scope note: "Multiple
enemy types / tower types (v2)."

A TD with 1 enemy + 1 tower is a tutorial of the verb, not a game.

### Axis 2 — Strategic depth — CRITICAL FAIL

> "For v1: **none**. The player is purely observational."

The player has **zero verbs**. Outcome is determined entirely by
designer-placed towers + wave numbers. The "game" is a deterministic
animation that either resolves to win or lose.

Decisions per minute: 0. Branches: 0.

### Axis 3 — Pacing — FAIL

> "wave N spawns 2N+1 enemies" + same path, same enemy type

Wave 1 = 3 enemies. Wave 10 = 21 enemies. Same composition. No boss
wave, no rush wave, no varied composition. Pure linear arithmetic
escalation.

The GDD's "Discovery" claim ("First time you realize how the wave
curve interacts") fails after wave 2 — the player has seen the entire
mechanical surface.

### Axis 4 — Feedback — PARTIAL FAIL

GDD mentions: "hits flash sparks; kills give shake; gold ticks live."

**Audio: not mentioned.** (Tier 2.6n procedural audio exists; GDD is
silent.) **Damage numbers: not mentioned.** (Towers do 1 damage
invisibly.) **Wave start/end announcements: not mentioned.** **HUD
detail beyond gold: missing.**

For a "Challenge" aesthetic, the player needs to READ the game state
quickly. Without damage numbers + audio cues + wave alerts, the game
plays in a quiet daze.

### Axis 5 — Aesthetic match — CRITICAL MISMATCH

Stated: **Challenge + Submission + Discovery**.

- **Challenge**: with NO player agency, what's challenging? Watching
  towers fire at fixed positions isn't challenging — it's spectating.
  Outcome is fixed by designer-time decisions, not player-time
  decisions. This is the central aesthetic dishonesty.
- **Submission**: ✓ (trance loop of watching wave clears can work
  for a spectator-style game).
- **Discovery**: with 1 enemy + 1 tower + same wave shape, there's
  nothing to discover after the first wave. Mismatch.

The honest aesthetic for v1-as-described is **Submission alone** —
a calm spectator demo. The "Challenge + Discovery" claims are
aspirational.

### Axis 6 — Scope honesty — PASS WITH CAVEATS

Fits Yume's primitives. Honest deferrals to v2 listed. Path-following
mechanic is correctly identified as "new" but composable.

The scope deferrals are honest individually. But aggregated, they
mean v1 lacks the entire genre's defining mechanic (player builds).

### Axis 7 — Adversarial pokes — RED FLAGS

- **Passive win**: ✓ confirmed. Player does literally nothing. This
  is the strongest single criticism.
- **Wave 10 = wave 1 × 7**: confirmed. Same path, same enemy, more.
- **Predetermined outcome**: every playthrough is identical. Replay
  value zero (see Axis 11).
- **Save/persistence**: not mentioned. Mid-game alt-tab loses
  progress, but at 12-22 min total runtime, less critical.

### Axis 8 — Total content scope — FAIL

GDD doesn't specify total play time, but reading between the lines:
- 10 waves
- ~10s per wave + ~2-3s per spawn
- Total: ~3-5 minutes of "watching" per playthrough

This is not a TD game — it's a TD tech demo. Even classic Bloons /
PvZ have ≥20 levels OR endless mode for "casual game" framing.
3-5 minutes per playthrough × deterministic outcome = once-and-done
tech demo.

The GDD never frames itself as "demo" — it claims wave-system,
escalation, win/lose, multi-tier aesthetic. By those claims, content
scope is FAR below threshold.

### Axis 9 — Signature design moments — FAIL

GDD describes: 1 zigzag path, 4-8 hand-placed waypoints, 3-5 hand-
placed towers, linear wave escalation.

**No named, iconic, memorable moments.** No boss wave, no twist, no
"the moment the demon spawns and you panic," no "the corner where
two towers crossfire and slay 3 imps in one second." Just a curve.

A player who finishes a TowerDef3D run won't describe ANY specific
moment to a friend. They'll say "I watched towers shoot some imps."

### Axis 10 — Theme / identity — PARTIAL

> "Dark sci-fi vibe (red walls, glowing markers)"

This is a palette, not a theme. What's the fantasy?

- Are you commanding a defense grid in a derelict space station?
- Defending a research outpost from rogue AI?
- A planetary defense controller during alien invasion?
- A simulation in a training program?

"Dark sci-fi" is a render direction, not a fictional context. The
asset-designer has a palette to work from but no narrative grounding
for sound design (mechanical clank? alien skitter? military comm
chatter?), HUD typography, or player onboarding hook.

Compare to good theme: "You're the AI of an abandoned mining colony's
last defense grid; the towers are repurposed mining lasers; enemies
are corrupted maintenance drones."

### Axis 11 — Replay value — CRITICAL FAIL

GDD is silent on replay. After clearing 10 waves once:
- No randomness (deterministic spawn)
- No score chasing (no metrics tracked beyond "won/lost")
- No procedural variation (same path, same wave composition)
- No achievements / unlockables
- No endless mode
- No difficulty modes

Replay value: literally zero. Every run is bit-identical to every
other run. Why launch the game twice?

For a 3-5 minute experience, this is fatal.

### Axis 12 — Real-UX — FAIL

GDD doesn't mention:
- **Pause** — can player pause to think? (TD is real-time)
- **Restart** — mid-game restart hotkey?
- **Speed controls** — TDs traditionally have 2x / 4x speed buttons
- **Difficulty modes** — easy / normal / hard?
- **Onboarding** — how does player learn what towers do?
- **Save** — quit & resume?
- **Game-over screen** — what happens after lose? "Press R to retry"?

The "Challenge" aesthetic specifically needs UX scaffolding — players
need to be able to retry quickly. Without restart UX, every loss = quit.

For a 10-wave TD: speed controls are nearly genre-mandatory. Watching
3 imps walk at 2 m/s for 20 seconds gets old by wave 3.

## Concrete revision requests (consolidated, by priority)

The number of failures (8 of 12) is severe. The right path is one of
two structural rewrites, not surface fixes.

### Path A — Honest demo rescope

If "TowerDef3D" is meant as a tech demo of Yume's TD support, reframe
the GDD:

- Aesthetic: Submission ONLY (drop Challenge + Discovery)
- Title: "TD Demo: pipeline validation"
- Total play: ~3 min (honest)
- No "real game" framing
- Acknowledge no player agency, no replay
- Theme: optional (still helpful for asset coherence)

### Path B — Real game scope

To deliver on stated Challenge + Discovery aesthetics:

1. **Player builds** — press 1-4 to place towers (cost gold, slot
   markers visible). Critical — without this, no Challenge.
2. **≥3 enemy types** — fast/tank/swarm with distinct behaviors.
   Wave compositions vary.
3. **≥2 tower types** — basic/sniper or basic/AoE. Strategic placement
   becomes meaningful.
4. **Tower upgrades** — level 2 per tower (extra cost) for replay
   strategy.
5. **Wave variety** — at least 3 named waves (rush, tank, mixed boss
   wave). Mark levels 5 and 10 as signature.
6. **Theme** — pick a concrete fictional context.
7. **Audio** — specify shoot/hit/kill/build/wave-start sounds.
8. **Real-UX** — speed control (1x/2x/4x), pause, restart,
   game-over with retry.
9. **Replay** — endless mode after wave 10 OR per-wave star ratings
   (no leaks = 3 stars; some leaks = fewer).
10. **Damage numbers / kill feed** — visible feedback.

This is essentially the manual iteration we did POST-build to make
TowerDef3D actually playable. The GDD should have included all of
this.

## Reasoning summary

The original 7-axis review caught 5 issues and called this revise. The
12-axis lens reveals **8 of 12 failures** — including aesthetic
dishonesty (Challenge claim with no player agency) and content scope
fail (3-5 min playtime vs claimed multi-tier game).

This isn't a "revise" verdict because surface fixes don't address the
core: **the GDD pretends to be a tower defense game while shipping a
tower defense animation.** The fix isn't more polish — it's choosing
honestly between (A) demo rescope or (B) actual game scope.

Worth noting: the manual iteration on TowerDef3D POST-build added
exactly the items in Path B. Build mechanic was added (commit
b5f78ec). Demon enemy was added (commit fec651f-area). Tower upgrades
added. Audio (Tier 2.6n) added. Wave overlap added. HUD readability
fixes added. Several hours of work that the 12-axis reviewer would
have surfaced in 5 minutes of GDD review.

The pipeline failure mode this exposes:
- 7-axis review accepted "revise" + 4 specific items.
- Those 4 items got addressed → "accept."
- Build proceeded.
- Game shipped feeling thin.
- Manual playtest discovered: theme thin, replay zero, no signature
  moments, UX missing.
- Each issue cost an iteration cycle to fix manually.

**With 12-axis review applied at GDD time**: ALL of these would have
been caught upfront. Path B revisions would have produced a GDD that
shipped a real TD on first build attempt, saving ~5 hours of
post-build iteration.

This is exactly why "harsher reviewer" matters. Verdict: reject —
designer must choose path A or B before any further work.
