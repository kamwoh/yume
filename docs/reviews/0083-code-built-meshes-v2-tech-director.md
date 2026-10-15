# Tech-director review: ADR 0083 (code-built meshes v2)

_Date: 2026-10-15_
_Reviewer: yume-tech-director_
_Input: `docs/adr/0083-code-built-meshes-v2.md` (untracked draft, status proposed). There is no code diff._

## Verdict

**Revise.** The direction is sound and agrees with ADR 0021. The ADR
exposes Godot CSG and does not write its own geometry code. But the
`bake()` contract conflicts with how Godot 4.6 CSG updates. Three
renderer paths break on merged meshes. The pivot and facing claims do
not agree with the data. Fix the five blocking items below, then send
the ADR back for review. The status stays `proposed`. The user decides.

## Invariant checks

| Check | Result | Evidence |
|---|---|---|
| #1 JSON-only content | Pass | New ops are generic geometry. All compositions stay in `meshes.json`. Grep: 0 hits. |
| #2 No semantic effects | Pass (N/A) | The ADR adds no effect types. Grep: 0 hits. |
| #3 No entity classes | Pass | Grep: 0 hits. |
| #5 Queries first-class | Pass (N/A) | Grep: 0 hits. |
| #8 Primitives + interpreter | Pass | `lathe`, `extrude`, `sweep` and `csg` groups are generic verbs that any game can use. They come with an ADR. |
| #9 Phase flush | N/A | No tick or phase change. |
| #10 Freeze policy | N/A | No new pending pipeline. |
| #11 Level discontinuity | Pass | The bake cache keys on mesh name and params, not on entity identity. It can survive `transition_level` safely. |
| #12 Persistent clobber | N/A | |
| ADR 0021 expose, not reimplement | Pass with one gap | CSG is exposed. The ADR does not name the Godot API for the non-CSG merge (see B2). |
| Visual gate | Applies at implementation | F2 changes `renderer_3d/entity_mesh_3d.gd`. Every phase that changes a render needs a capture and a `yume-visual-designer` pass. |
| Tests ship with the phase | Planned | F4 holds the tests. Move each test into the phase that adds the feature (F2 for bake and cache, F3 for ops). |

## Code claims checked

| Claim | Result |
|---|---|
| 117 meshes, 469 parts | True. Ops: box 214, cylinder 114, sphere 104, prism 22, capsule 10, quad 4, torus 1. |
| Each part gets a new `StandardMaterial3D`, color only | True. `mesh_lib.gd` `_make_material()`. Emission is the one extra field (`mesh_lib.gd:150-157`). |
| Each part is its own `MeshInstance3D` | True. `build_primitives_into()`. |
| "A cottage is 8 draw calls and 8 materials" | Partly true. `house_1f` has 8 parts but only 5 distinct colors. A merge gives about 5 surfaces, not 4. |
| `multimesh_director.gd` has a copy of the shape switch | True. `_build_mesh_for_primitive()` at line 417. |
| One MultiMesh per part | True. The group key is `mesh|prim_idx|params_key` (line 114). |
| Only two callers | **Wrong.** `build_primitives_into()` also has callers in `ui/widgets/viewmodel_director.gd:72`, `editor/yume_scene_preview.gd:225` and `qa/asset_preview.gd:78`. |
| `rotation_deg` and `$param` | True. `rotation_deg` does not resolve `$param` today. No mesh uses it with a param. |
| "The `y_offset` and `mesh_yaw_offset` bug classes cannot occur" | **Wrong.** See B4. |

## Godot 4.6 CSG claims checked at the source

Source: `godotengine/godot` tag `4.6-stable`,
`modules/csg/doc_classes/*.xml` and `modules/csg/csg_shape.cpp`.

