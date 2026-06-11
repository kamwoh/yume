#!/usr/bin/env python3
"""oracle.py — ADR 0060 Phase 0 determinism gate.

Run ONE demo TWICE with the SAME (initial_state, input_log) and diff the
per-tick `canonical_state_hash` sequences. Identical → deterministic.
Divergent → report the first divergent tick + entity (the determinism-bug
backlog; this tool only FINDS divergence, never fixes it).

Driver: `scenes/scenario_test.tscn` (scenario_runner / step_runner) — it is
TICK-LOCKED and input-driven (the demo's tests.json scenarios), so two runs
execute the identical fixed tick/input sequence. Far cleaner than real-time
capture for a determinism test. The engine's `--hash-log=<path>` (wired at
the World tick level, ADR 0060) appends {tick, hash, ents} per tick; the
log accumulates across the suite's per-scenario Worlds (World appends).

Usage:
    venv/bin/python tools/yume_env/oracle.py <demo>            # e.g. demo_sokoban
    venv/bin/python tools/yume_env/oracle.py <demo> --runs 3   # extra confidence

Env (same as scripts/play.sh): YUME_GODOT_BIN, YUME_TEMPLATE_DST.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

GODOT_BIN = os.environ.get(
    "YUME_GODOT_BIN",
    "godot",  # set YUME_GODOT_BIN in your shell profile
)
TEMPLATE_DST = os.environ.get(
    "YUME_TEMPLATE_DST",
    os.path.expanduser("~/.yume/YumeTemplate"),  # set YUME_TEMPLATE_DST
)
# Where Godot's user:// resolves. Derive the Windows user from the template
# path on WSL2+Windows; override with YUME_USERDATA.
def _default_userdata() -> str:
    import re as _re
    m = _re.match(r"^/mnt/c/Users/([^/]+)/", os.environ.get("YUME_TEMPLATE_DST", ""))
    if m:
        return "/mnt/c/Users/%s/AppData/Roaming/Godot/app_userdata/Yume Framework" % m.group(1)
    return os.path.expanduser("~/.yume/userdata")


USERDATA = Path(
    os.environ.get("YUME_USERDATA", "") or _default_userdata()
)


def run_once(demo: str, run_idx: int, timeout: int = 300) -> list[dict]:
    """Run the scenario suite once with --hash-log; return the parsed rows."""
    log_name = f"oracle_{demo}_r{run_idx}.jsonl"
    wsl_log = USERDATA / log_name
    if wsl_log.exists():
        wsl_log.unlink()
    cmd = [
        GODOT_BIN, "--path", ".", "--headless",
        "scenes/scenario_test.tscn", "--",
        f"--game={demo}", f"--hash-log=user://{log_name}",
    ]
    proc = subprocess.run(
        cmd, cwd=TEMPLATE_DST, capture_output=True, text=True, timeout=timeout
    )
    if not wsl_log.exists():
        print(f"  [run {run_idx}] NO hash-log produced. godot stderr tail:")
        print("    " + "\n    ".join(proc.stderr.splitlines()[-8:]))
        raise SystemExit(2)
    rows: list[dict] = []
    for line in wsl_log.read_text().splitlines():
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def diverging_entities(a: dict, b: dict) -> list[str]:
    """Names of entities whose per-entity hash differs (or only in one)."""
    ea = a.get("ents", {})
    eb = b.get("ents", {})
    out = []
    for eid in sorted(set(ea) | set(eb)):
        if ea.get(eid) != eb.get(eid):
            tag = "missing" if (eid not in ea or eid not in eb) else "changed"
            out.append(f"{eid} ({tag})")
    return out


def compare(runs: list[list[dict]], demo: str) -> bool:
    """Compare all runs against run 0. Return True if all identical."""
    base = runs[0]
    deterministic = True
    for ri in range(1, len(runs)):
        other = runs[ri]
        n = min(len(base), len(other))
        if len(base) != len(other):
            print(f"  ⚠ run0 has {len(base)} rows, run{ri} has {len(other)} "
                  f"(comparing first {n})")
        first_div = None
        for i in range(n):
            if base[i].get("hash") != other[i].get("hash"):
                first_div = i
                break
        if first_div is None and len(base) == len(other):
            continue  # identical
        deterministic = False
        if first_div is None:
            print(f"  run{ri}: hashes match for {n} rows but lengths differ "
                  f"→ DIVERGENT (length).")
            continue
        a, b = base[first_div], other[first_div]
        ents = diverging_entities(a, b)
        print(f"  run{ri}: FIRST DIVERGENCE at log-row {first_div} "
              f"(tick={a.get('tick')}):")
        print(f"    run0 hash={a.get('hash','')[:16]}…  "
              f"run{ri} hash={b.get('hash','')[:16]}…")
        print(f"    divergent entities: {', '.join(ents) if ents else '(world_state/relations only — no entity-level diff)'}")
    return deterministic


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print("usage: oracle.py <demo> [--runs N]")
        return 2
    demo = args[0]
    n_runs = 2
    if "--runs" in sys.argv:
        n_runs = int(sys.argv[sys.argv.index("--runs") + 1])

    print(f"=== determinism oracle: {demo} ({n_runs} runs, scenario-driven) ===")
    runs = []
    for ri in range(n_runs):
        rows = run_once(demo, ri)
        print(f"  run {ri}: {len(rows)} hashed ticks")
        runs.append(rows)

    if not runs[0]:
        print(f"RESULT: {demo} — NO TICKS HASHED (no scenarios, or suite did "
              f"not tick). Inconclusive.")
        return 1

    ok = compare(runs, demo)
    print(f"RESULT: {demo} — {'DETERMINISTIC ✓' if ok else 'DIVERGENT ✗ (determinism-bug backlog)'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
