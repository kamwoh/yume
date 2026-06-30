---
name: yume-infinigen-scene
description: Generate a realistic 3D World layer for a Yume game using the Infinigen procedural backend (ADR 0074). Produces a walkable native-scale terrain (mountain/canyon/coast/desert/...) plus an ecologically-scattered asset library (rocks, plants, leafy trees) — all real Infinigen geometry baked to glb, no engine change. Invoke when the user wants a realistic procedural natural environment (terrain + foliage + rocks) as the World layer a game is built onto, as opposed to yume-create-scene (the openai/Tripo hero-image pipeline) or yume-map-author (2D semantic-map level authoring). Requires the external Infinigen env (YUME_INFINIGEN_PYTHON / YUME_INFINIGEN_REPO); degrades to a clear error if absent.
---

# /yume-infinigen-scene

You orchestrate Yume's **Infinigen World-layer pipeline** (ADR 0074). From a
target game folder + a scene type, you produce a runnable, **walkable**
realistic natural world: a native-scale terrain ground with ecological
scatter (trees, rocks) drawn from a generated asset library. Everything is
real Infinigen geometry baked to `.glb`; the engine renders it through
existing primitives (`visual.normalize:false` + trimesh collider, ADR 0062).

The tool (`tools/yume_infinigen/`) does the heavy lifting; you drive it,
integrate the output, and run the visual + walkability gates.

## When to invoke

- ✅ "Generate a realistic mountain/canyon/desert scene for `<game>`."
- ✅ "Make an Infinigen world to build my game onto."
- ✅ "Scatter real trees and rocks on procedural terrain."
- ❌ HUD/screen authoring → `yume-hud-author` / `yume-screen-author`.
- ❌ A single asset (one rock) → `python -m tools.yume_infinigen <game> --factory <X>` directly.
- ❌ A stylized hero-image-driven scene → `yume-create-scene` (openai/Tripo).
- ❌ A 2D semantic-map level → `yume-map-author`.

## Prerequisites (check FIRST, fail loud)

The backend is an EXTERNAL heavy dependency (its own py3.11 + `bpy`), like
Tripo. Two env vars must point at it; absent → STOP and tell the user:

```bash
export YUME_INFINIGEN_PYTHON=$HOME/infinigen311/bin/python   # 3.11 + bpy
export YUME_INFINIGEN_REPO=/path/to/infinigen                # the source repo
```

**Terrain also needs a one-time build the minimal install skips** (SDF
kernels, glm→SoilMachine, marching_cubes ext, landlab). If `--terrain`
fails with a missing `.so` / `LutProvider` / `landlab`, run the build steps
in `tools/yume_infinigen/README.md` § "One-time terrain build". Caves are
auto-patched at runtime.

## The pipeline (4 steps)

```
1. ASSETS   python -m tools.yume_infinigen <game> --factory <F> --seeds 0,1,2
2. TERRAIN  python -m tools.yume_infinigen <game> --terrain --scene-type <T>
            (also extracts ecological scatter → places step-1 assets)
3. INTEGRATE  clear scene.json ground.mesh so the terrain IS the ground
4. VERIFY     live --capture (visual gate) + a drop-a-body walkability check
```

### Step 1 — asset library (the things that get scattered)

Generate the props the scatter will place. Scatter maps **roles → defs**:
`tree` → any def whose id contains tree/bush/fern/cactus; `rock` → boulder/
rock/coral. Generate at least one of each role so the scatter isn't empty.

```bash
python -m tools.yume_infinigen <game> --factory BoulderFactory --seeds 0,1,2
python -m tools.yume_infinigen <game> --factory TreeFactory --seeds 0      # leafy billboard
python -m tools.yume_infinigen <game> --factory FernFactory --seeds 0
```

- `--list-factories` prints the full catalog (any of ~300 Infinigen factories).
- **Foliage** (Tree/Bush/Palm) auto-takes the impostor-billboard path
  (cheap leaves; defaults to vivid-green **summer** + base leaf emission so
  vertical billboards aren't dark). Solids decimate+bake.
- Each `--factory` run MERGES into `entities/infinigen_assets.json` (defs
  accumulate; safe to call repeatedly).
- Creatures (Frog/Bird/...) are ❌ (upstream Infinigen bug, v1.19.1).

### Step 2 — terrain + scatter (the World)

```bash
python -m tools.yume_infinigen <game> --terrain --scene-type mountain
```

- Generates a coarse Infinigen terrain (~1.4 GB peak — NOT the 16 GB full
  foliage scenes need), bakes its surfaces, exports a native-scale glb.
- Extracts Infinigen's **ecological** scatter (density + slope), positions-
  only (no foliage realize), and emits `entities/infinigen_terrain.json`:
  the terrain def (`normalize:false` + trimesh collider) + one instance per
  scatter point referencing your step-1 assets (cycled for variety, varied yaw).
- `--scene-type`: mountain / canyon / coast / desert / cliff / ... ·
  `--texres` (default 512; 1024 is ~4× slower) · `--tree-density` /
  `--rock-density`.

### Step 3 — integrate

Clear the game's flat ground so the terrain IS the ground:

```python
# scene.json: set "ground" to {} (the terrain entity is the floor now)
```

The engine globs `entities/*.json`, so `infinigen_terrain.json` +
`infinigen_assets.json` load automatically. For a `top_down_3d`/walkable
game the player just needs to spawn ABOVE the terrain surface (sample the
terrain height at spawn x,z, or start high and let gravity settle it).

### Step 4 — verify (MANDATORY gates)

Per `.claude/rules/visual-qa.md` — the World is rendering content:

1. **Visual** — live `--capture` an oblique vista; confirm relief, scattered
   assets on the surface (not floating/buried), foliage reads green at
   distance, no pink/magenta fallback.
2. **Walkability** — a character body dropped above the terrain must rest ON
   the surface. **Scenario tests CANNOT check this** — the headless runner
   disables `_physics_process` (no move_and_slide). Use a live `--capture`
   after ~4 s with a visible test body, or spawn the real player high and
   capture it settled.

## Hard-won gotchas (don't relearn these)

- **`visual.normalize: false` is mandatory on the terrain** — without it the
  renderer scales the glb to unit-height (1/37), pancaking a 150 m terrain to
  ~4 units and flattening 5 m of relief into 0.15 (looks dead flat). ADR 0062.
- **PLANAR decimate only** — COLLAPSE decimate pancakes terrain relief.
- **Scatter coords** — Infinigen is Z-up, Yume is Y-up; the driver maps
  Blender (x,y,z) → Yume (x, z, −y). Unit-tested; don't hand-edit.
- **Scatter is positions-only** — never realize Infinigen's foliage (that's
  the 16 GB path). Place YOUR Phase-B assets at the positions.
- **`validate_center_pivot_y` is terrain-aware** — it skips the flat-ground
  y≈height/2 check when a terrain def is present (the surface height is a
  legitimate non-zero y). Don't "fix" scatter y-values to 0.
- **`os._exit(0)`** after gen is normal (dodges a bpy-as-module atexit
  segfault); a rc=1 after a success log line is harmless.

## References

- ADR 0074 — the World-layer backend decision + support matrix.
- `tools/yume_infinigen/README.md` — usage + the one-time terrain build.
- `.claude/rules/data-demo.md` — `visual.normalize`, base-anchoring, schema.
- `.claude/rules/visual-qa.md` — the capture+read gate this skill runs.
