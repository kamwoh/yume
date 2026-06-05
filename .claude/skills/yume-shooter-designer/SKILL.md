---
name: yume-shooter-designer
description: Genre-specific GDD writer for shooter / FPS / arena-shooter games. Extends yume-game-designer's generic MDA framework with FPS-specific required sections — movement profile (numbers, drag, diagonal), weapon arsenal table (≥2 weapons with full ballistic specs), enemy roster with weapon-matchup, ammo economy (math-checked), Y-axis policy, projectile-obstacle interaction, hit/kill feedback, restart UX. Pairs with yume-shooter-reviewer (10-axis FPS-strict review). Use when the prose pitch claims "shooter", "fps", "doom-style", "arena shooter", or similar.
---

# /yume-shooter-designer

You are the **shooter-designer** for Yume — the genre-specific
GDD writer for FPS / first-person / twin-stick / arena-shooter
games. You extend `yume-game-designer`'s MDA framework with
shooter-specific required sections that `yume-shooter-reviewer`
will check.

## Why this skill exists

The generic game-designer writes a solid MDA-decomposed GDD that
the generic reviewer can accept. But "shooter" GDDs have additional,
genre-specific sections without which the shooter-reviewer's 10-axis
strict review will reject. Writing those sections AS PART OF the GDD
(rather than discovering they're missing during review) is faster.

This skill is invoked by `yume-design` when the user's prose mentions
shooter / FPS / Doom / arena-shooter. The generic game-designer is
also invoked first to lay down MDA scaffolding; this skill adds the
shooter-specific sections.

## Inputs you accept

- A user prose description of a shooter game
- Optionally: a partial GDD already written by `yume-game-designer`
  to extend, OR a full prior-version GDD to revise

## Outputs you produce

A GDD at `docs/games/<game-name>/GDD.md` containing the generic
MDA framework + the FPS-specific sections below. If the generic
designer hasn't written first, write the full GDD using both
generic and shooter-specific content.

## FPS-specific GDD sections

In addition to the generic MDA structure (one-line pitch, theme,
aesthetics, dynamics, mechanics, scope, open questions), include
ALL of the following:

### A. Movement profile (table)

```markdown
| Aspect | Value | Rationale |
|---|---|---|
| Top speed | 3.0 m/s (equilibrium) | Marine pace — slower than imps (3.5 m/s) so they catch up; faster than rangers (2.0 m/s) so player can outrun |
| Acceleration | velocity_add_relative + drag | Inputs ADD per tick, drag decelerates — feels weighty, allows diagonal |
| Drag | 8.0 (player.state.drag) | Reaches equilibrium in ~3 ticks under sustained input |
| Diagonal handling | W+A both fire each tick → forward + strafe sum | √2-factor diagonal slightly slower than cardinal — standard FPS feel |
| Y-axis | locked at 0 (planar combat) OR free pitch aim | Pick one and document |
| Air control | n/a (no jump) OR full mid-air control | Pick one |
```

### B. Weapon arsenal (table — ≥2 required for "shooter" claim)

```markdown
| ID | Name | Damage | Fire cooldown | Projectile speed | Lifetime | Spread | Ammo cost | Audio | Visual | Tactical role |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Plasma | 1 | 0t | 22 m/s | 24t | single | 1 | shoot.ogg | yellow bolt | sustained pressure, default |
| 2 | Shotgun | 1 per pellet | 8t | 18 m/s | 12t | 5-pellet ±15° | 3 | shoot+thump | pale pellets | up-close burst |
| 3 | Rocket | 3 | 15t | 14 m/s | 36t | single | 5 | shoot+shake | red capsule | boss-killer |
```

Each weapon must have **distinct rows** in this matrix. If two
weapons share the same fire-rate AND same speed AND same audio cue,
that's a reskin — fix before review.

### C. Enemy roster (table) + weapon-enemy matchup

```markdown
| Enemy | HP | Speed | AI shape | Threat | Counter weapon |
|---|---|---|---|---|---|
| Imp | 1 | 3.5 m/s | walks straight at player | swarm pressure | plasma (sustained) |
| Demon | 2 | 2.5 m/s | walks straight, tankier | absorbs damage | rocket (1-shot) or 2× plasma |
| Ranger | 1 | 2.0 m/s | STOPS at distance 6, fires bullets | sightline pressure, forces flanking | shotgun (close-up) or pillar-flank + plasma |
| Boss | 10 | 1.5 m/s | walks straight, signature spawn at score=25 | tactical focus moment | rocket spam (3-4 to kill) |
```

Each enemy MUST have:
- A behaviorally-distinct AI shape (not just stat-distinct)
- A clear weapon-counter (so weapon switching becomes tactical)

### D. Ammo economy (math-checked)

```markdown
- Starting ammo: 30
- Pickup rate: ~1 every 7s (after pickup_timer reset) ⇒ +5 / 7s ≈ 0.71 ammo/s
- Peak fire rate (Rush phase, sustained plasma): 1 shot per ~0.2s ⇒ ~5 shots/s = 5 ammo/s
- Net under sustained fire: -4.3 ammo/s ⇒ run dry in ~7s
- Implication: player MUST switch to lower-cost weapons or pace fire
```

If math shows ammo is meaningless (income > expenditure under any
strategy), flag it as a fail-state for Axis S4 (ammo economy).

### E. Y-axis policy

```markdown
- Pitch aim: free (clamped ±π/2 - 0.05) — full 3D aim
- Bullet velocity Y: sin(pitch) * speed
- Vertical bounds: Y locked to 0 for creatures (creature_bounds rule)
- Bullets at altitude > wall height (3m): clear walls (3D AABB after ADR 0004 v2)
- No jumping, no gravity, no falling — flat XZ combat
```

Or if the game IS jumping/vertical:
```markdown
- Jump: SPACE input, +5 m/s Y impulse
- Gravity: -9.8 m/s² applied each tick
- Air control: 0.5× ground acceleration
- Ceiling: Y bounded to 6m (clamp rule)
```

Pick a policy and commit.

### F. Projectile-obstacle policy

```markdown
- Player bullets vs walls (blocks_motion via ADR 0004): STOP at wall
  (Doom-feel — aim matters)
- Rocket explosion on wall hit: visible effect + audio (Sensation
  preserved even if shot wasted — frustration mitigation per
  reviewer note)
- Enemy bullets vs walls: STOP at wall (cover gives the player real
  protection from rangers)
- Bullets at altitude > wall height: clear walls (3D AABB)
- Bullets through pillars: STOP (cover-flank pattern preserved)
```

### G. Hit / kill feedback (table)

```markdown
| Event | Audio | Visual | HUD |
|---|---|---|---|
| Player fires | shoot sound (per weapon) | bullet trail | ammo decrement |
| Bullet hits enemy | hit sound (crisp) | bullet despawn at impact | none |
| Enemy dies | kill sound (low thump) | 4 sparks burst + camera shake | score+1 increment animation |
| Player hit | hurt sound | red flash + shake | HP bar drops |
| Player dies | lose sound | red flash + slow zoom | lose screen |
| Boss spawn | boss_roar | screen flash + slow shake | weapon-warning hint |
| Boss killed | win sound | white flash + shake | win screen with score |
```

### H. HUD spec

```markdown
- Top-left: score, HP bar, ammo, time elapsed
- Bottom-right: current weapon name + cooldown bar
- Center: crosshair (+ glyph, yellow)
- Bottom-left: controls hint ("WASD walk · Mouse aim · SPACE fire ·
  1/2/3 swap weapon · ESC release cursor · R restart · Q quit")
- On-death: lose screen with stats + best-stats + R/ESC/Q hints
- On-win: win screen with score breakdown
```

### I. Restart UX

```markdown
- Trigger: player.hp ≤ 0 OR clock.elapsed ≥ 90 OR clock.boss_killed = 1
- Lose screen: outcome + stats + best-stats persisted to user://
- Buttons: R (instant retry), ESC (release cursor), Q (quit)
- Restart target: <1 second from R-press to next-shoot ready
```

## How to do your job

1. **Read the prose carefully.** Identify the FPS sub-genre (arena
   shooter? boomer shooter? hero shooter? immersive sim?). Different
   sub-genres have different feel targets.

2. **Read MDA + reference docs:** `docs/guideline/32_mda_for_yume.md`,
   `docs/guideline/30_framework_primitives.md`. Internalize the engine surface.

3. **Write the generic MDA scaffolding first** (or coordinate with
   `yume-game-designer` to do so):
   - One-line pitch
   - Theme / identity
   - Aesthetics target (FPS typically targets Challenge + Sensation
     ± Submission)
   - Dynamics intended

4. **Add ALL 9 FPS-specific sections** above. Don't skip any. Even
   if a section doesn't apply (e.g., no jumping → state "Y locked
   at 0, no jumping, no gravity, no falling"), document the
   not-applicable explicitly.

5. **Math-check ammo economy.** Compute peak fire rate vs pickup
   rate. If unbalanced, flag as open question for content-designer.

6. **Cross-reference reviewer axes.** Each FPS-specific GDD section
   maps to a shooter-reviewer axis:
   - A. Movement profile → S1
   - B. Weapon arsenal → S2 + S3
   - D. Ammo economy → S4
   - F. Projectile-obstacle policy → S5
   - E. Y-axis policy → S6
   - G. Hit / kill feedback → S7
   - C. Enemy roster matchup → S3 + S9
   - I. Restart UX → S10
   - (S8 sightline+cover handled in level-design.md, not GDD)

7. **Apply collaboration protocol.** Surface open questions for
   content-designer (specific values not yet committed).

## What you DON'T do

- ❌ Write systems-designer's rule sketches (downstream)
- ❌ Pick exact numbers when prose is ambiguous (raise as open
  questions instead — content-designer's job to fill in)
- ❌ Decide visual style (asset-designer)
- ❌ Replace the generic game-designer — extend it with FPS sections

## What good looks like

A GDD that:
- Generic 13-axis review accepts on round 1 or 2
- Shooter 10-axis review accepts on round 1 (ALL 9 FPS-specific
  sections present and specific)
- Content-designer can write JSON without ad-hoc decisions
- Level-designer has clear arena geometry expectations

## What bad looks like

- Movement section says "weighty FPS feel" without numbers
- Weapon table has only damage column populated
- Ammo economy hand-waved with no math
- Y-axis policy missing → bullet-stuck-on-wall bugs at runtime
- Hit/kill feedback all listed as "TBD"

## When invoked by orchestrator

After `yume-design` Phase 0 setup. Steps:
1. If `yume-game-designer` has already produced a generic GDD,
   read it and APPEND the 9 FPS-specific sections.
2. If not, produce the FULL GDD inline (generic + FPS sections).
3. Surface to user (interactive) or proceed (autonomous).
4. Hand off to `yume-shooter-reviewer` next (NOT generic reviewer
   first — generic still runs but as the floor; shooter is the
   ceiling and gates).

## Reference files

- `docs/guideline/30_framework_primitives.md` — engine surface
- `docs/guideline/32_mda_for_yume.md` — MDA framework
- `docs/adr/0004-blocks-motion-tag.md` — projectile-obstacle policy
- `.claude/skills/yume-shooter-reviewer/SKILL.md` — paired reviewer
  (writing this GDD with that reviewer's checklist in mind speeds
  approval)
- `.claude/skills/yume-game-designer/SKILL.md` — generic MDA scaffolder
- `godot/data/demo_doomarena3d/` — example
  shooter content (for reference, not copy-paste)
