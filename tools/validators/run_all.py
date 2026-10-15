#!/usr/bin/env python3
"""run_all.py — run every validator in this directory in sequence.

Usage:
    python3 tools/validators/run_all.py                  # all games (where applicable)
    python3 tools/validators/run_all.py demo_aldenmere   # one game
    python3 tools/validators/run_all.py demo_aldenmere --strict

Every validator always runs with `--strict`, so its exit code says
whether it found anything. Without `--strict` the runner still exits 0
(play.sh launches anyway) but names each validator that found issues.
With `--strict` it exits 1 on any finding.

Why always-strict (2026-10-15): most validators exit 0 in non-strict
mode even when they print violations. The runner then printed "all 33
validators passed" over 15 real rule violations in demo_aldenmere, so
every play.sh launch showed a false green line.

`scripts/play.sh` historically called each validator by hand. This
runner consolidates that into one invocation:

    python3 tools/validators/run_all.py <game>

Per-validator behavior — whether they take a game arg or scan all
games — is preserved (the validator itself decides what to do with
the args). The runner just forwards what it received.
"""

import argparse
import subprocess
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent

# Validators that scan the whole repo / sync target (no per-game arg).
# Passed an empty arg list (plus --strict if applicable).
REPO_WIDE = {
    "validate_no_stray_scripts.py",
    "validate_tick_override.py",
    "validate_claude_config.py",
    "validate_meshes.py",
    "validate_tag_writes.py",
}


def main() -> int:
    ap = argparse.ArgumentParser(prog="run_all.py")
    ap.add_argument("game", nargs="?", default=None,
                    help="Game folder name (e.g. demo_aldenmere). "
                         "Omit to scan every demo_* folder where "
                         "the validator supports it.")
    ap.add_argument("--strict", action="store_true",
                    help="Exit 1 on any finding (validators always "
                         "run strict; this only sets the runner's exit code).")
    args = ap.parse_args()

    scripts = sorted(p for p in HERE.glob("validate_*.py"))
    if not scripts:
        print("[run_all] no validate_*.py scripts found in this dir",
              file=sys.stderr)
        return 1

    failed: list[str] = []
    for s in scripts:
        cmd: list[str] = [sys.executable, str(s)]
        if s.name not in REPO_WIDE and args.game:
            cmd.append(args.game)
        cmd.append("--strict")

        label = s.stem.removeprefix("validate_")
        print(f"\n=== {label} ===", flush=True)
        res = subprocess.run(cmd)
        if res.returncode != 0:
            failed.append(s.name)

    print()
    if failed:
        verdict = "FAILED" if args.strict else "reported issues (non-strict: continuing)"
        print(f"[run_all] {len(failed)} of {len(scripts)} validator(s) {verdict}: "
              f"{', '.join(failed)}")
        return 1 if args.strict else 0
    print(f"[run_all] all {len(scripts)} validators passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
