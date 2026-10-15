# ADR 0083 — Code-built meshes v2: baked parts, CSG ops, shared materials

_Date: 2026-10-15_
_Status: accepted 2026-10-15 (revision 3: tech-director accept with conditions, all applied. User approved.) Section 4 amended in F4._

## Context

On 2026-10-15 the user set a priority: "we should prioritize code-built
first, doesn't matter it is through blender or direct 3d". Code-built
meshes are free and deterministic. Their pivot and facing come from
construction, so a gate can check them. AI meshes need a measured
`y_offset` and `mesh_yaw_offset` for each asset.

The current code-built path is `godot/data/meshes.json` plus
`scripts/engine/libs/mesh_lib.gd`. Each entry lists Godot primitives
(box, sphere, cylinder, capsule, plane, prism, torus, quad). On
2026-10-15 the library had 117 meshes with 469 parts. The path has these
limits:

1. **Shapes.** There is no lathe, extrude, sweep or boolean cut. A vase,
   an arch, a window hole or a pipe is not possible.
2. **Materials.** Each part gets a new `StandardMaterial3D` with a color
   and an optional emission. There is no roughness or metallic, and no
   shared palette.
3. **Draw calls.** Each part is its own `MeshInstance3D`. `house_1f` has
   8 parts, so it is 8 draw calls, but it has only 5 colors.
4. **Five build paths.** `MeshLib.build_primitives_into()` has 4 callers:
   `renderer_3d/entity_mesh_3d.gd`, `ui/widgets/viewmodel_director.gd`,
   `editor/yume_scene_preview.gd` and `qa/asset_preview.gd`.
   `multimesh_director.gd` has its own copy of the shape switch
   (`_build_mesh_for_primitive`). That copy drops `emission` and ignores
   `pivot`, and it makes one MultiMesh per part.
5. **The convention is not kept.** 33 of 117 meshes have a base off
   `y = 0`. Some float (`person` +0.10, `merchant_npc_hero_3d` +0.20,
   `merchant_portal_3d` +1.35, `prim_unit_banner` +0.50). `imp_3d` and
   `ranger_3d` face +Z. Demos make up for some bases with `y_offset`.
   Nothing checks the base, the facing, or the look of the result.

Godot 4.6 has the missing geometry. `CSGPolygon3D` has `MODE_SPIN`
(lathe), `MODE_DEPTH` (extrude) and `MODE_PATH` (sweep). A
`CSGCombiner3D` child with `OPERATION_SUBTRACTION` cuts holes.
`CSGShape3D.bake_static_mesh()` returns an `ArrayMesh`, with one surface
for each material. `SurfaceTool.append_from()` merges plain meshes. Per
ADR 0021, we expose these APIs and write no geometry code.

Two Godot facts constrain the design (checked against the `4.6-stable`
source by the tech-director review,
`docs/reviews/0083-code-built-meshes-v2-tech-director.md`):

- CSG updates are deferred. `_make_dirty()` queues `update_shape()` with
  `call_deferred()`. `bake_static_mesh()` returns an empty mesh until
  that call runs. The class reference says to await
  `get_tree().process_frame` first.
- CSG uses Manifold. `PlaneMesh` and `QuadMesh` are not manifold, and
  CSG recalculates normals. Plain parts must not go through CSG.

## Decision

Extend the direct `meshes.json` path in five parts. Blender stays an
optional later backend. It is not in this ADR.

### 1. Bake each mesh once, merged by material key

`MeshLib.bake(mesh_def, params) -> Dictionary` returns the baked meshes,
the separate parts and the AABB. A cache holds each result. The key is
the exact text of the primitives, the resolved params, the flags and the
`materials` block, so a key never matches two different inputs.

- **Plain parts** (all current ops) merge with
  `SurfaceTool.append_from(mesh, 0, part_transform)`. Each material key
  gets one `SurfaceTool`. Each `commit()` adds one surface to the
  `ArrayMesh`. This runs synchronously.
- **The material key** is color, roughness, metallic, emission and
  emission energy. Parts with the same key share one material instance.
  Emission is part of the key, so an emissive part never lights another
  mesh.
- **`cast_shadow`** splits the result. The bake returns at most two
  `ArrayMesh` values: one for shadow casters and one for the other parts.
- **Separate parts.** A part with `name` or `pivot` stays its own node.
  The animation director addresses these parts (ADR 0035).
- **Callers.** `build_primitives_into()` becomes a thin wrapper over
  `bake()`, so the viewmodel, the editor preview and the asset preview
  use the same path. `multimesh_director.gd` calls `bake()`. We delete
  `_build_mesh_for_primitive`. The director then makes one MultiMesh per
  baked surface set. It also gets emission and pivot support from the
  shared path.
