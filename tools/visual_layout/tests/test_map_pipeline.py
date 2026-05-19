"""test_map_pipeline.py — extract_map + compile_map tests (ADR 0054 Phase 3).

Synthetic map images painted programmatically. Covers:
- Coord transform pixel ↔ world
- anchor / zone / path extraction
- Path skeletonization + tracing
- Compile to entities.json fragment

Usage:
    python3 -m tools.visual_layout.tests.test_map_pipeline
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from tools.visual_layout.compile_map import compile_layout_to_entities  # noqa: E402
from tools.visual_layout.extract_map import (  # noqa: E402
    extract_map_layout,
    image_px_to_world,
    layout_to_dict,
)
from tools.visual_layout.extractor_common import Legend, LegendEntry  # noqa: E402

_PASS = 0
_FAIL = 0


def _check(cond: bool, label: str, detail: str = "") -> None:
    global _PASS, _FAIL
    if cond:
        _PASS += 1
        print(f"  ✓ {label}")
    else:
        _FAIL += 1
        print(f"  ✗ {label}\n      {detail}")


# ============================================================
# COORDINATE TRANSFORM
# ============================================================


def test_image_to_world_centers() -> None:
    print("\n[1] image_px_to_world: image center → world origin")
    wx, wz = image_px_to_world(100, 100, (200, 200), (100, 100))
    _check(abs(wx) < 0.01 and abs(wz) < 0.01, f"center → (0, 0) (got ({wx:.3f}, {wz:.3f}))")


def test_image_to_world_corners() -> None:
    print("\n[2] image_px_to_world: corners map symmetrically")
    # top-left of 200x200 image → world (-50, -50) at map_size 100×100
    wx, wz = image_px_to_world(0, 0, (200, 200), (100, 100))
    _check(abs(wx + 50) < 0.01 and abs(wz + 50) < 0.01,
           f"(0,0) → (-50,-50) (got ({wx:.1f}, {wz:.1f}))")
    # bottom-right → world (+50, +50)
    wx, wz = image_px_to_world(200, 200, (200, 200), (100, 100))
    _check(abs(wx - 50) < 0.01 and abs(wz - 50) < 0.01,
           f"(200,200) → (+50,+50) (got ({wx:.1f}, {wz:.1f}))")


# ============================================================
# SYNTHETIC MAP IMAGES
# ============================================================


def _build_simple_map(size: int = 200) -> np.ndarray:
    """Synthetic top-down map:
    - Dark grey background bottom + sides
    - Green grass in middle clearing
    - Dark green forest ring around it
    - Yellow fire_pit at center
    - Red-brown hut at left
    - Tan path from hut to fire pit
    """
    img = np.full((size, size, 3), (40, 40, 40), dtype=np.uint8)  # bg
    # forest ring (full image)
    img[:] = (42, 90, 42)  # ≈ #2a5a2a forest
    # grass clearing (centered)
    img[40:160, 40:160] = (160, 216, 112)  # ≈ #a0d870 grass
    # fire pit at center: 16x16 yellow
    img[92:108, 92:108] = (240, 192, 32)  # ≈ #f0c020
    # hut at left-center: 20x20 brown
    img[90:110, 50:70] = (160, 64, 32)  # ≈ #a04020
    # tan path from hut (60, 100) to fire pit (100, 100): horizontal line
    img[98:102, 70:92] = (200, 168, 120)  # ≈ #c8a878
    return img


def _map_legend_simple() -> Legend:
    return Legend(
        name="test_map_simple",
        entries=[
            LegendEntry(name="background", hex="#282828", kind="zone", min_area_px=100),
            LegendEntry(name="grass", hex="#a0d870", kind="zone", min_area_px=500),
            LegendEntry(name="forest", hex="#2a5a2a", kind="zone", min_area_px=500),
            LegendEntry(name="fire_pit", hex="#f0c020", kind="anchor", min_area_px=50),
            LegendEntry(name="hut", hex="#a04020", kind="anchor", min_area_px=100),
            LegendEntry(name="path", hex="#c8a878", kind="path", min_area_px=20),
        ],
        expected_clusters=8,
    )


# ============================================================
# END-TO-END EXTRACTION
# ============================================================


def test_extract_simple_map() -> None:
    print("\n[3] extract_map_layout: synthetic map → anchors + zones + paths")
    img = _build_simple_map(200)
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        import cv2
        cv2.imwrite(f.name, cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
        tmp_path = Path(f.name)
    try:
        legend = _map_legend_simple()
        layout = extract_map_layout(
            tmp_path, legend, map_size=(100.0, 100.0), random_state=42
        )
        # 2 anchors expected: fire_pit + hut
        _check(len(layout.anchors) == 2, f"2 anchors (got {len(layout.anchors)})")
        names = {a.name for a in layout.anchors}
        _check(names == {"fire_pit", "hut"}, f"anchors: fire_pit + hut (got {names})")
        # World pos check — fire_pit centroid is (100, 100) px on 200x200
        # image with map_size 100m → world (0, 0)
        fire = next(a for a in layout.anchors if a.name == "fire_pit")
        _check(abs(fire.world_pos[0]) < 1 and abs(fire.world_pos[1]) < 1,
               f"fire_pit world ≈ (0, 0) (got {fire.world_pos})")
        # Hut centroid (60, 100) px → world (-20, 0)
        hut = next(a for a in layout.anchors if a.name == "hut")
        _check(abs(hut.world_pos[0] + 20) < 2 and abs(hut.world_pos[1]) < 2,
               f"hut world ≈ (-20, 0) (got {hut.world_pos})")
        # 2 zones expected: grass + forest (background skipped)
        zones = [z.name for z in layout.zones]
        _check("grass" in zones, f"grass zone present (zones: {zones})")
        _check("forest" in zones, f"forest zone present (zones: {zones})")
        grass = next(z for z in layout.zones if z.name == "grass")
        _check(grass.area_world > 1000, f"grass area world > 1000 m² (got {grass.area_world})")
        # 1 path expected (the tan strip from hut to fire pit)
        _check(len(layout.paths) >= 1, f"≥1 path (got {len(layout.paths)})")
        if layout.paths:
            p = layout.paths[0]
            _check(p.length_world > 5, f"path length > 5m (got {p.length_world})")
    finally:
        tmp_path.unlink(missing_ok=True)


def test_serialization_round_trip() -> None:
    print("\n[4] layout_to_dict: serializes round-trip cleanly")
    img = _build_simple_map(200)
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        import cv2
        cv2.imwrite(f.name, cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
        tmp_path = Path(f.name)
    try:
        legend = _map_legend_simple()
        layout = extract_map_layout(tmp_path, legend, map_size=(100.0, 100.0), random_state=42)
        d = layout_to_dict(layout)
        # JSON-encodable
        try:
            json.dumps(d)
            _check(True, "MapLayout dict is JSON-serializable")
        except Exception as e:
            _check(False, "JSON-serializable", str(e))
        _check("anchors" in d and "zones" in d and "paths" in d,
               "all three categories in dict")
        # All anchor world_pos as 2-element list
        for a in d["anchors"]:
            _check(isinstance(a["world_pos"], list) and len(a["world_pos"]) == 2,
                   f"anchor {a['name']} world_pos is 2-list")
    finally:
        tmp_path.unlink(missing_ok=True)


# ============================================================
# COMPILE TO ENTITIES.JSON
# ============================================================


def test_compile_layout_to_entities() -> None:
    print("\n[5] compile_layout_to_entities: layout → instances + patterns")
    layout_dict = {
        "image_path": "synthetic.png",
        "image_size_px": [200, 200],
        "map_size": [100.0, 100.0],
        "legend_name": "test_map_simple",
        "anchors": [
            {"name": "fire_pit", "image_px": [100, 100],
             "world_pos": [0.0, 0.0], "footprint_px": 256,
             "bbox_px": [92, 92, 16, 16], "rotation_hint": ""},
            {"name": "hut", "image_px": [60, 100],
             "world_pos": [-20.0, 0.0], "footprint_px": 400,
             "bbox_px": [50, 90, 20, 20], "rotation_hint": "face_fire_pit"},
        ],
        "zones": [
            {"name": "grass", "mask_path": "grass_mask.png",
             "area_px": 14400, "area_world": 3600.0},
            {"name": "forest", "mask_path": "forest_mask.png",
             "area_px": 25600, "area_world": 6400.0},
        ],
        "paths": [],
        "warnings": [],
    }
    fragment = compile_layout_to_entities(layout_dict)
    _check(len(fragment["initial_instances"]) == 2,
           f"2 initial_instances (got {len(fragment['initial_instances'])})")
    # Find the hut instance
    hut_inst = next(
        (i for i in fragment["initial_instances"] if i["_source_anchor"] == "hut"),
        None
    )
    _check(hut_inst is not None, "hut instance present")
    if hut_inst:
        _check(hut_inst["def"] == "prop_mud_hut",
               f"hut → prop_mud_hut (got {hut_inst['def']})")
        _check(hut_inst["position"][0] == -20.0,
               f"hut position x preserved (got {hut_inst['position']})")
        _check(hut_inst.get("state", {}).get("_rotation_hint") == "face_fire_pit",
               "rotation_hint propagated to state._rotation_hint")
    # 1 pattern expected: forest (grass has empty config)
    pat_names = [p.get("_source_zone") for p in fragment["patterns"]]
    _check("forest" in pat_names, f"forest pattern emitted (got {pat_names})")
    if "forest" in pat_names:
        forest_pat = next(p for p in fragment["patterns"] if p["_source_zone"] == "forest")
        # Count scaled by area: 6400 m² × 0.30 density = 1920
        _check(forest_pat["count"] > 1000,
               f"forest count scaled by area (got {forest_pat['count']})")


def test_compile_anchor_override() -> None:
    print("\n[6] compile: per-game anchor_to_def override")
    layout_dict = {
        "anchors": [
            {"name": "fire_pit", "image_px": [0, 0], "world_pos": [0, 0],
             "footprint_px": 100, "bbox_px": [0, 0, 10, 10], "rotation_hint": ""},
        ],
        "zones": [],
        "paths": [],
        "warnings": [],
    }
    custom_map = {"fire_pit": "my_custom_fire_pit_def"}
    fragment = compile_layout_to_entities(layout_dict, anchor_to_def=custom_map)
    inst = fragment["initial_instances"][0]
    _check(inst["def"] == "my_custom_fire_pit_def",
           f"custom def override used (got {inst['def']})")


# ============================================================
# MAIN
# ============================================================


def main() -> int:
    test_image_to_world_centers()
    test_image_to_world_corners()
    test_extract_simple_map()
    test_serialization_round_trip()
    test_compile_layout_to_entities()
    test_compile_anchor_override()
    total = _PASS + _FAIL
    print(f"\npassed: {_PASS}  failed: {_FAIL}  total: {total}")
    return 0 if _FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
