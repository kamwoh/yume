#!/usr/bin/env python3
"""
Regression test for validate_duplicate_mutations suppression (2026-06-06).

The validator warns when two rules in DIFFERENT files mutate the same
(query-tags, field) pair. Two patterns are legitimate, not clobbers, and must
be SUPPRESSED — else the gate cries wolf and authors learn to ignore it:

  1. Cooldown/timer: a state_set (reset on fire/spawn) + a state_add/state_mul
     (per-tick decrement) on the same field. Universal idiom.
  2. Mutually-exclusive levels: rules that all live in per-level rules files
     (levels/<id>/rules.json) never run together — only one level loads.

But a REAL clobber — two rules in non-level files both state_set the same
field — must still flag. This test pins all three.

Run:  python3 -m tools.validators.tests.test_duplicate_mutations_suppression
"""

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tools.validators.validate_duplicate_mutations import validate_game


def _rule(rid, tag, field, etype, **extra):
    eff = {"type": etype, "target": "self", "field": field}
    eff.update(extra)
    return {"id": rid, "trigger": {"type": "tick"},
            "query": {"tags_all": [tag]}, "effect": eff}


def _write(game_dir, rel, rules):
    p = game_dir / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"rules": rules}))


def _flag_count(game_dir):
    return len(validate_game(game_dir, game_dir.parent))


def main() -> int:
    failures = 0
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)

        # (1) cooldown/timer: world sets, goals decrements — SUPPRESS
        g1 = root / "demo_timer"
        _write(g1, "world/rules.json", [_rule("set_cd", "player", "cooldown", "state_set", value=10)])
        _write(g1, "game/goals.json", [_rule("tick_cd", "player", "cooldown", "state_add", amount=-1)])
        ok1 = _flag_count(g1) == 0

        # (2) cross-level: two per-level files increment the same field — SUPPRESS
        g2 = root / "demo_levels"
        _write(g2, "levels/a/rules.json", [_rule("a_spawn", "clock", "count", "state_add", amount=1)])
        _write(g2, "levels/b/rules.json", [_rule("b_spawn", "clock", "count", "state_add", amount=1)])
        ok2 = _flag_count(g2) == 0

        # (3) REAL clobber: two non-level files both state_set the same field — FLAG
        g3 = root / "demo_clobber"
        _write(g3, "world/rules.json", [_rule("set_day_a", "clock", "day", "state_set", value=0)])
        _write(g3, "game/goals.json", [_rule("set_day_b", "clock", "day", "state_set", value=6)])
        ok3 = _flag_count(g3) == 1

        for name, ok in [("cooldown set+decrement suppressed", ok1),
                         ("cross-level suppressed", ok2),
                         ("real both-state_set clobber flagged", ok3)]:
            print(f"  [{'ok' if ok else 'FAIL'}] {name}")
            if not ok:
                failures += 1

    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: 3 cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
