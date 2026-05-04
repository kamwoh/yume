# DoomArena3D

_Date: 2026-05-04_
_Designer: yume-game-designer_
_Source: 3D port of demo_doomarena (2D); v3.0 — multi-chamber campaign via ADR 0006._

## One-line pitch

Containment Chambers. You're the Last Marine fighting through three
sealed chambers of a derelict mining colony — clear each to advance,
break the boss to win. First-person mouselook, three weapons, four
monster types, persistent loadout across chambers.

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
| **Challenge** | Aim + dodge under pressure. First-person view raises the cost of looking the wrong way. Now real after Axis 1 expansion (3 enemy types + boss force tactical decisions). v3.0 also adds the cross-chamber persistent-loadout decision (carry shotgun ammo into chamber 2, or burn it on chamber 1 imps?). |
| **Sensation** | Hits feel impactful — camera shake, red flash on damage, monsters explode into 3D sparkles, audio cues per cascade (Tier 2.6n shipped). v3.0 chamber-transition beats are also Sensation moments (containment-breach audio + flash) between trance segments. |
| **Submission** | Within each chamber, the trance loop survives — continuous spawn pressure + look→spot→fire→reposition rhythm is unbroken. Chamber transitions are brief Sensation beats between trance segments, not part of the trance itself. (v3.0 reframe: Submission applies INTERNAL to each chamber, not across the whole campaign.) |

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

## Campaign structure (REV — v3.0 per ADR 0006: 3 chambers)

The game now spans **three sealed containment chambers** played in
sequence. Each chamber is a different arena layout + enemy
composition + clear condition. Player loadout (HP, ammo, score,
current_weapon, weapon_cooldown) is **persistent** across chambers
— you don't re-equip between rooms.

| Chamber | Name | Layout | Enemy mix | Clear condition | Beat |
|---|---|---|---|---|---|
| 1 | **Outer Containment** | Smaller arena (28×28m), 4 cover pillars, 1 perimeter | Imps only (1.5s spawn) | Score reaches 5 kills | Onboarding — learn movement + plasma |
| 2 | **The Foundry** *(signature)* | Original 44×44m chamber: divider + 8 pillars + 4 machinery | Imp + demon + ranger mix (2s spawn) | Score reaches 20 (15 more after chamber 1) | Tactical — weapons + cover decisions matter; rangers force pillar-flanking |
| 3 | **Core Containment** *(finale)* | Open 44×44m arena, sparse cover (3 pillars), boss spawns immediately at center-back | Boss (10 HP) + supplemental imps every 4s | Boss killed → CHAMBER STABILIZED win | Climax — boss-rocket showdown |

**Persistent player loadout**: `player` def tagged `persistent` per
ADR 0006 — survives `transition_level` effect calls. State carried:
HP, ammo, score, current_weapon, weapon_cooldown, facing, pitch.

**Per-chamber clear rule**: tick rule queries player score; when ≥
chamber-specific target, fires `transition_level` effect with target
"next". Engine handles entity teardown + new chamber load between
ticks.

**Final chamber (Core Containment)**: clear condition is `boss_killed`
(existing rule still works), and the boss_killed_win cascade fires
`transition_level next` — past last level → engine sets
`world.all_levels_complete = 1` → HUD wins via existing binding.

**No HP/ammo refill between chambers** (v3.0 design choice). Player
who took heavy damage in chamber 1 enters chamber 2 wounded —
encourages careful play. Pickups in each chamber restore HP/ammo
mid-combat.

**Wave-beat → chamber mapping** (v3.0 — replaces v2.5's elapsed-time
phase rules): the v2.5 Calm/Mixed/Rush phase beats now map onto the
3 chambers. Outer = Calm-equivalent (imps only, onboarding); Foundry
= Mixed-equivalent (composition pressure with imp+demon+ranger);
Core = Rush+Boss-equivalent (climax). The v2.5 elapsed-time triggers
(`elapsed_gte: 30` for Mixed, `elapsed_gte: 60` for Rush siren) are
retired — chamber-specific spawn rules express the same idea more
naturally.

