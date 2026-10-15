# Code-built mesh ops — reference

_Last updated: 2026-10-15 (ADR 0083 F2-F5)_

## Entry shape

```jsonc
"materials": {"iron": {"color": "#4a4a4f", "roughness": 0.4, "metallic": 0.8}},
"meshes": {
  "<name>": {
    "primitives": [ /* parts, in order */ ],
    "params": {"body": "#a04020"},   // values for $body
    "cast_shadow": true               // default for every part
  }
}
```

Each part has `op`, optional `pos` ([x, y, z], default 0) and optional
`rotation_deg` ([x, y, z], Node3D YXZ order). Both accept `$param`.

## Materials

A part uses `"material": "<name>"` from the `materials` block, or inline
fields: `color`, `roughness` (default 1.0), `metallic` (default 0.0),
`emission`, `emission_energy`. Inline fields win over the named material.
Parts with the same five values share one material and one surface, so
reuse materials: fewer materials means fewer draw calls.

## Plain ops (Godot primitives)

| op | Fields | Local frame |
|---|---|---|
| `box` | `size` [x, y, z] | centered on `pos` |
| `sphere` | `radius` | centered |
| `cylinder` | `radius`, `height` | centered, axis +Y |
| `capsule` | `radius`, `height` (total, with the caps) | centered, axis +Y |
| `prism` | `size` [x, y, z] | centered, the triangle in XY, ridge along Z at the top |
| `torus` | `inner_radius`, `outer_radius` | centered, ring in the XZ plane |
| `plane` | `size` [x, z] | flat in XZ, faces +Y |
| `quad` | `size` [x, y] | flat in XY, faces +Z |

## CSG ops

| op | Fields | Local frame |
|---|---|---|
| `lathe` | `profile` [[r, y], ...] (r >= 0), `segments` (>= 3, default 16) | spins around +Y. The bake closes the profile along the axis. |
| `extrude` | `polygon` [[x, y], ...], `depth` | the polygon in XY, depth along Z, centered on `pos` |
| `sweep` | `polygon` [[x, y], ...], `path` [[x, y, z], ...], optional `interval` (default 0.05) | the polygon follows the path. The path is a polyline, so add points for a smooth bend. |

Lathe and sweep shade smooth. Extrude has flat faces.

## Cuts (CSG groups)

Parts with the same `group` form one CSG shape. A part with
`"csg": "subtract"` cuts the earlier parts of its group, and
`"csg": "intersect"` keeps only the overlap. A cut part takes the
material of the group's first part, so the faces of the hole match the
wall.

Limits:

- No `quad` or `plane` in a CSG group (they are not closed shapes).
- No `name` or `pivot` on a part in a CSG group.
- A CSG part appears one frame after the plain parts. This is normal.

## Conventions (choices, not rules)

- Unit space: about 1 unit tall. `state.scale` sets the size per entity.
- Floor props: base at y = 0. A hovering, flying or sunk object can
  differ. The base is a choice for each game (ADR 0083 F4).
- Front: -Z (Godot forward) for actors, signs and doors, unless the game
  needs another front.

## Worked examples

### Vase (lathe)

```json
"vase_3d": {"primitives": [
  {"op": "lathe", "segments": 24, "color": "#b5653a", "roughness": 0.6,
   "profile": [[0.18, 0], [0.24, 0.1], [0.27, 0.3], [0.16, 0.62], [0.11, 0.78], [0.15, 0.86]]},
  {"op": "cylinder", "pos": [0, 0.01, 0], "radius": 0.2, "height": 0.02, "color": "#6b3a1a"}]}
```

### Arched wall (cuts)

```json
"arch_wall_3d": {"primitives": [
  {"op": "box", "group": "wall", "pos": [0, 0.5, 0], "size": [1.4, 1.0, 0.2], "material": "stone"},
  {"op": "box", "group": "wall", "csg": "subtract", "pos": [0, 0.3, 0], "size": [0.5, 0.6, 0.4]},
  {"op": "cylinder", "group": "wall", "csg": "subtract", "pos": [0, 0.6, 0],
   "rotation_deg": [90, 0, 0], "radius": 0.25, "height": 0.4},
  {"op": "box", "pos": [0, 1.04, 0], "size": [1.5, 0.08, 0.26], "color": "#6e6a62"}]}
```

