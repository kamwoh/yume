#!/usr/bin/env python3
"""Validate game data integrity — catches 80% of bugs without running Godot.

Usage:
    python tools/validate_game_data.py /path/to/game/data/
    python tools/validate_game_data.py /mnt/c/Users/kamwoh/Documents/Projects/Godot/FF9/data/
"""

import json
import sys
import os
from pathlib import Path
from collections import defaultdict


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        return {"__error__": str(e)}


def main(data_dir):
    data_dir = Path(data_dir)
    errors = []
    warnings = []
    stats = defaultdict(int)

    # Load all data files
    items = {i["id"]: i for i in load_json(data_dir / "items.json")} if (data_dir / "items.json").exists() else {}
    enemies = {e["id"]: e for e in load_json(data_dir / "enemies.json")} if (data_dir / "enemies.json").exists() else {}
    characters = {c["id"]: c for c in load_json(data_dir / "characters.json")} if (data_dir / "characters.json").exists() else {}
    quests = {q["id"]: q for q in load_json(data_dir / "quests.json")} if (data_dir / "quests.json").exists() else {}
    progression = load_json(data_dir / "progression.json") if (data_dir / "progression.json").exists() else {}

    # Load all locations
    loc_dir = data_dir / "locations"
    locations = {}
    if loc_dir.exists():
        for f in sorted(loc_dir.glob("*.json")):
            d = load_json(f)
            if "__error__" in d:
                errors.append(f"PARSE ERROR: {f.name} — {d['__error__']}")
                continue
            locations[d["id"]] = d
            stats["locations"] += 1

    if not locations:
        print("ERROR: No locations found!")
        return 1

    # Collect all flags that get SET somewhere
    flags_set = set()
    for loc in locations.values():
        for event in loc.get("on_enter_events", []):
            for step in event.get("steps", []):
                if step.get("action") == "set_flag":
                    flags_set.add(step.get("flag", ""))

    print(f"Loaded: {len(locations)} locations, {len(items)} items, {len(enemies)} enemies, {len(characters)} characters, {len(quests)} quests")
    print(f"Flags defined: {len(flags_set)}")
    print()

    # === CHECK 1: Exit targets exist ===
    print("--- Exit References ---")
    for loc_id, loc in locations.items():
        for exit_data in loc.get("exits", []):
            target = exit_data.get("target", "")
            if target and target not in locations:
                errors.append(f"BROKEN EXIT: {loc_id} → {target} (target doesn't exist)")
            # Check requires_flag references a flag that gets set
            req_flag = exit_data.get("requires_flag", "")
            if req_flag and req_flag not in flags_set:
                warnings.append(f"GATE FLAG NEVER SET: {loc_id} exit requires '{req_flag}' but no event sets it")
    stats["exit_checks"] = sum(len(l.get("exits", [])) for l in locations.values())

    # === CHECK 2: Treasure item_ids exist ===
    print("--- Treasure References ---")
    for loc_id, loc in locations.items():
        for t in loc.get("treasures", []):
            item_id = t.get("item_id", "")
            if item_id and item_id not in items and not item_id.startswith("gil_"):
                warnings.append(f"UNKNOWN ITEM: {loc_id} treasure '{item_id}' not in items.json")
        stats["treasures"] += len(loc.get("treasures", []))

    # === CHECK 3: Encounter enemy IDs exist ===
    print("--- Encounter References ---")
    for loc_id, loc in locations.items():
        for enc in loc.get("encounters", []):
            for eid in enc.get("enemies", []):
                if eid not in enemies:
                    errors.append(f"UNKNOWN ENEMY: {loc_id} encounter references '{eid}' not in enemies.json")
            if enc.get("is_boss"):
                stats["bosses"] += 1

    # === CHECK 4: Reachability (graph walk from starting location) ===
    print("--- Reachability ---")
    start = progression.get("starting_location", "")
    if start and start in locations:
        visited = set()
        queue = [start]
        while queue:
            current = queue.pop(0)
            if current in visited:
                continue
            visited.add(current)
            for exit_data in locations.get(current, {}).get("exits", []):
                target = exit_data.get("target", "")
                if target in locations and target not in visited:
                    queue.append(target)
        unreachable = set(locations.keys()) - visited
        if unreachable:
            for u in sorted(unreachable):
                warnings.append(f"UNREACHABLE: {u} — cannot be reached from {start}")
        stats["reachable"] = len(visited)
        stats["unreachable"] = len(unreachable)
    else:
        errors.append(f"INVALID START: starting_location '{start}' not found")

    # === CHECK 5: Content density ===
    print("--- Content Density ---")
    for loc_id, loc in locations.items():
        t_count = len(loc.get("treasures", []))
        n_count = len(loc.get("ambient_npcs", [])) + len(loc.get("story_npcs", []))
        e_count = sum(len(ev.get("steps", [])) for ev in loc.get("on_enter_events", []))

        if t_count < 2:
            warnings.append(f"LOW DENSITY: {loc_id} has only {t_count} treasures (target: 3-6)")
        if t_count == 0:
            errors.append(f"EMPTY ROOM: {loc_id} has ZERO treasures")
        if n_count == 0 and e_count <= 1 and loc.get("type") == "town":
            warnings.append(f"SILENT TOWN: {loc_id} has 0 NPCs and ≤1 event step")

    # === CHECK 6: NPC quest-state dialogue ===
    print("--- NPC Quality ---")
    for loc_id, loc in locations.items():
        for npc in loc.get("ambient_npcs", []):
            if "dialogue_states" not in npc and "dialogues_by_quest" not in npc:
                warnings.append(f"STATIC NPC: {loc_id} NPC '{npc.get('name', '?')}' has no quest-state dialogue")
        stats["npcs"] += len(loc.get("ambient_npcs", []))

    # === CHECK 7: Boss steal lists ===
    print("--- Boss Quality ---")
    for eid, enemy in enemies.items():
        if enemy.get("is_boss") and not enemy.get("steal_table"):
            warnings.append(f"BOSS NO STEALS: boss '{eid}' has no steal_table")

    # === CHECK 8: Cutscene-Room Consistency ===
    print("--- Cutscene-Room Consistency ---")
    gs_path = data_dir / "game_state.json"
    if gs_path.exists():
        gs = load_json(gs_path)
        for phase in gs.get("phases", []):
            trigger = phase.get("trigger", "")
            if trigger.startswith("reach:"):
                loc_id = trigger.split(":", 1)[1]
                if loc_id not in locations:
                    errors.append(f"PHASE '{phase.get('id','')}' triggers on non-existent location '{loc_id}'")
                else:
                    # Check: characters mentioned in cutscene should exist in the room
                    loc = locations[loc_id]
                    room_npcs = set()
                    for npc in loc.get("ambient_npcs", []):
                        room_npcs.add(npc.get("name", "").lower())
                    for npc in loc.get("story_npcs", []):
                        room_npcs.add(npc.get("name", "").lower())

                    for step in phase.get("cutscene", []):
                        speaker = step.get("speaker", "")
                        text = step.get("text", "")
                        if speaker and speaker not in ("", "???"):
                            # Check if speaker is a party member (they're always "present")
                            party_names = set()
                            for c in characters.values():
                                if c.get("role") == "party_member":
                                    party_names.add(c.get("id", "").lower())
                                    party_names.add(c.get("name", "").lower())
                                    # Also add first name (e.g. "Adelbert Steiner" → "steiner")
                                    for part in c.get("name", "").lower().split():
                                        party_names.add(part)
                            is_party = speaker.lower() in party_names
                            is_in_room = speaker.lower() in room_npcs
                            if not is_party and not is_in_room:
                                warnings.append(f"CUTSCENE-ROOM MISMATCH: Phase '{phase.get('id','')}' has speaker '{speaker}' but they're not in room '{loc_id}' and not a party member")

    # === CHECK 9: Hardcoded values in progression ===
    print("--- Data Consistency ---")
    if progression:
        sp = progression.get("starting_party", [])
        sl = progression.get("starting_location", "")
        if sl and sl not in locations:
            errors.append(f"starting_location '{sl}' not in locations")
        for cid in sp:
            if cid not in characters:
                errors.append(f"starting_party member '{cid}' not in characters")
        if len(sp) > 1:
            warnings.append(f"starting_party has {len(sp)} members — should party members join via game_state phases instead?")

    # === CHECK 10: Dialog ownership ===
    print("--- Dialog Ownership ---")
    dlg_path = data_dir / "dialogues.json"
    if dlg_path.exists():
        dlgs = load_json(dlg_path)
        if isinstance(dlgs, list):
            for d in dlgs:
                trigger = d.get("trigger_condition", "")
                if trigger == "auto":
                    errors.append(f"DIALOG OWNERSHIP: '{d.get('id','')}' has trigger_condition='auto' — this should be in game_state.json, not dialogues.json")
                elif trigger.startswith("quest:"):
                    errors.append(f"DIALOG OWNERSHIP: '{d.get('id','')}' has quest trigger — this should be in game_state.json, not dialogues.json")

    # === CHECK 11: Shop placement ===
    print("--- Shop Coverage ---")
    regions_with_shops = set()
    for loc_id, loc in locations.items():
        if loc.get("shop"):
            region = "_".join(loc_id.split("_")[:2])
            regions_with_shops.add(region)
    all_regions = set("_".join(lid.split("_")[:2]) for lid in locations)
    regions_without = all_regions - regions_with_shops
    for r in sorted(regions_without):
        warnings.append(f"NO SHOP: region '{r}' has no shop")

    # === REPORT ===
    print()
    print("=" * 60)
    print(f"RESULTS: {len(errors)} errors, {len(warnings)} warnings")
    print("=" * 60)

    if errors:
        print(f"\n🔴 ERRORS ({len(errors)}):")
        for e in sorted(errors):
            print(f"  {e}")

    if warnings:
        print(f"\n🟡 WARNINGS ({len(warnings)}):")
        for w in sorted(warnings):
            print(f"  {w}")

    print(f"\n📊 STATS:")
    print(f"  Locations: {stats['locations']}")
    print(f"  Treasures: {stats['treasures']} ({stats['treasures']/max(stats['locations'],1):.1f}/room)")
    print(f"  NPCs: {stats['npcs']}")
    print(f"  Bosses: {stats['bosses']}")
    print(f"  Reachable: {stats.get('reachable', '?')}/{stats['locations']}")
    print(f"  Unreachable: {stats.get('unreachable', '?')}")
    print(f"  Exit links checked: {stats['exit_checks']}")

    return 1 if errors else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: python {sys.argv[0]} /path/to/game/data/")
        sys.exit(1)
    sys.exit(main(sys.argv[1]))
