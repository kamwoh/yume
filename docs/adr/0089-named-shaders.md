# ADR 0089 — Shaders by name, and custom shaders through the graph

_Date: 2026-10-17_
_Status: accepted 2026-10-17_

_Implements: ADR 0086 phase 3_

## Context

ADR 0086 makes the JSON a host-neutral spec. Today content names a
Godot shader file:

```json
"sky": {"shader": "@lib/shaders/sky_clouds.gdshader", "shader_params": {...}}
```

A second interpreter cannot run a `.gdshader` file. The survey of
2026-10-17 found 17 shader references in content:

| Shader | Uses | Where |
|---|---|---|
| `sky_clouds` | 7 | `lighting.sky.shader` |
| `water_stylized` | 3 | `water.mesh.shader`, one entity `visual.shader` |
| `ground_biome_displace` | 2 | `ground.mesh.shader` |
| `ground_ortho_displace` | 2 | `ground.mesh.shader` |
| `toon` | 0 | library only |
| shader graph (ADR 0058) | 1 | `ground.mesh.shader_dag` |

No game uses a custom hand-written `.gdshader`. The graph has 7
primitives, and all of them draw biome ground. `yume_shadergen`
compiles the graph and then writes
`"shader": "assets/shaders/ground.gdshader"` back into `scene.json`, so
the compiled Godot file is part of the spec.

One game also names `@lib/textures/water_normal.tres`, a Godot
`NoiseTexture2D` resource, in `shader_params`.

The owner approved four choices on 2026-10-17.

## Decision

### 1. Content names a library shader by name

```json
"sky": {"shader": "sky_clouds", "shader_params": {"cloud_coverage": 0.5}}
```

The names are `sky_clouds`, `water_stylized`, `ground_biome_displace`,
`ground_ortho_displace` and `toon`. `ShaderLib.NAMES` in
`util/shader_lib.gd` is the one list.

- Each named shader has a fixed parameter list. `gen_api_manifest.py`
  reads it from the library shader and publishes it in the api
  manifest, with each parameter's type, default and range.
- The exact look is host-defined. Each interpreter writes its own
  version of each named shader. The parameters must change the look in
  the direction their names say.
- A color parameter is `[r, g, b]` or `[r, g, b, a]` from 0 to 1. A
  texture parameter is an asset path (ADR 0087).
- The interpreter sets some parameters itself: `plane_size`,
  `screen_tex` and `depth_tex`. Content does not set them.
- A new named shader needs an ADR.

### 2. A custom shader uses the graph

A game that needs its own shader writes `shader_dag` (ADR 0058). The
spec has no other custom shader form. Content must not name a
`.gdshader` or `.tres` file.

### 3. The graph is the only shader field

When `ground.mesh` has `shader_dag`, it has no `shader` field.
`yume_shadergen` compiles the graph to
`<game>/assets/shaders/ground.gdshader` and no longer edits
`scene.json`. The ground renderer loads the compiled file from that
fixed place. A missing compiled file reports `shader.not_compiled`.
`scripts/play.sh` runs `yume_shadergen` before each run.

### 4. The water normal texture belongs to the interpreter

`water_normal_tex` leaves the spec. When the water shader runs, the
Godot interpreter supplies its own noise texture. The `.tres` file stays
in the library, and only the engine names it.

### 5. Enforcement

- `ShaderLib.load_named(name)` rejects a name outside `NAMES` with
  `shader.unknown`.
- `AssetPath` and `content.py` no longer treat `.gdshader` and `.tres`
  as asset extensions.
- `validate_host_neutral.py` rejects a value that ends with
  `.gdshader`, `.tres` or `.tscn`, and a `shader` value outside
  `NAMES`. It reads `NAMES` from `shader_lib.gd`.
- The contract document lists the names and the rules above.

## Consequences

- A second interpreter knows the full shader vocabulary: 5 names, their
  parameters, and the graph primitives.
- An LLM writes a short name in place of a library path.
- The compiled graph output stops being content. `scene.json` holds
  only the graph.
- The graph covers only biome ground today. A game that wants a custom
  sky or water shader needs new graph primitives first. Each one needs
  an ADR.
- The parameter list of a named shader follows the uniforms of the
  Godot file. A change to those uniforms changes the spec, so it needs
  an ADR.

## Alternatives considered

- **Port all 5 shaders to the graph.** This needs about 20 new
  primitives (clouds, mountains, foam, refraction, fresnel). A second
  interpreter must still implement every primitive, so the cost is
  higher and the portability is the same.
- **Allow a `.gdshader` path as a Godot-only extension.** No game needs
  it. It can join later through an ADR.
