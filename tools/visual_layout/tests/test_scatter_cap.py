"""Regression tests for the scatter_in_mask expected_count cap +
the validate() count-overflow gate.

Empirical 2026-06-08: lanterns emitted 1220 rocks + 239 trees (1510
total) for a catalog asking ~30 — _extract_scatter sized purely by
density×area, ignoring expected_count, and validate() only WARNed on
the drift. Two defenses now: the scatter primitive caps at
expected_count × SCATTER_SPREAD_FACTOR, and validate() hard-FAILS on a
class emitting > expected × OVERFLOW_FACTOR (catching the same bug class
from any extraction method).

Run: python3 -m pytest tools/visual_layout/tests/test_scatter_cap.py
"""
import random

import numpy as np

from tools.visual_layout import lib_extract_dispatch as d
from tools.visual_layout import lib_extract_validate as val


def _scatter(expected, density=1.0):
    """Scatter 'rock' into an all-grass 100×100 px / 80×80 m scene.
    density=1/m² × 6400 m² → ~6400 density-target (way over any cap)."""
    palette = [("grass", "#00ff00"), ("rock", "#808080")]
    label_map = np.zeros((100, 100), dtype=int)  # all grass (idx 0)
    ce = {
        "name": "rock", "expected_count": expected,
        "strategy": {
            "mask_source_class": "grass",
            "scatter_density_per_m2": density,
            "rotation_rule": "no_rotation",
            "min_distance_between_meters": 0.1,
            "canonical_size_meters": [1, 1, 1],
        },
    }
    return d._extract_scatter(
        name="rock", class_entry=ce, label_map=label_map, palette=palette,
        image_size=(100, 100), world_size_m=(80.0, 80.0),
        sampler=None, anchors={}, rng=random.Random(42),
    )


def test_scatter_caps_at_expected_count():
    n = len(_scatter(expected=30))
    assert n <= round(30 * d.SCATTER_SPREAD_FACTOR), \
        f"expected cap <= {round(30 * d.SCATTER_SPREAD_FACTOR)}, got {n}"


def test_scatter_without_expected_count_is_density_driven():
    # No expected_count → original behavior, far above any cap.
    assert len(_scatter(expected=None)) > round(30 * d.SCATTER_SPREAD_FACTOR)


def test_scatter_max_factor_override():
    # Per-strategy override widens/narrows the cap.
    palette = [("grass", "#00ff00"), ("rock", "#808080")]
    label_map = np.zeros((100, 100), dtype=int)
    ce = {
        "name": "rock", "expected_count": 10,
        "strategy": {
            "mask_source_class": "grass", "scatter_density_per_m2": 1.0,
            "rotation_rule": "no_rotation", "min_distance_between_meters": 0.1,
            "canonical_size_meters": [1, 1, 1], "scatter_max_factor": 1.0,
        },
    }
    n = len(d._extract_scatter(
        name="rock", class_entry=ce, label_map=label_map, palette=palette,
        image_size=(100, 100), world_size_m=(80.0, 80.0),
        sampler=None, anchors={}, rng=random.Random(7)))
    assert n <= 10, f"factor=1.0 cap should be 10, got {n}"


def _instances(n, cls):
    return [{"id": f"{cls}_{i}", "class": cls,
             "position": [i * 5.0, 0, 0], "scale": [1, 1, 1]}
            for i in range(n)]


def _catalog():
    return {"classes": [
        {"name": "rock", "intent_type": "object_placement",
         "expected_count": 30, "strategy": {"strategy_origin": "lib"}},
    ]}


def test_validate_flags_overflow_as_fail():
    r = val.validate(
        extracted={"instances": _instances(1220, "rock"),
                   "world_size_meters": [20000, 20000]},
        catalog=_catalog())
    assert r["verdict"] == "fail"
    assert r["overflow_classes"] == ["rock"]


def test_validate_within_intent_no_overflow():
    # 35 vs expected 30 → drift at most, never overflow (35 < 30×3).
    r = val.validate(
        extracted={"instances": _instances(35, "rock"),
                   "world_size_meters": [20000, 20000]},
        catalog=_catalog())
    assert not r["overflow_classes"]
