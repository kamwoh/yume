# DoomArena

_Date: 2026-05-03_
_Designer: yume-game-designer_

## One-line pitch

Lone marine in a sealed sci-fi arena. Monsters teleport in, swarm you,
you shoot back. Survive 90 seconds OR drop 30 of them.

## Aesthetics target

| Category | Why |
|---|---|
| **Challenge** | The whole game is dodging + aiming pressure. Death is real. |
| **Sensation** | Hits feel impactful — camera shake, red flash on damage, monsters explode into particles. Bullets streak, fish-flip directional. |
| **Submission** | One closed room, repeating pattern (spawn → approach → shoot → repeat). Trance-state arcade loop. |

Expressly NOT: Discovery (no hidden rooms), Narrative (no story), Fellowship (single-player), Expression (no customization).

## Dynamics intended

- **Pressure curve**: monsters spawn faster as time passes (interval 4s → 2s by t=60s). Player ammo + HP attrite.
- **Tempo loop**: shoot → kill → score climbs → pickup grabs → keep moving. Stationary = dead.
- **Resource tension**: bullets cost ammo (start 30, +5 per ammo pickup). Health pickups restore +25 HP. Without picking up: you starve out around 60-70s.
- **Feedback dynamics**: every hit triggers shake + particle. Player damage triggers red flash. Score number flashes on increment. Tinypond's "polish layer" applied to a hostile world.

Randomness:
- Monster spawn position (4-8 edge markers, random pick)
- Monster type (80% imp, 20% demon)
- Pickup spawn timing + position

Typical first interesting event: ~4 seconds (first monster appears). First kill: ~6 seconds. First near-death: ~30-45 seconds.

## Mechanics

All behavior expressed via Yume's 7 primitives + the new Round-1 polish (velocity_lerp, lifetime, emit_shell_event). No new primitives required.

### Player verbs

| Verb | Trigger | Effect |
|---|---|---|
| Move N/S/E/W | input WASD (HOLD) | velocity_lerp toward target with `rate=0.18`; weighty motion |
| Stop | input "stop" (HOLD-edge) | velocity_lerp toward zero |
| Shoot N/S/E/W | input arrow keys (PRESS-edge) | spawn `bullet` with directional velocity + lifetime |

### World clock

A `arena_clock` singleton entity with state:
- `elapsed` — seconds since start (drives pressure curve + win/lose)
- `spawn_timer` — countdown to next monster spawn
- `pickup_timer` — countdown to next pickup spawn

### Combat loop

- Bullet vs Monster contact → both removed; spawn 4 short-lived sparkle particles; emit camera shake event; player.score +1; player.ammo -1 already happened on shoot.
- Monster vs Player contact → monster removed; player.HP -10; emit screen-flash event.
- Bullet vs Wall contact → bullet removed; small spark particle.
- Bullet lifetime hits 0 → auto-despawn (engine handles).

### Pickups

- Health pickup (red cross) — randomly spawns ~every 8s. On player contact: player.HP +25 (clamped 0-100). Pickup removed.
- Ammo pickup (yellow box) — randomly spawns ~every 6s. On player contact: player.ammo +5. Pickup removed.

## Entity inventory

10 defs:
- `arena_clock` (meta singleton — timer + spawn timers)
- `player` (the marine — HP, ammo, score state; WASD-controlled)
- `wall_segment` (decorative arena boundary)
- `spawn_marker` (invisible — monsters teleport here from)
- `monster_imp` (common, 1 HP, walks toward player at 60 px/s)
- `monster_demon` (rare, 2 HP, slower 40 px/s)
- `bullet` (player-spawned, has lifetime, rotates with velocity)
- `health_pickup` (random spawn, +25 HP)
- `ammo_pickup` (random spawn, +5 ammo)
- `particle_spark` (transient — fade + auto-despawn via lifetime)

## Rule inventory

~22 rules:

**Clock + pressure (3)**
- `clock_tick` — increments elapsed; updates spawn_timer/pickup_timer
- `monster_spawn_wave` — spawns monster at random spawn_marker when spawn_timer ≤ 0
- `pickup_spawn` — spawns random pickup at random arena point when pickup_timer ≤ 0

**Player input (8)**
- `move_north/south/east/west` — velocity_lerp toward (0, ±240) or (±240, 0)
- `move_stop` — velocity_lerp toward (0, 0)
- `fire_north/south/east/west` — spawn bullet at player position with velocity (0, ±400) or (±400, 0); decrement player.ammo (gated by ammo > 0)

**Monster AI (1)**
- `monster_homing` — every tick, sets monster velocity toward player position (homing missile)

**Combat (4)**
- `bullet_kills_monster` — contact: remove monster + bullet, spawn 4 spark particles, score+1, emit shake
- `monster_hits_player` — contact: remove monster, player.HP -10, emit flash
- `bullet_hits_wall` — contact: remove bullet, spawn 1 spark
- `pickup_grabbed` — split into pickup_health and pickup_ammo (2 rules)

**Bounds (1)**
- `entity_bounds` — clamp player + monsters to arena rect

**Particles (already engine-handled)**
- Particles auto-despawn via state.lifetime decrement (engine convention, no rule needed)

## Honest scope

In scope:
- 2D top-down arena combat
- 90s timer + 30 kills win condition
- Full HUD via GameShell

Out of scope (explicitly):
- 3D first-person view (Yume's third-person 3D doesn't reach Doom feel)
- Audio / sound effects (Tier 2.6n deferred)
- Sprite animations (frame anim is Round 3)
- Damage numbers floating "+10" (Round 3 text primitive)
- Multiple weapons / power-ups / level progression
- Pixel-buffer RL agent training (deliberately set aside per user)

## Open questions (auto-resolved for autonomous mode)

- **Q1 Monster speed scaling over time?** Resolved: NO for v1. Constant speed.
- **Q2 Different monster types or just imp?** Resolved: TWO (imp + demon) for visual variety; demon is 2-HP harder.
- **Q3 Bullets pierce or stop on first hit?** Resolved: STOP. One bullet, one kill (or one wall hit).
- **Q4 Arena shape — square or circular?** Resolved: SQUARE bounds (640×480 play area, ±320/±240 from center). Easier with bounds clamp.
- **Q5 Initial state of the player?** Resolved: HP=100, ammo=30, score=0 at world start.

_Respects framework invariants #1–#8 from `docs/30_framework_primitives.md`._
