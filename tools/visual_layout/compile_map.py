"""compile_map.py — MapLayout schema → entities.json fragment (ADR 0054 Phase 3).

Bridges the extracted map to Yume's level/entities.json format:

    {
      "initial_instances": [...],
      "patterns": [...]
    }

Per-anchor → initial_instances entry with (position, def, optional state).
Per-zone   → patterns entry that scatters def instances inside the zone's
             world-coord polygon (approximated via grass bbox if mask not
             usable directly; future ADR can wire mask-aware scatter).
Per-path   → ignored for entities (paths are level decals/visuals, not
             entities). A future compiler pass may emit decals or
             scatter cobblestones along the polyline.

What this compiler DOESN'T do:
- Emit the full entities.json (that's content-designer's job — entity
  defs live in entities/*.json). The compiler emits the INSTANCES that
  go in level/entities.json.
- Author def-specific state overrides. The map says "this is a hut";
  it doesn't say "this hut has hp=100". The skill / LLM fills that in.
- Resolve rotation hints. The map says "hut faces fire_pit"; engine-
  side or content-designer rule sets state.facing accordingly.

Anchor name → def_id mapping is provided via the compile call. A
camp-genre default mapping (`DEFAULT_ANCHOR_TO_DEF`) covers aldenmere-
style games; per-game overrides extend or replace it.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


# ============================================================
# DEFAULT ANCHOR → DEF MAPPING
# ============================================================

# Maps legend names from map_camp_default.json to entity def_ids.
# Per-game overrides via compile_layout_to_entities(anchor_to_def=...).
DEFAULT_ANCHOR_TO_DEF: dict[str, str] = {
    "fire_pit": "prop_fire_pit",
    "hut": "prop_mud_hut",
    "drying_rack": "prop_drying_rack",
    "storage": "prop_storage_chest",
    "garden": "prop_garden_patch",
    "berry_bush": "food_berry_bush",
    "rock": "prop_stone",
    "bridge": "prop_bridge",
}

# Zone name → default scatter pattern config.
# scatter_def must be authored to live inside the zone (e.g. trees in forest).
DEFAULT_ZONE_PATTERNS: dict[str, dict] = {
    "forest": {
        "_comment": "Trees scattered inside the forest mask region.",
        "pattern": "scatter",
        "def": "prop_tree_pine",       # per-game override likely
        "id_prefix": "forest_tree",
        "count": 50,                    # scaled by zone area downstream
        "min_spacing": 1.5,
        "scale_min": 0.8,
        "scale_max": 1.4,
    },
    "grass": {},                        # explicit no-pattern; grass is ground
    "water": {},                        # water is rendered as ground shader
}


# ============================================================
# COMPILER
# ============================================================


def compile_layout_to_entities(
    layout: dict,
    anchor_to_def: dict[str, str] | None = None,
    zone_patterns: dict[str, dict] | None = None,
) -> dict:
    """Compile a MapLayout dict into a fragment suitable for splicing
    into a level's entities.json.

    Args:
        layout:         MapLayout dict (from extract_map.layout_to_dict).
        anchor_to_def:  per-game override of DEFAULT_ANCHOR_TO_DEF.
        zone_patterns:  per-game override of DEFAULT_ZONE_PATTERNS.

    Returns:
        {
          "_layout_source": "<image path>",
          "_legend_used":   "<legend name>",
          "initial_instances": [...],
          "patterns": [...]
        }

    The output is a FRAGMENT — append-merge into level/entities.json's
    existing initial_instances + patterns arrays, or use as the
    foundation if authoring fresh.
    """
    a2d = dict(DEFAULT_ANCHOR_TO_DEF)
    if anchor_to_def:
        a2d.update(anchor_to_def)
    zp = dict(DEFAULT_ZONE_PATTERNS)
    if zone_patterns:
        zp.update(zone_patterns)

    instances: list[dict] = []
    for i, anchor in enumerate(layout.get("anchors", [])):
        name = anchor["name"]
        def_id = a2d.get(name)
        if def_id is None:
            # Skip — caller didn't map this anchor name.
            continue
        wx, wz = anchor["world_pos"]
        inst: dict = {
            "_comment": f"Auto-generated from visual_layout extraction ({name}).",
            "_source_anchor": name,
            "def": def_id,
            "id": f"{name}_{i:02d}",
            "position": [round(wx, 2), 0.0, round(wz, 2)],
        }
        # If extractor surfaced a rotation hint, attach it to state
        # for downstream rule resolution.
        hint = anchor.get("rotation_hint", "")
        if hint:
            inst["state"] = {"_rotation_hint": hint}
        instances.append(inst)

    patterns: list[dict] = []
    for zone in layout.get("zones", []):
        name = zone["name"]
        cfg = zp.get(name)
        if not cfg:
            continue
        pat = dict(cfg)
        pat["_source_zone"] = name
        # Scatter count scales linearly with zone area (per m²) so larger
        # forests get more trees naturally.
        # Base: ~0.3 entities/m² for trees in forest (≈3m spacing × jitter)
        if "count" in pat and zone.get("area_world", 0) > 0:
            density = float(pat.get("_density_per_m2", 0.30))
            pat["count"] = max(int(zone["area_world"] * density), 8)
            pat.pop("_density_per_m2", None)
        patterns.append(pat)

    return {
        "_comment": (
            "Generated by tools/visual_layout/compile_map.py from a "
            "semantic map image (ADR 0054). Each instance has "
            "_source_anchor pointing back at the legend entry. Author "
            "refines def overrides + state per game intent. Patterns are "
            "scaled by zone area; tune `_density_per_m2` per-pattern as "
            "needed."
        ),
        "_layout_source": layout.get("image_path", "unknown"),
        "_legend_used": layout.get("legend_name", "unknown"),
        "initial_instances": instances,
        "patterns": patterns,
    }


# ============================================================
# CLI
# ============================================================


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="compile_map")
    ap.add_argument("--layout", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--anchor-map", type=Path, default=None,
                    help="Optional JSON file mapping legend names → def_ids.")
    args = ap.parse_args(argv)

    layout = json.loads(args.layout.read_text(encoding="utf-8"))
    a2d = None
    if args.anchor_map and args.anchor_map.exists():
        a2d = json.loads(args.anchor_map.read_text(encoding="utf-8"))

    fragment = compile_layout_to_entities(layout, anchor_to_def=a2d)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(fragment, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        f"[compile_map] {len(fragment['initial_instances'])} instances + "
        f"{len(fragment['patterns'])} patterns → {args.output}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
