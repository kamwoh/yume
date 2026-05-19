"""compile_ui.py — UILayout schema → hud.json (ADR 0054 Phase 1).

Bridges the extracted layout to Yume's canonical HUD format. Per the
post-review schema positioning: this compiler outputs directly into
hud.json; the intermediate .layout.json is kept only for debugging.

Yume hud.json schema (engine-authoritative):
{
  "panels": [
    {
      "anchor": "top-left",
      "width": 200,
      "height": 80,
      "x_offset": 20,
      "y_offset": 12,
      "elements": [...]
    },
    ...
  ]
}

Each UIComponent → one panel.

What the compiler does NOT do:
- Author the `elements` array. That's the role of the
  yume-hud-layout skill — the wireframe tells us WHERE the panel
  goes, but the LLM still authors WHAT it contains (label bindings,
  bar colors, format strings).
- Pixel-perfect width / height — Yume HUDs scale to the viewport.
  Width / height in hud.json is a HINT, not a contract. The
  compiler converts width_pct + a target screen size into
  reasonable defaults.

Usage (standalone):
    python3 -m tools.visual_layout.compile_ui \\
        --layout extracted.layout.json --output hud.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


# ============================================================
# DEFAULT ELEMENT TEMPLATES
# ============================================================

# Per-component-name defaults for the elements array. These produce a
# SKELETON HUD that runs without errors; the skill then refines them
# with game-specific bindings (e.g. world_clock.current_objective).
# Keys match `name` from ui_default.json's legend entries.

DEFAULT_ELEMENTS_BY_NAME: dict[str, list[dict]] = {
    "objective_text": [
        {
            "type": "label",
            "binds": "world_clock.current_objective",
            "format": "{}",
            "size": 18,
            "color": "#f0e0a0",
            "bold": True,
        }
    ],
    "day_time_panel": [
        {
            "type": "label",
            "binds": "world_clock.current_day",
            "format": "Day {}",
            "size": 22,
            "color": "#e8d8a0",
            "bold": True,
        }
    ],
    "minimap": [
        {
            "type": "minimap",
            "size": [180, 180],
            "world_bounds": [-80, -80, 80, 80],
            "background": "#0a0c08",
            "border": "#605a48",
            "tag_colors": {
                "player": "#ffd040",
                "named_npc": "#ff9040",
                "tree": "#3a6a30",
            },
        }
    ],
    "vitals_panel": [
        {
            "type": "label",
            "binds": "player.state.health",
            "format": "HP {}",
            "size": 14,
            "color": "#e0a0a0",
        }
    ],
    "hotbar": [
        {
            "type": "label",
            "binds": "player.state.active_slot",
            "format": "Slot {}",
            "size": 14,
            "color": "#d8c898",
        }
    ],
    "controls_hint": [
        {
            "type": "label",
            "text": "WASD walk · Mouse look · E interact · I inventory",
            "size": 12,
            "color": "#909088",
        }
    ],
    "inventory_panel": [],
    "tooltip_or_modal": [],
}


# Per-anchor default panel dimensions (pixels). The wireframe's
# width_pct / height_pct tell us the visual share of screen but
# Yume's Control system needs concrete pixel hints. These defaults
# match aldenmere's hand-authored values.
ANCHOR_DEFAULTS: dict[str, dict] = {
    "top-left":      {"width": 200, "height": 80,  "x_offset": 20, "y_offset": 12},
    "top-center":    {"width": 600, "height": 60,  "x_offset": 0,  "y_offset": 8},
    "top-right":     {"width": 200, "height": 188, "x_offset": 20, "y_offset": 12},
    "center-left":   {"width": 200, "height": 100, "x_offset": 20, "y_offset": 0},
    "center":        {"width": 400, "height": 60,  "x_offset": 0,  "y_offset": 0},
    "center-right":  {"width": 200, "height": 100, "x_offset": 20, "y_offset": 0},
    "bottom-left":   {"width": 220, "height": 180, "x_offset": 20, "y_offset": 20},
    "bottom-center": {"width": 600, "height": 80,  "x_offset": 0,  "y_offset": 16},
    "bottom-right":  {"width": 220, "height": 80,  "x_offset": 20, "y_offset": 16},
}


def _default_panel_for(component: dict, target_screen_size: tuple[int, int]) -> dict:
    """Build a panel dict for one UIComponent."""
    sw, sh = target_screen_size
    anchor = component["anchor"]
    name = component["name"]
    anchor_def = ANCHOR_DEFAULTS.get(anchor, {})
    # Prefer the wireframe's measured size; fall back to anchor defaults.
    width = max(80, int(round(component["width_pct"] * sw)))
    height = max(40, int(round(component["height_pct"] * sh)))
    # If extracted is way smaller than the anchor default, clamp up.
    width = max(width, anchor_def.get("width", width) // 2)
    height = max(height, anchor_def.get("height", height) // 2)
    panel = {
        "_comment": f"Auto-generated from visual_layout extraction ({name}).",
        "_source_component": name,
        "anchor": anchor,
        "width": width,
        "height": height,
        "x_offset": anchor_def.get("x_offset", 0),
        "y_offset": anchor_def.get("y_offset", 0),
        "elements": DEFAULT_ELEMENTS_BY_NAME.get(name, []),
    }
    return panel


def compile_layout_to_hud(
    layout: dict,
    target_screen_size: tuple[int, int] = (1280, 720),
) -> dict:
    """Compile a UILayout dict (from extract_ui.layout_to_dict) into
    a hud.json dict ready to write to disk.

    `layout`:               UILayout serialized to dict.
    `target_screen_size`:   pixel reference for scaling width/height.
                            Yume HUD scales to viewport; this is just a
                            hint. Default (1280, 720) matches dev capture.

    Returns: hud.json dict with "panels" array.

    The compiler does NOT delete an existing hud.json. The caller
    decides whether to overwrite, merge, or save as a side-by-side
    alternative.
    """
    panels = []
    for comp in layout.get("components", []):
        panels.append(_default_panel_for(comp, target_screen_size))
    hud = {
        "_comment": (
            "Generated by tools/visual_layout/compile_ui.py from a wireframe "
            "image (ADR 0054). Each panel has _source_component pointing back "
            "at the wireframe's legend entry. Author refines `elements` with "
            "game-specific bindings; layout (anchor + width + height) comes "
            "from the wireframe."
        ),
        "_layout_source": layout.get("image_path", "unknown"),
        "_legend_used": layout.get("legend_name", "unknown"),
        "panels": panels,
    }
    return hud


# ============================================================
# CLI
# ============================================================


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="compile_ui")
    ap.add_argument("--layout", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--screen-w", type=int, default=1280)
    ap.add_argument("--screen-h", type=int, default=720)
    args = ap.parse_args(argv)

    layout = json.loads(args.layout.read_text(encoding="utf-8"))
    hud = compile_layout_to_hud(layout, (args.screen_w, args.screen_h))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(hud, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"[compile_ui] {len(hud['panels'])} panels → {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
