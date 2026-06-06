#!/usr/bin/env python3
"""
check_examples.py — GATE: every COMMITTED example game must pass the full
validator bank (--strict). Run in CI / before tagging a release.

Why this exists (post-mortem 2026-06-06): demo_doomarena3d was committed as an
OSS example WITHOUT running the validators on it — it shipped with a runaway
(uncapped) monster spawner. The example demos are the first thing a fresh
clone runs, so a broken one is the worst first impression. Demos under
godot/data/demo_*/ are gitignored EXCEPT the few un-ignored examples; those
are exactly the ones a cloner runs, so they must validate clean.

Usage:
    python3 tools/validators/check_examples.py            # validate + report
    python3 tools/validators/check_examples.py --strict   # exit 1 on any failure
"""

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent

# The committed, runnable, key-free example games (see .gitignore exceptions +
# README § Generation pipeline). Keep in sync with the .gitignore `!` rules.
EXAMPLES = ["demo_sokoban", "demo_doomarena3d", "demo_lanterns"]


def _is_committed(game: str) -> bool:
    """True if any file under the demo is git-tracked (i.e. it's a real
    committed example, not just a local working copy)."""
    r = subprocess.run(
        ["git", "ls-files", f"godot/data/{game}"],
        cwd=REPO, capture_output=True, text=True,
    )
    return bool(r.stdout.strip())


def main() -> int:
    strict = "--strict" in sys.argv
    failures = []
    for game in EXAMPLES:
        if not (REPO / "godot" / "data" / game).is_dir():
            print(f"[skip] {game}: not present on disk")
            continue
        committed = _is_committed(game)
        r = subprocess.run(
            [sys.executable, "tools/validators/run_all.py", game, "--strict"],
            cwd=REPO, capture_output=True, text=True,
        )
        ok = r.returncode == 0
        tag = "ok" if ok else "FAIL"
        commit_note = "" if committed else " (not yet committed)"
        print(f"[{tag}] {game}{commit_note}")
        if not ok:
            # surface the failing validator lines
            for line in (r.stdout + r.stderr).splitlines():
                if "FAIL" in line or "violation" in line.lower():
                    print(f"    {line}")
            if committed:  # only a committed example is a release-blocker
                failures.append(game)

    if failures:
        print(f"\n{len(failures)} COMMITTED example(s) fail validation: "
              f"{', '.join(failures)}")
        print("A committed example must pass the validator bank — fix it or "
              "drop it from the .gitignore exceptions before release.")
        return 1 if strict else 0
    print("\nAll committed examples pass the validator bank.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
