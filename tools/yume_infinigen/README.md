# yume_infinigen — Infinigen → Yume asset backend (ADR 0074)

Generates procedural 3D assets with [Infinigen](https://github.com/princeton-vl/infinigen)
(Princeton's Blender pipeline), decimates them to a real-time budget,
bakes PBR maps, and emits Yume entity defs + `.glb`. An **optional**
World/Assets-layer content source — like the Tripo asset-gen backend,
never required; output is plain `.glb` + JSON the rest of Yume already
consumes (`visual.mesh`, ADR 0046).

## What it is NOT

Infinigen is **not a renderer Yume gains**. Infinigen images come from
Blender Cycles (offline path-tracing, millions of polys); Yume renders
real-time on an iGPU. This tool imports Infinigen's *geometry + baked
textures* (heavily decimated) — the result is **good game art lit by
Yume's own renderer**, not an Infinigen render. Photorealism is out of
scope here; that's a Godot renderer-tier conversation (`gl_compatibility`
→ `forward_plus`), separate and deferred.

## Setup (heavy, external — one time)

Infinigen needs its own **Python 3.11 + `bpy`** environment, NOT Yume's
venv. With `uv`:

```bash
uv python install 3.11
uv venv ~/infinigen311 --python 3.11
uv pip install --python ~/infinigen311/bin/python bpy==4.2.0
cd /path/to/infinigen
git submodule update --init infinigen/infinigen_gpl infinigen/OcMesher
INFINIGEN_MINIMAL_INSTALL=True uv pip install --python ~/infinigen311/bin/python -e .
```

Then point Yume at it (shell profile):

```bash
export YUME_INFINIGEN_PYTHON="$HOME/infinigen311/bin/python"
export YUME_INFINIGEN_REPO="/path/to/infinigen"
```

Unset → the tool no-ops with a helpful message (graceful, never crashes).

## Usage

```bash
# one species
python -m tools.yume_infinigen demo_foo --factory BoulderFactory

# a batch of distinct species (one entity def per seed)
python -m tools.yume_infinigen demo_foo --factory BoulderFactory \
    --seeds 0,1,2,3 --faces 2500 --texres 512

python -m tools.yume_infinigen demo_foo --factory TreeFactory \
    --seeds 5,6 --faces 10000 --collider base
```

Writes `data/<game>/assets/infinigen/<slug>.glb` + a def into
`data/<game>/entities/infinigen_assets.json` (engine globs it). Placement
is Yume's job — scatter the defs with patterns. The defs carry a derived
collider (ADR 0072: `base` trunk-footprint for top-heavy props, `full`
for solids) and a natural-size `state.scale` from the asset's baked
height.

### Real object factories

The bulk of Infinigen's CLI registry is *materials/scatters*; the real
nature **object** generators are direct-imported by name:

| `--factory` | what |
|---|---|
| `BoulderFactory` | chunky rock (solid → `full` collider) |
| `TreeFactory` / `BushFactory` | foliage (realized; `base` collider; budget ~10K faces) |
| `CactusFactory` | cactus |
| `MushroomFactory` | mushroom |

## Pieces

- `gen_asset.py` — runs INSIDE the infinigen env. One Blender session:
  generate → join → decimate (before bake, the OOM fix) → bake PBR →
  GLB + metadata sidecar. `os._exit(0)` dodges bpy's harmless
  shutdown segfault.
- `__main__.py` — runs in Yume's python. Shells out per seed, copies
  glb, emits entity defs.
- `config.py` — env resolution + per-factory collider default.

## Knobs + caveats

- **`--faces`** is the real-time budget (rock 2-4K, tree 6-12K).
  Decimation is lossy; the baked **normal map** carries the surviving
  surface detail. **`--texres`** 256/512 for the iGPU.
- **Foliage (trees/bushes/palms) → impostor billboards (2026-06-20).**
  Infinigen leaves are ~14K faces EACH (film density, ~15M faces/tree)
  and SHATTER under decimation. So foliage factories take a different
  path: `realize=False` keeps leaves as cheap instances; the generator
  picks the GREENEST leaf cluster (measured by a tiny render — material
  names don't separate leaf vs bark), bakes it to one alpha **impostor
  card**, and places a light crossed-quad billboard at each cluster
  transform. Result: a ~8K-face, ~0.4 MB leafy tree the existing Yume
  mesh pipeline loads with no engine change. The impostor render uses
  Eevee under `LIBGL_ALWAYS_SOFTWARE=1` (the driver sets this) for a
  reliable headless software-GL path. Tune `--lod-dist` (default 12)
  for leaf density. Trunk gets a `base` collider automatically.
- Empirical baseline (2026-06-19): a `BoulderFactory` came in at 916K
  faces → 5K → 801 KB GLB, rendered in Yume on an Intel UHD 630 with
  baked albedo + normal + shadows at full frame rate.

## Phase C — terrain (IMPLEMENTED, ADR 0074)

```bash
python -m tools.yume_infinigen demo_foo --terrain --scene-type mountain
#   → a native-scale Infinigen ground glb + a normalize:false + trimesh
#     entity def in entities/infinigen_terrain.json
```

Generates a coarse Infinigen terrain (~1.4 GB peak — NOT the 16 GB that
full foliage scenes need), bakes its surfaces, and emits a ground the
renderer loads at native world scale (`visual.normalize: false`, ADR
0062) with a 1:1 trimesh collider. `--scene-type`: mountain / canyon /
coast / desert / etc. Then clear `scene.json` `ground.mesh` so the
terrain IS the ground. PLANAR decimate only (COLLAPSE flattens relief).

### One-time terrain build (the minimal install skips it)

```bash
cd /path/to/infinigen
make terrain                                   # g++ SDF kernels → terrain/lib/cpu/*.so
# soil_machine needs glm (header-only, no sudo):
git clone --depth1 https://github.com/g-truc/glm ~/glm
g++ -O3 -c -fpic -fopenmp -I~/glm -Iinfinigen/terrain/source/cpu/soil_machine \
    -o infinigen/terrain/lib/cpu/soil_machine/SoilMachine.o \
    infinigen/terrain/source/cpu/soil_machine/SoilMachine.cpp
g++ -shared -fopenmp -o infinigen/terrain/lib/cpu/soil_machine/SoilMachine.so \
    infinigen/terrain/lib/cpu/soil_machine/SoilMachine.o
# marching_cubes ext (must be importable AS infinigen.terrain.marching_cubes):
cp infinigen/terrain/marching_cubes/_marching_cubes_lewiner_cy.pyx infinigen/terrain/marching_cubes.pyx
CFLAGS="-I$(python -c 'import numpy;print(numpy.get_include())')" cythonize -3 -i infinigen/terrain/marching_cubes.pyx
rm infinigen/terrain/marching_cubes.pyx infinigen/terrain/marching_cubes.c
uv pip install --python $YUME_INFINIGEN_PYTHON landlab     # snowfall sim
```

(Caves are auto-patched at runtime — they use an addon-only bpy op
absent in headless bpy-module.)

`--terrain` ALSO extracts Infinigen's **ecological scatter** (C2): it places
the game's existing Phase-B asset defs (trees→foliage, rocks→boulders) at
Infinigen's density/slope-aware positions — positions-only (~1.4 GB, no
foliage realize). So one `--terrain` command yields a **complete populated
World layer**: terrain + scattered assets. Generate the Phase-B assets
first (rocks, a tree) so the scatter has defs to place.

Lighting (C3) is intentionally NOT generated — Yume's own renderer
(`scene.json` lighting) already lights the World layer correctly; the
asset/terrain are the content, lighting is the engine's job (ADR 0021).
