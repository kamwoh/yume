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
    "/home/kamwoh/godot-linux/Godot_v4.6.1-stable_linux.x86_64",
)
# Dedicated Linux env project (separate .godot cache from the Windows template,
# and keeps the source godot/ clean — .godot is not gitignored there).
LINUX_PROJECT = os.environ.get(
    "YUME_GODOT_LINUX_PROJECT",
    "/home/kamwoh/godot-linux/yume",
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
            "--exclude=data/*/assets/",   # heavy render assets — not needed for state
            "--exclude=.godot/",          # keep the env's own import cache
            f"{SOURCE_GODOT}/", f"{proj}/",
        ],
        check=True,
    )
    if reimport or not (proj / ".godot").exists():
        subprocess.run(
            [GODOT_LINUX_BIN, "--path", str(proj), "--headless", "--import"],
            check=True,
            timeout=import_timeout,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
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
    ):
        self.game = game
        self._bin = bin_path or GODOT_LINUX_BIN
        self._project = project or LINUX_PROJECT
        cmd = [
            self._bin,
            "--path",
            self._project,
            "--headless",
            scene,
            "--",
            f"--game={game}",
            "--stdio-step",
        ]
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
        return self._last

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

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
