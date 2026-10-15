#!/usr/bin/env python3
"""validate_meshes.py — check the schema of the code-built mesh library (ADR 0083).

This validator is repo-wide. It reads `godot/data/meshes.json` and checks
each part of each mesh. Each part has a known `op` and the fields that
the op needs. Each `$param` has a value in the mesh's `params`. Each
`material` name is in the top-level `materials` block. A `lathe` has
`segments` of 3 or more and no negative radius. A `quad` or `plane` is
not in a CSG group, because CSG needs closed (manifold) shapes.

It does not check the base height or the facing of a mesh. Those are
content choices that change per game: a portal hovers, a rock sinks, a
projectile is centered on its flight point. On 2026-10-15 the user
rejected a strict "base at y = 0" rule for this reason (ADR 0083 F4).
A floating entity is a visual bug, and the visual QA gate and
`validate_center_pivot_y.py` own it.

Usage:
    python3 tools/validators/validate_meshes.py [--strict] [--report]

`--report` also prints the unit-space AABB (base and top) of every mesh,
as information. It never fails on it.
"""

import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MESHES = ROOT / "godot" / "data" / "meshes.json"

# op -> required fields (each entry: a field, or a tuple of choices)
REQUIRED = {
    "box": ("size",),
    "sphere": ("radius",),
    "cylinder": ("radius", "height"),
    "capsule": ("radius", "height"),
    "plane": ("size",),
    "prism": ("size",),
    "torus": ("inner_radius", "outer_radius"),
    "quad": ("size",),
    "lathe": ("profile",),
    "extrude": ("polygon", "depth"),
    "sweep": ("polygon", "path"),
}
CSG_OPS = {"lathe", "extrude", "sweep"}
NON_MANIFOLD = {"quad", "plane"}


def _resolve(v, params):
    if isinstance(v, str) and v.startswith("$"):
        return params.get(v[1:], v)
    return v


def _vec3(v, default=(0.0, 0.0, 0.0)):
    if isinstance(v, (int, float)):
        return (float(v),) * 3
    if isinstance(v, list):
        if len(v) >= 3:
            return tuple(float(x) for x in v[:3])
        if len(v) == 2:
            return (float(v[0]), float(v[1]), 0.0)
    return default


def _vec2(v):
    if isinstance(v, (int, float)):
        return (float(v), float(v))
    if isinstance(v, list) and len(v) >= 2:
        return (float(v[0]), float(v[1]))
    return (1.0, 1.0)


def _rot_yxz(deg):
    """Rotation matrix for Node3D euler degrees in YXZ order: R = Ry Rx Rz."""
    x, y, z = (math.radians(a) for a in deg)
    cx, sx, cy, sy, cz, sz = math.cos(x), math.sin(x), math.cos(y), math.sin(y), math.cos(z), math.sin(z)
    ry = ((cy, 0, sy), (0, 1, 0), (-sy, 0, cy))
    rx = ((1, 0, 0), (0, cx, -sx), (0, sx, cx))
    rz = ((cz, -sz, 0), (sz, cz, 0), (0, 0, 1))

    def mul(a, b):
        return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))
    return mul(mul(ry, rx), rz)


def _local_box(p, params):
    """Local (min, max) of one part before its transform, or None."""
    op = p.get("op")
    g = lambda k, d: _resolve(p.get(k, d), params)
    if op in ("box", "prism"):
        s = _vec3(g("size", [1, 1, 1]))
        return tuple(-c / 2 for c in s), tuple(c / 2 for c in s)
    if op == "sphere":
        r = float(g("radius", 0.5))
        return (-r, -r, -r), (r, r, r)
    if op in ("cylinder", "capsule"):
        r, h = float(g("radius", 0.3)), float(g("height", 1.0))
        return (-r, -h / 2, -r), (r, h / 2, r)
    if op == "torus":
        ri, ro = float(g("inner_radius", 0.3)), float(g("outer_radius", 0.5))
        t = (ro - ri) / 2
        return (-ro, -t, -ro), (ro, t, ro)
    if op == "plane":
        sx, sz = _vec2(g("size", [1, 1]))
        return (-sx / 2, 0, -sz / 2), (sx / 2, 0, sz / 2)
    if op == "quad":
        sx, sy = _vec2(g("size", [1, 1]))
        return (-sx / 2, -sy / 2, 0), (sx / 2, sy / 2, 0)
    if op == "lathe":
        pts = [_vec2(q) for q in g("profile", [])]
        if not pts:
            return None
        r = max(abs(q[0]) for q in pts)
        return (-r, min(q[1] for q in pts), -r), (r, max(q[1] for q in pts), r)
    if op == "extrude":
        pts = [_vec2(q) for q in g("polygon", [])]
        if not pts:
            return None
        d = float(g("depth", 0.1))
        return ((min(q[0] for q in pts), min(q[1] for q in pts), -d / 2),
                (max(q[0] for q in pts), max(q[1] for q in pts), d / 2))
    if op == "sweep":
        path = [_vec3(q) for q in g("path", [])]
        poly = [_vec2(q) for q in g("polygon", [])]
        if not path or not poly:
            return None
        r = max(math.hypot(*q) for q in poly)
        return (tuple(min(q[i] for q in path) - r for i in range(3)),
                tuple(max(q[i] for q in path) + r for i in range(3)))
    return None


