"""map_smoke.py — end-to-end Phase 3 live test (ADR 0054).

Targets aldenmere's camp layout. Generates a top-down semantic map
via nanobanana, extracts anchors/zones/paths, compiles to an
entities.json fragment, diffs against the existing level layout.

Cost: ~$0.05 per run (nanobanana). Ledger-cached.

Usage:
    python3 -m tools.visual_layout.map_smoke
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.visual_layout.compile_map import compile_layout_to_entities  # noqa: E402
from tools.visual_layout.extract_map import (  # noqa: E402
    extract_map_layout,
    layout_to_dict,
)
from tools.visual_layout.extractor_common import Legend  # noqa: E402
from tools.yume_assetgen.backends.nanobanana import NanobananaBackend  # noqa: E402
from tools.yume_assetgen.ledger import load_ledger, prompt_hash  # noqa: E402

GAME = "demo_aldenmere"
MAP_SIZE_M = 80.0  # ~aldenmere's 50m village + 30m fringe

# Top-down semantic map prompt. Mirrors aldenmere's camp:
# fire pit center, mud hut + market east, river south, forest around.
MAP_PROMPT = """\
A clean flat 2D semantic top-down layout map for a cozy survival \
forest camp clearing.

Strict requirements for machine extraction:
- strict top-down view, flat 2D, no perspective
- dark neutral grey background outside the map (#1a1a1a)
- each object/region is a SOLID FILLED color
- NO shadows, NO gradients, NO textures, NO decorative illustration
- NO text labels, NO icons, NO handwritten characters
- clean rectangular or rounded boundaries between regions
- objects clearly separated, not touching
- square 1:1 composition

Map content (top-down, north is up):
- DARK GREEN (#2a5a2a) dense forest surrounding the clearing (the \
outer ring covering most of the image)
- LIGHT GREEN (#a0d870) open grass clearing in the center (a wide \
oval shape, ~60% of map width)
- YELLOW (#f0c020) small round FIRE PIT at the exact center of the \
clearing
- RED-BROWN (#a04020) HUT to the west of fire pit, a small square
- ORANGE (#e08040) DRYING RACK to the east of fire pit, a small square
- PURPLE (#9060c0) STORAGE area to the southeast, a small square
- DARK OLIVE GREEN (#508030) GARDEN patch to the northwest of fire \
pit, a small square
- BLUE (#3070c0) RIVER along the bottom edge running east-west, a \
horizontal blue band
- DARK BROWN (#704020) BRIDGE crossing the river at bottom-center, \
a small rectangle on top of the blue river
- TAN (#c8a878) dirt PATH connecting the bridge to the fire pit, \
plus shorter branches to hut, drying rack, storage, garden — these \
are thin lines
- PINK (#e040a0) BERRY BUSHES scattered as 3-4 small dots in the \
northwest part of the clearing
- GREY (#808080) ROCKS scattered as 3-4 small dots in the northeast \
part of the clearing

Use ONLY the exact hex colors listed above. Output must look like a \
clean semantic map for a game layout compiler, NOT a painted \
illustration. NO text characters. Square aspect ratio.
"""


def main() -> int:
    game_dir = ROOT / "godot" / "data" / GAME
    layouts_dir = game_dir / "layouts"
    layouts_dir.mkdir(parents=True, exist_ok=True)

    asset_cfg_path = game_dir / "asset_gen.json"
    asset_cfg = json.loads(asset_cfg_path.read_text(encoding="utf-8"))
    nano_cfg = asset_cfg.get("backend_config", {}).get("nanobanana", {})

    ledger = load_ledger(game_dir)
    p_hash = prompt_hash(MAP_PROMPT)
    map_hash = hashlib.sha256(MAP_PROMPT.encode("utf-8")).hexdigest()[:8]
    map_png = layouts_dir / f"camp_map_{map_hash}.png"

    print(f"[map_smoke] target: {GAME}")
    print(f"[map_smoke] prompt_hash: {p_hash}")

    # === Stage 1: generate semantic map ===
    print("\n[map_smoke] === Stage 1: generate semantic map ===")
    hit = ledger.has("nanobanana", "visual_layout_semantic_map", p_hash)
    if hit:
        print(f"[map_smoke] (ledger cached) prior map: {hit['out_path']}")
        map_png = game_dir / hit["out_path"]
    elif map_png.exists():
        print(f"[map_smoke] (file exists, skipping gen) {map_png.name}")
    else:
        nano = NanobananaBackend(nano_cfg)
        nano.generate_texture(MAP_PROMPT, map_png, size=(1024, 1024))
        print(f"[map_smoke] map saved: {map_png.name}")
        ledger.add(
            backend="nanobanana",
            kind="visual_layout_semantic_map",
            entity_id="camp_aldenmere",
            prompt=MAP_PROMPT,
            p_hash=p_hash,
            out_path=str(map_png.relative_to(game_dir)),
        )
        ledger.save()

    # === Stage 2: extract ===
    print("\n[map_smoke] === Stage 2: extract ===")
    legend = Legend.from_file(ROOT / "tools" / "visual_layout" / "legends" / "map_camp_default.json")
    masks_dir = layouts_dir / f"camp_masks_{map_hash}"
    layout = extract_map_layout(
        map_png, legend,
        map_size=(MAP_SIZE_M, MAP_SIZE_M),
        masks_out_dir=masks_dir,
        random_state=42,
    )
    print(f"[map_smoke] anchors={len(layout.anchors)} zones={len(layout.zones)} paths={len(layout.paths)}")
    for a in layout.anchors:
        print(f"  anchor: {a.name:14s} world={a.world_pos} footprint_px={a.footprint_px}")
    for z in layout.zones:
        print(f"  zone:   {z.name:14s} area_world={z.area_world:8.1f} m²")
    for p in layout.paths:
        print(f"  path:   {p.name:14s} length={p.length_world:6.2f}m pts={len(p.world_pts)}")
    if layout.warnings:
        print(f"  warnings: {layout.warnings}")
    layout_dict = layout_to_dict(layout)
    layout_json = layouts_dir / f"camp_layout_{map_hash}.layout.json"
    layout_json.write_text(
        json.dumps(layout_dict, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"[map_smoke] layout saved: {layout_json.name}")

    # === Stage 3: compile to entities.json fragment ===
    print("\n[map_smoke] === Stage 3: compile to entities.json fragment ===")
    # Aldenmere-specific anchor override (matches actual defs in
    # demo_aldenmere/entities/). Reference legend defaults work but
    # the game's def ids differ slightly.
    aldenmere_anchor_map = {
        "fire_pit": "prop_fire_pit",
        "hut": "prop_mud_hut",
        "drying_rack": "prop_drying_rack",
        "storage": "prop_lean_to",
        "garden": "food_berry_bush",
        "berry_bush": "food_berry_bush",
        "rock": "prop_stone_small",
        "bridge": "prop_log_bridge",
    }
    fragment = compile_layout_to_entities(layout_dict, anchor_to_def=aldenmere_anchor_map)
    fragment_path = layouts_dir / f"camp_entities_{map_hash}.json"
    fragment_path.write_text(
        json.dumps(fragment, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        f"[map_smoke] fragment: {len(fragment['initial_instances'])} instances + "
        f"{len(fragment['patterns'])} patterns → {fragment_path.name}"
    )

    # === Stage 4: diff against existing level layout ===
    print("\n[map_smoke] === Stage 4: diff vs existing level/entities.json ===")
    existing_path = game_dir / "levels" / "level_proto_village" / "entities.json"
    if existing_path.exists():
        existing = json.loads(existing_path.read_text(encoding="utf-8"))
        existing_defs = sorted({
            i.get("def", "?") for i in existing.get("initial_instances", [])
            if isinstance(i, dict)
        })
        compiled_defs = sorted({i["def"] for i in fragment["initial_instances"]})
        print(f"  existing defs ({len(existing_defs)}): {existing_defs[:8]}...")
        print(f"  compiled defs ({len(compiled_defs)}): {compiled_defs}")
        overlap = set(existing_defs) & set(compiled_defs)
        print(f"  overlap: {sorted(overlap)}")

    print(f"\n[map_smoke] DONE — outputs in {layouts_dir.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
