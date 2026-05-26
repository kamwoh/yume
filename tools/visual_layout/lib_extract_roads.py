"""lib_extract_roads.py — road / path network extraction.

A road in the semantic map is a CLASSIFICATION region (cobblestone /
dirt_path biome), not an object. This module extracts it into the
road GRAPH: centerline polylines in world coordinates. Those polylines
then drive flat path-segment entities (or, later, a ribbon mesh /
decal / NPC pathing).

Pipeline:
  path mask (union of path classes)
    → Zhang-Suen skeletonize (1px centerline)
    → trace skeleton into polylines (endpoints + junctions = graph nodes)
    → Ramer-Douglas-Peucker simplify each polyline
    → convert pixel → world coords

Pure stdlib + numpy. No scipy / cv2.
"""
from __future__ import annotations

import numpy as np

from tools.visual_layout import lib_extract as cv


# ============================================================
# ZHANG-SUEN THINNING (pure numpy)
# ============================================================

def skeletonize(mask: np.ndarray) -> np.ndarray:
    """Zhang-Suen thinning → 1px-wide skeleton (boolean array).

    Iteratively peels boundary pixels that don't break connectivity,
    until stable. Classic 2-subiteration algorithm.
    """
    img = mask.astype(np.uint8).copy()
    H, W = img.shape

    def neighbours(y, x):
        # P2..P9 clockwise from north (Zhang-Suen ordering)
        return [
            img[y - 1, x], img[y - 1, x + 1], img[y, x + 1], img[y + 1, x + 1],
            img[y + 1, x], img[y + 1, x - 1], img[y, x - 1], img[y - 1, x - 1],
        ]

    def transitions(n):
        # number of 0→1 transitions in the ordered neighbour sequence
        seq = n + n[:1]
        return sum((a == 0 and b == 1) for a, b in zip(seq, seq[1:]))

    changed = True
    while changed:
        changed = False
        for step in (0, 1):
            to_zero = []
            ys, xs = np.where(img == 1)
            for y, x in zip(ys.tolist(), xs.tolist()):
                if y <= 0 or y >= H - 1 or x <= 0 or x >= W - 1:
                    continue
                n = neighbours(y, x)
                b = sum(n)
                if b < 2 or b > 6:
                    continue
                if transitions(n) != 1:
                    continue
                p2, p3, p4, p5, p6, p7, p8, p9 = n
                if step == 0:
                    if p2 * p4 * p6 != 0:
                        continue
                    if p4 * p6 * p8 != 0:
                        continue
                else:
                    if p2 * p4 * p8 != 0:
                        continue
                    if p2 * p6 * p8 != 0:
                        continue
                to_zero.append((y, x))
            if to_zero:
                changed = True
                for (y, x) in to_zero:
                    img[y, x] = 0
    return img.astype(bool)


# ============================================================
# SKELETON → POLYLINES
# ============================================================

_NB8 = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]


def _neighbour_coords(skel: np.ndarray, y: int, x: int) -> list[tuple[int, int]]:
    H, W = skel.shape
    out = []
    for dy, dx in _NB8:
        ny, nx = y + dy, x + dx
        if 0 <= ny < H and 0 <= nx < W and skel[ny, nx]:
            out.append((ny, nx))
    return out


def trace_polylines(skel: np.ndarray) -> list[list[tuple[int, int]]]:
    """Trace a 1px skeleton into polylines between graph nodes.

    Graph nodes = endpoints (1 neighbour) + junctions (≥3 neighbours).
    Each polyline runs node → node along degree-2 path pixels. A loop
    with no node gets one arbitrary start.

    Returns a list of polylines, each a list of (x, y) pixel pairs.
    """
    H, W = skel.shape
    degree = {}
    ys, xs = np.where(skel)
    for y, x in zip(ys.tolist(), xs.tolist()):
        degree[(y, x)] = len(_neighbour_coords(skel, y, x))

    nodes = {p for p, d in degree.items() if d == 1 or d >= 3}
    visited_edges: set[frozenset] = set()
    polylines: list[list[tuple[int, int]]] = []

    def walk(start, first):
        path = [start, first]
        prev, cur = start, first
        while True:
            if cur in nodes:
                return path
            nbrs = [p for p in _neighbour_coords(skel, cur[0], cur[1])
                    if p != prev]
            if not nbrs:
                return path
            # degree-2 path pixel: follow the single continuation
            nxt = nbrs[0]
            prev, cur = cur, nxt
            path.append(cur)
            if cur == start:
                return path

    for node in nodes:
        for nb in _neighbour_coords(skel, node[0], node[1]):
            edge = frozenset((node, nb))
            if edge in visited_edges:
                continue
            path = walk(node, nb)
            # mark all edges in this path as visited
            for a, b in zip(path, path[1:]):
                visited_edges.add(frozenset((a, b)))
            if len(path) >= 2:
                # store as (x, y)
                polylines.append([(p[1], p[0]) for p in path])

    # Pure loops with no node: pick any unvisited skeleton pixel.
    all_px = set(zip(ys.tolist(), xs.tolist()))
    seen = set()
    for poly in polylines:
        for (x, y) in poly:
            seen.add((y, x))
    for p in all_px - seen:
        if degree.get(p, 0) != 2:
            continue
        nbrs = _neighbour_coords(skel, p[0], p[1])
        if not nbrs:
            continue
        path = walk(p, nbrs[0])
        for a, b in zip(path, path[1:]):
            visited_edges.add(frozenset((a, b)))
        polylines.append([(q[1], q[0]) for q in path])
        for (qx, qy) in [(q[1], q[0]) for q in path]:
            seen.add((qy, qx))

    return polylines


