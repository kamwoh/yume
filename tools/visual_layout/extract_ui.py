"""extract_ui.py — UI wireframe → rect schema (ADR 0054 Phase 1).

Pipeline:
    load wireframe image
    → extractor_common.extract_components_from_image
    → per-component:
        - centroid + bbox
        - classify into 9-anchor grid (3×3 zones of screen)
        - infer width / height (in screen-relative units OR pixels)
        - emit UIComponent dataclass
    → top-level UILayout (screen size + list[UIComponent])

The anchor-classification step is what makes UI extraction tractable:
Yume's HUD positions panels via 9 named anchors (top-left, top-center,
top-right, center-left, center, center-right, bottom-left, bottom-center,
bottom-right). Each panel has width/height/offsets, but the absolute
position emerges from anchor + offset, not a raw pixel rect. So we
just need to know "which 9-zone is this rect's centroid in?" + the
rect's size.

This is much easier than pixel-perfect extraction. Off-by-a-few-pixels
errors at the image level become zero error at the anchor level.

Usage:
    python3 -m tools.visual_layout.extract_ui --image wireframe.png \\
        --legend tools/visual_layout/legends/ui_default.json \\
        --output extracted.layout.json
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.visual_layout.extractor_common import (  # noqa: E402
    Legend,
    extract_components_from_image,
    load_image,
)


# ============================================================
# DATA TYPES
# ============================================================


@dataclass
class UIComponent:
    """One extracted UI panel."""

    name: str  # legend entry name
    anchor: str  # one of 9 anchor names
    bbox_px: tuple[int, int, int, int]  # (x, y, w, h) in image coords
    centroid_px: tuple[float, float]
    width_pct: float  # bbox width as fraction of image width
    height_pct: float  # bbox height as fraction of image height
    confidence: float = 1.0


@dataclass
class UILayout:
    """Result of extracting a UI wireframe."""

    image_path: str
    image_size_px: tuple[int, int]  # (W, H)
    legend_name: str
    components: list[UIComponent] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


# ============================================================
# 9-ANCHOR CLASSIFICATION
# ============================================================


ANCHOR_NAMES = (
    "top-left",   "top-center",   "top-right",
    "center-left", "center",      "center-right",
    "bottom-left", "bottom-center", "bottom-right",
)


def classify_anchor(
    centroid_px: tuple[float, float],
    image_size_px: tuple[int, int],
) -> str:
    """Map a centroid pixel coord to one of 9 anchor names.

    The image is divided into a 3×3 grid. Each anchor occupies one cell.
    Boundary thirds at 1/3 and 2/3 of each axis.

    Args:
        centroid_px:    (cx, cy) — image coords, y-down.
        image_size_px:  (W, H).

    Returns:
        anchor name string.
    """
    cx, cy = centroid_px
    w, h = image_size_px
    # X classification
    if cx < w / 3.0:
        x_zone = "left"
    elif cx < 2.0 * w / 3.0:
        x_zone = "center"
    else:
        x_zone = "right"
    # Y classification
    if cy < h / 3.0:
        y_zone = "top"
    elif cy < 2.0 * h / 3.0:
        y_zone = "center"
    else:
        y_zone = "bottom"
    # Combine. "center-center" → "center"
    if y_zone == "center" and x_zone == "center":
        return "center"
    if y_zone == "center":
        return f"center-{x_zone}"
    return f"{y_zone}-{x_zone}"


# ============================================================
# EXTRACTION
# ============================================================


def extract_ui_layout(
    image_path: Path,
    legend: Legend,
    *,
    skip_legend_names: tuple[str, ...] = ("background",),
    random_state: int = 42,
) -> UILayout:
    """Extract a UI wireframe image into a UILayout schema.

    Args:
        image_path:        path to the wireframe PNG.
        legend:            UI legend.
        skip_legend_names: legend entries to ignore (e.g. background).
        random_state:      kmeans seed for determinism.

    Returns:
        UILayout with one UIComponent per detected non-background component.
        Components with multiple connected sub-regions emit one per region.
    """
    img = load_image(image_path)
    h, w = img.shape[:2]
    comps_by_name, _ = extract_components_from_image(
        img, legend, random_state=random_state
    )
    layout = UILayout(
        image_path=str(image_path),
        image_size_px=(w, h),
        legend_name=legend.name,
    )
    for legend_name, comps in comps_by_name.items():
        if legend_name in skip_legend_names:
            continue
        if not comps:
            # Note: extractor doesn't know which entries are required.
            # The validator (validate_layout.py) reads the legend's
            # expected_count to decide whether a missing component
            # is a FAIL (required) or a WARN (optional).
            layout.warnings.append(f"missing_component: {legend_name}")
            continue
        for comp in comps:
            bx, by, bw, bh = comp.bbox_xywh
            anchor = classify_anchor(comp.centroid_px, (w, h))
            ui_comp = UIComponent(
                name=legend_name,
                anchor=anchor,
                bbox_px=(bx, by, bw, bh),
                centroid_px=comp.centroid_px,
                width_pct=bw / w,
                height_pct=bh / h,
                confidence=1.0,  # placeholder; refine with shape-match later
            )
            layout.components.append(ui_comp)
    return layout


# ============================================================
# SERIALIZATION
# ============================================================


def layout_to_dict(layout: UILayout) -> dict:
    """Convert UILayout to JSON-serializable dict.

    UIComponent.bbox_px / centroid_px tuples are converted to lists
    so json.dumps emits them as JSON arrays.
    """
    return {
        "image_path": layout.image_path,
        "image_size_px": list(layout.image_size_px),
        "legend_name": layout.legend_name,
        "components": [
            {
                "name": c.name,
                "anchor": c.anchor,
                "bbox_px": list(c.bbox_px),
                "centroid_px": list(c.centroid_px),
                "width_pct": round(c.width_pct, 4),
                "height_pct": round(c.height_pct, 4),
                "confidence": round(c.confidence, 3),
            }
            for c in layout.components
        ],
        "warnings": list(layout.warnings),
    }


def save_layout(layout: UILayout, path: Path) -> None:
    """Save a UILayout to .layout.json."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(layout_to_dict(layout), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


# ============================================================
# CLI
# ============================================================


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="extract_ui")
    ap.add_argument("--image", required=True, type=Path)
    ap.add_argument("--legend", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    args = ap.parse_args(argv)

    legend = Legend.from_file(args.legend)
    layout = extract_ui_layout(args.image, legend)
    save_layout(layout, args.output)
    print(f"[extract_ui] {len(layout.components)} components → {args.output}")
    if layout.warnings:
        print(f"  warnings: {layout.warnings}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
