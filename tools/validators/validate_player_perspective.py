#!/usr/bin/env python3
"""validate_player_perspective.py

Static checks for the player-perspective bug class — keybinds the
player can't discover, objective text referencing landmarks the
player can't see.

Empirical motivation (2026-05-08): merchant Day 1 shipped with
"south-west of the fountain" as objective text but the fountain
was off-screen at spawn, AND the M-key map binding existed in
inputs.json + screens.json global_inputs but was missing from the
HUD controls_hint. Player perspective: "I don't know where is the
shop. Where is my map?"

Two static checks that catch both bugs at sync time:

1. INPUTS-COVERED-BY-HUD: every action declared in inputs.json
   must be mentioned by KEY in hud.json's controls_hint, OR be
   prefixed `ui_` (Godot built-in actions: ui_accept, ui_cancel,
   etc., not player-discoverable verbs).

2. OBJECTIVE-LANDMARK-LABELED: every noun-phrase landmark
   referenced in any current_objective state_set value (e.g.
   "fountain", "shop door", "captain", "tower") must be either:
     a) the display_name of an entity tagged `named_npc`, OR
     b) explicitly listed in an exemption file (some objective
        text references abstract concepts, not entities).

Run: python3 tools/validate_player_perspective.py demo_<game> [--strict]
"""

import json
import re
import sys
from pathlib import Path

GAME_ARG = sys.argv[1] if len(sys.argv) > 1 else None
STRICT = "--strict" in sys.argv

if not GAME_ARG:
    print("usage: validate_player_perspective.py demo_<game> [--strict]")
    sys.exit(2)

ROOT = Path(__file__).resolve().parent.parent.parent
GAME_DIR = ROOT / "godot" / "data" / GAME_ARG
if not GAME_DIR.exists():
    print(f"[fail] {GAME_DIR} not found")
    sys.exit(2)

errors = []
warnings = []


def load_json(p: Path):
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{p.name}: parse error: {exc}")
        return None


# ---- check 1: HUD controls_hint covers every player-facing input ----

# Canonical path per ADR 0009 Phase 5b — `<game>/ui/input.json`. The
# legacy root-level `inputs.json` is no longer read by the engine; if
# we see one, warn so authors don't author into a dead file.
inputs = load_json(GAME_DIR / "ui" / "input.json")
legacy_inputs = GAME_DIR / "inputs.json"
if legacy_inputs.exists():
    errors.append(
        f"legacy {legacy_inputs.name} present at data root — engine reads "
        f"only `ui/input.json` since ADR 0009 Phase 5b. Move actions "
        f"into ui/input.json or delete the dead file."
    )
hud = load_json(GAME_DIR / "hud.json")

if inputs and hud:
    declared = [
        a.get("name", "") for a in inputs.get("actions", [])
        if not a.get("reserved", False)
    ]
    declared = [n for n in declared if n and not n.startswith("ui_")]
    hint = str(hud.get("controls_hint", ""))
    hint_lower = hint.lower()

    # Aggregate all rule files to scan for input-trigger actions + screens
    # global_inputs that consume actions. Bug class (2026-05-08): merchant
    # declared `open_map` and `toggle_camera` in inputs.json but
    # toggle_camera had no rule consuming it AND open_map was in the wrong
    # canonical file. Player presses key, nothing happens.
    rule_actions: set = set()

    def collect_rule_input_actions(d):
        if isinstance(d, dict):
            t = d.get("trigger")
            if isinstance(t, dict) and t.get("type") == "input":
                act = t.get("action", "")
                if isinstance(act, str) and act:
                    rule_actions.add(act)
            for v in d.values():
                collect_rule_input_actions(v)
        elif isinstance(d, list):
            for x in d:
                collect_rule_input_actions(x)

    for path in [
        GAME_DIR / "world" / "rules.json",
        GAME_DIR / "game" / "goals.json",
    ]:
        rj = load_json(path)
        if rj:
            collect_rule_input_actions(rj)
    for lvl_dir in (GAME_DIR / "levels").glob("level_*"):
        p = lvl_dir / "rules.json"
        if p.exists():
            rj = load_json(p)
            if rj:
                collect_rule_input_actions(rj)
    # screens.json global_inputs (action-driven on_press chains)
    sj = load_json(GAME_DIR / "screens.json")
    if sj and isinstance(sj.get("global_inputs"), list):
        for g in sj["global_inputs"]:
            if isinstance(g, dict):
                act = g.get("action", "")
                if isinstance(act, str) and act:
                    rule_actions.add(act)

    for name in declared:
        keys = []
        for a in inputs.get("actions", []):
            if a.get("name") == name:
                keys = a.get("keys", [])
                break
        if not keys:
            continue
        # Coverage 1: HUD controls_hint mentions keybind
        token_match = any(k.lower() in hint_lower for k in keys)
        name_match = name.lower().replace("_", " ") in hint_lower
        if not (token_match or name_match):
            errors.append(
                f"controls_hint missing keybind for action '{name}' "
                f"(keys={keys}). Player has no way to discover this. "
                f"Add to hud.json::controls_hint or prefix the action "
                f"`ui_` if it's a built-in non-discoverable action."
            )
        # Coverage 2: action is consumed by SOME rule or global_input.
        # A declared-but-unconsumed action means pressing the key does
        # nothing — same player perspective as a missing keybind.
        if name not in rule_actions and not name.startswith("move_"):
            errors.append(
                f"action '{name}' declared in ui/input.json with keys="
                f"{keys} but no rule (game/goals.json or world/rules.json "
                f"or screens.json global_inputs) consumes it. Pressing the "
                f"key fires the input but nothing reacts. Either wire a "
                f"rule with trigger.input.action='{name}' OR add "
                f"`reserved: true` to the action def to skip this check."
            )