- **Shader paint.** `entity_mesh_3d.gd` `_paint_shader_recursive()` sets
  one `material_override` from surface 0 today. It changes to one
  `ShaderMaterial` per surface with `set_surface_override_material()`.
  Live case: the 4-color `river_3d` water in `demo_aldenmere`.
- **Cache bound.** The cache keeps up to 512 entries. When it is full,
  it drops the least recently used entry. `house_1f` with a per-instance
  `$albedo` makes one entry for each tint.

`mesh_lib.gd` already builds visual nodes inside `scripts/engine/libs/`.
That breaks the "engine modules import no visual nodes" line in
`engine-scripts.md`. `bake()` adds CSG nodes, so we move `mesh_lib.gd`
to `scripts/renderer_3d/` in F2.

### 2. New ops through Godot CSG, with a warm-up bake

| op | Godot node | Fields | Local frame |
|---|---|---|---|
| `lathe` | `CSGPolygon3D`, `MODE_SPIN` | `profile` (list of `[r, y]`, `r >= 0`), `segments` (3 or more) | Spins around +Y. The bake closes the profile along the axis: it adds `[0, y_last]` and `[0, y_first]`. |
| `extrude` | `CSGPolygon3D`, `MODE_DEPTH` | `polygon` (list of `[x, y]`), `depth` | Godot extrudes along -Z. The bake adds `+depth/2` on Z in the `append_from` transform. The baked mesh ignores the root CSG node's own transform. |
| `sweep` | `CSGPolygon3D`, `MODE_PATH` + `Path3D` | `polygon`, `path` (list of `[x, y, z]`) | `path_rotation = PATH_ROTATION_PATH_FOLLOW` and `path_local = true`. The first has no "Z must decrease" limit. The second keeps the warm-up node's position out of the mesh. |

A part can also set `"csg": "subtract"` or `"csg": "intersect"` and a
`group`. The bake applies each cut to the earlier parts of the same
group. CSG runs only for a group that has a `csg` part, or for a part
with a `lathe`, `extrude` or `sweep` op. A `quad` or `plane` part in a
CSG group is a validator error.

```jsonc
{"op": "box", "group": "wall", "pos": [0, 0.5, 0], "size": [1, 1, 0.1], "material": "stone"},
{"op": "box", "group": "wall", "csg": "subtract", "pos": [0, 0.6, 0], "size": [0.3, 0.3, 0.2]},
{"op": "lathe", "pos": [0.6, 0, 0], "segments": 16, "material": "clay",
 "profile": [[0.12, 0], [0.15, 0.08], [0.08, 0.3], [0.1, 0.4]]}
```

**The CSG bake is asynchronous. A warm-up hides that from the callers.**

- `MeshLib.warm(mesh_names) -> Signal`: it builds the CSG trees of all
  the named meshes out of the scene tree. It awaits one `process_frame`,
  then calls `bake_static_mesh()` on each, fills the cache and frees the
  nodes. (F1 showed that the tree is not needed, but the frame is.)
- WorldBoot calls `warm()` with every mesh that the level's entity defs
  reference. It awaits the signal before the renderers attach. The
  callers then read the cache synchronously, as in part 1.
- A def that spawns later with an un-warmed CSG mesh starts its own
  `warm()`. The renderer shows the plain parts at once and adds the
  CSG surfaces one frame later.
- We do not call the deprecated `_update_shape()` binding.

### 3. Shared materials

`meshes.json` gets a top-level `materials` block. A part uses
`"material": "<name>"`, or it keeps an inline `color` with optional
`roughness`, `metallic` and `emission`. Each distinct key makes one
material instance, shared by all meshes.

```jsonc
"materials": {
  "wood":  {"color": "#7a5230", "roughness": 0.9},
  "iron":  {"color": "#4a4a4f", "roughness": 0.4, "metallic": 0.8},
  "stone": {"color": "#8c8a83", "roughness": 0.95}
}
```

Existing `color` and `$param` entries keep their meaning. `rotation_deg`
also accepts `$param` values.

### 4. Construction convention and gates

> **Amended 2026-10-15 (F4, user decision).** The user rejected the strict
> base rule: "I think this is very game specific and shouldn't be strict
> like this". The base height and the facing of a mesh are content
> choices. `validate_meshes.py` checks only the schema. The data fixes of
> the 33 meshes and the demo-offset check below are withdrawn. See
> "F4 results".

The convention applies to every mesh in `meshes.json`, with no
exemption field:

