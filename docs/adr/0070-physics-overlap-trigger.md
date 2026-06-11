# ADR 0070 — Physics overlap trigger (`trigger: "overlap"` + `body_type: "area"`)

_Date: 2026-06-11_
_Status: accepted_

## Context

Yume has one proximity primitive: `trigger: "contact"` — a per-tick
radius query over the engine's SpatialIndex. It is deterministic,
phase-ordered, headless-testable, and circles-only. That last property
is a real authoring gap: a thin finish-line strip, a doorway, a boost
pad, a pit-lane corridor cannot be expressed as a center+radius without
either over-catching (radius spans the whole strip width AND length) or
chaining many small circles.

Godot already ships exactly the missing capability: Area3D / PhysicsServer
area overlap detection with real shapes and swept tests. ADR 0044's
physics schema reserved `body_type: "area"` for this but left it
unimplemented (fell back to static with a warning).

Per ADR 0021 (expose, don't reimplement), the right move is to expose
Godot's overlap detection as a SECOND trigger — not to replace contact.
The two differ in guarantees, not in shape of use:

| | `contact` | `overlap` (this ADR) |
|---|---|---|
| predicate computed by | the sim (SpatialIndex, fixed order) | Godot PhysicsServer (broadphase) |
| deterministic across runs/machines | YES — feeds lockstep, replay, hash oracle | NO — float/broadphase/timing drift |
| shape | circle (planar radius) | any collision shape (box, sphere, ...) |
| needs physics space / scene tree | no (bare env dicts tick fine) | yes |
| event model | level-triggered (fires every tick while near) | edge-triggered (enter / exit) |

## Decision

1. **`body_type: "area"`** is implemented in PhysicsBodyBuilder:
   `area_create()` + the existing shape pipeline (incl. `from_visual_mesh`
   shrink-wrap), `area_set_collision_mask` selecting which body layers it
   detects, monitorable off (it watches; it is not watched).
2. **Spawn wiring**: SpawnManager registers a World monitor callback per
   area (`area_set_monitor_callback`). RID bodies get
   `body_attach_object_instance_id(entity)` so events resolve back to
   entity ids; character bodies resolve via their node's `entity_ref`.
3. **Event buffer**: callbacks append `{a: <area entity id>, b: <body
   entity id>, change: "enter"|"exit"}` to `env.overlap_events`. Nothing
   fires mid-physics-step.
4. **Dispatch**: PhaseScheduler drains the buffer in the react phase
   (after contact, before relation_changed) and fires
   `trigger: {type: "overlap", change: "enter"|"exit"}` rules whose
   `query: {a: ..., b: ...}` specs match the event pair. Bindings mirror
   contact: `a` (the area), `b` (the body), `self` = `a`.
5. **Determinism doctrine** (the load-bearing caveat): overlap is
   PRESENTATION-GRADE. Overlap rules may drive juice — toasts, stings,
   flashes, camera kicks, ambient triggers. They MUST NOT drive
   replicated, replayed, or win-condition state (laps, score, spawns):
   those stay on contact/tick rules, whose answers the sim owns.
   Reviewer axis: any overlap rule whose effects mutate fields named in
   net.json `replicate` or read by goal/win rules is a defect.

## Consequences

- Shaped trigger volumes become one JSON block (autorace's start-line
  toast is the reference use).
- The buffer/drain keeps rule ORDERING inside the tick discipline; what
  stays non-deterministic is whether/when Godot reports the overlap —
  hence the presentation-grade rule above.
- Unit tests cover dispatch (synthetic events injected into
  `env.overlap_events`); the physics-side event generation is verified
  by live capture, not headless assert — by design, since headless
  determinism is exactly what overlap doesn't promise.
- **Scripted-input runs generate NO overlap events** (verified
  2026-06-11): StepRunner bursts sim ticks synchronously without
  physics steps, so bodies teleport through trigger volumes between
  broadphase updates. `--capture-input` flows and scenario tests will
  never fire overlap rules — verify overlap content with live play or
  real-time AI captures. This is the determinism quarantine working as
  designed, not a bug.
- Two toasts fired in the same second render overlapped (ScreenFlow
  anchors all toasts at one position) — cosmetic stacking is future
  ScreenFlow polish.
- 2D parity (PhysicsServer2D areas) deferred with the rest of ADR 0044
  Condition 9.

## Alternatives considered

- **Backing `contact` itself with physics**: rejected — breaks the
  determinism contract under lockstep/replay/oracle (ADR 0060/0061/0063
  all lean on sim-owned answers; ADR 0063 documents Godot 3D physics as
  not cross-machine deterministic).
- **Polygon/strip support in SpatialIndex**: deterministic shaped
  triggers, but reimplements what Godot does well (ADR 0021 violation)
  and grows the index from grid-hash to general geometry — the cost the
  zone primitive (ADR 0031) already paid for axis-aligned regions.
- **Zone-state primitive (ADR 0031) for the finish line**: zones are
  axis-aligned and tick-polled; they cover region-membership semantics
  but not arbitrary shapes or enter/exit edges from real colliders.
