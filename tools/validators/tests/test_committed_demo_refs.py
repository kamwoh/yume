#!/usr/bin/env python3
"""
Engine tests may read only the committed example demos (batch G, 2026-10-16).

Empirical case: test_scene_preview read res://data/demo_lightlab. That demo is
gitignored, so it existed on the author's machine and the test passed there.
On a clean checkout (CI) the preview built 0 nodes and the test failed.

Run:  python3 -m tools.validators.tests.test_committed_demo_refs
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))

from tools.validators.check_examples import EXAMPLES, _is_committed  # noqa: E402

DEMO_REF = re.compile(r"data/(demo_[a-z0-9_]+)")


def main() -> int:
    fails = []
    for p in sorted((REPO / "godot" / "scripts" / "engine").rglob("*.gd")):
        if "/tests/" not in p.as_posix():
            continue
        for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            for demo in DEMO_REF.findall(line.split("#", 1)[0]):
                if demo not in EXAMPLES or not _is_committed(demo):
                    fails.append(f"{p.relative_to(REPO)}:{n} reads {demo}, which is not a committed example")
    for f in fails:
        print(f"  [FAIL] {f}")
    print(f"\n{'PASS' if not fails else 'FAIL'}: {len(fails)} failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
