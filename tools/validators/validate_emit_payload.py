#!/usr/bin/env python3
"""
Static validator for `emit` payload nesting.

The `emit` effect reads its payload from a NESTED dict:

    effect_core.emit:  raw_payload = e.get("payload", {})

so an emit authored with the payload fields at TOP level:

    {"type": "emit", "signal": "socialise",
     "target": "npc_sera", "actor": "player_1"}          # WRONG

fires the signal with an EMPTY payload. Top-level `target` / `actor` are
simply ignored. Then any signal rule written the documented way —

    {"trigger": {"type": "signal", "name": "socialise"},
     "require": {"target": {...}, "actor": {...}}}

— validates bindings that were never set, so `require` always fails and the
rule NEVER FIRES. Nothing errors. Nothing is logged. The button just does
nothing.

Correct form:

    {"type": "emit", "signal": "socialise",
     "payload": {"target": "npc_sera", "actor": "player_1"}}

This is the same shape of trap as the `event:`-vs-`signal:` landmine that
check_emit_signal_fields in validate_rules.py already covers — asymmetric
naming in the emit/signal pipeline, wrong form ships silently. That check
looks at the KEY NAME; this one looks at the NESTING.

Scanned surfaces — everywhere an effect chain can be authored:
    world/rules/*.json, world/rules.json, game/goals.json, tutorial.json
    screens.json, hud.json

Usage:
    python3 tools/validators/validate_emit_payload.py             # all demos
    python3 tools/validators/validate_emit_payload.py <game>
    python3 tools/validators/validate_emit_payload.py --strict    # exit 1

Auto-registered by run_all.py (globs validate_*.py).

Empirical case 2026-08-17: a menu-driven game shipped with six emits in
screens.json all written flat. Every button in the game did nothing, with a
clean boot log and 31/31 validators passing.
"""

import json
import sys
from pathlib import Path

# Keys that legitimately live at an emit's top level.
EMIT_OWN_KEYS = {"type", "signal", "payload"}


def _walk(node, path, errors):
    if isinstance(node, dict):
        if str(node.get("type", "")) == "emit":
            stray = sorted(
                k for k in node
                if k not in EMIT_OWN_KEYS and not str(k).startswith("_")
            )
            if stray:
                errors.append((
                    path,
                    f"emit has top-level key(s) {stray} — the engine reads the "
                    f"payload from a NESTED `payload` dict, so these are IGNORED. "
                    f"The signal fires empty, every `require` on it fails, and the "
                    f"rule NEVER FIRES (silently). Move them inside "
                    f"\"payload\": {{...}}.",
                ))
            if "signal" not in node:
                errors.append((
                    path,
                    "emit has no `signal` field — effect_core.emit returns "
                    "immediately when the name is empty, so this is a no-op.",
                ))
            if "payload" in node and not isinstance(node["payload"], dict):
                errors.append((
                    f"{path}.payload",
                    "emit `payload` must be a dict; a non-dict is read as empty.",
                ))
        for k, v in node.items():
            _walk(v, f"{path}.{k}", errors)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _walk(v, f"{path}[{i}]", errors)


def _files(game_dir: Path):
    yield from sorted(game_dir.glob("world/rules/*.json"))
    yield from sorted(game_dir.glob("levels/*/rules.json"))
    yield from sorted(game_dir.glob("levels/*/rules/*.json"))
    for name in ("world/rules.json", "game/goals.json", "tutorial.json",
                 "screens.json", "hud.json"):
        f = game_dir / name
        if f.is_file():
            yield f


def validate_game(game_dir: Path, repo: Path):
    errors = []
    for f in _files(game_dir):
        try:
            doc = json.loads(f.read_text())
        except Exception as exc:
            errors.append((str(f.relative_to(repo)), f"JSON parse error: {exc}"))
            continue
        _walk(doc, f.name + "$", errors)
    return errors


def main() -> int:
    strict = "--strict" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    repo = Path(__file__).resolve().parent.parent.parent
    data = repo / "godot" / "data"
    if not data.is_dir():
        print(f"[validate_emit_payload] data root missing: {data}")
        return 0

    games = [data / args[0]] if args else sorted(p for p in data.glob("demo_*") if p.is_dir())
    total = 0
    for g in games:
        if not g.is_dir():
            continue
        errs = validate_game(g, repo)
        if errs:
            total += len(errs)
            print(f"[validate_emit_payload] FAIL — {g.name}")
            for path, msg in errs:
                print(f"  {path}: {msg}")

    if total == 0:
        print(f"[validate_emit_payload] ok — {len(games)} game(s) scanned")
        return 0
    print(
        f"\n{total} emit-payload issue(s). Each is a SILENT no-op: the signal "
        f"fires with an empty payload and every rule requiring it never runs."
    )
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
