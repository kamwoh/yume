"""
test_paid_work.py — batch B (2026-10-16): the Tripo V3 calls and the
protection against paying twice. No network: a fake V3 server replaces
urllib in the tripo3d module.

Run:  python3 -m pytest tools/yume_assetgen/tests/test_paid_work.py
"""

import io
import json
import urllib.error
from pathlib import Path

import pytest

from tools.yume_assetgen.backends import base, tripo3d
from tools.yume_assetgen.backends.tripo3d import Tripo3DBackend, TripoTaskFailed
from tools.yume_assetgen.ledger import is_paid_backend, load_ledger, prompt_hash


class FakeV3:
    """Answers the V3 routes. `script` maps a route to a list of answers:
    a dict (JSON body), an int (HTTP error status) or an exception."""

    def __init__(self, script):
        self.script = {k: list(v) for k, v in script.items()}
        self.calls = []

    def urlopen(self, req, timeout=None):
        url = req if isinstance(req, str) else req.full_url
        body = None if isinstance(req, str) or req.data is None else req.data
        route = url.split("/v3", 1)[-1] if "/v3" in url else url
        self.calls.append((route, body))
        answers = self.script.get(route) or self.script.get(route.split("/")[1] if route.startswith("/") else route)
        if not answers:
            raise AssertionError(f"unexpected call {route}")
        a = answers.pop(0) if len(answers) > 1 else answers[0]
        if isinstance(a, int):
            raise urllib.error.HTTPError(url, a, "err", {}, io.BytesIO(b'{"code": 1}'))
        if isinstance(a, BaseException):
            raise a
        raw = a if isinstance(a, bytes) else json.dumps(a).encode()
        return _Resp(raw)

    def count(self, route):
        return sum(1 for r, _ in self.calls if r == route)

    def body(self, route):
        return json.loads(next(b for r, b in self.calls if r == route))


class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _task(status, **kw):
    return {"code": 0, "data": {"status": status, **kw}}


OK_SUBMIT = {"code": 0, "status": "success", "data": {"task_id": "t-1", "status": "queued"}}
OK_UPLOAD = {"code": 0, "data": {"file_token": "file_abc"}}
SUCCESS = _task("success", output={"model_url": "https://cdn/model.glb"})


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("TRIPO_API_KEY", "tsk_test")
    monkeypatch.setattr(tripo3d.time, "sleep", lambda s: None)

    def install(script):
        fake = FakeV3(script)
        monkeypatch.setattr(tripo3d.urllib.request, "urlopen", fake.urlopen)
        return fake

    backend = Tripo3DBackend({"poll_interval": 0, "timeout": 5})
    ledger = load_ledger(tmp_path)
    slot = ledger.slot(backend="tripo3d", kind="mesh", entity_id="rock",
                       prompt="a rock", p_hash=prompt_hash("a rock"))
    return install, backend, ledger, slot, tmp_path


def test_v3_routes_and_fields(env):
    install, backend, ledger, slot, tmp = env
    concept = tmp / "c.png"
    concept.write_bytes(b"\xff\xd8\xff\xe0jpeg-in-a-png-name")
    fake = install({
        "/files": [OK_UPLOAD],
        "/generation/image-to-model": [OK_SUBMIT],
        "/tasks/t-1": [_task("queued"), _task("running"), SUCCESS],
        "https://cdn/model.glb": [b"glTF"],
    })
    out = backend.generate_mesh("a rock", tmp / "rock.glb", reference_image=concept, task_slot=slot)
    assert out.read_bytes() == b"glTF"
    body = fake.body("/generation/image-to-model")
    assert "type" not in body, "V3 routes by endpoint, so the body has no type"
    assert body["model_version"] == "v2.5-20250123", "V3 needs model_version"
    assert body["file"] == {"type": "jpg", "file_token": "file_abc"}, "type from magic bytes"
    assert fake.count("/tasks/t-1") == 3


def test_text_to_model_route(env):
    install, backend, ledger, slot, tmp = env
    fake = install({
        "/generation/text-to-model": [OK_SUBMIT],
        "/tasks/t-1": [SUCCESS],
        "https://cdn/model.glb": [b"glTF"],
    })
    backend.config["model_version"] = "v3.1-20260211"
    backend.generate_mesh("a rock", tmp / "rock.glb", task_slot=slot)
    body = fake.body("/generation/text-to-model")
    assert body == {"model_version": "v3.1-20260211", "prompt": "a rock"}


