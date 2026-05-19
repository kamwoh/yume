"""merge_hud.py — combine compiled-layout anchors with existing
hud.json elements (ADR 0054 §S1 schema positioning).

The compile_ui pipeline produces a hud.json with EXTRACTED anchors
and SKELETON elements. The game's canonical hud.json has rich elements
(label bindings, bar configs, minimap configs, format strings) but
LLM-authored anchors. The merger combines them: per panel, swap the
canonical's anchor/width/height/offsets in to use the compiled's
EXTRACTED layout, while keeping the canonical's rich elements.

Heuristic matching:
    Each existing panel is classified by its first element's binds /
    type / text content. Classification map:

        binds contains "current_objective"          → objective_text
        binds contains "current_day" / "season"     → day_time_panel
        element type == "minimap"                   → minimap
        binds contains "health"/"hunger"/"warmth"   → vitals_panel
        binds contains "inventory" / "active_slot"  → hotbar
        text contains "WASD" / "walk"               → controls_hint
        anchor == "bottom-right" + no binds         → inventory_panel
        anchor == "center"                          → tooltip_or_modal
        unknown                                     → (leave alone)

    Each compiled panel has `_source_component` already. Matching:
    if classification matches, swap layout fields; if no match,
    LEAVE the existing panel alone (preserve user content).

Compiled panels with no matching existing panel are APPENDED to the
merged hud.json (so they show up as skeleton placeholders for the
asset-designer to refine).

Usage:
    python3 -m tools.visual_layout.merge_hud \\
        --compiled godot/data/demo_aldenmere/assets/layouts/hud_generated_10d342ee.json \\
        --existing godot/data/demo_aldenmere/hud.json \\
        --output godot/data/demo_aldenmere/hud.merged.json

    # Or write in-place + backup:
    python3 -m tools.visual_layout.merge_hud \\
        --compiled ...hud_generated_X.json \\
        --existing godot/data/demo_aldenmere/hud.json \\
        --inplace
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path


# ============================================================
# CLASSIFICATION
# ============================================================


def classify_existing_panel(panel: dict) -> str | None:
    """Return the legend-name this existing panel most likely represents,
    or None if we can't tell."""
    elements = panel.get("elements", [])
    if not isinstance(elements, list):
        return None

    # Walk the elements; first one with a strong signal wins.
    for el in elements:
        if not isinstance(el, dict):
            continue
        if el.get("type") == "minimap":
            return "minimap"
        binds = str(el.get("binds", ""))
        if not binds:
            text = str(el.get("text", "")).lower()
            if "wasd" in text or "walk" in text or "interact" in text:
                return "controls_hint"
            continue
        b = binds.lower()
        if "current_objective" in b:
            return "objective_text"
        if "current_day" in b or "season" in b or "current_hour" in b:
            return "day_time_panel"
        if any(k in b for k in ("health", "hunger", "warmth", "energy", "vitals")):
            return "vitals_panel"
        if "active_slot" in b or "inventory_slot" in b or "hotbar" in b:
            return "hotbar"

    # Anchor-based fallback for panels with no element signal.
    anchor = panel.get("anchor", "")
    if anchor == "bottom-right":
        return "inventory_panel"
    if anchor == "center":
        return "tooltip_or_modal"
    return None


# ============================================================
# MERGE
# ============================================================


# Fields the compiled layout owns. Everything else (elements,
# _comment, format-specifics) stays from existing.
LAYOUT_FIELDS = ("anchor", "width", "height", "x_offset", "y_offset", "align")


def merge_layouts(compiled: dict, existing: dict) -> dict:
    """Produce a merged hud.json dict.

    Strategy:
    1. Classify each existing panel.
    2. For each compiled panel, find matching existing by class.
    3. If matched: take compiled's LAYOUT_FIELDS, keep existing
       everything else.
    4. If no match: append the compiled panel as-is (skeleton).
    5. Existing panels with no compiled match are PRESERVED unchanged
       (so user content that the wireframe didn't include — e.g.
       conditional center mood icon — survives).

    Returns: merged dict in hud.json shape (panels[] + comments).
    """
    classified: dict[str, list[dict]] = {}  # class_name → list[panel]
    unclassified: list[dict] = []
    for ep in existing.get("panels", []):
        cls = classify_existing_panel(ep)
        if cls:
            classified.setdefault(cls, []).append(ep)
        else:
            unclassified.append(ep)

    merged_panels: list[dict] = []
    used_existing: set[int] = set()  # id(panel) of consumed entries
    summary = {"matched": [], "appended": [], "preserved": []}

    for cp in compiled.get("panels", []):
        name = cp.get("_source_component", "")
        candidates = classified.get(name, [])
        # Pick the first unused candidate.
        match = next(
            (c for c in candidates if id(c) not in used_existing),
            None,
        )
        if match is not None:
            # Build merged panel: existing as base, compiled's layout
            # fields layered in.
            merged_p = dict(match)
            for f in LAYOUT_FIELDS:
                if f in cp:
                    merged_p[f] = cp[f]
            merged_p["_layout_source"] = (
                f"compiled from {compiled.get('_layout_source', 'unknown')}"
            )
            merged_panels.append(merged_p)
            used_existing.add(id(match))
            summary["matched"].append(name)
        else:
            # No existing panel matched — append the compiled skeleton.
            merged_panels.append(dict(cp))
            summary["appended"].append(name)

    # Preserve unmatched existing panels (e.g. conditional mood icon).
    for ep in existing.get("panels", []):
        if id(ep) not in used_existing:
            merged_panels.append(ep)
            cls = classify_existing_panel(ep) or "(unclassified)"
            summary["preserved"].append(cls)

    out = dict(existing)
    out["panels"] = merged_panels
    out["_merge_summary"] = summary
    return out


# ============================================================
# CLI
# ============================================================


def main() -> int:
    ap = argparse.ArgumentParser(prog="merge_hud")
    ap.add_argument("--compiled", required=True, type=Path,
                    help="Compiled hud.json from compile_ui")
    ap.add_argument("--existing", required=True, type=Path,
                    help="Canonical hud.json with rich elements")
    ap.add_argument("--output", type=Path, default=None,
                    help="Write merged output here. Default: <existing>.merged.json")
    ap.add_argument("--inplace", action="store_true",
                    help="Overwrite --existing in place (backs up to .bak)")
    args = ap.parse_args()

    if not args.compiled.exists():
        print(f"ERROR: --compiled not found: {args.compiled}")
        return 2
    if not args.existing.exists():
        print(f"ERROR: --existing not found: {args.existing}")
        return 2

    compiled = json.loads(args.compiled.read_text(encoding="utf-8"))
    existing = json.loads(args.existing.read_text(encoding="utf-8"))

    merged = merge_layouts(compiled, existing)
    summary = merged.pop("_merge_summary")

    if args.inplace:
        backup = args.existing.with_suffix(args.existing.suffix + ".bak")
        shutil.copy(args.existing, backup)
        out_path = args.existing
        print(f"[merge_hud] backed up {args.existing.name} → {backup.name}")
    else:
        out_path = args.output or args.existing.with_suffix(".merged.json")

    out_path.write_text(
        json.dumps(merged, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print(f"[merge_hud] wrote {out_path}")
    print(f"  matched   ({len(summary['matched'])}): {summary['matched']}")
    print(f"  appended  ({len(summary['appended'])}): {summary['appended']}")
    print(f"  preserved ({len(summary['preserved'])}): {summary['preserved']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
