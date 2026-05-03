# DoomArena3D — design review (12-axis)

_Date: 2026-05-03_
_Reviewer: yume-game-reviewer (12-axis)_
_GDD: docs/games/doomarena3d/GDD.md_

## Verdict
**revise** (medium — not reject)

DoomArena3D is markedly stronger than TowerDef3D's v1: the player has
real agency (WASD + mouse + fire), the aesthetic claims are honest,
and the player-vs-system loop works mechanically. But content scope
and signature-content gaps mean v1 is closer to "arcade demo" than
"shootable arcade game." Revisable without redesign.

(Comparison: TowerDef3D scored 8/12 fails + reject; DoomArena3D scores
2 outright fails + 6 partials → revise.)

## Per-axis findings

### Axis 1 — Mechanical depth — PARTIAL

> "monster_imp (common, 1 HP, walks toward player at 3.5 m/s)"
> "monster_demon (rare, 2 HP, slower 2.5 m/s)"
> "bullet (player-spawned bolt)"

**2 enemy types, 1 weapon** for a shooter. Heuristic minimum is ≥3
enemies + ≥2 weapons.

The 2 enemies are differentiated by HP + speed only — same behavior
(walk toward player). That's a stat sheet, not behavioral variety.
For "Sensation + Challenge" aesthetics, the player needs *different
threat patterns*: a fast rusher that demands kiting, a tank that
demands sustained fire, a ranged enemy that demands dodging.

Single weapon — same fire rate, same damage, same bolt — never gets
old? In 90 seconds yes. Across many runs? Tedium.

→ **Revision request**: add ≥1 more enemy type with distinct *behavior*
(not just stats) — e.g., a fast "hopper" that moves erratically; a
"shooter" enemy that fires back at range; a "swarmer" that spawns in
groups of 3-5. AND/OR add a secondary weapon (rocket with splash, or
shotgun with spread).

### Axis 2 — Strategic depth — PASS

Strong. Player has agency: WASD movement with weighty drag, mouselook
aiming, ammo + HP resource management, pickup-priority decisions.
Decisions per minute: 30+ (each shot is a decision; each pickup grab
is a decision).

This is the major contrast vs TowerDef3D's "passive win." DoomArena3D
is a real game.

### Axis 3 — Pacing — PARTIAL

> "monster spawn interval shortens with elapsed time (4s → 2s by
> t=60s)."

Density escalation, but no compositional variety. After t=60, the
game is "many monsters, same monsters" until win/lose. No tempo shift,
no rest beat, no climax beat.

For a 90-second loop, the GDD implies a single rising pressure curve
without phases. Compare: a "wave clear" beat at 15 kills, a "boss"
spawn at 25 kills, a "final rush" at the 80s mark. Currently: pure
density.

→ **Revision request**: define ≥2 named beats in the 90-second loop:
- "Wave 1" (0-30s): basic imps only, low density
- "Wave 2" (30-60s): demons start appearing, density rises
- "Final rush" (60-90s): swarm density + announcement / siren
- (Optional) Boss at 25 kills: a single high-HP tank with unique
  mesh + announcement audio

### Axis 4 — Feedback — PARTIAL (with caveat)

> "Audio / sound effects (Tier 2.6n deferred)"

GDD honestly defers audio because Tier 2.6n didn't exist at GDD
authoring time. Tier 2.6n now ships — audio is a "free upgrade."

GDD specifies: shake, flash, sparkles, HUD live updates. Decent visual
juice. **Damage numbers**: not specified ("you took -10 HP" floating).
**Kill feed**: not specified. **Crosshair**: not in original GDD
(added post-build).

→ **Revision request**: post-Tier 2.6n update the GDD to specify
audio cues per cascade (shoot/hit/kill/hurt/pickup) — already done in
the manual iteration but not formalized in GDD. Add damage numbers
and kill confirmation feedback for "Sensation" aesthetic to deliver.

### Axis 5 — Aesthetic match — PASS

Stated: **Challenge + Sensation + Submission**. All three are
delivered:

