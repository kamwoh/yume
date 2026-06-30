"""test_driver.py — offline unit test for yume_infinigen pure logic.

No bpy / infinigen / network needed — exercises the entity-def emission
and collider-default heuristic that turn a generated asset into a
schema-valid Yume def (ADR 0074).

Usage:
    python3 -m tools.yume_infinigen.tests.test_driver
"""
import json
import os
import sys
import tempfile
from pathlib import Path

from tools.yume_infinigen.config import default_collider, is_foliage
from tools.yume_infinigen.catalog import list_factories, looks_like_part
from tools.yume_infinigen.__main__ import _entity_def, _terrain_def, _scatter_instances

_fails = []


def _check(cond, msg):
    if cond:
        print(f"  ok  {msg}")
    else:
        print(f"  XX  {msg}")
        _fails.append(msg)


def test_collider_defaults():
    print("collider defaults (ADR 0072 heuristic)")
    _check(default_collider("BoulderFactory") == "full", "solid rock -> full wrap")
    _check(default_collider("TreeFactory") == "base", "tree -> trunk-footprint base")
    _check(default_collider("CactusFactory") == "base", "cactus -> base")
    _check(default_collider("MushroomFactory") == "base", "mushroom -> base")
    _check(default_collider("UnknownFactory") == "full", "unknown -> full (safe default)")


def test_entity_def_full():
    print("entity def — full collider (rock)")
    d = _entity_def("boulder_0", "BoulderFactory",
                    "res://data/demo_x/assets/infinigen/boulder_0.glb", 1.30, "full")
    _check(d["id"] == "boulder_0", "id set")
    _check(d["state_init"]["scale"] == 1.3, "scale = natural height (1.30m)")
    _check(d["visual"]["mesh"].endswith("boulder_0.glb"), "mesh res:// path")
    cs = d["physics"]["collision_shape"]
    _check(cs["from_visual_mesh"] is True, "full -> from_visual_mesh true")
    _check(cs["type"] == "box" and len(cs["size"]) == 3, "box collider with fallback size")
    _check(abs(cs["offset"][1] - 0.65) < 1e-6, "offset lifts collider to base (h/2)")
    _check(d["physics"]["$extends"] == "@lib.physics.bodies.static_wall", "extends static_wall")


def test_entity_def_base():
    print("entity def — base collider (tree)")
    d = _entity_def("tree_5", "TreeFactory",
                    "res://data/demo_x/assets/infinigen/tree_5.glb", 6.0, "base")
    cs = d["physics"]["collision_shape"]
    _check(cs["from_visual_mesh"] == "base", "base -> from_visual_mesh 'base' (trunk footprint)")
    _check(cs["size"][0] < cs["size"][1], "base fallback is narrower than tall (trunk-shaped)")


def test_entity_def_none():
    print("entity def — no collider")
    d = _entity_def("mush_1", "MushroomFactory",
                    "res://data/demo_x/assets/infinigen/mush_1.glb", 0.4, "none")
    _check("physics" not in d, "collider none -> no physics block")
    _check(d["state_init"]["scale"] == 0.4, "tiny asset keeps natural scale")


def test_foliage_detection():
    print("foliage detection (billboard vs solid path)")
    _check(is_foliage("TreeFactory"), "TreeFactory -> foliage (billboard)")
    _check(is_foliage("BushFactory"), "BushFactory -> foliage")
    _check(is_foliage("PalmTreeFactory"), "PalmTreeFactory -> foliage")
    _check(not is_foliage("BoulderFactory"), "BoulderFactory -> solid")
    _check(not is_foliage("CoralFactory"), "CoralFactory -> solid")
    _check(not is_foliage("CactusFactory"), "CactusFactory -> solid (no leaf clusters)")


def test_part_detection():
    print("part-factory heuristic (B5 fail-fast gate)")
    _check(looks_like_part("CrabClawFactory"), "CrabClawFactory -> part")
    _check(looks_like_part("BaseCactusFactory"), "BaseCactusFactory -> part")
    _check(looks_like_part("MushroomCapFactory"), "MushroomCapFactory -> part")
    _check(not looks_like_part("BoulderFactory"), "BoulderFactory -> standalone")
    _check(not looks_like_part("FrogFactory"), "FrogFactory -> standalone")


def test_catalog():
    # Only runs when the infinigen repo is reachable; the grep needs source.
    repo = os.environ.get("YUME_INFINIGEN_REPO", "")
    if not repo or not os.path.isdir(repo):
        print("catalog grep — SKIPPED (YUME_INFINIGEN_REPO not set)")
        return
    print("catalog grep (against real infinigen source)")
    facs = list_factories(repo)
    _check(len(facs) > 100, f"found many factories ({len(facs)})")
    _check("BoulderFactory" in facs, "BoulderFactory present")
    _check("CoralFactory" in facs, "CoralFactory present")
    _check(facs.get("BoulderFactory") == "rocks", "BoulderFactory categorized as rocks")


def test_terrain_def():
    print("terrain def (C1)")
    d = _terrain_def("res://data/demo_x/assets/infinigen/terrain.glb")
    _check(d["visual"]["normalize"] is False, "normalize=False (native scale, ADR 0062)")
    _check("terrain" in d["tags"] and "ground" in d["tags"], "terrain+ground tags")
    cs = d["physics"]["collision_shape"]
    _check(cs["type"] == "trimesh", "trimesh collider")
    _check(cs["mesh"].endswith("terrain.glb"), "collider mesh = the glb path (not from_visual_mesh)")


def test_scatter_coords():
    print("scatter instances (C2) — coordinate map + role→def")
    with tempfile.TemporaryDirectory() as td:
        game = Path(td)
        (game / "entities").mkdir()
        (game / "entities" / "infinigen_assets.json").write_text(json.dumps({"definitions": [
            {"id": "tree_0"}, {"id": "boulder_3"}, {"id": "coral_0"}]}))
        # Blender (x,y,z up) point → Yume (x, z, -y up)
        scatter = {"tree": [[10.0, 20.0, 5.0]], "rock": [[1.0, 2.0, 3.0]]}
        insts = _scatter_instances(game, scatter)
    _check(len(insts) == 2, "one instance per position")
    tree = [i for i in insts if i["def"] == "tree_0"]
    _check(len(tree) == 1, "tree role -> tree_0 def")
    _check(tree[0]["position"] == [10.0, 5.0, -20.0], "Blender(10,20,5) -> Yume(10,5,-20)")
    rock = [i for i in insts if i["def"] in ("boulder_3", "coral_0")]
    _check(len(rock) == 1, "rock role -> a boulder/coral def")
    _check("yaw" in rock[0].get("state", {}), "instance carries a varied yaw")


def test_scatter_no_assets():
    print("scatter with no Phase-B assets — skips gracefully")
    with tempfile.TemporaryDirectory() as td:
        game = Path(td); (game / "entities").mkdir()
        insts = _scatter_instances(game, {"tree": [[0, 0, 0]]})
    _check(insts == [], "no asset defs -> no instances (skipped, not crash)")


def main():
    for t in (test_collider_defaults, test_entity_def_full,
              test_entity_def_base, test_entity_def_none,
              test_foliage_detection, test_part_detection,
              test_terrain_def, test_scatter_coords, test_scatter_no_assets,
              test_catalog):
        t()
    print(f"\n{'FAIL' if _fails else 'PASS'}: {len(_fails)} failure(s)")
    return 1 if _fails else 0


if __name__ == "__main__":
    sys.exit(main())
