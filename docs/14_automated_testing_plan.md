# Automated Testing Plan — Testing Without a Human

## The Problem
We can't manually playtest 52 rooms every time we make changes. We need automated ways to verify the game works.

## Three Layers of Testing

### Layer 1: Data Validation (Python — no Godot needed)
**What:** Verify all JSON data files are correct, cross-referenced, and complete.
**Run:** `python tools/validate_game_data.py /path/to/ff9/data/`

Checks:
- [ ] All JSON files parse without errors
- [ ] All location exit targets reference existing location IDs
- [ ] All treasure item_ids exist in items.json
- [ ] All encounter enemy IDs exist in enemies.json
- [ ] All quest triggers reference valid location IDs
- [ ] All dialogue location_ids reference valid locations
- [ ] Every dungeon has at least 1 boss encounter or is a sub-room of a boss area
- [ ] Every town has a shop
- [ ] Every room has >= 3 treasures (walkthrough density)
- [ ] Every ambient NPC has dialogue_states with at least early/mid/late
- [ ] Story gating: exits with requires_flag reference flags that are set somewhere
- [ ] No orphan locations (every room reachable from starting location via exits)
- [ ] Level curve: bosses get harder over the progression path
- [ ] Steal lists: every boss has at least 2 stealable items
- [ ] The full path from starting_location to final boss is traversable (graph walk)

**This is the highest ROI test. Catches 80% of bugs without running Godot.**

### Layer 2: Godot Headless Smoke Test (Godot CLI)
**What:** Run Godot in headless mode, load each location, verify no parse errors.
**Run:** `godot --headless --path /path/to/ff9/ --script res://tests/smoke_test.gd`

Godot supports `--headless` mode on Linux. We can write a GDScript that:
1. Iterates through every location JSON
2. Calls `LocationManager.load_location(id)` for each
3. Checks that no errors occurred (no null references, no missing nodes)
4. Prints PASS/FAIL per location
5. Exits with code 0 (all pass) or 1 (any fail)

```gdscript
# tests/smoke_test.gd
extends SceneTree

func _init():
    # Load each location and verify no crash
    var dir := DirAccess.open("res://data/locations/")
    if dir:
        dir.list_dir_begin()
        var file := dir.get_next()
        while file != "":
            if file.ends_with(".json"):
                var loc_id := file.replace(".json", "")
                print("Testing: ", loc_id)
                # Try loading the location data
                var f := FileAccess.open("res://data/locations/" + file, FileAccess.READ)
                var data = JSON.parse_string(f.get_as_text())
                if data == null:
                    printerr("FAIL: ", file, " — invalid JSON")
                else:
                    print("PASS: ", loc_id)
            file = dir.get_next()
    quit()
```

**Limitation:** WSL2 can't easily run Godot headless for the Windows project. Options:
- Copy project to Linux, run Godot Linux headless
- Use `godot.exe --headless` from Windows side via PowerShell

### Layer 3: Automated Playthrough Bot (Future)
**What:** A GDScript that walks through the game automatically, making choices and fighting battles.
**How:** Add an `autoplay` mode to GameManager that:
1. Reads a playthrough script (JSON list of actions)
2. Walks to exits automatically
3. Opens chests
4. Talks to NPCs
5. Fights battles (auto-attack)
6. Logs everything encountered
7. Verifies quest progression fires correctly

```json
// playthrough_script.json
[
    {"action": "verify_location", "expected": "alexandria_castle_gate"},
    {"action": "walk_to_exit", "target": "alexandria_castle_courtyard"},
    {"action": "verify_event", "expected": "garnet_joined"},
    {"action": "walk_to_exit", "target": "alexandria_castle_interior"},
    {"action": "walk_to_exit", "target": "evil_forest_edge"},
    {"action": "verify_party", "expected": ["zidane", "garnet", "steiner", "vivi"]},
    {"action": "walk_to_exit", "target": "evil_forest_path"},
    {"action": "walk_to_exit", "target": "evil_forest_deep"},
    {"action": "fight_boss", "expected": "plant_brain"},
    {"action": "verify_flag", "expected": "plant_brain_defeated"},
    {"action": "walk_to_exit", "target": "ice_cavern_entrance"},
    ...
]
```

This is the most powerful but most complex. Save for later.

## Recommendation: Start with Layer 1

Layer 1 (data validation) gives us 80% of the value with 20% of the effort. It runs instantly, doesn't need Godot, and catches the most common bugs:
- Broken exit references (player gets stuck)
- Missing items in treasure references
- Missing enemies in encounter references
- Rooms with zero content
- Unreachable rooms
- Story gating flags that are never set

Let me build this first.
