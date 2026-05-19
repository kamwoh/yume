"""
nanobanana.py — Google Gemini 2.5 Flash Image backend.

"nanobanana" is the colloquial name for Google's Gemini 2.5 Flash
Image generation model. It's an image-out modality of Gemini's
multimodal API: text (+optional image references) → PNG bytes.

Used for:
    - albedo textures (visual.albedo_texture_prompt)
    - per-surface textures (material_overrides.<surface>.albedo_texture_prompt)
    - concept reference images (visual.mesh_reference_prompt) that the
      pipeline THEN hands to Tripo3D as an image-to-3D ref

API spec (current as of 2026-05):
    POST https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent?key=<API_KEY>
    Body:
      {
        "contents": [{"parts": [{"text": "<prompt>"},
                                {"inlineData": {...}}  // optional ref images
                               ]}],
        "generationConfig": {"responseModalities": ["IMAGE"]}
      }
    Response:
      candidates[0].content.parts[i].inlineData.{mimeType, data}
        data is base64-encoded PNG bytes.

Config (backend_config.nanobanana):
    api_key_env: env var name holding the key (default GEMINI_API_KEY)
    model: model id override (default gemini-2.5-flash-image)
    timeout: request timeout in seconds (default 120)

Pure stdlib via urllib.request — no `requests` dep.
"""

import base64
import json
import os
import urllib.error
import urllib.request
from pathlib import Path
from typing import Iterable

from .base import Backend


class NanobananaBackend(Backend):
    """Gemini 2.5 Flash Image text-to-image (with optional ref images)."""

    DEFAULT_MODEL = "gemini-2.5-flash-image"
    API_BASE = "https://generativelanguage.googleapis.com/v1beta"

    def name(self) -> str:
        return "nanobanana"

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
        size: Iterable[int] = (512, 512),
        reference_images: list[Path] | None = None,
    ) -> Path:
        """Generate a PNG from the prompt.

        `reference_images` is an optional list of paths to images
        passed alongside the text prompt (multimodal input). Gemini
        accepts up to a few inline images per request. Useful for
        style transfer / variation runs.

        `size` is advisory — Gemini's flash image model chooses its
        own resolution. Authors can post-process if a specific size
        is needed.
        """
        api_key = self._get_api_key()
        model = self.config.get("model", self.DEFAULT_MODEL)
        url = f"{self.API_BASE}/models/{model}:generateContent?key={api_key}"

        parts: list[dict] = [{"text": prompt}]
        for ref in (reference_images or []):
            ref_p = Path(ref)
            if not ref_p.exists():
                continue
            parts.append({
                "inlineData": {
                    "mimeType": _mime_for(ref_p),
                    "data": base64.b64encode(ref_p.read_bytes()).decode("ascii"),
                }
            })

        gen_cfg: dict = {"responseModalities": ["IMAGE"]}
        # Aspect ratio override (2026-05-19). Gemini 3.x image-preview
        # models accept `imageConfig.aspectRatio` inside generationConfig
        # with one of {"1:1", "16:9", "9:16", "4:3", "3:4"}. gemini-2.5-
        # flash-image ignores this field and stays at 1024×1024.
        ar = self.config.get("aspect_ratio")
        if ar:
            gen_cfg["imageConfig"] = {"aspectRatio": ar}
        body = {
            "contents": [{"parts": parts}],
            "generationConfig": gen_cfg,
        }

        timeout = float(self.config.get("timeout", 120))
        data = _post_json(url, body, timeout=timeout)

        # Extract the first image part from the candidates.
        candidates = data.get("candidates", [])
        if not candidates:
            raise RuntimeError(f"nanobanana: no candidates in response: {data}")
        resp_parts = candidates[0].get("content", {}).get("parts", [])
        for p in resp_parts:
            inline = p.get("inlineData") or p.get("inline_data")
            if not inline:
                continue
            mime = inline.get("mimeType") or inline.get("mime_type", "")
            if not mime.startswith("image/"):
                continue
            img_b64 = inline.get("data", "")
            img_bytes = base64.b64decode(img_b64)
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_bytes(img_bytes)
            return out_path

        # No image part found — likely the safety filter triggered or
        # the prompt resolved to text-only output.
        finish_reason = candidates[0].get("finishReason", "")
        raise RuntimeError(
            f"nanobanana: no image in response (finishReason={finish_reason}). "
            f"Check the prompt for safety filter triggers."
        )

    # ------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------

    def _get_api_key(self) -> str:
        env_var = self.config.get("api_key_env", "GEMINI_API_KEY")
        key = os.environ.get(env_var, "").strip()
        if not key:
            raise RuntimeError(
                f"nanobanana: env var {env_var} is empty. "
                f"Set GEMINI_API_KEY or override via backend_config.nanobanana.api_key_env."
            )
        return key


def _mime_for(path: Path) -> str:
    suffix = path.suffix.lower()
    return {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webp": "image/webp",
    }.get(suffix, "application/octet-stream")


def _post_json(url: str, body: dict, *, timeout: float = 120) -> dict:
    """POST a JSON body and parse the JSON response. Surfaces error
    body text on non-2xx so authors can read why the call failed."""
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
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
            f"nanobanana: HTTP {e.code} {e.reason} — {err_body[:500]}"
        ) from e
