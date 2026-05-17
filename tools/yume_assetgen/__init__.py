"""
yume_assetgen — AI-assisted texture + mesh generation pipeline.

Reads `data/<game>/asset_gen.json` (backend + style config), scans
the game's entity defs for `*_prompt` fields, dispatches each prompt
to the configured backend, saves output to `data/<game>/assets/`,
and (optionally) patches entity defs to reference the generated
files.

CLI:
    python3 -m tools.yume_assetgen <game_name>
    python3 -m tools.yume_assetgen <game_name> --dry-run
    python3 -m tools.yume_assetgen <game_name> --backend mock
    python3 -m tools.yume_assetgen <game_name> --only-textures
    python3 -m tools.yume_assetgen <game_name> --only-meshes

Backend interface lives at backends.base.Backend; mock backend ships
with the package. Real backends (OpenAI Images, Stable Diffusion,
Tripo3D mesh-gen) slot in by subclassing Backend + registering in
backends.REGISTRY.

Empirical motivation (task #116, 2026-05-17):
    Code-drawn primitives + flat colors give every entity the same
    "engineering preview" look. AI-gen textures + meshes let each
    game ship a distinct aesthetic without per-asset hand-authoring.
    JSON content stays canonical; the pipeline emits files that
    entity defs reference via `visual.albedo_texture` /
    `visual.mesh`.
"""

from .config import AssetGenConfig, load_config, save_config_template
from .pipeline import run_pipeline, scan_prompts, PromptItem
from .backends import REGISTRY, Backend, get_backend

__version__ = "0.1.0"
