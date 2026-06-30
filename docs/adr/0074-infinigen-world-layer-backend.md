# ADR 0074 — Infinigen as a World-layer / asset-library backend

_Date: 2026-06-19_
_Status: accepted (Phase B implemented + validated 2026-06-20; Phase C deferred)_

## Context

Yume's content ceiling is bounded by its asset sources: code-draw
primitives (free, simple) and the Tripo/openai assetgen pipeline
(single AI-gen meshes). Neither produces the *organic complexity* or
*at-volume variety* of a dedicated procedural generator.

[Infinigen](https://github.com/princeton-vl/infinigen) (Princeton) is a
Blender-based procedural generator: trees, rocks, creatures, plants,
terrain, materials — all from a seed, with baked PBR maps. It targets
photoreal ML-training datasets, but its *geometry + baked textures* are
exactly the shape Yume already consumes (`visual.mesh` .glb +
`albedo_texture`/`normal_texture` per ADR 0046).

**Feasibility proven (2026-06-19, this session):**
- A ChunkyRock generated → baked PBR (diffuse/normal/roughness, 1024²)
  → exported OBJ at **1.31M triangles** → Blender-decimated 99.8% to
  **3K faces** → 1.7 MB GLB → **loaded and rendered in Yume on the
  Intel UHD 630** at full frame rate, with the baked albedo + normal
  map + real shadows. Zero engine changes (existing .glb path handled
  it).
- A TreeFactory (custom script, `realize=True`) generated + baked
  successfully, but the realized foliage (tens of millions of polys)
  **OOM-killed the process at export**. Lesson: decimate IN-SESSION
  before export; never round-trip the raw realized mesh.

The architectural fit is the **three-layer model (ADR 0067)**:
Infinigen becomes an alternative **World-layer backend**, a sibling to
`compose_world`. The Game layer (rules, player) and Yume's live-entity
model stay Yume's. Per **ADR 0021** Infinigen is EXPOSED as an external
content tool, not reimplemented — the same posture as Tripo/assetgen.

## Decision

A new offline tool `tools/yume_infinigen/`, invoked through an external
Python-3.11 + `bpy` Infinigen environment (heavy authoring dependency,
NOT in Yume's venv or runtime). Two phases:

### Phase B — asset library (build first)

`generate factory asset → decimate IN BLENDER → bake textures (capped
res) → GLB → emit Yume entity def`. One Blender session per asset (the
OOM lesson):

Any factory is resolved **dynamically** (grep source for `class <name>`,
import only that module; the `AssetFactory`-subclass check also rejects
internal part factories) — all ~300 factories work, no hand-maintained
map. A Yume-side catalog (`--list-factories`) + fuzzy typo rejection runs
*before* the slow Blender launch. Multiple seeds run in **one** Blender
session (amortizes gin-init + resolve).

Two asset classes take two paths:

**Solid path** (rocks, cacti, corals, ferns, shells, fruit, …):
1. `apply_gin_configs` + `configure_blender`; spawn `realize=True`.
2. **join → reduce to a face budget**: collapse-decimate for single-
   surface assets; if collapse can't reach budget (multi-island spiky
   meshes), **voxel-remesh** into one watertight surface then collapse.
3. validate/clean (merge-doubles, recalc normals); bake PBR at capped
   res (256/512) and export GLB with textures embedded.

**Foliage path** (trees, bushes, palms) — Infinigen leaves are ~14K
faces EACH (~15M faces/tree) and **shatter under decimation**, so the
solid path can't make a real-time leafy tree. Instead (empirical
2026-06-20): spawn `realize=False` (leaves stay cheap instances — avoids
the multi-GB realize that OOM'd a 7 GB box); pick the **greenest** leaf
cluster (measured by a tiny render — material names don't separate leaf
vs bark); bake it to **one alpha impostor card**; place a light crossed-
quad **billboard** at each cluster transform. A ~8K-face / ~0.4 MB leafy
tree that loads as a plain alpha-clipped glb — **no engine change**, the
standard game-foliage impostor technique. (Eevee impostor render under
`LIBGL_ALWAYS_SOFTWARE=1` for reliable headless software-GL.)

4. emit/patch a Yume entity def: `visual.mesh` → the glb; collider per
   ADR 0072 (`base` trunk-footprint for trees/upright plants, `full`
   for solids); natural `state.scale` from the baked height. A JSON
   sidecar carries bbox/height/`foliage` flag.

**Owns** (writes only these): `data/<game>/assets/infinigen/*.glb`,
`entities/<slug>.json` defs. Placement uses Yume's existing
scatter/patterns.

### Per-factory support matrix (validated 2026-06-20)

| Class | Status |
|---|---|
| rocks (boulder, pile, blender-rock) | ✅ solid |
| cacti, ferns, succulents, small-plants | ✅ solid |
| corals, mollusks, fruit, shells | ✅ solid |
| **trees / bushes / palms** | ✅ **foliage billboards** |
| creatures (frog/bird/fish/…) | ❌ upstream Infinigen bug (`CreatureGenome.postprocess_func`, v1.19.1) — document, don't patch |

### Phase C — scene layout (extends B)

**C1 — terrain (IMPLEMENTED 2026-06-20).** `--terrain --scene-type
<mountain|canyon|coast|…>` generates a coarse Infinigen terrain (Ground +
LandTiles + WarpedRocks + VoronoiRocks), bakes its procedural surfaces,
and exports a glb the renderer loads as a **native-scale ground**
(`visual.normalize: false`, ADR 0062) with a **trimesh collider** matching
1:1. `gen_terrain.py`.

**Walkability verified** (live capture, 2026-06-20): a character body
dropped from 30 m onto the terrain centre falls and **rests on the visible
surface** (does not pass through), confirming the trimesh collider aligns
1:1 with the rendered mesh under `normalize:false`. Note: scenario tests
can't cover this — the headless runner disables `_physics_process` (no
move_and_slide), so collision must be checked with a live `--capture`.

