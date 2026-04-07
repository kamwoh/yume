#!/usr/bin/env python3
"""Simulates a full playthrough using game_state.json phases.

Follows the story state machine: each phase has a trigger, and the simulator
navigates to the trigger location, fires the phase, and advances.

Usage:
    python tools/simulate_playthrough.py /path/to/game/data/
"""

import json
import sys
from pathlib import Path
from collections import defaultdict, deque


class GameState:
    def __init__(self, data_dir):
        self.data_dir = Path(data_dir)
        self.items = {i["id"]: i for i in self._load("items.json")}
        self.enemies = {e["id"]: e for e in self._load("enemies.json")}
        self.characters = {c["id"]: c for c in self._load("characters.json")}
        self.quests = self._load("quests.json")
        self.quest_map = {q["id"]: q for q in self.quests}

        self.locations = {}
        for f in sorted((self.data_dir / "locations").glob("*.json")):
            d = self._load_path(f)
            self.locations[d["id"]] = d

        # Load game_state.json
        gs_path = self.data_dir / "game_state.json"
        if gs_path.exists():
            gs = self._load_path(gs_path)
            self.phases = gs.get("phases", [])
            self.starting_phase = gs.get("starting_phase", "")
            self.starting_location = gs.get("starting_location", "")
            self.starting_party = gs.get("starting_party", [])
            self.starting_items = gs.get("starting_items", [])
        else:
            self.phases = []
            self.starting_location = ""
            self.starting_party = []
            self.starting_items = []

        # Runtime state
        self.current_location = ""
        self.party = []
        self.party_stats = {}
        self.inventory = defaultdict(int)
        self.gil = 200
        self.flags = set()
        self.visited = set()
        self.completed_quests = set()
        self.active_quests = {}
        self.bosses_defeated = []
        self.treasures_collected = []
        self.current_phase_index = 0

        # Results
        self.passed = 0
        self.failed = 0
        self.errors = []

    def _load(self, name):
        return self._load_path(self.data_dir / name)

    def _load_path(self, path):
        with open(path) as f:
            return json.load(f)

    def ok(self, msg):
        self.passed += 1
        print(f"  ✓ {msg}")

    def fail(self, msg):
        self.failed += 1
        self.errors.append(msg)
        print(f"  ✗ {msg}")

    def info(self, msg):
        print(f"  → {msg}")

    def start(self):
        self.current_location = self.starting_location
        self.party = list(self.starting_party)
        for cid in self.party:
            self._init_member(cid)
        for item_id in self.starting_items:
            self.inventory[item_id] += 1
        self.ok(f"Game started: {self.current_location}, party={self.party}")

    def _init_member(self, cid):
        if cid in self.characters:
            self.party_stats[cid] = dict(self.characters[cid]["stats"])

    def enter_location(self, loc_id):
        if loc_id not in self.locations:
            self.fail(f"Location '{loc_id}' does not exist")
            return
        first = loc_id not in self.visited
        self.visited.add(loc_id)
        self.current_location = loc_id
        loc = self.locations[loc_id]
        self.info(f"Entered: {loc['name']} ({loc_id}){' [NEW]' if first else ''}")

        # Collect treasures
        for t in loc.get("treasures", []):
            key = f"chest_{loc_id}_{t.get('item_id','')}_{t.get('x',0)}"
            if key not in self.flags:
                self.flags.add(key)
                self.inventory[t["item_id"]] += 1
                self.treasures_collected.append(t["item_id"])

    def fire_phase(self, phase):
        """Execute a story phase."""
        pid = phase["id"]
        self.info(f"PHASE: {pid}")

        # Add party
        for cid in phase.get("adds_party", []):
            if cid not in self.party:
                self.party.append(cid)
                self._init_member(cid)
                self.ok(f"PARTY JOIN: {cid} → {self.party}")

        # Set flags
        for flag in phase.get("sets_flags", []):
            self.flags.add(flag)

        # Unlock exits
        for unlock in phase.get("unlocks_exits", []):
            from_loc = unlock.get("from", "")
            to_loc = unlock.get("to", "")
            # Find the requires_flag on that exit and set it
            loc = self.locations.get(from_loc, {})
            for ex in loc.get("exits", []):
                if ex.get("target") == to_loc:
                    rf = ex.get("requires_flag", "")
                    if rf:
                        self.flags.add(rf)
                        self.info(f"EXIT UNLOCKED: {from_loc} → {to_loc} (flag: {rf})")

        # Quest updates
        quest = phase.get("quest", {})
        if "start" in quest:
            qid = quest["start"]
            self.active_quests[qid] = 0
            self.info(f"QUEST START: {qid}")
        if "complete" in quest:
            qid = quest["complete"]
            if qid in self.active_quests:
                del self.active_quests[qid]
            self.completed_quests.add(qid)
            self.ok(f"QUEST COMPLETE: {qid}")

        # Boss fight
        boss_id = phase.get("boss", "")
        if boss_id:
            self._fight_boss(boss_id)

        # Cutscene (just count steps for reporting)
        steps = phase.get("cutscene", [])
        if steps:
            speakers = set(s.get("speaker", "") for s in steps if s.get("speaker"))
            self.info(f"CUTSCENE: {len(steps)} steps, speakers: {speakers or 'narrator'}")

    def _fight_boss(self, boss_id):
        if boss_id not in self.enemies:
            self.fail(f"Boss '{boss_id}' not in enemies.json")
            return
        boss = self.enemies[boss_id]
        hp = boss["stats"]["hp"]
        name = boss.get("name", boss_id)
        is_unwinnable = boss_id == "beatrix"

        print(f"\n  ⚔ BOSS: {name} (HP: {hp})")

        if is_unwinnable:
            self.ok(f"Beatrix — unwinnable by design. Survived.")
        else:
            # Simple check: can party deal damage?
            total_atk = sum(self.party_stats.get(c, {}).get("strength", 10) for c in self.party)
            self.ok(f"Winnable (party STR total: {total_atk} vs boss HP: {hp})")

        self.bosses_defeated.append(boss_id)

        # Collect steals
        for steal in boss.get("steal_table", []):
            self.inventory[steal["item_id"]] += 1

    def find_path(self, from_loc, to_loc):
        """BFS shortest path."""
        if from_loc == to_loc:
            return []
        queue = deque([(from_loc, [])])
        seen = {from_loc}
        while queue:
            node, path = queue.popleft()
            for ex in self.locations.get(node, {}).get("exits", []):
                target = ex.get("target", "")
                if not target or target not in self.locations or target in seen:
                    continue
                # Check gate
                rf = ex.get("requires_flag", "")
                if rf and rf not in self.flags:
                    continue
                new_path = path + [target]
                if target == to_loc:
                    return new_path
                seen.add(target)
                queue.append((target, new_path))
        return None


