# ADR 0059 — Water surface from scene.json

_Date: 2026-05-26_
_Status: accepted_

## Context

The text-to-world pipeline produces scenes where the semantic map
contains a `water_surface` region (rivers, ponds, lakes). Until now
that region was rendered two ways, both unsatisfying:

1. **Albedo paint** — the ground shader
   (`ground_simple_displace.gdshader`) samples the semantic map and
   uses the water color as the ground albedo. Result: flat blue paint
   on the ground plane. No transparency, no motion, no depth.
2. **Heightmap depression** — the heightmap dips the river region
   below the surrounding terrain, so there's a *trough* where water
   should be — but the trough is still painted ground, not water.

A stylized water shader already exists at
`data/lib/shaders/water_stylized.gdshader` (procedural animated
ripples, transparency, fresnel-ish crests, no textures). It was
authored but never wired to anything, because the entity-mesh render
path (`multimesh_director.gd`) only supports `StandardMaterial3D`
(albedo + roughness + metallic) — it can't apply a custom
`ShaderMaterial` to an entity. So water couldn't be an entity.

The only engine surface that already loads custom shaders +
ShaderMaterials is `GroundRenderer` (ADR 0052 / 0055). It builds the
ground plane, loads `ground.mesh.shader`, forwards
`ground.mesh.shader_params`. A water surface is the same shape of
problem: a flat plane with a custom shader.

## Decision

Add a `water` block to `scene.json`, sibling of `ground`, rendered by
`GroundRenderer.build_water()` (same class — it already owns the
shader-plane machinery; a separate coordinator would duplicate it).

```jsonc
"water": {
  "mesh": {
    "size": [80, 80],            // plane extent (usually matches ground)
    "level": 0.0,                // world Y of the water SURFACE
    "shader": "res://data/lib/shaders/water_stylized.gdshader",
    "shader_params": {           // forwarded to the ShaderMaterial
      "base_color": [0.10, 0.30, 0.45, 0.78],
      "highlight_color": [0.65, 0.82, 0.92, 0.85],
      "wave_speed": 0.08,
      "ripple_density": 6.0
    }
  }
}
```

`build_water()`:
- builds a flat `PlaneMesh` (no subdivision — ripples are in the
  fragment shader via UV + TIME, no vertex displacement)
- positions it at `y = level`
- loads `shader`, makes a `ShaderMaterial`, forwards `shader_params`
  (+ auto-sets `plane_size` from `size`, mirroring the ground path)
- adds a `Water` MeshInstance3D to the world
- **no collider** — water is not a walkable/colliding surface; actors
  pass through (swimming/boats are future game-logic, not engine)

### Why no masking is needed

The water shader uses `render_mode blend_mix` (transparent) and the
terrain is opaque. The opaque terrain is rendered first and writes
the depth buffer. The transparent water plane tests against that
depth buffer, so:

- Where terrain sits **above** `water.level` (the town plain, hills) —
  the terrain is nearer the camera; the water plane behind it is
  depth-rejected → invisible.
- Where terrain dips **below** `water.level` (the river bed, carved by
  the heightmap) — the water plane is nearer than the terrain →
  renders.

So the water plane only appears in the heightmap depressions. The
shoreline is exactly where terrain crosses `water.level` — handled
for free by depth testing.

This composes directly with ADR 0052 (heightmap displacement): the
heightmap carves the riverbed, the water plane fills it.

### Refinement (2026-05-26): region mask is required after all

Depth-test confinement alone was insufficient. With a HILLY heightmap,
the city itself has low-spots **below** `water.level`, so the full
plane showed water there too — the river appeared to "flood the city."
Depth-test confines vertically but not horizontally.

Fix: a **region mask**. compose_world derives `water_mask.png` (white =
`water_surface` semantic pixels, dilated ~4px to reach the banks) and
the water shader (`water_stylized.gdshader`) samples it via the same
world→UV math as the ground shader, `discard`-ing fragments outside
the mask (`use_water_mask` uniform). Water then exists ONLY in the
river/pond region — city terrain height is irrelevant, no flooding.

The two mechanisms now cooperate: the **mask** confines water
horizontally to the river region; the **water_level + depth-test**
set the surface height + shoreline within that region. `water_level`
is derived from the 85th-percentile heightmap-Y over the water mask
(see compose_world.derive_water_level).

## Consequences

**Enables:**
- True animated, transparent water in any auto-generated or
  hand-authored scene by adding one scene.json block.
- The terrain-fills-with-water effect (riverbed depression + flat
  water level) that paint-on-ground could never produce.
- Reuse of the existing `water_stylized.gdshader` (and any future
  water shader — the block just points at a different path).

**Precludes / defers:**
- **Per-level water rebind** — `GroundRenderer.rebind_shader_params`
  (ADR 0055) currently rebinds the ground shader on level transition.
  A symmetric `rebind_water_params` is deferred until a game needs
  per-level water tuning. For now the water block is read once at boot.
- **Water collision / swimming** — actors pass through. Buoyancy,
  swim state, drowning are game-logic (rules + state), not engine,
  and out of scope here.
- **Reflections** — the stylized shader fakes shimmer via metallic +
  roughness, not screen-space reflection. True SSR is a Godot
  WorldEnvironment concern, separately tunable, not part of this ADR.

**No new primitive in the seven-primitive sense.** This is a
capability-exposure (ADR 0021 pattern), exactly like `ground.mesh`
exposes the ground plane. The engine ships the renderer; the JSON
declares the surface.

## Alternatives considered

- **B — `visual.shader` on entities.** Add ShaderMaterial support to
  `multimesh_director`, then water = a flat quad entity. More general
  (glowing/animated entities in future) but touches the hot
  per-entity render path; bigger blast radius for a single feature.
  Deferred — can be done later without conflicting with this ADR.
- **C — water as a biome in the ground shader.** All in one shader,
  no separate plane. But the ground is opaque, so transparency can
  only be faked, and there's no actual surface at a fixed level — the
  "terrain dips and water fills it" effect is impossible. Rejected.

## References

- `data/lib/shaders/water_stylized.gdshader` — the surface shader
- `godot/scripts/engine/coordinators/ground_renderer.gd` — host class
- ADR 0052 — heightmap displacement (carves the riverbed)
- ADR 0055 — multi-biome ground / shader_params rebind
- ADR 0021 — expose Godot capabilities, don't reimplement