Two findings corrected the earlier "Phase C needs 16 GB, hardware-blocked"
conclusion — it was **wrong**:
- The 16 GB minimum is for FULL foliage scenes; **coarse terrain alone
  peaks at ~1.4 GB** (fits 7 GB easily).
- The real blocker was the **minimal install skipping the build**. Terrain
  needs (one-time, see README): `make terrain` (g++ SDF kernels) + **glm**
  headers → `SoilMachine.so` + the **marching_cubes** Cython ext (built as
  module `infinigen.terrain.marching_cubes`) + `pip install landlab`, plus
  a bpy-module **cave patch** (caves use an addon-only operator absent
  headless). PLANAR decimate only — COLLAPSE pancakes the relief.

**C2 — scatter placements (IMPLEMENTED 2026-06-20).** `--terrain` also
extracts Infinigen's **ecological** scatter positions
(`density.placement_mask` for surface/slope selection + `placeholder_locs`
POISSON sampling) — **positions-only, ~1.4 GB, no foliage realize** (the
16 GB risk avoided). The driver maps Blender (x,y,z up) → Yume (x, z, −y up)
and places the **Phase-B asset library** at those points (trees→foliage,
rocks→boulders, cycled for variety, varied yaw). One command →
terrain + scattered assets = a complete populated World layer.

**C3 — lighting (RESOLVED, not built).** Per ADR 0021 (expose, don't
reimplement): **Yume's own renderer already lights the terrain + assets
correctly** (`scene.json` lighting, ADR 0025/0071 — verified in capture).
Re-deriving Infinigen's exact sun angle/sky would be a marginal feature
that duplicates what Yume does well; the World layer just needs to be lit,
and it is. Skipped deliberately.

### Environment contract

`YUME_INFINIGEN_PYTHON` (the 3.11 venv's python) + `YUME_INFINIGEN_REPO`
(infinigen source). Absent → the tool no-ops with a warning and the
pipeline degrades to existing backends — exactly the `--scene` /
`--with-assets` key-missing pattern (ADR 0067 Phase 0).

## Consequences

- Infinigen's variety + baked detail become Yume content — a real
  step up for organic assets and "generate N species in one command."
- **NOT a renderer, by construction.** Yume re-lights everything with
  its own real-time rasterizer; the imported look is *good game art*,
  not an Infinigen Cycles render. Photoreal parity is an explicit
  NON-goal here — that is a Godot renderer-tier conversation
  (`gl_compatibility` → `forward_plus`: SDFGI/SSR/volumetrics) + shader
  work, deferred to a future ADR and gated on capable hardware.
- **Decimation is mandatory and lossy.** 99%+ reduction throws away
  Infinigen's geometry; what survives is the baked **normal map** on a
  low-poly proxy (the standard high-to-low bake technique). Tune the
  face budget + texture res per asset class.
- Heavy offline dependency (separate env, Blender, two git submodules
  `infinigen_gpl` + `OcMesher`). An authoring tool, like Tripo — never
  a runtime or test dependency.
- World-layer ownership (ADR 0067) keeps it from clobbering the Game
  layer; output is plain glb + JSON (data-drives-everything intact).

## Alternatives considered

- **Baked whole-scene diorama** (one giant .glb backdrop): rejected —
  dead scenery, no per-object liveness/collision, still too heavy.
- **Reimplement Infinigen's generators in GDScript**: rejected per ADR
  0021 (expose, don't reimplement) — and it's infeasible (they're deep
  Blender geometry-node pipelines).
- **Use Infinigen's Cycles renderer for Yume**: rejected — it's
  offline path-tracing (seconds/frame), a different computational
  regime from real-time. This is the category mismatch the design is
  careful to avoid: Infinigen feeds the *stage*, Godot does the
  *rendering*.
