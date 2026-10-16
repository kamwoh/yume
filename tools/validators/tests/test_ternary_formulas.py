#!/usr/bin/env python3
"""
Regression test for validate_rules check (12): a ternary in a formula
(2026-10-16).

Empirical case: Godot 4.6.1's Expression parses `a if cond else b`, drops
the tokens after `a`, and returns `a` with no error. An aldenmere
cloud_wrap formula with a ternary moved every cloud, not only the far ones.

Run:  python3 -m tools.validators.tests.test_ternary_formulas
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.validators.validate_rules import check_ternary_formulas  # noqa: E402


def rule(value, key="effect"):
    eff = {"type": "state_set", "target": "self", "field": "x", "value": value}
    return {"id": "r", "trigger": {"type": "tick"}, key: eff if key == "effect" else {"self": value}}


CASES = [
    ("ternary in effect value", rule("self.state.x - 160 if self.state.x > 80 else self.state.x"), True),
    ("ternary in a value list", rule(["0", "1 if world.tick > 3 else 2"]), True),
    ("float(cond) idiom", rule("self.state.x - 160 * float(self.state.x > 80)"), False),
    ("keywords inside a string literal", rule("'if' + 'else'"), False),
    ("ternary in a comment", {"id": "r", "effect": {"type": "remove", "_comment": "a if b else c"}}, False),
    ("ternary in require", rule("1 if a else 0", key="require"), True),
]


def main() -> int:
    failures = 0
    for name, r, expect in CASES:
        errs: list = []
        check_ternary_formulas(r, errs)
        ok = bool(errs) == expect
        print(f"  [{'ok' if ok else 'FAIL'}] {name} -> {'flagged' if errs else 'clean'}")
        failures += 0 if ok else 1
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {len(CASES)} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