| Claim | Result |
|---|---|
| `CSGPolygon3D` has `MODE_DEPTH`, `MODE_SPIN`, `MODE_PATH` | True (values 0, 1, 2). |
| `MODE_DEPTH` extrudes | True. It extrudes along **-Z** from the polygon plane. |
| `MODE_SPIN` lathes around Y | True. `spin_sides` must be 3 or more (`ERR_FAIL_COND(p_spin_sides < 3)`). `spin_degrees` must be in (0.01, 360]. |
| `MODE_PATH` sweeps along a `Path3D` | True. It reads `path_node` (a `NodePath`) through `get_node_or_null()`. `PATH_ROTATION_POLYGON` and `PATH_ROTATION_PATH` require "the path Z coordinates to continually decrease". |
| `OPERATION_SUBTRACTION`, `OPERATION_INTERSECTION` | True. |
| `bake_static_mesh()` returns an `ArrayMesh` | True. "Materials from involved CSG nodes are added as extra mesh surfaces." |
| `bake_static_mesh()` (4.4+) can run inside a synchronous `bake()` | **Not shown.** See B1. |
| CSG uses the Manifold library | True (`#include <manifold/manifold.h>`). `CSGMesh3D` accepts only manifold meshes. `PlaneMesh` and `QuadMesh` are non-manifold. |
| Performance | The class reference says CSG has "a significant CPU performance cost" and is for prototyping. Bake once and cache, as the ADR says. |

The pinned docs (`docs/engine-reference/godot/`) say nothing about CSG,
`ArrayMesh` or `SurfaceTool`. The pin is `gl_compatibility`. The F1
spike must run on that renderer.

## Blocking items

### B1. CSG mesh data is deferred. The synchronous `bake()` contract is not proven.

`bake_static_mesh()` only returns `root_mesh`
(`csg_shape.cpp:736-742`). `root_mesh` is filled by `update_shape()`.
`_make_dirty()` queues `update_shape()` with `call_deferred()`
(lines 222 and 231). The class reference says: "make sure to call
`await get_tree().process_frame` before using `bake_static_mesh`".
A call right after the node tree is built returns an empty mesh.

The ADR signature `MeshLib.bake(mesh_def, params) -> Dictionary` is
synchronous and static. Two ways can make it work:

- (a) Call `root._update_shape()` directly before `bake_static_mesh()`.
  `update_shape()` needs only `is_root_shape()`, not `is_inside_tree()`.
  But the `_update_shape` binding is under `#ifndef DISABLE_DEPRECATED`
  (`csg_shape.cpp:1003-1004`). It is a deprecated API.
- (b) Make the bake async. Each caller then awaits it. This changes
  `entity_mesh_3d.gd` `_ready()` and the MultiMesh scan.

**Required change:** the ADR states which way it uses. F1 tests that exact
call sequence out of the tree and in the tree. "Works headless" is
not the risk. The deferred update is the risk.

### B2. The ADR does not say how non-CSG parts merge.

The ADR says "static parts merge into the baked mesh" but names no
API. If the merge puts every part under one `CSGCombiner3D` union,
three things go wrong:

- The 4 `quad` parts (and any `plane`) are non-manifold. CSG cannot use them.
- CSG recalculates normals and smooths faces. Boxes and cylinders shade differently.
- Every mesh pays the CSG CPU cost, not only meshes with cuts.

**Required change:** state that plain parts merge with
`SurfaceTool.append_from(mesh, surface, transform)` per material. Then
`commit()` adds one surface to the `ArrayMesh`. CSG runs only for a
`group` that has a `csg` part or a `lathe`, `extrude` or `sweep` op.
Both APIs are Godot APIs, so ADR 0021 holds.

### B3. Merged meshes break three existing renderer paths.

1. **Shader paint collapses the surfaces.**
   `entity_mesh_3d.gd` `_paint_shader_recursive()` reads
   `material_override`, else surface 0. Then it sets one
   `material_override` for the whole node. On a merged mesh every
   surface gets the surface 0 albedo. Live case: `demo_aldenmere`
   `prop_water_plane` uses `river_3d` (4 colors: bank, shallow, water,
   ripple) with `water_stylized.gdshader`. After the merge all bands
   get one color. The fix: write a `ShaderMaterial` per surface with
   `set_surface_override_material()`.
2. **Emission mutates the shared material.** `mesh_lib.gd:150-157`
   sets `emission` on `mi.material_override` in place. With shared
   material instances, one emissive part lights every mesh that uses
   that material. The material key must include `emission` and
   `emission_energy`. Or emission goes only in the `materials` block.
3. **The material key is not defined.** The ADR says "one surface per
   material". It must define the key for inline parts: color, roughness,
   metallic, emission, emission energy. Per-part `cast_shadow` is
   supported by `build_primitives_into()` today. A part with a different
   `cast_shadow` cannot share a `MeshInstance3D` with other parts. Put it
   in the key, or keep that part separate.

