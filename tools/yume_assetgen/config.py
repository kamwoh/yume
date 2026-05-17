"""
config.py — asset_gen.json schema + load/save helpers.

asset_gen.json lives at `data/<game>/asset_gen.json` and configures
which backend to use, project-wide style prompts, and where outputs
land. Per-entity prompts live in the entity defs themselves (in the
`visual` block) — this file is just the shared config.

Schema:
{
  "_comment": "...",
  // backend can be a string (single backend for everything) OR a
  // dict {texture: "X", mesh: "Y", concept: "Z"} for per-kind
  // routing. Per-kind config is the recommended shape — different
  // services do textures (Gemini/nanobanana) vs meshes (Tripo3D)
  // better, and you usually want both in one game.
  "backend": "mock" | {
    "texture": "nanobanana" | "mock",
    "mesh":    "tripo3d"    | "mock",
    "concept": "nanobanana" | "mock"   // optional; defaults to texture backend
  },
  "backend_config": {
    "mock":       {"output_size": [512, 512]},
    "nanobanana": {"api_key_env": "GEMINI_API_KEY",
                   "model": "gemini-2.5-flash-image",
                   "timeout": 120},
    "tripo3d":    {"api_key_env": "TRIPO_API_KEY",
                   "poll_interval": 5, "timeout": 600,
                   "texture": true, "pbr": true}
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
    # `backend` is either a string (single backend for everything) OR
    # a dict {texture: "X", mesh: "Y", concept: "Z"} per-kind routing.
    backend: object = "mock"
    backend_config: dict = field(default_factory=dict)
    style: dict = field(default_factory=lambda: {
        "global_prefix": "",
        "texture_suffix": "",
        "mesh_suffix": "",
        "concept_suffix": "",
        "negative_prompt": "",
    })
    outputs: dict = field(default_factory=lambda: {
        "texture_dir": "assets/textures",
        "mesh_dir": "assets/meshes",
        "concept_dir": "assets/concepts",
        "image_size": [512, 512],
    })
    patch_entities: bool = True
    skip_existing: bool = True

    def texture_dir_abs(self, game_dir: Path) -> Path:
        return game_dir / self.outputs.get("texture_dir", "assets/textures")

    def mesh_dir_abs(self, game_dir: Path) -> Path:
        return game_dir / self.outputs.get("mesh_dir", "assets/meshes")

    def concept_dir_abs(self, game_dir: Path) -> Path:
        return game_dir / self.outputs.get("concept_dir", "assets/concepts")

    def texture_ref(self, game_dir_rel_to_res: str, entity_id: str) -> str:
        """Build the `res://...` reference for a generated texture."""
        d = self.outputs.get("texture_dir", "assets/textures")
        return f"res://{game_dir_rel_to_res}/{d}/{entity_id}.png"

    def mesh_ref(self, game_dir_rel_to_res: str, entity_id: str) -> str:
        d = self.outputs.get("mesh_dir", "assets/meshes")
        return f"res://{game_dir_rel_to_res}/{d}/{entity_id}.glb"

    def backend_for(self, kind: str) -> str:
        """Resolve the backend name for a given asset kind.

        kind is "texture" / "mesh" / "concept". If `backend` is a
        string, that single backend handles every kind. If `backend`
        is a dict, look up the kind; `concept` falls back to
        `texture`'s backend when not explicitly set.
        """
        b = self.backend
        if isinstance(b, str):
            return b
        if isinstance(b, dict):
            if kind in b:
                return str(b[kind])
            if kind == "concept" and "texture" in b:
                return str(b["texture"])
            # Unknown kind: pick any present mapping as a last resort.
            for v in b.values():
                return str(v)
        return "mock"


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
            "run `python3 -m tools.yume_assetgen <game_name>`. "
            "Set GEMINI_API_KEY + TRIPO_API_KEY env vars before running "
            "with the real backends."
        ),
        "backend": {
            "texture": "nanobanana",
            "mesh": "tripo3d",
            "concept": "nanobanana"
        },
        "backend_config": {
            "mock": {"output_size": [512, 512]},
            "nanobanana": {
                "api_key_env": "GEMINI_API_KEY",
                "model": "gemini-2.5-flash-image",
                "timeout": 120
            },
            "tripo3d": {
                "api_key_env": "TRIPO_API_KEY",
                "poll_interval": 5,
                "timeout": 600,
                "texture": True,
                "pbr": True
            }
        },
        "style": {
            "global_prefix": "",
            "texture_suffix": ", color albedo only, tileable, no shadows",
            "mesh_suffix": ", clean topology, T-pose, low triangle count",
            "concept_suffix": ", front view, neutral pose, clean style",
            "negative_prompt": "blur, noise, signature, watermark"
        },
        "outputs": {
            "texture_dir": "assets/textures",
            "mesh_dir": "assets/meshes",
            "concept_dir": "assets/concepts",
            "image_size": [512, 512]
        },
        "patch_entities": True,
        "skip_existing": True,
    }
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(template, indent=2) + "\n", encoding="utf-8")
    return p