def test_poll_error_keeps_task_and_rerun_resumes(env):
    install, backend, ledger, slot, tmp = env
    install({
        "/generation/text-to-model": [OK_SUBMIT],
        "/tasks/t-1": [403],
    })
    with pytest.raises(base.BackendHTTPError):
        backend.generate_mesh("a rock", tmp / "rock.glb", task_slot=slot)
    # The pending entry is on disk before the poll failed.
    reloaded = load_ledger(tmp)
    assert reloaded.pending("tripo3d", "mesh", prompt_hash("a rock"))["task_id"] == "t-1"
    assert reloaded.has("tripo3d", "mesh", prompt_hash("a rock")) is None, "pending is not done"
    slot2 = reloaded.slot(backend="tripo3d", kind="mesh", entity_id="rock",
                          prompt="a rock", p_hash=prompt_hash("a rock"))
    fake = install({
        "/generation/text-to-model": [OK_SUBMIT],
        "/tasks/t-1": [SUCCESS],
        "https://cdn/model.glb": [b"glTF"],
    })
    backend.generate_mesh("a rock", tmp / "rock.glb", task_slot=slot2)
    assert fake.count("/generation/text-to-model") == 0, "the rerun resumed, it did not pay again"


def test_timeout_keeps_task(env):
    install, backend, ledger, slot, tmp = env
    backend.config["timeout"] = 0.05
    install({"/generation/text-to-model": [OK_SUBMIT], "/tasks/t-1": [_task("running")]})
    with pytest.raises(RuntimeError, match="resumes it"):
        backend.generate_mesh("a rock", tmp / "rock.glb", task_slot=slot)
    assert slot.get() == "t-1"


def test_failed_task_drops_pending(env):
    install, backend, ledger, slot, tmp = env
    install({
        "/generation/text-to-model": [OK_SUBMIT],
        "/tasks/t-1": [_task("failed", error_code=2008, error_message="moderation")],
    })
    with pytest.raises(TripoTaskFailed, match="2008"):
        backend.generate_mesh("a rock", tmp / "rock.glb", task_slot=slot)
    assert slot.get() is None, "a refunded task leaves no pending entry"
    assert load_ledger(tmp).entries == []


def test_poll_retries_transient_errors(env):
    install, backend, ledger, slot, tmp = env
    fake = install({
        "/generation/text-to-model": [OK_SUBMIT],
        "/tasks/t-1": [503, urllib.error.URLError("reset"), 429, SUCCESS],
        "https://cdn/model.glb": [b"glTF"],
    })
    backend.generate_mesh("a rock", tmp / "rock.glb", task_slot=slot)
    assert fake.count("/tasks/t-1") == 4


def test_submit_retries_429_not_400_or_timeout(env):
    install, backend, ledger, slot, tmp = env
    fake = install({"/generation/text-to-model": [429, OK_SUBMIT], "/tasks/t-1": [SUCCESS],
                    "https://cdn/model.glb": [b"glTF"]})
    backend.generate_mesh("a rock", tmp / "rock.glb", task_slot=slot)
    assert fake.count("/generation/text-to-model") == 2
    for answer in (400, TimeoutError("read timed out")):
        slot.drop()
        fake = install({"/generation/text-to-model": [answer]})
        with pytest.raises(Exception):
            backend.generate_mesh("b rock", tmp / "b.glb")
        assert fake.count("/generation/text-to-model") == 1, f"{answer!r} is not retried"


def test_ledger_covers_all_paid_backends_and_saves_per_call(tmp_path):
    for name in ("nanobanana", "gemini_image", "imagen", "openai_images", "gpt_image", "tripo3d"):
        assert is_paid_backend(name), name
    assert not is_paid_backend("mock")
    ledger = load_ledger(tmp_path)
    ledger.add(backend="gpt_image", kind="texture", entity_id="e", prompt="p",
               p_hash=prompt_hash("p"), out_path="x.png")
    reloaded = load_ledger(tmp_path)
    assert reloaded.has("openai_images", "texture", prompt_hash("p")), "alias hit after a save per call"
    assert not list(tmp_path.glob("*.tmp")), "the atomic write leaves no temp file"


def test_retryable_status():
    assert base.BackendHTTPError("x", 429, "r").retryable
    assert base.BackendHTTPError("x", 503, "r").retryable
    assert not base.BackendHTTPError("x", 400, "r").retryable
    assert not base.BackendHTTPError("x", 403, "r").retryable
    assert not base.is_retryable(TimeoutError())


def test_no_v2_leftovers():
    src = Path(tripo3d.__file__).read_text(encoding="utf-8")
    for old in ("/v2/openapi", "//api.tripo3d.", "image_token", "pbr_model", "\"banned\"", '"type": "image_to_model"'):
        assert old not in src, old


def test_v3_base_url_is_the_verified_one():
    # The migration guide's region table names openapi.tripo3d.com for both
    # regions. A live probe on 2026-10-16 showed that an international key
    # gets "Invalid API key" there and works on openapi.tripo3d.ai.
    assert Tripo3DBackend.API_BASE == "https://openapi.tripo3d.ai/v3"
