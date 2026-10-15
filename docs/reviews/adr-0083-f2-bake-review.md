# Code review — ADR 0083 F2, MeshLib.bake()

_Date: 2026-10-15_
_Reviewer: yume-code-reviewer_
_Subject: f8a4f06 (`perf(render): bake code-built meshes once, merged by material`)_

## Verdict

`accept-with-conditions`

## What the change does (1-2 sentences)

The commit merges the static parts of each code-built mesh into at most
two cached `ArrayMesh` values, with one surface for each material key.
All 5 build paths and the MultiMesh director now use this bake. The diff
stays in the F2 scope of the ADR. The extra items (`rotation_deg` with
`$param`, emission in MultiMesh) come with the shared path.

## Questions

### Q1 — Why does the bake cache key not include `named_materials`?

> `key = hash(primitives) | hash(params) | flags`. A part with
> `"material": "iron"` resolves through the static `named_materials`.

If the `materials` block changes and the primitives do not, `bake()`
returns the old mesh with the old material. The doc comment on
`clear_caches()` says the opposite: "A meshes.json reload does not need
it: the key hashes the primitives themselves." That claim is false for a
change in the `materials` block only.

Today no `meshes.json` has a `materials` block, so no player sees this.
F4 and F5 add the first users, and `yume-mesh-author` will edit
materials in a loop. That is the first consumer to hit it.

Two fixes are possible:
- Add `hash(named_materials)` to the key (one line).
- Or call `clear_caches()` in `load_from_file()` when the block changes.

Either fix also makes the doc comment true. Add a test: bake, change
`named_materials["iron"].metallic`, bake again, expect a different
result.

**Author's answer needed before:** merge

### Q2 — What stops the next author from mutating a shared material?

> "Callers must not change the returned meshes or their materials.
> Duplicate first."

Before F2, each part had its own new `StandardMaterial3D`. Code that
changed `mi.material_override` changed one part of one entity. After F2,
the same write changes every entity with that material key in the whole
scene. The `ArrayMesh` surfaces are shared too, so a
`mesh.surface_set_material()` call has the same effect.

I checked every current writer. `_paint_albedo_texture_recursive`,
`_apply_material_overrides`, `asset_preview` and the new shader paint
all duplicate or use surface overrides. So the code has no fault today.
But the only gate is a doc comment, and the bug class is new. A future
hit flash, a `tint` effect or a fade can write in place. (`tint` is
already in `MUTATION_FIELDS`.) The result: "one goblin flashes, all
goblins flash".

What enforces "duplicate first"? Suggested gates, in cost order:
- A test: build two hosts from the same primitives. Run the albedo paint
  and the shader paint on host A. Then expect no change in the cached
  `material_for()` and in host B's surface materials.
- One line in `.claude/rules/engine-scripts.md`: MeshLib materials and
  baked meshes are shared, so write through `set_surface_override_material`
  or a `duplicate()`. Cite this commit.
- Optional: a grep check in the validator suite for `.albedo_color =`
  or `.emission =` on `get_active_material(`/`surface_get_material(`
  results in `scripts/renderer_3d/`.

**Author's answer needed before:** merge

### Q3 — Why does an unknown material name fall back to white with no message?

> `f = named_materials.get(str(mname), {}).duplicate()`

`"material": "irn"` gives a white part and no warning. The ADR puts the
name check in `validate_meshes.py`, which is F4. Until F4 ships, the
`materials` block is live schema with no gate. A `push_warning` (or
`EngineError.raise` at warning level, as `load_from_file` does) costs
one line and closes the gap now.

**Author's answer needed before:** merge (or a TODO that names F4)

### Q4 — Is a silent 32-bit hash collision acceptable?

The key uses `hash()` of the primitive array and of the params. Two
different inputs with the same hash return the wrong mesh, with no
error. At 512 entries the chance per run is small (about 3e-5). But the
symptom is an entity with the geometry of a different mesh, and nobody
will think of a cache when they debug it. Options: store the inputs in
the entry and compare on a hit, or document the risk in the ADR. Which
one do you choose?

**Author's answer needed before:** accept (a choice, not a fix)

### Q5 — Why does the ADR say one key and the code use another?

ADR § 1 says the key is "the mesh name and a hash of the resolved
params". The code hashes the primitives, not the name. The code choice
is better, because two mesh names with the same parts share an entry.
Update the ADR text, so that F3 does not "fix" the code back.

**Author's answer needed before:** merge

## Smells

- `godot/scripts/engine/tests/test_runner.gd:1457` — the test is named
  "least-recently-used entries go first", but it only checks the size
  cap. A FIFO cache passes it. Add: bake A, fill to the cap, bake A
  again (touch), add one more, expect A still cached and the oldest
  untouched entry gone.
- `godot/scripts/engine/tests/test_runner.gd:1479` — `MultiMeshDirector`
  extends `Node`, and the test never frees `dir`. This leaks one Node per
  run (the older `test_multimesh_director` has the same leak).
- `godot/scripts/renderer_3d/mesh_lib.gd` — `bake()` returns `"aabb"`,
  but no caller reads it. Keep it only if F3/`warm()` needs it, and say so.
- `godot/scripts/renderer_3d/mesh_lib.gd:59` — `named_materials` is a
  static set by the instance loader, last load wins. All 4 loaders read
  `res://data/meshes.json` today, so this is latent. A per-game
  `meshes.json` would break it. Why not keep the materials on the
  `MeshLib` instance, next to `meshes`?
- `godot/scripts/engine/directors/multimesh_director.gd:10` — a doc line
  runs past 100 columns after the edit.
- `godot/scripts/renderer_3d/entity_mesh_3d.gd` — 1011 LoC, above the
  ~800 line. This commit removes lines, so it is not the cause. Note it
  for a later split.

## Gate posture

| Change | Gate updated? | Suggestion |
|---|---|---|
| Merge by material key | yes | Test: 5 parts → 4 surfaces, emission own key |
| Shared materials and meshes | no | Q2: mutation-isolation test + engine-scripts.md line |
| `materials` block (new schema) | no | Q3: runtime warning now, `validate_meshes.py` in F4 |
| Bake cache + LRU | partial | Q1 stale-key test, LRU recency test |
| MultiMesh R * S order | yes | `_instance_transform` test with non-uniform scale and yaw |
| MultiMesh emission | yes | Test checks a glowing surface |
| Per-surface shader paint | yes | Test checks two bands keep two colors |
| `mesh_lib.gd` move | yes | No stale references to the old path in code or docs |
| Visual gate | yes | ADR F2 results: same template, pixel diff 0.1 and 1.6 of 255. Was a `shader_path` mesh such as `river_3d` in frame? The ADR names it as the live case. |

## Conditions for accept

- [ ] Q1: put `named_materials` in the cache key (or clear on load), fix
      the `clear_caches()` comment, add the stale-materials test.
- [ ] Q2: add the mutation-isolation test and the `engine-scripts.md`
      line about shared materials.
- [ ] Q3: warn on an unknown material name.
- [ ] Q5: align the ADR § 1 key text with the code.
- [ ] Make the LRU test check recency, not only the size cap.

## What this did NOT cover

- Godot API behavior of `SurfaceTool.append_from` with mixed primitive
  formats. The tests and the visual gate cover it in practice.
- The pre-existing MultiMesh gaps (`y_offset`, `albedo_texture`,
  `shader_path` on eligible entities). This commit does not change them.
- The F3-F5 scope (CSG, `warm()`, validator, turntable).
- I did not run the tests. The results come from the commit message and
  the ADR.
