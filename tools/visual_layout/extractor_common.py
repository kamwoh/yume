"""extractor_common.py — shared primitives for visual layout extraction.

Per ADR 0054 Phase 0. Foundation for both UI and map extractors.

Pipeline of operations (all stateless functions on np.ndarray):

    load_image(path)
        → RGB uint8 HxWx3
    quantize(img, k)
        → labels HxW, centroids Kx3 (RGB)
    match_centroids_to_legend(centroids, legend)
        → centroid_idx → legend_name (Lab distance, with threshold)
    masks_by_legend_name(labels, centroid_map, legend_names)
        → name → HxW bool mask
    connected_components(mask, min_area_px)
        → list of {centroid_px, area_px, bbox, contour}
    morphological_clean(mask, op, kernel_size)
        → cleaned HxW bool

These are pure functions — no I/O side effects, no global state.
Tests inject synthetic numpy arrays; production uses real image
files via load_image.

K-means uses scikit-learn (KMeans with n_init=5 for stability).
Color distance uses CIE Lab via scikit-image (rgb2lab + Euclidean
in Lab is a reasonable approximation of perceptual distance).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

import numpy as np

try:
    import cv2
except ImportError as e:
    raise ImportError(
        "extractor_common requires opencv-python-headless. "
        "Install: pip install -r tools/visual_layout/requirements.txt"
    ) from e

try:
    from skimage.color import rgb2lab
except ImportError as e:
    raise ImportError(
        "extractor_common requires scikit-image. "
        "Install: pip install -r tools/visual_layout/requirements.txt"
    ) from e

try:
    from sklearn.cluster import KMeans
except ImportError as e:
    raise ImportError(
        "extractor_common requires scikit-learn. "
        "Install: pip install -r tools/visual_layout/requirements.txt"
    ) from e


# ============================================================
# DATA TYPES
# ============================================================


@dataclass(frozen=True)
class LegendEntry:
    """One entry in a visual-layout legend.

    `name`:       canonical id (e.g. "fire_pit", "minimap_panel")
    `hex`:        intended pixel color, e.g. "#c0a020". Quantization
                  matches each centroid to the nearest legend entry by
                  CIE Lab distance, so slight drift in the actual image
                  is tolerated.
    `min_area_px`: optional minimum connected-component area to consider
                   "present". Smaller components are filtered as noise.
    `kind`:       extraction strategy (map legends only; UI legends
                  default to "anchor" but the value is ignored). One of:
                    "anchor" — discrete entity at centroid. UI panels,
                               map landmarks like fire_pit, hut.
                    "zone"   — continuous region. Forest, grass, water.
                               Stored as a mask for downstream patterns.
                    "path"   — thin connected curve. Roads, rivers.
                               Skeletonized via skimage to a polyline.
    """

    name: str
    hex: str
    min_area_px: int = 8
    kind: str = "anchor"

    @property
    def rgb(self) -> tuple[int, int, int]:
        h = self.hex.lstrip("#")
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


@dataclass
class Legend:
    """A complete legend for one image type. Per-game OR reference-shipped."""

    name: str
    entries: list[LegendEntry] = field(default_factory=list)
    expected_clusters: int | None = None  # override; default = len + 2

    @classmethod
    def from_dict(cls, doc: dict) -> "Legend":
        return cls(
            name=str(doc.get("name", "unnamed")),
            entries=[
                LegendEntry(
                    name=str(e["name"]),
                    hex=str(e["hex"]),
                    min_area_px=int(e.get("min_area_px", 8)),
                    kind=str(e.get("kind", "anchor")),
                )
                for e in doc.get("entries", [])
            ],
            expected_clusters=doc.get("expected_clusters"),
        )

    @classmethod
    def from_file(cls, path: Path) -> "Legend":
        return cls.from_dict(json.loads(Path(path).read_text(encoding="utf-8")))

    @property
    def names(self) -> list[str]:
        return [e.name for e in self.entries]

    def by_name(self, name: str) -> LegendEntry | None:
        for e in self.entries:
            if e.name == name:
                return e
        return None


@dataclass
class Component:
    """One connected component in a mask. Pixel coordinates."""

    label: str  # legend entry name
    centroid_px: tuple[float, float]  # (x, y) — image coords, y-down
    area_px: int
    bbox_xywh: tuple[int, int, int, int]  # (x, y, w, h)
    contour: np.ndarray | None = None  # Nx1x2 from cv2.findContours, optional


# ============================================================
# IMAGE I/O
# ============================================================


def load_image(path: str | Path) -> np.ndarray:
    """Load an RGB uint8 image. Strips alpha if present."""
    raw = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if raw is None:
        raise FileNotFoundError(f"could not load image: {path}")
    if raw.ndim == 2:
        # grayscale → treat as RGB grayscale
        rgb = cv2.cvtColor(raw, cv2.COLOR_GRAY2RGB)
    elif raw.shape[2] == 4:
        rgb = cv2.cvtColor(raw, cv2.COLOR_BGRA2RGB)
    elif raw.shape[2] == 3:
        rgb = cv2.cvtColor(raw, cv2.COLOR_BGR2RGB)
    else:
        raise ValueError(f"unexpected channel count {raw.shape[2]} in {path}")
    return rgb.astype(np.uint8)


def save_mask_png(mask: np.ndarray, path: str | Path) -> None:
    """Save a bool/0-255 mask as a single-channel PNG (for debugging)."""
    if mask.dtype == bool:
        out = (mask.astype(np.uint8)) * 255
    else:
        out = mask.astype(np.uint8)
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(path), out)


# ============================================================
# K-MEANS QUANTIZATION
# ============================================================


def quantize(img: np.ndarray, k: int, random_state: int = 0) -> tuple[np.ndarray, np.ndarray]:
    """K-means cluster the image's pixels into k color centroids.

    Args:
        img: HxWx3 uint8 RGB image.
        k:   number of clusters. Per ADR 0054, default is
             `len(legend) + 2` (the +2 absorbs anti-aliased edges +
             noise). Per-legend override via Legend.expected_clusters.
        random_state: deterministic seed. Tests pass a fixed value.

    Returns:
        (labels, centroids)
        - labels:    HxW int32 — each pixel's cluster id (0..k-1).
        - centroids: kx3 float64 RGB centers.

    Notes on stability:
        - n_init=5: trades a small amount of compute for stability
          against unlucky initialization. KMeans is sensitive to
          init when clusters are unbalanced (which they are for our
          inputs — a few large regions + many small markers).
        - We don't expose n_init as a parameter to keep the API tight.
          If empirical extraction quality wobbles, revisit.
    """
    if img.ndim != 3 or img.shape[2] != 3:
        raise ValueError(f"expected HxWx3 image, got shape {img.shape}")
    if k < 2:
        raise ValueError(f"k must be ≥ 2, got {k}")
    h, w = img.shape[:2]
    pixels = img.reshape(-1, 3).astype(np.float64)
    km = KMeans(n_clusters=k, n_init=5, random_state=random_state)
    flat_labels = km.fit_predict(pixels)
    labels = flat_labels.reshape(h, w).astype(np.int32)
    centroids = km.cluster_centers_  # k×3 RGB
    return labels, centroids


# ============================================================
# LEGEND MATCHING
# ============================================================


def _rgb_to_lab_single(rgb_arr: np.ndarray) -> np.ndarray:
    """Convert N×3 RGB (uint8 or float) → N×3 Lab. Wraps skimage."""
    # skimage rgb2lab expects HxWx3 [0..1] floats. Reshape to ?x1x3.
    arr = rgb_arr.astype(np.float64) / 255.0
    pseudo_img = arr.reshape(-1, 1, 3)
    lab = rgb2lab(pseudo_img)
    return lab.reshape(-1, 3)


def match_centroids_to_legend(
    centroids: np.ndarray,
    legend: Legend,
    max_lab_distance: float = 35.0,
) -> dict[int, str | None]:
    """Match each k-means centroid to the nearest legend entry.

    Args:
        centroids:        K×3 RGB centroids from quantize().
        legend:           Legend object.
        max_lab_distance: if a centroid's nearest legend entry is
                          farther than this in Lab space, the centroid
                          is unmatched (mapped to None). 35 is the
                          ADR default — tuned for stylized
                          flat-color images.

    Returns:
        dict {centroid_idx → legend_name | None}.
        Unmatched centroids (None) typically represent anti-aliased
        edge pixels or noise that should be ignored downstream.
    """
    if len(legend.entries) == 0:
        return {i: None for i in range(len(centroids))}
    legend_rgb = np.array([e.rgb for e in legend.entries], dtype=np.float64)
    legend_lab = _rgb_to_lab_single(legend_rgb)
    centroid_lab = _rgb_to_lab_single(centroids)
    out: dict[int, str | None] = {}
    for c_id, c_lab in enumerate(centroid_lab):
        dists = np.linalg.norm(legend_lab - c_lab, axis=1)
        nearest = int(np.argmin(dists))
        if dists[nearest] <= max_lab_distance:
            out[c_id] = legend.entries[nearest].name
        else:
            out[c_id] = None
    return out


# ============================================================
# MASK EXTRACTION
# ============================================================


def masks_by_legend_name(
    labels: np.ndarray,
    centroid_map: dict[int, str | None],
    legend_names: Sequence[str],
) -> dict[str, np.ndarray]:
    """Build per-legend-name bool masks.

    Args:
        labels:       HxW int32 cluster ids from quantize().
        centroid_map: centroid-id → legend-name from
                      match_centroids_to_legend.
        legend_names: which legend names to extract masks for.

    Returns:
        {name → HxW bool mask}. Names with no matching centroids
        return empty (all-False) masks.
    """
    out: dict[str, np.ndarray] = {}
    for name in legend_names:
        # Collect all centroid ids that matched THIS name (could be
        # multiple if k > number of distinct legend colors).
        ids = [cid for cid, n in centroid_map.items() if n == name]
        if not ids:
            out[name] = np.zeros(labels.shape, dtype=bool)
            continue
        mask = np.isin(labels, ids)
        out[name] = mask
    return out


# ============================================================
# MORPHOLOGICAL OPS
# ============================================================


def morphological_clean(
    mask: np.ndarray,
    op: str = "open",
    kernel_size: int = 3,
) -> np.ndarray:
    """Apply morphological cleanup. Returns bool mask.

    op options:
        "open"    — erode then dilate. Removes small noise.
        "close"   — dilate then erode. Fills small holes.
        "erode"   — pure erosion. Shrinks regions.
        "dilate"  — pure dilation. Grows regions.
        "open_close" — open then close. Good general cleanup.
    """
    if mask.dtype != bool:
        raise ValueError(f"expected bool mask, got {mask.dtype}")
    src = (mask.astype(np.uint8)) * 255
    k = max(1, kernel_size)
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (k, k))
    if op == "open":
        out = cv2.morphologyEx(src, cv2.MORPH_OPEN, kernel)
    elif op == "close":
        out = cv2.morphologyEx(src, cv2.MORPH_CLOSE, kernel)
    elif op == "erode":
        out = cv2.erode(src, kernel)
    elif op == "dilate":
        out = cv2.dilate(src, kernel)
    elif op == "open_close":
        tmp = cv2.morphologyEx(src, cv2.MORPH_OPEN, kernel)
        out = cv2.morphologyEx(tmp, cv2.MORPH_CLOSE, kernel)
    else:
        raise ValueError(f"unknown morphological op: {op}")
    return out.astype(bool)


# ============================================================
# CONNECTED COMPONENTS
# ============================================================


def connected_components(
    mask: np.ndarray,
    label: str = "unknown",
    min_area_px: int = 8,
    include_contour: bool = True,
) -> list[Component]:
    """Find connected components in a bool mask.

    Args:
        mask:             HxW bool mask.
        label:            legend name to stamp on each Component.
        min_area_px:      drop components smaller than this. Noise filter.
        include_contour:  populate Component.contour via cv2.findContours.
                          Set False if downstream doesn't need shape data
                          (centroid + area + bbox is faster).

    Returns:
        list of Component, ordered by area descending.
    """
    if mask.dtype != bool:
        raise ValueError(f"expected bool mask, got {mask.dtype}")
    if not mask.any():
        return []
    src = (mask.astype(np.uint8)) * 255
    # connectedComponentsWithStats returns: (num_labels, labels_img, stats, centroids)
    n_labels, label_img, stats, centroids = cv2.connectedComponentsWithStats(src, connectivity=8)
    out: list[Component] = []
    # Skip background (label 0)
    for cid in range(1, n_labels):
        area = int(stats[cid, cv2.CC_STAT_AREA])
        if area < min_area_px:
            continue
        x = int(stats[cid, cv2.CC_STAT_LEFT])
        y = int(stats[cid, cv2.CC_STAT_TOP])
        w = int(stats[cid, cv2.CC_STAT_WIDTH])
        h = int(stats[cid, cv2.CC_STAT_HEIGHT])
        cx, cy = centroids[cid]
        contour = None
        if include_contour:
            # Make a per-component mask + find its contour
            comp_mask = ((label_img == cid).astype(np.uint8)) * 255
            cnts, _ = cv2.findContours(comp_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            if cnts:
                contour = cnts[0]
        out.append(
            Component(
                label=label,
                centroid_px=(float(cx), float(cy)),
                area_px=area,
                bbox_xywh=(x, y, w, h),
                contour=contour,
            )
        )
    out.sort(key=lambda c: c.area_px, reverse=True)
    return out


# ============================================================
# HIGH-LEVEL FACADE
# ============================================================


def extract_components_from_image(
    img: np.ndarray,
    legend: Legend,
    *,
    morph_op: str = "open",
    morph_kernel: int = 3,
    max_lab_distance: float = 35.0,
    random_state: int = 0,
) -> tuple[dict[str, list[Component]], dict[str, np.ndarray]]:
    """High-level facade: image + legend → per-name components + masks.

    Returns:
        (components_by_name, masks_by_name)
        - components_by_name: {legend_name → list[Component]}
        - masks_by_name:      {legend_name → HxW bool mask (post-cleanup)}

    Use this for the common case. For pipelines that need lower-level
    control, call the individual functions directly.
    """
    k = legend.expected_clusters if legend.expected_clusters else (len(legend.entries) + 2)
    labels, centroids = quantize(img, k=k, random_state=random_state)
    centroid_map = match_centroids_to_legend(
        centroids, legend, max_lab_distance=max_lab_distance
    )
    raw_masks = masks_by_legend_name(labels, centroid_map, legend.names)
    components_by_name: dict[str, list[Component]] = {}
    clean_masks: dict[str, np.ndarray] = {}
    for name, mask in raw_masks.items():
        entry = legend.by_name(name)
        clean = morphological_clean(mask, op=morph_op, kernel_size=morph_kernel)
        clean_masks[name] = clean
        comps = connected_components(
            clean,
            label=name,
            min_area_px=entry.min_area_px if entry else 8,
            include_contour=True,
        )
        components_by_name[name] = comps
    return components_by_name, clean_masks
