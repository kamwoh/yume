#!/usr/bin/env python3
"""
Regression test for validate_lifetime_despawn (2026-06-06).

A def with a `lifetime` state field must have BOTH a decrement rule and a
`remove`-on-lifetime rule reaching it (by tag-subset), or it lives forever.
This bug class hit doomarena3d twice (bullets, then particle_spark) and a tag
mismatch (enemy_bullet tagged "projectile" but the despawn rule queried
"bullet") — pin all of it.

Run:  python3 -m tools.validators.tests.test_lifetime_despawn
"""

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tools.validators.validate_lifetime_despawn import validate_game


def _game(root, name, defs, rules):
    g = root / name
    (g / "entities").mkdir(parents=True, exist_ok=True)
    (g / "world").mkdir(parents=True, exist_ok=True)
    (g / "entities" / "defs.json").write_text(json.dumps({"definitions": defs}))
    (g / "world" / "rules.json").write_text(json.dumps({"rules": rules}))
    return g


BULLET = {"id": "bullet", "tags": ["bullet", "projectile"], "state_init": {"lifetime": 24}}
ENEMY_BOLT = {"id": "enemy_bullet", "tags": ["enemy_bullet", "projectile"], "state_init": {"lifetime": 24}}
DEC = lambda tag: {"id": f"age_{tag}", "trigger": {"type": "tick"},
                   "query": {"tags_all": [tag]},
                   "effect": {"type": "state_add", "target": "self", "field": "lifetime", "amount": -1}}
DEL = lambda tag: {"id": f"exp_{tag}", "trigger": {"type": "tick"},
                   "query": {"tags_all": [tag], "state": {"lifetime_lte": 0}},
                   "effect": {"type": "remove", "target": "self"}}


def main() -> int:
    failures = 0
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)

        # (1) covered by shared "projectile" tag → OK
        g1 = _game(root, "demo_ok", [BULLET, ENEMY_BOLT], [DEC("projectile"), DEL("projectile")])
        ok1 = len(validate_game(g1)) == 0

        # (2) lifetime def with NO rules → flag
        g2 = _game(root, "demo_none", [BULLET], [])
        ok2 = len(validate_game(g2)) == 1

        # (3) tag mismatch: rules query "bullet" but enemy_bullet lacks it → flag only enemy_bullet
        g3 = _game(root, "demo_mismatch", [BULLET, ENEMY_BOLT], [DEC("bullet"), DEL("bullet")])
        iss3 = validate_game(g3)
        ok3 = len(iss3) == 1 and iss3[0]["id"] == "enemy_bullet"

        # (4) decrement but no remove → flag (would never reach 0-and-despawn)
        g4 = _game(root, "demo_nodel", [BULLET], [DEC("projectile")])
        ok4 = len(validate_game(g4)) == 1

        for name, ok in [("shared-tag coverage passes", ok1),
                         ("no rules flagged", ok2),
                         ("tag mismatch flags only the uncovered def", ok3),
                         ("decrement-without-remove flagged", ok4)]:
            print(f"  [{'ok' if ok else 'FAIL'}] {name}")
            if not ok:
                failures += 1

    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: 4 cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
