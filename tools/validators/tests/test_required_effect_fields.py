#!/usr/bin/env python3
"""
Regression test for validate_rules.check_required_effect_fields.

Empirical 2026-10-16: 12 aldenmere tag_add / tag_remove effects used
`"tags": [...]`. The engine reads `tag`, so those effects did nothing.
This test pins the check in both directions.

Run:  python3 -m tools.validators.tests.test_required_effect_fields
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tools.validators.validate_rules import check_required_effect_fields


def _rule(effect):
    return {"id": "r", "trigger": {"type": "tick"}, "effect": effect}


CASES = [
    ("tag_add with tag", _rule({"type": "tag_add", "target": "self", "tag": "lit"}), False),
    ("tag_add with tags list", _rule({"type": "tag_add", "target": "self", "tags": ["lit"]}), True),
    ("tag_remove in a list, no tag", _rule([{"type": "tag_remove", "target": "self"}]), True),
    ("state_set without field", _rule({"type": "state_set", "value": 1}), True),
    ("state_add complete", _rule({"type": "state_add", "field": "hp", "amount": 1}), False),
    ("state_add with delta (check 8 owns it)", _rule({"type": "state_add", "field": "hp", "delta": 1}), False),
    ("spawn without template", _rule({"type": "spawn", "position": "self"}), True),
    ("emit is not in the table", _rule({"type": "emit", "signal": "x"}), False),
]


def main() -> int:
    failures = 0
    for name, rule, expect in CASES:
        errs: list = []
        check_required_effect_fields(rule, errs)
        got = len(errs) > 0
        ok = got == expect
        print(f"  [{'ok' if ok else 'FAIL'}] {name} -> {'flagged' if got else 'clean'}")
        if not ok:
            failures += 1
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {len(CASES)} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