**Chamber-transition beat** (v3.0): when a chamber's clear condition
fires, before `transition_level` triggers entity teardown:
- HUD shows `CHAMBER N CLEARED` banner for ~1.5s
- Plays `chamber_breach` audio cue (NEW: low descending tone +
  reverb tail, ~0.8s — needs adding to sounds.json)
- Brief screen flash (`#80c0ff` containment-cyan, 12 frames)
- Persistent state visible on HUD throughout transition (HP/ammo/
  score retained — no flicker)

Without this beat, transitions feel like load screens. With it, they
feel like climax moments — supporting the Sensation aesthetic.

**Death = full-campaign restart** (v3.0 design choice). HP=0 in any
chamber → lose screen → R reloads from chamber 1 with fresh HP/ammo/
score. No mid-campaign checkpoints — single-life challenge across
all 3 chambers supports the Challenge aesthetic. Suiciding-to-refill
exploit is closed by design (the persistent loadout is the strategic
constraint, not a punishment to escape).

## Mechanics

All behavior expressed via Yume's 7 primitives + Round-1 polish
(velocity_lerp + drag, lifetime + fade, emit_shell_event) + Tier 2.6o
camera modes (first_person_3d) + Tier 2.6q declarative patterns. No
new primitives required.

### Movement profile (REV — v2.5 per shooter-reviewer S1)

| Aspect | Value |
|---|---|
| Top speed | 3.0 m/s equilibrium (sustained input + drag) |
| Acceleration | per-tick velocity_add_relative; drag decelerates between |
| Drag | player.state.drag = 8.0 (factor 0.6 per tick at tick_seconds=0.05) |
| Equilibrium math | add * (1 − drag*dt) / (drag*dt) = 2.0 * 0.6 / 0.4 = 3.0 m/s |
| Diagonal | W+A both queue each tick; forward + strafe contributions sum (√2-factor diagonal slightly slower than cardinal — standard FPS feel) |
| Y-axis | creatures locked at Y=0; pitch-aim free for camera only |

### Player verbs

| Verb | Trigger | Effect |
|---|---|---|
| Walk forward | input `move_north` (HOLD) | velocity_add_relative forward=2.0 |
| Walk back    | input `move_south` (HOLD) | velocity_add_relative forward=-2.0 |
| Strafe left  | input `move_west`  (HOLD) | velocity_add_relative strafe=2.0 |
| Strafe right | input `move_east`  (HOLD) | velocity_add_relative strafe=-2.0 |
| Look around  | mouse motion (passive)    | GameShell drains env.mouse_delta into player.state.facing |
| Fire         | input `fire` (PRESS-edge) | spawn weapon-specific bullet from current_weapon; ammo -cost |
| Switch weapon 1 | input `weapon_1` (PRESS-edge) | player.current_weapon = 1 (plasma bolt) |
| Switch weapon 2 | input `weapon_2` (PRESS-edge) | player.current_weapon = 2 (shotgun) |
| Switch weapon 3 | input `weapon_3` (PRESS-edge) | player.current_weapon = 3 (rocket) |

### World clock

A `arena_clock` singleton entity with state:
- `elapsed` — seconds since start (drives pressure curve + win/lose)
- `spawn_timer` — countdown to next monster spawn
- `pickup_timer` — countdown to next pickup spawn

### Combat loop

- Bullet vs Monster contact → bullet.remove + monster.hp -= bullet.damage;
  if monster.hp ≤ 0 → 4 sparkles + camera shake + score+1 + remove.
- Monster vs Player contact → monster removed; player.HP -10; emit
  red flash + small shake.
- Bullet lifetime → 0 → auto-despawn (engine handles via
  `_decrement_lifetimes`).

### Projectile-obstacle policy (REV — v2.5 per shooter-reviewer S5)

- **Player bullets vs walls**: STOP at wall (Doom-feel — aim matters,
  no shoot-through-cover exploits)
- **Rocket on wall hit**: removed via lifetime expiration; visual
  spark feedback so wasted shots are visible (frustration mitigation)
