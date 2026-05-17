#!/usr/bin/env python3
"""
inspect_glb.py — print the contents of a .glb file (ADR 0046 Phase B.3).

Authors use this to discover the slot names + clip names of a .glb so
they can write the right `clip_alias` mappings + `material_overrides`
in entity defs. Without inspect tooling, authors GUESS slot names and
silently get fallback materials (per ADR 0046 tech-director gate).

Usage:
    python3 tools/inspect_glb.py path/to/file.glb

Output (for a typical character .glb):
    === path/to/villager.glb ===
    nodes:
        0  root
        1  body (mesh=0)
        2  head (mesh=1)
        3  Skeleton3D
    meshes:
        0  body_mesh
            surface 0: material 'body_skin' (#a0c0e0)
            surface 1: material 'belt_leather'
        1  head_mesh
            surface 0: material 'face_skin'
    materials:
        0  body_skin           albedo=(0.627, 0.753, 0.878, 1.0)
        1  belt_leather        albedo=(0.439, 0.282, 0.157, 1.0)
        2  face_skin           albedo=(0.937, 0.792, 0.671, 1.0)
    animations (AnimationPlayer clips):
        Idle              duration=2.000  tracks=18
        Walking           duration=0.833  tracks=18
        Running           duration=0.667  tracks=18
        Attack            duration=0.500  tracks=12

To use in an entity def's visual block, copy material names verbatim
into material_overrides and clip names into animation_state_rules:

    "visual": {
      "mesh": "res://data/test_assets/villager.glb",
      "animation_state_rules": [
        {"if_velocity_gt": 0.1, "state": "walk", "clip_alias": "Walking"},
        {"default": "idle", "clip_alias": "Idle"}
      ],
      "material_overrides": {
        "body_skin": "#a0c0e0",
        "belt_leather": "#704020"
      }
    }

Pure-stdlib implementation: .glb files are JSON+binary chunk
containers (12-byte header + N chunks, each `length + type + data`).
The JSON chunk has everything we need.
"""

import json
import struct
import sys
from pathlib import Path


GLB_MAGIC = b"glTF"
CHUNK_TYPE_JSON = b"JSON"
CHUNK_TYPE_BIN = b"BIN\x00"


def parse_glb(path):
    """Parse a .glb's JSON chunk. Returns the parsed dict + binary
    buffer (which we don't use for printing but exposes for future
    callers)."""
    data = Path(path).read_bytes()
    if len(data) < 12:
        raise ValueError(f"{path}: too small to be a .glb")
    magic, version, total_len = struct.unpack_from("<4sII", data, 0)
    if magic != GLB_MAGIC:
        raise ValueError(f"{path}: not a .glb (magic = {magic!r})")
    if version != 2:
        raise ValueError(f"{path}: GLB version {version} (this tool expects 2)")

    pos = 12
    json_dict = None
    bin_buf = b""
    while pos < total_len:
        chunk_len, chunk_type = struct.unpack_from("<I4s", data, pos)
        pos += 8
        chunk_data = data[pos : pos + chunk_len]
        pos += chunk_len
        if chunk_type == CHUNK_TYPE_JSON:
            json_dict = json.loads(chunk_data.decode("utf-8"))
        elif chunk_type == CHUNK_TYPE_BIN:
            bin_buf = chunk_data
        # else: ignore unknown chunk types (forward-compat per spec)
    if json_dict is None:
        raise ValueError(f"{path}: no JSON chunk found")
    return json_dict, bin_buf


def fmt_color(rgba):
    """Format an [r,g,b,a] float-array as a one-liner."""
    if not rgba:
        return ""
    if len(rgba) == 4:
        return "albedo=(%.3f, %.3f, %.3f, %.3f)" % tuple(rgba)
    if len(rgba) == 3:
        return "albedo=(%.3f, %.3f, %.3f)" % tuple(rgba)
    return "albedo=%s" % rgba


def print_nodes(gltf):
    nodes = gltf.get("nodes", [])
    if not nodes:
        return
    print("nodes:")
    for i, n in enumerate(nodes):
        name = n.get("name", "")
        bits = [f"    {i:3d}  {name!s:25s}"]
        if "mesh" in n:
            bits.append(f"mesh={n['mesh']}")
        if "skin" in n:
            bits.append(f"skin={n['skin']}")
        if "camera" in n:
            bits.append("camera")
        if "children" in n:
            bits.append(f"children={n['children']}")
        print(" ".join(bits).rstrip())


def print_meshes(gltf):
    meshes = gltf.get("meshes", [])
    materials = gltf.get("materials", [])
    if not meshes:
        return
    print("meshes:")
    for i, m in enumerate(meshes):
        name = m.get("name", f"mesh_{i}")
        print(f"    {i:3d}  {name}")
        for j, prim in enumerate(m.get("primitives", [])):
            if "material" in prim:
                mat_idx = prim["material"]
                mat_name = materials[mat_idx].get("name", f"material_{mat_idx}") if mat_idx < len(materials) else "?"
                # Pull albedo color if available for the one-liner.
                color = ""
                if mat_idx < len(materials):
                    pbr = materials[mat_idx].get("pbrMetallicRoughness", {})
                    rgba = pbr.get("baseColorFactor")
                    if rgba:
                        color = " " + _short_color_hex(rgba)
                print(f"        surface {j}: material '{mat_name}'{color}")
            else:
                print(f"        surface {j}: (no material)")


def _short_color_hex(rgba):
    """Convert [r,g,b,a] float 0-1 to '#RRGGBB' for one-liner display."""
    if len(rgba) < 3:
        return ""
    r = max(0, min(255, int(round(rgba[0] * 255))))
    g = max(0, min(255, int(round(rgba[1] * 255))))
    b = max(0, min(255, int(round(rgba[2] * 255))))
    return "(#%02x%02x%02x)" % (r, g, b)


def print_materials(gltf):
    materials = gltf.get("materials", [])
    if not materials:
        return
    print("materials:")
    for i, m in enumerate(materials):
        name = m.get("name", f"material_{i}")
        pbr = m.get("pbrMetallicRoughness", {})
        rgba = pbr.get("baseColorFactor")
        color_str = fmt_color(rgba) if rgba else ""
        print(f"    {i:3d}  {name:30s} {color_str}")


def print_animations(gltf):
    anims = gltf.get("animations", [])
    if not anims:
        print("animations (AnimationPlayer clips): (none)")
        return
    print("animations (AnimationPlayer clips):")
    accessors = gltf.get("accessors", [])
    for a in anims:
        name = a.get("name", "(unnamed)")
        track_count = len(a.get("channels", []))
        # Duration = max time across all sampler inputs. Each sampler
        # references an accessor whose max[0] is the last keyframe time.
        max_time = 0.0
        for s in a.get("samplers", []):
            input_idx = s.get("input")
            if input_idx is not None and input_idx < len(accessors):
                acc = accessors[input_idx]
                mx = acc.get("max", [])
                if mx and isinstance(mx[0], (int, float)):
                    max_time = max(max_time, float(mx[0]))
        print(f"    {name:25s} duration={max_time:.3f}  tracks={track_count}")


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        print("usage: inspect_glb.py <path/to/file.glb>", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    if not Path(path).exists():
        print(f"error: {path} does not exist", file=sys.stderr)
        sys.exit(1)
    try:
        gltf, _bin = parse_glb(path)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"=== {path} ===")
    print_nodes(gltf)
    print_meshes(gltf)
    print_materials(gltf)
    print_animations(gltf)


if __name__ == "__main__":
    main()
