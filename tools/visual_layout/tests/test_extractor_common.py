"""test_extractor_common.py — synthetic-input tests for ADR 0054 Phase 0.

Covers the foundation primitives:
    quantize
    match_centroids_to_legend
    masks_by_legend_name
    connected_components
    morphological_clean
    extract_components_from_image (facade)

Synthetic input only (np arrays painted programmatically). No image
files, no API calls. Deterministic via fixed random_state.

Usage:
    python3 -m tools.visual_layout.tests.test_extractor_common
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from tools.visual_layout.extractor_common import (  # noqa: E402
    Component,
    Legend,
    LegendEntry,
    connected_components,
    extract_components_from_image,
    masks_by_legend_name,
    match_centroids_to_legend,
    morphological_clean,
    quantize,
)

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
# SYNTHETIC INPUT BUILDERS
# ============================================================


def _three_color_grid(size: int = 64) -> np.ndarray:
    """Build a HxWx3 image with three solid color regions:
    - top half: red
    - bottom-left quadrant: green
    - bottom-right quadrant: blue
    Easy ground truth for tests.
    """
    img = np.zeros((size, size, 3), dtype=np.uint8)
    half = size // 2
    img[:half, :] = (200, 30, 30)         # red
    img[half:, :half] = (30, 180, 60)     # green
    img[half:, half:] = (30, 40, 200)     # blue
    return img


def _legend_three_colors() -> Legend:
    return Legend(
        name="test_three",
        entries=[
            LegendEntry(name="red_zone", hex="#c81e1e"),     # ~ (200, 30, 30)
            LegendEntry(name="green_zone", hex="#1eb43c"),   # ~ (30, 180, 60)
            LegendEntry(name="blue_zone", hex="#1e28c8"),    # ~ (30, 40, 200)
        ],
    )


def _two_huts_image(size: int = 80) -> np.ndarray:
    """Image with green background + 2 brown 'hut' squares spaced apart.
    Used to test connected_components correctly finding two distinct
    components."""
    img = np.zeros((size, size, 3), dtype=np.uint8)
    img[:] = (60, 150, 80)  # green grass
    img[10:25, 10:25] = (140, 80, 40)  # brown hut 1
    img[55:70, 55:70] = (140, 80, 40)  # brown hut 2
    return img


def _drifted_red_image(size: int = 32, hue_drift: int = 25) -> np.ndarray:
    """Image where ALL pixels are 'red' but slightly different shades —
    tests k-means' robustness to color drift within a single legend entry.
    """
    img = np.zeros((size, size, 3), dtype=np.uint8)
    # Half image at "perfect" red, half at drifted red
    img[:, : size // 2] = (200, 30, 30)
    img[:, size // 2 :] = (200 - hue_drift, 30 + hue_drift, 30)
    return img


# ============================================================
# TEST CASES
# ============================================================


def test_quantize_basic() -> None:
    print("\n[1] quantize: 3-color image → 3 distinct centroids")
    img = _three_color_grid(64)
    labels, centroids = quantize(img, k=3, random_state=42)
    _check(labels.shape == (64, 64), "labels shape matches image", str(labels.shape))
    _check(centroids.shape == (3, 3), "centroids shape Kx3", str(centroids.shape))
    # All k=3 cluster ids must be used
    unique = set(np.unique(labels).tolist())
    _check(unique == {0, 1, 2}, "all 3 cluster ids assigned", str(unique))


def test_quantize_handles_drift() -> None:
    print("\n[2] quantize: drifted-red image → centroids cluster near red")
    img = _drifted_red_image(32, hue_drift=25)
    labels, centroids = quantize(img, k=2, random_state=42)
    # Both centroids should be in the "red" region of color space
    # (R > 150, G+B < 150) — they cluster the drift
    for c in centroids:
        is_red_zone = c[0] > 150 and (c[1] + c[2]) < 200
        _check(is_red_zone, f"centroid {c.astype(int)} is in red color region")


def test_match_centroids_to_legend() -> None:
    print("\n[3] match_centroids_to_legend: centroids snap to nearest legend entry")
    legend = _legend_three_colors()
    centroids = np.array(
        [
            [200, 30, 30],   # → red_zone
            [30, 180, 60],   # → green_zone
            [30, 40, 200],   # → blue_zone
        ],
        dtype=np.float64,
    )
    matches = match_centroids_to_legend(centroids, legend)
    _check(matches[0] == "red_zone", f"centroid 0 → red_zone (got {matches[0]})")
    _check(matches[1] == "green_zone", f"centroid 1 → green_zone (got {matches[1]})")
    _check(matches[2] == "blue_zone", f"centroid 2 → blue_zone (got {matches[2]})")


def test_match_drift_tolerance() -> None:
    print("\n[4] match_centroids_to_legend: small drift still matches nearest legend")
    legend = _legend_three_colors()
    # Slight drift from each legend entry — should still match
    centroids = np.array(
        [
            [180, 50, 50],   # close to red
            [60, 160, 80],   # close to green
            [50, 60, 180],   # close to blue
        ],
        dtype=np.float64,
    )
    matches = match_centroids_to_legend(centroids, legend, max_lab_distance=35.0)
    _check(matches[0] == "red_zone", f"drifted red still → red_zone (got {matches[0]})")
    _check(matches[1] == "green_zone", f"drifted green still → green_zone (got {matches[1]})")
    _check(matches[2] == "blue_zone", f"drifted blue still → blue_zone (got {matches[2]})")


def test_match_unmatched_distant() -> None:
    print("\n[5] match_centroids_to_legend: far centroid → None (unmatched)")
    legend = _legend_three_colors()
    centroids = np.array(
        [
            [128, 128, 128],  # grey — far from any of red/green/blue
        ],
        dtype=np.float64,
    )
    matches = match_centroids_to_legend(centroids, legend, max_lab_distance=20.0)
    _check(matches[0] is None, f"grey → None at tight threshold (got {matches[0]})")
    # At looser threshold should still match SOMETHING
    matches_loose = match_centroids_to_legend(centroids, legend, max_lab_distance=100.0)
    _check(matches_loose[0] is not None, "grey → some legend entry at loose threshold")


def test_masks_by_legend_name() -> None:
    print("\n[6] masks_by_legend_name: labels → per-name bool masks")
    # Synthetic labels: 8x8 quadrants of cluster 0, 1, 2, 3
    labels = np.zeros((8, 8), dtype=np.int32)
    labels[:4, :4] = 0
    labels[:4, 4:] = 1
    labels[4:, :4] = 2
    labels[4:, 4:] = 3
    centroid_map = {0: "A", 1: "B", 2: "A", 3: None}  # 0+2 both → A
    masks = masks_by_legend_name(labels, centroid_map, ["A", "B", "C"])
    _check("A" in masks and "B" in masks and "C" in masks, "all requested names returned")
    _check(int(masks["A"].sum()) == 32, f"mask A covers cluster 0+2 (got {masks['A'].sum()}, expected 32)")
    _check(int(masks["B"].sum()) == 16, f"mask B covers cluster 1 (got {masks['B'].sum()}, expected 16)")
    _check(int(masks["C"].sum()) == 0, "mask C empty (no centroid matched)")


def test_connected_components_two_huts() -> None:
    print("\n[7] connected_components: two-huts image → 2 components")
    img = _two_huts_image(80)
    # Hand-build a "brown" mask
    mask = (
        (img[:, :, 0] > 120)
        & (img[:, :, 0] < 160)
        & (img[:, :, 1] > 60)
        & (img[:, :, 1] < 100)
    )
    comps = connected_components(mask, label="hut", min_area_px=10)
    _check(len(comps) == 2, f"found 2 huts (got {len(comps)})")
    if len(comps) >= 2:
        _check(comps[0].area_px == comps[1].area_px == 225, f"each hut 15x15=225 px (got {comps[0].area_px} {comps[1].area_px})")
        # Centroids: hut 1 center is (17, 17), hut 2 center is (62, 62)
        # cv2 reports centroid as (x_mean, y_mean) where for [10:25, 10:25] (15x15)
        # the center is at (17, 17) (or close)
        cx1, cy1 = comps[1].centroid_px  # smallest by sort order — could be either
        cx0, cy0 = comps[0].centroid_px
        # Sort by area same → order may swap; check by sum invariant
        sum_x = cx0 + cx1
        sum_y = cy0 + cy1
        _check(abs(sum_x - 79) < 2, f"sum of centroid x ≈ 17+62=79 (got {sum_x:.1f})")
        _check(abs(sum_y - 79) < 2, f"sum of centroid y ≈ 17+62=79 (got {sum_y:.1f})")


def test_connected_components_filter_noise() -> None:
    print("\n[8] connected_components: min_area_px filters noise")
    mask = np.zeros((20, 20), dtype=bool)
    mask[2:5, 2:5] = True   # 9 px — small
    mask[10:18, 10:18] = True  # 64 px — large
    comps_strict = connected_components(mask, label="x", min_area_px=20)
    _check(len(comps_strict) == 1, f"with min=20 → 1 component (got {len(comps_strict)})")
    comps_loose = connected_components(mask, label="x", min_area_px=5)
    _check(len(comps_loose) == 2, f"with min=5 → 2 components (got {len(comps_loose)})")


def test_morphological_clean_removes_noise() -> None:
    print("\n[9] morphological_clean (open): removes small noise")
    mask = np.zeros((40, 40), dtype=bool)
    mask[10:30, 10:30] = True  # 20x20 solid block
    mask[1:3, 1:3] = True       # 2x2 noise speck
    cleaned = morphological_clean(mask, op="open", kernel_size=3)
    # The big block should survive; the speck shouldn't
    _check(cleaned[20, 20], "center of big block still True after open")
    _check(not cleaned[1, 1], "noise speck removed after open")


def test_facade_three_color_image() -> None:
    print("\n[10] extract_components_from_image: end-to-end on 3-color grid")
    img = _three_color_grid(64)
    legend = _legend_three_colors()
    comps_by_name, masks_by_name = extract_components_from_image(
        img, legend, random_state=42
    )
    _check(set(comps_by_name.keys()) == {"red_zone", "green_zone", "blue_zone"},
           "all 3 legend names present in output")
    _check(len(comps_by_name["red_zone"]) >= 1, "red_zone has ≥1 component")
    _check(len(comps_by_name["green_zone"]) >= 1, "green_zone has ≥1 component")
    _check(len(comps_by_name["blue_zone"]) >= 1, "blue_zone has ≥1 component")
    # Mask areas should sum near image total (some loss from morph open)
    total_pixels = 64 * 64
    masked_total = sum(int(m.sum()) for m in masks_by_name.values())
    _check(
        masked_total > 0.85 * total_pixels,
        f"masked area covers ≥85% of image ({masked_total}/{total_pixels})",
    )


def test_facade_two_huts() -> None:
    print("\n[11] extract_components_from_image: two-huts image → 2 hut components")
    img = _two_huts_image(80)
    legend = Legend(
        name="test_two_huts",
        entries=[
            LegendEntry(name="grass", hex="#3c9650"),    # ~ (60, 150, 80)
            LegendEntry(name="hut", hex="#8c5028"),      # ~ (140, 80, 40)
        ],
        expected_clusters=4,  # +2 buffer
    )
    comps_by_name, _ = extract_components_from_image(
        img, legend, random_state=42, morph_kernel=3
    )
    _check(len(comps_by_name["hut"]) == 2,
           f"facade finds 2 huts (got {len(comps_by_name['hut'])})")
    _check(len(comps_by_name["grass"]) >= 1, "grass present as background component")


# ============================================================
# MAIN
# ============================================================


def main() -> int:
    test_quantize_basic()
    test_quantize_handles_drift()
    test_match_centroids_to_legend()
    test_match_drift_tolerance()
    test_match_unmatched_distant()
    test_masks_by_legend_name()
    test_connected_components_two_huts()
    test_connected_components_filter_noise()
    test_morphological_clean_removes_noise()
    test_facade_three_color_image()
    test_facade_two_huts()
    total = _PASS + _FAIL
    print(f"\npassed: {_PASS}  failed: {_FAIL}  total: {total}")
    return 0 if _FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
