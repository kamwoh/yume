#!/usr/bin/env python3
"""Procedural dungeon generator — creates N connected room JSONs.

Supports: irregular room shapes, multi-floor, biome variety.

Usage:
    python generate_dungeon.py /path/to/game/data/ --rooms 5 --seed 42
    python generate_dungeon.py /path/to/game/data/ --rooms 7 --seed 99 --biome forest
    python generate_dungeon.py /path/to/game/data/ --rooms 10 --seed 123 --floors 2
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path


# ============================================================
# ROOM SHAPES — "shape" abstraction layer
# ============================================================

def shape_rectangle(width: int, height: int, rng: random.Random) -> list[list[str]]:
    """Standard rectangle room."""
    grid = []
    for z in range(height):
        row = []
        for x in range(width):
            if z == 0 or z == height - 1 or x == 0 or x == width - 1:
                row.append("W")
            else:
                row.append("F")
        grid.append(row)
    return grid


def shape_L(width: int, height: int, rng: random.Random) -> list[list[str]]:
    """L-shaped room — main rectangle with extension on one side."""
    grid = shape_rectangle(width, height, rng)
    # Cut out a corner to make L-shape
    cut_w = rng.randint(width // 3, width // 2)
    cut_h = rng.randint(height // 3, height // 2)
    # Pick which corner to cut
    corner = rng.choice(["ne", "nw", "se", "sw"])
    for z in range(height):
        for x in range(width):
            if corner == "ne" and x >= width - cut_w and z < cut_h:
                grid[z][x] = "."
            elif corner == "nw" and x < cut_w and z < cut_h:
                grid[z][x] = "."
            elif corner == "se" and x >= width - cut_w and z >= height - cut_h:
                grid[z][x] = "."
            elif corner == "sw" and x < cut_w and z >= height - cut_h:
                grid[z][x] = "."
    # Rebuild walls around new shape
    _rebuild_walls(grid, width, height)
    return grid


def shape_T(width: int, height: int, rng: random.Random) -> list[list[str]]:
    """T-shaped room — wide top with narrow stem."""
    grid = []
    stem_w = max(5, width // 2)
    stem_start = (width - stem_w) // 2
    top_h = rng.randint(height // 3, height // 2)

    for z in range(height):
        row = []
        for x in range(width):
            if z < top_h:
                # Top bar — full width
                if z == 0 or x == 0 or x == width - 1:
                    row.append("W")
                else:
                    row.append("F")
            else:
                # Stem — narrow
                if x < stem_start or x >= stem_start + stem_w:
                    row.append(".")
                elif x == stem_start or x == stem_start + stem_w - 1:
                    row.append("W")
                elif z == height - 1:
                    row.append("W")
                else:
                    row.append("F")
        grid.append(row)
    # Fix the junction between top and stem
    _rebuild_walls(grid, width, height)
    return grid


def shape_cave(width: int, height: int, rng: random.Random) -> list[list[str]]:
    """Cellular automata cave — organic shape."""
    # Initialize with ~45% walls
    grid = []
    for z in range(height):
        row = []
        for x in range(width):
            if z == 0 or z == height - 1 or x == 0 or x == width - 1:
                row.append("W")  # Border always wall
            elif rng.random() < 0.45:
                row.append("W")
            else:
                row.append("F")
        grid.append(row)

    # Iterate cellular automata 4 times
    for _ in range(4):
        new_grid = [row[:] for row in grid]
        for z in range(1, height - 1):
            for x in range(1, width - 1):
                # Count wall neighbors (Moore neighborhood)
                walls = 0
                for dz in range(-1, 2):
                    for dx in range(-1, 2):
                        if dz == 0 and dx == 0:
                            continue
                        nz, nx = z + dz, x + dx
                        if 0 <= nz < height and 0 <= nx < width:
                            if grid[nz][nx] == "W":
                                walls += 1
                        else:
                            walls += 1  # Out of bounds = wall
                # Rule: become wall if 5+ neighbors are walls
                new_grid[z][x] = "W" if walls >= 5 else "F"
        grid = new_grid

    # Ensure border is wall
    for z in range(height):
        grid[z][0] = "W"
        grid[z][width - 1] = "W"
    for x in range(width):
        grid[0][x] = "W"
        grid[height - 1][x] = "W"

    # Flood fill from center to ensure connectivity
    _ensure_connected(grid, width, height)
    return grid


def shape_circular(width: int, height: int, rng: random.Random) -> list[list[str]]:
    """Circular/oval room."""
    grid = []
    cx, cz = width / 2.0, height / 2.0
    rx, rz = width / 2.0 - 1.0, height / 2.0 - 1.0

    for z in range(height):
        row = []
        for x in range(width):
            # Check if inside ellipse
            dx = (x + 0.5 - cx) / rx
            dz = (z + 0.5 - cz) / rz
            if dx * dx + dz * dz <= 1.0:
                row.append("F")
            else:
                row.append(".")
        grid.append(row)

    # Add walls around floor tiles
    _rebuild_walls(grid, width, height)
    return grid


def shape_alcove(width: int, height: int, rng: random.Random) -> list[list[str]]:
    """Rectangle with an alcove/nook extending from one side."""
    grid = shape_rectangle(width, height, rng)
    # Add alcove on one side
    alcove_w = rng.randint(3, max(4, width // 3))
    alcove_h = rng.randint(3, max(4, height // 3))
    side = rng.choice(["north", "south", "east", "west"])

    if side == "east":
        ax = width - 1
        az = (height - alcove_h) // 2
        for z in range(az, az + alcove_h):
            for x in range(ax, min(ax + alcove_w, width + alcove_w)):
                if z < 0 or z >= height:
                    continue
                # Extend grid if needed — we work within existing bounds
                if x < width:
                    grid[z][x] = "F"
            # Extend rows
            while len(grid[z]) < width + alcove_w - 1:
                grid[z].append("F")
        # Pad all other rows
        extended_w = max(len(r) for r in grid)
        for z in range(height):
            while len(grid[z]) < extended_w:
                grid[z].append(".")
        _rebuild_walls(grid, extended_w, height)
        return grid

    elif side == "south":
        for z in range(height, height + alcove_h - 1):
            row = ["." for _ in range(width)]
            sx = (width - alcove_w) // 2
            for x in range(sx, sx + alcove_w):
                if 0 <= x < width:
                    row[x] = "F"
            grid.append(row)
        _rebuild_walls(grid, width, len(grid))
        return grid

    # Default: just return rectangle with slight asymmetry
    _rebuild_walls(grid, width, height)
    return grid


def _rebuild_walls(grid: list[list[str]], width: int, height: int) -> None:
    """Rebuild wall tiles around floor tiles. Floor adjacent to void/edge gets wall."""
    h = len(grid)
    w = max(len(r) for r in grid) if grid else 0
    for z in range(h):
        for x in range(len(grid[z])):
            if grid[z][x] == "F":
                # Check if any neighbor is void or out of bounds
                for dz in range(-1, 2):
                    for dx in range(-1, 2):
                        if dz == 0 and dx == 0:
                            continue
                        nz, nx = z + dz, x + dx
                        if nz < 0 or nz >= h or nx < 0 or nx >= len(grid[nz]):
                            continue
                        if grid[nz][nx] == ".":
                            grid[nz][nx] = "W"


def _ensure_connected(grid: list[list[str]], width: int, height: int) -> None:
    """Flood fill from center — remove disconnected floor patches."""
    cx, cz = width // 2, height // 2
    # Find nearest floor to center
    start = None
    for r in range(max(width, height)):
        for dz in range(-r, r + 1):
            for dx in range(-r, r + 1):
                nz, nx = cz + dz, cx + dx
                if 0 <= nz < height and 0 <= nx < width and grid[nz][nx] == "F":
                    start = (nx, nz)
                    break
            if start:
                break
        if start:
            break

    if not start:
        return

    # BFS from start
    visited = set()
    queue = [start]
    while queue:
        x, z = queue.pop(0)
        if (x, z) in visited:
            continue
        if x < 0 or x >= width or z < 0 or z >= height:
            continue
        if grid[z][x] != "F":
            continue
        visited.add((x, z))
        queue.extend([(x + 1, z), (x - 1, z), (x, z + 1), (x, z - 1)])

    # Remove disconnected floors
    for z in range(height):
        for x in range(width):
            if grid[z][x] == "F" and (x, z) not in visited:
                grid[z][x] = "W"


# Shape registry — "shape" abstraction
SHAPE_GENERATORS = {
    "rectangle": shape_rectangle,
    "L": shape_L,
    "T": shape_T,
    "cave": shape_cave,
    "circular": shape_circular,
    "alcove": shape_alcove,
}


def _add_doors(grid: list[list[str]], doors: dict) -> None:
    """Add 3-wide doors on specified sides of a grid."""
    h = len(grid)
    w = max(len(r) for r in grid) if grid else 0

    if doors.get("north"):
        mid = w // 2
        for dx in range(-1, 2):
            x = mid + dx
            if 0 <= x < len(grid[0]):
                grid[0][x] = "D"

    if doors.get("south"):
        mid = w // 2
        for dx in range(-1, 2):
            x = mid + dx
            if 0 <= x < len(grid[h - 1]):
                grid[h - 1][x] = "D"

    if doors.get("east"):
        mid_z = h // 2
        for dz in range(-1, 2):
            z = mid_z + dz
            if 0 < z < h - 1 and len(grid[z]) > 0:
                # Extend row if needed
                while len(grid[z]) < w:
                    grid[z].append(".")
                grid[z][w - 1] = "D"

    if doors.get("west"):
        mid_z = h // 2
        for dz in range(-1, 2):
            z = mid_z + dz
            if 0 < z < h - 1:
                grid[z][0] = "D"


# ============================================================
# BIOMES — model sets + lighting moods
# ============================================================

BIOMES = {
    "dungeon": {
        "props": ["barrel", "column", "barrel", "column", "rocks", "banner"],
        "enemies": ["character-orc"],
        "lighting_moods": ["warm", "dark", "dramatic"],
        "shapes": ["rectangle"],
    },
    "town": {
        "props": ["barrel", "cart", "fountain-center", "fence", "banner-red", "banner-green", "chest"],
        "enemies": ["character-orc"],
        "lighting_moods": ["bright", "warm"],
        "shapes": ["rectangle", "L", "T"],
        "outdoor": True,
    },
    "forest": {
        "props": ["rocks", "barrel", "column"],
        "enemies": ["character-orc"],
        "lighting_moods": ["natural", "dim"],
        "shapes": ["cave", "circular", "alcove"],
        "outdoor": True,
    },
    "cave": {
        "props": ["rocks", "rocks", "barrel", "column", "chest"],
        "enemies": ["character-orc"],
        "lighting_moods": ["dark", "dramatic"],
        "shapes": ["cave", "cave", "circular"],
    },
    "castle": {
        "props": ["column", "banner", "gate", "shield-round", "shield-rectangle", "weapon-sword", "weapon-spear"],
        "enemies": ["character-orc"],
        "lighting_moods": ["dramatic", "warm"],
        "shapes": ["rectangle", "T", "L"],
    },
    "interior": {
        "props": ["barrel", "chest", "column"],
        "enemies": [],
        "lighting_moods": ["warm", "bright"],
        "shapes": ["rectangle", "alcove"],
    },
}


# Room templates — story_role → generation rules
ROOM_TEMPLATES = {
    "guard_post": {
        "min_w": 12, "max_w": 18, "min_h": 10, "max_h": 16,
        "enemy_count": [0, 0], "prop_density": 0.08,
        "ai_default": "guard",
        "description": "A guard station with weapons and watchful sentries.",
    },
    "corridor": {
        "min_w": 5, "max_w": 8, "min_h": 14, "max_h": 22,
        "enemy_count": [0, 0], "prop_density": 0.03,
        "interactables": [{"type": "trap", "chance": 0.5}],
        "description": "A narrow stone passage connecting chambers.",
        "force_shape": "rectangle",
    },
    "treasure_vault": {
        "min_w": 10, "max_w": 14, "min_h": 8, "max_h": 12,
        "enemy_count": [0, 0], "prop_density": 0.05,
        "interactables": [
            {"type": "chest", "count": [2, 4], "contents": ["gold_coin", "potion"]},
            {"type": "coin", "count": [2, 5]},
        ],
        "ai_default": "guard",
        "description": "A vault glowing with treasure. Guarded.",
    },
    "boss_arena": {
        "min_w": 16, "max_w": 22, "min_h": 16, "max_h": 22,
        "enemy_count": [0, 0], "prop_density": 0.03,
        "enemy_stats": {"hp": 120, "damage": 15, "speed": 2.5},
        "ai_default": "guard",
        "description": "A grand arena. Something dangerous awaits.",
    },
    "living_quarters": {
        "min_w": 8, "max_w": 12, "min_h": 8, "max_h": 12,
        "enemy_count": [0, 0], "prop_density": 0.1,
        "description": "Cramped quarters with personal belongings.",
    },
}

LIGHTING_MOODS = {
    "warm": {
        "bg_color": [0.02, 0.02, 0.03],
        "ambient_light": [0.2, 0.17, 0.14],
        "sun_energy": 0.0,
        "light_color": [1.0, 0.85, 0.5],
        "light_energy": 2.0,
        "light_range": 6.0,
    },
    "dark": {
        "bg_color": [0.01, 0.01, 0.02],
        "ambient_light": [0.12, 0.1, 0.08],
        "sun_energy": 0.0,
        "light_color": [0.8, 0.7, 0.5],
        "light_energy": 1.2,
        "light_range": 4.0,
    },
    "golden": {
        "bg_color": [0.02, 0.02, 0.03],
        "ambient_light": [0.18, 0.15, 0.1],
        "sun_energy": 0.0,
        "light_color": [1.0, 0.9, 0.4],
        "light_energy": 2.5,
        "light_range": 5.0,
    },
    "dramatic": {
        "bg_color": [0.01, 0.01, 0.01],
        "ambient_light": [0.1, 0.08, 0.06],
        "sun_energy": 0.0,
        "light_color": [1.0, 0.5, 0.3],
        "light_energy": 3.0,
        "light_range": 8.0,
    },
    "bright": {
        "bg_color": [0.3, 0.4, 0.6],
        "ambient_light": [0.5, 0.5, 0.5],
        "sun_energy": 0.8,
        "light_color": [1.0, 0.95, 0.8],
        "light_energy": 1.0,
        "light_range": 10.0,
    },
    "natural": {
        "bg_color": [0.15, 0.25, 0.15],
        "ambient_light": [0.35, 0.4, 0.3],
        "sun_energy": 0.6,
        "light_color": [0.9, 1.0, 0.8],
        "light_energy": 1.5,
        "light_range": 8.0,
    },
    "dim": {
        "bg_color": [0.05, 0.05, 0.08],
        "ambient_light": [0.15, 0.15, 0.12],
        "sun_energy": 0.0,
        "light_color": [0.7, 0.8, 1.0],
        "light_energy": 1.0,
        "light_range": 4.0,
    },
}

DEFAULT_SEQUENCE = ["guard_post", "corridor", "living_quarters", "corridor", "treasure_vault"]


# ============================================================
# PROP / ENEMY / LIGHT GENERATORS
# ============================================================

def generate_props(grid: list[list[str]], template: dict, biome: dict, rng: random.Random) -> list[dict]:
    """Place props on floor tiles following design rules."""
    h = len(grid)
    w = max(len(r) for r in grid) if grid else 0
    props = []
    available = biome.get("props", ["barrel", "column"])
    density = template.get("prop_density", 0.05)
    floor_count = sum(1 for z in range(h) for x in range(len(grid[z])) if grid[z][x] == "F")
    prop_count = max(2, int(floor_count * density) + rng.randint(0, 2))

    no_collision_types = ["banner", "banner-red", "banner-green", "coin",
                          "weapon-sword", "weapon-spear", "shield-round", "shield-rectangle"]

    # Collect floor positions
    floor_tiles = [(x, z) for z in range(h) for x in range(len(grid[z])) if grid[z][x] == "F"]
    if not floor_tiles:
        return props

    for _ in range(prop_count):
        prop_type = rng.choice(available)
        gx, gz = rng.choice(floor_tiles)

        prop = {"type": prop_type, "gx": gx, "gz": gz}
        if prop_type in ["banner", "banner-red", "banner-green"]:
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
        count = rng.randint(inter_def["count"][0], inter_def["count"][1]) if "count" in inter_def else 1
        for _ in range(count):
            gx, gz = rng.choice(floor_tiles)
            prop = {"type": itype, "gx": gx, "gz": gz, "interactable": True,
                    "interaction_range": 1.0 if itype == "coin" else 1.5}
            if itype == "coin":
                prop["auto_trigger"] = True
            elif itype == "trap":
                prop["auto_trigger"] = True
                prop["damage"] = rng.randint(10, 20)
            elif itype == "chest":
                prop["contents"] = [rng.choice(inter_def.get("contents", ["gold_coin"])) for _ in range(rng.randint(1, 3))]
            props.append(prop)

    return props


def generate_enemies(grid: list[list[str]], template: dict, biome: dict, rng: random.Random) -> list[dict]:
    """Place enemies on floor tiles."""
    h = len(grid)
    enemies = []
    ecount_range = template.get("enemy_count", [0, 1])
    count = rng.randint(ecount_range[0], ecount_range[1])
    enemy_models = biome.get("enemies", ["character-orc"])
    if not enemy_models:
        return enemies

    floor_tiles = [(x, z) for z in range(h) for x in range(len(grid[z]))
                   if grid[z][x] == "F" and z > 2 and z < h - 2]
    if not floor_tiles:
        return enemies

    for i in range(count):
        gx, gz = rng.choice(floor_tiles)
        model = rng.choice(enemy_models)
        base_stats = template.get("enemy_stats", {"hp": 60, "damage": 8, "speed": 3.0})

        enemy = {
            "name": f"Guard_{i+1}", "model": model, "gx": gx, "gz": gz,
            "color": [0.4 + rng.random() * 0.2, 0.3 + rng.random() * 0.2, 0.3],
            "brain": "state_machine",
            "stats": {
                "hp": base_stats.get("hp", 60) + rng.randint(-10, 10),
                "damage": base_stats.get("damage", 8) + rng.randint(-2, 2),
                "speed": base_stats.get("speed", 3.0),
                "attack_range": 1.0, "detect_range": 6.0,
                "attack_cooldown": 1.0 + rng.random() * 0.5,
            },
            "ai_config": {
                "default_state": template.get("ai_default", "guard"),
                "guard_position": {"gx": gx, "gz": gz},
                "guard_facing": rng.choice(["north", "south", "east", "west"]),
                "detect_range": 6.0, "attack_range": 1.0, "flee_hp_percent": 0.15,
            },
        }
        enemies.append(enemy)

    return enemies


def generate_lights(grid: list[list[str]], mood_name: str, rng: random.Random) -> list[dict]:
    """Place point lights on floor tiles."""
    h = len(grid)
    mood = LIGHTING_MOODS.get(mood_name, LIGHTING_MOODS["warm"])
    lights = []

    floor_tiles = [(x, z) for z in range(h) for x in range(len(grid[z])) if grid[z][x] in ("F", "D")]
    if not floor_tiles:
        return lights

    # 1 light per ~30 floor tiles, min 2
    num_lights = max(2, len(floor_tiles) // 30 + rng.randint(0, 2))

    # Spread lights evenly
    step = max(1, len(floor_tiles) // num_lights)
    for i in range(0, len(floor_tiles), step):
        gx, gz = floor_tiles[min(i, len(floor_tiles) - 1)]
        lights.append({
            "gx": gx, "gz": gz,
            "y": 1.5 + rng.random() * 0.5,
            "color": mood["light_color"],
            "energy": mood["light_energy"] * (0.6 + rng.random() * 0.4),
            "range": mood["light_range"] * (0.7 + rng.random() * 0.3),
        })

    return lights


# ============================================================
# ROOM GENERATION
# ============================================================

def generate_room(room_id: str, story_role: str, doors: dict, biome_name: str,
                  rng: random.Random, floor_num: int = 0) -> dict:
    """Generate a complete room JSON with shape variety and biome support."""
    template = ROOM_TEMPLATES.get(story_role, ROOM_TEMPLATES["guard_post"])
    biome = BIOMES.get(biome_name, BIOMES["dungeon"])

    width = rng.randint(template["min_w"], template["max_w"])
    height = rng.randint(template["min_h"], template["max_h"])

    # Pick shape — from template override, biome preference, or random
    if "force_shape" in template:
        shape_name = template["force_shape"]
    else:
        shape_name = rng.choice(biome.get("shapes", ["rectangle"]))

    shape_fn = SHAPE_GENERATORS.get(shape_name, shape_rectangle)
    grid = shape_fn(width, height, rng)

    # Normalize grid dimensions (some shapes extend)
    actual_h = len(grid)
    actual_w = max(len(r) for r in grid) if grid else width
    # Pad rows to same width
    for z in range(actual_h):
        while len(grid[z]) < actual_w:
            grid[z].append(".")

    # Add doors
    _add_doors(grid, doors)

    # Pick lighting mood from biome
    mood_name = rng.choice(biome.get("lighting_moods", ["warm"]))
    mood = LIGHTING_MOODS.get(mood_name, LIGHTING_MOODS["warm"])

    props = generate_props(grid, template, biome, rng)
    enemies = generate_enemies(grid, template, biome, rng)
    lights = generate_lights(grid, mood_name, rng)

    # Spawn point — find a floor tile near a door or center
    floor_tiles = [(x, z) for z in range(actual_h) for x in range(len(grid[z])) if grid[z][x] == "F"]
    if floor_tiles:
        # Prefer center-ish
        center = (actual_w // 2, actual_h // 2)
        floor_tiles.sort(key=lambda t: abs(t[0] - center[0]) + abs(t[1] - center[1]))
        spawn_gx, spawn_gz = floor_tiles[0]
    else:
        spawn_gx, spawn_gz = actual_w // 2, actual_h // 2

    # Convert grid to strings
    grid_map = ["".join(row) for row in grid]

    room = {
        "id": room_id,
        "name": f"{story_role.replace('_', ' ').title()} ({shape_name})",
        "type": biome_name,
        "description": template.get("description", ""),
        "story_role": story_role,
        "shape": shape_name,
        "floor": floor_num,
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
            "sun_energy": mood.get("sun_energy", 0.0),
            "lighting": {"type": "dark" if mood.get("sun_energy", 0) == 0 else "bright"},
        },
        "layout": {
            "width": actual_w * 50, "height": actual_h * 50,
            "ground_color": [0.2, 0.18, 0.15],
            "entrance": {"x": spawn_gx * 50, "y": spawn_gz * 50},
        },
        "exits": [], "props": [], "story_npcs": [], "ambient_npcs": [],
        "treasures": [], "encounters": [], "shop": [], "connections": [],
    }

    return room


def _find_door_center(grid_map: list[str], width: int, height: int, side: str) -> tuple[float, float]:
    """Find the center position of door tiles on the given side."""
    door_positions = []
    for z, row in enumerate(grid_map):
        for x, cell in enumerate(row):
            if cell != "D":
                continue
            if side == "north" and z == 0:
                door_positions.append((x + 0.5, z + 0.5))
            elif side == "south" and z == height - 1:
                door_positions.append((x + 0.5, z + 0.5))
            elif side == "east" and x == len(row) - 1:
                door_positions.append((x + 0.5, z + 0.5))
            elif side == "west" and x == 0:
                door_positions.append((x + 0.5, z + 0.5))

    if door_positions:
        avg_x = sum(p[0] for p in door_positions) / len(door_positions)
        avg_z = sum(p[1] for p in door_positions) / len(door_positions)
        return avg_x, avg_z

    # Fallback: center of that side
    if side == "north":
        return width / 2.0, 0.5
    elif side == "south":
        return width / 2.0, height - 0.5
    elif side == "east":
        return width - 0.5, height / 2.0
    else:
        return 0.5, height / 2.0


def _opposite_dir(direction: str) -> str:
    return {"north": "south", "south": "north", "east": "west", "west": "east"}.get(direction, direction)


# ============================================================
# DUNGEON LAYOUT — 2D placement with optional multi-floor
# ============================================================

def generate_dungeon(num_rooms: int, seed: int, sequence: list[str] | None = None,
                     biome_name: str = "dungeon", num_floors: int = 1) -> tuple[list[dict], dict]:
    """Generate a dungeon with 2D layout, varied shapes, and optional multi-floor."""
    rng = random.Random(seed)

    if sequence is None:
        sequence = DEFAULT_SEQUENCE
    while len(sequence) < num_rooms:
        sequence.append(rng.choice(list(ROOM_TEMPLATES.keys())))
    sequence = sequence[:num_rooms]

    # Distribute rooms across floors
    rooms_per_floor = []
    base = num_rooms // num_floors
    remainder = num_rooms % num_floors
    for f in range(num_floors):
        count = base + (1 if f < remainder else 0)
        rooms_per_floor.append(count)

    all_rooms = []
    dungeon_rooms = []
    room_idx = 0
    floor_y_spacing = 50.0  # Y offset between floors

    for floor_num in range(num_floors):
        floor_count = rooms_per_floor[floor_num]
        floor_sequence = sequence[room_idx:room_idx + floor_count]

        # Plan 2D layout for this floor
        directions = {
            "north": (0, -1), "south": (0, 1),
            "east": (1, 0), "west": (-1, 0),
        }
        placed = {}
        room_positions = []

        cx, cz = 0, 0
        placed[(cx, cz)] = 0
        room_positions.append((cx, cz, None))

        for i in range(1, floor_count):
            dir_options = list(directions.keys())
            rng.shuffle(dir_options)
            placed_ok = False

            for dir_name in dir_options:
                dx, dz = directions[dir_name]
                nx, nz = cx + dx, cz + dz
                if (nx, nz) not in placed:
                    placed[(nx, nz)] = i
                    room_positions.append((nx, nz, dir_name))
                    cx, cz = nx, nz
                    placed_ok = True
                    break

            if not placed_ok:
                for pos in list(placed.keys()):
                    for dir_name in dir_options:
                        dx, dz = directions[dir_name]
                        nx, nz = pos[0] + dx, pos[1] + dz
                        if (nx, nz) not in placed:
                            placed[(nx, nz)] = i
                            room_positions.append((nx, nz, dir_name))
                            cx, cz = nx, nz
                            placed_ok = True
                            break
                    if placed_ok:
                        break

        # Generate rooms for this floor
        floor_rooms = []
        for i, story_role in enumerate(floor_sequence):
            room_id = f"gen_f{floor_num+1}_room_{i+1:03d}"
            gx, gz, _ = room_positions[i]

            doors = {
                "north": (gx, gz - 1) in placed,
                "south": (gx, gz + 1) in placed,
                "east": (gx + 1, gz) in placed,
                "west": (gx - 1, gz) in placed,
            }

            room = generate_room(room_id, story_role, doors, biome_name, rng, floor_num)
            floor_rooms.append(room)
            all_rooms.append(room)

        # Calculate offsets by placing rooms so doors are adjacent
        # Room center in world = offset. Grid is centered: local x=0 is at grid col w/2
        room_offsets = {0: (0.0, 0.0)}

        for i in range(1, len(floor_rooms)):
            gx, gz, connect_dir = room_positions[i]
            room = floor_rooms[i]
            room_grid = room["grid"]["map"]
            room_w = max(len(r) for r in room_grid)
            room_h = len(room_grid)

            # I moved in connect_dir to get here, so my parent is BEHIND me
            # E.g., connect_dir=east means I went east, parent is to my west
            opp = _opposite_dir(connect_dir)
            dir_deltas = {"north": (0, -1), "south": (0, 1), "east": (1, 0), "west": (-1, 0)}
            pdx, pdz = dir_deltas[opp]
            parent_pos = (gx + pdx, gz + pdz)

            parent_idx = placed.get(parent_pos)
            if parent_idx is None or parent_idx not in room_offsets:
                room_offsets[i] = (0.0, 0.0)
                continue

            parent = floor_rooms[parent_idx]
            p_grid = parent["grid"]["map"]
            p_w = max(len(r) for r in p_grid)
            p_h = len(p_grid)
            p_ox, p_oz = room_offsets[parent_idx]

            # Parent's door toward me is on the side FACING me (connect_dir)
            # I went east → parent's east door faces me, my west door faces parent
            p_door_x, p_door_z = _find_door_center(p_grid, p_w, p_h, connect_dir)
            my_door_side = _opposite_dir(connect_dir)
            my_door_x, my_door_z = _find_door_center(room_grid, room_w, room_h, my_door_side)

            # Align door x-centers (or z-centers for east/west connections)
            if connect_dir in ("north", "south"):
                # Rooms stack vertically (z-axis). Align x-centers of doors.
                # Parent door world-x = p_ox + (p_door_x - p_w/2)
                p_door_world_x = p_ox + (p_door_x - p_w / 2.0)
                # My door local-x = my_door_x - room_w/2
                my_door_local_x = my_door_x - room_w / 2.0
                ox = p_door_world_x - my_door_local_x

                # Z: place my room so my door row is adjacent to parent's door row
                if connect_dir == "south":
                    # Parent is south of me. Parent's south door is at their last row.
                    # My north door is at my first row.
                    # Parent's south edge world-z = p_oz + p_h/2
                    # My north edge world-z = oz - room_h/2
                    # Adjacent: my north edge = parent south edge
                    oz = p_oz + p_h / 2.0 + room_h / 2.0
                else:  # north
                    oz = p_oz - p_h / 2.0 - room_h / 2.0

            else:  # east or west
                # Rooms stack horizontally (x-axis). Align z-centers of doors.
                p_door_world_z = p_oz + (p_door_z - p_h / 2.0)
                my_door_local_z = my_door_z - room_h / 2.0
                oz = p_door_world_z - my_door_local_z

                if connect_dir == "east":
                    ox = p_ox + p_w / 2.0 + room_w / 2.0
                else:  # west
                    ox = p_ox - p_w / 2.0 - room_w / 2.0

            room_offsets[i] = (ox, oz)

        for i, room in enumerate(floor_rooms):
            ox, oz = room_offsets.get(i, (0.0, 0.0))
            dungeon_rooms.append({
                "location": room["id"],
                "offset": {
                    "x": ox,
                    "y": float(floor_num * floor_y_spacing),
                    "z": oz,
                },
                "floor": floor_num,
            })

        room_idx += floor_count

    # Add stairs between floors
    if num_floors > 1:
        for f in range(num_floors - 1):
            # Find last room on floor f and first room on floor f+1
            floor_f_rooms = [r for r in dungeon_rooms if r["floor"] == f]
            floor_f1_rooms = [r for r in dungeon_rooms if r["floor"] == f + 1]
            if floor_f_rooms and floor_f1_rooms:
                # Mark last room of floor f as having stairs
                last_room_id = floor_f_rooms[-1]["location"]
                for room in all_rooms:
                    if room["id"] == last_room_id:
                        room["has_stairs_up"] = True
                        room["stairs_target_floor"] = f + 1
                        break

    dungeon = {
        "starting_room": all_rooms[0]["id"] if all_rooms else "",
        "spawn_on_grid": all_rooms[0]["spawn_on_grid"] if all_rooms else {"gx": 4, "gz": 4},
        "num_floors": num_floors,
        "rooms": dungeon_rooms,
    }

    return all_rooms, dungeon


# ============================================================
# MAIN
# ============================================================

def main():
    parser = argparse.ArgumentParser(description="Generate a procedural dungeon")
    parser.add_argument("data_dir", type=Path, help="Game data directory")
    parser.add_argument("--rooms", type=int, default=5, help="Number of rooms (default 5)")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    parser.add_argument("--biome", type=str, default="dungeon",
                        help="Biome: dungeon, town, forest, cave, castle, interior")
    parser.add_argument("--floors", type=int, default=1, help="Number of floors (default 1)")
    parser.add_argument("--sequence", type=str, default=None,
                        help="Comma-separated room types")
    args = parser.parse_args()

    data_dir = args.data_dir.resolve()
    locations_dir = data_dir / "locations"
    locations_dir.mkdir(parents=True, exist_ok=True)

    sequence = args.sequence.split(",") if args.sequence else None
    rooms, dungeon = generate_dungeon(args.rooms, args.seed, sequence, args.biome, args.floors)

    for room in rooms:
        path = locations_dir / f"{room['id']}.json"
        path.write_text(json.dumps(room, indent=2))
        grid = room["grid"]["map"]
        w = max(len(r) for r in grid)
        print(f"  {room['id']}: {w}x{len(grid)} {room['story_role']} shape={room['shape']} floor={room['floor']} — {len(room['npcs_on_grid'])} enemies, {len(room['props_on_grid'])} props")

    dungeon_path = data_dir / "dungeon.json"
    dungeon_path.write_text(json.dumps(dungeon, indent=2))
    print(f"\nGenerated {len(rooms)} rooms ({args.biome} biome, {args.floors} floor(s)) → {locations_dir}/")

    # Generate nav_grid
    import subprocess
    map_tool = Path(__file__).parent / "dungeon_map.py"
    if map_tool.exists():
        subprocess.run(["python3", str(map_tool), str(data_dir)], capture_output=True)
        print(f"Nav grid → {data_dir / 'nav_grid.json'}")


if __name__ == "__main__":
    main()
