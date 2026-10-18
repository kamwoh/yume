# ADR 0093 — URDF importer for articulated bodies

_Date: 2026-10-18_
_Status: accepted 2026-10-18_

_Related: ADR 0051 (authoring-time emitters), ADR 0091 (articulated bodies), ADR 0092 (sensors)_

## Context

ADR 0091 put robots in the spec. Most robots already exist as URDF
files, the format of ROS. A URDF robot is a tree of links and joints,
the same model as an articulated body. The owner asked for the importer
as the next robot step on 2026-10-18.

The two models differ in three ways:

- ROS is Z-up with X forward. Yume is Y-up with -Z forward.
- A URDF joint can rotate the child frame (`rpy`). A Yume link frame
  has the root orientation.
- URDF has no motors.

## Decision

`tools/yume_urdf` is an authoring-time emitter (ADR 0051). It writes the
ADR 0091 JSON and adds no spec field.

1. **Axes.** A ROS vector (x, y, z) becomes (-y, z, -x). The matrix has
   determinant 1, so a hinge keeps its right-hand rule.
2. **Frames.** The tool folds each joint rotation into the positions,
   joint axes and shapes below it. A box must end axis-aligned, and a
   cylinder must end along x, y or z. Other rotations stop the import
   with an error, because the spec has no rotated shape.
3. **Motors.** Each `continuous` or `revolute` joint gets a motor that
   reads `self.state.<joint>_cmd`, with `<limit effort>` as
   `max_torque`, and a report named `<joint>`. A `revolute` joint keeps
   its limits.
4. **Unsupported input stops the import.** `prismatic`, `planar` and
   `floating` joints are errors. A mesh geometry gives a warning, and
   that link has no shape.
5. **Options.** `--friction LINK=V` (URDF has no friction), `--layer`
   and `--spawn`.

### Interpreter change

A URDF caster is a `fixed` link with a frictionless sphere. A merged
link takes the parent body's material, so the caster dragged. Now a
`fixed` link with its own `friction` or `restitution` keeps its own
body, held by a 6-DOF joint with every axis locked. ADR 0091 §7 records
the change.

### Renderer fix

A URDF root link is often `base_footprint`, with no shape. The renderer
drew a default 1 m box for it, and the box hid the robot. A link with no
shape now draws nothing.

### Enforcement

- `tools/yume_urdf/tests/test_urdf.py` (in `scripts/ci_checks.sh`)
  checks the example conversion, the axis change, the folded rotation,
  the motors and four error cases. The example output must pass
  `articulation_problems`.
- `test_articulated_body` checks the separate body for a fixed link with
  its own friction. It also checks that a link with no shape draws
  nothing.
- The local rover demo imports `examples/diffbot.urdf` and drives it in
  a scenario.

## Consequences

**Enables:**
- Existing robot models load into Yume with one command.
- The output is plain JSON, so an author can edit it.

**Costs:**
- The tool rejects a URDF with rotated shapes, sliders or meshes as its
  only collision shapes. Many real robots use meshes.

**Known gaps:**
- No mesh collision. A mesh needs a hull or a box fit.
- No inertia tensor. The host computes inertia from the shapes.
- No `xacro`. Run `xacro` first to get a plain URDF.

## Alternatives considered

- **Add link rotation to the spec.** It would take any URDF, but every
  author would need rotation arithmetic. A later ADR can add it when a
  real robot needs it.
- **An importer in the engine.** The spec names no host format, and
  URDF is one input format of many. An authoring tool keeps the engine
  free of it.