The cylinder turns 90 deg on X, so its axis runs along Z through the
wall. The box cut and the round cut together make the arch.

### Lamp post (sweep, emission)

`yume-mesh-author` made this one on 2026-10-15 in 3 rounds. The note
`docs/reviews/mesh-lamp_post_3d.md` has the plan and the rounds.

```json
"materials": {"iron": {"color": "#2e2e33", "roughness": 0.5, "metallic": 0.6}, "stone": {"color": "#8c8982", "roughness": 0.95, "metallic": 0.0}},
"lamp_post_3d": {"primitives": [
  {"op": "box", "pos": [0, 0.03, 0], "size": [0.22, 0.06, 0.22], "material": "stone"},
  {"op": "box", "pos": [0, 0.085, 0], "size": [0.16, 0.05, 0.16], "material": "stone"},
  {"op": "box", "pos": [0, 0.13, 0], "size": [0.1, 0.04, 0.1], "material": "stone"},
  {"op": "cylinder", "pos": [0, 0.17, 0], "radius": 0.032, "height": 0.05, "material": "iron"},
  {"op": "cylinder", "pos": [0, 0.54, 0], "radius": 0.02, "height": 0.78, "material": "iron"},
  {"op": "sphere", "pos": [0, 0.945, 0], "radius": 0.028, "material": "iron"},
  {"op": "sweep", "material": "iron", "polygon": [[0.012, 0], [0.0085, 0.0085], [0, 0.012], [-0.0085, 0.0085], [-0.012, 0], [-0.0085, -0.0085], [0, -0.012], [0.0085, -0.0085]], "path": [[0, 0.86, 0], [0, 0.895, -0.035], [0, 0.918, -0.08], [0, 0.928, -0.13], [0, 0.925, -0.18], [0, 0.912, -0.215], [0, 0.9, -0.23]], "interval": 0.02},
  {"op": "sweep", "material": "iron", "polygon": [[0.007, 0], [0, 0.007], [-0.007, 0], [0, -0.007]], "path": [[0, 0.78, 0], [0, 0.81, -0.03], [0, 0.85, -0.07], [0, 0.89, -0.1], [0, 0.915, -0.12]], "interval": 0.02},
  {"op": "cylinder", "pos": [0, 0.885, -0.23], "radius": 0.006, "height": 0.035, "material": "iron"},
  {"op": "lathe", "segments": 4, "pos": [0, 0.852, -0.23], "rotation_deg": [0, 45, 0], "profile": [[0, 0.03], [0.07, 0]], "material": "iron"},
  {"op": "box", "pos": [0, 0.846, -0.23], "size": [0.095, 0.012, 0.095], "material": "iron"},
  {"op": "box", "pos": [0, 0.795, -0.23], "size": [0.07, 0.09, 0.07], "color": "#d89a40", "emission": "#ff8c1a", "emission_energy": 0.45, "cast_shadow": false},
  {"op": "box", "pos": [0, 0.744, -0.23], "size": [0.085, 0.012, 0.085], "material": "iron"},
  {"op": "cylinder", "pos": [0.04, 0.795, -0.19], "radius": 0.006, "height": 0.1, "material": "iron"},
  {"op": "cylinder", "pos": [-0.04, 0.795, -0.19], "radius": 0.006, "height": 0.1, "material": "iron"},
  {"op": "cylinder", "pos": [0.04, 0.795, -0.27], "radius": 0.006, "height": 0.1, "material": "iron"},
  {"op": "cylinder", "pos": [-0.04, 0.795, -0.27], "radius": 0.006, "height": 0.1, "material": "iron"},
  {"op": "sphere", "pos": [0, 0.73, -0.23], "radius": 0.012, "material": "iron"}]}
```

Ideas to reuse: a `lathe` with 4 segments makes a pyramid roof. Two
`sweep` parts make a curved arm and its brace. The glowing glass keeps
`emission_energy` near 0.45: a higher value clips to white in the
preview. For real light on the ground, give the entity a `visual.light`
block (ADR 0072).