- **Challenge**: ✓ aim + dodge under pressure, limited ammo, HP
  attrition. Player can lose. Real consequences.
- **Sensation**: ✓ shake + flash + sparkles for visceral feedback.
- **Submission**: ✓ trance arcade loop (look → spot → fire → reposition).

All three aesthetics are mechanically supported, unlike TowerDef3D's
Challenge claim.

### Axis 6 — Scope honesty — PASS

GDD honestly enumerates open questions (Q1-Q5), explicitly defers
audio + multiple weapons + jumping. Resolves to "first-person planar
arcade" — clear, scope-honest framing. Q1 was even revised post-
playtest (planar → full 3D pitch) which shows iteration discipline.

### Axis 7 — Adversarial pokes — MOSTLY PASS

- **Passive win**: ✗ — player must actively kill or be killed. ✓
- **Same-monster spam**: ⚠ confirmed at Axis 3.
- **Visual confusion**: 2 enemy types in 90s arena = manageable. ✓
- **Save/persistence**: 90s game, save not needed. ✓
- **Cornered/stuck**: arena bounds clamp; no real wall geometry to
  hide behind. Player is exposed always. Could become tedious if
  every monster swarms equally — see signature moments below.

### Axis 8 — Total content scope — FAIL

> "Survive 90 seconds OR drop 30 of them."

90-second single-arena experience. For shooter heuristic: ≥3 levels
OR endless arena with variety.

- 1 arena
- 1 wave shape (escalating density)
- 90-second cap

This is an **arcade demo**, not a shootable arcade *game*. 5 minutes
total play across 3 retries.

The GDD never frames itself as "demo." It claims wave system, win/
lose, multi-aesthetic — by those claims, content scope is below
threshold.

→ **Revision request**: pick one:
- (A) Reframe explicitly as "DoomArena3D: 90-second arcade challenge
  demo" — honest scope
- (B) Add content: 3 arenas with different geometry, 5+ enemy types,
  endless mode after 90s clear, leaderboard

### Axis 9 — Signature design moments — FAIL

GDD describes: 1 arena, 2 enemy types, random spawn, density curve.
**Nothing iconic.** No boss, no twist, no "the moment X happens" beat.

A player who survives 90 seconds describes it as "I shot some imps
and a demon, didn't die." No specific moment to recall.

→ **Revision request**: add ≥1 named signature moment. Examples:
- "The Wave" — at exactly 60s, the spawn rate quadruples for 5
  seconds and a siren plays. Player's most memorable failure mode.
- "The Demon Boss" — at 25 kills, a single 10-HP demon with a
  distinct mesh + roar appears. Player must focus fire while
  surviving the swarm.
- "The Last Clip" — when ammo ≤ 5, ammo pickups stop spawning for
  10 seconds, forcing one tense low-ammo stretch.

### Axis 10 — Theme / identity — PARTIAL

> "Lone marine in a sealed sci-fi arena, first-person view."
> "Dark sci-fi vibe (red walls, glowing markers)"

This is better than TowerDef3D's "dark sci-fi vibe" because there's
a fictional role ("lone marine") and a clear genre reference (Doom).
The player can hold a fantasy: "I'm a space marine in a containment
chamber under attack."

But it's underspecified:
- WHERE is this arena? Mining colony? Space station? Test chamber?
- WHO is the marine? Last survivor? Trainee? Convict?
- WHY are the demons attacking? Ritual? Containment breach? Demonic
  invasion?

Asset-designer + sound-designer have a palette but no narrative hook
for specific design choices (mining-equipment SFX vs military comm
chatter vs alien skitter).

→ **Revision request**: 1-2 sentence "the game's vibe / fantasy /
fictional context." E.g., "You are the last marine in a derelict
mining colony's containment chamber after a portal incident. The
demons are corrupted miners; the arena is a research lab. Audio
should mix military-comm radio static with distant industrial
machinery."

### Axis 11 — Replay value — PARTIAL

Score chasing (max 30 kills) is implicit in the win condition but not
called out as the replay loop. After clearing 30, what?

- No leaderboard
- No daily seed (different spawn pattern per day)
- No difficulty modes (no "expert" with halved pickups, "casual" with
  doubled HP)
