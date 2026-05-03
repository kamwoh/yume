# DoomArena3D

_Date: 2026-05-03_
_Designer: yume-game-designer_
_Source: 3D port of demo_doomarena (2D); revised round 2 per 12-axis review._

## One-line pitch

Containment Chamber 7. You're the last marine after the portal
incident — three minutes to either drop 30 demons or escape with your
score. Pitch-aim mouselook, space to fire, three monster types, one
boss.

## Theme / identity (REV — per Axis 10)

**Containment Chamber 7 / "Last Marine"**: you are the final marine
in a derelict deep-space mining colony, holding the central
containment chamber after a portal incident corrupted the local
mining drones into demonic forms. The arena is the chamber; the
monsters are corrupted miner-drones (imps), heavy demolition rigs
(demons), and one industrial-mover (the boss).

Visual palette: rust + emergency-lighting red + dark steel + warning-
hazard yellow. Sound palette: distant industrial machinery hum,
corrupted-comm radio static between waves, mechanical-sounding
monster vocalizations (not organic).

This grounds asset choices: walls = damaged steel paneling with
warning stripes; sky = red-tinted simulated; sounds = industrial,
not magical.

## Aesthetics target

| Category | Why |
|---|---|
| **Challenge** | Aim + dodge under pressure. First-person view raises the cost of looking the wrong way. Now real after Axis 1 expansion (3 enemy types + boss force tactical decisions). |
| **Sensation** | Hits feel impactful — camera shake, red flash on damage, monsters explode into 3D sparkles, audio cues per cascade (Tier 2.6n shipped). |
| **Submission** | One closed arena, repeating loop (look → spot → fire → reposition). Trance-state arcade with score-chase replay. |

Expressly NOT: Discovery (no rooms beyond the arena), Narrative (no
story beyond theme), Fellowship (single-player), Expression (no
customization).

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
- Monster type per spawn (60% imp, 30% demon, 10% ranger)
- Pickup spawn timing + position

Typical first interesting event: ~4 seconds (first monster appears).
First kill: ~6-8 seconds. First near-death: ~30-45 seconds.

### Wave beats (REV — per Axis 3 + 9)

Three named phases inside the 90-second loop, instead of pure density
escalation:

| Phase | Time | Spawn rate | Composition | Beat purpose |
|---|---|---|---|---|
| **Calm** | 0-30s | 4s interval | imp only | Onboarding; player learns aim + reload rhythm |
| **Mixed** | 30-60s | 3s interval | 60% imp, 30% demon, 10% ranger | Composition pressure; demons need 2 hits, rangers shoot back |
| **Rush** *(signature)* | 60-89s | 1.5s interval | mostly imp + occasional demon | Density spike; siren announcement audio plays at t=60s |
| **The Boss** *(signature)* | At 25 kills (any time) | one-shot | 1 boss "industrial mover" (10 HP, slow, big mesh, distinct roar) | Tactical pause — boss demands focus while swarm continues |

Player must split attention between boss + ongoing waves. The boss
spawn is the "you'll remember this moment" beat per Axis 9.

If the boss is killed before time runs out: 5-second slow-mo win with
"CHAMBER STABILIZED" message + score breakdown.

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

10 defs (REV — added monster_ranger + monster_boss + enemy_bullet):

- `arena_clock` (singleton — timer + spawn timers + boss flag, invisible)
- `player` (HP, ammo, score, facing, pitch state; mouse + WASD)
- `monster_imp` (common, 1 HP, walks toward player at 3.5 m/s)
- `monster_demon` (uncommon, 2 HP, slower 2.5 m/s — tank)
- `monster_ranger` *(NEW REV per Axis 1)* — uncommon, 1 HP, slow 2 m/s,
  STOPS at distance 6 from player and fires `enemy_bullet` every 1.5s.
  Forces player to prioritize ranged threats vs melee.
- `monster_boss` *(NEW REV per Axis 9 signature)* — single spawn at
  score=25. 10 HP, very slow 1.5 m/s, double-size mesh, distinct
  red-glow + audio roar on spawn. Killing it = 5-second slow-mo win
  beat. While alive: continues to spawn imps.
- `enemy_bullet` *(NEW REV)* — ranger's projectile. Fires straight at
  player position at spawn time. 1 damage on contact. Lifetime 30
  ticks. Visual: small red sphere, distinct from player's yellow bolt.
- `bullet` (player bolt, lifetime 24 ticks, yellow glowing sphere)
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

## Honest scope (REV — round 2 update for real-game scope)

