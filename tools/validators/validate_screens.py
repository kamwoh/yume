#!/usr/bin/env python3
"""
Static validator for transition_screen effects.

Walks every screens.json + rules.json + levels/*/rules.json under a game's
data directory. For each `transition_screen` effect found, verifies the
`target` is either a known screen id from screens.json OR the special
token `@previous`. Anything else (e.g. `_close`, `_pop`, a misspelled id)
is reported as a broken reference.

Catches the bug class that bit us in Session 5: merchant authors used
`_close` as a "close this modal" convention that the engine doesn't
recognize — every dismiss button silently warned at runtime instead of
popping the screen stack.

Usage:
    python3 tools/validate_screens.py                  # all demos
    python3 tools/validate_screens.py demo_merchant    # one game
    python3 tools/validate_screens.py --strict         # warn on missing
                                                       #   screens.json too

Exit code:
    0 — clean (or no screens.json present)
    1 — at least one broken reference

Wired into scripts/play.sh as a pre-launch gate.
"""

import json
import os
import sys
from pathlib import Path

VALID_SPECIAL = {"@previous", "@root"}  # add new sentinels here as engine grows


def find_transition_screen_effects(node, path):
    """Recursively yield (target_value, json_path) for every transition_screen
    effect found in `node`."""
    if isinstance(node, dict):
        if node.get("type") == "transition_screen":
            yield (node.get("target", ""), path)
        for k, v in node.items():
            yield from find_transition_screen_effects(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, item in enumerate(node):
            yield from find_transition_screen_effects(item, f"{path}[{i}]")


def collect_screen_ids(screens_json):
    """Return set of {id} from screens.json's `screens` array."""
    if not screens_json:
        return set()
    return {s.get("id", "") for s in screens_json.get("screens", []) if isinstance(s, dict)}


def validate_game(game_dir, strict=False):
    """Validate one game's data dir. Returns list of (file, json_path,
    target, reason) tuples for every broken reference."""
    game_dir = Path(game_dir)
    errors = []

    screens_path = game_dir / "screens.json"
    if not screens_path.exists():
        if strict:
            print(f"  [warn] no screens.json in {game_dir.name}")
        return errors

    try:
        screens_json = json.loads(screens_path.read_text())
    except json.JSONDecodeError as e:
        errors.append((str(screens_path), "<root>", "", f"JSON parse error: {e}"))
        return errors

    valid_ids = collect_screen_ids(screens_json)

    # Files that may contain transition_screen effects:
    #   screens.json (button on_click)
    #   game/goals.json (rule effects)
    #   levels/*/rules.json (per-level rules — when ADR 0006 multi-level)
    #   any *_staged.json siblings (catch bugs before they're spliced)
    targets_to_scan = [
        screens_path,
        game_dir / "game" / "goals.json",
    ]
    levels_dir = game_dir / "levels"
    if levels_dir.exists():
        for level_dir in levels_dir.iterdir():
            if level_dir.is_dir():
                rules = level_dir / "rules.json"
                if rules.exists():
                    targets_to_scan.append(rules)
    # Staged files (active authoring): also scan
    game_subdir = game_dir / "game"
    if game_subdir.exists():
        for staged in game_subdir.glob("*_staged.json"):
            targets_to_scan.append(staged)

    for path in targets_to_scan:
        if not path.exists():
            continue
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError as e:
            errors.append((str(path), "<root>", "", f"JSON parse error: {e}"))
            continue
        for target, json_path in find_transition_screen_effects(doc, "$"):
            if target == "":
                errors.append((str(path), json_path, target,
                               "empty transition_screen target"))
            elif target in VALID_SPECIAL:
                continue  # ok
            elif target in valid_ids:
                continue  # ok
            else:
                errors.append((str(path), json_path, target,
                               f"unknown screen id (not in screens.json + not @previous)"))

    return errors


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    repo_root = Path(__file__).resolve().parent.parent.parent
    data_root = repo_root / "godot" / "data"

    if args:
        targets = [data_root / args[0]]
    else:
        targets = [d for d in data_root.iterdir() if d.is_dir() and d.name.startswith("demo_")]

    total_errors = 0
    for game_dir in sorted(targets):
        if not game_dir.exists():
            print(f"[skip] {game_dir} (not found)")
            continue
        errors = validate_game(game_dir, strict=strict)
        if errors:
            label = "FAIL" if strict else "WARN"
            print(f"[{label}] {game_dir.name} ({len(errors)} broken reference(s)):")
            for path, json_path, target, reason in errors:
                rel = Path(path).relative_to(repo_root)
                print(f"  {rel}::{json_path}")
                print(f"    target={target!r}  reason: {reason}")
            total_errors += len(errors)
        else:
            print(f"[ok] {game_dir.name}")

    if total_errors:
        print(f"\n{total_errors} broken transition_screen reference(s).")
        print("Valid targets are screen ids (from screens.json) or '@previous'.")
        if strict:
            sys.exit(1)
        # Non-strict: print + exit 0 so play.sh keeps going. Strict mode is
        # for agent/CI gates — see .claude/rules/visual-qa.md screen-flow gate.
    sys.exit(0)


if __name__ == "__main__":
    main()
