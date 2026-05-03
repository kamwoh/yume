# TowerDef3D — rule sketches

_Date: 2026-05-03_
_Designer: yume-systems-designer_
_GDD: docs/games/towerdef3d/GDD.md_

## Primitive sufficiency check

- [x] Entity (defs + state + tags + properties) — handles all entities
- [x] Tag (membership) — enemy/tower/projectile/waypoint/base/clock
- [x] Rule (trigger + query + effect) — same shape used in 2D doomarena/doomarena3d
- [x] Trigger (tick, contact) — both used; no input/spawn/signal needed
- [x] Effect (state_*, spawn, remove, velocity_set, emit_shell_event,
       relate) — all in vocabulary
- [x] Query (tags + state with operators + relations + radius) — used
- [x] Relation (typed directed edges) — `next_waypoint` chain, plus enemies
       have `targeting → waypoint` relation when running

**No new primitive required.** Path-following composes from existing.
Tower auto-targeting "first match" works; "select nearest" is a
known engine gap to address later (out of scope here).

## Rule sketches

### Clock advance

**Trigger:** tick interval 1
**Query:** tags=[wave_clock]
**Effect:** state_add wave_timer -=tick_seconds; state_add spawn_cooldown -=tick_seconds

### Wave start (set enemies_to_spawn for the wave)

**Trigger:** tick interval 1
**Query:** tags=[wave_clock], state.wave_timer_lt 0, state.enemies_to_spawn_lte 0
**Effect:** state_set enemies_to_spawn = 2*wave + 1; state_set wave_timer = 99

### Spawn one enemy from the wave queue

**Trigger:** tick interval 1
**Query:** tags=[wave_clock], state.spawn_cooldown_lte 0, state.enemies_to_spawn_gt 0
**Effect:**
- spawn enemy_grunt at spawn waypoint position with override
  state.target_waypoint = "wp_1"
- relate (enemy → wp_1) via "targeting"
- state_add enemies_to_spawn -1
- state_set spawn_cooldown = 0.4

### Wave clear → advance

**Trigger:** tick interval 1
**Query:** tags=[wave_clock], state.enemies_to_spawn_lte 0
**Require:** no entities matching tags=[enemy]
**Effect:** state_add wave +1; state_set wave_timer = 8.0

### Enemy homing toward target waypoint