In scope:
- 3D first-person arena combat with mouselook + pitch (full 3D aim)
- 90s timer + 30 kills win condition; boss kill = early "stable" win
- 3 enemy types (imp / demon / ranger) + 1 boss
- 3 wave beats (Calm / Mixed / Rush) + boss spawn signature moment
- Full HUD via GameShell (HP bar, ammo, kill count, timer, controls
  hint, crosshair)
- Camera shake + red flash + audio cues per cascade (Tier 2.6n
  procedural sounds)
- Restart UX: lose screen with "Press R to retry" — fast arcade flow
- Replay framing: best-stats persisted (best score, best survival
  time) across game sessions

Out of scope (explicitly):
- Multiple weapons (single bolt fire only — secondary weapon for v3)
- Jumping / gravity — flat XZ movement (Y stays 0)
- Real walls (circular bound clamp replaces wall colliders)
- Multiple arenas / level progression — single chamber, replay via
  score chase
- Difficulty modes — single fixed difficulty for v2

### Replay framing (REV — per Axis 11)

The 90-second arcade loop IS the replay vector. After first death/
timeout/win:
- Lose/win screen shows `Score: <kills>`, `Time: <Xs>`, and best
  stats: `Best score: 27 (this session)` / `Best score ever: 35`.
- Persistent best-stats stored at `user://doomarena3d_save.json`.
- Player chases: kill more in 90s, OR survive longer past 30 kills,
  OR kill the boss in fewer total kills.
- Optional: track "fastest boss kill" as additional score axis.

### Restart UX (REV — per Axis 12)

On HP=0 OR 90s timer expired OR boss killed:
- Game pauses; show outcome screen with final stats + best stats.
- 3 button options:
  - **R**: instant retry — full reset of arena (all entities despawn
    + respawn from initial state; clock reset to 0).
  - **ESC**: release mouse cursor.
  - **Q**: quit game.
- Restart flow target: <1 second from press-R to next-shoot.

### Audio per cascade (REV — Tier 2.6n integration)

Already specified in current implementation; formalizing in GDD:

| Action | Sound (from sounds.json) | Reason |
|---|---|---|
| Player fire | `shoot` (square, 880→220 Hz, 0.12s) | Snappy bolt sound |
| Bullet hits enemy | `hit` (noise burst, 0.08s) | Crisp impact |
| Enemy death | `kill` (low square, 0.35s) | Satisfying drop |
| Player hurt | `hurt` (noise+low pitch) | Visceral red-flash companion |
| Pickup grab | `pickup` (rising sine chime) | Reward feedback |
| Boss spawn | (NEW REV: needs `boss_roar` — descending square 200→80 Hz, 0.6s) | Distinct from imp deaths; player notices boss appears |
| Wave 3 siren | (NEW REV: needs `siren` — alternating two-tone, 1.5s) | Announces Rush phase at t=60s |
| Restart on death | `lose` | Existing |
| Boss-killed win | `win` | Existing |

## Open questions (auto-resolved for autonomous mode)

- **Q1 Use mouse-pitch or planar aim?** FULL 3D AIM (use_pitch=true).
  Bullet velocity formula uses pitch component. ✓ (already implemented)
- **Q2 Click-to-shoot or space-to-shoot?** SPACE — keeps mouse free
  for aim. ✓ (already implemented)
- **Q3 Arena shape — round or square?** SQUARE bounds (±15 m XZ,
  30×30 m arena). ✓ (already implemented)
- **Q4 Monster speed scaling over time?** No — variety from enemy
  types instead.
- **Q5 Initial state of the player?** HP=100, ammo=30, score=0,
  facing=0, pitch=0, velocity=(0,0,0). ✓
- **Q6 (NEW) How does ranger fire?** Tick rule: every 1.5s (use
  state.fire_cooldown), if player within radius 8 of ranger AND
  ranger.state.cooldown ≤ 0, spawn `enemy_bullet` at ranger position
  with velocity = (player.position - ranger.position).normalized()
  × 8 m/s. Bullet damages player on contact (state_add hp -1).
- **Q7 (NEW) How does boss spawn trigger?** Tick rule: every 4 ticks,
  query player.score == 25 AND clock.boss_spawned == 0. If match:
  spawn monster_boss at random ring position (radius 14), set
  clock.boss_spawned = 1, emit boss_roar audio.
- **Q8 (NEW) Multiple ammo pickups stack?** Yes — no max ammo cap
  (cosmetically clamped at 99 in HUD display). Encourages active
  pickup grabbing.

_Respects framework invariants #1–#8 from `docs/30_framework_primitives.md`._
