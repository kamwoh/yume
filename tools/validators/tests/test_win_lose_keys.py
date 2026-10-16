#!/usr/bin/env python3
"""
Regression test for validate_rules check (13): hud.json win/lose keys
that the engine never reads (2026-10-16).

Empirical case: the game-rules-designer skill called `screen` a required
key, and aldenmere set it on both blocks. win_lose_widget.gd ignores it.
The allowed keys come from that file, so the list cannot drift.

Run:  python3 -m tools.validators.tests.test_win_lose_keys
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.validators.validate_rules import WIN_LOSE_KEYS, check_win_lose_keys  # noqa: E402

CASES = [
    ("screen key", {"win": {"binds": "p.s", "op": ">=", "value": 3, "screen": "end"}}, 1),
    ("valid win", {"win": {"binds": "p.s", "op": ">=", "value": 3, "message": "ok", "_comment": "x"}}, 0),
    ("sustained on lose", {"lose": {"binds": "p.hp", "op": "<=", "value": 0, "sustained": 60}}, 0),
    ("both blocks bad", {"win": {"screen": "a"}, "lose": {"screen": "b"}}, 2),
]


def main() -> int:
    failures = 0
    if WIN_LOSE_KEYS != {"binds", "op", "value", "message", "sustained"}:
        print(f"  [FAIL] keys read from win_lose_widget.gd: {sorted(WIN_LOSE_KEYS)}")
        failures += 1
    for name, hud, want in CASES:
        errs: list = []
        check_win_lose_keys(hud, errs)
        ok = len(errs) == want
        print(f"  [{'ok' if ok else 'FAIL'}] {name} -> {len(errs)} error(s)")
        failures += 0 if ok else 1
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {len(CASES) + 1} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
