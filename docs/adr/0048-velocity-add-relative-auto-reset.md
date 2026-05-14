# ADR 0048 — `velocity_add_relative` auto-resets per sim-tick

_Date: 2026-05-15_
_Status: accepted_
_Supersedes: ADR 0040's `state.zero_velocity_pretick` opt-in workaround_

## Context

Camera-relative WASD (ADR 0040) uses `velocity_add_relative` effects — each
movement key fires an input rule that ADDS its rotated contribution to
the entity's velocity. Multi-key same-tick (W+D held) accumulates into
a diagonal naturally.

But across ticks, the previous tick's velocity persisted. When the player
mouse-turned mid-walk, last tick's velocity pointed in the OLD facing,
this tick's add was in the NEW facing — the vector sum landed BETWEEN
the two directions, producing a visible "the camera is pulling me
sideways" drift. User-reported as "something pulling" on 2026-05-10.

The original fix (ADR 0040 follow-up) added an opt-in flag:

```jsonc
"state_init": {
  "zero_velocity_pretick": true   // ← workaround
}
```

…plus a per-tick scan in `world.gd`:

```gdscript
func _pretick_velocity_zero() -> void:
    for id in entities.keys():           # O(N) scan every sim tick
        var ent = entities[id]
        if not bool(ent.get_state("zero_velocity_pretick", false)): continue
        if ent.velocity is Vector2: ent.set_velocity(Vector2.ZERO)
        elif ent.velocity is Vector3: ent.set_velocity(Vector3.ZERO)
```

…plus suppression logic in `input_registrar.gd` (don't queue `stop_x`/
`stop_y` for opt-in actors, lest they wipe camera-relative components)
…plus a `data-demo.md` gotcha rule warning content authors
…plus a multimesh_director check (treat opt-in entities as runtime
movers, exclude from static batching).

**Four layers of workaround for one semantic mismatch in the primitive.**

## Decision

Make `velocity_add_relative` **auto-reset velocity on the first add per
sim-tick** for any entity. Subsequent adds within the same tick accumulate
normally — preserving the multi-key diagonal behavior.

Detection mechanism:
- `world.gd::_tick_due()` writes `world_state["_tick"] = _tick_count`
  each sim-tick (via ADR 0047 — `world_state` is the `_engine` entity's
  state, monotonic counter visible to effects).
- `velocity_add_relative` reads `env.world._tick` and compares to the
  entity's `state._vel_add_last_tick`. If different, fresh tick → reset
  velocity to zero before adding. Update the marker.

```gdscript
var current_tick := int(ws.get("_tick", -1))
var last_tick := int(ent.get_state("_vel_add_last_tick", -2))
var fresh_tick := current_tick != last_tick
if fresh_tick:
    ent.set_state("_vel_add_last_tick", current_tick)
# ... compute dvx/dvz from facing-rotated forward/strafe ...
if v_cur is Vector2:
    var base := Vector2.ZERO if fresh_tick else (v_cur as Vector2)
    ent.set_velocity(base + Vector2(dvx, dvz))
```

The primitive now does what content authors expected from its name —
"compute and write THIS tick's camera-relative contribution" — instead
of mechanically adding to whatever residue was lying around.

## Consequences

### Deletions (four workaround layers gone)

| Before | After |
|---|---|
| `world.gd::_pretick_velocity_zero()` (16 lines, O(N) per tick scan) | Deleted entirely |
| `input_registrar.gd` zero_velocity_pretick suppression branches (35 lines) | Deleted |
| `multimesh_director.gd` zero_velocity_pretick disqualifier | Deleted (actor/player tag already covered it) |
| `data/demo_aldenmere/entities/player.json` `state.zero_velocity_pretick: true` + 200-word comment | Deleted |
| `data-demo.md` "`velocity_add_relative` requires deceleration mechanism" gotcha | Will simplify (next pass) |

Net engine LOC: **~60 lines deleted, ~15 lines added** (the auto-reset
block in `velocity_add_relative`).

### Gated `stop_x` / `stop_y` to world-frame cameras only

