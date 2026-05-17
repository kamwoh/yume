"""
base.py — Backend abstract base class.

Each concrete backend (mock, openai_images, stable_diffusion_local,
tripo3d) implements ONE OR BOTH of:
    - generate_texture(prompt, out_path, size) — PNG output
    - generate_mesh(prompt, out_path) — .glb output

If a backend doesn't support a kind (e.g. OpenAI Images doesn't do
meshes), `supports_mesh` returns False and pipeline skips.

The pipeline catches per-prompt exceptions and continues — one
prompt failing shouldn't block the rest of the batch.
"""

from abc import ABC, abstractmethod
from pathlib import Path
from typing import Iterable


class Backend(ABC):
    """Abstract base for asset-gen backends.

    Subclasses receive their `backend_config[<name>]` dict in
    __init__. The pipeline calls `supports_texture()` /
    `supports_mesh()` to decide which prompts to dispatch.
    """

    def __init__(self, config: dict):
        self.config = config

    @abstractmethod
    def name(self) -> str:
        """Return the backend's registry name."""

    def supports_texture(self) -> bool:
        return False

    def supports_mesh(self) -> bool:
        return False

    def generate_texture(
        self,
        prompt: str,
        out_path: Path,
        size: Iterable[int] = (512, 512),
    ) -> Path:
        """Write a PNG to `out_path` based on `prompt`. Returns the
        path written. Implementations should `mkdir -p` parent dirs.
        """
        raise NotImplementedError(
            f"{self.name()}: texture generation not supported"
        )

    def generate_mesh(
        self,
        prompt: str,
        out_path: Path,
        reference_image: "Path | None" = None,
    ) -> Path:
        """Write a .glb to `out_path`. Returns the path written.

        `reference_image` (optional) is a path to a PNG that should be
        used as a 2D concept-image input to image→3D mode (Tripo3D
        supports this; other backends may ignore it).
        """
        raise NotImplementedError(
            f"{self.name()}: mesh generation not supported"
        )
