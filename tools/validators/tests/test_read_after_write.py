#!/usr/bin/env python3
"""
Regression test for validate_rules.check_effect_read_after_write.

The check guards the free-cam-toggle order hazard (2026-05-27): a `value`
formula reading `self.state.X` while ANOTHER effect in the same list writes X
→ the formula may read the just-written value, not the prior one.

Refinement (2026-06-09): an effect reading its OWN field is SAFE — a
self-referential single-key toggle (`state_set cam_ortho = "1 - self.state.
cam_ortho"`) evaluates the value BEFORE the write. The check must ALLOW that
(it's the canonical on/off toggle) while still catching the cross-effect bug.
This test pins both directions.

Run:  python3 -m tools.validators.tests.test_read_after_write
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tools.validators.validate_rules import check_effect_read_after_write


def violations(rule: dict):
    errs: list = []
    check_effect_read_after_write(rule, errs)
    return errs


# (name, rule, expect_violation)
CASES = [
    ("self-toggle single effect (SAFE — must NOT flag)", {
        "id": "toggle", "effect": [
            {"type": "state_set", "target": "self", "field": "cam_ortho",
             "value": "1 - self.state.cam_ortho"},
        ]}, False),
    ("self-add reading own field (SAFE)", {
        "id": "wrap", "effect": [
            {"type": "state_set", "target": "self", "field": "phase",
             "value": "(self.state.phase + 1) % 4"},
        ]}, False),
    ("cross-effect read-after-write (HAZARD — must flag)", {
        "id": "freecam", "effect": [
            {"type": "state_set", "field": "camera_mode", "value": "free_cam"},
            {"type": "state_set", "field": "previous_camera_mode",
             "value": "self.state.camera_mode"},
        ]}, True),
    ("formula reads a field no effect writes (fine)", {
        "id": "ok", "effect": [
            {"type": "state_set", "field": "y", "value": "self.state.hp * 2"},
        ]}, False),
]


def main() -> int:
    failures = 0
    for name, rule, expect in CASES:
        errs = violations(rule)
        got = len(errs) > 0
        ok = got == expect
        print(f"  [{'ok' if ok else 'FAIL'}] {name} -> "
              f"{'flagged' if got else 'clean'}"
              + ("" if ok else f"  (expected {'flagged' if expect else 'clean'})"))
        if not ok:
            failures += 1
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: "
          f"{len(CASES)} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
