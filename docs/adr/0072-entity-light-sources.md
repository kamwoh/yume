# ADR 0072 — Per-entity light sources + emissive primitives

_Date: 2026-06-12_
_Status: accepted_

## Context

The engine's only light is the LightingDirector sun (ADR 0025). Every
"lit" prop fakes it — `merchant_lamppost_lit_3d` is a bright sphere
that emits nothing; at dusk the world goes dark with two dozen lamps
standing in it. The visual-density vocabulary (soul.md axis 4:
"micro-lights every 8-15m") has had no real primitive behind it.

Godot ships OmniLight3D / SpotLight3D and material emission; per ADR
0021 we expose, not reimplement.

## Decision

1. **`visual.light` block** on entity defs — EntityMesh3D mounts a
   light child, so lights live/die/move with their entity and scatter
   with patterns:

```jsonc
"visual": {
  "mesh": "merchant_lamppost_lit_3d",
  "light": {
    "type": "omni",            // omni | spot
    "color": "#ffd9a0",
    "energy": 2.5,
    "range": 10.0,
    "position": [0, 3.05, 0],  // local offset (the lamp head)
    "shadow": false,           // per-light shadows are the expensive part
    "angle": 45.0,             // spot only
    "direction": [0, -1, 0]    // spot only — aim vector
  }
}
```

2. **`emission` on mesh-lib primitives** — `{"op": "sphere", ...,
   "emission": "$glow", "emission_energy": 2.0}` maps to
   StandardMaterial3D emission. With glow enabled (ADR 0071-era
   blocks), emissive heads bloom — "the lamp is on" reads even at
   distances where the light's falloff doesn't.

3. **Batching exclusion**: entities with `visual.light` are
   disqualified from multimesh batching (the batcher replaces the
   renderer node; the light child must survive).

## Consequences

- Night/dusk scenes become real: `time_of_day` + lamp entities now
  compose (autorace dusk racing, the lanterns demo's namesake).
- gl_compatibility caps per-mesh light influence (~8 omni); dozens of
  scattered lamps are fine, hundreds are not. Shadowed lights are the
  costly variant and default OFF; enabling per-lamp shadows on iGPU
  hardware is the author's informed choice.
- Carried lights (lantern in hand, headlights) come free — the light
  is a child of the entity's renderer and follows it.

## Addendum (2026-06-13) — arrays, world-unit offsets, area emulation

- `visual.light` accepts an ARRAY of light dicts — multi-light fixtures
  (chandeliers, paired headlights, area-emulation panels) in one def.
  Bindings (`energy_binds`/`color_binds`) are per-entry.
- Light offsets + cone/range geometry are WORLD units: the renderer
  counter-scales each mounted light against the prop's `state.scale`.
  Without this, a [0.16, 5, 0.16] pole catapulted its y=4 spot to
  world y=20 and crushed the cone 0.16x — every pole-mounted spot in
  the lightlab silently lit nothing (empirical 2026-06-13; a bare
  minimal-repro spot worked, isolating the parent-scale cause).
- AREA LIGHTS (no Godot realtime equivalent) are emulated:
  `prim_unit_panel_lit` emissive panel kit + an array of distributed
  low-energy omnis. Reference exhibit: lightlab's hard-vs-soft wall
  pair (theater_spot vs area_softbox).
- gl_compatibility per-mesh light cap (~8) is REAL and silently drops
  excess lights: keep light-dense exhibits spatially separated so no
  single mesh sits inside 8+ light ranges.

## Addendum (2026-06-12) — camera-attached light

`scene.json camera.light` (same schema as `visual.light`) mounts a
light as a CHILD of the Camera3D via CameraDirector — a headlamp that
follows the view with zero lag in every camera mode. Spot type aims
down the camera forward (-Z), i.e. where the player looks. First use:
the lightlab free-cam torch.

## Alternatives considered

- **Scene-level `lighting.point_lights` array**: placements would
  duplicate entity positions and not follow movers. Rejected; can be
  added later if a scene needs unattached lights.
- **Emission-only (no real lights)**: bloom fakes the glow but lights
  nothing around it — a lamppost that doesn't light the ground reads
  dead at night. Both halves are needed.
