"""
tripo3d.py — Tripo3D text-to-3D + image-to-3D backend.

Tripo3D is an async generation service: submit a task, get a task_id,
poll until success/failure, then download the resulting .glb from a
signed URL.

API spec (current as of 2026-05, v2 openapi):
    Submit task:
        POST https://api.tripo3d.ai/v2/openapi/task
        Authorization: Bearer <API_KEY>
        Body:
          {"type": "text_to_model", "prompt": "..."}
          or
          {"type": "image_to_model", "file": {"file_token": "..."}, "prompt": "..."}

    Poll task:
        GET https://api.tripo3d.ai/v2/openapi/task/<task_id>
        Authorization: Bearer <API_KEY>
        Response: {"data": {"status": "queued"|"running"|"success"|"failed",
                            "output": {"pbr_model": "<url>"}, ...}}

    Image upload (for image_to_model):
        POST https://api.tripo3d.ai/v2/openapi/upload/sts
        Authorization: Bearer <API_KEY>
        multipart/form-data with `file` field
        Response: {"data": {"file_token": "..."}}

Config (backend_config.tripo3d):
    api_key_env:   env var name (default TRIPO_API_KEY)
    poll_interval: seconds between status checks (default 5)
    timeout:       total seconds to wait for completion (default 600)
    model_version: optional Tripo model version override
    style:         optional style preset
    texture:       bool — include PBR textures in the .glb (default true)

Pure stdlib via urllib.request — no `requests` dep.
"""

import json
import mimetypes
import os
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from .base import Backend