- Unit space. The base sits at `y = 0`. `state.scale` sets the size.
- The front faces `-Z` (Godot forward).

The 33 meshes off `y = 0` get a data fix in F4. This includes the
center-pivot projectiles, clouds and viewmodels. A shift of the parts
alone does not fix every mesh:

- `floor_grate` is a floor slab. A plain shift lifts its top surface
  above the entities on it.
- The 3 viewmodels share one offset in `scene.json`, but each needs a
  different shift.
- 5 projectiles would draw 0.16-0.34 m above their colliders.

So F4 starts with a table of all 33 meshes. Each row names the fix: a
part shift, a new design, or a new size. Each row also names every
coupled value: the collider offset, the viewmodel offset, the spawn
height and any entity offset. One commit changes the mesh and its coupled values together. Per the reset-field-family rule, the
whole `y_offset` / `y_offset_mesh` family resets, not one field.
`imp_3d` and `ranger_3d` turn to face -Z, and any `mesh_yaw_offset` that
made up for them goes.

Gates:

- **`tools/validators/validate_meshes.py`** (static, in `run_all`):
  - known ops, the required fields for each op, a definition for each
    `$param`, and a name in `materials` for each `material`.
  - `segments >= 3` and `r >= 0` for `lathe`, and no `quad` or `plane`
    in a CSG group.
  - the unit-space AABB, with rotation, must have its base at `y = 0`
    (tolerance 0.02).
  - for each demo on disk, any entity that sets `y_offset`,
    `y_offset_mesh` or `mesh_yaw_offset` on a code-built mesh is an
    error. A code-built mesh needs no offset. Some offsets are not base
    fixes, for example the water z-fight bias in `demo_aldenmere` and
    the step height in `demo_steptest`. The error message says where
    that height goes: into the mesh data, or into `position.y`.
- **Facing is a visual gate, not a static gate.** No static rule can
  find the front of an arbitrary shape. The turntable sheet (part 5)
  puts the yaw 0 frame first, with the label "front (-Z)". The
  `yume-mesh-author` skill must check that frame before it accepts a
  mesh.
- **Tests ship with each phase.** F2 tests the bake. It checks one
  surface per material key, an emissive part with its own key, the
  cache hit, the cache bound and per-surface shader paint. F3 tests each
  op: vertices present, the expected AABB, a closed lathe profile, and a
  CSG cut that makes the volume smaller. Each test also runs the MultiMesh path.
- **Visual gate.** Each phase that changes rendering captures
  `demo_aldenmere` and one more 3D demo before and after, per
  `.claude/rules/visual-qa.md`.

### 5. Turntable check and an authoring skill

- `scripts/qa/asset_preview.gd` gets `--turntable=N`. It captures N
  angles of one mesh into one contact-sheet PNG. The yaw 0 frame comes
  first.
- A new forked skill `yume-mesh-author` (ADR 0082) authors one mesh.
  Arguments: a mesh name, a text brief and an optional concept image.
  It plans the parts, writes the entry, runs `validate_meshes.py`,
  captures the turntable and compares the result with the brief. It
  does up to 3 fix rounds. It writes the entry to `meshes.json` and a
  review note, and it returns 200 words or fewer.
- `yume-asset-designer` Strategy C2 points to this skill.
- `tools/yume_codegen/entities.py` emits only mesh names, so it needs
  no change. `api-manifest.json` has no mesh-op section. The op list
  lives in `validate_meshes.py` and the `yume-mesh-author` skill.

## Phases

| Phase | Work | Estimate |
|---|---|---|
| F1 | Spike on the pinned `gl_compatibility` renderer, headless. Test the warm-up sequence: build in the tree, await one frame, bake, free. Also run the bake out of the tree. The CSG update does not need the tree, so this can work too. Use the simpler sequence that passes. Measure the draw calls of `demo_aldenmere` before and after a merge prototype. | 0.5 day |
| F2 | `bake()` + material key + cache + shared materials. Move `mesh_lib.gd` to `renderer_3d/`. All 5 callers use `bake()`. The MultiMesh copy goes. Per-surface shader paint. Tests + visual gate. | 1.5 days |
| F3 | `lathe`, `extrude`, `sweep`, CSG groups, `warm()` in WorldBoot. Tests + visual gate. | 1 day |
| F4 | `validate_meshes.py`. Fix the 33 bases and the 2 facings. Reset the offsets that made up for them. | 1 day |
| F5 | Turntable capture + `yume-mesh-author` + 3 sample meshes (a vase, an arched doorway, a lamp post). | 1 day |