- **Bullets at altitude > 3m wall-top**: clear walls naturally per
  ADR 0004's 3D AABB (bullets fired into the sky pass over arena
  walls — fixes "bullet floats up wall" bug)
- **Enemy bullets vs walls**: STOP at wall (cover protects player from
  rangers — supports tactical pillar-flank pattern)

### Y-axis policy (REV — v2.5 per shooter-reviewer S6)

- **Pitch aim**: free, clamped ±π/2 - 0.05
- **Bullet velocity Y**: `sin(pitch) * weapon.speed` (positive pitch =
  looking up = +Y component)
- **Bullets at altitude**: 3D AABB collision means bullets above wall
  height (3m) clear walls; below wall height they stop
- **Creatures**: Y locked at 0 via creature_bounds rule
- **No jumping, no gravity, no falling** — flat XZ combat for v2.5

### Weapons (REV — v2.5 per reviewer Axis 1: shooters need ≥2 weapons)

3 weapons, switchable via `1`/`2`/`3` keys. Each has distinct
fire-cooldown and ballistic profile.

| ID | Name | Damage | Fire rate | Ballistic | Tactical role |
|---|---|---|---|---|---|
| 1 | **Plasma bolt** | 1 | fast (no cooldown) | single bolt, 22 m/s, lifetime 24t | Default — sustained pressure |
| 2 | **Shotgun** | 1 per pellet | slow (8t cooldown) | 5-pellet horizontal spread (±15°) at 18 m/s, lifetime 12t | Up-close kill — close range pellets stack on one target |
| 3 | **Rocket** | 3 | very slow (15t cooldown) | single bigger bolt at 14 m/s, lifetime 36t | Boss-killer + tank-popper |

Cooldown is per-weapon: `player.state.fire_cooldown` decrements each
tick; fire rule requires it ≤ 0 AND ammo > 0 AND weapon-specific
ammo cost (1 for plasma, 3 for shotgun, 5 for rocket — encourages
mixing).

`player.state.current_weapon` (1/2/3) starts at 1. Weapon switch is
PRESS-edge — accidental hold doesn't cycle.

HUD shows current weapon name + cooldown bar.

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

## Rule inventory (REV — v2.6 post-cleanup)

**Clock (5)**
- `clock_advance` — increments elapsed; decrements spawn_timer + pickup_timer + demon_timer + ranger_timer
- `monster_spawn` (imp), `monster_spawn_demon` (≥30s), `monster_spawn_ranger` (≥30s) — type-specific spawns by phase
- `pickup_spawn_health` / `pickup_spawn_ammo` — random pickup spawns

**Player input (3 movement + 3 weapons + 3 fire)**
- `move_forward/back/strafe_left/strafe_right` — velocity_add_relative (additive per-tick so diagonals work)
- `weapon_switch_1/2/3` — set player.current_weapon, click sound
- `weapon_cooldown_tick` — decrement weapon_cooldown each tick
- `fire_plasma` / `fire_shotgun` / `fire_rocket` — gated by current_weapon + ammo + cooldown

**AI (3)**
- `monster_homing` — non-ranger creatures walk toward player (XZ plane)
- `ranger_homing` — ranger walks toward player but stops at fire_range (clamp-step)
- `ranger_cooldown_tick` + `ranger_fire` — ranger decrements cooldown, fires enemy_bullet on player contact within radius

**Combat (4)**
- `bullet_kills_monster` — contact: bullet damage scales by bullet.properties.damage
- `enemy_bullet_hits_player` — contact: -10 HP + flash + remove
- `monster_death` — hp ≤ 0: 4 sparks + shake + score+1 + remove
- `monster_hits_player` — contact: kamikaze + -10 HP + flash + shake

