---
name: yume-create-scene
description: One-command text-to-3D-world pipeline. From a prose scene pitch, produces a runnable Yume scene end-to-end — hero reference → hero-conditioned orthographic → semantic + heightmap → extract → map (compose_world) → presentation shell (compose_shell) → optional Tripo assets. The catalog is the single LLM-authored input; tools.visual_layout.compose_scene drives the rest deterministically. Invoke when the user wants a whole new 3D scene/level from a description (NOT for HUD/screen authoring, single assets, or GDScript-game generation).
---

# /yume-create-scene

You are the **orchestrator** for Yume's text-to-3D-world pipeline. Given a
prose scene pitch, you produce a runnable scene by authoring the one
LLM-in-the-loop input (the class catalog) and then running the
deterministic orchestrator.

## The pipeline (what `compose_scene` chains)

```
prose + catalog
  ├─ 1. HERO reference        openai text→image      (the art-direction anchor)
  ├─ 2. ORTHOGRAPHIC top-down openai /edits on HERO   (hero-conditioned: one style)
  ├─ 3. SEMANTIC map          openai /edits on ORTHO  (flat-colour classification)
  ├─ 4. HEIGHTMAP             openai /edits on ORTHO  (grayscale elevation)
  ├─ 5. compose_world         (SCENE only: defs + flat placements in
  │                            entities/auto_gen.json, biome ground, water)
  │       └─ extraction: generic strategy dispatch, OR a per-scene
  │          authored `data/<game>/extract.py` if present (see § Per-scene
  │          extractor)
  ├─ 6. compose_shell         (FLAT shell: camera/player/input/lighting/.tscn,
  │                            singletons in entities/shell_singletons.json)
  └─ 7. [--assets] yume_assetgen (Tripo .glb for asset_source:tripo classes)
```

Every stage after the catalog is deterministic — your job is the catalog +
running the tool + the visual-qa loop.

**Scene-only + flat (ADR 0067).** `compose_world` is the **scene layer** — it
writes ONLY the 3D environment (`scene.json`, `entities/auto_gen.json` with
defs + flat `initial_instances`, biome ground, water, road graph, terrain
assets). It writes **no** `game/flow.json`, **no** `levels/`, **no**
`world/state.json` (those are game-domain). The scene boots FLAT — the engine
globs `entities/*.json`; `world_boot._load_content`'s else-branch needs no
flow.json. `compose_shell` then writes its singletons to a flat
`entities/shell_singletons.json`. Keeping the scene in its own lane is what
lets `/yume-design --scene` reuse `compose_world` as the World layer without a
clobber (see § Used as the World layer below).

## Procedure

### 1. Author the class catalog (the one LLM step)

Invoke `yume-scene-class-catalog` on the prose (and a stage-1 reference if
present) to produce the catalog JSON. It defines the classes, their hex
keys (CLASSIFICATION colours, not display colours — see
yume-scene-class-catalog rule #8), intent types, `expected_count`s,
`heightmap_hints`, and `composition_notes`. Save it (e.g.
`/tmp/_class_catalog.json`).

Per-class **asset tier** is set in `extraction_strategies.json`
(`asset_source`: kit / procedural / tripo). Before marking a class
`tripo`, CHECK the kit registry (meshes.json) — reuse an existing kit if
one fits (compose_world also warns). Complex hero objects → tripo (a
style-aligned `mesh_reference_prompt` drives a hero-conditioned concept →
image_to_model). Simple/structural → kit.

### 2. (Optional) per-scene config

Drop a `godot/data/<game>/scene_config.json` (dataclass-backed; see
`tools/visual_layout/scene_config.py`) to set world size, terrain
height_scale/offset, biome colours, lighting mood, player spawn, and shell
jump feel (`"shell": {"jump_impulse": 7.0, "gravity": 18.0}` — initial
jump/fall values written into the scaffold; both stay runtime-mutable
state). Omit for sensible defaults.

### 3. Run the orchestrator

```bash
python3 -m tools.visual_layout.compose_scene <game> \
    --catalog /tmp/_class_catalog.json [--prose "..."] [--assets]
```

- Idempotent: image steps skip if present (`--regen` to force).
- `--skip-gen` if the maps already exist (just re-run compose_world/shell).
- `--assets` to also generate Tripo meshes.

### 3b. (Optional) per-scene extractor — `data/<game>/extract.py`

When the generic strategy dispatch mis-places a scene's objects (wrong
mask, scatter ignoring where the LLM drew things, rotation/scale off),
author a per-scene extractor instead of hand-tuning magic constants in
`extraction_strategies.json`. `compose_world` auto-discovers
`data/<game>/extract.py` (gitignored, per-scene content — NOT shared
tooling) and runs its `extract(ctx) -> list[dict]` in place of the
generic dispatch; absent → dispatch as before.

