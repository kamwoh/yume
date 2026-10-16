#!/usr/bin/env python3
"""
Regression test for validate_rules check (11): a query clause on a field
that the game never defines (2026-10-16).

Empirical case: demo_lanterns queried `collected_ge`. The engine suffix is
`_gte`, so the engine read `collected_ge` as a field name. No entity has
that field, and queries are strict, so the win rule never fired. CI
did not see it, because the game had no scenarios.

Run:  python3 -m tools.validators.tests.test_query_fields_defined
"""

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.validators.validate_rules import (  # noqa: E402
    QUERY_SUFFIXES, check_query_fields_defined, collect_defined_fields,
)

ENTITIES = {
    "definitions": [{"id": "gs", "tags": ["game_state"], "properties": {"kind": "x"},
                     "state_init": {"collected": 0}}],
    "initial_instances": [{"def": "gs", "id": "gs", "state": {"won": 0}}],
}
RULES = {"rules": [{"id": "spawner", "trigger": {"type": "tick"}, "effect": [
    {"type": "spawn", "template": "gs", "overrides": {"state": {"bonus": 1}}},
    {"type": "state_set", "target": "self", "field": "timer", "value": 1}]}]}


def q(state=None, props=None, contact=False):
    spec = {"tags_all": ["game_state"]}
    if state:
        spec["state"] = state
    if props:
        spec["properties"] = props
    query = {"a": spec, "b": {"tags_all": ["x"]}} if contact else spec
    return {"id": "r", "trigger": {"type": "tick"}, "query": query, "effect": []}


CASES = [
    ("wrong suffix _ge", q({"collected_ge": 3}), True),
    ("valid suffix _gte", q({"collected_gte": 3}), False),
    ("instance state field", q({"won_eq": 0}), False),
    ("spawn override field", q({"bonus": 1}), False),
    ("state_set field", q({"timer_lt": 5}), False),
    ("engine field", q({"on_floor": 1}), False),
    ("vector component", q({"position_x_gt": 80}), True),
    ("properties field", q(props={"kind": "x"}), False),
    ("unknown property", q(props={"colour": "red"}), True),
    ("contact a-binding", q({"collected_ge": 3}, contact=True), True),
    ("query fields do not define fields", q({"ghost": 1}), True),
]


def main() -> int:
    failures = 0
    if "_gte" not in QUERY_SUFFIXES or "_has" not in QUERY_SUFFIXES:
        print(f"  [FAIL] suffixes from query.gd: {QUERY_SUFFIXES}")
        failures += 1
    with tempfile.TemporaryDirectory() as tmp:
        g = Path(tmp)
        (g / "entities").mkdir()
        (g / "entities" / "e.json").write_text(json.dumps(ENTITIES))
        (g / "world" / "rules").mkdir(parents=True)
        (g / "world" / "rules" / "r.json").write_text(json.dumps(RULES))
        # A query in a game file must not count as a definition.
        (g / "world" / "rules" / "q.json").write_text(json.dumps({"rules": [q({"ghost": 1})]}))
        defined = collect_defined_fields(g)
    for name, rule, expect in CASES:
        errs: list = []
        check_query_fields_defined(rule, errs, defined)
        ok = bool(errs) == expect
        print(f"  [{'ok' if ok else 'FAIL'}] {name} -> {'flagged' if errs else 'clean'}")
        failures += 0 if ok else 1
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {len(CASES) + 1} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
