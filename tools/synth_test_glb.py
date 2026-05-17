#!/usr/bin/env python3
"""
synth_test_glb.py — synthesize a minimal .glb for Phase B.4 testing.

Generates a colored cube with two animation clips ("Idle" + "Walking")
that rotate the cube around the Y axis. The Idle clip is a slow
breath-like bob; the Walking clip is a faster yaw oscillation.
Two materials ("body" + "trim") on two surfaces let
material_overrides be tested end-to-end.

Authoring purpose: pure-stdlib GLB generator means the test asset is
reproducible from source — `make test-glb` regenerates it any time
the loader contract changes. The .glb itself lives at
`godot/data/test_assets/cube_anim.glb`.

GLB format reference: https://github.com/KhronosGroup/glTF/tree/main/specification/2.0
Layout:
    [12-byte header: 'glTF' + version(uint32) + total_length(uint32)]
    [JSON chunk: length(uint32) + 'JSON' + json_text padded to 4 bytes]
    [BIN chunk:  length(uint32) + 'BIN\\x00' + binary_buffer padded to 4 bytes]

Usage:
    python3 tools/synth_test_glb.py [output_path]
"""

import json
import math
import struct
import sys
from pathlib import Path

# ============================================================
# CUBE GEOMETRY (two-material split: body=top 4 faces, trim=bottom 4)
# ============================================================

# 24 vertices (4 per face × 6 faces) so we can assign per-face normals.
# This gives us 2 surfaces: surface_0 = first 12 verts (body), surface_1 = next 12 (trim).
HALF = 0.5

# Per-face vertices in (px, py, pz, nx, ny, nz) format, 4 verts per face.
# Order: top, bottom, front, back, left, right.
_FACES = [
    # top (y = +HALF, normal +Y)
    [(-HALF, +HALF, -HALF, 0, 1, 0), (+HALF, +HALF, -HALF, 0, 1, 0),
     (+HALF, +HALF, +HALF, 0, 1, 0), (-HALF, +HALF, +HALF, 0, 1, 0)],
    # bottom (y = -HALF, normal -Y)
    [(-HALF, -HALF, +HALF, 0, -1, 0), (+HALF, -HALF, +HALF, 0, -1, 0),
     (+HALF, -HALF, -HALF, 0, -1, 0), (-HALF, -HALF, -HALF, 0, -1, 0)],
    # front (z = +HALF, normal +Z)
    [(-HALF, -HALF, +HALF, 0, 0, 1), (-HALF, +HALF, +HALF, 0, 0, 1),
     (+HALF, +HALF, +HALF, 0, 0, 1), (+HALF, -HALF, +HALF, 0, 0, 1)],
    # back (z = -HALF, normal -Z)
    [(+HALF, -HALF, -HALF, 0, 0, -1), (+HALF, +HALF, -HALF, 0, 0, -1),
     (-HALF, +HALF, -HALF, 0, 0, -1), (-HALF, -HALF, -HALF, 0, 0, -1)],
    # left (x = -HALF, normal -X)
    [(-HALF, -HALF, -HALF, -1, 0, 0), (-HALF, +HALF, -HALF, -1, 0, 0),
     (-HALF, +HALF, +HALF, -1, 0, 0), (-HALF, -HALF, +HALF, -1, 0, 0)],
    # right (x = +HALF, normal +X)
    [(+HALF, -HALF, +HALF, 1, 0, 0), (+HALF, +HALF, +HALF, 1, 0, 0),
     (+HALF, +HALF, -HALF, 1, 0, 0), (+HALF, -HALF, -HALF, 1, 0, 0)],
]

# Body = top + front + back + sides (faces 0, 2, 3, 4, 5).
# Trim = bottom only (face 1).
BODY_FACES = [0, 2, 3, 4, 5]
TRIM_FACES = [1]


def build_vertices_and_indices():
    """Return (positions, normals, body_indices, trim_indices)."""
    positions = []
    normals = []
    body_indices = []
    trim_indices = []
    vert_idx = 0
    for face_idx, verts in enumerate(_FACES):
        for v in verts:
            positions.append((v[0], v[1], v[2]))
            normals.append((v[3], v[4], v[5]))
        # Each face = 2 triangles via vert offsets 0,1,2 + 0,2,3 (CCW from front).
        i0 = vert_idx
        face_indices = [i0, i0 + 1, i0 + 2, i0, i0 + 2, i0 + 3]
        if face_idx in BODY_FACES:
            body_indices.extend(face_indices)
        else:
            trim_indices.extend(face_indices)
        vert_idx += 4
    return positions, normals, body_indices, trim_indices


