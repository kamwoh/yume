# ADR 0092 — Sensors: rays and lidar that write state

_Date: 2026-10-18_
_Status: accepted 2026-10-18_

_Related: ADR 0005 (raycast_hit), ADR 0086 (host-neutral spec), ADR 0091 (articulated bodies)_

## Context

ADR 0091 gave robots bodies and motors. A robot must also sense the
world each tick, so that a rule can react, for example turn before a
wall.

The `raycast_hit` effect (ADR 0005) does not fit. It is a weapon that
fires once, when a rule runs it. It tests spheres and boxes from entity
fields, not the collision shapes, and it gives the hit to the next
effects, not to state.

The owner approved these options on 2026-10-18:

- 1A: a `sensors` list in the def, on any entity.
- 2: two types, `ray` and `lidar`, that write state.
- 3: an autopilot in the rover demo, in JSON only.

## Decision

### 1. A `sensors` list in the def

```json
"sensors": [
  {"type": "ray", "link": "chassis", "at": [0, 0, -0.21], "direction": [0, 0, -1],
   "range": 3.0, "report": "front", "collision_mask": ["wall"]},
  {"type": "lidar", "link": "chassis", "at": [0, 0.06, 0], "direction": [0, 0, -1],
   "rays": 13, "fov": 2.4, "range": 3.0, "report": "lidar"}
]
```

- The sensor frame is the pose of `link` on an articulated body. Without
  `link`, it is the entity position and `state.yaw`.
- `at` and `direction` are in that frame. `range` is in meters.
- `collision_mask` names the layers that the sensor sees (`"all"` by
  default).
- A ray hits collision shapes, never an `area`, and never a body of its
  own entity.

### 2. Readback

Each sensor reads at the start of each tick, after the ADR 0091
readback and before the rules.

| Type | Writes |
|---|---|
| `ray` | `<report>_distance` (`range` when nothing is hit) and `<report>_hit` (0 or 1) |
| `lidar` | `<report>_ranges` (one distance for each ray), `<report>_min` and `<report>_min_angle` |

A lidar spreads `rays` evenly over `fov`, centered on `direction`, about
the frame up axis. An angle is in radians from `direction`, positive to
the left (the yaw sense). A formula cannot index an array, so
`_min` and `_min_angle` give rules what they need. A later controller
(ADR 0020) can read `_ranges`.

### 3. Host-defined distances

A distance is host-defined (ADR 0086). A test checks a guarantee with a
margin:

- a wall 1.95 m ahead reads 1.95 ± 0.05.
- nothing in range reads exactly `range`.
- a layer that the mask does not list is not seen.
- the frame turns with the entity yaw.

### 4. The Godot interpreter

`SensorArray` (`coordinators/sensor_array.gd`) casts each ray with
`PhysicsDirectSpaceState3D.intersect_ray`. SpawnManager builds it after
the body, so the rays can skip the entity's own bodies. World reads
each sensor once per tick.

### 5. A step-runner fix

The autopilot toggle found a defect in ADR 0091. After `_step_physics`,
the step runner sits inside a physics frame, and there a scripted press
gives no press edge. So a press action never fired after the first tick
of a world with an articulated body. `_do_press` now leaves the physics
frame first. `test_articulated_body` checks two presses after ticks.

### Enforcement

- `SensorArray.SENSOR_TYPES` and `SENSOR_FIELDS` are closed lists.
  `validate_host_neutral.py` check 12 reads them. It also checks that a
  `link` names a link of the def's articulated body, that only a lidar
  has `rays` and `fov`, and the mask layer names.
- The engine reports `sensor.bad_config` for a sensor with no type or
  no report name.
- `test_sensor_array` in `test_runner.gd` checks the guarantees above
  and the skip of a robot's own links.
- `test_host_neutral.py` has 5 new cases.
- `gen_api_manifest.py` prints the lists (§Sensors).

## Consequences

**Enables:**
- Obstacle avoidance, wall following and line-of-sight checks as plain
  rules. The rover demo wanders with five rules.
- An NPC or a character can carry the same sensors.

**Costs:**
- Each ray is one physics query each tick. A 13-ray lidar costs 13
  queries.
- A new sensor type or field needs an ADR.

**Known gaps:**
- No camera, contact or force sensor.
- No sensor noise. A host may add none, so a test cannot depend on it.
- `_ranges` is not usable in a formula until the formula language reads
  arrays.

## Alternatives considered

- **A physics `raycast_hit` that rules call each tick.** It needs one
  rule for each sensor, and the reading does not stay in state.
- **Sensors only on articulated bodies.** Characters and NPCs need the
  same rays, and the frame rule covers both.
