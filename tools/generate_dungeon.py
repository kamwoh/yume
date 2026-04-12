#!/usr/bin/env python3
"""Procedural dungeon generator — creates N connected room JSONs.

Usage:
    python generate_dungeon.py /path/to/game/data/ --rooms 5 --seed 42

Generates:
    data/locations/gen_room_001.json ... gen_room_005.json
    data/dungeon.json (room layout + offsets)
    data/nav_grid.json (for A* pathfinding)
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path


# Room templates — story_role → generation rules
ROOM_TEMPLATES = {
    "guard_post": {
        "min_w": 12, "max_w": 18, "min_h": 10, "max_h": 16,
        "enemy_count": [1, 2], "prop_density": 0.08,
        "props": ["barrel", "column", "weapon-sword", "weapon-spear", "shield-round", "banner"],
        "enemy_model": "character-orc",
        "ai_default": "guard",
        "lighting_mood": "warm",
        "description": "A guard station with weapons and watchful sentries.",
    },
    "corridor": {
        "min_w": 5, "max_w": 8, "min_h": 14, "max_h": 22,
        "enemy_count": [0, 1], "prop_density": 0.03,
        "props": ["column", "rocks", "barrel"],
        "interactables": [{"type": "trap", "chance": 0.5}],
        "lighting_mood": "dark",
        "description": "A narrow stone passage connecting chambers.",
    },
    "treasure_vault": {
        "min_w": 10, "max_w": 14, "min_h": 8, "max_h": 12,
        "enemy_count": [1, 1], "prop_density": 0.05,
        "props": ["column", "stairs", "banner"],
        "interactables": [
            {"type": "chest", "count": [2, 4], "contents": ["gold_coin", "potion"]},
            {"type": "coin", "count": [2, 5]},
        ],
        "enemy_model": "character-orc",
        "ai_default": "guard",
        "lighting_mood": "golden",
        "description": "A vault glowing with treasure. Guarded.",
    },
    "boss_arena": {
        "min_w": 16, "max_w": 22, "min_h": 16, "max_h": 22,
        "enemy_count": [1, 1], "prop_density": 0.03,
        "props": ["column", "rocks", "banner", "gate"],
        "enemy_model": "character-orc",
        "enemy_stats": {"hp": 120, "damage": 15, "speed": 2.5},
        "ai_default": "guard",
        "lighting_mood": "dramatic",
        "description": "A grand arena. Something dangerous awaits.",
    },
    "living_quarters": {
        "min_w": 8, "max_w": 12, "min_h": 8, "max_h": 12,
        "enemy_count": [0, 1], "prop_density": 0.1,
        "props": ["barrel", "chest", "column"],
        "lighting_mood": "warm",
        "description": "Cramped quarters with personal belongings.",
    },
}

# Lighting moods
LIGHTING_MOODS = {
    "warm": {
        "bg_color": [0.02, 0.02, 0.03],
        "ambient_light": [0.2, 0.17, 0.14],
        "light_color": [1.0, 0.85, 0.5],
        "light_energy": 2.0,
        "light_range": 6.0,
    },
    "dark": {
        "bg_color": [0.01, 0.01, 0.02],
        "ambient_light": [0.12, 0.1, 0.08],
        "light_color": [0.8, 0.7, 0.5],
        "light_energy": 1.2,
        "light_range": 4.0,
    },
    "golden": {
        "bg_color": [0.02, 0.02, 0.03],
        "ambient_light": [0.18, 0.15, 0.1],
        "light_color": [1.0, 0.9, 0.4],
        "light_energy": 2.5,
        "light_range": 5.0,
    },
    "dramatic": {
        "bg_color": [0.01, 0.01, 0.01],
        "ambient_light": [0.1, 0.08, 0.06],
        "light_color": [1.0, 0.5, 0.3],
        "light_energy": 3.0,
        "light_range": 8.0,
    },
}

# Dungeon pacing sequence
DEFAULT_SEQUENCE = ["guard_post", "corridor", "treasure_vault", "corridor", "boss_arena"]


# generate_grid replaced by generate_grid_4dir (supports north/south/east/west doors)


def generate_props(width: int, height: int, template: dict, rng: random.Random) -> list[dict]:
    """Place props following design rules: walls=storage, corners=personal, center=focal."""
    props = []
    available = template.get("props", ["barrel", "column"])
    density = template.get("prop_density", 0.05)
    interior_area = (width - 2) * (height - 2)
    prop_count = max(2, int(interior_area * density) + rng.randint(0, 2))

    no_collision_types = ["banner", "coin", "weapon-sword", "weapon-spear", "shield-round", "shield-rectangle"]

    for _ in range(prop_count):
        prop_type = rng.choice(available)
        # Placement logic based on type
        if prop_type in ["barrel", "weapon-sword", "weapon-spear", "shield-round"]:
            # Along walls
            if rng.random() < 0.5:
                gx = rng.choice([1, width - 2])
                gz = rng.randint(2, height - 3)
            else:
                gx = rng.randint(2, width - 3)
                gz = rng.choice([1, height - 2])
        elif prop_type == "column":
            # Grid pattern — every 3-4 tiles
            gx = rng.choice([3, width // 2, width - 4])
            gz = rng.choice([3, height // 2, height - 4])
        elif prop_type == "banner":
            # On walls, high up
            gx = rng.randint(2, width - 3)
            gz = 1
        else:
            # Random interior
            gx = rng.randint(2, width - 3)
            gz = rng.randint(2, height - 3)

        gx = max(1, min(gx, width - 2))
        gz = max(1, min(gz, height - 2))

        prop = {"type": prop_type, "gx": gx, "gz": gz}
        if prop_type == "banner":
            prop["y_offset"] = 1.2
            prop["no_collision"] = True
        elif prop_type in no_collision_types:
            prop["no_collision"] = True
        props.append(prop)

    # Add interactables from template
    for inter_def in template.get("interactables", []):
        itype = inter_def["type"]
        if "chance" in inter_def and rng.random() > inter_def["chance"]:
            continue
        count = 1
        if "count" in inter_def:
            count = rng.randint(inter_def["count"][0], inter_def["count"][1])
        for _ in range(count):
            gx = rng.randint(2, width - 3)
            gz = rng.randint(2, height - 3)
            prop = {
                "type": itype, "gx": gx, "gz": gz,
                "interactable": True,
                "interaction_range": 1.0 if itype == "coin" else 1.5,
            }
            if itype == "coin":
                prop["auto_trigger"] = True
            elif itype == "trap":
                prop["auto_trigger"] = True
                prop["damage"] = rng.randint(10, 20)
            elif itype == "chest":
                contents = inter_def.get("contents", ["gold_coin"])
                prop["contents"] = [rng.choice(contents) for _ in range(rng.randint(1, 3))]
            props.append(prop)

    return props


def generate_enemies(width: int, height: int, template: dict, rng: random.Random) -> list[dict]:
    """Place enemies with AI config."""
    enemies = []
    ecount_range = template.get("enemy_count", [0, 1])
    count = rng.randint(ecount_range[0], ecount_range[1])

    for i in range(count):
        gx = rng.randint(2, max(3, width - 3))
        gz = rng.randint(2, max(3, height - 3))
        model = template.get("enemy_model", "character-orc")
        base_stats = template.get("enemy_stats", {"hp": 60, "damage": 8, "speed": 3.0})

        enemy = {
            "name": f"Guard_{i+1}",
            "model": model,
            "gx": gx, "gz": gz,
            "color": [0.4 + rng.random() * 0.2, 0.3 + rng.random() * 0.2, 0.3],
            "brain": "state_machine",
            "stats": {
                "hp": base_stats.get("hp", 60) + rng.randint(-10, 10),
                "damage": base_stats.get("damage", 8) + rng.randint(-2, 2),
                "speed": base_stats.get("speed", 3.0),
                "attack_range": 1.0,
                "detect_range": 6.0,
                "attack_cooldown": 1.0 + rng.random() * 0.5,
            },
            "ai_config": {
                "default_state": template.get("ai_default", "guard"),
                "guard_position": {"gx": gx, "gz": gz},
                "guard_facing": rng.choice(["north", "south", "east", "west"]),
                "detect_range": 6.0,
                "attack_range": 1.0,
                "flee_hp_percent": 0.15,
            },
        }
        enemies.append(enemy)

    return enemies


def generate_lights(width: int, height: int, template: dict, rng: random.Random) -> list[dict]:
    """Place point lights based on mood."""
    mood_name = template.get("lighting_mood", "warm")
    mood = LIGHTING_MOODS.get(mood_name, LIGHTING_MOODS["warm"])

    lights = []

    # Entrance light (south)
    lights.append({
        "gx": width // 2, "gz": height - 2, "y": 1.5,
        "color": mood["light_color"], "energy": mood["light_energy"] * 0.8,
        "range": mood["light_range"],
    })

    # Exit light (north)
    lights.append({
        "gx": width // 2, "gz": 1, "y": 1.5,
        "color": mood["light_color"], "energy": mood["light_energy"],
        "range": mood["light_range"],
    })

    # Mid-room fill lights
    num_fills = max(1, (width * height) // 60)
    for _ in range(num_fills):
        lights.append({
            "gx": rng.randint(2, width - 3),
            "gz": rng.randint(3, height - 4),
            "y": 1.5 + rng.random() * 0.5,
            "color": mood["light_color"],
            "energy": mood["light_energy"] * (0.6 + rng.random() * 0.4),
            "range": mood["light_range"] * (0.7 + rng.random() * 0.3),
        })

    return lights


def generate_room(room_id: str, story_role: str, has_north_door: bool, has_south_door: bool,
                   rng: random.Random) -> dict:
    """Generate a complete room JSON."""
    template = ROOM_TEMPLATES.get(story_role, ROOM_TEMPLATES["guard_post"])
    mood_name = template.get("lighting_mood", "warm")
    mood = LIGHTING_MOODS.get(mood_name, LIGHTING_MOODS["warm"])

    width = rng.randint(template["min_w"], template["max_w"])
    height = rng.randint(template["min_h"], template["max_h"])

    grid_map = generate_grid(width, height, has_north_door, has_south_door)
    props = generate_props(width, height, template, rng)
    enemies = generate_enemies(width, height, template, rng)
    lights = generate_lights(width, height, template, rng)

    # Spawn inside south door
    spawn_gz = height - 3 if has_south_door else height // 2
    spawn_gx = width // 2

    room = {
        "id": room_id,
        "name": template.get("description", story_role).split(".")[0],
        "type": "dungeon",
        "description": template.get("description", ""),
        "story_role": story_role,
        "grid": {
            "tile_size": 1.0,
            "tiles": {"floor": "floor", "wall": "wall", "door": "wall-opening"},
            "map": grid_map,
        },
        "spawn_on_grid": {"gx": spawn_gx, "gz": spawn_gz},
        "props_on_grid": props,
        "npcs_on_grid": enemies,
        "point_lights": lights,
        "atmosphere": {
            "bg_color": mood["bg_color"],
            "ambient_light": mood["ambient_light"],
            "sun_energy": 0.0,
            "lighting": {"type": "dark"},
        },
        "layout": {
            "width": width * 50, "height": height * 50,
            "ground_color": [0.2, 0.18, 0.15],
            "entrance": {"x": spawn_gx * 50, "y": spawn_gz * 50},
        },
        "exits": [], "props": [], "story_npcs": [], "ambient_npcs": [],
        "treasures": [], "encounters": [], "shop": [], "connections": [],
    }

    return room


def generate_grid_4dir(width: int, height: int, doors: dict) -> list[str]:
    """Generate room grid with doors on any side: north/south/east/west."""
    rows = []
    for z in range(height):
        row = list("W" if (z == 0 or z == height - 1 or True) else "F" for _ in range(width))
        # Fill interior
        for x in range(width):
            if z == 0 or z == height - 1:
                row[x] = "W"
            elif x == 0 or x == width - 1:
                row[x] = "W"
            else:
                row[x] = "F"

        # North door (z=0)
        if z == 0 and doors.get("north"):
            mid = width // 2
            for dx in range(-1, 2):
                if 0 <= mid + dx < width:
                    row[mid + dx] = "D"

        # South door (z=height-1)
        if z == height - 1 and doors.get("south"):
            mid = width // 2
            for dx in range(-1, 2):
                if 0 <= mid + dx < width:
                    row[mid + dx] = "D"

        # East door (x=width-1)
        if doors.get("east") and z == height // 2:
            row[width - 1] = "D"
            if height // 2 - 1 >= 0:
                rows_to_fix = [height // 2 - 1, height // 2, height // 2 + 1]
            else:
                rows_to_fix = [height // 2]
            # We'll fix east doors after all rows are built

        # West door (x=0)
        if doors.get("west") and z == height // 2:
            row[0] = "D"

        rows.append("".join(row))

    # Fix east/west doors — need 3 tiles tall for passage
    if doors.get("east"):
        mid_z = height // 2
        for dz in range(-1, 2):
            z = mid_z + dz
            if 0 < z < height - 1:
                r = list(rows[z])
                r[width - 1] = "D"
                rows[z] = "".join(r)

    if doors.get("west"):
        mid_z = height // 2
        for dz in range(-1, 2):
            z = mid_z + dz
            if 0 < z < height - 1:
                r = list(rows[z])
                r[0] = "D"
                rows[z] = "".join(r)

    return rows


def generate_room(room_id: str, story_role: str, doors: dict, rng: random.Random) -> dict:
    """Generate a complete room JSON. doors = {"north": bool, "south": bool, "east": bool, "west": bool}"""
    template = ROOM_TEMPLATES.get(story_role, ROOM_TEMPLATES["guard_post"])
    mood_name = template.get("lighting_mood", "warm")
    mood = LIGHTING_MOODS.get(mood_name, LIGHTING_MOODS["warm"])

    width = rng.randint(template["min_w"], template["max_w"])
    height = rng.randint(template["min_h"], template["max_h"])

    grid_map = generate_grid_4dir(width, height, doors)
    props = generate_props(width, height, template, rng)
    enemies = generate_enemies(width, height, template, rng)
    lights = generate_lights(width, height, template, rng)

    # Spawn near whichever door is the "entrance"
    if doors.get("south"):
        spawn_gx, spawn_gz = width // 2, height - 3
    elif doors.get("west"):
        spawn_gx, spawn_gz = 2, height // 2
    elif doors.get("east"):
        spawn_gx, spawn_gz = width - 3, height // 2
    else:
        spawn_gx, spawn_gz = width // 2, height // 2

    room = {
        "id": room_id,
        "name": template.get("description", story_role).split(".")[0],
        "type": "dungeon",
        "description": template.get("description", ""),
        "story_role": story_role,
        "grid": {
            "tile_size": 1.0,
            "tiles": {"floor": "floor", "wall": "wall", "door": "wall-opening"},
            "map": grid_map,
        },
        "spawn_on_grid": {"gx": spawn_gx, "gz": spawn_gz},
        "props_on_grid": props,
        "npcs_on_grid": enemies,
        "point_lights": lights,
        "atmosphere": {
            "bg_color": mood["bg_color"],
            "ambient_light": mood["ambient_light"],
            "sun_energy": 0.0,
            "lighting": {"type": "dark"},
        },
        "layout": {
            "width": width * 50, "height": height * 50,
            "ground_color": [0.2, 0.18, 0.15],
            "entrance": {"x": spawn_gx * 50, "y": spawn_gz * 50},
        },
        "exits": [], "props": [], "story_npcs": [], "ambient_npcs": [],
        "treasures": [], "encounters": [], "shop": [], "connections": [],
    }

    return room


def generate_dungeon(num_rooms: int, seed: int, sequence: list[str] | None = None) -> tuple[list[dict], dict]:
    """Generate a dungeon with 2D layout — rooms connect in varied directions."""
    rng = random.Random(seed)

    if sequence is None:
        sequence = DEFAULT_SEQUENCE
    while len(sequence) < num_rooms:
        sequence.append(rng.choice(list(ROOM_TEMPLATES.keys())))
    sequence = sequence[:num_rooms]

    # Plan 2D layout — place rooms on a grid
    # Each cell = (grid_x, grid_z) in room-space
    placed = {}  # (gx, gz) → room_index
    room_positions = []  # [(gx, gz, connect_dir)] per room
    directions = {
        "north": (0, -1, "south"),   # my north connects to their south
        "south": (0, 1, "north"),
        "east": (1, 0, "west"),
        "west": (-1, 0, "east"),
    }

    # Place first room at origin
    cx, cz = 0, 0
    placed[(cx, cz)] = 0
    room_positions.append((cx, cz, None))

    for i in range(1, num_rooms):
        # Pick a random direction from current position
        dir_options = list(directions.keys())
        rng.shuffle(dir_options)

        placed_ok = False
        for dir_name in dir_options:
            dx, dz, _ = directions[dir_name]
            nx, nz = cx + dx, cz + dz
            if (nx, nz) not in placed:
                placed[(nx, nz)] = i
                room_positions.append((nx, nz, dir_name))
                cx, cz = nx, nz
                placed_ok = True
                break

        if not placed_ok:
            # All neighbors occupied — try from any placed room
            for pos, idx in list(placed.items()):
                for dir_name in dir_options:
                    dx, dz, _ = directions[dir_name]
                    nx, nz = pos[0] + dx, pos[1] + dz
                    if (nx, nz) not in placed:
                        placed[(nx, nz)] = i
                        room_positions.append((nx, nz, dir_name))
                        cx, cz = nx, nz
                        placed_ok = True
                        break
                if placed_ok:
                    break

    # Generate rooms with correct doors
    rooms = []
    for i, story_role in enumerate(sequence):
        room_id = f"gen_room_{i+1:03d}"
        gx, gz, _ = room_positions[i]

        # Check which neighbors exist
        doors = {
            "north": (gx, gz - 1) in placed,
            "south": (gx, gz + 1) in placed,
            "east": (gx + 1, gz) in placed,
            "west": (gx - 1, gz) in placed,
        }

        room = generate_room(room_id, story_role, doors, rng)
        rooms.append(room)

    # Calculate world-space offsets
    # Each room is placed at its grid position × room size
    # Use max room size for spacing to prevent overlap
    max_w = max(len(r["grid"]["map"][0]) for r in rooms) + 2
    max_h = max(len(r["grid"]["map"]) for r in rooms) + 2

    dungeon_rooms = []
    for i, room in enumerate(rooms):
        gx, gz, _ = room_positions[i]
        offset_x = gx * max_w
        offset_z = gz * max_h
        dungeon_rooms.append({
            "location": room["id"],
            "offset": {"x": float(offset_x), "z": float(offset_z)},
        })

    dungeon = {
        "starting_room": rooms[0]["id"],
        "spawn_on_grid": rooms[0]["spawn_on_grid"],
        "rooms": dungeon_rooms,
    }

    return rooms, dungeon


def main():
    parser = argparse.ArgumentParser(description="Generate a procedural dungeon")
    parser.add_argument("data_dir", type=Path, help="Game data directory")
    parser.add_argument("--rooms", type=int, default=5, help="Number of rooms (default 5)")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    parser.add_argument("--sequence", type=str, default=None,
                        help="Comma-separated room types (e.g., guard_post,corridor,treasure_vault)")
    args = parser.parse_args()

    data_dir = args.data_dir.resolve()
    locations_dir = data_dir / "locations"
    locations_dir.mkdir(parents=True, exist_ok=True)

    sequence = args.sequence.split(",") if args.sequence else None
    rooms, dungeon = generate_dungeon(args.rooms, args.seed, sequence)

    # Write room JSONs
    for room in rooms:
        path = locations_dir / f"{room['id']}.json"
        path.write_text(json.dumps(room, indent=2))
        grid = room["grid"]["map"]
        print(f"  {room['id']}: {len(grid[0])}x{len(grid)} {room['story_role']} — {len(room['npcs_on_grid'])} enemies, {len(room['props_on_grid'])} props")

    # Write dungeon.json
    dungeon_path = data_dir / "dungeon.json"
    dungeon_path.write_text(json.dumps(dungeon, indent=2))

    print(f"\nGenerated {len(rooms)} rooms → {locations_dir}/")
    print(f"Dungeon layout → {dungeon_path}")

    # Also generate nav_grid
    import subprocess
    map_tool = Path(__file__).parent / "dungeon_map.py"
    if map_tool.exists():
        subprocess.run(["python3", str(map_tool), str(data_dir)], capture_output=True)
        print(f"Nav grid → {data_dir / 'nav_grid.json'}")


if __name__ == "__main__":
    main()