**Trigger:** contact (broadcast, radius 1000)
**Query:**
- a: tags=[enemy], state.target_waypoint exists
- b: tags=[waypoint] AND state.id_eq self.target_waypoint  (← this won't work directly)

Wait — query can't reference `a.state.X` from b's filter. Need a
different mechanism: **use the `targeting` relation** instead. Each
enemy has a `targeting` relation pointing to its current target
waypoint. Then:

**Trigger:** tick interval 1
**Query:** tags=[enemy], relations: targeting (any) → waypoint
**Effect:** velocity_set toward target's position via formula reading
the related waypoint's state.position.

Issue: the formula evaluator can't currently follow a relation in a
binding. So we need either:
1. Carry waypoint position in enemy.state (denormalized — update on
   advance)
2. Use a contact pattern: enemy + waypoint within radius 1000 with
   require: relation `targeting` from a to b

Option 2 is cleaner. Use contact broadcast:

**Trigger:** contact
**Query:**
- a: tags=[enemy]
- b: tags=[waypoint]
- radius: 1000  (always-fires)
**Require:** relation `targeting` from a to b (exists)
**Effect:** velocity_set target=a, x/z toward b's position; speed = 2
m/s.

### Enemy advances waypoint on contact

**Trigger:** contact
**Query:**
- a: tags=[enemy]
- b: tags=[waypoint]
- radius: 0.8
**Require:** relation `targeting` from a to b (must be CURRENT target)
**Effect:**
- transfer_relation `targeting` from a → (a's current b's `next_waypoint` related entity)
- (No removal of enemy unless next is null AND b has tags=[base])

### Enemy reaches base

**Trigger:** contact
**Query:**
- a: tags=[enemy]
- b: tags=[base]
- radius: 0.8
**Effect:**
- state_add b.hp -1
- emit_shell_event shake
- remove a

### Tower fires at first enemy in range

**Trigger:** tick interval 5  (every 0.5s @ 0.1s tick)
**Query:** tags=[tower]
**Effect:** check via require: contact-style require? Actually we need a
two-step here:
1. Tower's tick fires
2. Find an enemy within tower.range → if any, spawn projectile

This is a tick rule with a sub-query. Looking at the manifest and
existing rules: tick rules can include `query.radius` to scope
candidates around `_origin_position`, but the rule's iteration is
over the matching entities. Here we want "for each tower, find at
least one enemy nearby and fire at it."

Actually simpler: use a **contact rule** (a=tower, b=enemy, radius=tower.range, chance based on cooldown). That naturally fires per (tower, enemy) pair. Add a per-tower cooldown via state.cooldown to gate it.

**Trigger:** contact
**Query:**
- a: tags=[tower], state.cooldown_lte 0
- b: tags=[enemy]
- radius: <evaluated from a.properties.range — need formula in radius?>

Wait, the contact rule's `radius` is a literal float. We need it to
be `a.properties.range` per-tower. Looking at Phase 2.6q manifest:
contact rule's radius is fixed-per-rule, not formula. So all towers
use the SAME radius. For v1, ALL towers have range=6.0 m.

**Trigger:** contact
**Query:**
- a: tags=[tower], state.cooldown_lte 0
- b: tags=[enemy]
- radius: 6.0
**Effect:**
- spawn projectile at a.state.position with velocity toward b
- state_set a.cooldown = 0.5

### Tower cooldown decrements

**Trigger:** tick interval 1
**Query:** tags=[tower]
**Effect:** state_add cooldown -=tick_seconds

### Projectile hits enemy

**Trigger:** contact
**Query:**
- a: tags=[projectile]
- b: tags=[enemy]
- radius: 0.6
**Effect:**
- state_add b.hp -1
- remove a

### Enemy death

**Trigger:** tick interval 1
**Query:** tags=[enemy], state.hp_lte 0
**Effect:**
- spawn 4 particle_spark with random outward velocity
- emit_shell_event shake
- state_add player.gold +5
- remove self

## Cascade design

1. **Wave cascade**: clock_advance → wave_start → wave_spawn_one (×N) → enemies advance waypoints → fight or reach base → wave_clear_advance.
2. **Combat cascade**: tower_fires → projectile_hits_enemy → enemy_death (with feedback).
3. **Loss cascade**: enemy_reaches_base → base.hp -1 → eventually base.hp ≤ 0 → HUD lose-condition triggers.

## Balance values

- Base HP: 10. Allows ~10 leakers before loss. Generous for v1.
- Tower fire cooldown: 0.5s. Damage: 1 per shot.
- Tower range: 6 m. Path is ~30 m long.
- Enemy HP: 3. Speed: 2 m/s.
- Wave size: 2*wave+1. Wave 1 = 3, Wave 10 = 21.
- Wave countdown between waves: 8 s.
- Spawn cooldown within wave: 0.4 s. So wave 10 = 21 enemies × 0.4s = 8.4s to spawn all.

## ADRs needed

None for v1 — composition suffices. Future ADR candidates flagged:

1. **Select-nearest query op** — currently towers fire at "first match" because the engine has no nearest selector. Affects all targeting genres (tower defense, enemy AI in shooters, party AI in RPGs). Round 2 work.
2. **Formula-evaluable contact radius** — currently `radius` is literal. To support per-tower ranges (tower types with different range), need formula support. Round 2 work.

## Open questions for content-designer

- Path waypoint positions: zigzag pattern. Suggest:
  - wp_1 (start): (-12, 0, -10)
  - wp_2: (-4, 0, -10)
  - wp_3: (-4, 0, 0)
  - wp_4: (4, 0, 0)
  - wp_5: (4, 0, 10)
  - wp_6: (12, 0, 10)
  - wp_base: (12, 0, 0)  (final, tagged as base)

- Tower placements (3-5 along the path):
  - tower_1 at (-8, 0, -6) — covers wp_2 corner
  - tower_2 at (0, 0, -3) — covers wp_3 corner
  - tower_3 at (8, 0, 6) — covers wp_5 corner
  - tower_4 at (0, 0, 7) — covers wp_5 mid-stretch
