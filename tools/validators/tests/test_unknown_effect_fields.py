#!/usr/bin/env python3
"""
Regression test for validate_rules check (10) and its UI-chain use in
validate_effect_chains.py (batch G, 2026-10-16).

Empirical case: aldenmere used `formula_x` on velocity_set and `state` on
spawn. The engine reads `x` and `overrides.state`, so both were silent
no-ops.

Run:  python3 -m tools.validators.tests.test_unknown_effect_fields
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.validators.validate_rules import check_unknown_effect_fields  # noqa: E402
from tools.validators.validate_effect_chains import _unknown_fields  # noqa: E402


def rule(effect):
    return {"id": "r", "trigger": {"type": "tick"}, "effect": effect}


CASES = [
    ("velocity_set formula_x", rule({"type": "velocity_set", "target": "self", "formula_x": "1"}), True),
    ("velocity_set x formula", rule({"type": "velocity_set", "target": "self", "x": "randf()"}), False),
    ("spawn with state", rule([{"type": "spawn", "template": "t", "state": {"a": 1}}]), True),
    ("spawn with overrides", rule([{"type": "spawn", "template": "t", "overrides": {"state": {"a": 1}}}]), False),
    ("comment key", rule({"type": "remove", "target": "self", "_comment": "x"}), False),
    ("open effect skipped", rule({"type": "emit_shell_event", "event": "shake", "intensity": 2}), False),
]


def main() -> int:
    failures = 0
    for name, r, expect in CASES:
        errs: list = []
        check_unknown_effect_fields(r, errs)
        ok = bool(errs) == expect
        print(f"  [{'ok' if ok else 'FAIL'}] {name} -> {'flagged' if errs else 'clean'}")
        failures += 0 if ok else 1
    ui = {"screens": [{"elements": [{"type": "button", "on_click": [
        {"type": "transition_screen", "target": "title", "screen": "oops"}]}]}]}
    errs: list = []
    _unknown_fields(ui, "screens.json$", errs)
    ok = len(errs) == 1 and "screen" in errs[0][1]
    print(f"  [{'ok' if ok else 'FAIL'}] nested button chain -> {errs}")
    failures += 0 if ok else 1
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {len(CASES) + 1} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
