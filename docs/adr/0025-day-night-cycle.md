# ADR 0025 — Day/night cycle exposed via scene.json lighting block

_Date: 2026-05-07_
_Status: accepted (shipped — `scripts/engine/lighting_director.gd`, 2026-05-09)_

## Context

Yume's 3D scenes today have static lighting authored directly in
per-game `.tscn` files (e.g. `scenes/doomarena3d.tscn` declares a fixed
DirectionalLight3D + WorldEnvironment). That is fine for arena
shooters where time of day is irrelevant, but it locks out any game
where the player should *feel time passing*.

Concrete driver: the kingdom-sim GDD (`docs/games/merchant/GDD.md`)
calls for a "living world" — NPCs follow daily schedules (wake at
dawn, market in mid-day, sleep at night). Without visible lighting
transitions, the player has no perceptual signal that schedule
phases are advancing. The world feels frozen even when its rules
are running.

The state needed to drive day/night already exists. Multiple demos
keep a `world_clock` singleton entity tagged `world_clock` with a
`time_of_day` state field on a 0.0–24.0 hour scale (harvestcore,
tinypond). Content rules already mutate it. What's missing is the
*visual translation* from that scalar to sun rotation + colors.

If we leave this to per-game GDScript, every world-time game
reimplements the same Tween/Color-curve math, and JSON-only authoring
breaks (Invariant #1: data drives everything). If we hardcode it in
each demo's `.tscn`, the lighting becomes static again — the whole
point of the cycle is missed.

Per ADR 0021 (Yume = JSON layer over Godot), the right answer is to
EXPOSE Godot's existing capabilities (`DirectionalLight3D`,
`WorldEnvironment`, `Sky`, `ProceduralSkyMaterial`, built-in
`Color.lerp` interpolation) through a JSON-declarative block in
`scene.json`.

## Decision

Add a new optional `lighting` block to `scene.json` and a new engine
module `lighting_director.gd` that reads it.

### scene.json schema additions

```jsonc
{
  "lighting": {
    "directional_light": {
      "enabled": true,
      "binds_to": "world_clock.time_of_day",   // "<tag>.<state_field>"
      "shadow_enabled": true,
      "color_at_noon": "#fff8e0",
      "color_at_dawn_dusk": "#ff9060",
      "color_at_night": "#3050a0",
      "energy_noon": 1.0,                      // optional
      "energy_horizon": 0.7,                   // optional
      "energy_night": 0.05                     // optional
    },
    "ambient": {
      "color_day": "#a0a0c0",
      "color_night": "#202040",
      "energy_day": 0.4,
      "energy_night": 0.1
    },
    "sky": {
      "horizon_day": "#80a0e0",
      "horizon_night": "#101020",
      "ground_day": "#404040",                 // optional
      "ground_night": "#101010"                // optional
    }
  }
}
```

Every block is optional. Omit `lighting` entirely → no-op (current
behavior preserved for 2D demos and static-light 3D demos).

### Engine module

`godot/scripts/engine/lighting_director.gd` — a `Node` registered as
a sibling of `GameShell` / `OverlayManager` / `ScreenFlow` under the
universal `play.tscn`:

- On `_ready`: reads `<data_root>/scene.json`'s `lighting` block. If
  absent → permanent no-op.
- On first `_process` after env exists: adopts existing
  `DirectionalLight3D` + `WorldEnvironment` siblings if a per-game
  `.tscn` declared them; otherwise creates them.
- Each frame: resolves the bound value (e.g. `world_clock`'s
  `time_of_day`), interpolates sun rotation + color + ambient + sky
  horizon, writes them to the live nodes.

### Binding resolution

Bound lookup is generic — the JSON specifies `"binds_to":
"<tag>.<field>"` and the director uses `QueryLib`-style tag lookup.
First it checks `env.world_state` (so games using
`state_set target=world` work); failing that, it scans entities for
the tag and reads `state.<field>`. Fallback: assume noon
(`time_of_day = 12.0`) — lets the director run sanely in demos
without a clock entity.

### What's reused vs new

Per ADR 0021:

| Capability | Source |
|---|---|
| Directional lighting | Godot `DirectionalLight3D` (engine adopts/creates one) |
| Ambient + sky | Godot `WorldEnvironment` + `Environment` + `Sky` |
| Procedural sky material | Godot `ProceduralSkyMaterial` (only if engine creates env) |
| Color interpolation | Godot `Color.lerp(other, t)` |
| Rotation construction | Godot `Basis.looking_at(direction, up)` |
| Cycle math | NEW (small static helpers in `lighting_director.gd`) |

The "cycle math" novelty is just three pure functions —
`day_factor(t)`, `sun_color_at(t, c_noon, c_horizon, c_night)`,
`sun_direction_at(t)` — each ~3 lines. We don't reinvent tweens or
spline curves; we use a closed-form sinusoidal day factor and
piecewise color lerp.

## Consequences

**Enables**: any 3D demo can opt into a day/night cycle by adding a
`lighting` block to its `scene.json` plus a `world_clock` entity
whose state field advances over time (a content concern — typically
a single `state_add time_of_day +<delta>` rule on a tick trigger).
Kingdom-sim is the immediate consumer.

**Doesn't break**:
- 2D demos: scene.json has no `lighting` → director no-ops.
- Existing 3D demos (doomarena3d, fpsgarden, etc.): scene.json has
  no `lighting` → director no-ops, their hand-authored `.tscn`
  lighting stands.

**Composition**: any 3D demo that DID want both pre-authored
lighting AND the cycle (e.g. doomarena3d gets a "night campaign
variant") can already declare the lighting block; the director will
adopt the existing `DirectionalLight3D` instead of creating a new
one. Per-game `.tscn` shadow + light_energy initial values are
overwritten each frame by the director — that's by design.

**Single binding scope**: only one `world_clock`-style entity is
read per scene. If a game wants two lights with independent cycles
(moon vs sun), that's a future ADR — for now, one cycle.

**Tick-rate independence**: the director updates per-frame
(`_process`), not per-tick. Color blends remain smooth even at
slow tick rates (e.g. 0.5s). Time-of-day itself advances on tick
(in JSON content rules), so the director simply observes the
latest state each frame.

## Alternatives considered

**A. Per-game GDScript Tween in each `.tscn`.** Rejected — every
world-time game reimplements the same color+rotation math, and the
generated-content workflow (`/yume-design`) can't write GDScript.
Violates Invariant #1.

**B. New effect type `set_directional_light_color` + `rotate_light`.**
Rejected — would let content rules mutate lights directly, but
forces every game to redeclare 24 transition rules per cycle. The
director encapsulates "given a time, what should the light look
like" once, freeing content to focus on the world.

**C. Hardcoded fixed lighting forever.** Rejected — kingdom-sim's
core fantasy is "watching a town wake up and go to sleep". Visible
time-shift is core, not polish.

**D. Plug into the existing `WorldEnvironment` via a new effect chain
on tick rules.** Rejected for the same reasons as (B); also, the
update is a per-frame interpolation, not a per-tick discrete event.
Effects are tick-aligned by design.

## References

- ADR 0021 — Yume as JSON layer over Godot (the architectural framing).
- `docs/guideline/30_framework_primitives.md` § "Engine-recognized scene config"
  (where this block joins `ground` and `level_seed`).
- `godot/scripts/engine/lighting_director.gd` — implementation.
- `godot/scripts/engine/tests/test_runner.gd` § `test_lighting_director_*`.