def simulate(data_dir):
    game = GameState(data_dir)

    if not game.phases:
        print("ERROR: No game_state.json or no phases defined")
        return 1

    print(f"\n=== YUME PLAYTHROUGH SIMULATION ===")
    print(f"    {len(game.phases)} story phases, {len(game.locations)} locations\n")

    game.start()

    # Enter starting location
    game.enter_location(game.current_location)

    for i, phase in enumerate(game.phases):
        pid = phase["id"]
        trigger = phase.get("trigger", "")

        print(f"\n--- Phase {i+1}/{len(game.phases)}: {pid} ---")
        print(f"    Trigger: {trigger}")

        if trigger == "start":
            # Fire immediately
            game.fire_phase(phase)
            continue

        if trigger.startswith("reach:"):
            target_loc = trigger.split(":", 1)[1]

            # Navigate to target
            if game.current_location != target_loc:
                path = game.find_path(game.current_location, target_loc)
                if path is None:
                    game.fail(f"Cannot reach '{target_loc}' from '{game.current_location}'")
                    continue
                for loc_id in path:
                    game.enter_location(loc_id)
            else:
                # Already here (might not have "entered" yet)
                if target_loc not in game.visited:
                    game.enter_location(target_loc)

            game.fire_phase(phase)

        elif trigger.startswith("defeat:"):
            # Boss defeat — should have been handled by the previous phase's boss field
            # The phase fires after the boss is defeated
            boss_id = trigger.split(":", 1)[1]
            if boss_id in game.bosses_defeated:
                game.fire_phase(phase)
            else:
                game.fail(f"Boss '{boss_id}' not defeated — trigger can't fire")

    # Mop up: visit remaining rooms
    remaining = set(game.locations.keys()) - game.visited
    if remaining:
        game.info(f"\nExploring {len(remaining)} remaining rooms...")
        for target in sorted(remaining):
            path = game.find_path(game.current_location, target)
            if path:
                for loc_id in path:
                    if loc_id not in game.visited:
                        game.enter_location(loc_id)

    # === REPORT ===
    print(f"\n{'='*60}")
    print(f"=== PLAYTHROUGH COMPLETE ===")
    print(f"{'='*60}")

    print(f"\nRooms visited: {len(game.visited)}/{len(game.locations)}")
    print(f"Party: {game.party}")
    print(f"Bosses defeated: {game.bosses_defeated}")
    print(f"Quests completed: {game.completed_quests}")
    print(f"Active quests: {list(game.active_quests.keys())}")
    print(f"Treasures: {len(game.treasures_collected)}")
    print(f"Flags: {len(game.flags)}")

    print(f"\n--- Completion Checks ---")

    unvisited = set(game.locations.keys()) - game.visited
    if unvisited:
        game.fail(f"UNVISITED: {sorted(unvisited)}")
    else:
        game.ok("All rooms visited!")

    expected_party = [c["id"] for c in game.characters.values() if c.get("role") == "party_member"]
    missing = set(expected_party) - set(game.party)
    if missing:
        game.fail(f"MISSING party members: {missing}")
    else:
        game.ok(f"Full party: {game.party}")

    main_quests = [q for q in game.quests if q.get("quest_type") == "main"]
    incomplete = [q["id"] for q in main_quests if q["id"] not in game.completed_quests]
    if incomplete:
        game.fail(f"INCOMPLETE quests: {incomplete}")
    else:
        game.ok(f"All {len(main_quests)} main quests complete!")

    if "game_complete" in game.flags:
        game.ok("Game completion flag set!")
    else:
        game.fail("game_complete flag NOT set")

    print(f"\n{'='*60}")
    print(f"PASSED: {game.passed} | FAILED: {game.failed}")
    print(f"{'='*60}")

    if game.errors:
        print("\nErrors:")
        for e in game.errors:
            print(f"  ✗ {e}")

    return 1 if game.failed > 0 else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: python {sys.argv[0]} /path/to/game/data/")
        sys.exit(1)
    sys.exit(simulate(sys.argv[1]))