**The discipline (user directive 2026-05-29): the script WRITES
FUNCTIONS that DERIVE values; it never hand-sets them.** Tuning = tuning
the formula, not the constant.

| value | derive from | NOT |
|---|---|---|
| scatter count | the catalog's `expected_count` (design intent) | ❌ "fill the mask" (a drawn blob is a CLUSTER, not a per-pixel tiling — filling it 1:1 made 1275 flowers + 6 fps) |
| scatter position | within the class's OWN drawn mask (where the LLM put it) | ❌ scatter on grass / a foreign mask |
| spacing | `√(mask_area / N) · SPREAD` | ❌ hand-set `min_distance` |
| blob scale | the drawn component's world bbox (non-canonical assets) | ❌ a guessed canonical for things the LLM sized |
| rotation | PCA major axis of the blob when elongated, else rotation_rule | ❌ 0 / random |

Reuse `lib_extract` + `lib_extract_dispatch` helpers (connected_components,
infer_rotation_deg, pixel_to_world, _emit_instance, _instance) — the
library does the primitives; the per-scene script does the routing +
derivation. Reference implementation: `data/demo_tiny_village/extract.py`.

The comparator `tools/visual_layout/compare_semantic.py` is the
**placement-fidelity signal** for tuning the formulas:
```bash
python3 -m tools.visual_layout.compare_semantic <game> --catalog <catalog.json>
```
It synthesizes the actual semantic from the placed entities and reports
per-class IoU + coverage delta vs the LLM map (+ a `semantic_diff.png`).

### 4. Visual-QA loop (REQUIRED — see `.claude/rules/visual-qa.md`)

⚠️ **The semantic diff is a PLACEMENT PROXY, not a quality metric.** A
high IoU means "entities landed where the LLM drew them" — it says
NOTHING about whether the scene looks good or even renders at a sane
frame rate. Empirical 2026-05-29: chasing the comparator's coverage-delta
drove counts to 2129 instances (IoU up!) while the scene became a carpet
of fallback boxes at 6 fps. **You MUST capture + read the 3D frame before
declaring done — every time, no exceptions.** Numbers passing ≠ scene
good.

