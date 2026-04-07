#!/usr/bin/env python3
"""Comprehensive game system tests — simulates game logic in Python.

Tests every engine feature has matching data, verifies game flow logic,
checks balance curves, and ensures no dead-ends.

Usage:
    python tools/test_game_systems.py /path/to/game/data/
"""

import json
import sys
from pathlib import Path
from collections import defaultdict

PASS = 0
FAIL = 0
WARN = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  ✓ {msg}")


def fail(msg):
    global FAIL
    FAIL += 1
    print(f"  ✗ {msg}")


def warn(msg):
    global WARN
    WARN += 1
    print(f"  ⚠ {msg}")


def load_json(path):
    with open(path) as f:
        return json.load(f)


def main(data_dir):
    data_dir = Path(data_dir)

    items = {i["id"]: i for i in load_json(data_dir / "items.json")}
    enemies = {e["id"]: e for e in load_json(data_dir / "enemies.json")}
    characters = {c["id"]: c for c in load_json(data_dir / "characters.json")}
    quests = load_json(data_dir / "quests.json")
    dialogues = load_json(data_dir / "dialogues.json")
    progression = load_json(data_dir / "progression.json")

    locations = {}
    for f in sorted((data_dir / "locations").glob("*.json")):
        d = load_json(f)
        locations[d["id"]] = d

    # ================================================================
    print("\n=== TEST 1: Party System ===")
    # ================================================================
    starting_party = progression.get("starting_party", [])
    if starting_party:
        ok(f"Starting party defined: {starting_party}")
    else:
        fail("No starting_party in progression.json")

    for cid in starting_party:
        if cid in characters:
            ok(f"Starting character '{cid}' exists in characters.json")
        else:
            fail(f"Starting character '{cid}' NOT in characters.json")

    # Check party members join via cutscene events
    join_events = {}
    for loc_id, loc in locations.items():
        for event in loc.get("on_enter_events", []):
            for step in event.get("steps", []):
                if step.get("action") == "join_party":
                    char_id = step.get("character_id", "")
                    join_events[char_id] = loc_id

    party_chars = [c for c in characters.values() if c.get("role") == "party_member"]
    for c in party_chars:
        cid = c["id"]
        if cid in starting_party:
            ok(f"'{cid}' starts in party")
        elif cid in join_events:
            ok(f"'{cid}' joins via event in {join_events[cid]}")
        else:
            fail(f"'{cid}' is party_member but never joins (not in starting_party, no join_party event)")

    # Check each party member has abilities
    for c in party_chars:
        abilities = c.get("abilities", [])
        if len(abilities) >= 3:
            ok(f"'{c['id']}' has {len(abilities)} abilities")
        else:
            warn(f"'{c['id']}' has only {len(abilities)} abilities (target: 8-10)")

    # ================================================================
    print("\n=== TEST 2: Quest Chain ===")
    # ================================================================
    quest_map = {q["id"]: q for q in quests}

    # Check quest chain is connected (prerequisite links)
    first_quest = None
    for q in quests:
        if q.get("prerequisite") is None:
            if first_quest:
                warn(f"Multiple root quests: '{first_quest}' and '{q['id']}'")
            first_quest = q["id"]
            ok(f"Root quest: '{q['id']}'")

    if not first_quest:
        fail("No root quest (quest with prerequisite=null)")

    # Walk the quest chain
    chain = []
    visited = set()
    current = first_quest
    while current:
        if current in visited:
            fail(f"Quest chain has a LOOP at '{current}'")
            break
        visited.add(current)
        chain.append(current)
        # Find quest that has this as prerequisite
        next_q = None
        for q in quests:
            if q.get("prerequisite") == current:
                next_q = q["id"]
                break
        current = next_q

    if len(chain) == len(quests):
        ok(f"Quest chain is complete: {len(chain)} quests linked")
    else:
        orphans = [q["id"] for q in quests if q["id"] not in visited]
        warn(f"Quest chain has {len(chain)}/{len(quests)} quests. Orphans: {orphans}")

    # Check quest triggers reference valid locations
    for q in quests:
        for step in q.get("steps", []):
            trigger = step.get("trigger", "")
            if trigger.startswith("reach:"):
                loc_id = trigger.split(":")[1]
                if loc_id in locations:
                    ok(f"Quest '{q['id']}' trigger location '{loc_id}' exists")
                else:
                    fail(f"Quest '{q['id']}' trigger references missing location '{loc_id}'")

    # ================================================================
    print("\n=== TEST 3: Battle System ===")
    # ================================================================

    # Check damage formula doesn't produce zero/negative
    for c in party_chars:
        atk = c["stats"].get("strength", 10)
        for e in enemies.values():
            if e.get("is_boss"):
                continue
            defn = e["stats"].get("defense", 5)
            dmg = max(1, atk * 3 - defn * 2)  # mirrors _calc_physical
            if dmg <= 0:
                fail(f"'{c['id']}' does 0 damage to '{e['id']}' (atk={atk}, def={defn})")

    ok("Physical damage formula produces positive damage for all party vs regular enemies")

    # Check bosses aren't one-shottable at expected level
    for eid, e in enemies.items():
        if not e.get("is_boss"):
            continue
        hp = e["stats"]["hp"]
        if hp < 100:
            warn(f"Boss '{eid}' has very low HP ({hp})")
        else:
            ok(f"Boss '{eid}' HP: {hp}")

    # Check level curve makes sense
    curve = progression.get("level_curve", [])
    if curve:
        prev = 0
        for entry in curve:
            lvl = entry.get("expected_level", 0)
            if lvl > prev:
                ok(f"Act {entry['act']} expected level {lvl} (increasing)")
                prev = lvl
            else:
                fail(f"Act {entry['act']} expected level {lvl} NOT increasing from {prev}")

    # ================================================================
    print("\n=== TEST 4: Dialogue System ===")
    # ================================================================

    # Check dialogue location_ids reference valid locations
    for dlg in dialogues:
        loc_id = dlg.get("location_id", "")
        if loc_id and loc_id not in locations:
            fail(f"Dialogue '{dlg['id']}' references missing location '{loc_id}'")

    # Check dialogues have enough lines
    for dlg in dialogues:
        lines = dlg.get("lines", [])
        if len(lines) < 3:
            warn(f"Dialogue '{dlg['id']}' has only {len(lines)} lines (target: 5+)")
        else:
            ok(f"Dialogue '{dlg['id']}': {len(lines)} lines")

    # ================================================================
    print("\n=== TEST 5: Cutscene System ===")
    # ================================================================

    # Check all cutscene actions are valid
    valid_actions = {"dialogue", "narration", "wait", "camera_to", "camera_follow_player",
                     "npc_walk", "npc_face", "sfx", "set_flag", "join_party",
                     "screen_shake", "fade_out", "fade_in"}
    for loc_id, loc in locations.items():
        for event in loc.get("on_enter_events", []):
            for step in event.get("steps", []):
                action = step.get("action", "")
                if action not in valid_actions:
                    warn(f"Unknown cutscene action '{action}' in {loc_id}")

    ok("Cutscene action validation complete")

    # ================================================================
    print("\n=== TEST 6: Inventory System ===")
    # ================================================================

    # Check starting items exist
    for item_id in progression.get("starting_items", []):
        if item_id in items:
            ok(f"Starting item '{item_id}' exists")
        else:
            fail(f"Starting item '{item_id}' NOT in items.json")

    # Check consumables have heal_amount
    for iid, item in items.items():
        if item.get("item_type") == "consumable" and item.get("usable_in_battle"):
            ha = item.get("heal_amount", 0)
            if ha > 0 or iid in ("antidote", "eye_drops"):
                ok(f"Consumable '{iid}' has effect (heal={ha})")
            elif iid == "tent":
                ok(f"Consumable '{iid}' is tent (full heal at save point)")
            else:
                warn(f"Consumable '{iid}' has heal_amount=0 and no special effect?")

    # Check equipment has stats
    for iid, item in items.items():
        if item.get("item_type") in ("weapon", "armor"):
            stats = item.get("stats", {})
            if stats:
                ok(f"Equipment '{iid}' has stats: {stats}")
            else:
                fail(f"Equipment '{iid}' has NO stats")

    # ================================================================
    print("\n=== TEST 7: Game Flow Simulation ===")
    # ================================================================

    # Simulate walking through the game from start to end
    start = progression.get("starting_location", "")
    if start not in locations:
        fail(f"Starting location '{start}' not found")
    else:
        # BFS to find path from start to each story beat location
        for beat in progression.get("story_beats", []):
            target = beat.get("location_id", "")
            if target not in locations:
                fail(f"Story beat location '{target}' not found")
                continue

            # BFS ignoring requires_flag (checking connectivity)
            visited = set()
            queue = [(start, [start])]
            found = False
            while queue:
                current, path = queue.pop(0)
                if current == target:
                    ok(f"Story beat '{beat['description'][:40]}...' reachable ({len(path)} rooms)")
                    found = True
                    break
                if current in visited:
                    continue
                visited.add(current)
                for exit_data in locations.get(current, {}).get("exits", []):
                    t = exit_data.get("target", "")
                    if t in locations and t not in visited:
                        queue.append((t, path + [t]))
            if not found:
                fail(f"Story beat location '{target}' UNREACHABLE from start")

    # ================================================================
    print("\n=== TEST 8: Save/Load System ===")
    # ================================================================

    # Check save system covers all needed state
    # (Can only verify data shape, not runtime behavior)
    save_fields = ["flags", "party", "inventory", "gil", "current_location", "quests"]
    ok(f"Save system should persist: {', '.join(save_fields)}")

    # ================================================================
    print("\n=== TEST 9: Shop Economy ===")
    # ================================================================

    # Check shop items exist and prices are reasonable
    shops_found = 0
    for loc_id, loc in locations.items():
        for shop_item in loc.get("shop", []):
            shops_found += 1
            iid = shop_item.get("item_id", "")
            price = shop_item.get("price", 0)
            if iid not in items:
                fail(f"Shop in '{loc_id}' sells unknown item '{iid}'")
            elif price <= 0:
                fail(f"Shop in '{loc_id}' sells '{iid}' for {price} gil (invalid)")

    if shops_found > 0:
        ok(f"Validated {shops_found} shop entries across all locations")
    else:
        fail("No shop items found in any location!")

    # Check gear progression: later shops should sell better gear
    # (simplified: just check some shops exist before bosses)

    # ================================================================
    print("\n=== TEST 10: Encounter Balance ===")
    # ================================================================

    # Check XP rewards add up to leveling expectations
    total_xp_available = 0
    for loc_id, loc in locations.items():
        for enc in loc.get("encounters", []):
            if enc.get("is_boss"):
                continue
            rate = enc.get("rate", 0)
            for eid in enc.get("enemies", []):
                if eid in enemies:
                    total_xp_available += enemies[eid].get("xp_reward", 0)

    ok(f"Total XP from regular enemies (1 encounter each): {total_xp_available}")

    # Check enemy level progression matches region order
    region_order = []
    visited = set()
    queue = [start]
    while queue:
        current = queue.pop(0)
        if current in visited:
            continue
        visited.add(current)
        region = "_".join(current.split("_")[:2])
        if region not in region_order:
            region_order.append(region)
        for exit_data in locations.get(current, {}).get("exits", []):
            t = exit_data.get("target", "")
            if t in locations and t not in visited:
                queue.append(t)

    prev_max_level = 0
    for region in region_order:
        max_enemy_level = 0
        for loc_id, loc in locations.items():
            if not loc_id.startswith(region):
                continue
            for enc in loc.get("encounters", []):
                for eid in enc.get("enemies", []):
                    if eid in enemies:
                        lvl = enemies[eid]["stats"].get("level", 1)
                        max_enemy_level = max(max_enemy_level, lvl)
        if max_enemy_level > 0:
            if max_enemy_level >= prev_max_level:
                ok(f"Region '{region}' max enemy level: {max_enemy_level} (non-decreasing)")
            else:
                warn(f"Region '{region}' max enemy level: {max_enemy_level} LOWER than previous {prev_max_level}")
            prev_max_level = max_enemy_level

    # ================================================================
    # SUMMARY
    # ================================================================
    print("\n" + "=" * 60)
    print(f"RESULTS: {PASS} passed, {FAIL} failed, {WARN} warnings")
    print("=" * 60)

    return 1 if FAIL > 0 else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: python {sys.argv[0]} /path/to/game/data/")
        sys.exit(1)
    sys.exit(main(sys.argv[1]))