Also list all five callers of the build path (B-table above). Make
`build_primitives_into()` a thin wrapper over `bake()`, so the
viewmodel, editor preview and asset preview do not drift from the
renderer.

### B4. The pivot and facing claims do not agree with the data.

The context says the `y_offset` and `mesh_yaw_offset` bug classes
"cannot occur" for code-built meshes. The data shows otherwise:

- **Base.** A rough AABB check (unrotated parts only, tolerance 0.02)
  finds **33 of 117** meshes with the base off `y = 0`. Some are
  center-pivot by intent (`bolt_3d`, `rocket_3d`, `cloud_3d`, the 3
  viewmodels). Others **float**: `person` +0.10, `merchant_npc_hero_3d`
  +0.20, `merchant_portal_3d` +1.35, `prim_unit_banner` +0.50. The
  ADR's Negative section mentions only "old meshes with a center
  pivot". That understates the work.
- **Facing.** `house_1f` has its door at z = -0.5 (front -Z). But
  `imp_3d` has its eyes at z = +0.18 and `ranger_3d` has its lens at
  z = +0.22 (front +Z). The library already breaks the proposed
  convention.
- **The gate does not check facing.** Context item 5 and the Positive
  section promise a facing check. Section 4's `validate_meshes.py`
  checks only the base. Add a check that can fail. Example: an
  optional `front` marker part, or a required turntable frame at yaw 0
  that the mesh-author skill reads.
- **The `y_offset` family.** Entities already set `y_offset` on library
  meshes to make up for the old bases: `demo_steptest` `prim_unit_box`
  (0.15 and 0.4), and `demo_aldenmere` `grass_tuft_3d`, `log_pile_3d`
  and `mushroom_patch_3d`. If F4 fixes a mesh base, those offsets apply
  twice. Per the reset-field-family rule, `validate_meshes.py` must
  cross-check every entity that sets `y_offset` or `y_offset_mesh` on a
  code-built mesh.

**Required change:** reword the claim to "the convention makes these bug
classes checkable, and the gate checks them". List the 33 meshes in
F4 scope, with fix or exempt for each.

### B5. `pivot_mode: center` looks like a per-def escape hatch.

The user's rule is: fix the derivation or the source data, never add
an override field. A field whose only job is to pass the validator is
that pattern. Two ways stay inside the rule:

- Fix the source data for every floating mesh (`person`, the merchant
  NPCs, `merchant_portal_3d`).
- For meshes that are center-pivot by meaning (projectiles,
  viewmodels, clouds), derive the class from data the engine already
  uses. Example: the meshes that entity defs reference only with no
  ground contact. Or state in the ADR why a declared pivot class is
  semantic data and not an override.

The user must decide this. The ADR must name the choice.

## Non-blocking items

- **Lathe profile.** `CSGPolygon3D.polygon` is a closed polygon. The
  example profile ends at `[0.1, 0.4]`. The closing edge then runs
  diagonally to `[0, 0]` and cuts a cone out of the vase. State that
  `bake()` closes the profile along the axis (adds `[0, y_last]`), or
  that authors must close it. The validator checks `r >= 0` for every
  point and `segments >= 3`.
- **Extrude direction.** `MODE_DEPTH` extrudes along -Z. With the -Z
  front convention, an extruded sign grows away from its front face.
  Document the local frame for each op.
- **Sweep rotation.** Name the `path_rotation` that `sweep` uses. The
  two non-follow modes need Z to decrease along the path.
- **Cache size.** A per-instance `visual.params` change makes a new
  cache entry, and the cache has no limit. Note the bound or the
  eviction rule. `house_1f` sets `$albedo` per instance, so each tint
  is one bake.
- **MultiMesh fixes for free.** Today the MultiMesh path drops
  `emission` and ignores `pivot`. A shared `bake()` fixes both. Add this
  to the Positive section and add a test for it.
- **Manifest and codegen.** The new ops are not in
  `docs/engine-reference/api-manifest.json` (it has no mesh-op section).
  `tools/yume_codegen/entities.py` emits mesh fields. Say whether each
  gets the new ops.
