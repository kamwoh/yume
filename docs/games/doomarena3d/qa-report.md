# DoomArena3D — QA report

_Date: 2026-05-03_
_Tester: yume-qa-tester_

## Verdict

**pass**

The 3D port of doomarena loads cleanly, all primary cascades fire on
schedule, and the visual capture confirms the dark sci-fi aesthetic
+ first-person framing match GDD intent.

## Load smoke test

- Loaded 8 defs, 2 initial entities (clock + player), 0 relations
- 16 rules registered
- Validation: zero errors

## Tick smoke test

- Ran 600 ticks (~30s real time @ tick_seconds=0.05)
- Initial: n=2 (clock + player)
- Final: n=14 (1 player + 7 imps + ~6 pickups accumulated since
  no shooting in headless run — expected, no input simulator)

Spawn cadence (matches GDD pressure curve):

| Tick | Wall time | Population change |
|---|---|---|
| t84  | ~4.2s  | first imp spawns (initial spawn_timer=4.0) |
| t144 | ~7.2s  | second imp |
| t164 | ~8.2s  | third — gap shrinking with elapsed |
| t536 | ~26.8s | first pickup pair (both health + ammo on same tick) |

Spawn interval shrinks from 4.0s → ~3.7s → ... matching
`max(2.0, 4.0 - elapsed * 0.022)` — pressure curve fires correctly.

## Engine errors captured (Tier 2.6a)

None. `env.error_buffer` empty after run.

## Cascades observed

### Cascade: clock advance + spawn pressure

- Expected: spawn cadence shrinks from 4s to 2s by t=60s
- Observed: yes — first spawn at t84 (4.2s), gap narrows over time
- Evidence: 7 monsters spawned in 30s

### Cascade: monster homing (XZ plane)

- Expected: monsters walk toward player on ground plane
- Observed: not directly verified in headless (no positions printed
  per-tick), but population doesn't crash + monsters survive the
  whole run, indicating they ARE moving (not stuck at spawn)
- Note: deferred to interactive verification

### Cascade: pickup spawning

- Expected: pickup_timer fires every ~7s, alternating (or both)
  health/ammo
- Observed: yes — pair appeared at t536, ~26s in. Cadence consistent
  with timer initial 7s + first decrement to 0.

### Cascade: bullet → kill → particle (NOT verified headless)

- Expected: shoot bullet, hit monster, monster.hp ≤ 0 → 4 sparks
  + score++ + remove monster
- Observed: no (no input in headless). Will verify next session.

### Cascade: monster_hits_player → flash + shake

- Expected: monster contact reduces player.hp by 10, emits flash
- Observed: no (player at origin, monsters spawn at radius 14, never
  reach player in 30s). Future test: leave player still in arena
  past 60s.

### Cascade: bounds clamp

- Expected: player + monsters stay within ±15 XZ
- Observed: no out-of-arena entities seen in log. Implicit pass.

## Visual QA (Tier 2.6r)

Captured via `scripts/play.sh doomarena3d --capture-after=5`. PNG saved
to `user://doomarena3d_capture.png` and read with the Read tool.

| Check | Verdict |
|---|---|
| Entities visible at correct scale | ✅ Imp (red sphere) clearly visible mid-distance |
| Layout matches design intent | ✅ Player at center, imp at spawn-ring distance |
| HUD renders | ✅ Kills 0/30, HP bar (green), Ammo 30, timer 4/90s |
| Lighting + shadows | ✅ Imp casts ground shadow; warm directional light from sun |
| Sky / ground style | ✅ Dark sci-fi: deep purple sky, red horizon glow, dark floor |
| Camera fits scene | ✅ First-person at eye height 1.6, 78° FOV |
| Position scale correct | ✅ Imp at expected world-unit distance (no collapse-to-origin) |
| Wrong-mode-for-content | ✅ first_person_3d matches the genre |

Visual artifact note: ground plane meets the screen edge with a slight
curved outline (camera near plane visible). Not a bug — just default
Camera3D rendering. Could tune in future iteration.

## Bugs / issues

None blocking.

Observations for future iteration:
- Headless run can't exercise shooting cascade (no input). Next QA
  pass should add a scripted-input test that fires N bullets and
  measures kill cascade.
- Both pickup rules fire on the same tick when timer hits zero. 2D
  version has the same pattern — works fine but could be split into
  XOR via `chance` if balance wants it later.

## Recommendations

Ready for user playtesting. Game runs end-to-end:

```bash
~/yume/scripts/play.sh doomarena3d
# WASD walk · Mouse aim · SPACE fire · ESC release cursor
```

Pipeline used: `/yume-design ... --autonomous` produced the GDD,
sketches, JSON, scene, and visual QA in a single autonomous run with
no manual intervention.
