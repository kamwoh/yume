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
  ├─ 5. compose_world         (extract → defs, placements, biome ground, water)
  ├─ 6. compose_shell         (camera, player, input, lighting, .tscn)
  └─ 7. [--assets] yume_assetgen (Tripo .glb for asset_source:tripo classes)
```

Every stage after the catalog is deterministic — your job is the catalog +
running the tool + the visual-qa loop.

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
height_scale/offset, biome colours, lighting mood, player spawn. Omit for
sensible defaults.

### 3. Run the orchestrator

```bash
python3 -m tools.visual_layout.compose_scene <game> \
    --catalog /tmp/_class_catalog.json [--prose "..."] [--assets]
```

- Idempotent: image steps skip if present (`--regen` to force).
- `--skip-gen` if the maps already exist (just re-run compose_world/shell).
- `--assets` to also generate Tripo meshes.

### 4. Visual-QA loop (REQUIRED — see `.claude/rules/visual-qa.md`)

Capture and review — DON'T declare done on "it ran":
```bash
./scripts/play.sh <name> --capture     # or godot ... --capture-after
```
Read the PNG with a context-specific prompt. Check the 3D baseline
(ground, sky, lighting, player present, mesh bases on ground, NO tiling
grid on textured ground — baseline #10) and composition. Iterate.

### 5. Report

Scene path, what generated vs skipped, the play command, and any
visual-qa findings.

## Hard rules

- **The catalog is the only thing you author by hand.** Everything else is
  the tool. Don't hand-write entity defs / placements.
- **Never commit generated assets** (.glb / gen textures / concepts) — they
  are gitignored and regenerated. See `.claude/rules` + memory.
- **Never delete/overwrite generated assets** — versioned filenames; old
  outputs are preserved (paid artifacts).
- **compose_world wipes the shell**; the orchestrator always runs
  compose_shell after, and `validate_shell_consistency` catches a
  camera-less scene if a step is skipped.
- **Tripo .glb are heavy** (~40MB high-poly). For many instances of one
  asset, prefer a kit or (future) MultiMesh; watch perf.

## What this is NOT

- NOT HUD/screen authoring (yume-hud-author / yume-screen-author — locked
  2D pipelines).
- NOT single-asset generation (yume-asset-designer + yume_assetgen).
- NOT the GDScript-game pipeline (/yume-design → GDD → JSON game).
- This is the ACTIVE 3D map/world pipeline (see
  `.claude/rules/pipeline-stability.md`).

## Reference files

- `tools/visual_layout/compose_scene.py` — the orchestrator (this skill drives it)
- `tools/visual_layout/compose_world.py` / `compose_shell.py` — map + shell layers
- `tools/visual_layout/scene_config.py` — per-scene config dataclasses
- `godot/data/lib/extraction_strategies.json` — per-class strategy + asset_source
- `.claude/skills/yume-scene-class-catalog/SKILL.md` — the stage-2 catalog author
- `.claude/rules/visual-qa.md` — the mandatory visual gate
