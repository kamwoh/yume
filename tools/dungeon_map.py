#!/usr/bin/env python3
"""Generates a 2D occupancy map from dungeon.json + location JSONs.

Visualizes the entire seamless dungeon as ASCII and outputs a grid
that can be used for A* pathfinding.

Usage:
    python dungeon_map.py /path/to/game/data/
"""

import json
import sys
from pathlib import Path


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def build_occupancy_grid(data_dir: Path) -> tuple:
    """Build a 2D grid from dungeon.json + all room JSONs.

    Returns: (grid, min_x, min_z, cell_size, room_info)
    Grid values: 0=void, 1=floor, 2=wall, 3=door, 4=prop, 5=enemy, 6=interactable
    """
    dungeon_path = data_dir / "dungeon.json"
    if not dungeon_path.exists():
        # Single room mode
        print("No dungeon.json found — using progression.json")
        prog = load_json(data_dir / "progression.json")
        loc_id = prog.get("starting_location", "")
        rooms = [{"location": loc_id, "offset": {"x": 0, "z": 0}}]
    else:
        dungeon = load_json(dungeon_path)
        rooms = dungeon.get("rooms", [])

    # First pass: determine world bounds
    all_cells = []  # (world_x, world_z, cell_type, room_name)

    for room_def in rooms:
        loc_id = room_def["location"]
        offset_x = room_def.get("offset", {}).get("x", 0)
        offset_z = room_def.get("offset", {}).get("z", 0)

        loc_path = data_dir / "locations" / f"{loc_id}.json"
        if not loc_path.exists():
            print(f"  Warning: {loc_id}.json not found")
            continue

        loc = load_json(loc_path)
        grid = loc.get("grid", {})
        grid_map = grid.get("map", [])
        tile_size = grid.get("tile_size", 1.0)

        if not grid_map:
            continue

        rows = len(grid_map)
        cols = len(grid_map[0])
        grid_ox = -cols * tile_size / 2.0
        grid_oz = -rows * tile_size / 2.0

        for z, row in enumerate(grid_map):
            for x, cell in enumerate(row):
                wx = offset_x + grid_ox + x * tile_size + tile_size / 2
                wz = offset_z + grid_oz + z * tile_size + tile_size / 2

                if cell == "F":
                    all_cells.append((wx, wz, 1, loc_id))
                elif cell == "W":
                    all_cells.append((wx, wz, 2, loc_id))
                elif cell == "D":
                    all_cells.append((wx, wz, 3, loc_id))

        # Props
        for prop in loc.get("props_on_grid", []):
            gx = prop.get("gx", 0)
            gz = prop.get("gz", 0)
            wx = offset_x + grid_ox + gx * tile_size + tile_size / 2
            wz = offset_z + grid_oz + gz * tile_size + tile_size / 2
            cell_type = 6 if prop.get("interactable", False) else 4
            all_cells.append((wx, wz, cell_type, loc_id))

        # NPCs
        for npc in loc.get("npcs_on_grid", []):
            gx = npc.get("gx", 0)
            gz = npc.get("gz", 0)
            wx = offset_x + grid_ox + gx * tile_size + tile_size / 2
            wz = offset_z + grid_oz + gz * tile_size + tile_size / 2
            all_cells.append((wx, wz, 5, loc_id))

    if not all_cells:
        print("No cells found!")
        return None, 0, 0, 1, {}

    # Determine bounds
    min_x = min(c[0] for c in all_cells) - 1
    max_x = max(c[0] for c in all_cells) + 1
    min_z = min(c[1] for c in all_cells) - 1
    max_z = max(c[1] for c in all_cells) + 1

    cell_size = 1.0
    grid_w = int((max_x - min_x) / cell_size) + 1
    grid_h = int((max_z - min_z) / cell_size) + 1

    # Build grid
    grid = [[0] * grid_w for _ in range(grid_h)]

    for wx, wz, cell_type, room_name in all_cells:
        gx = int((wx - min_x) / cell_size)
        gz = int((wz - min_z) / cell_size)
        if 0 <= gx < grid_w and 0 <= gz < grid_h:
            # Higher cell type wins (enemy > prop > door > floor)
            if cell_type > grid[gz][gx] or grid[gz][gx] == 0:
                grid[gz][gx] = cell_type

    return grid, min_x, min_z, cell_size, {"width": grid_w, "height": grid_h}


def print_ascii_map(grid: list, info: dict) -> None:
    """Print the grid as ASCII art."""
    symbols = {0: " ", 1: ".", 2: "#", 3: "D", 4: "o", 5: "E", 6: "!"}

    print(f"\n{'='*60}")
    print(f"  DUNGEON MAP ({info['width']}x{info['height']})")
    print(f"{'='*60}")
    print(f"  Legend: .=floor #=wall D=door o=prop E=enemy !=interactable")
    print()

    for row in grid:
        line = "  "
        for cell in row:
            line += symbols.get(cell, "?")
        print(line)

    print()

    # Stats
    floor_count = sum(1 for row in grid for c in row if c == 1)
    wall_count = sum(1 for row in grid for c in row if c == 2)
    door_count = sum(1 for row in grid for c in row if c == 3)
    prop_count = sum(1 for row in grid for c in row if c == 4)
    enemy_count = sum(1 for row in grid for c in row if c == 5)
    interact_count = sum(1 for row in grid for c in row if c == 6)

    print(f"  Floor: {floor_count}  Walls: {wall_count}  Doors: {door_count}")
    print(f"  Props: {prop_count}  Enemies: {enemy_count}  Interactables: {interact_count}")
    print(f"  Walkable: {floor_count + door_count} tiles")


def export_grid_json(grid: list, min_x: float, min_z: float, cell_size: float, output_path: Path) -> None:
    """Export grid as JSON for A* pathfinding in GDScript."""
    data = {
        "grid": grid,
        "min_x": min_x,
        "min_z": min_z,
        "cell_size": cell_size,
        "width": len(grid[0]) if grid else 0,
        "height": len(grid),
        "walkable_values": [1, 3, 4, 5, 6],  # floor, door, prop, enemy, interactable
    }
    output_path.write_text(json.dumps(data, separators=(",", ":")))
    print(f"\n  Grid exported to: {output_path}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python dungeon_map.py /path/to/game/data/")
        sys.exit(1)

    data_dir = Path(sys.argv[1])
    if not data_dir.exists():
        print(f"Error: {data_dir} not found")
        sys.exit(1)

    grid, min_x, min_z, cell_size, info = build_occupancy_grid(data_dir)
    if grid is None:
        sys.exit(1)

    print_ascii_map(grid, info)

    # Export for A* use
    output = data_dir / "nav_grid.json"
    export_grid_json(grid, min_x, min_z, cell_size, output)


if __name__ == "__main__":
    main()