class Tripo3DBackend(Backend):
    """Tripo3D text/image → .glb mesh generator (async, polling)."""

    API_BASE = "https://api.tripo3d.ai/v2/openapi"
    DEFAULT_POLL_INTERVAL = 5
    DEFAULT_TIMEOUT = 600  # 10 minutes; mesh gen routinely takes 2-5 min

    def name(self) -> str:
        return "tripo3d"

    def supports_texture(self) -> bool:
        # Tripo3D's output .glb has baked-in textures, but loose PNG
        # texture extraction is not its product. For loose textures,
        # use nanobanana.
        return False

    def supports_mesh(self) -> bool:
        return True

    # ------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------

    def generate_mesh(
        self,
        prompt: str,
        out_path: Path,
        reference_image: Path | None = None,
    ) -> Path:
        """Generate a .glb from the prompt.

        If `reference_image` is set, uses image-to-model mode
        (Tripo3D matches the mesh to the image). Else uses
        text-to-model mode.
        """
        api_key = self._get_api_key()
        if reference_image is not None and Path(reference_image).exists():
            file_token = self._upload_image(Path(reference_image), api_key)
            task_id = self._submit_image_to_model(file_token, prompt, api_key)
        else:
            task_id = self._submit_text_to_model(prompt, api_key)
        result_url = self._poll_until_done(task_id, api_key)
        self._download(result_url, out_path)
        return out_path

    # ------------------------------------------------------------
    # Submit tasks
    # ------------------------------------------------------------

    def _submit_text_to_model(self, prompt: str, api_key: str) -> str:
        body = self._base_submit_body("text_to_model")
        body["prompt"] = prompt
        return self._submit(body, api_key)

    def _submit_image_to_model(
        self, file_token: str, prompt: str, api_key: str
    ) -> str:
        body = self._base_submit_body("image_to_model")
        body["file"] = {"file_token": file_token}
        if prompt:
            body["prompt"] = prompt
        return self._submit(body, api_key)

    def _base_submit_body(self, task_type: str) -> dict:
        body: dict = {"type": task_type}
        if "model_version" in self.config:
            body["model_version"] = self.config["model_version"]
        if "style" in self.config:
            body["style"] = self.config["style"]
        if "texture" in self.config:
            body["texture"] = bool(self.config["texture"])
        if "pbr" in self.config:
            body["pbr"] = bool(self.config["pbr"])
        return body

    def _submit(self, body: dict, api_key: str) -> str:
        data = _post_json(
            f"{self.API_BASE}/task",
            body,
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=60,
        )
        task_id = (
            data.get("data", {}).get("task_id")
            or data.get("task_id")  # API has had both shapes
        )
        if not task_id:
            raise RuntimeError(f"tripo3d: submit failed: {data}")
        return task_id

    # ------------------------------------------------------------
    # Upload image (for image_to_model)
    # ------------------------------------------------------------

    def _upload_image(self, path: Path, api_key: str) -> str:
        """Upload `path` to Tripo3D's STS endpoint, return file_token.
        Uses stdlib multipart encoding — no `requests` dep."""
        url = f"{self.API_BASE}/upload/sts"
        ctype, _ = mimetypes.guess_type(path.name)
        ctype = ctype or "application/octet-stream"
        body, content_type = _encode_multipart(
            "file", path.name, ctype, path.read_bytes()
        )
        req = urllib.request.Request(
            url,
            data=body,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": content_type,
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = json.load(resp)
        except urllib.error.HTTPError as e:
            err = ""
            try:
                err = e.read().decode("utf-8", errors="replace")
            except Exception:
                pass
            raise RuntimeError(
                f"tripo3d upload: HTTP {e.code} {e.reason} — {err[:500]}"
            ) from e
        file_token = (
            data.get("data", {}).get("file_token") or data.get("file_token")
        )
        if not file_token:
            raise RuntimeError(f"tripo3d: upload returned no file_token: {data}")
        return file_token

    # ------------------------------------------------------------
    # Poll + download
    # ------------------------------------------------------------

    def _poll_until_done(self, task_id: str, api_key: str) -> str:
        interval = float(self.config.get("poll_interval", self.DEFAULT_POLL_INTERVAL))
        timeout = float(self.config.get("timeout", self.DEFAULT_TIMEOUT))
        deadline = time.time() + timeout
        last_status = ""
        while time.time() < deadline:
            req = urllib.request.Request(
                f"{self.API_BASE}/task/{task_id}",
                headers={"Authorization": f"Bearer {api_key}"},
            )
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    data = json.load(resp)
            except urllib.error.HTTPError as e:
                raise RuntimeError(
                    f"tripo3d poll: HTTP {e.code} {e.reason} (task {task_id})"
                ) from e
            blob = data.get("data", data)
            status = str(blob.get("status", "")).lower()
            if status != last_status:
                last_status = status
            if status == "success":
                output = blob.get("output", {})
                # Prefer pbr_model (textured), fall back to base model.
                url = (
                    output.get("pbr_model")
                    or output.get("model")
                    or output.get("rendered_image")
                )
                if not url:
                    raise RuntimeError(
                        f"tripo3d: success status but no model URL: {blob}"
                    )
                return url
            if status in ("failed", "cancelled", "expired", "banned"):
                err = blob.get("error", blob.get("message", "no detail"))
                raise RuntimeError(
                    f"tripo3d: task {task_id} ended status={status} — {err}"
                )
            time.sleep(interval)
        raise RuntimeError(
            f"tripo3d: task {task_id} did not complete within {timeout}s "
            f"(last status: {last_status})"
        )

    def _download(self, url: str, out_path: Path) -> None:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            with urllib.request.urlopen(url, timeout=300) as resp:
                data = resp.read()
        except urllib.error.HTTPError as e:
            raise RuntimeError(
                f"tripo3d download: HTTP {e.code} {e.reason} for {url}"
            ) from e
        out_path.write_bytes(data)

    # ------------------------------------------------------------
    # Misc
    # ------------------------------------------------------------

    def _get_api_key(self) -> str:
        env_var = self.config.get("api_key_env", "TRIPO_API_KEY")
        key = os.environ.get(env_var, "").strip()
        if not key:
            raise RuntimeError(
                f"tripo3d: env var {env_var} is empty. "
                f"Set TRIPO_API_KEY or override via backend_config.tripo3d.api_key_env."
            )
        return key


# ============================================================
# HELPERS
# ============================================================


def _post_json(
    url: str,
    body: dict,
    *,
    headers: dict | None = None,
    timeout: float = 60,
) -> dict:
    """POST a JSON body, parse JSON response. Surfaces error body."""
    h = {"Content-Type": "application/json"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"), headers=h
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        err = ""
        try:
            err = e.read().decode("utf-8", errors="replace")
        except Exception:
            pass
        raise RuntimeError(
            f"tripo3d: HTTP {e.code} {e.reason} — {err[:500]}"
        ) from e


def _encode_multipart(
    field: str, filename: str, ctype: str, data: bytes
) -> tuple[bytes, str]:
    """Encode a single-file multipart/form-data body. Returns
    (body_bytes, content_type_header)."""
    boundary = "----yume-assetgen-" + uuid.uuid4().hex
    crlf = b"\r\n"
    parts = [
        f"--{boundary}".encode(),
        f'Content-Disposition: form-data; name="{field}"; filename="{filename}"'.encode(),
        f"Content-Type: {ctype}".encode(),
        b"",
        data,
        f"--{boundary}--".encode(),
        b"",
    ]
    body = crlf.join(parts)
    return body, f"multipart/form-data; boundary={boundary}"