A subtle interaction: `stop_x` (engine-queued when no E/W held) used to
fire a `velocity_set x: 0` rule. For camera-relative WASD with only one
movement key, that rule would WIPE the camera-relative x component on
the same tick the movement set it. The `input_registrar` previously
suppressed the queue for opt-in actors.

After this ADR, the suppression is gone — but the lib bundle's stop_x /
stop_y RULES now gate themselves to world-frame cameras only:

```jsonc
"query": {"tags_all": ["world_clock"],
          "state": {"camera_mode_in": ["top_down_3d", "third_person_3d"]}}
```

Camera-relative cameras (FP, iso) rely on `velocity_add_relative`'s
auto-reset (mid-walk) and `lib_wasd_stop` (full-idle) for snap-to-zero.
Per-axis stop is meaningless for them and would still wipe components.
Gate is enforced declaratively in the rule, not imperatively in the
engine.

### Visual / feel preserved

- **Aldenmere FP**: identical feel — auto-reset gives the same
  per-tick freshness that pretick-zero used to give.
- **doomarena3d FP**: unchanged — uses `drag` for snap; the auto-reset
  is additionally helpful but invisible.
- **isometric_3d cameras**: same as Aldenmere FP path.
- **World-frame cameras** (top_down_3d, third_person_3d): unaffected;
  they use `velocity_set` per-axis, no relative rotation.

### Backward-incompatible content change

Any per-game `state.zero_velocity_pretick: true` is now a no-op. The
flag does nothing. The grep cleanup removed it from all in-tree demos;
future authoring guidance dropped the field. If a downstream game
re-introduces the flag, it'll silently work the same as without it —
no warning needed (the flag is harmless data).

The per-entity `state._vel_add_last_tick` field is engine-private
(leading underscore convention per `data-demo.md`). Content rules
should not query or write it.

## Alternatives considered

### A. Keep the four-layer workaround

Status quo. Rejected — exactly the dirt this ADR is removing.

### B. Add an opt-in to the auto-reset

`state.velocity_add_resets: true` — only entities opting in get the
reset semantics. Backward-compatible for any game that was relying on
the accumulating behavior cross-tick.

Rejected because **no game was relying on the cross-tick accumulation
deliberately** — every use site was either bug-tolerant (doomarena3d
used drag to mask it) or worked around it (Aldenmere with pretick-zero).
Making the new behavior universal is the cleaner contract.

### C. Rename to `velocity_set_relative_per_tick`

Make the semantics clearer in the name. Rejected — the existing name is
already used in content; renaming requires content migration. The
docstring on the effect now documents the per-tick reset.

### D. Express via a rule-phase reset before input

Add a "pretick" phase that fires before input, with rules that reset
state. Content-side, more flexible. Rejected — adds a new phase to the
scheduler for one use case. The effect-internal reset is more localized.

## Tech-director review

Accepted. Net engine LOC: **−60**. No new primitives, no new phase, no
new opt-in fields. Just a semantics tightening on an existing effect.

Invariants verified:
- **#1** (JSON-only content channel): no engine-game leakage. Content
  authors stop seeing `zero_velocity_pretick` and the multi-line gotcha
  warning.
- **#8** (engine = primitives + interpreter): `velocity_add_relative`
  remains one of the canonical motion effects; its semantics tightened
  but it didn't bifurcate into multiple variants.
- **#9** (phase boundaries flush): the auto-reset happens within the
  effect's apply pass, not as a separate phase. No phase ordering change.

Tests: 840 unit pass (down 1 — the obsolete multimesh test that
exercised `zero_velocity_pretick`). Aldenmere walking capture confirms
camera-relative WASD works without the flag.

## References

- ADR 0040 — Camera-relative WASD (introduced the original workaround)
- ADR 0047 — `world_state` as `_engine` entity (provides the `_tick`
  counter this ADR depends on)
- `godot/scripts/engine/core/effects/effect_motion.gd::velocity_add_relative`
- `godot/data/lib/input_bundles/wasd_with_fp_variant.json`
