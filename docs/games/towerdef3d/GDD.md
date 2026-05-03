# TowerDef3D

_Date: 2026-05-03_
_Designer: yume-game-designer_

## One-line pitch

3D top-down arena. Enemies march a fixed waypoint path toward your
base. Auto-firing towers chip them down. Survive 10 waves.

## Aesthetics target

| Category | Why |
|---|---|
| **Challenge** | Resource pressure (HP at base) + wave escalation. Ramp-up should reward attention. |
| **Submission** | The whole genre is watching automation play out. Trance-state observation. |
| **Discovery** | First time you realize how the wave curve interacts with tower coverage = ah-ha. (Light layer; mainly for v2 with multiple tower types.) |

Expressly NOT: Sensation-heavy (no constant feedback chaos —
calmness is part of the genre), Narrative, Fellowship.

## Dynamics intended

- **Wave escalation curve**: enemy count grows linearly per wave
  (wave N spawns 2N+1 enemies). Wave timer ~10s.
- **Spatial puzzle**: tower placement determines coverage. Path
  geometry determines which towers see which segments.
- **Resource arithmetic**: base HP = 10. Each enemy that reaches base
  → -1 HP. Each kill = +5 gold. Lose if base HP=0 or wave timer
  expires before clearing wave.
- **Feedback dynamics**: hits flash sparks; kills give shake; gold
  number ticks up live in HUD.

Randomness:
- None for v1. Deterministic spawn cadence + path. Skill comes from
  layout, not luck. Add wave variety (faster/tankier types) for v2.