def part_aabb(p, params):
    box = _local_box(p, params)
    if box is None:
        return None
    lo, hi = box
    pos = _vec3(_resolve(p.get("pos", [0, 0, 0]), params))
    rot = _vec3(_resolve(p.get("rotation_deg", [0, 0, 0]), params))
    m = _rot_yxz(rot) if any(rot) else None
    pts = []
    for cx in (lo[0], hi[0]):
        for cy in (lo[1], hi[1]):
            for cz in (lo[2], hi[2]):
                c = (cx, cy, cz)
                if m:
                    c = tuple(sum(m[i][k] * c[k] for k in range(3)) for i in range(3))
                pts.append(tuple(c[i] + pos[i] for i in range(3)))
    return (tuple(min(q[i] for q in pts) for i in range(3)),
            tuple(max(q[i] for q in pts) for i in range(3)))


def mesh_aabb(entry):
    params = entry.get("params", {})
    lo, hi = None, None
    for p in entry.get("primitives", []):
        if not isinstance(p, dict) or p.get("csg"):
            continue
        b = part_aabb(p, params)
        if b is None:
            continue
        lo = b[0] if lo is None else tuple(min(lo[i], b[0][i]) for i in range(3))
        hi = b[1] if hi is None else tuple(max(hi[i], b[1][i]) for i in range(3))
    return lo, hi


def _params_used(v, out):
    if isinstance(v, str) and v.startswith("$"):
        out.add(v[1:])
    elif isinstance(v, list):
        for x in v:
            _params_used(x, out)


def check_schema(name, entry, materials):
    issues = []
    params = entry.get("params", {})
    groups = {}
    for i, p in enumerate(entry.get("primitives", [])):
        where = f"{name}[{i}]"
        if not isinstance(p, dict):
            issues.append(f"{where}: part is not an object")
            continue
        op = p.get("op")
        if op not in REQUIRED:
            issues.append(f"{where}: unknown op {op!r}")
            continue
        for field in REQUIRED[op]:
            if field not in p:
                issues.append(f"{where}: op {op!r} needs `{field}`")
        used = set()
        for v in p.values():
            _params_used(v, used)
        for k in sorted(used - set(params)):
            issues.append(f"{where}: ${k} has no value in params")
        mat = _resolve(p.get("material"), params)
        if mat is not None and mat not in materials:
            issues.append(f"{where}: material {mat!r} is not in the materials block")
        if op == "lathe":
            if int(_resolve(p.get("segments", 16), params)) < 3:
                issues.append(f"{where}: lathe needs segments >= 3")
            if any(_vec2(q)[0] < 0 for q in _resolve(p.get("profile", []), params)):
                issues.append(f"{where}: lathe profile has a negative radius")
        g = p.get("group")
        if g:
            groups.setdefault(g, []).append(p)
    for g, parts in groups.items():
        is_csg = any(q.get("csg") or q.get("op") in CSG_OPS for q in parts)
        if is_csg:
            for q in parts:
                if q.get("op") in NON_MANIFOLD:
                    issues.append(f"{name}: group {g!r} is CSG but has a non-manifold {q['op']!r}")
    return issues


def main() -> int:
    strict = "--strict" in sys.argv
    report = "--report" in sys.argv
    doc = json.loads(MESHES.read_text(encoding="utf-8"))
    lib = doc.get("meshes", {})
    materials = doc.get("materials", {})
    issues = []
    for name, entry in lib.items():
        issues += check_schema(name, entry, materials)
        if report:
            lo, hi = mesh_aabb(entry)
            if lo is not None:
                print(f"  [meshes:info] {name}: y {lo[1]:+.3f} .. {hi[1]:+.3f}")
    for i in issues:
        print(f"  [meshes] {i}")
    if not issues:
        print(f"[ok] meshes.json ({len(lib)} meshes)")
        return 0
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