- No unlockables (different weapons, arenas, marine skins)

For a 90-second arcade format, "beat your best time / kill count"
IS the canonical replay vector. GDD doesn't frame it that way. Easy
fix.

→ **Revision request**: add Replay section: "After first clear,
player chases best time (sub-90s win) and best kill count (>30 in
90s). Persistent best-stats stored in user save. Optional: daily
seed for shared challenge."

### Axis 12 — Real-UX — PARTIAL FAIL

GDD doesn't address:
- **Restart on death** — when HP=0 or 90s expires, what UX? Press R?
  Press SPACE? Auto-restart? Lose screen with "Try Again" prompt?
  For arcade, fast restart is mandatory.
- **Mouse capture** — first-person games need mouse lock. GDD
  silent. (Manual playtest revealed this — added ESC to release.)
- **Pause** — not mentioned. Probably acceptable for 90s arcade.
- **Difficulty modes** — not mentioned. Acceptable for arcade demo.
- **Onboarding** — controls hint? Crosshair (added post-build)?
  HUD legibility?

For a 90-second arcade, the only critical UX is **fast restart**.
GDD silent.

→ **Revision request**: specify restart UX:
- On death/timeout: lose screen with stats ("You killed 22 imps in
  74s") + "Press R to retry / ESC for menu"
- Restart: full reset of arena_clock, all entity states, player
  position. < 1 second restart for arcade flow.

## Concrete revision requests (consolidated, prioritized)

### Critical (block ship)

1. **Add 1+ enemy with distinct behavior** (not just stats). Fast
   hopper / ranged shooter / swarmer.
2. **Pick scope path** (A demo or B real game). If demo, drop
   "real game" claims; if real game, expand content per Axis 8.
3. **Add signature moment** — boss / wave / siren beat. Without
   this, every 90s playthrough is interchangeable.
4. **Specify restart UX** — fast retry flow on death/timeout.

### Strong (block aesthetic match)

5. **Specify audio per cascade** (Tier 2.6n is now available). Free
   upgrade for "Sensation" delivery.
6. **Define wave beats** — at minimum 2-3 named phases in the 90s
   loop. Currently: pure density curve.
7. **Theme depth** — 1-2 sentence fictional context to ground asset/
   sound choices.
8. **Replay framing** — explicit "score chase + best-stats save" loop.

### Nice-to-have

9. Damage numbers / kill feed for visual feedback.
10. Mouse-capture handling specification.

## Reasoning summary

DoomArena3D is structurally sound — player has agency, aesthetic
claims are honest, mechanics serve the stated MDA. This is a
fundamentally different baseline than TowerDef3D, which had
aesthetic dishonesty at its core (Challenge claim with zero player
agency).

The 8 partial / fail axes here are content-scope problems, not design
problems:
- Need more enemy variety (Axis 1).
- Need wave variety (Axis 3).
- Need explicit signature beats (Axis 9).
- Need theme depth (Axis 10).
- Need replay framing (Axis 11).
- Need restart UX (Axis 12).

All addressable in 1-2 GDD revision rounds without rewriting the
core design. Verdict: **revise (medium)**, ~6 specific revisions.

Compare to TowerDef3D's 12-axis verdict (reject): TowerDef3D needed
fundamental redesign (player verbs); DoomArena3D needs richer content
within the existing design. The 12-axis lens correctly distinguishes
between these two failure modes.

If revisions land, expected round-2 verdict: accept.

## What this validates about the reviewer skill

The 12-axis review correctly grades doomarena3d HARSHER than the old
7-axis would have (which would have likely accepted on basis of "has
player agency, has shake/flash"), but NOT as harsh as TowerDef3D
(reject vs revise). The skill differentiates failure modes:

- **Reject**: aesthetic-claim dishonesty / no player agency for genres
  that require it
- **Revise medium**: content-scope + variety gaps in otherwise sound
  designs
- **Revise light**: missing specific specs in a generally good design
- **Accept**: all 12 axes meet bar at honestly-claimed scope

This is the right calibration.
