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

import urllib.error
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Iterable

# HTTP statuses that mean "the provider did not do the work, try later".
# Other 4xx errors (bad request, auth, no credit, moderation) fail the
# same way on a retry. A network timeout is ambiguous: the provider can
# have done (and charged) the work, so it is never retried either.
RETRYABLE_STATUS = frozenset({429, 500, 502, 503, 504})


class BackendHTTPError(RuntimeError):
    """An HTTP error from a backend, with its status code.

    Empirical 2026-10-16 (batch B): compose_scene retried every error 3
    times, so a 400 or a timeout on a paid call ran 3 times. Callers now
    retry only when `retryable` is true."""

    def __init__(self, backend: str, status: int, reason: str, body: str = "", where: str = ""):
        self.backend = backend
        self.status = status
        self.body = body
        at = f" on {where}" if where else ""
        super().__init__(f"{backend}: HTTP {status} {reason}{at} — {body[:500]}")

    @property
    def retryable(self) -> bool:
        return self.status in RETRYABLE_STATUS


def http_error(backend: str, e: urllib.error.HTTPError, where: str = "") -> BackendHTTPError:
    """Build a BackendHTTPError from a urllib HTTPError, with its body."""
    body = ""
    try:
        body = e.read().decode("utf-8", errors="replace")
    except Exception:
        pass
    return BackendHTTPError(backend, e.code, str(e.reason), body, where)


def is_retryable(e: BaseException) -> bool:
    return isinstance(e, BackendHTTPError) and e.retryable


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
        task_slot=None,
    ) -> Path:
        """Write a .glb to `out_path`. Returns the path written.

        `reference_image` (optional) is a path to a PNG that should be
        used as a 2D concept-image input to image→3D mode (Tripo3D
        supports this; other backends may ignore it).

        `task_slot` (optional, a ledger.TaskSlot) lets an async backend
        record its task id at submit and resume it on a later run. A
        synchronous backend ignores it.
        """
        raise NotImplementedError(
            f"{self.name()}: mesh generation not supported"
        )