If F1 shows that the warm-up bake fails, F3 uses `SurfaceTool` for lathe
and extrude only. Booleans then wait for a new ADR.

## Consequences

**Positive:**

- Code-built meshes can show curves, holes and profiles.
- Fewer draw calls and materials in every 3D demo.
- One build path instead of five. MultiMesh gets emission and pivot.
- A static gate on the base and on stray offsets, and a visual gate on
  facing.

**Negative:**

- WorldBoot waits one extra frame when a level uses CSG meshes.
- Animated parts (`name` or `pivot`) do not merge, so rigs gain nothing.
- A merged mesh cannot recolor one part at run time. A per-instance
  `visual.params` change makes a new cache entry.
- F4 touches 33 library meshes. A demo that relied on an old base or
  facing changes until its offset resets. Demos are gitignored, so the
  validator checks only the demos on the disk.

## Alternatives considered

**A. Blender `bpy` scripts that export `.glb`.** This gives bevels,
modifiers and sculpt-like tools. Blender is not installed, and it adds a
large dependency and an import step. Keep it as a later backend for
shapes that CSG cannot make.

**B. Our own geometry in `SurfaceTool` for every op.** Full control, but
it rebuilds what `CSGPolygon3D` already does. ADR 0021 rejects this.
It stays only as the F1 fallback.

**C. A synchronous CSG bake through the `_update_shape()` binding.**
Simple, but Godot marks that binding deprecated. A later Godot release
can delete it.

**D. A `pivot_mode: center` field for meshes off `y = 0`.** It passes the
validator without a data fix. It is a per-def escape hatch, which the
project rules forbid. Rejected.

**E. Keep the current path and add AI meshes for the rest.** This keeps
the per-asset offsets and the per-mesh cost. It is against the user's
priority.

## F1 results (2026-10-15)

The spike ran on Godot 4.6.1, headless and on `opengl3`
(`gl_compatibility`). Both gave the same numbers.

| Case | Result |
|---|---|
| `bake_static_mesh()` at once, in or out of the tree | `null` |
| `bake_static_mesh()` after one `process_frame`, in or out of the tree | Works. A wall with a hole has 96 vertices. |
| `lathe`, `extrude`, `sweep` after one frame | Work. 384, 48 and 132 vertices. |
| A parent at (100, 50, 100) | Does not leak into the mesh. |
| `extrude` with `depth` 0.2 | The AABB runs from z = -0.2 to 0, so the `+depth/2` shift is needed. |
| `SurfaceTool.append_from` + `commit(existing)` | One surface, then two. |

Changes to the plan:

- `warm()` needs no node in the scene tree. It builds the CSG trees out
  of the tree, awaits one `process_frame` and bakes. One frame is still
  required.
- A cut part with no material adds a surface for the faces of the hole.
  F3 gives each cut part the material of the first part in its group.

Draw calls, measured on `opengl3` after 240 frames:

| Scene | Mesh nodes | After merge (estimate) | Draw calls now |
|---|---|---|---|
| `pipeline_v1_3d` | 1998 | 1193 (-40%) | 1362 |
| `doomarena3d` | 37 | 27 (-27%) | 93 |
| `aldenmere_3d` | 297 | 297 (0%) | 819 |

`aldenmere_3d` uses mostly AI `.glb` meshes, so the merge does not help
it. None of the three scenes uses MultiMesh today.

## F2 results (2026-10-15)

F2 shipped `MeshLib.bake()`, the material key, the shared `materials`
block, the bake cache (512 entries) and per-surface shader paint.
`mesh_lib.gd` moved to `scripts/renderer_3d/`. All 5 callers use the
bake. The MultiMesh copy of the shape switch is gone.

Draw calls on `opengl3` after 240 frames:

| Scene | Before | After |
|---|---|---|
| `pipeline_v1_3d` | 1362 | 942 (-31%) |
| `doomarena3d` | 93 | 80 (-14%) |

The first `aldenmere_3d` number (819) came from a template without
imported `.glb` assets, so it is not a valid baseline.

Visual gate: the old and the new code ran from the same imported
template, captured at 4 s and 6 s. `pipeline_v1_3d` at 6 s and
`aldenmere_3d` match (mean pixel difference 0.1 and 1.6 of 255). In
`doomarena3d` the walls, the pillars and the viewmodel match. Only the
live enemy differs, because its AI ran differently.

Tests: `test_main` has 1195 passes and 0 failures (1170 before, 25 new).
The `doomarena3d` (41) and `demo_aldenmere` (19) scenarios pass.

## F3 results (2026-10-15)

F3 shipped `lathe`, `extrude`, `sweep`, CSG groups with `subtract` and
`intersect`, and `MeshLib.warm()`.

