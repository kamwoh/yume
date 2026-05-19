"""test_ui_pipeline.py — extract_ui + compile_ui tests (ADR 0054 Phase 1).

Synthetic wireframe images painted programmatically. Each test verifies
one end-to-end behavior:
- Anchor classification (centroid → 9-zone)
- Component count extraction
- Width/height pct calculation
- Compilation to hud.json shape
- Validator catches expected failure classes

Usage:
    python3 -m tools.visual_layout.tests.test_ui_pipeline
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from tools.visual_layout.compile_ui import compile_layout_to_hud  # noqa: E402
from tools.visual_layout.extract_ui import (  # noqa: E402
    classify_anchor,
    extract_ui_layout,
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
# ANCHOR CLASSIFICATION (no I/O — pure function)
# ============================================================


def test_anchor_classification_corners() -> None:
    print("\n[1] classify_anchor: 9-zone grid corners + center")
    size = (300, 300)
    cases = [
        ((50, 50), "top-left"),
        ((150, 50), "top-center"),
        ((250, 50), "top-right"),
        ((50, 150), "center-left"),
        ((150, 150), "center"),
        ((250, 150), "center-right"),
        ((50, 250), "bottom-left"),
        ((150, 250), "bottom-center"),
        ((250, 250), "bottom-right"),
    ]
    for centroid, expected in cases:
        got = classify_anchor(centroid, size)
        _check(got == expected, f"centroid {centroid} → {expected} (got {got})")


def test_anchor_boundary() -> None:
    print("\n[2] classify_anchor: boundary cases")
    size = (300, 300)
    # On the 1/3 boundary (x=100) — strict less-than puts at center
    got = classify_anchor((100, 50), size)
    _check(got == "top-center", f"x=100 on boundary → top-center (got {got})")
    # Just under 1/3 (x=99) → top-left
    got = classify_anchor((99, 50), size)
    _check(got == "top-left", f"x=99 → top-left (got {got})")


# ============================================================
# END-TO-END WIREFRAME EXTRACTION
# ============================================================


def _build_4_rect_wireframe(size: int = 256) -> np.ndarray:
    """Paint a synthetic wireframe with 4 rects at 4 corners:
    - top-left: cool light-blue (day_time_panel)
    - top-right: bright green (minimap)
    - bottom-left: salmon pink (vitals_panel)
    - bottom-center: warm brown (hotbar)
    + dark grey background.
    """
    img = np.full((size, size, 3), (26, 26, 26), dtype=np.uint8)  # bg
    # top-left day_time @ ~(40, 40), 60x40
    img[24:64, 24:84] = (160, 192, 224)  # ≈ #a0c0e0
    # top-right minimap @ ~(size-50, 40), 60x60
    img[20:80, size - 80 : size - 20] = (96, 192, 96)  # ≈ #60c060
    # bottom-left vitals @ ~(40, size-50), 60x50
    img[size - 80 : size - 30, 24:84] = (224, 128, 128)  # ≈ #e08080
    # bottom-center hotbar @ ~(size/2, size-30), 100x30
    img[size - 50 : size - 20, (size - 100) // 2 : (size + 100) // 2] = (
        192, 160, 96
    )  # ≈ #c0a060
    return img


def _ui_legend_minimal() -> Legend:
    return Legend(
        name="test_ui_minimal",
        entries=[
            LegendEntry(name="background", hex="#1a1a1a", min_area_px=1000),
            LegendEntry(name="day_time_panel", hex="#a0c0e0", min_area_px=200),
            LegendEntry(name="minimap", hex="#60c060", min_area_px=400),
            LegendEntry(name="vitals_panel", hex="#e08080", min_area_px=300),
            LegendEntry(name="hotbar", hex="#c0a060", min_area_px=300),
        ],
        expected_clusters=6,
    )


def test_extract_4_rect_wireframe() -> None:
    print("\n[3] extract_ui_layout: 4-rect wireframe → 4 components in 4 anchors")
    img = _build_4_rect_wireframe(256)
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        import cv2
        cv2.imwrite(f.name, cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
        tmp_path = Path(f.name)
    try:
        legend = _ui_legend_minimal()
        layout = extract_ui_layout(tmp_path, legend, random_state=42)
        _check(
            len(layout.components) == 4,
            f"found 4 components (got {len(layout.components)})",
        )
        anchors_seen = {c.anchor for c in layout.components}
        expected_anchors = {"top-left", "top-right", "bottom-left", "bottom-center"}
        _check(
            anchors_seen == expected_anchors,
            f"each in a distinct expected anchor "
            f"(got {anchors_seen}, expected {expected_anchors})",
        )
        # Verify name→anchor mapping
        name_to_anchor = {c.name: c.anchor for c in layout.components}
        _check(
            name_to_anchor.get("day_time_panel") == "top-left",
            f"day_time_panel → top-left (got {name_to_anchor.get('day_time_panel')})",
        )
        _check(
            name_to_anchor.get("minimap") == "top-right",
            f"minimap → top-right (got {name_to_anchor.get('minimap')})",
        )
        _check(
            name_to_anchor.get("vitals_panel") == "bottom-left",
            f"vitals_panel → bottom-left (got {name_to_anchor.get('vitals_panel')})",
        )
        _check(
            name_to_anchor.get("hotbar") == "bottom-center",
            f"hotbar → bottom-center (got {name_to_anchor.get('hotbar')})",
        )
    finally:
        tmp_path.unlink(missing_ok=True)


def test_extract_missing_component_warns() -> None:
    print("\n[4] extract_ui_layout: missing component → warning")
    img = _build_4_rect_wireframe(256)
    # Use a legend that expects MORE than what's in the image
    legend = Legend(
        name="test_ui_with_extra",
        entries=[
            LegendEntry(name="background", hex="#1a1a1a"),
            LegendEntry(name="day_time_panel", hex="#a0c0e0"),
            LegendEntry(name="minimap", hex="#60c060"),
            LegendEntry(name="vitals_panel", hex="#e08080"),
            LegendEntry(name="hotbar", hex="#c0a060"),
            LegendEntry(name="objective_text", hex="#f0e0a0"),  # NOT in image
            LegendEntry(name="controls_hint", hex="#808080"),    # NOT in image
        ],
        expected_clusters=8,
    )
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        import cv2
        cv2.imwrite(f.name, cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
        tmp_path = Path(f.name)
    try:
        layout = extract_ui_layout(tmp_path, legend, random_state=42)
        missing_warnings = [
            w for w in layout.warnings if "missing_required_component" in w
        ]
        _check(
            len(missing_warnings) >= 2,
            f"warns on missing components (got {len(missing_warnings)} warnings: "
            f"{missing_warnings})",
        )
    finally:
        tmp_path.unlink(missing_ok=True)


# ============================================================
# COMPILE TO HUD.JSON
# ============================================================


def test_compile_layout_to_hud() -> None:
    print("\n[5] compile_layout_to_hud: 4-component layout → 4-panel hud.json")
    layout_dict = {
        "image_path": "synthetic.png",
        "image_size_px": [256, 256],
        "legend_name": "test_ui_minimal",
        "components": [
            {
                "name": "day_time_panel", "anchor": "top-left",
                "bbox_px": [24, 24, 60, 40], "centroid_px": [54, 44],
                "width_pct": 0.234, "height_pct": 0.156, "confidence": 1.0
            },
            {
                "name": "minimap", "anchor": "top-right",
                "bbox_px": [176, 20, 60, 60], "centroid_px": [206, 50],
                "width_pct": 0.234, "height_pct": 0.234, "confidence": 1.0
            },
            {
                "name": "vitals_panel", "anchor": "bottom-left",
                "bbox_px": [24, 176, 60, 50], "centroid_px": [54, 201],
                "width_pct": 0.234, "height_pct": 0.195, "confidence": 1.0
            },
            {
                "name": "hotbar", "anchor": "bottom-center",
                "bbox_px": [78, 206, 100, 30], "centroid_px": [128, 221],
                "width_pct": 0.391, "height_pct": 0.117, "confidence": 1.0
            },
        ],
        "warnings": [],
    }
    hud = compile_layout_to_hud(layout_dict, target_screen_size=(1280, 720))
    _check("panels" in hud, "hud.json has 'panels' key")
    _check(len(hud["panels"]) == 4, f"4 panels in output (got {len(hud['panels'])})")
    anchors = {p["anchor"] for p in hud["panels"]}
    _check(
        anchors == {"top-left", "top-right", "bottom-left", "bottom-center"},
        f"anchors preserved through compile (got {anchors})",
    )
    # Width should scale: minimap width_pct 0.234 × 1280 = ~300
    minimap_panel = next(p for p in hud["panels"] if p["_source_component"] == "minimap")
    _check(
        minimap_panel["width"] >= 100,
        f"minimap width plausible (got {minimap_panel['width']})",
    )
    # Default elements populated
    _check(
        len(minimap_panel["elements"]) > 0,
        "minimap panel has default elements",
    )


# ============================================================
# VALIDATOR
# ============================================================


def test_validator_catches_overlap() -> None:
    print("\n[6] validate_layout: detects rect overlap")
    # Two rects overlapping by >10%
    layout_dict = {
        "image_path": "test.png",
        "image_size_px": [200, 200],
        "legend_name": "test",
        "components": [
            {
                "name": "A", "anchor": "top-left",
                "bbox_px": [10, 10, 50, 50], "centroid_px": [35, 35],
                "width_pct": 0.25, "height_pct": 0.25,
            },
            {
                "name": "B", "anchor": "top-left",
                "bbox_px": [30, 30, 50, 50], "centroid_px": [55, 55],
                "width_pct": 0.25, "height_pct": 0.25,
            },
        ],
        "warnings": [],
    }
    with tempfile.NamedTemporaryFile(suffix=".layout.json", delete=False, mode="w") as f:
        json.dump(layout_dict, f)
        tmp_path = Path(f.name)
    try:
        sys.path.insert(0, str(ROOT / "tools" / "validators"))
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "validate_layout", ROOT / "tools" / "validators" / "validate_layout.py"
        )
        validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(validator)
        fails, warns = validator.check_layout(tmp_path, None)
        overlap_fails = [f for f in fails if "overlap" in f]
        _check(len(overlap_fails) >= 1, f"overlap detected (fails: {fails})")
    finally:
        tmp_path.unlink(missing_ok=True)


def test_validator_passes_clean_layout() -> None:
    print("\n[7] validate_layout: clean 4-corner layout passes")
    layout_dict = {
        "image_path": "test.png",
        "image_size_px": [400, 400],
        "legend_name": "test",
        "components": [
            {"name": "A", "anchor": "top-left", "bbox_px": [20, 20, 80, 60],
             "centroid_px": [60, 50], "width_pct": 0.2, "height_pct": 0.15},
            {"name": "B", "anchor": "top-right", "bbox_px": [300, 20, 80, 60],
             "centroid_px": [340, 50], "width_pct": 0.2, "height_pct": 0.15},
            {"name": "C", "anchor": "bottom-left", "bbox_px": [20, 320, 80, 60],
             "centroid_px": [60, 350], "width_pct": 0.2, "height_pct": 0.15},
            {"name": "D", "anchor": "bottom-right", "bbox_px": [300, 320, 80, 60],
             "centroid_px": [340, 350], "width_pct": 0.2, "height_pct": 0.15},
        ],
        "warnings": [],
    }
    with tempfile.NamedTemporaryFile(suffix=".layout.json", delete=False, mode="w") as f:
        json.dump(layout_dict, f)
        tmp_path = Path(f.name)
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "validate_layout", ROOT / "tools" / "validators" / "validate_layout.py"
        )
        validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(validator)
        fails, warns = validator.check_layout(tmp_path, None)
        _check(len(fails) == 0, f"no fails on clean layout (got {fails})")
    finally:
        tmp_path.unlink(missing_ok=True)


# ============================================================
# SERIALIZATION ROUND TRIP
# ============================================================


def test_layout_to_dict_serialization() -> None:
    print("\n[8] layout_to_dict: round-trip preserves field shapes")
    from tools.visual_layout.extract_ui import UIComponent, UILayout
    layout = UILayout(
        image_path="x.png",
        image_size_px=(100, 100),
        legend_name="test",
        components=[
            UIComponent(
                name="foo", anchor="top-left",
                bbox_px=(1, 2, 3, 4), centroid_px=(2.5, 4.0),
                width_pct=0.03, height_pct=0.04, confidence=1.0,
            )
        ],
        warnings=[],
    )
    d = layout_to_dict(layout)
    _check(isinstance(d["components"][0]["bbox_px"], list), "bbox_px serialized as list")
    _check(d["components"][0]["bbox_px"] == [1, 2, 3, 4], "bbox values preserved")
    _check(d["components"][0]["centroid_px"] == [2.5, 4.0], "centroid values preserved")
    # JSON-encodable
    try:
        json.dumps(d)
        _check(True, "layout dict is JSON-serializable")
    except Exception as e:
        _check(False, "layout dict is JSON-serializable", str(e))


# ============================================================
# MAIN
# ============================================================


def main() -> int:
    test_anchor_classification_corners()
    test_anchor_boundary()
    test_extract_4_rect_wireframe()
    test_extract_missing_component_warns()
    test_compile_layout_to_hud()
    test_validator_catches_overlap()
    test_validator_passes_clean_layout()
    test_layout_to_dict_serialization()
    total = _PASS + _FAIL
    print(f"\npassed: {_PASS}  failed: {_FAIL}  total: {total}")
    return 0 if _FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
