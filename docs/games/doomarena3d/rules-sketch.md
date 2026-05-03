# DoomArena3D — rule sketches

_Date: 2026-05-03_
_Designer: yume-systems-designer_
_GDD: docs/games/doomarena3d/GDD.md_

## Primitive sufficiency check

The 2D doomarena already shipped using only the 7 primitives + Round-1
polish. The 3D port adds nothing new at the engine level — it leans on
existing Tier 2.6 features:

- [x] Entity (Vector3 position + velocity, just like fpsgarden)
- [x] Tag (player, monster, bullet, particle, pickup_health, pickup_ammo, clock, creature)
- [x] Rule (trigger + query + effect — same shapes as 2D)
- [x] Trigger (tick, contact, input — same set as 2D)
- [x] Effect (state_*, spawn, remove, velocity_set, velocity_set_relative, emit_shell_event)
- [x] Query (tags + state.{x}_lt, contact a/b, radius — same set as 2D)
- [x] Relation (n/a — arcade game)

**No new primitive required. No ADR needed.**

## Rule sketches

### Mechanic: clock advance + pressure curve

**Trigger:** tick interval 1
**Query:** tags=[clock]
**Effect:** state_add elapsed +0.1; state_add spawn_timer -0.1; state_add pickup_timer -0.1
**Why:** drives win/lose check, monster spawn cadence, pickup cadence.

### Mechanic: monster spawn at random ring position

**Trigger:** tick interval 1
**Query:** tags=[clock], spawn_timer < 0
**Effect:**
- spawn `monster_imp` at position [cos(angle)*14, 0, sin(angle)*14]
  with `angle = randf() * TAU`
- state_set spawn_timer = max(2.0, 4.0 - elapsed * 0.022)

**Why:** monsters appear at the edge of the arena and walk in. Ring
radius 14 (just inside ±15 bound) means monsters never spawn outside
playable area. Pressure curve same as 2D.

Note: TAU not in formula whitelist. Use `6.283185 * randf()` instead
or compute via `randf() * 2 * 3.14159`.

### Mechanic: pickup spawn (health + ammo, alternating chance)

**Trigger:** tick interval 1
**Query:** tags=[clock], pickup_timer < 0
**Effect:**
- chance 0.5 → spawn health_pickup at `[(randf()-0.5)*28, 0.5, (randf()-0.5)*28]`
- chance 0.5 → spawn ammo_pickup similar
- state_set pickup_timer = 7.0

**Why:** keeps player attriting + restoring resources at a steady pace.

### Mechanic: player movement (4 rules — forward/back/strafe)

**Trigger:** input action move_north / south / east / west (HOLD)
**Effect:** velocity_set_relative target=actor forward=+/-4.5 strafe=0
or strafe=+/-4.5 (using fpsgarden weight)

**Why:** WASD moves player relative to mouse-look facing direction.
`actor` keyword resolves to the camera's follow_tag entity (player).
Drag (state.drag=8.0) handles deceleration when no input held.

### Mechanic: player fires bolt forward

**Trigger:** input action `fire` (PRESS-edge)
**Query:** tags=[player], ammo > 0
**Effect:**
- spawn `bullet` at
  `[self.state.position.x + cos(self.state.facing)*0.6, 1.4,
    self.state.position.z + sin(self.state.facing)*0.6]`
  with override velocity
  `[cos(self.state.facing)*22, 0, sin(self.state.facing)*22]`
- state_add self.ammo -1

**Why:** bullet shoots forward in the player's looking direction. Bolt
spawns 0.6 m forward and 1.4 m up (eye level) so it doesn't visibly
pop out of the player. Lifetime 24 ticks × 0.05s tick = 1.2s before
auto-despawn (~26 m travel distance — covers full arena).

Note: `fire` must be added to world.gd's `input_actions_press` so it
fires once per keypress (PRESS-edge), not every tick (HOLD).

### Mechanic: monster homing toward player (XZ plane)