# ============================================================
# ANIMATION TRACKS
# ============================================================
#
# Both clips animate the same node ("Cube", node index 0) via two
# samplers: one rotation track and one translation track.
#
# Idle: gentle Y-axis bob (translation) over 2s loop.
# Walking: faster yaw rotation oscillation over 0.833s loop (~1.2 Hz).


def quat_from_euler_y(angle_rad):
    """Quaternion for rotation around Y axis only."""
    half = angle_rad * 0.5
    return (0.0, math.sin(half), 0.0, math.cos(half))


def build_idle_keyframes():
    """5 keys over 2.0s: y-translation up/down bob."""
    times = [0.0, 0.5, 1.0, 1.5, 2.0]
    translations = [
        (0.0, 0.00, 0.0),
        (0.0, 0.06, 0.0),
        (0.0, 0.00, 0.0),
        (0.0, -0.06, 0.0),
        (0.0, 0.00, 0.0),
    ]
    return times, translations


def build_walking_keyframes():
    """5 keys over 0.833s: yaw oscillation left/right."""
    times = [0.0, 0.21, 0.42, 0.63, 0.833]
    angles = [0.0, math.radians(15.0), 0.0, math.radians(-15.0), 0.0]
    rotations = [quat_from_euler_y(a) for a in angles]
    return times, rotations


# ============================================================
# BINARY BUFFER PACKING
# ============================================================
#
# All accessor data lives in ONE buffer. Each accessor specifies offset
# + length + element count. Buffer layout (4-byte aligned per spec):
#   [positions vec3*24]
#   [normals   vec3*24]
#   [body_indices    uint16*30]   (10 tris × 3)
#   [trim_indices    uint16*6]    (2 tris × 3)
#   [idle_times      float*5]
#   [idle_translations vec3*5]
#   [walk_times      float*5]
#   [walk_rotations  vec4*5]


def pack_buffer():
    positions, normals, body_indices, trim_indices = build_vertices_and_indices()
    idle_times, idle_translations = build_idle_keyframes()
    walk_times, walk_rotations = build_walking_keyframes()

    chunks = []
    accessors = []
    buffer_views = []

    def add_vec3_block(values, byte_target=34962):  # ARRAY_BUFFER
        """Pack a list of (x,y,z) tuples; return accessor dict + bv dict."""
        buf = b"".join(struct.pack("<fff", v[0], v[1], v[2]) for v in values)
        return _add_block(buf, len(values), "VEC3", 5126, byte_target,
                          mins=_axis_min(values, 3), maxs=_axis_max(values, 3))

    def add_vec4_block(values, byte_target=None):
        buf = b"".join(struct.pack("<ffff", *v) for v in values)
        return _add_block(buf, len(values), "VEC4", 5126, byte_target)

    def add_scalar_floats(values, byte_target=None):
        buf = b"".join(struct.pack("<f", v) for v in values)
        return _add_block(buf, len(values), "SCALAR", 5126, byte_target,
                          mins=[min(values)], maxs=[max(values)])

    def add_ushort_indices(values):
        buf = b"".join(struct.pack("<H", v) for v in values)
        return _add_block(buf, len(values), "SCALAR", 5123, 34963)  # ELEMENT_ARRAY_BUFFER

    def _add_block(buf, count, type_str, component_type, byte_target=None, mins=None, maxs=None):
        # 4-byte align before each new view
        while sum(len(c) for c in chunks) % 4 != 0:
            chunks.append(b"\x00")
        offset = sum(len(c) for c in chunks)
        chunks.append(buf)
        bv = {"buffer": 0, "byteOffset": offset, "byteLength": len(buf)}
        if byte_target is not None:
            bv["target"] = byte_target
        buffer_views.append(bv)
        bv_idx = len(buffer_views) - 1
        accessor = {
            "bufferView": bv_idx,
            "componentType": component_type,
            "count": count,
            "type": type_str,
        }
        if mins is not None:
            accessor["min"] = mins
        if maxs is not None:
            accessor["max"] = maxs
        accessors.append(accessor)
        return len(accessors) - 1

    pos_acc = add_vec3_block(positions)
    norm_acc = add_vec3_block(normals)
    body_idx_acc = add_ushort_indices(body_indices)
    trim_idx_acc = add_ushort_indices(trim_indices)
    idle_time_acc = add_scalar_floats(idle_times)
    idle_xlate_acc = add_vec3_block(idle_translations)
    walk_time_acc = add_scalar_floats(walk_times)
    walk_rot_acc = add_vec4_block(walk_rotations)

    # 4-byte pad the whole buffer end.
    while sum(len(c) for c in chunks) % 4 != 0:
        chunks.append(b"\x00")
    binary_buffer = b"".join(chunks)

    return binary_buffer, accessors, buffer_views, dict(
        pos=pos_acc, norm=norm_acc,
        body_idx=body_idx_acc, trim_idx=trim_idx_acc,
        idle_time=idle_time_acc, idle_xlate=idle_xlate_acc,
        walk_time=walk_time_acc, walk_rot=walk_rot_acc,
    )


