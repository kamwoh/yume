# TowerDef3D — QA report

_Date: 2026-05-03_
_Tester: yume-qa-tester_

## Verdict

**pass**

3rd autonomous /yume-design pipeline run. Validates `top_down_3d`
camera mode + the new path-following pattern (waypoints store
direction-to-next via state.next_vx / next_vz). All scenarios pass;
live smoke shows correct cascade.

## Load smoke test

- 8 defs, 13 initial entities (clock + player + 6 waypoints + base + 4 towers), 0 relations
- 10 rules registered
- Validation: zero errors

## Tick smoke test

- Live headless run (~24s real time):
  - First enemy spawned at t≈32 (wave_timer initial=3.0 → wave_start
    fires after ~3s; first wave_spawn_one immediately after)
  - At t40: 2 enemies + 3 projectiles (towers actively firing)
  - Player gold reached 115 by capture time → kills are happening
  - Pickup spawning correctly cadenced (every 0.4s within wave)

## Engine errors captured (Tier 2.6a)

None. `env.error_buffer` empty.

## Cascades observed

### Cascade: clock_advance + wave_start

- Expected: wave_timer ticks down from 3.0; at ≤0, wave_start fires
  setting enemies_to_spawn = 2*wave+1 = 3 and wave_timer = 99
- Observed: yes (scenario `clock_advance_works`: wave_timer = 97.1
  after 50 ticks proves both decrement and wave_start reset)

### Cascade: wave_spawn_one

- Expected: enemies spawn at wp_1 with initial velocity toward wp_2
  (i.e. velocity = +X)
- Observed: yes (scenario `first_wave_starts`: ≥1 enemy after 40
  ticks; live shows enemies progressing along path)

### Cascade: enemy advances at waypoint

- Expected: contact (enemy, waypoint, radius 0.8) → set enemy
  velocity to waypoint's stored next_vx/next_vz
- Observed: yes (scenario `enemy_advances_at_waypoint`: enemy passing
  wp_2 — its velocity.z became > 1 i.e. now moving south)

### Cascade: tower fires + projectile damages enemy

- Expected: tower contacts enemy in 6m range with cooldown ≤ 0 →
  spawn projectile. Projectile contacts enemy → -1 hp + remove.
- Observed: yes (scenario `tower_fires_when_enemy_in_range`: enemy
  hp dropped from 99 to <99; tower cooldown reset to >0)

### Cascade: enemy reaches base

- Expected: contact (enemy, base, radius 0.8) → -1 base.hp + remove enemy
- Observed: yes (scenario `enemy_at_base_damages_it`: base.hp dropped
  from 10 to <10; leaker removed)

### Cascade: enemy death → gold

- Expected: enemy.hp ≤ 0 → spawn 4 sparks + shake + +5 gold + remove
- Observed: yes (scenario `enemy_death_grants_gold`: gold went 100 → 105+)

## Visual QA (Tier 2.6r)

Captured via `play.sh towerdef3d --capture-after=8`. PNG read.

| Check | Verdict |
|---|---|
| Top-down 3D camera works | ✅ Camera at (0, 22, 0) rotated -π/2 looking down |
| Towers visible at correct scale | ✅ Gray cylinders with yellow glow tips |
| Waypoints visible | ✅ Green markers at expected positions |
| Base visible | ✅ Blue cube on right side |
| Enemies on path | ✅ Pink-colored grunts walking the zigzag |
| Projectiles flying | ✅ Yellow bolts mid-flight visible at multiple positions |
| HUD renders | ✅ Wave 1/10, Gold 115, Queued 0, base HP bar |
| Lighting + shadows | ✅ Towers cast diagonal shadows across ground |
| `top_down_3d` camera mode functional | ✅ First real-game test of this mode |

## Known engine gaps surfaced

No new bugs found this run. Pre-known limitations confirmed:
- **Tower targeting "first match"** — engine has no `select: nearest`
  query op. Towers fire at first matching enemy within range, not
  necessarily closest. Acceptable for v1.
- **Contact radius is literal-only** — can't write `radius:
  "self.properties.range"`. All tower types need fixed radius unless
  this becomes a primitive expansion. Future ADR candidate.

## Bugs / issues

None blocking.

## Recommendations

Ready for user playtest. Game runs end-to-end:

```bash
~/yume/scripts/play.sh towerdef3d
```

Pipeline used: `/yume-design ... --autonomous` produced the GDD,
sketches, JSON, scene, scenarios, and visual QA in a single autonomous
run with no manual intervention. 3rd consecutive successful run.
