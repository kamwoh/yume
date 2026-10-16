#!/usr/bin/env python3
"""
Static validator for the effect-chain ordering gate
(.claude/rules/engine-scripts.md § effect-chain validation gate).

The rule has been documented since ADR 0010 but never machine-enforced:
**destructive effects must be LAST in their chain.** Anything queued after
one is silently dropped when the world/scene is replaced at end-of-frame.
Nothing errors, nothing is logged — the button just doesn't do the second
half of what it says.

Empirical case (ADR 0010 reference content): a "New Game" button was wired
as [reload_scene, transition_screen]. The screen transition was dropped.
The visual gate passed — nothing looked wrong — and the user found it by
clicking.

There are TWO levels of destruction, and conflating them produces false
positives on chains that work fine in practice:

  SCENE-DESTROYING — tears down the whole Godot node tree, ScreenFlow and
  all. NOTHING may follow, not even a UI effect.
      reload_scene, scene_change, quit_app

  WORLD-SWAPPING — replaces the entity set; the node tree (ScreenFlow,
  GameShell, HUD) survives. Only effects that resolve against the OLD
  entities are dropped; shell-tier effects still land.
      transition_level (also at the fade midpoint when fade_duration>0),
      level_call, level_return (ADR 0077), load_state, reset_world

So `[reset_world, transition_screen]` — the standard "New Game" button —
is CORRECT and must not be flagged: the world is rebuilt, the screen
transition still reaches the surviving ScreenFlow. But
`[reset_world, state_set target=player_1 ...]` is a real bug: that player
entity is gone.

NOT destructive at all: screen_fade (tweens an overlay alpha),
transition_screen (swaps UI), save_state (reads), show_toast.

Scanned surfaces — every place an effect chain can be authored:
    world/rules/*.json, world/rules.json, game/goals.json, tutorial.json
    screens.json (on_click / on_change / on_submit)
    hud.json (same)

Usage:
    python3 tools/validators/validate_effect_chains.py             # all demos
    python3 tools/validators/validate_effect_chains.py <game>
    python3 tools/validators/validate_effect_chains.py --strict    # exit 1

Auto-registered by run_all.py (globs validate_*.py).
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import content  # noqa: E402

SCENE_DESTROYING = {
    "reload_scene",
    "scene_change",
    "quit_app",
}

WORLD_SWAPPING = {
    "transition_level",
    "level_call",
    "level_return",
    "load_state",
    "reset_world",
}

# Shell-tier effects: they live above the world, so they survive a world
# swap and are legal after one. Everything NOT in this set is assumed to
# resolve against entities and is therefore dropped.
WORLD_INDEPENDENT = {
    "transition_screen",
    "screen_fade",
    "show_toast",
    "show_overlay",
    "dismiss_overlay",
    "emit_shell_event",
    "save_state",
    "set_audio_bus_volume",
    "set_input_mapping",
    "quit_app",
}

# Keys whose value is an effect chain (a list of effect dicts, or one dict).
CHAIN_KEYS = ("effect", "effects", "on_click", "on_change", "on_submit", "on_press")


def _check_chain(chain, path, errors):
    if isinstance(chain, dict):
        return  # a single effect can't be mis-ordered
    if not isinstance(chain, list):
        return
    effects = [e for e in chain if isinstance(e, dict) and "type" in e]
    if len(effects) < 2:
        return
    for i, eff in enumerate(effects[:-1]):
        t = str(eff.get("type", ""))
        later = [str(e.get("type", "")) for e in effects[i + 1:]]

        if t in SCENE_DESTROYING:
            errors.append((
                f"{path}[{i}]",
                f"`{t}` tears down the whole scene tree (ScreenFlow included) "
                f"but is not last — every later effect is silently dropped: "
                f"{later}. Move `{t}` to the end of the chain.",
            ))
            continue

        if t in WORLD_SWAPPING:
            dropped = [e for e in later if e not in WORLD_INDEPENDENT]
            if dropped:
                errors.append((
                    f"{path}[{i}]",
                    f"`{t}` replaces the entity set, but {len(dropped)} later "
                    f"effect(s) resolve against the OLD entities and are "
                    f"silently dropped: {dropped}. Move `{t}` last, or fire "
                    f"those effects from a rule triggered after the swap. "
                    f"(Shell-tier effects like transition_screen DO survive "
                    f"and are fine here.)",
                ))


def _walk(node, path, errors):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in CHAIN_KEYS:
                _check_chain(v, f"{path}.{k}", errors)
            _walk(v, f"{path}.{k}", errors)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _walk(v, f"{path}[{i}]", errors)


def _files(game_dir: Path):
    # The rule files the engine loads (content.py), plus the UI chains.
    yield from content.rule_files(game_dir)
    for name in ("screens.json", "hud.json"):
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
        _walk(content.resolver().resolve(doc), f.name + "$", errors)
    return errors


def main() -> int:
    strict = "--strict" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    repo = Path(__file__).resolve().parent.parent.parent
    data = repo / "godot" / "data"
    if not data.is_dir():
        print(f"[validate_effect_chains] data root missing: {data}")
        return 0

    games = [data / args[0]] if args else sorted(p for p in data.glob("demo_*") if p.is_dir())
    total = 0
    for g in games:
        if not g.is_dir():
            continue
        errs = validate_game(g, repo)
        if errs:
            total += len(errs)
            print(f"[validate_effect_chains] FAIL — {g.name}")
            for path, msg in errs:
                print(f"  {path}: {msg}")

    if total == 0:
        print(f"[validate_effect_chains] ok — {len(games)} game(s) scanned")
        return 0
    print(
        f"\n{total} effect-chain ordering violation(s). Each drops effects "
        f"SILENTLY at runtime. See .claude/rules/engine-scripts.md "
        f"§ effect-chain validation gate."
    )
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
