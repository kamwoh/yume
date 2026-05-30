"""ADR 0060 Phase 2 — CI test for the stdio stepping env.

Launches the env (native Linux Godot, --stdio-step), steps a fixed action
sequence twice in separate processes, and asserts:
  1. the per-tick canonical hash sequence is IDENTICAL across runs (determinism
     through the full stdio round-trip — the Phase 0 oracle property, now via
     the live env), and
  2. the hash actually CHANGES across steps (the env truly advances the sim,
     not a frozen no-op).

Also smoke-tests a 3D demo (aldenmere) to confirm state stepping works with
render assets excluded (meshes are renderer-side; state is mesh-independent).

Run:  venv/bin/python -m tools.yume_env.test_env
Exit 0 = pass, 1 = fail. (Plain-assert harness, matching the repo's no-pytest
convention for engine-adjacent tests.)
"""

from __future__ import annotations

import sys

from tools.yume_env.env import YumeEnv, ensure_project


def _run(game: str, seq: list[list[str]]) -> list[str]:
    env = YumeEnv(game)
    try:
        obs = env.reset()
        hashes = [obs["hash"]]
        for acts in seq:
            obs = env.step(acts)
            hashes.append(obs["hash"])
        return hashes
    finally:
        env.close()


def main() -> int:
    ensure_project()
    fails = 0

    # --- 1. determinism + liveness on sokoban (lightweight 2D) ---
    seq = [["move_north"], [], ["move_east"], [], ["move_south"]]
    h1 = _run("demo_sokoban", seq)
    h2 = _run("demo_sokoban", seq)
    if h1 != h2:
        print(f"FAIL: sokoban not deterministic across runs\n  {h1}\n  {h2}")
        fails += 1
    else:
        print(f"PASS: sokoban deterministic across two env processes ({len(h1)} ticks)")
    if len(set(h1)) <= 1:
        print(f"FAIL: sokoban hash never changed — env not stepping the sim ({h1})")
        fails += 1
    else:
        print(f"PASS: sokoban hash changes across steps ({len(set(h1))} distinct)")

    # --- 2. 3D demo state stepping with assets excluded ---
    try:
        h3 = _run("demo_aldenmere", [["move_north"], [], ["move_north"]])
        if len(h3) == 4 and all(h for h in h3):
            print(f"PASS: aldenmere (3D, meshes excluded) steps via state channel ({len(h3)} ticks)")
        else:
            print(f"FAIL: aldenmere produced malformed hash sequence: {h3}")
            fails += 1
    except Exception as e:  # noqa: BLE001
        print(f"FAIL: aldenmere env raised: {e}")
        fails += 1

    print(f"\n=== RESULTS === {'PASS' if fails == 0 else 'FAIL'} (failures: {fails})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