- **Renderer location.** `mesh_lib.gd` lives in `scripts/engine/libs/`
  and already builds `MeshInstance3D` nodes. `engine-scripts.md` says
  engine modules do not import visual nodes. The ADR adds CSG nodes in
  the same file. This is an old exception. Name it, or move `bake()` to
  `renderer_3d/`.

## Tests and demos

There is no code diff, so I did not run `test_main.tscn` or the
scenario tests. Run them on each phase commit.

## Top 3 for the caller

1. B1: `bake_static_mesh()` is empty until a deferred `update_shape()`
   runs. Pick a sync (deprecated `_update_shape()`) or async contract.
   F1 must test that sequence.
2. B3: merged meshes break `visual.shader` on multi-color meshes
   (aldenmere `river_3d` water) and leak emission through shared
   materials. Define the material key and paint per surface.
3. B4 and B5: 33 of 117 meshes are off `y = 0`, some float, and
   `imp_3d` and `ranger_3d` face +Z. The validator has no facing check.
   `pivot_mode` needs a ruling under the no-escape-hatch rule.

## Re-review (revision 2)

_Date: 2026-10-15_
_Input: `docs/adr/0083-code-built-meshes-v2.md` revision 2 (untracked, status proposed). There is still no code diff._

### Verdict

**Accept with conditions.** Revision 2 resolves B1, B2, B3 and B5.
B4 is mostly resolved. The new Godot claims are true at the
`4.6-stable` source. Three conditions remain (C1-C3 below). They are
small ADR text edits and F4 scope items. They do not need another
full review. I did not change the ADR status. The user decides.

Source for this pass: `godotengine/godot` tag `4.6-stable`, files
`modules/csg/csg_shape.cpp`, `modules/csg/doc_classes/CSGShape3D.xml`,
`modules/csg/doc_classes/CSGPolygon3D.xml`,
`scene/resources/surface_tool.{h,cpp}`, `doc/classes/SurfaceTool.xml`,
`doc/classes/MeshInstance3D.xml` and `scene/main/scene_tree.cpp`.

### New claims checked at the source

| Claim | Result | Evidence |
|---|---|---|
| Warm-up bake: build in tree, await one `process_frame`, `bake_static_mesh()`, free | **True.** | `_make_dirty()` queues `update_shape()` with `call_deferred()` (`csg_shape.cpp:222,231`). `SceneTree::process()` flushes the `MessageQueue` after `_process()` in every frame, and again right after it emits `process_frame`. Nodes built in frame N get `update_shape()` in that same frame's flush. The await resumes at the `process_frame` emit of frame N+1, so `root_mesh` is valid. `bake_static_mesh()` returns `root_mesh` (`csg_shape.cpp:736-742`). One frame is enough. |
| Out of tree, the same sequence fails (F1 expects this) | **Probably wrong.** | `call_deferred()` does not need the tree. `update_shape()` needs only `is_root_shape()`. `NOTIFICATION_PARENTED` calls `_make_dirty()` out of the tree too (`csg_shape.cpp:853-866`). Expect the out-of-tree bake to work after one frame. F1 must record the result. It must not expect a failure. The in-tree design still works. |
| `PATH_ROTATION_PATH_FOLLOW` has no "Z must decrease" limit | **True.** | `CSGPolygon3D.xml:77-87`: the note is on `PATH_ROTATION_POLYGON` and `PATH_ROTATION_PATH` only. In the code, `PATH_FOLLOW` takes `up` from `curve->sample_baked_up_vector()`, not a fixed `(0,1,0)`. |
| `MODE_DEPTH` + shift `+depth/2` centers the shape on `pos` | **True.** | The front face is at local z = 0. The end face is at `translate_local(0, 0, -depth)` (`_build_brush`). The shape spans z in [-depth, 0]. A `+depth/2` shift gives [-depth/2, +depth/2]. See N-R2 for where to apply it. |
| `SurfaceTool.append_from(mesh, surface, transform)` in 4.6 | **True.** | `void append_from(const Ref<Mesh> &p_existing, int p_surface, const Transform3D &p_xform)` (`surface_tool.h:242`, bound at `surface_tool.cpp:1383`). See N-R3 for two limits. |
| `MeshInstance3D.set_surface_override_material(surface, material)` | **True.** | `MeshInstance3D.xml:117-125`. It sets the override on the instance, not on the mesh resource. So a per-instance shader does not leak into the cached `ArrayMesh`. |
| `bake_static_mesh()` gives one surface per material | **True.** | "Materials from involved CSG nodes are added as extra mesh surfaces." |

