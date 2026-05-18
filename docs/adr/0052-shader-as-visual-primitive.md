# ADR 0052 — Custom shader as a visual primitive

_Date: 2026-05-17_
_Status: accepted_

## Context

Yume's visual layer historically supported three "tiers" of entity
visuals (per `entity_mesh_3d.gd`):

1. `visual.model_3d` → load a `.glb` / `.tscn` directly
2. `visual.mesh` → compose primitives from `meshes.json` (code-drawn)
3. `visual.color` + `size` → bare colored box

Every primitive's material was a `StandardMaterial3D` constructed
by `mesh_lib._make_material()`. This worked for opaque diffuse
surfaces but couldn't express:

- Animated procedural effects (water ripples, fire flicker, magic
  glow, force-field shimmer)
- Multi-layer noise blends (tile-break shaders for ground)
- Time-driven UV scrolls (flowing water, scrolling banners)
- Fresnel + view-dependent effects (glass, ice, polished metal)

Per ADR 0021 ("Yume = JSON layer over Godot"), Godot's shader
system is exactly the kind of capability we should EXPOSE through
a JSON-declared primitive, not reimplement or work around.

The triggering use case was aldenmere's river. The previous
`river_3d` mesh-def used 6 colored boxes (sand/shallow/water/ripple
bands) stacked at different y-heights — a static visual stand-in.
For the "complete the scene 1-by-1" pass, replacing this with
real animated water was the natural next step.

## Decision

Add a new optional `visual.shader` field carrying a `res://` path
to a Godot `.gdshader` file, paired with `visual.shader_params`
(dict of uniform names → values). When present, the renderer
swaps every primitive's `material_override` for a `ShaderMaterial`
backed by the referenced shader, with the params bound as uniforms.

Shader files live under `godot/data/lib/shaders/` (shared across
games) or `godot/data/<game>/assets/shaders/` (per-game). Authors
reference them via the same `res://...` convention used for
textures and meshes.

### Engine surface

```jsonc
"visual": {
  "mesh": "river_3d",
  "shader": "res://data/lib/shaders/water_stylized.gdshader",
  "shader_params": {
    "base_color": [0.10, 0.30, 0.45, 0.85],
    "highlight_color": [0.65, 0.85, 0.92, 0.95],
    "wave_speed": 0.30,
    "ripple_density": 30.0,
    "wave_dir1": [1.0, 0.4],
    "wave_dir2": [-0.4, 1.0]
  }
}
```

The shader replaces materials on ALL primitives of the entity
uniformly. Per-primitive shaders (different shader on each band
of a multi-primitive mesh) are NOT supported in this revision —
authors who need that should split the entity OR use
`material_overrides` (for .glb meshes with named surfaces).

### Implementation

- `entity_mesh_3d.gd::_apply_shader_to_primitives(shader_path,
  params)` — loads the shader via ResourceLoader, walks all
  child MeshInstance3D nodes, attaches a fresh ShaderMaterial.
- Called from the code-drawn-mesh branch immediately AFTER the
  existing `albedo_texture` overlay step (task #117). Order:
  1. MeshLib builds primitives with default StandardMaterial3D
  2. albedo_texture overlays if present (asset-gen output)
  3. shader replaces materials entirely if present (new)
- Param-resolution: `set_shader_parameter(name, value)` for
  each k:v in `visual.shader_params`. Godot auto-converts array
  values to Vector2/3/4 + Color based on the uniform's declared
  type in the shader.

## Consequences

**Enables**:
- Animated water (this revision — `water_stylized.gdshader`)
- Tile-blend shaders for ground (deferred — see #ground_tile_blend)
- Future per-entity glow, ice, glass, magic effects without engine
  changes (just write a new `.gdshader` + reference it from JSON)

**Precludes nothing** — purely additive. Existing entities without
`visual.shader` continue to use StandardMaterial3D as before.

**New rule for path-scoped review**:
- `godot/data/lib/shaders/**` — new tracked directory. Each shared
  shader gets a comment block at the top documenting its uniforms
  and intended use cases.

**Test coverage**: visual gate only — no unit test for shader
rendering (shaders run on the GPU; difficult to assert programmatically).
Empirical verification via in-engine capture + visual QA per
`.claude/rules/visual-qa.md`.

## Alternatives considered

**A. Animated UV-scroll via GDScript only (no custom shader)**

A node that ticks `material.uv1_offset += delta_offset` each frame.
Works with the existing StandardMaterial3D pipeline. Limitation: can
only animate UV transforms, not actual material logic. Couldn't
implement multi-layer noise blending, fresnel, or any effect that
needs custom fragment-shader math. Adequate for "moving texture",
inadequate for "stylized water look."

**B. Per-primitive shader override**

Same primitive can have different shaders per box/cylinder. More
flexible but adds complexity: per-primitive shader dict, per-
primitive uniform sets. Rejected for v1 — when authors need this
they can split the entity into multiple primitives + bind shaders
to material slots via `material_overrides`. Promote if a real use
case demands it.

**C. Inline shader code in JSON**

Author the `.gdshader` body as a string field in the entity def.
Rejected — shader code wants syntax highlighting, error reporting,
versioning under a real .gdshader file. The res:// indirection
keeps JSON clean and the shader editable.

## Empirical case

aldenmere's river prop (`prop_water_plane` → `river_3d`) shipped
with code-drawn static color bands (sand/shallow/water/ripple).
2026-05-17 replaced via this primitive — `water_stylized.gdshader`
generates animated value-noise ripples with no external textures.
Verified via two-frame capture (water_v2_t1.png + water_v2_t2.png,
1s apart) — ripple pattern visibly shifts between frames + water
reads as water at human eye height instead of layered cake.

## Future capability-exposure ADRs unlocked

This ADR establishes the shader-as-primitive pattern. Future
capability ADRs that may build on it:

- Ground tile-blend shader (break the visible repeat pattern when
  tiling a texture across a large plane)
- Fire/torch glow shader (used by juice-designer's lighting layer)
- Ice/glass/water-deep variant shaders sharing the water base
- Magic / aura / forcefield shaders for spell-driven games

Each is a new `.gdshader` file + entity reference; no engine
change needed.