**A change from the plan.** The plan put a `warm()` call in WorldBoot.
F3 puts it in `build_primitives_into()` instead. A CSG group that is not
in the cache makes the bake "pending". The plain parts show at once, and
one frame later the baked mesh nodes change. An `on_rebuilt` callback
lets `entity_mesh_3d` paint the new nodes again (albedo texture, shader,
shadow mode). So all 5 callers get CSG with no boot step. The MultiMesh
director does not batch a group with a pending bake: those entities keep
their own renderers, which rebuild themselves.

**A bug found in the visual check.** A swept pipe and its base box shared
one material, so they merged into one surface. The pipe did not draw.
`bake_static_mesh()` returns surfaces without indices, and
`SurfaceTool.append_from()` kept only the indexed triangles of the box.
The fix: `warm()` indexes each CSG mesh before it caches it. The gate:
`_all_vertices_drawn()` in `test_mesh_csg` checks that each vertex of a
baked surface is in a triangle. Without the fix, the test fails.

Other findings:

- CSG gives outward normals for both polygon windings, in all 3 modes.
- `sweep` built out of the tree works (`path_local`, a relative
  `path_node`).
- `lathe` and `sweep` set `smooth_faces`. Without it the vase looked
  faceted.

`asset_preview` captured three samples from temporary entries. They were
a vase (lathe), an arched wall (a box minus a box and a cylinder), and a
bent pipe (sweep). All three render as expected.

Tests: `test_main` has 1222 passes and 0 failures (19 new). The
`doomarena3d` (41) and `demo_aldenmere` (19) scenarios pass.

## F4 results (2026-10-15)

The F4 report found 31 of 117 meshes with a base off y = 0 (the review's
rough count was 33). They fall into two groups:

- 13 meshes float: `person`, `imp_3d`, `demon_3d`, `grunt_3d`,
  `ranger_3d`, 5 merchant NPCs, 3 merchant chests and
  `merchant_portal_3d` (+1.35).
- 18 meshes sink or use a center pivot: buried rocks and bushes,
  projectiles, the 3 viewmodels, `cloud_3d`, `floor_grate`, `bird_3d`.

A strict rule would make many of these wrong. A portal hovers, a rock
sinks, a projectile is centered on its flight point. The user decided
that the base is game specific and dropped the rule.

So F4 shipped `tools/validators/validate_meshes.py` with schema checks
only. It is in `run_all` as a repo-wide validator. It checks known ops
and the required fields of each op. Each `$param` needs a value, and each
`material` needs a known name. It also checks the lathe rules, and that
no CSG group holds a `quad` or a `plane`. `--report` prints the unit-space AABB of each mesh, with
rotation, as information. A floating entity stays a visual bug, owned by
the visual QA gate and `validate_center_pivot_y.py`.

No mesh data changed. `imp_3d` and `ranger_3d` still face +Z. The F5
turntable shows the facing of a mesh, but no gate requires -Z.

## F5 results (2026-10-15)

F5 shipped the turntable and the `yume-mesh-author` skill.

- `asset_preview.gd` gets `--turntable=N` (N views in one sheet, frame 0
  from -Z), `--turntable-output=` and `--lib=` (a draft mesh file on top
  of the library).
- **Studio light for the turntable.** The default preview light lit the
  top faces to white and left the front faces in shade. A calibration
  with `#808080`, `#b03020` and `#9a968c` boxes set a white key light of
  0.2 from the camera side and an ambient of 0.1. The three colors then
  render within 6/255 of their authored values. This also explains the
  white stone arch in F3.
- `validate_meshes.py --file=` checks a draft. The validator now also
  rejects `name` or `pivot` on a part in a CSG group.
- `.claude/skills/yume-mesh-author/` is a forked skill with a 5-item
  review (silhouette, proportions, connection, color, front) and up to 3
  rounds. Its `reference/mesh-ops.md` lists every op and holds 3 worked
  examples.

Test run: the skill made `lamp_post_3d` from a text brief in 3 rounds
(18 parts, a swept arm, a 4-segment lathe roof, an amber glow). Only the
color check failed in rounds 1 and 2: the glow clipped to white. The
caller read the final sheet and agrees with the accept.

Two changes from the plan:

- The samples (vase, arched wall, lamp post) stay as worked examples in
  the skill reference. They do not go into `meshes.json`, because no game
  uses them yet. A game adds one when it needs it.
- The facing rule ("the front faces -Z") is a recommendation, like the
  base (see the F4 amendment). The turntable shows the front, and the
  skill records the front of each mesh in its note.