Typical first interesting event: ~3s (first enemy reaches first
tower's range). First clear: ~12s (wave 1 cleared). First near-loss:
~wave 5-6 (ramp pressure, ammo/coverage gaps).

## Mechanics

All behavior expressed via Yume's 7 primitives + Round-1 polish
(velocity_set, lifetime, emit_shell_event) + Tier 2.6o camera modes
(top_down_3d). New mechanic: **waypoint path-following via relations**.
No new primitives required.

### Path-following design

Path = chain of `waypoint` entities linked by `next_waypoint`
relation. Each enemy carries `state.target_waypoint = "wp_1"` (the id
of its current target). Homing rule sets velocity toward the
position of the targeted waypoint. When enemy contacts its target
(radius ≈ 0.8 m), it advances `target_waypoint` to the related next
waypoint. Final waypoint is the base; on contact, enemy damages base
and despawns.

Composes from existing primitives. Relations + state field +
contact + state_set = path.

### Wave system

A `wave_clock` singleton with state:
- `wave` — current wave number (1-10)
- `wave_timer` — seconds until next wave begins
- `enemies_to_spawn` — how many remain to spawn this wave
- `spawn_cooldown` — seconds between spawns within a wave (0.4s)
- `enemies_alive` — derived count via query (could also be state)

On wave_timer ≤ 0: set enemies_to_spawn = 2*wave + 1.
On spawn_cooldown ≤ 0 AND enemies_to_spawn > 0: spawn 1 enemy at
start position; enemies_to_spawn -= 1; spawn_cooldown = 0.4.
On enemies_to_spawn = 0 AND no enemies alive: wave += 1; reset
wave_timer.

### Combat loop

- Tower-fires-projectile: tick rule (interval ~5 ticks = 0.5s).
  Tower queries for enemies within `properties.range`. If any match,
  spawn a projectile at tower position with velocity toward the first
  matched enemy.
- Projectile vs Enemy contact (radius 0.6): projectile removed,
  enemy.hp -= projectile.damage.
- Enemy death (query hp ≤ 0): spawn 4 sparkles, emit shake,
  player.gold += 5, remove enemy.
- Enemy reaches base waypoint (contact with base, radius 0.8):
  base.hp -= 1, emit shake, remove enemy.

### Player verbs

For v1: **none**. The player is purely observational. Tower placement
is hand-authored in `entities/zz_instances.json`. v2 will add
build/place mechanics.

## Entity inventory

10 defs:

- `wave_clock` (singleton — wave + wave_timer + enemies_to_spawn)
- `player` (singleton — gold, score state; not player-controlled in v1)
- `waypoint` (path node — invisible or marker mesh)
- `base` (final destination — has hp; enemies damage it on contact)
- `enemy_grunt` (the only enemy type for v1 — speed 2 m/s, hp 3)
- `tower_basic` (auto-firing — fire_cooldown 0.5s, range 6 m, damage 1)
- `projectile` (towers' bullets — lifetime 30 ticks)
- `particle_spark` (death feedback — lifetime 18 ticks, fade)
- `gate_marker` (cosmetic — visual hint at the spawn point)

## Rule inventory

~22 rules:

**Clock + waves (4)**
- `clock_advance` — every tick: wave_timer -=, spawn_cooldown -=
- `wave_start` — wave_timer ≤ 0 AND enemies_to_spawn = 0:
  enemies_to_spawn = 2*wave+1, wave_timer = 99 (will be reset on clear)
- `wave_spawn_one` — spawn_cooldown ≤ 0 AND enemies_to_spawn > 0:
  spawn enemy at start position with target_waypoint = first wp,
  decrement enemies_to_spawn, reset spawn_cooldown
- `wave_clear_advance` — enemies_to_spawn = 0 AND no enemy entities:
  wave += 1, wave_timer = 8.0 (next wave countdown)

**Path-following (3)**
- `enemy_homing` — every contact tick: enemy queries its
  target_waypoint (via context binding) and sets velocity toward it
- `enemy_advance_waypoint` — contact between enemy and its current
  target waypoint (radius 0.8): set enemy.target_waypoint to the
  related `next_waypoint`, OR remove enemy if final waypoint is base
- `enemy_reaches_base` — final case (above) handles damage to base

**Tower combat (4)**
- `tower_fires` — every 5 ticks: tower queries for enemies within
  range, spawns projectile at first matching enemy's position
- `projectile_motion_set` — on projectile spawn-trigger: set
  velocity toward enemy via formula (handled at spawn)
- `projectile_hits_enemy` — contact (radius 0.6): remove projectile,
  enemy.hp -= 1
- `enemy_death` — tick rule, query enemy.hp ≤ 0: spawn 4 sparks,
  emit shake, player.gold += 5, remove

**Base damage (2)**
- `enemy_at_base_contact` — contact between enemy and base (radius 0.8):
  base.hp -= 1, emit shake, remove enemy
- (no separate "lose" rule — HUD lose-condition watches base.hp)

## Honest scope

In scope:
- Wave system with linear escalation
- Path-following via relations
- Static tower placement (hand-authored)
- 10-wave win condition

Out of scope (explicitly):
- Player builds towers (v2 — needs UI affordance + cost)
- Multiple enemy types / tower types (v2)
- Procedural path generation (v3)
- Tower upgrades (v3)

## Open questions (auto-resolved for autonomous mode)

- **Q1 Tower auto-targeting policy?** Resolved: FIRST MATCH (engine
  has no "select nearest" query op yet). Flag as known limitation;
  in playtests, towers will fire at the first enemy in range, not
  necessarily the one closest. Adds slight emergent behavior. The
  systems-designer doc will explicitly call this out as a future ADR
  candidate.
- **Q2 Path shape?** Resolved: ZIGZAG (S-curve) — 7 waypoints. Tests
  the homing-changes-direction case more than a straight line would.
- **Q3 Initial state?** Resolved: base.hp = 10, player.gold = 100,
  wave = 1, wave_timer = 3.0 (so first wave spawns ~3s after start),
  spawn_cooldown = 0, enemies_to_spawn = 0 (forces wave_start to fire).

_Respects framework invariants #1–#8 from `docs/30_framework_primitives.md`._
