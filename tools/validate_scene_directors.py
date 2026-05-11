#!/usr/bin/env python3
"""
Static validator for per-game scene director nodes.

Yume's engine ships several "director" Node scripts (ScheduleDirector,
PartyDirector, FactionDirector, etc.) that the engine calls each tick
or at world load. Each director drains its subsystem's state from JSON
content (schedule blocks, party_member tags, faction defs, etc.).

If a game's content REFERENCES a subsystem but the director Node isn't
mounted in the game's per-game `.tscn`, the engine silently no-ops:

- Entity defs with `schedule:` blocks but no ScheduleDirector → NPCs sit
  motionless; engine never sets current_verb.
- Entities tagged `party_member` but no PartyDirector → followers don't
  leash behind the leader.
- factions.json present but no FactionDirector → faction bindings
  resolve to empty.

These bugs surface as "everything looks correct in the JSON but
nothing happens at runtime." This validator catches them at sync time.

Usage:
    python3 tools/validate_scene_directors.py                # all demos
    python3 tools/validate_scene_directors.py demo_aldenmere # one game
    python3 tools/validate_scene_directors.py --strict       # exit 1

Wired into scripts/play.sh as a non-blocking pre-launch check;
agents/CI use --strict.

Empirical case 2026-05-11: aldenmere_3d.tscn shipped without
ScheduleDirector mounted; all 8 villagers (Morwen + 7 others) sat
motionless despite each def having a schedule block. User caught it
manually after asking why animation looked broken.
"""

import json
import os
import sys
from pathlib import Path
import re


# Map from director Node name (the name in .tscn) to detection rules
# for whether the game uses that subsystem. Each detection rule:
#   - "entity_state_key": entity def has this key in its dict (e.g.,
#     defs with a "schedule" block use ScheduleDirector)
#   - "entity_tag": entity def has this tag in its tags array (e.g.,
#     a "party_member" tag implies PartyDirector)
#   - "file_present": a file at the given relative path triggers the
#     director (e.g., factions.json implies FactionDirector)
DIRECTOR_RULES = {
    "ScheduleDirector": {
        "entity_state_key": "schedule",
        "reason": "entity def(s) declare a `schedule:` block (ADR 0029) — "
                  "without ScheduleDirector mounted, the engine never resolves "
                  "slots → current_verb / current_target stay empty → NPCs sit "
                  "motionless.",
    },
    "PartyDirector": {
        "entity_tag": "party_member",
        "reason": "entity def(s) tagged `party_member` (ADR 0026) — "
                  "without PartyDirector mounted, followers won't leash behind "
                  "the leader.",
    },
    "FactionDirector": {
        "file_present": "factions.json",
        "reason": "factions.json exists (ADR 0032) — without FactionDirector "
                  "mounted, faction bindings resolve to empty.",
    },
    "DynastyDirector": {
        "entity_state_key": "lineage_id",
        "reason": "entity def(s) declare a `lineage_id` (ADR 0034) — "
                  "without DynastyDirector mounted, dynasty heirs / lineage "
                  "transitions never fire.",
    },
    "LightingDirector": {
        "scene_key": "lighting",
        "reason": "scene.json declares a `lighting` block (ADR 0025) — "
                  "without LightingDirector mounted, day/night cycle + "
                  "seasonal palette won't apply.",
    },
}


def find_game_scene(repo_root, game_name):
    """Locate the game's .tscn. Convention: `scenes/<game>.tscn` or
    `scenes/<game>_3d.tscn` or `scenes/<game>_2d.tscn`."""
    scenes_dir = repo_root / "godot" / "scenes"
    candidates = [
        scenes_dir / f"{game_name}_3d.tscn",
        scenes_dir / f"{game_name}.tscn",
        scenes_dir / f"{game_name}_2d.tscn",
    ]
    # Strip the demo_ prefix too
    if game_name.startswith("demo_"):
        slug = game_name[5:]
        candidates += [
            scenes_dir / f"{slug}_3d.tscn",
            scenes_dir / f"{slug}.tscn",
            scenes_dir / f"{slug}_2d.tscn",
        ]
    for c in candidates:
        if c.exists(): return c
    return None


def collect_mounted_director_nodes(tscn_path):
    """Parse the .tscn for `[node name="X" type="..."]` declarations.
    Returns set of mounted Node names."""
    out = set()
    try:
        txt = tscn_path.read_text()
    except Exception:
        return out
    for m in re.finditer(r'\[node name="([^"]+)"', txt):
        out.add(m.group(1))
    return out


def collect_entity_defs(game_dir):
    """Return list of (def_id, def_dict) across entities.json + entities/*.json."""
    out = []
    single = game_dir / "entities.json"
    if single.exists():
        try:
            doc = json.loads(single.read_text())
            for d in doc.get("definitions", []):
                if isinstance(d, dict): out.append((d.get("id", ""), d))
        except json.JSONDecodeError:
            pass
    ents_dir = game_dir / "entities"
    if ents_dir.exists() and ents_dir.is_dir():
        for f in sorted(ents_dir.rglob("*.json")):
            try:
                doc = json.loads(f.read_text())
            except json.JSONDecodeError:
                continue
            for d in doc.get("definitions", []):
                if isinstance(d, dict): out.append((d.get("id", ""), d))
    return out


def read_scene_json(game_dir):
    """Return parsed scene.json or empty dict."""
    p = game_dir / "scene.json"
    if not p.exists(): return {}
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError:
        return {}


def detect_uses(game_dir, rule):
    """Return True iff the game uses the subsystem this rule describes."""
    if "entity_state_key" in rule:
        key = rule["entity_state_key"]
        for _id, d in collect_entity_defs(game_dir):
            if key in d: return True
        return False
    if "entity_tag" in rule:
        tag = rule["entity_tag"]
        for _id, d in collect_entity_defs(game_dir):
            tags = d.get("tags", [])
            if isinstance(tags, list) and tag in tags: return True
        return False
    if "file_present" in rule:
        return (game_dir / rule["file_present"]).exists()
    if "scene_key" in rule:
        scene = read_scene_json(game_dir)
        return rule["scene_key"] in scene
    return False


def validate_game(game_dir, repo_root, strict=False):
    game_dir = Path(game_dir)
    game_name = game_dir.name
    issues = []
    scene = find_game_scene(repo_root, game_name)
    if scene is None:
        # Some games might not have a .tscn (test-only). Silently skip.
        return issues
    mounted = collect_mounted_director_nodes(scene)

    for director_name, rule in DIRECTOR_RULES.items():
        uses = detect_uses(game_dir, rule)
        if uses and director_name not in mounted:
            issues.append({
                "director": director_name,
                "scene": str(scene.relative_to(repo_root)),
                "reason": rule["reason"],
            })

    return issues


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

    total_issues = 0
    for game_dir in sorted(targets):
        if not game_dir.exists():
            print(f"[skip] {game_dir} (not found)")
            continue
        issues = validate_game(game_dir, repo_root, strict=strict)
        if issues:
            label = "FAIL" if strict else "WARN"
            print(f"[{label}] {game_dir.name} ({len(issues)} missing director node(s)):")
            for it in issues:
                print(f"  {it['scene']} is missing <{it['director']}>")
                print(f"    reason: {it['reason']}")
            total_issues += len(issues)
        else:
            print(f"[ok] {game_dir.name}")

    if total_issues:
        print(f"\n{total_issues} scene-director gap(s).")
        print("Add a [node name=\"<Director>\" type=\"Node\" parent=\".\"] "
              "with the matching script= line to each affected .tscn.")
        if strict:
            sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
