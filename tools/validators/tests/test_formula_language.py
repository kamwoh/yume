#!/usr/bin/env python3
"""
Regression test for validate_rules check (12): the formula language
(ADR 0088, 2026-10-17).

Empirical cases:
- 2026-10-16: Godot 4.6.1's Expression parses `a if cond else b`, drops
  the tokens after `a`, and returns `a` with no error. An aldenmere
  cloud_wrap formula moved every cloud.
- 2026-10-17: rules called `atan2` and `float`, which no list named.
  Nothing stopped any other GDScript function, constructor or method.

The test also checks that the validator reads the function list from
formula.gd, so the engine and the validator cannot drift.

Run:  python3 -m tools.validators.tests.test_formula_language
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.validators.validate_rules import FORMULA_FUNCTIONS, check_formula_language  # noqa: E402


def rule(value, key="effect"):
    eff = {"type": "state_set", "target": "self", "field": "x", "value": value}
    return {"id": "r", "trigger": {"type": "tick"}, key: eff if key == "effect" else {"self": value}}


CASES = [
    ("ternary in effect value", rule("self.state.x - 160 if self.state.x > 80 else self.state.x"), True),
    ("ternary in a value list", rule(["0", "1 if world.tick > 3 else 2"]), True),
    ("ternary in require", rule("1 if a else 0", key="require"), True),
    ("ternary in a comment", {"id": "r", "effect": {"type": "remove", "_comment": "a if b else c"}}, False),
    ("float(cond) idiom", rule("self.state.x - 160 * float(self.state.x > 80)"), False),
    ("atan2, subscript, and/not", rule("atan2(-self.state.v[0], -self.state.v[1]) * float(not (world.tick > 3 and true))"), False),
    ("exponent literal", rule("self.state.x * 1e-3 + .5"), False),
    ("bare binding", rule("self.id"), False),
    ("string literal", rule("self.state.x + 'a'"), True),
    ("modulo", rule("world.tick % 60"), True),
    ("power operator", rule("self.state.x ** 2"), True),
    ("unknown function", rule("wrapf(self.state.x, 0, 3)"), True),
    ("constructor", rule("1 + Vector2(1, 2)[0]"), True),
    ("method call", rule("self.state.list.size()"), True),
    ("constant name", rule("self.state.r * PI"), True),
    ("array literal", rule("1 + [1, 2][0]"), True),
    ("C-style and", rule("world.tick > 1 && self.state.on"), True),
    ("capitalized text is not a formula", rule("PI * 2"), False),
    ("literal text key", {"id": "r", "effect": {"type": "show_toast", "text": "go home (now)"}}, False),
]


def main() -> int:
    failures = 0
    for name, r, expect in CASES:
        errs: list = []
        check_formula_language(r, errs)
        ok = bool(errs) == expect
        print(f"  [{'ok' if ok else 'FAIL'}] {name} -> {'flagged' if errs else 'clean'}")
        failures += 0 if ok else 1
    twin = len(FORMULA_FUNCTIONS) == 16 and {"atan2", "float", "randf"} <= FORMULA_FUNCTIONS
    print(f"  [{'ok' if twin else 'FAIL'}] function list read from formula.gd")
    failures += 0 if twin else 1
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {len(CASES) + 1} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
