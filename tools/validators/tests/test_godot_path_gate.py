#!/usr/bin/env python3
"""
Regression test for validate_claude_config check 4: no absolute Godot
`--path` in skills, rules or CLAUDE.md (2026-10-16).

Empirical case: 8 skills kept their own copy of a capture command with
`--path C:/.../YumeTemplate`. Godot aborts on an absolute `--path` with
"Invalid project path" and prints no test output.

Run:  python3 -m tools.validators.tests.test_godot_path_gate
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.validators.validate_claude_config import ABSOLUTE_PATH, check_godot_path  # noqa: E402

CASES = [
    ("godot --path C:/.../YumeTemplate scenes/x.tscn", True),
    ('"$GODOT_BIN" --path "$TEMPLATE_DST" --headless --import', True),
    ("godot --path <template> --headless --import", True),
    ("godot --headless --path /mnt/c/Users/x/YumeTemplate", True),
    ('cd "$TEMPLATE_DST" && "$GODOT_BIN" --path . --headless', False),
    ('"$GODOT_BIN" --path . \\', False),
    ("An absolute `--path` aborts with an error.", False),
]


def main() -> int:
    failures = 0
    for line, expect in CASES:
        ok = bool(ABSOLUTE_PATH.search(line)) == expect
        print(f"  [{'ok' if ok else 'FAIL'}] {line}")
        failures += 0 if ok else 1
    repo = check_godot_path()
    if repo:
        print("  [FAIL] the repo has absolute --path lines:\n    " + "\n    ".join(repo))
        failures += 1
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {len(CASES) + 1} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
