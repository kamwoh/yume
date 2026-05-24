#!/usr/bin/env python3
"""
Generate collision-primitive .glbs at data/lib/assets/meshes/.

Convention: every collision primitive is bottom-rooted (bbox.y starts at
0, ends at 1.0) in its own coordinate frame. The entity referencing it
applies state.scale to bring the shape to actual world dimensions.

Two primitives ship today:

- primitive_cylinder.glb        (radius=0.1, height=1.0)
  Trees reference this as their properties.collision_mesh — the wide
  canopy mesh stays the visual, but the collider becomes a narrow
  trunk. Player walks between trees. The validator reads its bbox to
  derive aabb_extents (for BoxShape3D static collision).

- primitive_humanoid_capsule.glb (radius=0.15, height=1.0)
  CharacterBody3D templates in @lib.physics.bodies reference this as
  collision_shape.mesh. The engine reads its bbox at build time to
  derive a CapsuleShape3D (radius = bbox.x/2, height = bbox.y).
  Author humanoid proportions ONCE here; per-entity scale via
  state.scale.

Both are tall thin cylinder meshes — the engine only reads bbox,
not the actual geometry, so a cylinder is fine for a capsule's bbox.
The shape TYPE (box vs capsule) is set by the entity's body config;
this primitive only provides the dimensions.

Pure stdlib — no pygltflib / trimesh dependency.

Usage:
    python3 tools/gen_primitive_cylinder.py
"""
from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[1]
OUT_DIR = REPO_ROOT / "godot" / "data" / "lib" / "assets" / "meshes"