# ============================================================
# RAMER-DOUGLAS-PEUCKER (on (x, y) pixel polylines)
# ============================================================

def _perp(p, a, b) -> float:
    import math
    if a == b:
        return math.hypot(p[0] - a[0], p[1] - a[1])
    dx = b[0] - a[0]; dy = b[1] - a[1]
    norm = math.hypot(dx, dy)
    return abs(dy * p[0] - dx * p[1] + b[0] * a[1] - b[1] * a[0]) / norm


def rdp(points: list[tuple[int, int]], eps_px: float) -> list[tuple[int, int]]:
    if len(points) < 3:
        return list(points)
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        if j - i < 2:
            continue
        max_d, max_k = 0.0, -1
        for k in range(i + 1, j):
            dd = _perp(points[k], points[i], points[j])
            if dd > max_d:
                max_d, max_k = dd, k
        if max_d > eps_px and max_k > 0:
            keep[max_k] = True
            stack.append((i, max_k))
            stack.append((max_k, j))
    return [points[i] for i in range(len(points)) if keep[i]]


# ============================================================
# PUBLIC ENTRY POINT
# ============================================================

def extract_roads(
    *,
    label_map: np.ndarray,
    palette: list[tuple[str, str]],
    path_class_names: list[str],
    image_size: tuple[int, int],
    world_size_m: tuple[float, float],
    simplify_tolerance_meters: float = 0.8,
    min_world_length_m: float = 4.0,
) -> dict:
    """Extract the road network.

    Returns:
      {
        "polylines_world": [[[wx, wz], ...], ...],   # world-space
        "polylines_px": [[[x, y], ...], ...],         # pixel-space (debug)
        "n_polylines": int,
        "skeleton_px": int,
      }
    """
    iw, ih = image_size
    wx_m, wz_m = world_size_m
    px_per_m = 0.5 * (iw / wx_m + ih / wz_m)
    tol_px = simplify_tolerance_meters * px_per_m

    # Union mask of every path class present in the palette.
    mask = np.zeros(label_map.shape, dtype=bool)
    for name in path_class_names:
        idx = next((i for i, (n, _h) in enumerate(palette) if n == name), None)
        if idx is not None:
            mask |= (label_map == idx)

    if not mask.any():
        return {"polylines_world": [], "polylines_px": [],
                "n_polylines": 0, "skeleton_px": 0}

    skel = skeletonize(mask)
    polys_px = trace_polylines(skel)

    import math
    polylines_world = []
    polylines_px = []
    for poly in polys_px:
        if len(poly) < 2:
            continue
        simp = rdp(poly, tol_px)
        if len(simp) < 2:
            continue
        world = [list(cv.pixel_to_world(x, y, image_size, world_size_m))
                 for (x, y) in simp]
        # Drop noise fragments: keep only polylines whose total world
        # length clears the threshold. Real streets are long; the
        # dotted inter-house gaps misclassified as path are < a meter.
        total_len = sum(
            math.hypot(world[i + 1][0] - world[i][0],
                       world[i + 1][1] - world[i][1])
            for i in range(len(world) - 1)
        )
        if total_len < min_world_length_m:
            continue
        polylines_px.append(simp)
        polylines_world.append(world)

    return {
        "polylines_world": polylines_world,
        "polylines_px": polylines_px,
        "n_polylines": len(polylines_world),
        "skeleton_px": int(skel.sum()),
    }
