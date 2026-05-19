"""
imagen.py — Google Imagen 4 backend (supports non-square aspect).

Sibling of nanobanana.py. Difference: Gemini Flash Image
(nanobanana) outputs 1024×1024 only; Imagen 4 supports
{1:1, 9:16, 16:9, 4:3, 3:4} aspect ratios natively.

Used for:
    - UI wireframes (16:9 matches game viewport)
    - Semantic maps (1:1 for top-down; could use 16:9 for side-scroll)
    - Any texture/concept where aspect matters

Uses the same Google API key as Gemini (GEMINI_API_KEY).

API spec (current as of 2026-05-19):
    POST https://generativelanguage.googleapis.com/v1beta/models/imagen-4.0-generate-001:predict?key=<API_KEY>
    Body:
      {
        "instances": [{"prompt": "<prompt>"}],
        "parameters": {
          "sampleCount": 1,
          "aspectRatio": "16:9"  // 1:1 | 9:16 | 16:9 | 4:3 | 3:4
        }
      }
    Response:
      {
        "predictions": [
          {"bytesBase64Encoded": "<base64 PNG bytes>",
           "mimeType": "image/png"}
        ]
      }

Three model variants live:
    - imagen-4.0-generate-001       — standard quality
    - imagen-4.0-fast-generate-001  — faster + cheaper, lower quality
    - imagen-4.0-ultra-generate-001 — highest quality, slower + pricier

Default model = standard. Pricing ~$0.04/image (standard), $0.02/image
(fast). Imagen 3 was retired; do NOT use imagen-3.0-* model ids.

Config (backend_config.imagen):
    api_key_env: env var name (default GEMINI_API_KEY)
    model: model id (default imagen-4.0-generate-001)
    aspect_ratio: default aspect (default "16:9")
    timeout: request timeout in seconds (default 120)

Pure stdlib via urllib.request.
"""

import base64
import json
import os
import urllib.error
import urllib.request
from pathlib import Path
from typing import Iterable

from .base import Backend


# Imagen 3 accepts exactly these aspect ratios. Map `size=(W, H)` we
# get from the pipeline into the nearest supported aspect.
SUPPORTED_ASPECTS = {
    "1:1":  1.0,
    "16:9": 16 / 9,
    "9:16": 9 / 16,
    "4:3":  4 / 3,
    "3:4":  3 / 4,
}


def _size_to_aspect(size: Iterable[int], default: str = "16:9") -> str:
    """Pick the supported aspect ratio nearest to size=(W, H)."""
    try:
        w, h = list(size)[:2]
        target = float(w) / max(float(h), 1.0)
    except Exception:
        return default
    best_name = default
    best_diff = float("inf")
    for name, ratio in SUPPORTED_ASPECTS.items():
        d = abs(target - ratio)
        if d < best_diff:
            best_diff = d
            best_name = name
    return best_name


class ImagenBackend(Backend):
    """Google Imagen 3.0 text-to-image with native aspect-ratio support."""

    DEFAULT_MODEL = "imagen-4.0-generate-001"
    API_BASE = "https://generativelanguage.googleapis.com/v1beta"

    def name(self) -> str:
        return "imagen"

    def supports_texture(self) -> bool:
        return True

    def supports_mesh(self) -> bool:
        # 2D image gen only — meshes go through Tripo3D.
        return False

    # ------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------

    def generate_texture(
        self,
        prompt: str,
        out_path: Path,
        size: Iterable[int] = (1280, 720),
    ) -> Path:
        """Generate a PNG from the prompt. `size` is mapped to the
        nearest supported aspect ratio; Imagen picks the actual
        output resolution within that aspect.

        Default (1280, 720) maps to 16:9 — appropriate for UI
        wireframes that target a 16:9 game viewport.
        """
        api_key = self._get_api_key()
        model = self.config.get("model", self.DEFAULT_MODEL)
        aspect = self.config.get("aspect_ratio") or _size_to_aspect(
            size, default="16:9"
        )

        url = f"{self.API_BASE}/models/{model}:predict?key={api_key}"
        body = {
            "instances": [{"prompt": prompt}],
            "parameters": {
                "sampleCount": 1,
                "aspectRatio": aspect,
            },
        }

        timeout = float(self.config.get("timeout", 120))
        data = _post_json(url, body, timeout=timeout)

        predictions = data.get("predictions", [])
        if not predictions:
            raise RuntimeError(f"imagen: no predictions in response: {data}")
        first = predictions[0]
        img_b64 = first.get("bytesBase64Encoded", "")
        if not img_b64:
            err = first.get("raiFilteredReason") or first.get("error") or "no image bytes"
            raise RuntimeError(f"imagen: image missing from prediction ({err})")
        img_bytes = base64.b64decode(img_b64)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(img_bytes)
        return out_path

    # ------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------

    def _get_api_key(self) -> str:
        env_var = self.config.get("api_key_env", "GEMINI_API_KEY")
        key = os.environ.get(env_var, "").strip()
        if not key:
            raise RuntimeError(
                f"imagen: env var {env_var} is empty. "
                f"Set GEMINI_API_KEY or override via backend_config.imagen.api_key_env."
            )
        return key


def _post_json(url: str, body: dict, *, timeout: float = 120) -> dict:
    """POST JSON, parse JSON response. Surfaces error body on non-2xx."""
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        body_text = ""
        try:
            body_text = e.read().decode("utf-8", errors="replace")
        except Exception:
            pass
        raise RuntimeError(
            f"imagen: HTTP {e.code} {e.reason}\n  {body_text[:600]}"
        ) from e
