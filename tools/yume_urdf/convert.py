"""URDF → Yume articulated-body def (ADR 0091, ADR 0092).

A URDF robot is a tree of links and joints, the same model as an
articulated body. The importer changes three things:

1. Axes. URDF (ROS) is Z-up with X forward and Y left. Yume is Y-up with
   -Z forward. A ROS vector (x, y, z) becomes (-y, z, -x). This is a
   proper rotation, so the right-hand rule of a hinge stays the same.
2. Frames. A Yume link frame has the root orientation (ADR 0091), so the
   importer folds each joint rotation into the positions, joint axes and
   shapes below it. A box must end axis-aligned, and a cylinder must end
   along x, y or z. Other rotations are an ImportError.
3. Motors. URDF has no motors. Each continuous or revolute joint gets a
   motor that reads `self.state.<joint>_cmd`, with `<limit effort>` as
   the torque, and it reports as `<joint>`.

Joint types: continuous and revolute become hinge, fixed stays fixed.
prismatic, planar and floating are an ImportError (the spec has no
slider). A mesh geometry is skipped with a warning, so that link has no
shape.
"""
from __future__ import annotations

import math
import re
import xml.etree.ElementTree as ET

import numpy as np

# ROS (x fwd, y left, z up) → Yume (x right, y up, z back).
ROS_TO_YUME = np.array([[0.0, -1.0, 0.0], [0.0, 0.0, 1.0], [-1.0, 0.0, 0.0]])
_TOL = 1e-3


class URDFError(Exception):
    """The URDF uses a feature the spec does not have."""


def _floats(text: str | None, n: int, default: float = 0.0) -> list[float]:
    if not text:
        return [default] * n
    vals = [float(v) for v in text.split()]
    if len(vals) != n:
        raise URDFError(f"expected {n} numbers, got '{text}'")
    return vals


def rpy_matrix(roll: float, pitch: float, yaw: float) -> np.ndarray:
    """URDF rpy: R = Rz(yaw) · Ry(pitch) · Rx(roll)."""
    cr, sr, cp, sp, cy, sy = (math.cos(roll), math.sin(roll), math.cos(pitch),
                              math.sin(pitch), math.cos(yaw), math.sin(yaw))
    rx = np.array([[1, 0, 0], [0, cr, -sr], [0, sr, cr]])
    ry = np.array([[cp, 0, sp], [0, 1, 0], [-sp, 0, cp]])
    rz = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]])
    return rz @ ry @ rx


def _origin(el) -> tuple[np.ndarray, np.ndarray]:
    o = el.find("origin") if el is not None else None
    if o is None:
        return np.zeros(3), np.eye(3)
    return np.array(_floats(o.get("xyz"), 3)), rpy_matrix(*_floats(o.get("rpy"), 3))


def _clean(v: float) -> float:
    r = round(float(v), 6)
    return 0.0 if r == 0 else r


def _vec(v) -> list[float]:
    return [_clean(x) for x in v]


def _ident(name: str) -> str:
    """A state-field-safe name: lower case, digits and underscores."""
    return re.sub(r"[^a-z0-9_]", "_", name.lower())


def _shape(geom, offset_ros: np.ndarray, rot_ros: np.ndarray, link: str, warnings: list) -> dict | None:
    """One collision geometry in the root-aligned link frame, Yume axes."""
    rot = ROS_TO_YUME @ rot_ros
    offset = ROS_TO_YUME @ offset_ros
    box, cyl, sph = geom.find("box"), geom.find("cylinder"), geom.find("sphere")
    shape: dict
    if sph is not None:
        shape = {"type": "sphere", "radius": _clean(float(sph.get("radius")))}
    elif cyl is not None:
        axis = rot @ np.array([0.0, 0.0, 1.0])
        names = [i for i in range(3) if abs(abs(axis[i]) - 1.0) < _TOL]
        if not names:
            raise URDFError(f"link '{link}': a cylinder must end along x, y or z, got {_vec(axis)}")
        shape = {"type": "cylinder", "radius": _clean(float(cyl.get("radius"))),
                 "height": _clean(float(cyl.get("length"))), "axis": "xyz"[names[0]]}
        if shape["axis"] == "y":
            del shape["axis"]
    elif box is not None:
        if not np.all((np.abs(rot) < _TOL) | (np.abs(np.abs(rot) - 1.0) < _TOL)):
            raise URDFError(f"link '{link}': a box must end axis-aligned (a 90-degree rotation)")
        size = np.abs(rot) @ np.array(_floats(box.get("size"), 3))
        shape = {"type": "box", "size": _vec(size)}
    else:
        warnings.append(f"link '{link}': mesh geometry is skipped, so the link has no shape")
        return None
    if np.linalg.norm(offset) > 1e-9:
        shape["offset"] = _vec(offset)
    return shape


