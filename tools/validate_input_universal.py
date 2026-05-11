#!/usr/bin/env python3
"""ADR 0043 validator: every per-game ui/input.json must include the
universal action set (move_north/south/east/west + stop_x/stop_y/stop).

The canonical way is to splice `{"$include": "@lib.input.universal.actions"}`
into the actions array. This validator resolves that include the same way
the engine does (via the manifest's declared lib path) and asserts each
required action name appears at least once in the resolved list.

Usage:
    python3 tools/validate_input_universal.py            # all demos
    python3 tools/validate_input_universal.py demo_X     # one game
    python3 tools/validate_input_universal.py --strict   # exit 1

Wired into scripts/play.sh as a non-blocking pre-launch check.

Empirical case 2026-05-11: ADR 0043 moved WASD bindings out of
project.godot's [input] block into data/lib/input/universal.json. The
bug class this gates against: a game silently drops the $include line
and engine code polling `move_north` no-ops. Without this validator,
the symptom surfaces only at first playtest ("WASD doesn't work in
game X"). With it, the symptom surfaces at sync time.
"""

import json
import sys
from pathlib import Path


REQUIRED_ACTIONS = [
    "move_north", "move_south", "move_east", "move_west",
    "stop_x", "stop_y", "stop",
]

ROOT = Path(__file__).resolve().parent.parent
GODOT_DATA = ROOT / "godot" / "data"
LIB_PATH = GODOT_DATA / "lib" / "input" / "universal.json"


def load_json(path: Path):
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"[fail] parse error in {path}: {exc}")
        return None


def resolve_include(value, lib_cache: dict):
    """Walk a parsed JSON value and inline $include refs.
    Mirrors a tiny subset of lib_resolver.gd just for input.json shape."""
    if isinstance(value, dict):
        # $include in a dict context = array-splice marker; caller handles.
        # Recurse into other keys.
        return {k: resolve_include(v, lib_cache) for k, v in value.items()}
    if isinstance(value, list):
        out = []
        for item in value:
            if isinstance(item, dict) and "$include" in item:
                ref = item["$include"]
                spliced = resolve_ref(ref, lib_cache)
                if isinstance(spliced, list):
                    out.extend(spliced)
                else:
                    # unresolved or wrong shape — skip but warn
                    print(f"[warn] $include ref did not resolve to array: {ref}")
            else:
                out.append(resolve_include(item, lib_cache))
        return out
    return value


def resolve_ref(ref: str, lib_cache: dict):
    """Resolve a @lib.X.Y.Z ref to its value."""
    if not ref.startswith("@lib."):
        return None
    parts = ref[len("@lib."):].split(".")
    # First two parts identify the file (category.name → lib/category/name.json
    # OR lib/category.json depending on layout). Try both.
    candidates = [
        GODOT_DATA / "lib" / parts[0] / (parts[1] + ".json"),
        GODOT_DATA / "lib" / (parts[0] + ".json"),
    ]
    doc = None
    rest_idx = 2
    for c in candidates:
        if c.exists():
            doc = load_json(c)
            break
    if doc is None:
        return None
    # Traverse remaining parts as dict keys
    cur = doc
    for p in parts[rest_idx:]:
        if isinstance(cur, dict) and p in cur:
            cur = cur[p]
        else:
            return None
    return cur


def validate_game(game_dir: Path) -> list:
    """Return list of issue strings (empty = clean)."""
    issues = []
    path = game_dir / "ui" / "input.json"
    if not path.exists():
        # No input.json = game doesn't bind input; that's allowed
        return []
    doc = load_json(path)
    if doc is None or not isinstance(doc, dict):
        return [f"unreadable: {path}"]
    actions_raw = doc.get("actions", [])
    resolved = resolve_include(actions_raw, {})
    if not isinstance(resolved, list):
        return [f"{path}: actions did not resolve to a list"]
    found = {str(a.get("name", "")) for a in resolved
             if isinstance(a, dict) and "name" in a}
    missing = [a for a in REQUIRED_ACTIONS if a not in found]
    if missing:
        issues.append(
            f"{path}: missing universal action(s): {missing}. "
            f"Add `{{\"$include\": \"@lib.input.universal.actions\"}}` "
            f"at the top of the actions array (ADR 0043)."
        )
    return issues


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    if not LIB_PATH.exists():
        print(f"[fail] {LIB_PATH} not found — ADR 0043 lib missing")
        sys.exit(1 if strict else 0)
    if args:
        targets = [GODOT_DATA / args[0]]
    else:
        targets = [d for d in GODOT_DATA.iterdir()
                   if d.is_dir() and d.name.startswith("demo_")]
    total = 0
    for game in sorted(targets):
        if not game.exists():
            print(f"[skip] {game} (not found)")
            continue
        issues = validate_game(game)
        if issues:
            label = "FAIL" if strict else "WARN"
            print(f"[{label}] {game.name}:")
            for it in issues:
                print(f"  {it}")
            total += len(issues)
        else:
            print(f"[ok] {game.name}")
    if total > 0 and strict:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