def build_cylinder(radius: float = 0.1, height: float = 1.0, segments: int = 16) -> bytes:
    """Build a cylinder mesh: side wall + top cap + bottom cap.
    Bottom centered at (0,0,0); top at (0, height, 0)."""
    import math

    # Vertices: bottom ring + top ring + bottom center + top center
    positions: list[tuple[float, float, float]] = []
    normals: list[tuple[float, float, float]] = []

    # Side wall: paired bottom + top vertices, normal pointing radially out.
    # Each segment contributes 2 quad-pairs (= 4 vertices) but we share via
    # the ring layout. For simplicity emit ring duplicated per segment for
    # crisp normals.
    for i in range(segments):
        theta = (i / segments) * 2 * math.pi
        x = math.cos(theta) * radius
        z = math.sin(theta) * radius
        nx, nz = math.cos(theta), math.sin(theta)
        # Bottom ring
        positions.append((x, 0.0, z))
        normals.append((nx, 0.0, nz))
        # Top ring
        positions.append((x, height, z))
        normals.append((nx, 0.0, nz))

    side_vert_count = segments * 2

    # Bottom cap fan: center + ring (normals point down)
    bot_center_idx = len(positions)
    positions.append((0.0, 0.0, 0.0))
    normals.append((0.0, -1.0, 0.0))
    for i in range(segments):
        theta = (i / segments) * 2 * math.pi
        positions.append((math.cos(theta) * radius, 0.0, math.sin(theta) * radius))
        normals.append((0.0, -1.0, 0.0))

    # Top cap fan: center + ring (normals point up)
    top_center_idx = len(positions)
    positions.append((0.0, height, 0.0))
    normals.append((0.0, 1.0, 0.0))
    for i in range(segments):
        theta = (i / segments) * 2 * math.pi
        positions.append((math.cos(theta) * radius, height, math.sin(theta) * radius))
        normals.append((0.0, 1.0, 0.0))

    # Indices
    indices: list[int] = []
    # Side wall — connect each pair
    for i in range(segments):
        b0 = i * 2
        t0 = i * 2 + 1
        b1 = ((i + 1) % segments) * 2
        t1 = ((i + 1) % segments) * 2 + 1
        # Quad split into 2 triangles, CCW from outside
        indices.extend([b0, t0, t1])
        indices.extend([b0, t1, b1])

    # Bottom cap — winding CCW when viewed from below
    for i in range(segments):
        a = bot_center_idx + 1 + i
        b = bot_center_idx + 1 + ((i + 1) % segments)
        indices.extend([bot_center_idx, b, a])

    # Top cap — winding CCW when viewed from above
    for i in range(segments):
        a = top_center_idx + 1 + i
        b = top_center_idx + 1 + ((i + 1) % segments)
        indices.extend([top_center_idx, a, b])

    # Pack binary buffers
    pos_bytes = b"".join(struct.pack("<fff", *p) for p in positions)
    nrm_bytes = b"".join(struct.pack("<fff", *n) for n in normals)
    idx_bytes = struct.pack("<%dH" % len(indices), *indices)

    # Pad each buffer to 4-byte alignment
    def pad4(b: bytes) -> bytes:
        return b + b"\x00" * ((4 - (len(b) % 4)) % 4)

    pos_bytes = pad4(pos_bytes)
    nrm_bytes = pad4(nrm_bytes)
    idx_bytes = pad4(idx_bytes)

    bin_buffer = pos_bytes + nrm_bytes + idx_bytes

    # bbox for accessor min/max
    min_pos = [min(p[i] for p in positions) for i in range(3)]
    max_pos = [max(p[i] for p in positions) for i in range(3)]

    pos_offset = 0
    pos_byte_length = len(pos_bytes)
    nrm_offset = pos_offset + pos_byte_length
    nrm_byte_length = len(nrm_bytes)
    idx_offset = nrm_offset + nrm_byte_length
    idx_byte_length = len(idx_bytes)

    doc = {
        "asset": {"version": "2.0", "generator": "yume/gen_primitive_cylinder.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [{
            "primitives": [{
                "attributes": {"POSITION": 0, "NORMAL": 1},
                "indices": 2,
                "mode": 4  # TRIANGLES
            }]
        }],
        "buffers": [{"byteLength": len(bin_buffer)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": pos_offset, "byteLength": pos_byte_length, "target": 34962},
            {"buffer": 0, "byteOffset": nrm_offset, "byteLength": nrm_byte_length, "target": 34962},
            {"buffer": 0, "byteOffset": idx_offset, "byteLength": idx_byte_length, "target": 34963},
        ],
        "accessors": [
            {
                "bufferView": 0, "componentType": 5126, "count": len(positions),
                "type": "VEC3", "min": min_pos, "max": max_pos
            },
            {
                "bufferView": 1, "componentType": 5126, "count": len(normals),
                "type": "VEC3"
            },
            {
                "bufferView": 2, "componentType": 5123, "count": len(indices),
                "type": "SCALAR"
            }
        ]
    }

    json_chunk = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    json_chunk = json_chunk + b" " * ((4 - (len(json_chunk) % 4)) % 4)

    bin_chunk_header = struct.pack("<II", len(bin_buffer), 0x004E4942)  # 'BIN\0'
    json_chunk_header = struct.pack("<II", len(json_chunk), 0x4E4F534A)  # 'JSON'

    total_length = 12 + 8 + len(json_chunk) + 8 + len(bin_buffer)
    header = struct.pack("<III", 0x46546C67, 2, total_length)  # 'glTF', version, length

    return (
        header
        + json_chunk_header + json_chunk
        + bin_chunk_header + bin_buffer
    )


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    primitives = [
        ("primitive_cylinder.glb",         0.1,  1.0, "trunk-narrow trees / posts"),
        ("primitive_humanoid_capsule.glb", 0.15, 1.0, "humanoid CapsuleShape3D"),
    ]
    for name, r, h, purpose in primitives:
        data = build_cylinder(radius=r, height=h, segments=16)
        path = OUT_DIR / name
        path.write_bytes(data)
        print(f"wrote {path.relative_to(REPO_ROOT)}  "
              f"(r={r}, h={h}, {len(data)}b) — {purpose}")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
