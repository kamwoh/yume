"""
mock.py — placeholder backend that emits visually-distinct stand-in
assets without any external API calls.

Textures: a 2D PNG with a deterministic gradient + a 24px text band
across the bottom containing the prompt's first ~40 chars. Each
prompt produces a different gradient (hashed → HSV) so the eye can
tell them apart visually at-a-glance. Useful for:
    - Smoke-testing the pipeline end-to-end
    - Filling in defaults for games without real generation
    - Comparing layout / placement before art is ready

Meshes: re-uses the cube generator from tools/synth_test_glb.py with
prompt-deterministic colors. The output .glb is a valid Godot-
loadable PackedScene with 2 surfaces + 2 clips.

Pure stdlib — no Pillow, no numpy. PNG written via the `png` module
of stdlib... wait, Python stdlib doesn't ship PNG. So we hand-write
the IHDR + IDAT + IEND chunks. ~100 LoC, ugly but dependency-free.
"""

import hashlib
import struct
import zlib
from pathlib import Path
from typing import Iterable

from .base import Backend


def _hash_to_hue(text: str) -> float:
    """Map a string to a deterministic 0..1 hue value."""
    h = hashlib.sha1(text.encode("utf-8")).digest()
    return int.from_bytes(h[:4], "big") / (2 ** 32)


def _hsv_to_rgb(h: float, s: float, v: float) -> tuple:
    """h, s, v in 0..1. Returns (r, g, b) in 0..255 ints."""
    i = int(h * 6) % 6
    f = h * 6 - int(h * 6)
    p = v * (1 - s)
    q = v * (1 - f * s)
    t = v * (1 - (1 - f) * s)
    if i == 0:
        r, g, b = v, t, p
    elif i == 1:
        r, g, b = q, v, p
    elif i == 2:
        r, g, b = p, v, t
    elif i == 3:
        r, g, b = p, q, v
    elif i == 4:
        r, g, b = t, p, v
    else:
        r, g, b = v, p, q
    return int(r * 255), int(g * 255), int(b * 255)


# ============================================================
# PNG WRITER (stdlib only — no Pillow)
# ============================================================


def _png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    """Build one IHDR/IDAT/IEND chunk: length + type + data + CRC32."""
    crc = zlib.crc32(chunk_type + data)
    return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)


def _write_png(path: Path, pixels: list[list[tuple]], width: int, height: int) -> None:
    """Write an RGB PNG. `pixels` is a list of rows, each row is a
    list of (r, g, b) tuples. width × height must match."""
    sig = b"\x89PNG\r\n\x1a\n"

    # IHDR: 13 bytes — width, height, bit_depth, color_type, ...
    ihdr_data = struct.pack(
        ">IIBBBBB", width, height, 8, 2, 0, 0, 0  # 8-bit RGB, no interlace
    )

    # IDAT: scanlines, each prefixed by filter byte (0 = None).
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for r, g, b in row:
            raw.append(r & 0xFF)
            raw.append(g & 0xFF)
            raw.append(b & 0xFF)
    compressed = zlib.compress(bytes(raw))

    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(sig)
        f.write(_png_chunk(b"IHDR", ihdr_data))
        f.write(_png_chunk(b"IDAT", compressed))
        f.write(_png_chunk(b"IEND", b""))


# ============================================================
# PIXEL GENERATION
# ============================================================


def _build_gradient(width: int, height: int, base_rgb: tuple, accent_rgb: tuple):
    """Diagonal gradient from base→accent. Returns a list-of-list-of-tuples."""
    rows = []
    for y in range(height):
        row = []
        for x in range(width):
            t = (x + y) / max(1, width + height - 2)
            r = int(base_rgb[0] * (1 - t) + accent_rgb[0] * t)
            g = int(base_rgb[1] * (1 - t) + accent_rgb[1] * t)
            b = int(base_rgb[2] * (1 - t) + accent_rgb[2] * t)
            row.append((r, g, b))
        rows.append(row)
    return rows


