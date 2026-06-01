# ADR 0064 — Data-driven replication config

_Date: 2026-06-01_
_Status: accepted_

## Context

ADR 0063's client-server netcode replicates state, but **what** it replicates is
hardcoded in engine GDScript: `net_driver._serialize_state` bakes in "entities
tagged `actor`, fields position + facing." That violates the two load-bearing
Yume invariants:

- **Invariant #1 — data drives everything.** Every other game-specific decision
  (entities, rules, goals, audio, HUD) is JSON; the replication policy should be
  too. A shooter wants to replicate projectiles + hp; a sim wants different
  fields — neither should require editing engine code.
- **Invariant #8 — engine = primitives + interpreter.** The engine should ship a
  generic "replicate state per a declarative spec" interpreter; the per-game
  spec is content.

User framing (2026-06-01): "make this more configurable as stated in the Yume
principle — a JSON config saying what to serialize, like all other content."

## Decision

Add a per-game **`net.json`** (sibling of `goals.json` / `flow.json` /
`audio/cues.json`) that declares the replication policy, and make `net_driver` a
generic interpreter that reads it. Schema:

```jsonc
// data/demo_<game>/net.json
{
  "snapshot_hz": 20,                          // server state send rate
  "interpolation": { "enabled": true, "delay": 0.1 },  // client smoothing
  "replicate": [
    { "query": { "tags_all": ["actor"] },     "fields": ["position", "facing"] },
    { "query": { "tags_all": ["projectile"] }, "fields": ["position", "velocity"] },
    { "query": { "tags_all": ["enemy"] },      "fields": ["position", "facing", "hp"] }
  ]
}
```

- **`replicate`** is a list of groups. Each `query` selects entities via the
  engine's existing query primitive (`Query.matches` — Invariant #5, same
  `tags_all` / `tags_any` / `tags_none` / `state` semantics as rules), and
  `fields` lists the state to send for matched entities.
- **Field serialization** (generic): `"position"` → `Entity.get_position()`
  (serialized as `[x, y, z]`); any other field → `Entity.get_state(field)` (its
  raw value — float / Vector2 / Vector3 / int / bool / string).
- **Interpolation is type-driven**: on the client, numeric + vector fields lerp
  between the two bracketing snapshots; non-numeric (string / bool) snap to the
  newer snapshot. `"position"` lerps. The OWNED actor keeps its local `facing`
  (responsive mouse-look — ADR 0063), so the `facing` field is skipped for the
  owned actor only.
- **Default (no `net.json`)**: the prior hardcoded behavior — one group,
  `{tags_all: ["actor"]}`, fields `["position", "facing"]`, 20 Hz, interpolated.
  So every existing demo keeps working unchanged.

The wire record per entity becomes self-describing — `{id: {position:[x,y,z],
facing: f, ...}}` — instead of a positional array, so different groups can send
different field sets. (Still Godot binary-variant over `@rpc`, not JSON on the
wire — JSON is only the authoring format, per ADR 0063.)

## Consequences

- **Per-game replication policy in JSON, zero engine edits** — the netcode is now
  as data-driven as the rest of Yume. Adding a replicated field = editing
  `net.json`, not GDScript.
- Reuses `Query.matches`, so replication selection is consistent with rules
  (tags/state filters, anti-tags).
- New surface: a `net.json` loader in `net_driver` + a `validate_net.py`
  (fields/query well-formed, fields exist on the matched defs where checkable).
- Bandwidth/feel knobs (per-field interpolate on/off, reliable vs unreliable,
  per-group send rate, quantization) are deliberately **out of v1** — added later
  if a game needs them. v1 = query + fields + global snapshot_hz + interp.
- Non-numeric replicated fields (strings/arrays) are supported but always snap
  (no interpolation) — fine for discrete state (anim_state, team, name).

## Alternatives considered

- **Keep it hardcoded** — rejected; violates Invariants #1 + #8, and the user
  explicitly asked for the data-driven version.
- **A block in `scene.json`** instead of a dedicated `net.json` — rejected;
  replication is a game/world concern, not a per-scene presentation concern, and
  Yume's pattern is one file per concern. A dedicated `net.json` matches
  `goals.json` / `flow.json`.
- **Full per-field control in v1** (reliability, per-field interp, quantization)
  — deferred; start minimal (query + fields), extend when a game needs it.

## References

- Extends **ADR 0063** (client-server netcode — the replication *mechanism*; this
  makes the *policy* content).
- Reuses **`Query.matches`** (the query primitive — Invariant #5).
- Invariants **#1** (data drives everything) + **#8** (engine = primitives +
  interpreter), `docs/30_framework_primitives.md`.
