#!/usr/bin/env python3
"""run_all.py — run every validator in this directory in sequence.

Usage:
    python3 tools/validators/run_all.py                  # all games (where applicable)
    python3 tools/validators/run_all.py demo_aldenmere   # one game
    python3 tools/validators/run_all.py demo_aldenmere --strict

`--strict` is forwarded to each validator that supports it; under
strict, the runner exits 1 if ANY validator fails. Without `--strict`,
the runner always exits 0 — individual validators print warnings.

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
}


def main() -> int:
    ap = argparse.ArgumentParser(prog="run_all.py")
    ap.add_argument("game", nargs="?", default=None,
                    help="Game folder name (e.g. demo_aldenmere). "
                         "Omit to scan every demo_* folder where "
                         "the validator supports it.")
    ap.add_argument("--strict", action="store_true",
                    help="Forward --strict to validators; exit 1 on "
                         "any failure.")
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
        if args.strict:
            cmd.append("--strict")

        label = s.stem.removeprefix("validate_")
        print(f"\n=== {label} ===", flush=True)
        res = subprocess.run(cmd)
        if res.returncode != 0:
            failed.append(s.name)

    print()
    if failed:
        print(f"[run_all] {len(failed)} validator(s) reported failure: "
              f"{', '.join(failed)}")
        return 1 if args.strict else 0
    print(f"[run_all] all {len(scripts)} validators passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
