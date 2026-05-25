"""lib_extract.py — Generic extraction helpers for stage-5 of the
text-to-world pipeline.

The yume-extract-author skill writes a thin per-scene Python script
that uses these helpers. The helpers handle the heavy lifting (color
thresholding, connected components, rotation inference, mask saving);
the per-scene script just routes per-class.

Pure stdlib + numpy + PIL — no scipy dependency.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from PIL import Image


# ============================================================
# IMAGE I/O
# ============================================================

def load_rgb(path: str | Path) -> np.ndarray:
    """Load a PNG/JPG as an RGB numpy array (H, W, 3) uint8."""
    return np.array(Image.open(path).convert("RGB"))


def save_mask(mask: np.ndarray, path: str | Path) -> None:
    """Save a boolean mask as a 1-bit PNG."""
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    img = (mask.astype(np.uint8) * 255)
    Image.fromarray(img, mode="L").save(path)


# ============================================================
# COLOR THRESHOLDING
# ============================================================

def hex_to_rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))


def threshold_by_hex(
    img: np.ndarray,
    target_hex: str,
    tolerance_rgb: int = 30,
) -> np.ndarray:
    """Boolean mask where every channel is within `tolerance_rgb` of
    target_hex. Conservative enough to absorb JPEG compression jitter
    + gpt-image-2 color noise."""
    r, g, b = hex_to_rgb(target_hex)
    return (
        (np.abs(img[..., 0].astype(int) - r) <= tolerance_rgb)
        & (np.abs(img[..., 1].astype(int) - g) <= tolerance_rgb)
        & (np.abs(img[..., 2].astype(int) - b) <= tolerance_rgb)
    )


def threshold_nearest_palette(
    img: np.ndarray,
    palette: list[tuple[str, str]],
) -> np.ndarray:
    """Assign each pixel to the NEAREST hex in the palette.

    palette: list of (name, hex). Returns an int array (H, W) where
    each pixel's value is the index into `palette` of its nearest
    color. Use when you want a hard partition where every pixel
    belongs to exactly one class (no overlap, no gaps)."""
    H, W = img.shape[:2]
    pal_rgb = np.array([hex_to_rgb(h) for _, h in palette], dtype=np.int32)
    flat = img.reshape(-1, 3).astype(np.int32)
    # Squared distance to each palette color
    dists = np.sum((flat[:, None, :] - pal_rgb[None, :, :]) ** 2, axis=2)
    return np.argmin(dists, axis=1).reshape(H, W)


# ============================================================
# CONNECTED COMPONENTS (pure numpy, no scipy)
# ============================================================

def connected_components(
    mask: np.ndarray,
    connectivity: int = 4,
    min_area: int = 4,
) -> list[dict]:
    """Find connected components in a boolean mask via iterative
    flood-fill. Returns a list of dicts:

      {
        "id": int,
        "bbox": (x0, y0, x1, y1),  # inclusive
        "centroid": (cx, cy),       # pixel center
        "area_px": int,
        "pixels": numpy array of (y, x) coordinates,
      }

    `connectivity=4` checks N/S/E/W neighbors; `connectivity=8`
    also checks diagonals.
    """
    if mask.dtype != bool:
        mask = mask.astype(bool)
    H, W = mask.shape
    visited = ~mask  # True where DON'T process
    components: list[dict] = []

    ys, xs = np.where(mask)
    if connectivity == 4:
        deltas = ((1, 0), (-1, 0), (0, 1), (0, -1))
    else:
        deltas = ((1, 0), (-1, 0), (0, 1), (0, -1),
                  (1, 1), (1, -1), (-1, 1), (-1, -1))

    next_id = 0
    for sy, sx in zip(ys.tolist(), xs.tolist()):
        if visited[sy, sx]:
            continue
        # BFS / DFS via stack
        stack = [(sy, sx)]
        minx, miny, maxx, maxy = sx, sy, sx, sy
        pixels: list[tuple[int, int]] = []
        while stack:
            y, x = stack.pop()
            if y < 0 or y >= H or x < 0 or x >= W:
                continue
            if visited[y, x]:
                continue
            visited[y, x] = True
            pixels.append((y, x))
            if x < minx: minx = x
            if x > maxx: maxx = x
            if y < miny: miny = y
            if y > maxy: maxy = y
            for dy, dx in deltas:
                stack.append((y + dy, x + dx))
        if len(pixels) < min_area:
            continue
        next_id += 1
        px_arr = np.array(pixels)  # shape (N, 2): (y, x)
        cx = float(px_arr[:, 1].mean())
        cy = float(px_arr[:, 0].mean())
        components.append({
            "id": next_id,
            "bbox": (minx, miny, maxx, maxy),
            "centroid": (round(cx, 2), round(cy, 2)),
            "area_px": len(pixels),
            "pixels": px_arr,  # NOTE: caller can drop this if memory matters
        })
    return components


# ============================================================
# ROTATION INFERENCE (PCA on connected-component pixels)
# ============================================================

def infer_rotation_deg(component: dict) -> tuple[float, float]:
    """Estimate the dominant orientation of a connected component via
    PCA on its pixel coordinates.

    Returns (angle_deg, elongation_ratio):
      angle_deg ∈ [-90, +90), measured CCW from +X axis
      elongation_ratio = sqrt(eigval_max / eigval_min) — close to 1
                         means the shape is roughly isotropic (no
                         meaningful rotation); large means strongly
                         elongated.

    If elongation_ratio < 1.2, the rotation is meaningless and
    should be ignored (set to 0 in output). The caller decides the
    threshold.
    """
    px = component["pixels"]  # (N, 2) — (y, x)
    if px.shape[0] < 3:
        return 0.0, 1.0
    # Center on centroid (use float for precision)
    pts = px.astype(float)
    pts[:, 0] -= pts[:, 0].mean()
    pts[:, 1] -= pts[:, 1].mean()
    # Covariance: [[var_y, cov_yx], [cov_yx, var_x]]
    cov = np.cov(pts.T)
    if cov.shape != (2, 2):
        return 0.0, 1.0
    eigvals, eigvecs = np.linalg.eigh(cov)
    # eigh returns eigenvalues in ascending order
    eigval_min, eigval_max = eigvals[0], eigvals[1]
    elongation = math.sqrt(max(eigval_max, 1e-9) / max(eigval_min, 1e-9))
    # Principal axis is the eigenvector with the LARGER eigenvalue (index 1)
    vy, vx = eigvecs[:, 1]   # (y, x) component
    # Angle in image plane — atan2(dx, -dy) gives angle CCW from +X
    # (image Y is flipped vs math Y; we flip so positive angle = CCW
    # rotation in the natural sense)
    angle_deg = math.degrees(math.atan2(vx, -vy))
    # Normalize to [-90, +90) — orientations 180° apart are equivalent
    while angle_deg >= 90:  angle_deg -= 180
    while angle_deg < -90:  angle_deg += 180
    return round(angle_deg, 1), round(elongation, 3)


# ============================================================
# COORDINATE TRANSFORM (pixels → world meters)
# ============================================================

def pixel_to_world(
    cx_px: float, cy_px: float,
    image_size: tuple[int, int],
    world_size_m: tuple[float, float],
) -> tuple[float, float]:
    """Map pixel (cx, cy) origin-top-left → world (wx, wz) origin-
    center-of-map. Yume's 3D scenes use X=east, Z=south (Godot's
    -Y forward convention rendered as +Z). World Y is up (height
    comes from the heightmap)."""
    W, H = image_size
    wx_m, wz_m = world_size_m
    wx = (cx_px / W - 0.5) * wx_m
    wz = (cy_px / H - 0.5) * wz_m
    return round(wx, 3), round(wz, 3)


# ============================================================
# COVERAGE VALIDATOR
# ============================================================

def coverage_report(
    label_map: np.ndarray,
    palette: list[tuple[str, str]],
    expected_pcts: dict[str, float] | None = None,
) -> dict:
    """Compute per-class pixel coverage from a label map (output of
    threshold_nearest_palette). Returns a dict with per-class counts +
    overall coverage stat."""
    H, W = label_map.shape
    total = H * W
    per_class = {}
    for idx, (name, hex_) in enumerate(palette):
        n = int((label_map == idx).sum())
        per_class[name] = {
            "hex": hex_,
            "pixels": n,
            "pct": round(100 * n / total, 3),
        }
        if expected_pcts and name in expected_pcts:
            per_class[name]["expected_pct"] = expected_pcts[name]
            per_class[name]["drift_pct"] = round(
                per_class[name]["pct"] - expected_pcts[name], 2
            )
    return {
        "total_pixels": total,
        "per_class": per_class,
        "coverage_pct": 100.0,  # by construction with nearest-palette
        "unassigned_pct": 0.0,
    }


# ============================================================
# OUTPUT JSON WRITER
# ============================================================

def write_extracted_json(
    out_path: str | Path,
    *,
    semantic_map_path: str,
    catalog_path: str,
    image_size: tuple[int, int],
    world_size_m: tuple[float, float],
    classes: list[dict],
    coverage_pct: float = 100.0,
    unassigned_pct: float = 0.0,
    notes: str = "",
) -> None:
    """Write the final extracted.json for stage 5 output."""
    doc = {
        "source_semantic_map": str(semantic_map_path),
        "source_catalog": str(catalog_path),
        "image_size": list(image_size),
        "world_size_meters": list(world_size_m),
        "coverage_pct": round(coverage_pct, 3),
        "unassigned_pct": round(unassigned_pct, 3),
        "classes": classes,
        "notes": notes,
    }
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(out_path).write_text(json.dumps(doc, indent=2))
