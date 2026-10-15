"""
tripo3d.py — Tripo3D text-to-3D + image-to-3D backend (Tripo API V3).

Tripo3D is an async generation service: submit a task, get a task_id,
poll until success/failure, then download the resulting .glb from a
signed URL (valid about 24 h).

API spec: V3. The move from V2 was on 2026-10-16, because Tripo is
closing V2. Source: the developers.tripo3d.com tripo-v2-to-v3-migration
guide.
    Base:   https://openapi.tripo3d.ai/v3   Authorization: Bearer <API_KEY>
    Submit: POST /generation/text-to-model   {"prompt", "model_version", ...}
            POST /generation/image-to-model  {"file": {"type", "file_token"}, ...}
            POST /animations/rig-check       {"original_model_task_id"}
            POST /animations/rig             {"original_model_task_id", "rig_type", ...}
            POST /animations/retarget        {"original_model_task_id", "animation", ...}
            → {"code": 0, "data": {"task_id": "..."}}
    Poll:   GET /tasks/<task_id>
            → {"data": {"status": "queued"|"running"|"success"|"failed"|"cancelled",
                        "output": {"model_url": "<url>", "riggable": bool},
                        "error_code", "error_message"}}
    Upload: POST /files (multipart, field `file`) → {"data": {"file_token": "file_..."}}

V3 differences that matter here:
- No `type` field. Each task type has its own endpoint.
- `model_version` is REQUIRED for 3D generation.
- The upload token key is `file_token`.
- The model URL is `output.model_url`.
- `banned` and `expired` are now `failed`, with `error_code` 2008 or 2018.

Config (backend_config.tripo3d):
    api_key_env:   env var name (default TRIPO_API_KEY)
    poll_interval: seconds between status checks (default 5)
    timeout:       total seconds to wait for completion (default 600)
    model_version: 3D model version (default v2.5-20250123, the V2 server
                   default). V3 allows v3.1-20260211, v3.0-20250812,
                   v2.5-20250123 and P1-20260311.
    style:         optional style preset
    texture:       bool — include PBR textures in the .glb (default true)
    pbr:           bool — generate PBR materials (default true)
    rig_model_version: rig version (default v1.0-20240301, or v2.5-20260210)

Paid-work protection (2026-10-16, batch B):
- `task_slot` (a ledger.TaskSlot) records the task id right after
  submit. A later run resumes that task instead of paying again.
- A poll retries network errors and 429 / 5xx until the deadline. Only a
  task that ENDS failed or cancelled raises TripoTaskFailed. Tripo
  refunds those, so the caller drops the pending entry.
- A submit retries only 429 / 5xx answers. A submit that times out is
  never retried, because Tripo can have created (and charged) the task.

Pure stdlib via urllib.request — no `requests` dep.

## Pricing (verified 2026-05-17)

$0.01 per credit. Image-to-3D + texture + pbr: about 40 credits
($0.40) for v2.5 / v3.0 / v3.1, about 100 credits ($1.00) for P1.
"""

import json
import mimetypes
import os
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from .base import Backend, http_error, is_retryable


class TripoTaskFailed(RuntimeError):
    """The task ended `failed` or `cancelled`. Tripo refunds its credits,
    so a new submit does not pay twice."""


