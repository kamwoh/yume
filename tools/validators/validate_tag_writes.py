#!/usr/bin/env python3
"""validate_tag_writes.py — no in-place writes to an entity's `tags` (ADR 0084).

QueryLib keeps a lazy tag index. It rebuilds when `Entity.tag_epoch`
changes. The `tags` setter, `Entity.create`, `add_tag` and `remove_tag`
bump the epoch. An in-place write such as `ent.tags.append("x")` does
not, so later tag queries miss the change.

This validator is repo-wide. It scans `godot/scripts/**/*.gd` and fails
on a mutating call or an index write on `.tags`. It skips
`core/entity.gd`, which owns the epoch. It also skips the tests, which
write in place on purpose to check the dynamic gate.

Empirical 2026-10-16: `multimesh_director.gd` wrote `tags` in place at
two sites. Both now call `add_tag` / `remove_tag`.

Usage:
    python3 tools/validators/validate_tag_writes.py [--strict]
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "godot" / "scripts"
OWNER = SCRIPTS / "engine" / "core" / "entity.gd"
TESTS = SCRIPTS / "engine" / "tests"

MUTATORS = (
    "append", "append_array", "push_back", "push_front", "insert", "erase",
    "remove_at", "pop_back", "pop_front", "pop_at", "clear", "assign",
    "resize", "fill", "sort", "sort_custom", "reverse", "shuffle", "set",
)
IN_PLACE = re.compile(
    r"\.tags\s*\.\s*(?:%s)\s*\(|\.tags\s*\[[^\]]*\]\s*=(?!=)" % "|".join(MUTATORS)
)


def find(root=SCRIPTS):
    hits = []
    for path in sorted(root.rglob("*.gd")):
        if path == OWNER or TESTS in path.parents:
            continue
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("#", 1)[0]
            if IN_PLACE.search(code):
                hits.append((path.relative_to(ROOT), n, line.strip()))
    return hits


def main() -> int:
    strict = "--strict" in sys.argv
    hits = find()
    for path, n, line in hits:
        print(f"  [tag_writes] {path}:{n}: in-place write to `tags`. "
              f"Use add_tag / remove_tag or assign a new array.  {line}")
    if not hits:
        print("[ok] no in-place tag writes outside core/entity.gd")
        return 0
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