Capture and review — DON'T declare done on "it ran" OR "the IoU is high":
```bash
./scripts/play.sh <name> --capture     # or godot ... --capture-after
```
Read the PNG with a context-specific prompt. Check the 3D baseline
(ground, sky, lighting, player present, mesh bases on ground, NO tiling
grid on textured ground — baseline #10) and composition. Also check:
- **instance count + fps** — the capture log prints `n=<count>` and
  `FPS avg`. Thousands of instances / fps < 20 = a count-derivation bug;
  scatter counts must come from `expected_count`, not mask-fill.
- **no untextured fallback boxes** — a class rendering as white/grey
  primitive cubes means its `asset_source:tripo` `.glb` was never
  generated (run with `--assets`) OR it has no kit. Don't ship box-litter.

### 5. Report

Scene path, what generated vs skipped, the play command, instance count +
fps, and any visual-qa findings.

## Hard rules

- **The catalog is the only thing you author by hand.** Everything else is
  the tool. Don't hand-write entity defs / placements.
- **Never commit generated assets** (.glb / gen textures / concepts) — they
  are gitignored and regenerated. See `.claude/rules` + memory.
- **Never delete/overwrite generated assets** — versioned filenames; old
  outputs are preserved (paid artifacts).
- **compose_world wipes the shell**; re-running it regenerates
  `entities/auto_gen.json` + a camera-less `scene.json`, so the orchestrator
  always runs compose_shell after, and `validate_shell_consistency` catches a
  camera-less / player-less scene if a step is skipped.
- **Tripo .glb are heavy** (~40MB high-poly). For many instances of one
  asset, prefer a kit or (future) MultiMesh; watch perf.
- **Scatter counts come from `expected_count`, never from mask-fill.** A
  drawn blob is a cluster, not a per-pixel tiling. The catalog's
  `expected_count` is the design intent for HOW MANY; the mask is only
  WHERE. (Empirical 2026-05-29: mask-fill → 2129 instances → 6 fps.)
- **The semantic diff never substitutes for a 3D capture.** It is a
  placement proxy. Capture every iteration before declaring done.

## Used as the World layer by `/yume-design --scene` (ADR 0067)

`/yume-design --scene` builds a **game inside a generated 3D world**. It
reuses the **World layer of this pipeline** — the catalog step
(`yume-scene-class-catalog`) + `compose_world` — to produce the scene, then
the game skills layer the player + mechanics on top. It does **NOT** run
`compose_shell`: a real game provides its own player, movement, and camera,
so the third-person-explorer shell would conflict. The split is:

| | `/yume-create-scene` (this skill) | `/yume-design --scene` |
|---|---|---|
| Runs `compose_world`? | yes (scene) | yes (scene — the World layer) |
| Runs `compose_shell`? | **yes** (walkable diorama) | **no** (the game owns player/camera/movement) |
| Result | a walkable scene, no game logic | a full game set in the generated scene |

So this skill = "scene you can walk around in"; `/yume-design --scene` =
"game in a generated scene." Both share `compose_world`; only this skill adds
the shell. Don't run BOTH on one folder — the shell's gameplay rules would
collide with the game's mechanics.

## What this is NOT

- NOT HUD/screen authoring (yume-hud-author / yume-screen-author — locked
  2D pipelines).
- NOT single-asset generation (yume-asset-designer + yume_assetgen).
- NOT the GDScript-game pipeline (`/yume-design` → GDD → JSON game). But
  `/yume-design --scene` DOES reuse this skill's World layer (above).
- NOT `compose_map` / `yume-map-author`. That's a DIFFERENT tool: a 2D
  semantic sketch → entity **instances + patterns** spliced into an existing
  game's `levels/<id>/entities.json` (adding/editing a LEVEL). This skill
  generates a whole 3D **scene** (terrain, biomes, water, 3D placements).
  Both are the ACTIVE 3D pipeline category (see
  `.claude/rules/pipeline-stability.md`).

## Reference files

- `tools/visual_layout/compose_scene.py` — the orchestrator (this skill drives it)
- `tools/visual_layout/compose_world.py` / `compose_shell.py` — map + shell layers
- `tools/visual_layout/scene_config.py` — per-scene config dataclasses
- `tools/visual_layout/compare_semantic.py` — placement-fidelity comparator (IoU + diff PNG)
- `godot/data/<game>/extract.py` — OPTIONAL per-scene authored extractor (derives count/scale/rotation; gitignored)
- `godot/data/lib/extraction_strategies.json` — per-class strategy + asset_source
- `.claude/skills/yume-scene-class-catalog/SKILL.md` — the stage-2 catalog author
- `.claude/rules/visual-qa.md` — the mandatory visual gate