### Blocking items from the first review

| Item | Status | Evidence |
|---|---|---|
| B1. Sync bake not proven | **Resolved.** | Part 2 picks the async path with a warm-up (`MeshLib.warm() -> Signal`). It rejects `_update_shape()` (Alternative C). The source shows that the sequence works (table above). F1 tests it. |
| B2. Merge API not named | **Resolved.** | Part 1 names `SurfaceTool.append_from(mesh, 0, part_transform)`, one `SurfaceTool` per material key. CSG runs only for a `csg` group or a `lathe` / `extrude` / `sweep` part. A `quad` or `plane` in a CSG group is a validator error. |
| B3. Merge breaks three renderer paths | **Resolved.** | (1) Shader paint: one `ShaderMaterial` per surface with `set_surface_override_material()`, `river_3d` named as the live case. (2) Emission is in the material key. (3) The key is color, roughness, metallic, emission, emission energy. `cast_shadow` splits the result into at most two `ArrayMesh` values. All 5 callers are listed. `build_primitives_into()` becomes a wrapper over `bake()`. I found the 5 call sites in the tree. |
| B4. Pivot and facing claims | **Mostly resolved.** | The claim now says "a gate can check them" (Context, first paragraph). Context item 5 states the 33 meshes and the 2 facings. Facing is a visual gate (turntable yaw 0 frame, checked by `yume-mesh-author`). The validator errors on `y_offset`, `y_offset_mesh` and `mesh_yaw_offset` on code-built meshes. **Open:** the ADR does not list the 33 meshes with a fix method for each. The fix is not always a shift. See C1. |
| B5. `pivot_mode` escape hatch | **Resolved.** | The ADR names the choice: every mesh gets a data fix, with no exemption field. Alternative D rejects `pivot_mode`. This agrees with the no-escape-hatch rule. C1 lists the consequences that the data fix must handle. |

### Non-blocking items from the first review

| Item | Status | Evidence |
|---|---|---|
| Lathe profile closure | **Resolved.** | The bake adds `[0, y_last]` and `[0, y_first]`. The validator checks `r >= 0` and `segments >= 3`. Small gap: add a closing point only when the end point has `r != 0`. A duplicate point on the axis gives a zero-length edge. |
| Extrude direction | **Resolved.** | The op table has a "Local frame" column. See N-R2. |
| Sweep rotation | **Resolved.** | `PATH_ROTATION_PATH_FOLLOW`. See N-R1. |
| Cache size | **Resolved.** | 512 entries, LRU. |
| MultiMesh fixes for free | **Resolved.** | In the Positive section. "Each test also runs the MultiMesh path." |
| Manifest and codegen | **Resolved.** | Part 5: codegen emits only mesh names. The op list lives in `validate_meshes.py` and the skill. |
| Renderer location | **Resolved.** | F2 moves `mesh_lib.gd` to `scripts/renderer_3d/`. Note: `class_name MeshLib` moves, so F2 must run `--import` before the tests. |

### Conditions

**C1. F4 needs a per-mesh table, and a shift is not always the fix.**
I re-ran the AABB check. It gives the same 33 meshes. Three groups
break if F4 only shifts the parts up:

- `floor_grate` (`demo_doomarena3d` arena floor) is a 1 m slab with
  its top at y = -0.05. The top face is the walk surface. A shift puts
  the floor top at y = 1.0, above every entity. The fix is a thin slab
  (for example 0.01 m), not a shift.
- `viewmodel_plasma`, `viewmodel_shotgun` and `viewmodel_rocket` are
  placed by `demo_doomarena3d/scene.json` `hud.viewmodel.offset`. That
  is one offset for all three meshes. Their base shifts differ (0.225,
  0.29, 0.25). One offset cannot make up for three shifts. A shift
  also moves the grip point. F4 must say how the grip stays at the
  same screen position.
- `bolt_3d`, `enemy_bolt_3d`, `pellet_3d`, `rocket_3d` and `spark_3d`
  use `@lib.physics.bodies.character_projectile`. The collider sits at
  the entity origin. A shift puts the mesh 0.16-0.34 m above its
  collider. F4 must also set `collision_shape.offset` or the spawn
  height.

