#!/usr/bin/env python3
"""
Regression test for validate_adr_index.py (2026-10-16).

Empirical case: ADRs 0068-0081 had no index rows, and six ADRs said
"proposed" while demos used their code. Nothing checked either.

Run:  python3 -m tools.validators.tests.test_adr_index
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tools.validators import validate_adr_index as v  # noqa: E402

STATUS_CASES = [
    ("proposed", "proposed"),
    ("**proposed** — awaiting tech-director review", "proposed"),
    ("accepted for phase 1 (status corrected 2026-10-16)", "accepted"),
    ("**accepted with conditions** (tech-director review 2026-05-04)", "accepted"),
    ("revise → accept-with-conditions (2026-05-10)", "accepted"),
    ("**approved — Session A may begin** (2026-05-12)", "accepted"),
    ("superseded by ADR 0085 (2026-10-16).", "superseded"),
]


def main() -> int:
    failures = 0
    for text, want in STATUS_CASES:
        got = v.status_word(text)
        ok = got == want
        print(f"  [{'ok' if ok else 'FAIL'}] {text!r} -> {got}")
        failures += 0 if ok else 1
    issues = v.check()
    if issues:
        print("  [FAIL] the repo has ADR index findings:\n    " + "\n    ".join(issues))
        failures += 1
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {len(STATUS_CASES) + 1} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
