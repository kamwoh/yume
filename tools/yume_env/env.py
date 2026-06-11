"""ADR 0060 Phase 2 — single-env stdio stepping wrapper.

A gym-like `Env` over one Godot process running `--stdio-step` (the
StdioStepDriver autoload). One Godot process per Env; `step(actions)` writes a
JSON action batch to stdin and reads back the post-tick state + canonical hash
from stdout. Deterministic by construction (the engine side makes StepRunner the
sole tick driver).

State channel ONLY — pixel/frame observation is deferred (ADR 0060 Phase 2:
Godot FileAccess can't write pipes, so the binary frame channel needs a
separate file/TCP transport, not built yet).

RUNTIME: uses the NATIVE LINUX Godot binary. The Windows-Godot-via-WSL build
cannot do reliable stdin/stdout piping (CLAUDE.md) and can't open /dev/fd. Set
YUME_GODOT_LINUX_BIN / YUME_GODOT_LINUX_PROJECT to override.

Usage:
    from tools.yume_env.env import YumeEnv
    env = YumeEnv("demo_sokoban")
    obs = env.reset()                      # {"tick","hash","state"} (handshake)
    obs = env.step(["move_north"])         # advance one tick with these inputs
    obs = env.step([])                     # advance one tick, no input
    env.close()

The project dir must be imported once for the Linux binary (separate .godot
cache from the Windows template). `ensure_project()` syncs + imports on demand.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

GODOT_LINUX_BIN = os.environ.get(
    "YUME_GODOT_LINUX_BIN",
    os.path.expanduser("~/godot-linux/Godot_v4.6.1-stable_linux.x86_64"),
)
# Dedicated Linux env project (separate .godot cache from the Windows template,
# and keeps the source godot/ clean — .godot is not gitignored there).
LINUX_PROJECT = os.environ.get(
    "YUME_GODOT_LINUX_PROJECT",
    os.path.expanduser("~/godot-linux/yume"),
)
SOURCE_GODOT = os.environ.get(
    "YUME_GODOT_SOURCE",
    str(Path(__file__).resolve().parents[2] / "godot"),
)

SENTINEL = "@YUMESTEP@"


def ensure_project(reimport: bool = False, import_timeout: int = 600) -> str:
    """Sync source godot/ → the Linux env project and import once. Idempotent.

    Returns the project path. Pass reimport=True after engine-script changes.

    Heavy per-game render assets (data/*/assets/ — .glb meshes, textures,
    heightmaps) are EXCLUDED from the sync. This env is state-only: meshes are
    renderer-side and don't affect sim state, and importing ~1.7GB of Tripo .glb
    takes many minutes. Excluding them makes import near-instant. Entities still
    spawn logically; the renderer just has nothing to attach (harmless headless).
    """
    proj = Path(LINUX_PROJECT)
    proj.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "rsync", "-a", "--delete",
            "--exclude=data/demo_*/assets/",  # heavy per-demo render assets only;
            #                                   keep data/lib/assets (engine test fixtures)
            "--exclude=.godot/",          # keep the env's own import cache
            f"{SOURCE_GODOT}/", f"{proj}/",
        ],
        check=True,
    )
    if reimport or not (proj / ".godot").exists():
        # NOT check=True: godot --headless --import often exits non-zero on
        # benign "ObjectDB instances leaked at exit" warnings even when the
        # import succeeded. Validate by the .godot cache existing instead.
        subprocess.run(
            [GODOT_LINUX_BIN, "--path", str(proj), "--headless", "--import"],
            check=False,
            timeout=import_timeout,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if not (proj / ".godot").exists():
            raise RuntimeError(f"godot --import produced no .godot cache at {proj}")
    return str(proj)


class YumeEnv:
    """One Godot stdio-stepping process. Not thread-safe; one stepper per env."""

    def __init__(
        self,
        game: str,
        scene: str = "scenes/play.tscn",
        project: str | None = None,
        bin_path: str | None = None,
        boot_timeout: float = 30.0,
        frames: bool = False,
    ):
        """frames=True enables the pixel channel: the engine renders each step
        to a regular file (separate from the stdout state channel — the ADR 0060
        "wall"), and step()'s obs gains a "frame" with raw RGBA8 bytes + dims.
        Requires a GL context, so the process runs with --rendering-driver
        opengl3 instead of --headless (Mesa llvmpipe software GL works in WSL).
        Pays a synchronous GPU->CPU readback per step (slower than state-only).
        """
        self.game = game
        self._bin = bin_path or GODOT_LINUX_BIN
        self._project = project or LINUX_PROJECT
        self._frames = frames
        self._frame_path = None
        cmd = [self._bin, "--path", self._project]
        if frames:
            import tempfile

            self._frame_path = tempfile.NamedTemporaryFile(
                prefix=f"yume_frame_{game}_", suffix=".rgba", delete=False
            ).name
            cmd += ["--rendering-driver", "opengl3"]
        else:
            cmd += ["--headless"]
        cmd += [scene, "--", f"--game={game}", "--stdio-step"]
        if frames:
            cmd += [f"--frame-file={self._frame_path}"]
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._closed = False
        # Block until the driver's handshake line (skips Godot boot-log noise).
        self._last = self._read_step(boot_timeout)
        if not self._last.get("ready"):
            raise RuntimeError(f"env handshake malformed: {self._last}")

    # -- protocol -------------------------------------------------------

    def _read_step(self, timeout: float | None = None) -> dict:
        """Read stdout until a @YUMESTEP@ protocol line; parse + return it."""
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError(
                    "godot stdout closed before a step line.\n"
                    f"stderr tail:\n{self._drain_stderr()}"
                )
            line = line.strip()
            if not line.startswith(SENTINEL):
                continue  # boot log / unrelated print
            return json.loads(line[len(SENTINEL):])

    def _drain_stderr(self) -> str:
        try:
            return "".join(self.proc.stderr.readlines()[-12:])
        except Exception:
            return "(stderr unavailable)"

    # -- gym-like API ---------------------------------------------------

    def reset(self) -> dict:
        """Return the current observation (handshake). NOTE: does not yet
        re-seed the world — one process is one episode for now (full reset =
        relaunch). Returns {"tick","hash"} (+ "state" after the first step)."""
        return self._last

    def step(self, actions: list[str] | None = None) -> dict:
        """Advance exactly one tick with `actions` held this tick. Returns
        {"tick","hash","state"}."""
        if self._closed:
            raise RuntimeError("step() on a closed env")
        batch = {"actions": list(actions or [])}
        self.proc.stdin.write(json.dumps(batch) + "\n")
        self.proc.stdin.flush()
        self._last = self._read_step()
        # The state line arrives AFTER the engine has fully written + closed the
        # frame file, so reading it here never races a partial write.
        if self._frames and "frame" in self._last:
            self._last["frame"]["pixels"] = self._read_frame(self._last["frame"])
        return self._last

    def _read_frame(self, meta: dict):
        """Read the raw RGBA8 frame file: store_32(w) store_32(h) + w*h*4 bytes
        (little-endian, Godot's store_32). Returns a (h, w, 4) numpy array if
        numpy is available, else the raw bytes."""
        import struct

        with open(self._frame_path, "rb") as fh:
            raw = fh.read()
        w, h = struct.unpack("<II", raw[:8])
        body = raw[8 : 8 + w * h * 4]
        try:
            import numpy as np

            return np.frombuffer(body, dtype=np.uint8).reshape(h, w, 4)
        except ImportError:
            return body

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self.proc.stdin.write("QUIT\n")
            self.proc.stdin.flush()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        if self._frame_path:
            try:
                os.unlink(self._frame_path)
            except OSError:
                pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
