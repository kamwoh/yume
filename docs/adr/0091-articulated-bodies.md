# ADR 0091 — Articulated bodies: links, joints and motors

_Date: 2026-10-18_
_Status: accepted 2026-10-18_

_Related: ADR 0044 (physics bodies), ADR 0086 (host-neutral spec), ADR 0090 (spec vocabularies)_

## Context

The owner asked for a robot simulation, starting with a wheeled robot.
The spec had no way to join two bodies. A `rigid` body moved, but its
position did not write back to state, so no rule could read it.

A probe on 2026-10-18 built a two-wheel robot from `PhysicsServer3D`
rigid bodies, motor hinges and a pin caster. Headless Godot drove it
straight at 0.6 m/s from 6 rad/s on 0.1 m wheels, as the math predicts.
The probe found two more facts:

- The scenario runner ticked synchronously, so the physics server never
  stepped in a scenario. GDScript cannot step the server by hand.
- A physics frame does step the server in headless mode, if the script
  waits for it.

The owner approved four options on 2026-10-18:

- 1A: one entity holds the whole robot.
- 2A: a motor target is a formula.
- 4: the joint types `hinge`, `ball` and `fixed`.
- 5A: one physics step for each tick in scenarios.

## Decision

### 1. One entity, many links

A `physics` block with `"body_type": "articulated"` has three more
fields:

- `root`: the name of the root link.
- `links`: link name → `{shape, mass, friction, restitution, visual}`.
  `shape` uses the `collision_shape` vocabulary, plus `axis` (`x`, `y`
  or `z`, the long axis of a cylinder or capsule) and `offset`.
- `joints`: a list of `{type, parent, child, at, axis, limit, motor,
  report}`.

The links must form one tree: each link except the root has exactly one
parent joint. `collision_layer`, `collision_mask`, `linear_damp` and
`angular_damp` apply to all links. Links of one robot never collide with
each other.

Each link frame has the orientation of the root at spawn. `at` places
the child origin in the parent frame, and the joint anchor is that
origin. This is the URDF model with no link rotation, which keeps the
author's arithmetic to additions.

```json
"physics": {
  "body_type": "articulated",
  "root": "chassis",
  "links": {
    "chassis": {"shape": {"type": "box", "size": [0.3, 0.08, 0.4]}, "mass": 2.0},
    "wheel_l": {"shape": {"type": "cylinder", "radius": 0.1, "height": 0.04, "axis": "x"}, "friction": 1.0}
  },
  "joints": [
    {"type": "hinge", "parent": "chassis", "child": "wheel_l", "at": [-0.19, -0.05, -0.1],
     "axis": [-1, 0, 0], "motor": {"target_velocity": "self.state.left_cmd", "max_torque": 3.0},
     "report": "wheel_l"}
  ]
}
```

### 2. Joint types

| Type | Guarantee |
|---|---|
| `hinge` | The child turns about `axis` (in the parent frame) only. A positive angle or velocity follows the right-hand rule. `limit: [lo, hi]` holds the angle in radians. |
| `ball` | The child turns freely about the anchor. |
| `fixed` | The child does not move relative to the parent. The interpreter may merge it into the parent body. |

Only a `hinge` has `axis`, `limit`, `motor` and `report`.

### 3. Motors are formulas

`motor.target_velocity` is a formula with `self` and `world` bindings,
in radians per second. The engine reads it at the end of each tick,
after the rules ran. A rule changes a command with `state_set`, so the
ADR adds no effect type. `motor.max_torque` (N·m) limits the motor.

### 4. Readback

At the start of each tick, before the rules run:

- the root pose writes `state.position`, `state.yaw` and
  `state.velocity`.
- a hinge with `"report": "x"` writes `state.x_angle` (radians, not
  wrapped, so it counts whole turns as an encoder does) and
  `state.x_speed` (radians per second).

The engine names no field of its own except the reserved `position`,
`yaw` and `velocity`. The author names each joint report.

### 5. One physics step for each tick

Live play already runs one tick in each physics step (ADR 0068). In a
scenario, `StepRunner._advance` now waits for one physics frame after
each tick, when the world has an articulated body. It pauses the server
between ticks, so a frame that a step waits for (a key press, for
example) adds no step. Such scenarios run in real time, about 1 s for
60 ticks. A world with no articulated body keeps the synchronous path.

### 6. Host-defined motion

The motion is host-defined (ADR 0086). A test checks a guarantee with a
margin and never an exact value:

- equal forward wheel speeds move the robot forward in a straight line.
- opposite wheel speeds turn it in place.
- a motor with a zero target stops its wheel.
- the tick count stays exact: one tick for each step.

### 7. The Godot interpreter

- `ArticulatedBody` (`coordinators/articulated_body.gd`) builds one
  `PhysicsServer3D` rigid body for each link that is not `fixed`. A
  `fixed` link adds its shape and mass to its parent body.
- A host body has one material. So a `fixed` link with its own
  `friction` or `restitution` keeps its own body. A 6-DOF joint with
  every axis locked holds it (amended 2026-10-18, ADR 0093).
- A `hinge` is `joint_make_hinge` and a `ball` is `joint_make_pin`.
- Godot's hinge motor turns against the right-hand rule, so the
  interpreter negates the target.
- `max_torque` becomes an impulse for each physics step.
- The bodies never sleep, because a motor change does not wake a body.
- The renderer draws each link at its pose, from a mesh-library mesh or
  from the link shape in a `visual.color`.

### Enforcement

- `ArticulatedBody.JOINT_TYPES`, `LINK_FIELDS`, `JOINT_FIELDS`,
  `MOTOR_FIELDS` and `SHAPE_AXES` are closed lists.
  `validate_host_neutral.py` check 11 reads them. It also checks the
  tree, and it rejects `root`, `links` or `joints` on another body type.
- The engine reports `physics.bad_articulation` and builds no body for
  a block that is not one tree.
- `test_articulated_body` in `test_runner.gd` drives a rover through
  `StepRunner` and checks the guarantees above. It also checks the
  merged fixed link, the joint count and the release of every RID.
- `test_host_neutral.py` has 7 new cases.
- `gen_api_manifest.py` prints the lists (§Articulated bodies).

## Consequences

**Enables:**
- Wheeled robots, arms and legged robots from JSON, with motors that
  rules command and joint state that rules read.
- A second interpreter (for example a robotics simulator) can run the
  same robot file, because the spec names no host class.
- A URDF importer can emit this shape, because the model is a URDF
  tree.

**Costs:**
- A scenario with an articulated body runs in real time.
- A new joint type, link field or motor field needs an ADR.

**Known gaps:**
- A rule that writes `state.position` does not move an articulated
  body. The next readback replaces the value.
- `slider` joints, joint springs and per-link collision layers are not
  in the spec.
- Sensors (ray, lidar) and an external controller loop are later steps.
- An articulated body under the lockstep driver (ADR 0061) is not
  deterministic across peers.

## Alternatives considered

- **One entity for each link, and relations for the joints.** This fits
  the primitives, but one robot becomes several spawns and relations,
  which an author can easily get wrong.
- **A `joint_motor` effect.** A formula target needs no new effect, and
  the motor follows the state with no extra rule.
- **A kinematic drive model on a character body.** It is exact, but it
  is not articulated and cannot grow into an arm or a leg.
- **Test motion only in unit tests.** Game scenarios would then not
  cover the robot's main verb.
