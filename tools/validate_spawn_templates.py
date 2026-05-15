#!/usr/bin/env python3
"""
Static validator for spawn-effect template references.

Walks every world/rules.json + game/goals.json + levels/*/rules.json under
a game's data directory. For each `spawn` effect found, verifies the
`template` field names an entity def that actually exists in the game's
entities/*.json files (or merged `entities.json`).

Catches the bug class that bit us in Aldenmere Three Days to Eat:
content authored `"template": "wolf"` but the def id was `"animal_wolf"` →
every wolf-spawn rule fired engine error `[effect.spawn_no_def]` at runtime
instead of spawning anything. 7 such mismatches went undetected through
unit tests (which don't fire those specific spawn rules) until the user
saw the console errors.

Usage:
    python3 tools/validate_spawn_templates.py                  # all demos
    python3 tools/validate_spawn_templates.py demo_aldenmere   # one game
    python3 tools/validate_spawn_templates.py --strict         # exit 1
                                                               #   on broken

Exit code:
    0 — clean (or strict not requested)
    1 — at least one broken reference AND --strict given

Wire into scripts/play.sh as a pre-launch gate (non-strict by default so
games still play with known dangling refs; agents/CI use --strict).
"""

import json
import os
import sys
from pathlib import Path


def find_spawn_templates(node, path):
    """Recursively yield (template_value, json_path) for every `spawn` effect
    found in `node`. Skips effects with no template (engine reports those
    separately as effect.spawn_no_template)."""
    if isinstance(node, dict):
        if node.get("type") == "spawn":
            tmpl = node.get("template")
            if tmpl is not None:
                yield (str(tmpl), path)
        for k, v in node.items():
            yield from find_spawn_templates(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, item in enumerate(node):
            yield from find_spawn_templates(item, f"{path}[{i}]")


def collect_def_ids(game_dir):
    """Return set of all entity def ids the game declares.

    Entities can live in:
      - entities.json (single-file layout)
      - entities/*.json (split-file layout); each file has a top-level
        `definitions: [...]` array of `{id, tags, ...}` dicts.
    """
    ids = set()

    # Single-file layout
    single = game_dir / "entities.json"
    if single.exists():
        try:
            doc = json.loads(single.read_text())
            for d in doc.get("definitions", []):
                if isinstance(d, dict) and d.get("id"):
                    ids.add(str(d["id"]))
        except json.JSONDecodeError:
            pass

    # Split-file layout
    ents_dir = game_dir / "entities"
    if ents_dir.exists() and ents_dir.is_dir():
        for f in sorted(ents_dir.rglob("*.json")):
            try:
                doc = json.loads(f.read_text())
            except json.JSONDecodeError:
                continue
            for d in doc.get("definitions", []):
                if isinstance(d, dict) and d.get("id"):
                    ids.add(str(d["id"]))

    return ids


def collect_rule_files(game_dir):
    """Files that may contain `spawn` effects."""
    out = []
    candidates = [
        game_dir / "world" / "rules.json",
        game_dir / "game" / "goals.json",
    ]
    for c in candidates:
        if c.exists():
            out.append(c)
    levels_dir = game_dir / "levels"
    if levels_dir.exists():
        for level in sorted(levels_dir.iterdir()):
            if level.is_dir():
                r = level / "rules.json"
                if r.exists():
                    out.append(r)
    # Staged authoring files
    game_subdir = game_dir / "game"
    if game_subdir.exists():
        for staged in sorted(game_subdir.glob("*_staged.json")):
            out.append(staged)
    return out


def validate_game(game_dir, strict=False):
    game_dir = Path(game_dir)
    errors = []
    valid_ids = collect_def_ids(game_dir)
    if not valid_ids:
        # No entity defs — nothing meaningful to validate against.
        if strict:
            print(f"  [warn] no entity defs found in {game_dir.name}")
        return errors

    for path in collect_rule_files(game_dir):
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError as e:
            errors.append((str(path), "<root>", "", f"JSON parse error: {e}"))
            continue
        for template, json_path in find_spawn_templates(doc, "$"):
            if template == "":
                errors.append((str(path), json_path, template,
                               "empty spawn template"))
            elif template in valid_ids:
                continue
            else:
                # Suggest nearest match (cheap Levenshtein-style: substring or
                # prefix overlap) so authors can spot typos / missing
                # category prefix.
                suggestion = _nearest(template, valid_ids)
                msg = f"unknown def id"
                if suggestion:
                    msg += f" (did you mean {suggestion!r}?)"
                errors.append((str(path), json_path, template, msg))

    return errors


def _nearest(needle, haystack):
    """Cheap nearest-name suggestion. Returns the def id that:
      - contains `needle` as substring, OR
      - has the longest common prefix with `needle`.
    Returns None if no decent candidate.
    """
    # Substring match first.
    for d in sorted(haystack):
        if needle in d or d in needle:
            return d
    # Longest common prefix.
    best = None
    best_len = 0
    for d in haystack:
        i = 0
        while i < len(needle) and i < len(d) and needle[i] == d[i]:
            i += 1
        if i > best_len and i >= 3:
            best_len = i
            best = d
    return best


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    repo_root = Path(__file__).resolve().parent.parent
    data_root = repo_root / "godot" / "data"

    if args:
        targets = [data_root / args[0]]
    else:
        targets = [d for d in data_root.iterdir()
                   if d.is_dir() and d.name.startswith("demo_")]

    total_errors = 0
    for game_dir in sorted(targets):
        if not game_dir.exists():
            print(f"[skip] {game_dir} (not found)")
            continue
        errors = validate_game(game_dir, strict=strict)
        if errors:
            label = "FAIL" if strict else "WARN"
            print(f"[{label}] {game_dir.name} ({len(errors)} broken spawn template(s)):")
            for path, json_path, template, reason in errors:
                rel = Path(path).relative_to(repo_root)
                print(f"  {rel}::{json_path}")
                print(f"    template={template!r}  reason: {reason}")
            total_errors += len(errors)
        else:
            print(f"[ok] {game_dir.name}")

    if total_errors:
        print(f"\n{total_errors} broken spawn template reference(s).")
        print("Valid templates are entity def ids from entities/*.json (or entities.json).")
        if strict:
            sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