**Signature (3)**
- `boss_spawn_check` — score ≥ 25 → spawn monster_boss (one-shot via clock.boss_spawned)
- `boss_killed_win` — boss hp ≤ 0 → set clock.boss_killed = 1, win sound + flash
- `wave_phase_siren` — elapsed ≥ 60s → siren sound (one-shot via clock.siren_played)

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
- **Weapons (v2.5 REV)**: 3 weapons (plasma bolt / shotgun / rocket)
  with hot-key switching, per-weapon fire cooldown, distinct
  ballistic profiles, ammo costs that encourage mix-and-match.
- **Static obstacles (v2.5 REV)**: walls + cover pillars block
  motion via the `blocks_motion` engine primitive (ADR 0004 landed).
- **Boundary unification (v2.6 REV)**: walls + ground primitive
  (scene.json `ground` block) replace the old creature_bounds + 
  projectile_floor_despawn content rules. Engine-level instead of 
  content-level. Three mechanisms collapsed to two.
- **3-chamber campaign (v3.0 REV)**: multi-level structure via
  ADR 0006 (`progression.json` + `levels/` + `transition_level`
  effect + `persistent` tag). Chambers 1-2 cleared by score
  threshold; Chamber 3 (boss arena) cleared by boss kill.
  Persistent player loadout. Engine handles entity teardown +
  re-load between chambers between ticks.

Out of scope (explicitly):
- Jumping / gravity — flat XZ movement (Y stays 0)
- Multiple arenas / level progression — single chamber, replay via
  score chase
- Difficulty modes — single fixed difficulty for v2.5
- Bullet-blocked-by-wall opt-out (`ignores_obstacles`) — v3 if needed.

### Replay framing (REV — v3.0 multi-chamber speedrun)

The 3-chamber campaign is intrinsically replay-rich (multi-stage
campaigns naturally support speedrun framing — Doom 1993 had per-
level par times). After first death/win:

- Lose/win screen shows breakdown:
  - `Total clear time: <X>s`
  - `Chamber 1: <X>s · Chamber 2: <X>s · Chamber 3: <X>s`
  - `Final score: <N> kills` · `Damage taken: <N>`
  - `Best total clear: 87s · Best Chamber 3 boss-kill: 19s`
- Persistent best-stats stored at `user://doomarena3d_save.json`:
  - Best total clear time (campaign speedrun PB)
  - Best per-chamber time (per-stage PB)
  - Best chamber-3 boss-kill time
  - Lowest HP entering chamber 3 (challenge run)
  - Total damage taken across run (no-hit run)
- Player chases:
  - **Speedrun**: minimize total clear time
  - **Per-stage PB**: optimize chamber 1, 2, or 3 individually
  - **Boss-rush PB**: enter chamber 3 fast + kill boss fast
  - **Damageless**: complete campaign with low/zero damage taken
  - **Low-HP-3**: enter chamber 3 with lowest HP and still win

These axes give 5+ replay vectors vs. v2.5's single score-chase.

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
| Plasma fire | `shoot` (square, 880→220 Hz, 0.12s) | Snappy energy bolt |
| Shotgun fire | `shotgun_blast` (NEW v2.5 per S2: noise burst + low square 220→90 Hz, 0.18s) | Industrial thunky blast — distinct from plasma |
| Rocket fire | `rocket_launch` (NEW v2.5 per S2: rising square 80→200 Hz, 0.30s) | Heavy launch with whoosh tail |
| Bullet hits enemy | `hit` (noise burst, 0.08s) | Crisp impact |
| Enemy death | `kill` (low square, 0.35s) | Satisfying drop |
| Player hurt | `hurt` (noise+low pitch) | Visceral red-flash companion |
| Pickup grab | `pickup` (rising sine chime) | Reward feedback |
| Boss spawn | (NEW REV: needs `boss_roar` — descending square 200→80 Hz, 0.6s) | Distinct from imp deaths; player notices boss appears |
| ~~Wave 3 siren~~ | ~~`siren`~~ — RETIRED in v3.0 (chamber transitions replace elapsed-time phase rules) | — |
| **Chamber transition** *(v3.0 NEW)* | `chamber_breach` (NEW: low descending tone + reverb tail, ~0.8s) | Containment-broken cue when chamber clear fires |
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