# ---- check 2: objective text landmarks are labeled or exempt ----

# Collect all current_objective state_set values across rules
def collect_objective_texts(d, out):
    if isinstance(d, dict):
        if d.get("type") == "state_set" and d.get("field") == "current_objective":
            v = d.get("value")
            if isinstance(v, str):
                out.append(v)
        for v in d.values():
            collect_objective_texts(v, out)
    elif isinstance(d, list):
        for x in d:
            collect_objective_texts(x, out)


objectives = []
for rules_path in (GAME_DIR / "game/goals.json",):
    rj = load_json(rules_path)
    if rj:
        collect_objective_texts(rj, objectives)
for lvl_dir in (GAME_DIR / "levels").glob("level_*"):
    lvl_rules = lvl_dir / "rules.json"
    if lvl_rules.exists():
        rj = load_json(lvl_rules)
        if rj:
            collect_objective_texts(rj, objectives)


# Collect all named_npc display_names across entity defs
def collect_named_displays(d, out):
    if isinstance(d, dict):
        if "named_npc" in (d.get("tags") or []):
            dn = (d.get("properties") or {}).get("display_name", "")
            if dn:
                out.append(str(dn).lower())
        for v in d.values():
            collect_named_displays(v, out)
    elif isinstance(d, list):
        for x in d:
            collect_named_displays(x, out)


display_names = []
for entities_dir in (GAME_DIR / "entities",):
    if entities_dir.exists():
        for fp in entities_dir.glob("*.json"):
            ej = load_json(fp)
            if ej:
                collect_named_displays(ej, display_names)
# also instance-level
for lvl_dir in (GAME_DIR / "levels").glob("level_*"):
    lvl_ents = lvl_dir / "entities.json"
    if lvl_ents.exists():
        ej = load_json(lvl_ents)
        if ej:
            collect_named_displays(ej, display_names)

display_set = set(display_names)

# Load exemption file (game-specific list of allowed abstract nouns)
EXEMPT_PATH = GAME_DIR / ".objective_exemptions.txt"
exempt = set()
if EXEMPT_PATH.exists():
    for line in EXEMPT_PATH.read_text(encoding="utf-8").splitlines():
        line = line.strip().lower()
        if line and not line.startswith("#"):
            exempt.add(line)

# Built-in action verbs / direction words / generic nouns the player
# learns through play, not via labels.
BUILTIN_EXEMPT = {
    "north", "south", "east", "west", "left", "right", "up", "down",
    "press", "walk", "click", "tap", "key", "button", "screen", "world",
    "the", "a", "an", "and", "or", "to", "for", "of", "in", "on", "at",
    "your", "you", "yours", "ready", "now", "be", "is", "are",
    "map", "menu", "pause", "save", "load", "settings", "back",
    "day", "night", "morning", "afternoon", "evening", "today",
    "look", "find", "go",
}

# Extract candidate noun phrases ("the fountain", "the shop door",
# "the captain", "Maelgwyn") — heuristic: lowercase nouns of len>=4
# preceded by 'the'.
THE_NOUN_RE = re.compile(r"\bthe\s+([a-z][a-z\-_ ]{2,30})", re.IGNORECASE)
for txt in objectives:
    for m in THE_NOUN_RE.finditer(txt):
        phrase = m.group(1).strip().lower()
        # split possessive trail / period / comma
        phrase = re.split(r"[.,;:]", phrase)[0].strip()
        if not phrase:
            continue
        # skip pure direction / built-in
        if phrase in BUILTIN_EXEMPT:
            continue
        # split into head noun (first 1-2 words)
        head = " ".join(phrase.split()[:2])
        if head in BUILTIN_EXEMPT:
            continue
        # match against display_names case-insensitive substring
        labeled = any(head in dn or dn in head for dn in display_set)
        if labeled:
            continue
        if head in exempt or phrase in exempt:
            continue
        warnings.append(
            f"objective text mentions '{head}' but no named_npc-tagged "
            f"entity has display_name matching it. Player can't see a "
            f"label for this landmark. Either tag the relevant entity "
            f"with named_npc + display_name, OR add '{head}' to "
            f"{EXEMPT_PATH.relative_to(ROOT)} if it's an abstract concept."
        )
        warnings.append(f"  source text: \"{txt[:120]}\"")


# ---- report ----
prefix = f"[{GAME_ARG}]"
if errors:
    print(f"{prefix} FAIL — {len(errors)} player-perspective error(s):")
    for e in errors:
        print(f"  ✗ {e}")
if warnings:
    print(f"{prefix} {len(warnings)} player-perspective warning(s):")
    for w in warnings:
        print(f"  ⚠ {w}")

if not errors and not warnings:
    print(f"{prefix} ok — controls hint covers all inputs; objective landmarks labeled")

if errors and STRICT:
    sys.exit(1)
if warnings and STRICT:
    sys.exit(1)
sys.exit(0)
