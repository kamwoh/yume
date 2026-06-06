#!/usr/bin/env python3
"""
Regression test for validate_rules.FORMULA_ROOT_RE.

Guardrail (post-mortem 2026-06-06): the binding-root regex used to match each
`id.id` PAIR, so a multi-segment path like `self.state.position.x` matched
`self.state` (root self ✓) AND `position.x` (root `position` ✗) — flagging the
MIDDLE field as an unbound binding. That produced 68 false "unbound position"
violations on demo_doomarena3d (and would on any demo using
`self.state.position.x`). The regex must capture ONLY the LEADING root of a
full dotted chain. This test fails if it ever regresses to pair-matching.

Run:  python3 -m tools.validators.tests.test_formula_roots
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tools.validators.validate_rules import FORMULA_ROOT_RE


def roots(formula: str):
    return sorted({m.group(1) for m in FORMULA_ROOT_RE.finditer(formula)})


CASES = [
    # formula                                            expected leading roots
    ("self.state.position.x - sin(self.state.facing)",   ["self"]),
    ("self.state.position.z - cos(self.state.pitch)",    ["self"]),
    ("1.6 + sin(self.state.pitch) * 0.6",                ["self"]),
    ("clock.state.day + 1",                              ["clock"]),
    ("a.state.hp + b.state.hp",                          ["a", "b"]),
    ("world.tick * 2",                                   ["world"]),
    # A genuinely unbound root is still surfaced (the regex must not go blind):
    ("monster.state.hp - 1",                             ["monster"]),
]


def main() -> int:
    failures = 0
    for formula, expected in CASES:
        got = roots(formula)
        ok = got == expected
        print(f"  [{'ok' if ok else 'FAIL'}] {formula!r} -> {got}"
              + ("" if ok else f"  (expected {expected})"))
        if not ok:
            failures += 1
    # The specific bug: `position` (a middle field) must NEVER be a root.
    bad = "self.state.position.x"
    if "position" in roots(bad):
        print(f"  [FAIL] middle field leaked as a root in {bad!r}")
        failures += 1
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: "
          f"{len(CASES)} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
