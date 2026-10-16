#!/usr/bin/env python3
"""
Regression test for tools/validators/content.py (batch G, 2026-10-16).

Empirical case: validate_spawn_templates.py and validate_duplicate_mutations.py
read 0 rule files on demo_aldenmere and demo_thousandgate, because both games
use the `world/rules/*.json` folder form and the validators globbed only
`world/rules.json`. Each validator had its own loader.

This test pins the shared loader and fails when a validator walks rule files
by hand again.

Run:  python3 -m tools.validators.tests.test_content_loader
"""

import json
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tools.validators import content  # noqa: E402

VALIDATORS = Path(content.__file__).resolve().parent
# A validator may name a rule path only to read one marker file.
HAND_WALK_ALLOWED = {"validate_shell_consistency.py", "validate_claude_config.py"}
HAND_WALK = re.compile(r'"rules\.json"|"world/rules|"levels/\*/rules|glob\("world/rules')


def _write(root: Path, rel: str, doc) -> None:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(doc))


def check_rule_files() -> list[str]:
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        g = Path(tmp)
        _write(g, "world/rules.json", {"rules": [{"id": "ignored_by_folder"}]})
        _write(g, "world/rules/02_b.json", {"rules": [{"id": "b"}]})
        _write(g, "world/rules/01_a.json", {"rules": [{"id": "a"}]})
        _write(g, "game/goals.json", {"rules": [{"id": "goal"}]})
        _write(g, "tutorial.json", {"rules": [{"id": "tut"}]})
        _write(g, "levels/l1/rules/x.json", {"rules": [{"id": "lvl"}]})
        names = [str(p.relative_to(g)) for p in content.rule_files(g)]
        want = ["world/rules/01_a.json", "world/rules/02_b.json", "game/goals.json",
                "tutorial.json", "levels/l1/rules/x.json"]
        if names != want:
            fails.append(f"rule_files: got {names}, want {want}")
    return fails


def check_resolver() -> list[str]:
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        lib = Path(tmp)
        _write(lib, "motion/walk.json", {"rules": [{"id": "walk"}, {"id": "stop"}], "speed": 3})
        r = content.LibResolver(lib)
        got = r.resolve([{"id": "own"}, {"$include": "@lib.motion.walk.rules"}])
        if [x["id"] for x in got] != ["own", "walk", "stop"]:
            fails.append(f"$include splice: {got}")
        ext = r.resolve({"$extends": "@lib.motion.walk", "speed": 5})
        if ext.get("speed") != 5 or len(ext.get("rules", [])) != 2:
            fails.append(f"$extends merge: {ext}")
        if r.resolve("@lib.motion.walk.speed") != 3:
            fails.append("@lib field traversal")
        if r.resolve("@lib.missing.x") != "@lib.missing.x":
            fails.append("an unresolved ref must stay in place")
    return fails


def check_no_hand_walks() -> list[str]:
    fails = []
    for p in sorted(VALIDATORS.glob("validate_*.py")):
        if p.name in HAND_WALK_ALLOWED:
            continue
        for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("#", 1)[0]
            if HAND_WALK.search(code) and not code.strip().startswith(('"', "'", "print(")):
                fails.append(f"{p.name}:{n} walks rule files by hand. Use content.rule_files(). {line.strip()}")
    return fails


def main() -> int:
    fails = check_rule_files() + check_resolver() + check_no_hand_walks()
    for f in fails:
        print(f"  [FAIL] {f}")
    print(f"\n{'PASS' if not fails else 'FAIL'}: 3 checks, {len(fails)} failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