The pivot-dependent field family is wider than `y_offset` /
`y_offset_mesh`. It also holds `physics.collision_shape.offset`, the
`hud.viewmodel.offset` in `scene.json`, and spawn positions in rules.
Per the reset-field-family rule, F4 resets the whole family for each
mesh. **Required change:** add a table of the 33 meshes to F4.
For each mesh, give the fix (shift, reshape, or shift plus collider or viewmodel change)
and the sites that place it.

**C2. The validator's `y_offset` rule also catches offsets that do
not make up for a base.** On disk today it errors on 6 entities.
Two are not base compensation:

- `demo_aldenmere` `water_tile` sets `y_offset: -0.02` on
  `water_plane_3d`. That mesh already has its base at y = 0. The
  offset is a z-fight bias.
- `demo_steptest` `test_step` sets `y_offset: 0.15` on `prim_unit_box`,
  which already has its base at y = 0. The offset lifts the visual
  0.15 m above the ground, maybe to align with a centered collider.

The rule is consistent with the no-escape-hatch rule: the fix goes into
the mesh data or into `position.y`. But the validator message must say
that. A message that says only "a code-built mesh needs no offset"
does not tell the author where the height goes. **Required change:**
the message names the two legal places (mesh data, or a Vector3
`position`) and the collider offset to check.

**C3. Two implementation facts go into the op table.**

- **N-R1, sweep:** set `path_local = true`. With the default `false`,
  `_build_brush` uses `path->get_global_transform()` when the path is
  in the tree (`csg_shape.cpp:2276-2277`) and does not invert it. The
  warm-up builds the tree under a hidden node in the scene tree. So the
  position of that node goes into the baked geometry.
- **N-R2, extrude:** the transform of the CSG **root** node is not in
  `bake_static_mesh()`. The root mesh is in the root's local space.
  If the `CSGPolygon3D` is the root, a `+depth/2` set on its `position`
  does nothing. Apply the shift in the `append_from` transform, in the
  part's local frame **before** `rotation_deg`. Otherwise a rotated
  extrude is off-center.

### Other notes (non-blocking)

- **N-R3, `append_from` limits.** It does not copy the source material.
  Call `SurfaceTool.set_material()` for each key before `commit()`. It
  transforms normals with `p_xform.basis.xform()`, not the inverse
  transpose (`surface_tool.cpp:1043-1046`). This works for the
  rotation-only part transforms in the data today (no part has a
  `scale` field). A future per-part non-uniform scale would skew the
  normals.
- **N-R4, pop-in after a level change (Invariant #11).** `warm()` runs
  at WorldBoot. A `transition_level` to a level with new CSG meshes
  uses the lazy path, so CSG surfaces appear one frame late. Either
  `warm()` runs on the level swap, or the ADR states this as accepted.
  The lazy path must also rebuild a MultiMesh that was built before
  its CSG surfaces arrived.
- **N-R5, warm callers outside WorldBoot.** WorldBoot warms "every mesh
  that the level's entity defs reference". The viewmodel meshes come
  from `scene.json`, not entity defs. `asset_preview.gd --turntable`
  and `yume_scene_preview.gd` do not run through WorldBoot. Each must
  call and await `warm()` itself.
- **N-R6, MultiMesh and separate parts.** Parts with `name` or `pivot`
  stay separate nodes. The ADR does not say how the MultiMesh path
  draws them. One MultiMesh per separate part is enough.

### Invariant checks

No change from the first review. Revision 2 adds no effect, trigger,
query operator or pending pipeline. `warm()` is a boot step, not a
pending pipeline, so Invariant #10 does not apply. I did not rerun the
invariant greps or the tests, because there is no code diff. Run them
on each phase commit.

### Top 3 for the caller

1. All new Godot claims hold at the `4.6-stable` source. The warm-up
   bake works with one frame. B1, B2, B3 and B5 are resolved.
2. C1: a shift alone breaks `floor_grate` (floor top goes to 1.0 m), the
   3 viewmodels (one shared offset) and 5 projectiles (mesh above the
   collider). F4 needs a per-mesh fix table.
3. C3: set `path_local = true` on sweeps, and apply the extrude shift
   in the `append_from` transform. A root CSG node's own transform is
   not in the baked mesh.
