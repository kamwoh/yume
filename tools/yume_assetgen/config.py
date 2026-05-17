"""
config.py — asset_gen.json schema + load/save helpers.

asset_gen.json lives at `data/<game>/asset_gen.json` and configures
which backend to use, project-wide style prompts, and where outputs
land. Per-entity prompts live in the entity defs themselves (in the
`visual` block) — this file is just the shared config.

Schema:
{
  "_comment": "...",
  "backend": "mock" | "openai_images" | "stable_diffusion_local" | "tripo3d",
  "backend_config": {
    "mock":           {"output_size": [512, 512], "noise": 0.1},
    "openai_images":  {"model": "dall-e-3", "size": "1024x1024",
                       "api_key_env": "OPENAI_API_KEY"},
    "stable_diffusion_local": {
        "endpoint": "http://127.0.0.1:7860",
        "sampler": "Euler a",
        "steps": 25
    },
    "tripo3d":        {"api_key_env": "TRIPO3D_API_KEY"}
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
  "patch_entities": true,    // re-write entity defs with resolved paths
  "skip_existing": true      // don't regenerate if output file present
}

When `patch_entities=true`, the pipeline adds:
    visual.albedo_texture = "res://data/<game>/assets/textures/<entity>.png"
    visual.mesh           = "res://data/<game>/assets/meshes/<entity>.glb"
next to the existing *_prompt fields (preserved for re-runs).
"""

import json
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any


@dataclass
class AssetGenConfig:
    backend: str = "mock"
    backend_config: dict = field(default_factory=dict)
    style: dict = field(default_factory=lambda: {
        "global_prefix": "",
        "texture_suffix": "",
        "mesh_suffix": "",
        "negative_prompt": "",
    })
    outputs: dict = field(default_factory=lambda: {
        "texture_dir": "assets/textures",
        "mesh_dir": "assets/meshes",
        "image_size": [512, 512],
    })
    patch_entities: bool = True
    skip_existing: bool = True

    def texture_dir_abs(self, game_dir: Path) -> Path:
        return game_dir / self.outputs.get("texture_dir", "assets/textures")

    def mesh_dir_abs(self, game_dir: Path) -> Path:
        return game_dir / self.outputs.get("mesh_dir", "assets/meshes")

    def texture_ref(self, game_dir_rel_to_res: str, entity_id: str) -> str:
        """Build the `res://...` reference for a generated texture."""
        d = self.outputs.get("texture_dir", "assets/textures")
        return f"res://{game_dir_rel_to_res}/{d}/{entity_id}.png"

    def mesh_ref(self, game_dir_rel_to_res: str, entity_id: str) -> str:
        d = self.outputs.get("mesh_dir", "assets/meshes")
        return f"res://{game_dir_rel_to_res}/{d}/{entity_id}.glb"


def load_config(game_dir: Path) -> AssetGenConfig:
    """Load asset_gen.json from a game directory.

    If absent, returns a default AssetGenConfig with the mock
    backend — convenient for first-time use.
    """
    p = game_dir / "asset_gen.json"
    if not p.exists():
        return AssetGenConfig()
    raw = json.loads(p.read_text(encoding="utf-8"))
    raw.pop("_comment", None)
    cfg = AssetGenConfig()
    for k, v in raw.items():
        if hasattr(cfg, k):
            setattr(cfg, k, v)
    return cfg


def save_config_template(game_dir: Path, *, overwrite: bool = False) -> Path:
    """Drop a starter asset_gen.json into a game dir for the author
    to edit. Idempotent: refuses to overwrite unless overwrite=True.
    """
    p = game_dir / "asset_gen.json"
    if p.exists() and not overwrite:
        raise FileExistsError(f"{p}: already present; pass overwrite=True to replace")
    template = {
        "_comment": (
            "Asset-gen config for this game. Edit `backend` + `style` then "
            "run `python3 -m tools.yume_assetgen <game_name>`."
        ),
        "backend": "mock",
        "backend_config": {
            "mock": {"output_size": [512, 512], "noise": 0.1},
        },
        "style": {
            "global_prefix": "",
            "texture_suffix": "",
            "mesh_suffix": "",
            "negative_prompt": "",
        },
        "outputs": {
            "texture_dir": "assets/textures",
            "mesh_dir": "assets/meshes",
            "image_size": [512, 512],
        },
        "patch_entities": True,
        "skip_existing": True,
    }
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(template, indent=2) + "\n", encoding="utf-8")
    return p