def _axis_min(values, dim):
    return [min(v[i] for v in values) for i in range(dim)]


def _axis_max(values, dim):
    return [max(v[i] for v in values) for i in range(dim)]


# ============================================================
# GLTF JSON ASSEMBLY
# ============================================================


def build_gltf_json(buffer_length, accessors, buffer_views, indices):
    """Compose the top-level gltf JSON. References accessor indices
    bundled in `indices` dict from pack_buffer()."""
    return {
        "asset": {"version": "2.0", "generator": "yume synth_test_glb.py"},
        "scene": 0,
        "scenes": [{"name": "Scene", "nodes": [0]}],
        "nodes": [{"name": "Cube", "mesh": 0}],
        "meshes": [
            {
                "name": "Cube",
                "primitives": [
                    {  # surface 0: body (5 faces)
                        "attributes": {
                            "POSITION": indices["pos"],
                            "NORMAL": indices["norm"],
                        },
                        "indices": indices["body_idx"],
                        "material": 0,
                    },
                    {  # surface 1: trim (1 face, the bottom)
                        "attributes": {
                            "POSITION": indices["pos"],
                            "NORMAL": indices["norm"],
                        },
                        "indices": indices["trim_idx"],
                        "material": 1,
                    },
                ],
            }
        ],
        "materials": [
            {
                "name": "body",
                "pbrMetallicRoughness": {
                    "baseColorFactor": [0.78, 0.58, 0.36, 1.0],  # warm tan
                    "metallicFactor": 0.0,
                    "roughnessFactor": 0.85,
                },
            },
            {
                "name": "trim",
                "pbrMetallicRoughness": {
                    "baseColorFactor": [0.30, 0.22, 0.16, 1.0],  # dark brown
                    "metallicFactor": 0.0,
                    "roughnessFactor": 0.90,
                },
            },
        ],
        "animations": [
            {
                "name": "Idle",
                "samplers": [
                    {
                        "input": indices["idle_time"],
                        "output": indices["idle_xlate"],
                        "interpolation": "LINEAR",
                    }
                ],
                "channels": [
                    {
                        "sampler": 0,
                        "target": {"node": 0, "path": "translation"},
                    }
                ],
            },
            {
                "name": "Walking",
                "samplers": [
                    {
                        "input": indices["walk_time"],
                        "output": indices["walk_rot"],
                        "interpolation": "LINEAR",
                    }
                ],
                "channels": [
                    {
                        "sampler": 0,
                        "target": {"node": 0, "path": "rotation"},
                    }
                ],
            },
        ],
        "buffers": [{"byteLength": buffer_length}],
        "bufferViews": buffer_views,
        "accessors": accessors,
    }


# ============================================================
# GLB WRITER
# ============================================================


def write_glb(path):
    binary_buffer, accessors, buffer_views, indices = pack_buffer()
    gltf_json = build_gltf_json(len(binary_buffer), accessors, buffer_views, indices)
    json_text = json.dumps(gltf_json, separators=(",", ":")).encode("utf-8")
    # JSON chunk must be 4-byte aligned (pad with spaces, 0x20).
    while len(json_text) % 4 != 0:
        json_text += b" "
    # BIN chunk must also be 4-byte aligned (pack_buffer already pads).
    bin_data = binary_buffer

    header = struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(json_text) + 8 + len(bin_data))
    json_chunk = struct.pack("<I4s", len(json_text), b"JSON") + json_text
    bin_chunk = struct.pack("<I4s", len(bin_data), b"BIN\x00") + bin_data

    out = header + json_chunk + bin_chunk
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(out)
    return len(out)


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "godot/data/test_assets/cube_anim.glb"
    size = write_glb(out_path)
    print(f"wrote {out_path} ({size} bytes)")
    print("contents:")
    print("  - 1 mesh ('Cube') with 2 surfaces")
    print("  - 2 materials ('body' warm-tan, 'trim' dark-brown)")
    print("  - 2 animations: 'Idle' (2.0s bob), 'Walking' (0.833s yaw oscillation)")
    print()
    print(f"verify with: python3 tools/inspect_glb.py {out_path}")


if __name__ == "__main__":
    main()
