"""
openai_images.py — OpenAI gpt-image-2 backend.

Two endpoints, dispatched by presence of reference_images:

- `/v1/images/generations` (JSON body) — text-only generation.
  Used when no reference_images are supplied. Returns base64 PNG.

- `/v1/images/edits` (multipart/form-data) — image-conditioned
  generation. Used when one or more reference_images are supplied.
  gpt-image-2 processes input images at automatic high fidelity;
  prompt directs the transformation. Returns base64 PNG.

Per https://developers.openai.com/api/docs/models/gpt-image-2
the model accepts text + image input on the edits endpoint.

Used for:
    - albedo textures (text-only)
    - per-surface textures (text-only)
    - concept reference images
    - flat-color semantic maps DERIVED from a photoreal reference
      (image-conditioned) — preserves layout while changing style

Config (backend_config.openai_images):
    api_key_env: env var name (default OPENAI_API_KEY)
    model: model id override (default gpt-image-2-2026-04-21)
    quality: low / medium / high / auto (default "high")
    default_size: fallback "<W>x<H>" (default "1024x1024")
    timeout: request timeout in seconds (default 120)

Pure stdlib via urllib.request — no `openai` SDK dependency. Multipart
upload built manually to keep the dep surface zero.
"""

import base64
import json
import os
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Iterable

from .base import Backend


# gpt-image-2 accepts these exact size strings.
SUPPORTED_SIZES = [
    (1024, 1024),
    (1024, 1536),
    (1536, 1024),
]


def _size_to_string(size: Iterable[int], default: str = "1024x1024") -> str:
    """Map (W, H) to the nearest supported size string."""
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


def _mime_for(path: Path) -> str:
    return {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webp": "image/webp",
    }.get(path.suffix.lower(), "application/octet-stream")


class OpenAIImagesBackend(Backend):
    """OpenAI gpt-image-2 text-to-image (+ image-to-image via /edits)."""

    DEFAULT_MODEL = "gpt-image-2-2026-04-21"
    GENERATIONS_URL = "https://api.openai.com/v1/images/generations"
    EDITS_URL = "https://api.openai.com/v1/images/edits"

    def name(self) -> str:
        return "openai_images"

    def supports_texture(self) -> bool:
        return True

    def supports_mesh(self) -> bool:
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

        Dispatch:
          - reference_images NOT given → /v1/images/generations (text-only)
          - reference_images given     → /v1/images/edits (image-conditioned)

        `size` is mapped to the nearest supported value
        (1024x1024 / 1024x1536 / 1536x1024).
        """
        api_key = self._get_api_key()
        model = self.config.get("model", self.DEFAULT_MODEL)
        quality = self.config.get("quality", "high")
        size_str = _size_to_string(
            size, default=self.config.get("default_size", "1024x1024")
        )
        timeout = float(self.config.get("timeout", 120))

        if reference_images:
            data = self._call_edits(
                prompt=prompt,
                refs=[Path(r) for r in reference_images if Path(r).exists()],
                api_key=api_key,
                model=model,
                quality=quality,
                size_str=size_str,
                timeout=timeout,
            )
        else:
            data = self._call_generations(
                prompt=prompt,
                api_key=api_key,
                model=model,
                quality=quality,
                size_str=size_str,
                timeout=timeout,
            )

        items = data.get("data", [])
        if not items:
            raise RuntimeError(
                f"openai_images: empty data in response: {data}"
            )
        b64 = items[0].get("b64_json", "")
        if not b64:
            url = items[0].get("url", "")
            if url:
                raise RuntimeError(
                    f"openai_images: got URL response (model returned "
                    f"`url` not `b64_json`). Configure the model to "
                    f"return b64 or fetch the URL manually: {url}"
                )
            raise RuntimeError(
                f"openai_images: no b64_json in first data item: {items[0]}"
            )

        img_bytes = base64.b64decode(b64)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(img_bytes)
        return out_path

    # ------------------------------------------------------------
    # Endpoint dispatchers
    # ------------------------------------------------------------

    def _call_generations(
        self, *, prompt, api_key, model, quality, size_str, timeout
    ) -> dict:
        """Text-only via /v1/images/generations."""
        body = {
            "model": model,
            "prompt": prompt,
            "n": 1,
            "size": size_str,
            "quality": quality,
            "output_format": "png",
        }
        return _post_json(
            self.GENERATIONS_URL,
            body,
            api_key=api_key,
            timeout=timeout,
        )

    def _call_edits(
        self,
        *,
        prompt,
        refs: list[Path],
        api_key,
        model,
        quality,
        size_str,
        timeout,
    ) -> dict:
        """Image-conditioned via /v1/images/edits (multipart upload).

        Per the gpt-image-2 docs, the model processes input images at
        automatic high fidelity; the prompt directs the transformation.
        Multiple `image` fields are accepted — repeat the form name.

        `input_fidelity` is intentionally NOT sent: the docs state
        gpt-image-2 ignores it (uses high fidelity automatically).
        """
        if not refs:
            raise RuntimeError("openai_images: edits called with no refs")

        fields = {
            "model": model,
            "prompt": prompt,
            "n": "1",
            "size": size_str,
            "quality": quality,
            "output_format": "png",
        }
        files = [
            ("image", r.name, _mime_for(r), r.read_bytes())
            for r in refs
        ]
        body, content_type = _build_multipart(fields, files)

        req = urllib.request.Request(
            self.EDITS_URL,
            data=body,
            headers={
                "Content-Type": content_type,
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
                f"openai_images: HTTP {e.code} {e.reason} on /edits — {err_body[:500]}"
            ) from e

    # ------------------------------------------------------------
    # Helpers
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
    """POST a JSON body with Bearer auth, return parsed JSON."""
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


def _build_multipart(
    fields: dict[str, str],
    files: list[tuple[str, str, str, bytes]],
) -> tuple[bytes, str]:
    """Build a multipart/form-data body. Pure stdlib, no `requests`.

    fields: dict of {name: value} for plain string parts.
    files:  list of (form_name, filename, mime, bytes). Repeating
            `form_name` (e.g. "image") sends multiple files under
            the same field, which is how OpenAI accepts multiple
            reference images.

    Returns (body_bytes, content_type_with_boundary).
    """
    boundary = f"----yume{uuid.uuid4().hex}"
    bnd = boundary.encode("ascii")
    chunks: list[bytes] = []
    for k, v in fields.items():
        chunks.append(b"--" + bnd + b"\r\n")
        chunks.append(f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode())
        chunks.append(str(v).encode("utf-8"))
        chunks.append(b"\r\n")
    for name, filename, mime, data in files:
        chunks.append(b"--" + bnd + b"\r\n")
        chunks.append(
            f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
            f"Content-Type: {mime}\r\n\r\n".encode()
        )
        chunks.append(data)
        chunks.append(b"\r\n")
    chunks.append(b"--" + bnd + b"--\r\n")
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"
