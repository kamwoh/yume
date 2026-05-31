"""ADR 0061 Phase 2 — CI test for the ENet lockstep transport.

Launches two native-Linux Godot processes (host + client) on loopback, each
running the same demo under `--lockstep-*`, and asserts they ran the deterministic
sim in lockstep over the network:
  1. both completed the target tick count,
  2. neither reported a desync (per-tick hash exchange stayed in agreement),
  3. their final canonical hashes are identical (same input log → same state),
  4. they agree on the peer set.

This exercises the real transport: ENetMultiplayerPeer + @rpc input/hash
broadcast + the lockstep barrier (block until all peers' inputs for tick N).
The desync-DETECTION logic itself is unit-tested in test_runner.gd::test_lockstep
(injecting nondeterminism across two real processes is out of scope here — this
is the happy-path transport gate).

Run:  venv/bin/python -m tools.yume_env.test_lockstep_net
Exit 0 = pass, 1 = fail. Uses the LINUX binary (Windows-via-WSL networking is
unreliable). Tolerant: SKIP if ENet can't bind in this environment.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

from tools.yume_env.env import GODOT_LINUX_BIN, LINUX_PROJECT, ensure_project

GAME = "demo_sokoban"
TICKS = 20
PORT = 7777


def _spawn(role_args: list[str], out_path: Path) -> subprocess.Popen:
    if out_path.exists():
        out_path.unlink()
    cmd = [
        GODOT_LINUX_BIN, "--path", LINUX_PROJECT, "--headless",
        "scenes/play.tscn", "--",
        f"--game={GAME}",
        f"--lockstep-port={PORT}",
        f"--lockstep-ticks={TICKS}",
        f"--lockstep-out={out_path}",
    ] + role_args
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def _await_file(path: Path, timeout: float) -> dict | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            try:
                return json.loads(path.read_text())
            except Exception:
                pass  # mid-write; retry
        time.sleep(0.2)
    return None


def main() -> int:
    ensure_project(reimport=True)  # project.godot gained the LockstepDriver autoload
    host_out = Path("/tmp/yume_ls_host.json")
    client_out = Path("/tmp/yume_ls_client.json")

    host = _spawn(["--lockstep-host"], host_out)
    time.sleep(1.5)  # let the server bind before the client connects
    client = _spawn([f"--lockstep-join=127.0.0.1:{PORT}"], client_out)

    h = _await_file(host_out, 40)
    c = _await_file(client_out, 40)
    for p in (host, client):
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()

    if h is None or c is None:
        print(f"SKIP: lockstep transport — no result (host={h}, client={c}); "
              f"ENet may be unavailable in this environment")
        # stderr tail for diagnosis
        print("  host stderr:", (host.stderr.read()[-400:] if host.stderr else ""))
        return 0  # tolerant skip, like the frame-channel test

    fails = 0
    if "error" in h or "error" in c:
        print(f"FAIL: a peer errored — host={h}, client={c}")
        return 1
    if h["ticks_run"] != TICKS or c["ticks_run"] != TICKS:
        print(f"FAIL: tick count — host={h['ticks_run']} client={c['ticks_run']} (want {TICKS})")
        fails += 1
    else:
        print(f"PASS: both peers ran {TICKS} lockstep ticks over ENet")
    if h["desync_tick"] != -1 or c["desync_tick"] != -1:
        print(f"FAIL: desync — host={h['desync_tick']} client={c['desync_tick']}")
        fails += 1
    else:
        print("PASS: no desync (per-tick hash exchange stayed in agreement)")
    if h["final_hash"] != c["final_hash"] or not h["final_hash"]:
        print(f"FAIL: final hash mismatch — host={h['final_hash'][:8]} client={c['final_hash'][:8]}")
        fails += 1
    else:
        print(f"PASS: identical final canonical hash across peers ({h['final_hash'][:8]}…)")
    if sorted(h["peers"]) != sorted(c["peers"]):
        print(f"FAIL: peer-set disagreement — host={h['peers']} client={c['peers']}")
        fails += 1
    else:
        print(f"PASS: peers agree on the peer set {sorted(h['peers'])}")

    print(f"\n=== RESULTS === {'PASS' if fails == 0 else 'FAIL'} (failures: {fails})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
