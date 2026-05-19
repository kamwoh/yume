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
TECHNICAL DIAGRAM — solid color regions only — like MS Paint with \
the bucket fill tool. ZERO decoration. ZERO texture. ZERO shadows. \
ZERO outlines. ZERO text. ZERO labels. ZERO icons. ZERO dots. \
ZERO trees as separate shapes. ZERO illustrations of any kind.

This is a CSS color palette test, NOT an illustration.

Top-down 2D layout. Each region is a perfectly FLAT solid block of \
ONE hex color. No anti-aliasing artifacts. Plain rectangles or simple \
rounded rectangles only.

Color regions (north is top of frame):

#2a5a2a — solid dark green forest. Fills the outer 25% border of the \
image as a frame around the central clearing.

#a0d870 — solid light green grass clearing. Fills the central 50% of \
the image as one big rectangle.

#f0c020 — solid yellow circle ~8% of image width, placed at exact \
center of frame. This is the fire pit.

#a04020 — solid red-brown square ~8% of image width, placed in the \
left-center of the clearing, west of the yellow circle. This is the hut.

#e08040 — solid orange square ~8% of image width, placed in the \
right-center of the clearing, east of the yellow circle. Drying rack.

#9060c0 — solid purple square ~6% of image width, placed in the \
lower-right of the clearing. Storage.

#c0b070 — solid wheat-gold square ~6% of image width, placed in the \
upper-left of the clearing. Garden plot (cultivated grain field).

#3070c0 — solid blue rectangle filling the bottom 12% of the image, \
edge to edge. River.

#704020 — solid dark brown rectangle ~10% wide × 4% tall, placed at \
the bottom-center crossing the blue river. Bridge.

#c8a878 — solid tan thin straight lines ~1% thick, connecting the \
brown bridge upward to the yellow circle in the center, then short \
branches from the yellow circle to the hut, drying rack, garden, \
storage. Dirt paths.

#e040a0 — three solid pink circles ~3% of image width each, placed \
together in the upper-left area of the clearing (between garden and \
center). Berry bushes.

#808080 — three solid grey circles ~3% of image width each, placed \
together in the upper-right area of the clearing. Rocks.

ABSOLUTE RULES:
- Use ONLY the 11 hex colors listed above.
- ZERO text characters anywhere.
- ZERO illustrated trees, leaves, foliage, grass blades, brick \
patterns, wood grain, water ripples.
- ZERO drop shadows or gradient fills.
- ZERO outline strokes around shapes.
- The image looks like a color-coded blueprint, like a Tetris-style \
filled-shape diagram.
- If unsure, prefer fewer solid blocks over more decoration.

Output: a clean 1024x1024 square color-block layout.
"""


def main() -> int:
    game_dir = ROOT / "godot" / "data" / GAME
    layouts_dir = game_dir / "assets" / "layouts"
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
        "fire_pit": "structure_fire_pit",
        "hut": "shelter_mud_hut",
        "drying_rack": "prop_drying_rack",
        "storage": "shelter_lean_to",
        "garden": "food_berry_bush",
        "berry_bush": "food_berry_bush",
        "rock": "prop_stone",
        "bridge": "prop_marker_stone",  # aldenmere has no bridge def; reuse stone as a placeholder marker
    }
    # Override forest scatter to use aldenmere's actual tree def
    aldenmere_zone_patterns = {
        "forest": {
            "_comment": "Trees scattered inside the forest mask region.",
            "pattern": "scatter",
            "def": "prop_tree_oak",  # aldenmere has oak/birch/dead/fruit — no pine
            "id_prefix": "forest_tree",
            "count": 50,
            "min_spacing": 1.5,
            "scale_min": 0.8,
            "scale_max": 1.4,
        },
        "grass": {},
        "water": {},
    }
    fragment = compile_layout_to_entities(
        layout_dict,
        anchor_to_def=aldenmere_anchor_map,
        zone_patterns=aldenmere_zone_patterns,
    )
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