def _draw_label_band(rows: list, text: str, band_height: int = 24) -> None:
    """Darken the bottom `band_height` rows so the prompt text is
    legible if rendered atop. We can't draw text (no font lib), so
    instead embed the text by setting pixel patterns deterministically
    based on the text bytes — readable enough to identify outputs by
    name in a file browser thumbnail."""
    if not rows:
        return
    height = len(rows)
    width = len(rows[0])
    # Darken the band.
    for y in range(max(0, height - band_height), height):
        for x in range(width):
            r, g, b = rows[y][x]
            rows[y][x] = (r // 3, g // 3, b // 3)
    # Embed text bytes as pixel-on/off pattern in the band (one pixel
    # per text byte). Visible as a thin stripe of light pixels in the
    # darkened band.
    if not text:
        return
    stripe_y = height - band_height // 2
    if 0 <= stripe_y < height:
        text_bytes = text.encode("utf-8")[: min(len(text), width // 2)]
        for i, byte in enumerate(text_bytes):
            x = (i * 2) % width
            # Light pixels for "on" bits.
            for bit in range(8):
                if byte & (1 << bit) and x < width:
                    rows[stripe_y][x] = (240, 240, 240)
                x += 1
                if x >= width:
                    break


# ============================================================
# MESH (GLB) GENERATION — reuses synth_test_glb logic
# ============================================================


def _write_mock_glb(out_path: Path, body_rgb: tuple, trim_rgb: tuple) -> None:
    """Emit a cube .glb with prompt-determined colors. Reuses the
    synth_test_glb.py module's pure-stdlib generator."""
    import importlib.util
    here = Path(__file__).resolve()
    # tools/yume_assetgen/backends/mock.py → tools/synth_test_glb.py
    synth_path = here.parent.parent.parent / "synth_test_glb.py"
    if not synth_path.exists():
        raise FileNotFoundError(
            f"synth_test_glb.py not at {synth_path} — needed by mock mesh gen"
        )
    spec = importlib.util.spec_from_file_location("synth_test_glb", synth_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # Customize body + trim colors by monkeypatching the JSON builder
    # (the synth module defines colors inline in build_gltf_json).
    # Easier path: write the .glb then re-edit its JSON chunk.
    out_path.parent.mkdir(parents=True, exist_ok=True)
    module.write_glb(str(out_path))
    _patch_glb_material_colors(out_path, body_rgb, trim_rgb)


def _patch_glb_material_colors(path: Path, body_rgb: tuple, trim_rgb: tuple) -> None:
    """Re-open a .glb, re-encode its JSON chunk with new material
    baseColorFactor values, write back. The BIN chunk is untouched."""
    import json as _json

    data = path.read_bytes()
    magic, version, total_len = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF":
        return
    # Read JSON chunk.
    pos = 12
    json_len, json_type = struct.unpack_from("<I4s", data, pos)
    pos += 8
    json_bytes = data[pos : pos + json_len]
    pos += json_len
    # BIN chunk follows.
    bin_len, bin_type = struct.unpack_from("<I4s", data, pos)
    pos += 8
    bin_data = data[pos : pos + bin_len]

    gltf = _json.loads(json_bytes.decode("utf-8"))
    if "materials" in gltf and len(gltf["materials"]) >= 2:
        gltf["materials"][0].setdefault("pbrMetallicRoughness", {})[
            "baseColorFactor"
        ] = [body_rgb[0] / 255, body_rgb[1] / 255, body_rgb[2] / 255, 1.0]
        gltf["materials"][1].setdefault("pbrMetallicRoughness", {})[
            "baseColorFactor"
        ] = [trim_rgb[0] / 255, trim_rgb[1] / 255, trim_rgb[2] / 255, 1.0]

    new_json = _json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    while len(new_json) % 4 != 0:
        new_json += b" "

    new_total = 12 + 8 + len(new_json) + 8 + len(bin_data)
    header = struct.pack("<4sII", b"glTF", 2, new_total)
    json_chunk = struct.pack("<I4s", len(new_json), b"JSON") + new_json
    bin_chunk = struct.pack("<I4s", len(bin_data), b"BIN\x00") + bin_data
    path.write_bytes(header + json_chunk + bin_chunk)


# ============================================================
# BACKEND
# ============================================================


class MockBackend(Backend):
    """Pure-stdlib placeholder backend.

    Configurable via backend_config.mock:
        - output_size: [width, height] (default [512, 512])
        - noise: 0..1 — adds salt+pepper noise (default 0)
    """

    def name(self) -> str:
        return "mock"

    def supports_texture(self) -> bool:
        return True

    def supports_mesh(self) -> bool:
        return True

    def generate_texture(
        self,
        prompt: str,
        out_path: Path,
        size: Iterable[int] = (512, 512),
    ) -> Path:
        width, height = list(size) if size else (512, 512)
        # Base color from prompt hash; accent shifted 0.35 hue.
        hue = _hash_to_hue(prompt)
        base = _hsv_to_rgb(hue, 0.55, 0.85)
        accent = _hsv_to_rgb((hue + 0.35) % 1.0, 0.65, 0.95)
        rows = _build_gradient(width, height, base, accent)
        _draw_label_band(rows, prompt[:64])
        _write_png(out_path, rows, width, height)
        return out_path

    def generate_mesh(
        self,
        prompt: str,
        out_path: Path,
    ) -> Path:
        hue = _hash_to_hue(prompt)
        body = _hsv_to_rgb(hue, 0.5, 0.8)
        trim = _hsv_to_rgb((hue + 0.5) % 1.0, 0.6, 0.4)
        _write_mock_glb(out_path, body, trim)
        return out_path
