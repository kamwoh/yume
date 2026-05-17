# yume_assetgen — AI-assisted texture + mesh pipeline

JSON content stays canonical. This package emits the asset files
(PNGs for material textures, `.glb` files for 3D meshes) that
entity defs reference via `visual.albedo_texture` and `visual.mesh`.

## Quickstart

```bash
# 1. Drop a starter asset_gen.json into your game folder.
python3 -m tools.yume_assetgen demo_mygame --init

# 2. Add `*_prompt` fields to entity defs you want generated.
#    See "Authoring prompts" below.

# 3. List what WOULD generate (no API calls, no writes):
python3 -m tools.yume_assetgen demo_mygame --dry-run

# 4. Generate (mock backend by default — no external calls):
python3 -m tools.yume_assetgen demo_mygame

# 5. Switch to a real backend by editing asset_gen.json's `backend`
#    field. When real backends ship: openai_images, sd_local, tripo3d.
```

## Authoring prompts

Inside an entity def's `visual` block, add:

```jsonc
{
  "id": "villager_marken",
  "tags": ["villager", "actor"],
  "visual": {
    "color": "#a0c0e0",
    "albedo_texture_prompt": "weather-worn villager body, soft cel-shaded",
    "mesh_prompt": "low-poly humanoid villager, T-pose, clean topology"
  }
}
```

The pipeline:

1. Walks `entities/**/*.json` collecting `*_prompt` fields.
2. Wraps each prompt: `style.global_prefix + <raw_prompt> + style.<kind>_suffix`.
3. Dispatches to the configured backend.
4. Writes output to `assets/textures/<entity_id>.png` and
   `assets/meshes/<entity_id>.glb` (paths configurable).
5. Patches the entity def in place with the resolved `res://` path,
   leaving the prompt field untouched so re-runs find it again.

After a run, the def becomes:

```jsonc
{
  "id": "villager_marken",
  "tags": ["villager", "actor"],
  "visual": {
    "color": "#a0c0e0",
    "albedo_texture_prompt": "weather-worn villager body, soft cel-shaded",
    "albedo_texture": "res://data/demo_mygame/assets/textures/villager_marken.png",
    "mesh_prompt": "low-poly humanoid villager, T-pose, clean topology",
    "mesh": "res://data/demo_mygame/assets/meshes/villager_marken.glb"
  }
}
```

## asset_gen.json schema

```jsonc
{
  "backend": "mock",              // "mock" | "openai_images" | "stable_diffusion_local" | "tripo3d"
  "backend_config": {
    "mock": {"output_size": [512, 512]},
    "openai_images": {
      "model": "dall-e-3",
      "size": "1024x1024",
      "api_key_env": "OPENAI_API_KEY"
    },
    "stable_diffusion_local": {
      "endpoint": "http://127.0.0.1:7860",
      "sampler": "Euler a",
      "steps": 25
    },
    "tripo3d": {"api_key_env": "TRIPO3D_API_KEY"}
  },
  "style": {
    "global_prefix": "low-poly cartoon, soft lighting, ",
    "texture_suffix": ", color albedo only, tileable, no shadows",
    "mesh_suffix": ", clean topology, T-pose, low triangle count",
    "negative_prompt": "blur, noise, signature, watermark"
  },
  "outputs": {
    "texture_dir": "assets/textures",   // relative to data/<game>/
    "mesh_dir": "assets/meshes",
    "image_size": [512, 512]
  },
  "patch_entities": true,
  "skip_existing": true
}
```

## Backends

| Name | Textures | Meshes | Notes |
|------|---------|---------|-------|
| `mock` | ✓ | ✓ | No external calls. Emits deterministic prompt-hash gradient PNGs + cube .glbs. Use for smoke testing + visual layout before art ships. |
| `openai_images` | (planned) | ✗ | DALL-E 3 / DALL-E 2 via OpenAI API. Needs `OPENAI_API_KEY`. |
| `stable_diffusion_local` | (planned) | ✗ | Automatic1111 / ComfyUI HTTP API. Free. |
| `tripo3d` | ✗ | (planned) | Text + ref-image → .glb mesh. Needs `TRIPO3D_API_KEY`. |

To add a backend: subclass `Backend` in
`tools/yume_assetgen/backends/<name>.py`, implement
`generate_texture` and/or `generate_mesh`, register in
`backends/__init__.py::REGISTRY`.

## CLI flags

```
python3 -m tools.yume_assetgen <game_name> [options]

  --dry-run             list outputs without writing
  --backend NAME        override asset_gen.json's `backend` choice
  --only-textures       skip mesh prompts (faster iteration)
  --only-meshes         skip texture prompts
  --init                drop a starter asset_gen.json + exit
  --quiet               suppress per-item logging
  --json                print full summary as JSON at end
```

## Smoke test

```bash
python3 -m tools.yume_assetgen.tests.test_smoke
```

19 assertions covering: scan, prompt assembly, dry-run, mock
generation (PNG + GLB validity), entity-def patching, and
idempotent re-run.

## What this doesn't do (yet)

- **Texture support in the renderer** — needs companion engine
  change (task #117) extending `material_overrides` + a new
  `visual.albedo_texture` field on code-drawn meshes. Until that
  ships, generated PNGs sit on disk but don't render.
- **Real backend implementations** — only mock ships in v1.
  Real backends need API keys + per-backend testing.
- **Mesh re-targeting / animation rigging** — generated `.glb`
  files don't auto-pose for Yume's animation rules. Authors
  still add `animation_state_rules` + `clip_alias` per entity.
- **Style consistency across batches** — the global_prefix is
  the only consistency lever. Per-character LoRA / consistent-
  character workflows are backend-specific.
