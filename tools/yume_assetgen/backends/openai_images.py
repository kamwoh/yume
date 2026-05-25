"""
openai_images.py — OpenAI gpt-image-2 backend.

Sibling of nanobanana.py + imagen.py. Uses OpenAI's `/v1/images/
generations` endpoint with the gpt-image-2 model. Same Backend
contract as the other texture backends: text prompt → PNG.

Used for:
    - albedo textures (visual.albedo_texture_prompt)
    - per-surface textures (material_overrides.<surface>.albedo_texture_prompt)
    - concept reference images (visual.mesh_reference_prompt) that
      can then feed Tripo3D's image-to-3D step

API spec:
    POST https://api.openai.com/v1/images/generations
    Headers: Authorization: Bearer <OPENAI_API_KEY>
    Body:
      {
        "model": "gpt-image-2-2026-04-21",
        "prompt": "<prompt>",
        "n": 1,
        "size": "1024x1024",          // 1024x1024 / 1024x1536 / 1536x1024
        "quality": "high",            // low / medium / high / auto
        "output_format": "png"
      }
    Response:
      {
        "data": [
          {"b64_json": "<base64 PNG bytes>"}
        ]
      }

The gpt-image family returns base64-encoded bytes by default (no
URL fetch round-trip), which makes the single-roundtrip pattern
the same as nanobanana / imagen.

Config (backend_config.openai_images):
    api_key_env: env var name (default OPENAI_API_KEY)
    model: model id override (default gpt-image-2-2026-04-21)
    quality: low / medium / high / auto (default "high")
    default_size: fallback "<W>x<H>" when caller doesn't pass size
                  (default "1024x1024")
    timeout: request timeout in seconds (default 120)

Pure stdlib via urllib.request — same approach as the sibling
backends. No `openai` SDK dependency.
"""

import base64
import json
import os
import urllib.error
import urllib.request
from pathlib import Path
from typing import Iterable

from .base import Backend


# gpt-image-2 accepts these exact size strings. Match `size=(W, H)`
# we get from the pipeline to the closest supported value.
SUPPORTED_SIZES = [
    (1024, 1024),
    (1024, 1536),
    (1536, 1024),
]


def _size_to_string(size: Iterable[int], default: str = "1024x1024") -> str:
    """Map a (W, H) tuple to the nearest supported size string."""
    try:
        w, h = list(size)[:2]
        target = float(w) / max(float(h), 1.0)
    except Exception:
        return default
    best = SUPPORTED_SIZES[0]
    best_diff = float("inf")
    for sw, sh in SUPPORTED_SIZES:
        ratio = float(sw) / float(sh)
        d = abs(target - ratio)
        if d < best_diff:
            best_diff = d
            best = (sw, sh)
    return f"{best[0]}x{best[1]}"


class OpenAIImagesBackend(Backend):
    """OpenAI gpt-image-2 text-to-image."""

    DEFAULT_MODEL = "gpt-image-2-2026-04-21"
    API_URL = "https://api.openai.com/v1/images/generations"

    def name(self) -> str:
        return "openai_images"

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
        size: Iterable[int] = (1024, 1024),
        reference_images: list[Path] | None = None,
    ) -> Path:
        """Generate a PNG from the prompt.

        `reference_images` is accepted for interface parity with
        nanobanana but IGNORED — the /v1/images/generations endpoint
        is text-only. Use OpenAI's separate /v1/images/edits endpoint
        if you ever need multimodal input (not wired here).

        `size` is mapped to the nearest supported size string
        (1024x1024 / 1024x1536 / 1536x1024).
        """
        if reference_images:
            print(
                "[openai_images] WARNING: reference_images given but the "
                "generations endpoint is text-only — refs ignored. "
                "Use nanobanana for multimodal style transfer."
            )

        api_key = self._get_api_key()
        model = self.config.get("model", self.DEFAULT_MODEL)
        quality = self.config.get("quality", "high")
        size_str = _size_to_string(
            size, default=self.config.get("default_size", "1024x1024")
        )

        body = {
            "model": model,
            "prompt": prompt,
            "n": 1,
            "size": size_str,
            "quality": quality,
            "output_format": "png",
        }
        timeout = float(self.config.get("timeout", 120))
        data = _post_json(
            self.API_URL,
            body,
            api_key=api_key,
            timeout=timeout,
        )

        items = data.get("data", [])
        if not items:
            raise RuntimeError(
                f"openai_images: empty data in response: {data}"
            )
        b64 = items[0].get("b64_json", "")
        if not b64:
            # Defensive: if the API ever returns a URL instead of b64
            # (older `dall-e-*` models did), surface a clear error so
            # the caller knows to fetch separately.
            url = items[0].get("url", "")
            if url:
                raise RuntimeError(
                    f"openai_images: got URL response (model returned "
                    f"`url` not `b64_json`). Either configure the model "
                    f"to return b64 or fetch the URL manually: {url}"
                )
            raise RuntimeError(
                f"openai_images: no b64_json in first data item: {items[0]}"
            )

        img_bytes = base64.b64decode(b64)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(img_bytes)
        return out_path

    # ------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------

    def _get_api_key(self) -> str:
        env_var = self.config.get("api_key_env", "OPENAI_API_KEY")
        key = os.environ.get(env_var, "").strip()
        if not key:
            raise RuntimeError(
                f"openai_images: env var {env_var} is empty. "
                f"Set OPENAI_API_KEY or override via "
                f"backend_config.openai_images.api_key_env."
            )
        return key


def _post_json(
    url: str,
    body: dict,
    *,
    api_key: str,
    timeout: float = 120,
) -> dict:
    """POST a JSON body with Bearer auth, return parsed JSON.
    Surfaces error body text on non-2xx so authors can read why
    the call failed."""
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        err_body = ""
        try:
            err_body = e.read().decode("utf-8", errors="replace")
        except Exception:
            pass
        raise RuntimeError(
            f"openai_images: HTTP {e.code} {e.reason} — {err_body[:500]}"
        ) from e
