# TowerDef3D — design review

_Date: 2026-05-03_
_Reviewer: yume-game-reviewer_
_GDD: docs/games/towerdef3d/GDD.md_

## Verdict
**revise** (heavy)

## Per-axis findings

### Mechanical depth — FAIL

The GDD lists 10 entity defs but only **1 enemy type** (`enemy_grunt`)
and **1 tower type** (`tower_basic`). The heuristic minimum for a TD
to be "fun" is ≥3 enemies and ≥3 towers, and the GDD even self-admits
this gap by deferring "Multiple enemy types / tower types" to v2.

A TD with 1 enemy + 1 tower has **no archetypes**: no fast vs tanky
enemy distinction, no specialized vs generalist tower distinction, no
synergies, no counter-play. Every kill plays out the same way. Every
tower placement decision is just "spend 50 gold somewhere reasonable."

This is the single biggest depth gap. Without fixing this axis, the
rest don't matter.

### Strategic depth — FAIL

> "For v1: **none**. The player is purely observational. Tower
> placement is hand-authored in entities/zz_instances.json."

The GDD explicitly admits the player has **zero verbs in v1**. This
isn't a tower defense game — it's a tower defense **simulation that
the player watches**.

Decisions per minute: **0**. Branches: **0**. Risk/reward: none —
outcome is deterministic from designer-set tower placement.

A TD where the player can't place towers isn't a TD. It's a clockwork
demo of the engine.

### Pacing — FAIL

> "wave N spawns 2N+1 enemies" + "Wave timer ~10s"

Wave 1 = 3 enemies. Wave 10 = 21 enemies. **Same enemy, same path,
same composition — just more.** This is the textbook "wave 10 = wave
1 × 7" red flag.

No mechanic introduces itself per wave. No boss wave. No "rush" wave
of pure speed. No "tank" wave of high HP. No "swarm" wave at 3× normal
spawn rate. The pressure curve is purely numeric, not qualitative.

The GDD's stated "Discovery" aesthetic ("First time you realize how
the wave curve interacts with tower coverage") doesn't survive past
wave 2 — once the player sees one wave, they've seen them all.

### Feedback (audio/visual juice) — PARTIAL

Mentioned: "hits flash sparks; kills give shake; gold number ticks up
live in HUD." Good — uses Tier 2.6 visual primitives.

**Missing**:
- **Audio cues** — not mentioned. As of Tier 2.6n, the engine has
  procedural audio. GDD should specify shoot/hit/kill/build/wave-start
  sounds.
- **Damage numbers** — not mentioned. "Towers do 1 damage" is invisible
  unless the player counts hits. Floating "+1" numbers would make
  hits readable.
- **Wave start/end announcements** — not mentioned. Players need to
  know "wave 5 begins" to anticipate.
- **HUD detail** — only "gold ticks up" is specified. No mention of
  base HP bar, wave counter, enemies remaining, next wave timer.

For a "Submission/calmness" aesthetic, light feedback is OK — but the
absence of audio entirely is a gap.

### Aesthetic match — MISMATCH

Stated: **Challenge + Submission + Discovery**.

- **Challenge**: with **no player agency**, what does the player do
  that's challenging? Watching towers fire at fixed positions isn't
  challenging — it's spectating. Challenge requires meaningful
  decisions under pressure; the GDD has neither decisions nor
  pressure that can be addressed. **Aesthetic mismatch.**
- **Submission**: ✓ trance loop of watching wave clears works for a
  spectator-style game.
- **Discovery**: tied to wave variety + tower variety + interactions.
  With 1 enemy + 1 tower + same wave shape, there's nothing to
  discover after the first wave clear. **Aesthetic mismatch.**

The honest aesthetic for v1-as-described is just **Submission** (a
trance demo). The Challenge + Discovery claims are aspirational but
the design doesn't deliver them.

### Scope honesty — PASS

GDD fits Yume's 7 primitives. No out-of-scope features promised
(no networking, no dialogue, no real physics). Scope deferrals to v2
are explicit. The TODO list at the bottom is honest.

This is the only fully passing axis.

### Adversarial pokes — RED FLAGS

- **Passive win**: ✓ The player wins or loses without doing anything.
  Outcome is deterministic from designer-placed towers + wave numbers.
  This is the strongest single criticism — it's not really a game.
- **Wave 10 = wave 1 × 10**: ✓ Confirmed. Same path, same enemy,
  same composition.
- **Degenerate strategy**: N/A (no strategy possible).
- **Visual confusion**: PASS — too few entity types to confuse anyone.
- **Predetermined outcome**: every playthrough is identical. No
  randomness, no player input, no variation. Replay value: zero.

## Concrete revision requests

### Critical (block ship)

1. **Add player verbs to v1**: build mechanic via 4 hand-placed slots
   on the map. Press 1/2/3/4 to drop a tower at slot N. Costs 50 gold.
   Without this, the player has nothing to do and "Challenge" is a lie.

2. **Add ≥2 more enemy types**:
   - **Fast grunt** (1 hp, 4 m/s, no armor) — rushes through; tests
     tower coverage on long stretches.
   - **Tank demon** (8 hp, 1.5 m/s) — soaks fire; rewards focused
     damage.
   The 1-enemy → 3-enemy upgrade transforms the strategic landscape.
   Now the player thinks: "is this wave a rush or a tank?"

3. **Add ≥1 more tower type for v1**:
   - **Sniper tower** (2 dmg, 1.0s cooldown, range 10 m) — tradeoff:
     more damage and range, slower fire rate. Or
   - **AoE tower** (0.5 dmg to ALL enemies in radius 3) — for swarm
     waves.
   Now slot decisions become meaningful: "do I put basic or sniper at
   the corner?"

### Strong (block aesthetic match)

4. **Add wave variety**: at least 2 named wave shapes besides the
   default. E.g.:
   - Wave 5: pure rush (only fast grunts, 2× count)
   - Wave 8: pure tank (only demons, half count but 3× HP)
   - Wave 10: mixed boss wave (1 mega-tank with 50 HP + supporting
     swarm)

5. **Add audio specification**: GDD should call out specific sounds
   per cascade event. Engine has procedural audio (Tier 2.6n);
   leveraging it is free juice.

6. **Add damage number / floating text plan**: "+5 gold" floating up
   from kill location, "-1 HP" when base hit. Either via emit
   primitive or content-designer pattern.

### Nice-to-have

7. **Tower upgrades** (level 2 per slot for double cost) — adds
   another decision: build wide vs build deep. Could be v2 if scope
   pressure forces it.

## Reasoning summary

The GDD describes a competent **engine demo** of a TD genre but not a
**game** in the playable sense. Three of the seven axes fail (mechanical
depth, strategic depth, pacing) and two more are mismatched (aesthetic
on Challenge + Discovery, feedback partially). The single biggest
issue is the deferral of player verbs to v2 — without them, "tower
defense" is a category misnomer and the stated Challenge aesthetic
cannot be delivered. With the critical revisions (player builds,
3 enemy types, 2 tower types, wave variety) the game becomes a real
TD with strategic decisions. Scope is honest about what it does and
doesn't include — but what it doesn't include is most of the genre.
