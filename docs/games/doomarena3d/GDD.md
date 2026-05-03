# DoomArena3D

_Date: 2026-05-03_
_Designer: yume-game-designer_
_Source: 3D port of demo_doomarena (2D)._

## One-line pitch

Lone marine in a sealed sci-fi arena, first-person view. Monsters
spawn around you and walk in. Mouse-aim, click-to-shoot. Survive 90
seconds OR drop 30 of them.

## Aesthetics target

| Category | Why |
|---|---|
| **Challenge** | Aim + dodge under pressure. First-person view raises the cost of looking the wrong way. |
| **Sensation** | Hits feel impactful — camera shake, red flash on damage, monsters explode into 3D sparkles. Bolt streaks forward in the look direction. |
| **Submission** | One closed circular arena, repeating loop (look → spot → fire → reposition). Trance-state arcade. |

Expressly NOT: Discovery (no rooms beyond the arena), Narrative (no
story), Fellowship (single-player), Expression (no customization).

## Dynamics intended

Same shape as the 2D version — the 3D port preserves the dynamics; the
delta is the camera + control scheme.

- **Pressure curve**: monster spawn interval shortens with elapsed
  time (4s → 2s by t=60s).
- **Tempo loop**: look → fire → kill → score climbs → grab pickups →
  pivot. Standing still = surrounded.
- **Resource tension**: ammo starts at 30, +5 per pickup. HP starts at
  100, restored +25 per pickup.
- **Feedback dynamics**: every kill triggers shake + 4 sparks. Player
  damage triggers red full-screen flash. HUD numbers tick up live.

Randomness:
- Monster spawn position (random angle on a ring at radius 14)
- Monster type (80% imp, 20% demon)
- Pickup spawn timing + position

Typical first interesting event: ~4 seconds (first monster appears).
First kill: ~6-8 seconds. First near-death: ~30-45 seconds.

## Mechanics

All behavior expressed via Yume's 7 primitives + Round-1 polish
(velocity_lerp + drag, lifetime + fade, emit_shell_event) + Tier 2.6o
camera modes (first_person_3d) + Tier 2.6q declarative patterns. No
new primitives required.

### Player verbs

| Verb | Trigger | Effect |
|---|---|---|
| Walk forward | input `move_north` (HOLD) | velocity_set_relative forward=4.5 (matches fpsgarden weight) |
| Walk back    | input `move_south` (HOLD) | velocity_set_relative forward=-4.5 |
| Strafe left  | input `move_west`  (HOLD) | velocity_set_relative strafe=4.5 |
| Strafe right | input `move_east`  (HOLD) | velocity_set_relative strafe=-4.5 |
| Look around  | mouse motion (passive)    | GameShell drains env.mouse_delta into player.state.facing |
| Fire         | input `fire` (PRESS-edge) | spawn bullet at player position with velocity = facing × 22; ammo -1 |

Drag (state.drag = 8.0) decelerates the player when no input held —
weighty motion, no infinite slide. Same Vector3 drag pattern proven
in fpsgarden.

### World clock

A `arena_clock` singleton entity with state:
- `elapsed` — seconds since start (drives pressure curve + win/lose)
- `spawn_timer` — countdown to next monster spawn
- `pickup_timer` — countdown to next pickup spawn

### Combat loop

- Bullet vs Monster contact → bullet.remove + monster.hp -1; if
  monster.hp ≤ 0 → 4 sparkles + camera shake + score+1 + remove.
- Monster vs Player contact → monster removed; player.HP -10; emit
  red flash + small shake.
- Bullet lifetime → 0 → auto-despawn (engine handles via
  `_decrement_lifetimes`).

### Pickups

- Health pickup (red cube) — random ~every 7s. On player contact:
  player.HP +25 (clamped 0-100). Pickup removed.
- Ammo pickup (yellow cube) — random ~every 7s. On player contact:
  player.ammo +5. Pickup removed.

## Entity inventory

8 defs (vs 10 in 2D — drops `wall_segment` and `spawn_marker`; bounds
clamp + procedural spawn formula replace them):

- `arena_clock` (meta singleton — timer + spawn timers, invisible)
- `player` (the marine — HP, ammo, score, facing state; mouse + WASD)
- `monster_imp` (common, 1 HP, walks toward player at 3.5 m/s)
- `monster_demon` (rare, 2 HP, slower 2.5 m/s)
- `bullet` (player-spawned bolt, lifetime 24 ticks, glowing sphere)
- `health_pickup` (red cube, +25 HP)
- `ammo_pickup` (yellow cube, +5 ammo)
- `particle_spark` (transient — tiny glowing sphere with state.lifetime)

## Rule inventory

~17 rules (vs ~22 in 2D — collapses 4 directional fire rules into 1
forward-fire, drops bounds-as-walls, drops spawn-marker indirection):

**Clock (3)**
- `clock_advance` — increments elapsed; decrements spawn_timer + pickup_timer
- `monster_spawn` — spawns imp at random angle on edge when spawn_timer ≤ 0
- `pickup_spawn_health` / `pickup_spawn_ammo` — random pickup at random arena point

**Player input (5)**
- `move_forward/back/strafe_left/strafe_right` — velocity_set_relative
- `fire_forward` — single PRESS-edge rule: spawns bullet with velocity
  along player.state.facing, decrements ammo (gated by ammo > 0)

**Monster AI (1)**
- `monster_homing` — every contact tick, sets monster velocity toward
  player position (XZ plane, radius 1000 = always fires)

**Combat (3)**
- `bullet_kills_monster` — contact: bullet remove + monster.hp -1
- `monster_death` — query hp ≤ 0: 4 sparks + shake + score+1 + remove
- `monster_hits_player` — contact: monster remove + player.hp -10 + flash + shake

**Pickups (2)**
- `pickup_health_grab` — contact: hp +25 (clamped) + pickup remove
- `pickup_ammo_grab` — contact: ammo +5 + pickup remove

**Bounds (1)**
- `creature_bounds` — clamp player + monsters to arena (XZ ±15)

**Particles**: handled by engine `_decrement_lifetimes` — no rule needed.

## Honest scope

In scope:
- 3D first-person arena combat with mouselook
- 90s timer + 30 kills win condition
- Full HUD via GameShell (HP bar, ammo, kill count, timer)
- Camera shake + red flash via emit_shell_event

Out of scope (explicitly):
- Vertical aim / pitch (use_pitch=false) — Doom-1 style; planar combat
- Jumping / gravity — flat XZ movement only (Y stays 0)
- Audio / sound effects (Tier 2.6n deferred)
- Multiple weapons / power-ups / level progression
- Real walls (a circular bound clamp replaces wall colliders)

## Open questions (auto-resolved for autonomous mode)

- **Q1 Use mouse-pitch or planar aim?** Resolved: PLANAR (use_pitch=false).
  Doom-1 style. Bullets fly horizontally at eye-height. Simpler.
- **Q2 Click-to-shoot or space-to-shoot?** Resolved: SPACE — keeps
  mouse free for aim, no click-and-cursor-loss interactions. Single
  PRESS-edge rule.
- **Q3 Arena shape — round or square?** Resolved: SQUARE bounds (±15 m
  XZ, 30×30 m arena). Easier with state_set clamp; reads identically
  to round at first-person eye level.
- **Q4 Monster speed scaling over time?** Resolved: NO for v1.
  Constant per-monster speeds.
- **Q5 Initial state of the player?** Resolved: HP=100, ammo=30,
  score=0, facing=0 (looking +X), velocity=(0,0,0).

_Respects framework invariants #1–#8 from `docs/30_framework_primitives.md`._
