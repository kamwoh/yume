#!/usr/bin/env python3
"""Procedural simulation world generator.

Generates a complete world as JSON — terrain, elements, paths, camp.
Godot reads the JSON and renders. Same seed = same world.

Usage:
    python generate_sim_world.py /path/to/game/data/ --seed 42 --size 100
    python generate_sim_world.py /path/to/game/data/ --seed 99 --size 150 --biome forest
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
from pathlib import Path


# ============================================================
# NOISE — simple Perlin-like value noise for terrain
# ============================================================

def _hash2d(x: int, z: int, seed: int) -> float:
    """Deterministic pseudo-random from grid coords."""
    n = x * 374761393 + z * 668265263 + seed * 1274126177
    n = (n ^ (n >> 13)) * 1274126177
    n = n ^ (n >> 16)
    return (n & 0x7fffffff) / 0x7fffffff


def value_noise(x: float, z: float, seed: int, scale: float = 20.0) -> float:
    """Smooth value noise in [0, 1]."""
    sx = x / scale
    sz = z / scale
    ix, iz = int(math.floor(sx)), int(math.floor(sz))
    fx, fz = sx - ix, sz - iz
    # Smoothstep
    fx = fx * fx * (3 - 2 * fx)
    fz = fz * fz * (3 - 2 * fz)
    # 4 corners
    v00 = _hash2d(ix, iz, seed)
    v10 = _hash2d(ix + 1, iz, seed)
    v01 = _hash2d(ix, iz + 1, seed)
    v11 = _hash2d(ix + 1, iz + 1, seed)
    # Bilinear interpolation
    v0 = v00 + (v10 - v00) * fx
    v1 = v01 + (v11 - v01) * fx
    return v0 + (v1 - v0) * fz


def multi_octave_noise(x: float, z: float, seed: int, octaves: int = 3,
                        scale: float = 20.0, persistence: float = 0.5) -> float:
    """Layered noise for natural-looking terrain."""
    total = 0.0
    amplitude = 1.0
    frequency = 1.0
    max_val = 0.0
    for i in range(octaves):
        total += value_noise(x * frequency, z * frequency, seed + i * 1000, scale) * amplitude
        max_val += amplitude
        amplitude *= persistence
        frequency *= 2.0
    return total / max_val


# ============================================================
# ELEMENT PLACEMENT — Poisson disk-like with clustering
# ============================================================

def poisson_scatter(width: float, height: float, count: int, min_spacing: float,
                     cluster_size: int, rng: random.Random,
                     avoid_positions: list | None = None) -> list[tuple[float, float]]:
    """Place points with minimum spacing, optionally clustered."""
    positions = []
    avoid = avoid_positions or []
    max_attempts = count * 20

    for _ in range(count):
        placed = False
        for _ in range(max_attempts // count):
            x = rng.uniform(-width / 2 + 2, width / 2 - 2)
            z = rng.uniform(-height / 2 + 2, height / 2 - 2)

            # Check min spacing from existing
            too_close = False
            for px, pz in positions + avoid:
                if (x - px) ** 2 + (z - pz) ** 2 < min_spacing ** 2:
                    too_close = True
                    break
            if too_close:
                continue

            # Place cluster
            positions.append((x, z))
            for c in range(1, cluster_size):
                cx = x + rng.uniform(-1.5, 1.5)
                cz = z + rng.uniform(-1.5, 1.5)
                positions.append((cx, cz))
            placed = True
            break

    return positions


# ============================================================
# TERRAIN GENERATION
# ============================================================

def generate_terrain(width: float, height: float, seed: int,
                     terrain_config: dict | None = None) -> dict:
    """Generate terrain heightmap + decoration data. All params from config."""
    rng = random.Random(seed)
    cfg = terrain_config or {}

    resolution = cfg.get("resolution", 128)
    height_scale = cfg.get("height_scale", 4.0)
    noise_octaves = cfg.get("noise_octaves", 5)
    noise_scale = cfg.get("noise_scale", 40.0)
    noise_persistence = cfg.get("noise_persistence", 0.5)
    hills_octaves = cfg.get("hills_octaves", 2)
    hills_scale = cfg.get("hills_scale", 80.0)
    hills_persistence = cfg.get("hills_persistence", 0.6)
    hills_amplitude = cfg.get("hills_amplitude", 0.5)
    camp_flatten_radius = cfg.get("camp_flatten_radius", 20.0)
    camp_flatten_strength = cfg.get("camp_flatten_strength", 0.9)
    edge_rise_start = cfg.get("edge_rise_start", 0.7)
    edge_rise_power = cfg.get("edge_rise_power", 2.0)
    edge_rise_height = cfg.get("edge_rise_height", 0.6)

    # Generate heightmap as flat array [z * resolution + x]
    heights = []
    for z in range(resolution):
        for x in range(resolution):
            wx = (x / (resolution - 1) - 0.5) * width
            wz = (z / (resolution - 1) - 0.5) * height

            # Primary noise
            h = multi_octave_noise(wx, wz, seed, octaves=noise_octaves,
                                    scale=noise_scale, persistence=noise_persistence)

            # Rolling hills layer
            h += multi_octave_noise(wx + 500, wz + 500, seed + 100,
                                     octaves=hills_octaves, scale=hills_scale,
                                     persistence=hills_persistence) * hills_amplitude

            # Flatten camp area
            dist_from_center = math.sqrt(wx * wx + wz * wz)
            camp_flatten = max(0.0, 1.0 - dist_from_center / camp_flatten_radius)
            h *= (1.0 - camp_flatten * camp_flatten_strength)

            # Edge rise
            edge_dist = max(abs(wx) / (width / 2), abs(wz) / (height / 2))
            if edge_dist > edge_rise_start:
                edge_t = (edge_dist - edge_rise_start) / (1.0 - edge_rise_start)
                h += (edge_t ** edge_rise_power) * edge_rise_height

            heights.append(round(h, 4))

    # Ground patches — subtle color variation
    patches = []
    num_patches = int(width * height / 40)
    for _ in range(num_patches):
        patches.append({
            "x": rng.uniform(-width / 2 + 2, width / 2 - 2),
            "z": rng.uniform(-height / 2 + 2, height / 2 - 2),
            "radius": 1.5 + rng.random() * 3.0,
            "shade": rng.choice(["lighter", "darker"]),
        })

    # Flowers
    flowers = []
    num_flowers = int(width * height / 25)
    flower_colors = ["yellow", "red", "white", "purple"]
    for _ in range(num_flowers):
        flowers.append({
            "x": round(rng.uniform(-width / 2 + 1, width / 2 - 1), 2),
            "z": round(rng.uniform(-height / 2 + 1, height / 2 - 1), 2),
            "color": rng.choice(flower_colors),
            "size": round(0.05 + rng.random() * 0.06, 3),
        })

    return {
        "heightmap": {
            "resolution": resolution,
            "height_scale": height_scale,
            "heights": heights,
        },
        "patches": patches,
        "flowers": flowers,
    }


# ============================================================
# EDGE TREES
# ============================================================

def generate_edge_trees(width: float, height: float, seed: int) -> list[dict]:
    """Ring of trees around world border."""
    rng = random.Random(seed + 999)
    trees = []
    perimeter = 2 * (width + height)
    num_trees = int(perimeter / 1.5)
    tree_variants = ["tree_default", "tree_oak", "tree_cone", "tree_fat", "tree_tall", "tree_thin"]

    for i in range(num_trees):
        angle = (i / num_trees) * math.tau
        r = (min(width, height) / 2.0) - 1.0 + rng.uniform(-1.0, 2.0)
        x = math.cos(angle) * r
        z = math.sin(angle) * r
        if abs(x) < width / 2 and abs(z) < height / 2:
            trees.append({
                "x": x,
                "z": z,
                "model": rng.choice(tree_variants),
                "scale": 0.8 + rng.random() * 0.6,
                "rotation_y": rng.random() * 360,
            })

    return trees


# ============================================================
# PATHS
# ============================================================

def generate_paths(camp_x: float, camp_z: float, width: float, height: float,
                    seed: int) -> list[dict]:
    """Dirt paths radiating from camp."""
    rng = random.Random(seed + 777)
    path_tiles = []

    directions = [
        (1.0, 0.0, 90.0),
        (-1.0, 0.0, 90.0),
        (0.0, 1.0, 0.0),
        (0.0, -1.0, 0.0),
        (0.7, 0.7, 45.0),
    ]

    path_models = ["ground_pathStraight", "ground_pathOpen", "ground_pathRocks"]

    for dx, dz, rot in directions:
        path_len = rng.randint(8, 20)
        for i in range(path_len):
            px = camp_x + dx * i * 1.0
            pz = camp_z + dz * i * 1.0
            # Don't extend past world
            if abs(px) > width / 2 - 3 or abs(pz) > height / 2 - 3:
                break
            path_tiles.append({
                "x": px + rng.uniform(-0.15, 0.15),
                "z": pz + rng.uniform(-0.15, 0.15),
                "model": rng.choice(path_models),
                "rotation_y": rot,
                "scale": 0.5,
            })

    # Crossroads at camp
    path_tiles.append({
        "x": camp_x, "z": camp_z,
        "model": "ground_pathCross",
        "rotation_y": 0, "scale": 0.5,
    })

    return path_tiles


# ============================================================
# CAMP
# ============================================================

def generate_camp(camp_x: float, camp_z: float, seed: int) -> list[dict]:
    """Starting camp elements."""
    rng = random.Random(seed + 555)
    elements = [
        {"element": "campfire", "x": camp_x, "z": camp_z,
         "model": rng.choice(["campfire_stones", "campfire_logs"]), "scale": 1.0},
        {"element": "shelter", "x": camp_x - 3, "z": camp_z - 2,
         "model": "tent", "scale": 1.5, "rotation_y": rng.random() * 30},
        {"element": "shelter", "x": camp_x + 3, "z": camp_z - 1,
         "model": "tent-canvas", "scale": 1.5, "rotation_y": 180 + rng.random() * 30},
        {"element": "stone", "x": camp_x - 2, "z": camp_z + 2,
         "model": "rock_smallA", "scale": 0.8},
        {"element": "stone", "x": camp_x + 2, "z": camp_z + 2,
         "model": "rock_smallB", "scale": 0.8},
    ]
    return elements


# ============================================================
# ELEMENTS
# ============================================================

ELEMENT_MODELS = {
    "tree": {
        "variants": ["tree_default", "tree_oak", "tree_cone", "tree_fat",
                      "tree_detailed", "tree_tall", "tree_thin", "tree_small"],
        "scale_range": [0.7, 1.2],
    },
    "bush": {
        "variants": ["plant_bush", "plant_bushLarge", "plant_bushSmall",
                      "plant_bushDetailed", "plant_bushTriangle"],
        "scale_range": [0.8, 1.2],
    },
    "stone": {
        "variants": ["rock_largeA", "rock_largeB", "rock_smallA",
                      "rock_smallB", "rock_tallA", "rock_tallB"],
        "scale_range": [0.5, 1.0],
    },
    "water": {
        "variants": ["_primitive_water"],
        "scale_range": [1.0, 2.0],
    },
    "dirt": {
        "variants": ["patch-grass", "patch-grass-foliage"],
        "scale_range": [0.8, 1.2],
    },
    "grass_detail": {
        "variants": ["grass", "grass_large", "grass_leafs",
                      "flower_redA", "flower_yellowA", "flower_purpleA",
                      "mushroom_red", "mushroom_tan"],
        "scale_range": [0.8, 1.2],
    },
}

SCATTER_DEFAULTS = [
    {"element": "tree", "count": 120, "min_spacing": 3, "cluster_size": 3},
    {"element": "bush", "count": 80, "min_spacing": 2, "cluster_size": 2},
    {"element": "stone", "count": 40, "min_spacing": 4, "cluster_size": 2},
    {"element": "water", "count": 10, "min_spacing": 12, "cluster_size": 6},
    {"element": "dirt", "count": 25, "min_spacing": 5, "cluster_size": 1},
    {"element": "grass_detail", "count": 100, "min_spacing": 2, "cluster_size": 3},
]


def generate_elements(width: float, height: float, seed: int,
                       scatter_config: list | None = None) -> list[dict]:
    """Scatter all world elements with proper spacing."""
    rng = random.Random(seed)
    scatter = scatter_config or SCATTER_DEFAULTS
    all_elements = []
    all_positions = []  # For global spacing check

    # Scale counts by world area relative to 100x100
    area_scale = (width * height) / 10000.0

    for sc in scatter:
        eid = sc["element"]
        count = int(sc.get("count", 10) * area_scale)
        min_sp = sc.get("min_spacing", 3)
        cluster = sc.get("cluster_size", 1)
        models = ELEMENT_MODELS.get(eid, {"variants": ["_primitive"], "scale_range": [1.0, 1.0]})

        positions = poisson_scatter(width, height, count, min_sp, cluster, rng, all_positions)

        for x, z in positions:
            variant = rng.choice(models["variants"])
            sr = models["scale_range"]
            scale = sr[0] + rng.random() * (sr[1] - sr[0])

            all_elements.append({
                "element": eid,
                "x": round(x, 2),
                "z": round(z, 2),
                "model": variant,
                "scale": round(scale, 2),
                "rotation_y": round(rng.random() * 360, 1),
            })

        all_positions.extend(positions)

    return all_elements


# ============================================================
# MAIN GENERATOR
# ============================================================

def generate_sim_world(seed: int, width: float = 100, height: float = 100,
                       terrain_config: dict | None = None) -> dict:
    """Generate complete simulation world. All terrain params from config."""
    camp_x = 0.0
    camp_z = 0.0

    terrain = generate_terrain(width, height, seed, terrain_config)
    edge_trees = generate_edge_trees(width, height, seed)
    paths = generate_paths(camp_x, camp_z, width, height, seed)
    camp = generate_camp(camp_x, camp_z, seed)
    elements = generate_elements(width, height, seed)

    world = {
        "seed": seed,
        "world_size": {"width": width, "height": height},
        "spawn": {"x": camp_x, "z": camp_z},
        "terrain": terrain,
        "edge_trees": edge_trees,
        "paths": paths,
        "camp": camp,
        "elements": elements,
        "atmosphere": {
            "bg_color": [0.45, 0.65, 1.0],
            "ambient_light": [0.55, 0.55, 0.5],
            "ambient_energy": 0.7,
            "sun_energy": 1.4,
            "sun_color": [1.0, 0.93, 0.78],
            "sun_rotation": [-35, 40, 0],
            "fog_density": 0.012,
            "fog_color": [0.72, 0.78, 0.88],
        },
        "day_night": {
            "enabled": True,
            "cycle_seconds": 300,
            "day_ratio": 0.7,
        },
    }

    return world


def main():
    parser = argparse.ArgumentParser(description="Generate a simulation world")
    parser.add_argument("data_dir", type=Path, help="Game data directory")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    parser.add_argument("--size", type=int, default=100, help="World size (width=height)")
    args = parser.parse_args()

    data_dir = args.data_dir.resolve()
    sim_dir = data_dir / "sim"
    sim_dir.mkdir(parents=True, exist_ok=True)

    # Load terrain config from world_config.json if exists
    terrain_config = None
    wc_path = sim_dir / "world_config.json"
    if wc_path.exists():
        wc = json.loads(wc_path.read_text())
        terrain_config = wc.get("terrain", None)
        if terrain_config:
            print(f"Terrain config loaded from world_config.json")

    world = generate_sim_world(args.seed, args.size, args.size, terrain_config)

    # Save
    output = sim_dir / "generated_world.json"
    output.write_text(json.dumps(world, indent=2))

    # Stats
    print(f"World: {args.size}x{args.size}, seed={args.seed}")
    hmap = world['terrain'].get('heightmap', {})
    print(f"  Terrain: {hmap.get('resolution', 0)}x{hmap.get('resolution', 0)} heightmap, {len(world['terrain']['patches'])} patches, {len(world['terrain']['flowers'])} flowers")
    print(f"  Edge trees: {len(world['edge_trees'])}")
    print(f"  Paths: {len(world['paths'])} tiles")
    print(f"  Camp: {len(world['camp'])} structures")
    print(f"  Elements: {len(world['elements'])}")
    total = len(world['edge_trees']) + len(world['paths']) + len(world['camp']) + len(world['elements']) + len(world['terrain']['flowers'])
    print(f"  Total objects: {total}")
    print(f"\nSaved → {output}")


if __name__ == "__main__":
    main()
