"""
backends — pluggable image / mesh generation backends.

Each backend implements the Backend protocol from base.py. The
REGISTRY dict maps backend names (the `backend` field in
asset_gen.json) to backend classes. The pipeline calls
get_backend(name, config) to instantiate.

Currently shipping:
    - mock: emits placeholder PNGs + minimal .glbs (synthesized via
      tools/synth_test_glb.py logic). No external API calls. Useful
      for smoke-testing the pipeline + filling in defaults for games
      without real generation set up.

Future (slot in by creating a module + adding to REGISTRY):
    - openai_images: DALL-E for textures, no mesh path
    - stable_diffusion_local: HTTP POST to Automatic1111 / ComfyUI
    - tripo3d: image + text → .glb mesh generation
"""

from .base import Backend
from .mock import MockBackend

# Backend registry — name (string in asset_gen.json) → class
REGISTRY = {
    "mock": MockBackend,
}


def get_backend(name: str, config: dict) -> Backend:
    """Look up a backend by name, instantiate with its config block.

    Raises KeyError if `name` isn't registered.
    """
    if name not in REGISTRY:
        raise KeyError(
            f"unknown backend '{name}'. Available: {sorted(REGISTRY.keys())}"
        )
    return REGISTRY[name](config or {})