def _color(link_el, materials: dict) -> str | None:
    mat = link_el.find("visual/material")
    if mat is None:
        return None
    c = mat.find("color")
    rgba = c.get("rgba") if c is not None else materials.get(mat.get("name"))
    if not rgba:
        return None
    r, g, b = (_floats(rgba, 4)[:3])
    return "#%02x%02x%02x" % tuple(int(round(max(0.0, min(1.0, v)) * 255)) for v in (r, g, b))


def convert(urdf_text: str, def_id: str | None = None, friction: dict | None = None,
            tags: list | None = None, layers: list | None = None) -> tuple[dict, list]:
    """Return (def, warnings). `friction` maps link name → friction.
    `layers` sets collision_layer (names from @lib.physics.layers)."""
    friction = friction or {}
    root_el = ET.fromstring(urdf_text)
    if root_el.tag != "robot":
        raise URDFError("the top element must be <robot>")
    warnings: list = []
    materials = {}
    for m in root_el.findall("material"):
        c = m.find("color")
        if c is not None:
            materials[m.get("name")] = c.get("rgba")
    link_els = {l.get("name"): l for l in root_el.findall("link")}
    joint_els = root_el.findall("joint")
    children = {j.find("child").get("link") for j in joint_els}
    roots = [n for n in link_els if n not in children]
    if len(roots) != 1:
        raise URDFError(f"the links must form one tree, roots found: {roots}")
    root = roots[0]
    for name in friction:
        if name not in link_els:
            raise URDFError(f"--friction names an unknown link '{name}'")

    # Rotation of each link frame relative to the root, in ROS axes.
    rot = {root: np.eye(3)}
    joints_out, state_init = [], {}
    pending = list(joint_els)
    while pending:
        rest = []
        for j in pending:
            parent, child = j.find("parent").get("link"), j.find("child").get("link")
            if parent not in rot:
                rest.append(j)
                continue
            xyz, r = _origin(j)
            rot[child] = rot[parent] @ r
            name, jtype = j.get("name"), j.get("type")
            out = {"type": None, "parent": parent, "child": child,
                   "at": _vec(ROS_TO_YUME @ rot[parent] @ xyz)}
            if jtype == "fixed":
                out["type"] = "fixed"
            elif jtype in ("continuous", "revolute"):
                out["type"] = "hinge"
                ax_el = j.find("axis")
                axis = np.array(_floats(ax_el.get("xyz") if ax_el is not None else None, 3, 0.0)) \
                    if ax_el is not None else np.array([1.0, 0.0, 0.0])
                # URDF files write pi/2 as 1.5708, so snap the residue.
                ax = ROS_TO_YUME @ rot[child] @ axis
                out["axis"] = _vec(np.where(np.abs(ax) < 1e-4, 0.0, ax))
                lim = j.find("limit")
                if jtype == "revolute" and lim is not None:
                    out["limit"] = [_clean(float(lim.get("lower", 0))), _clean(float(lim.get("upper", 0)))]
                cmd = f"{_ident(name)}_cmd"
                effort = float(lim.get("effort")) if lim is not None and lim.get("effort") else 1.0
                out["motor"] = {"target_velocity": f"self.state.{cmd}", "max_torque": _clean(effort)}
                out["report"] = _ident(name)
                state_init[cmd] = 0.0
            else:
                raise URDFError(f"joint '{name}': type '{jtype}' is not in the spec (ADR 0091)")
            joints_out.append(out)
        if len(rest) == len(pending):
            raise URDFError("some joints do not connect to the root")
        pending = rest

    links_out = {}
    for name, el in link_els.items():
        link: dict = {}
        cols = el.findall("collision")
        if len(cols) > 1:
            warnings.append(f"link '{name}': only the first of {len(cols)} collision shapes is used")
        if cols:
            off, r = _origin(cols[0])
            geom = cols[0].find("geometry")
            shape = _shape(geom, rot[name] @ off, rot[name] @ r, name, warnings) if geom is not None else None
            if shape:
                link["shape"] = shape
        mass_el = el.find("inertial/mass")
        link["mass"] = _clean(max(float(mass_el.get("value")), 0.001)) if mass_el is not None else 0.001
        if name in friction:
            link["friction"] = float(friction[name])
        color = _color(el, materials)
        if color:
            link["visual"] = {"color": color}
        links_out[name] = link

    robot = root_el.get("name", "robot")
    d = {
        "id": def_id or _ident(robot),
        "tags": tags or [_ident(robot), "robot"],
        "properties": {"display_name": robot},
        "_comment": f"Imported from URDF robot '{robot}' by tools/yume_urdf. Each motor reads "
                    f"self.state.<joint>_cmd in rad/s.",
        "state_init": state_init,
        "physics": {"body_type": "articulated", "root": root, "links": links_out, "joints": joints_out},
    }
    if layers:
        d["physics"]["collision_layer"] = list(layers)
    return d, warnings