class Tripo3DBackend(Backend):
    """Tripo3D text/image → .glb mesh generator (async, polling)."""

    API_BASE = "https://openapi.tripo3d.ai/v3"
    DEFAULT_MODEL_VERSION = "v2.5-20250123"
    DEFAULT_POLL_INTERVAL = 5
    DEFAULT_TIMEOUT = 600  # 10 minutes; mesh gen routinely takes 2-5 min
    SUBMIT_ATTEMPTS = 3

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
        task_slot=None,
    ) -> Path:
        """Generate a .glb from the prompt.

        If `reference_image` is set, uses image-to-model mode
        (Tripo3D matches the mesh to the image). Else uses
        text-to-model mode.
        """
        api_key = self._get_api_key()

        def submit() -> str:
            if reference_image is not None and Path(reference_image).exists():
                file_token = self._upload_image(Path(reference_image), api_key)
                return self._submit_image_to_model(
                    file_token, prompt, api_key, image_type(Path(reference_image))
                )
            return self._submit_text_to_model(prompt, api_key)

        task_id = self.run_task(submit, task_slot)
        result_url = self._wait(task_id, api_key, task_slot, self._model_url)
        self._download(result_url, out_path)
        return out_path

    def run_task(self, submit, task_slot=None) -> str:
        """Return the task id from `task_slot`, or submit a new task and
        record its id in the slot before any poll."""
        if task_slot is not None:
            task_id = task_slot.get()
            if task_id:
                return task_id
        task_id = submit()
        if task_slot is not None:
            task_slot.put(task_id)
        return task_id

    def wait_url(self, task_id: str, api_key: str, task_slot=None) -> str:
        """Poll a model-producing task to success, return its model URL."""
        return self._wait(task_id, api_key, task_slot, self._model_url)

    def wait_output(self, task_id: str, api_key: str, task_slot=None) -> dict:
        """Poll a task to success, return its `output` dict (rig-check)."""
        return self._wait(task_id, api_key, task_slot, lambda blob: blob.get("output", {}))

    # ------------------------------------------------------------
    # Submit tasks
    # ------------------------------------------------------------

    def _submit_text_to_model(self, prompt: str, api_key: str) -> str:
        body = self._generation_body()
        body["prompt"] = prompt
        return self._submit("/generation/text-to-model", body, api_key)

    def _submit_image_to_model(
        self, file_token: str, prompt: str, api_key: str, file_type: str = "png"
    ) -> str:
        # V3 keeps the V2 file object: {"type", "file_token"}. The token
        # comes from POST /files (`file_<uuid>`). image-to-model takes no
        # `prompt` field (migration guide A.2), so the prompt is unused.
        body = self._generation_body()
        body["file"] = {"type": file_type, "file_token": file_token}
        return self._submit("/generation/image-to-model", body, api_key)

    # Animation pipeline (ADR 0053, 2026-05-18). Three task types follow
    # image-to-model and make a rigged, animated GLB:
    #   rig-check → rig → retarget (one per clip)
    # Each task is its own paid call. animate_smoke.py runs the chain and
    # gives each stage its own ledger TaskSlot.

    def _submit_prerigcheck(self, model_task_id: str, api_key: str) -> str:
        """Submit a riggability check. Returns task_id; poll separately."""
        body = {"original_model_task_id": model_task_id}
        return self._submit("/animations/rig-check", body, api_key)

    def _submit_rig(
        self,
        model_task_id: str,
        rig_type: str,
        api_key: str,
    ) -> str:
        """Submit a rig task. rig_type ∈ {biped, quadruped, hexapod, octopod,
        avian, serpentine, aquatic, others} per the official SDK's RigType."""
        if rig_type not in self.RIG_TYPES:
            raise ValueError(f"tripo3d: rig_type={rig_type!r} not in {self.RIG_TYPES}")
        body: dict = {
            "original_model_task_id": model_task_id,
            "rig_type": rig_type,
            "spec": self.config.get("rig_spec", "tripo"),
            "out_format": "glb",
            "model_version": self.config.get("rig_model_version", "v1.0-20240301"),
        }
        return self._submit("/animations/rig", body, api_key)

    def _submit_retarget(
        self,
        rig_task_id: str,
        animation: str,
        api_key: str,
        animate_in_place: bool = True,
    ) -> str:
        """Submit a retarget task. `animation` is a Tripo preset string
        like 'preset:walk' or 'preset:quadruped:walk' — see ADR 0053's
        animation-preset table.

        `animate_in_place=True` (default for Yume) strips root translation
        from the clip so the rig's root bone stays at origin throughout the
        cycle. The game engine drives world-space translation via
        state.velocity / pathfind_to; the animation only moves limbs. If
        False (Tripo default), the rig translates forward during the walk
        cycle, producing a "jump-then-stop" artifact when Yume's engine ALSO
        drives translation (double-counted motion + clip ends mid-step).

        Empirical case 2026-05-18: player_marken + morwen walked one cycle
        then froze. Two bugs: clip not looping (fixed engine-side) + root
        motion baked in (fixed by flipping this default to True).
        """
        body = {
            "original_model_task_id": rig_task_id,
            "animation": animation,
            "bake_animation": True,
            "animate_in_place": animate_in_place,
            "out_format": "glb",
        }
        return self._submit("/animations/retarget", body, api_key)

    def _generation_body(self) -> dict:
        body: dict = {
            "model_version": self.config.get("model_version", self.DEFAULT_MODEL_VERSION),
        }
        if "style" in self.config:
            body["style"] = self.config["style"]
        if "texture" in self.config:
            body["texture"] = bool(self.config["texture"])
        if "pbr" in self.config:
            body["pbr"] = bool(self.config["pbr"])
        return body

    def _submit(self, path: str, body: dict, api_key: str) -> str:
        """POST a task. Retries only a 429 / 5xx answer, with backoff."""
        for attempt in range(self.SUBMIT_ATTEMPTS):
            try:
                data = _post_json(
                    f"{self.API_BASE}{path}",
                    body,
                    headers={"Authorization": f"Bearer {api_key}"},
                    timeout=60,
                )
                break
            except Exception as e:
                if not is_retryable(e) or attempt == self.SUBMIT_ATTEMPTS - 1:
                    raise
                time.sleep(2.0 * (attempt + 1))
        task_id = (data.get("data") or {}).get("task_id")
        if not task_id:
            raise RuntimeError(f"tripo3d: submit failed: {data}")
        return task_id

    # ------------------------------------------------------------
    # Upload image (for image-to-model)
    # ------------------------------------------------------------

    def _upload_image(self, path: Path, api_key: str) -> str:
        """Upload `path` to POST /files, return its `file_token`.
        Uses stdlib multipart encoding — no `requests` dep. Uploads cost
        nothing, so a 429 (V3 allows about 10 uploads per minute) retries."""
        ctype, _ = mimetypes.guess_type(path.name)
        ctype = ctype or "application/octet-stream"
        body, content_type = _encode_multipart(
            "file", path.name, ctype, path.read_bytes()
        )
        for attempt in range(self.SUBMIT_ATTEMPTS):
            req = urllib.request.Request(
                f"{self.API_BASE}/files",
                data=body,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": content_type,
                },
            )
            try:
                with urllib.request.urlopen(req, timeout=120) as resp:
                    data = json.load(resp)
                break
            except urllib.error.HTTPError as e:
                err = http_error("tripo3d", e, "/files")
                if not err.retryable or attempt == self.SUBMIT_ATTEMPTS - 1:
                    raise err from e
                time.sleep(6.0 * (attempt + 1))
        file_token = (data.get("data") or {}).get("file_token")
        if not file_token:
            raise RuntimeError(f"tripo3d: upload returned no file_token: {data}")
        return file_token

    # ------------------------------------------------------------
    # Poll + download
    # ------------------------------------------------------------

    @staticmethod
    def _model_url(blob: dict) -> str:
        url = (blob.get("output") or {}).get("model_url")
        if not url:
            raise RuntimeError(f"tripo3d: success status but no output.model_url: {blob}")
        return url

    def _wait(self, task_id: str, api_key: str, task_slot, on_success):
        """Poll until a terminal status. A transient error (network, 429,
        5xx) waits and polls again. A failed or cancelled task drops the
        slot and raises TripoTaskFailed. A timeout keeps the slot, so the
        next run resumes the same task."""
        interval = float(self.config.get("poll_interval", self.DEFAULT_POLL_INTERVAL))
        timeout = float(self.config.get("timeout", self.DEFAULT_TIMEOUT))
        deadline = time.time() + timeout
        last_status = ""
        last_error = ""
        while time.time() < deadline:
            try:
                blob = self._get_task(task_id, api_key)
            except Exception as e:
                if not (is_retryable(e) or isinstance(e, (urllib.error.URLError, TimeoutError))):
                    raise
                last_error = str(e)
                time.sleep(interval)
                continue
            last_status = str(blob.get("status", "")).lower()
            if last_status == "success":
                return on_success(blob)
            if last_status not in ("queued", "running"):
                # V3 has 5 states. Any other value counts as failed.
                if task_slot is not None:
                    task_slot.drop()
                raise TripoTaskFailed(
                    f"tripo3d: task {task_id} ended status={last_status} "
                    f"error_code={blob.get('error_code')} — {blob.get('error_message', 'no detail')}"
                )
            time.sleep(interval)
        raise RuntimeError(
            f"tripo3d: task {task_id} did not complete within {timeout}s "
            f"(last status: {last_status or '?'}; last error: {last_error or 'none'}). "
            f"The ledger keeps the task id, so the next run resumes it."
        )

    def _get_task(self, task_id: str, api_key: str) -> dict:
        req = urllib.request.Request(
            f"{self.API_BASE}/tasks/{task_id}",
            headers={"Authorization": f"Bearer {api_key}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.load(resp)
        except urllib.error.HTTPError as e:
            raise http_error("tripo3d", e, f"/tasks/{task_id}") from e
        return data.get("data", data)

    def _download(self, url: str, out_path: Path) -> None:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            with urllib.request.urlopen(url, timeout=300) as resp:
                data = resp.read()
        except urllib.error.HTTPError as e:
            raise http_error("tripo3d", e, "download") from e
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


def image_type(path: Path) -> str:
    """The `file.type` of an image from its magic bytes, not its name.
    Gemini can write JPEG bytes to a `.png` name (memory note)."""
    head = path.read_bytes()[:12]
    if head.startswith(b"\xff\xd8"):
        return "jpg"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    return "png"


def _post_json(
    url: str,
    body: dict,
    *,
    headers: dict | None = None,
    timeout: float = 60,
) -> dict:
    """POST a JSON body, parse JSON response. Raises BackendHTTPError."""
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
        raise http_error("tripo3d", e, url.rsplit("/v3", 1)[-1]) from e


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
