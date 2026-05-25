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
from .imagen import ImagenBackend
from .mock import MockBackend
from .nanobanana import NanobananaBackend
from .openai_images import OpenAIImagesBackend
from .tripo3d import Tripo3DBackend

# Backend registry — name (string in asset_gen.json) → class.
# Real backends require API keys in env (GEMINI_API_KEY / OPENAI_API_KEY /
# TRIPO_API_KEY); `--backend mock` overrides config for offline iteration.
#   nanobanana     = gemini-2.5-flash-image — 1024×1024, multimodal (refs)
#   imagen         = imagen-4.0-generate-001 — supports 16:9 + other aspects
#   openai_images  = gpt-image-2-2026-04-21 — OpenAI's image gen,
#                    supports 1024x1024 / 1024x1536 / 1536x1024
#   tripo3d        = image + text → .glb mesh
REGISTRY = {
    "mock": MockBackend,
    "nanobanana": NanobananaBackend,
    "gemini_image": NanobananaBackend,    # alias — same underlying API
    "imagen": ImagenBackend,
    "openai_images": OpenAIImagesBackend,
    "gpt_image": OpenAIImagesBackend,     # alias — short form
    "tripo3d": Tripo3DBackend,
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
