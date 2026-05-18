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
    model_version: optional Tripo model version override (see below)
    style:         optional style preset
    texture:       bool — include PBR textures in the .glb (default true)
    pbr:           bool — generate PBR materials (default true)

Pure stdlib via urllib.request — no `requests` dep.

## model_version + pricing (verified 2026-05-17)

Available model_version strings (from official ComfyUI-Tripo node
+ Tripo OpenAPI docs):

  v1.4-20240625    legacy
  v2.0-20240919    legacy; seed param became deterministic from here
  v2.5-20250123    Tripo API DEFAULT if model_version omitted
  v3.0-20250812    sharper geometry, sculpture-level detail
  v3.1-20260211    current latest stable (recommended drop-in upgrade)
  P1-20260311      low-poly specialist for game assets (premium)

Tripo OpenAPI pricing (separate from Tripo Studio subscription):
  $0.01 per credit, 100-credit minimum top-up, 2000 free credits
  per first API-key generation.

Per-mesh credit cost (image-to-3D + texture + pbr):
  v2.5 / v3.0 / v3.1:  ~40 credits  = $0.40 / mesh
  P1:                  ~100 credits = $1.00 / mesh

Switching versions: drop `"model_version": "v3.1-20260211"` (or
similar) into backend_config.tripo3d. The ledger gates regen by
prompt_hash, NOT by model_version — switching alone won't force
regen of existing entries; nudge the prompt or remove specific
ledger entries to re-run.
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

    def supports_animation(self) -> bool:
        # ADR 0053: rig + retarget chain produces animated GLBs for
        # rig types {biped, quadruped, hexapod, octopod, avian,
        # serpentine, aquatic, others}.
        return True

    # Tripo's animation preset list (verified 2026-05-18 from
    # VAST-AI-Research/tripo-python-sdk/tripo3d/models.py:Animation).
    # Use these strings as the `animation` parameter of retarget tasks.
    ANIMATION_PRESETS = {
        "biped": [
            "preset:idle", "preset:walk", "preset:run",
            "preset:dive", "preset:climb", "preset:jump",
            "preset:slash", "preset:shoot", "preset:hurt",
            "preset:fall", "preset:turn",
        ],
        "quadruped": ["preset:quadruped:walk"],
        "hexapod": ["preset:hexapod:walk"],
        "octopod": ["preset:octopod:walk"],
        "avian": [],  # SDK doesn't enumerate; probe API at first use
        "serpentine": ["preset:serpentine:march"],
        "aquatic": ["preset:aquatic:march"],
        "others": [],  # SDK doesn't enumerate; fallback rig
    }

    RIG_TYPES = (
        "biped", "quadruped", "hexapod", "octopod",
        "avian", "serpentine", "aquatic", "others",
    )

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

    def generate_animated_mesh(
        self,
        prompt: str,
        out_dir: Path,
        rig_type: str,
        animation_clips: list[str],
        reference_image: Path | None = None,
    ) -> dict:
        """Run the full animation pipeline: image_to_model → prerigcheck →
        rig → N×retarget. Returns a dict describing per-stage outputs
        (caller is responsible for merging via glb_merge.py + ledger
        caching of intermediate task_ids).

        ADR 0053. This method makes paid API calls for every stage that
        isn't cached by the caller. Caller must consult
        tools/yume_assetgen/ledger.py before invoking.

        Returns:
            {
              "base_glb": Path,              # image_to_model output
              "base_task_id": str,
              "rig_task_id": str | None,     # None if prerigcheck failed
              "rig_glb": Path | None,
              "retarget_glbs": {              # clip_id → Path
                  "preset:walk": Path(...),
                  "preset:idle": Path(...),
              },
              "retarget_task_ids": {clip_id: str, ...},
              "riggable": bool,
            }

        Raises RuntimeError on submit/poll failure of base mesh stage.
        Failures in later stages (prerigcheck reject, rig reject) are
        returned as a partial dict with `riggable: False`; caller decides
        whether to fall back to static mesh or surface to user.
        """
        if rig_type not in self.RIG_TYPES:
            raise ValueError(
                f"tripo3d: rig_type={rig_type!r} not in {self.RIG_TYPES}"
            )
        api_key = self._get_api_key()
        out_dir.mkdir(parents=True, exist_ok=True)

        # Stage 1: base mesh (image_to_model preferred; falls back to text_to_model)
        if reference_image is not None and Path(reference_image).exists():
            file_token = self._upload_image(Path(reference_image), api_key)
            base_task_id = self._submit_image_to_model(file_token, prompt, api_key)
        else:
            base_task_id = self._submit_text_to_model(prompt, api_key)
        base_url = self._poll_until_done(base_task_id, api_key)
        base_glb = out_dir / f"{base_task_id}_base.glb"
        self._download(base_url, base_glb)

        result: dict = {
            "base_glb": base_glb,
            "base_task_id": base_task_id,
            "rig_task_id": None,
            "rig_glb": None,
            "retarget_glbs": {},
            "retarget_task_ids": {},
            "riggable": False,
        }

        # Stage 2: prerigcheck
        pre_task = self._submit_prerigcheck(base_task_id, api_key)
        pre_out = self._poll_for_status_dict(pre_task, api_key)
        riggable = bool(pre_out.get("riggable", False))
        result["riggable"] = riggable
        if not riggable:
            return result  # caller treats as "stay static, log + cache"

        # Stage 3: rig
        rig_task_id = self._submit_rig(base_task_id, rig_type, api_key)
        rig_url = self._poll_until_done(rig_task_id, api_key)
        rig_glb = out_dir / f"{rig_task_id}_rig.glb"
        self._download(rig_url, rig_glb)
        result["rig_task_id"] = rig_task_id
        result["rig_glb"] = rig_glb

        # Stage 4: retargets (per clip)
        for clip in animation_clips:
            re_task = self._submit_retarget(rig_task_id, clip, api_key)
            re_url = self._poll_until_done(re_task, api_key)
            safe_clip = clip.replace(":", "_")
            re_glb = out_dir / f"{rig_task_id}_{safe_clip}.glb"
            self._download(re_url, re_glb)
            result["retarget_glbs"][clip] = re_glb
            result["retarget_task_ids"][clip] = re_task

        return result

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
        # Confirmed via live test 2026-05-17: Tripo3D OpenAPI v2 expects
        # file as a dict with both `type` (lowercase, "png"/"jpg") and
        # `file_token` (returned from /upload's data.image_token or
        # data.file_token field). The bare-string + "image_token" top-
        # level shapes are rejected with 400.
        body = self._base_submit_body("image_to_model")
        body["file"] = {"type": "png", "file_token": file_token}
        if prompt:
            body["prompt"] = prompt
        return self._submit(body, api_key)

    # Animation pipeline (ADR 0053, 2026-05-18) — three task types chain
    # after image_to_model to produce a rigged + animated GLB:
    #   prerigcheck → rig → retarget(per-clip)
    # Each task is its own paid call. The orchestrator (generate_animated_mesh
    # below) wires them into a single pipeline that ledger.is_paid_backend()
    # respects + the ledger caches per task at the pipeline level (not here).

    def _submit_prerigcheck(self, model_task_id: str, api_key: str) -> str:
        """Submit a riggability check. Returns task_id; poll separately."""
        body = {
            "type": "animate_prerigcheck",
            "original_model_task_id": model_task_id,
        }
        return self._submit(body, api_key)

    def _submit_rig(
        self,
        model_task_id: str,
        rig_type: str,
        api_key: str,
    ) -> str:
        """Submit a rig task. rig_type ∈ {biped, quadruped, hexapod, octopod,
        avian, serpentine, aquatic, others} per the official SDK's RigType."""
        body: dict = {
            "type": "animate_rig",
            "original_model_task_id": model_task_id,
            "rig_type": rig_type,
            "spec": self.config.get("rig_spec", "tripo"),
            "out_format": "glb",
        }
        # Default rig model version per the SDK; override via config.
        rig_version = self.config.get("rig_model_version", "v1.0-20240301")
        if rig_version:
            body["model_version"] = rig_version
        return self._submit(body, api_key)

    def _submit_retarget(
        self,
        rig_task_id: str,
        animation: str,
        api_key: str,
    ) -> str:
        """Submit a retarget task. `animation` is a Tripo preset string
        like 'preset:walk' or 'preset:quadruped:walk' — see ADR 0053's
        animation-preset table."""
        body = {
            "type": "animate_retarget",
            "original_model_task_id": rig_task_id,
            "animation": animation,
            "bake_animation": True,
            "out_format": "glb",
        }
        return self._submit(body, api_key)

    def _poll_for_status_dict(self, task_id: str, api_key: str) -> dict:
        """Like _poll_until_done but returns the full success blob's
        output dict rather than a URL. Used for prerigcheck (no URL,
        only a `riggable` boolean) and rig tasks (need both URL + extra
        metadata like joint count if Tripo exposes it)."""
        interval = float(self.config.get("poll_interval", self.DEFAULT_POLL_INTERVAL))
        timeout = float(self.config.get("timeout", self.DEFAULT_TIMEOUT))
        deadline = time.time() + timeout
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
            if status == "success":
                return blob.get("output", {})
            if status in ("failed", "cancelled", "expired", "banned"):
                err = blob.get("error", blob.get("message", "no detail"))
                raise RuntimeError(
                    f"tripo3d: task {task_id} ended status={status} — {err}"
                )
            time.sleep(interval)
        raise RuntimeError(
            f"tripo3d: task {task_id} did not complete within {timeout}s"
        )

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
        """Upload `path` to Tripo3D's upload endpoint, return file_token.
        Uses stdlib multipart encoding — no `requests` dep.

        Confirmed via live test 2026-05-17: the endpoint is
        /v2/openapi/upload (NOT /upload/sts as the spec page name
        suggests — STS is the internal storage backend, but the
        public endpoint is /upload). Response shape:
            {"code": 0, "data": {"image_token": "<uuid>"}}
        Older docs use "file_token"; we accept either."""
        url = f"{self.API_BASE}/upload"
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
        # Tripo3D returns the upload token as either `image_token`
        # (v2.5+) or `file_token` (older). Accept both.
        ddata = data.get("data", {}) or {}
        file_token = (
            ddata.get("image_token")
            or ddata.get("file_token")
            or data.get("image_token")
            or data.get("file_token")
        )
        if not file_token:
            raise RuntimeError(f"tripo3d: upload returned no token: {data}")
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