**Trigger:** contact (broadcast pattern, radius 1000 = always)
**Query:**
- a: tags=[monster]
- b: tags=[player]
- radius: 1000
**Effect:** velocity_set target=a, x=normalized_dx*speed, y=0, z=normalized_dz*speed
where dx=b.position.x-a.position.x, dz=b.position.z-a.position.z, len=sqrt(dx²+dz²).

**Why:** monsters track the player on the ground plane. Y stays 0 to
keep planar motion. Same XZ pattern as 2D's XY homing.

### Mechanic: bullet damages monster

**Trigger:** contact
**Query:** a=tags[bullet], b=tags[monster], radius=1.2
**Effect:** state_add b.hp -1; remove a

**Why:** one bullet deals 1 damage. Imp dies in 1 hit (hp=1); demon
takes 2 (hp=2). Bullet always destroyed on hit.

### Mechanic: monster death cascade

**Trigger:** tick interval 1
**Query:** tags=[monster], hp ≤ 0
**Effect:** spawn 4 particle_spark with random offset + outward velocity;
emit_shell_event shake intensity=0.06 duration=8;
state_add player.score +1; remove self.

**Why:** queues death feedback (sparkles + shake + score). Particle
spawns use small Vector3 outward velocities for 3D visual burst.
Shake intensity 0.06 m matches fpsgarden's orb-collect feel — not
overwhelming but noticeable.

### Mechanic: monster damages player

**Trigger:** contact
**Query:** a=tags[monster], b=tags[player], radius=1.2
**Effect:** state_add b.hp -10; state_clamp b.hp [0,100];
emit_shell_event flash color=#ff0000 duration=12;
emit_shell_event shake intensity=0.1 duration=10; remove a.

**Why:** monster is kamikaze — disappears on contact. Hit gives big
visceral feedback. Same pattern as 2D.

### Mechanic: pickup grabs

**Trigger:** contact
**Queries:** a=player + b=pickup_health (or pickup_ammo), radius=1.2
**Effects:**
- health: state_add a.hp +25; state_clamp; remove b
- ammo: state_add a.ammo +5; remove b

### Mechanic: bounds clamp

**Trigger:** tick interval 1
**Query:** tags=[creature]
**Effect:** state_set self.position = `Vector3(clamp(x, -15, 15), 0, clamp(z, -15, 15))`

**Why:** keeps player + monsters in the arena, Y locked to 0 (no
jumping). 30×30 m playable area.

## Cascade design

The dynamics from the GDD compose from these rules:

1. **Pressure cascade** — clock_advance → monster_spawn (interval
   shrinks) → many monsters → kill or die.
2. **Tempo cascade** — fire_forward → bullet_kills_monster → monster.hp ≤ 0 → monster_death → score++.
3. **Resource cascade** — pickup_spawn → pickup_health_grab / pickup_ammo_grab → restored hp/ammo.
4. **Feedback cascade** — every kill emits shake; every hit on player emits flash.

## Balance values (initial guesses — content-designer fills)

- monster_imp.speed = 3.5 m/s (about 1 m/s faster than player walk
  speed of ~4.5 with drag → can't easily run past them)
- monster_demon.speed = 2.5 m/s
- bullet velocity = 22 m/s × cos/sin (covers arena diameter ~28 m in
  bullet lifetime = 1.2s → just barely reaches edge)
- bullet lifetime = 24 ticks (1.2s at 0.05s tick)
- contact radius for combat = 1.2 m (about person-shoulder width)
- spawn timer initial = 4s; min after curve = 2s by t=60s
- pickup timer = 7s

## ADRs needed

None — composition of existing primitives suffices. Tier 2.6o (camera
modes) + Tier 2.6q (declarative patterns) already shipped.

## Open questions for content-designer

- Mesh names for new entities — asset-designer phase will append:
  `imp_3d`, `demon_3d`, `bolt_3d`, `spark_3d`, `med_kit_3d`,
  `ammo_box_3d`. Player reuses existing `person`.
- World tick rate: 0.05s (matches fpsgarden — snappy first-person).
- Sky/ground style: dark sci-fi (deep purple sky, dark gray floor,
  red glowing horizon) — set in scene file, not data.
