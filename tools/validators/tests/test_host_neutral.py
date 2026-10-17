#!/usr/bin/env python3
"""
Regression test for validate_host_neutral.py (ADR 0087 and ADR 0089,
2026-10-17).

Empirical cases:
- 201 asset references in game JSON were Godot `res://` paths. 15 pointed
  into another demo's folder, and 16 named files that did not exist.
- 17 shader references named `.gdshader` files, and one named a `.tres`
  resource. Two games set 5 and 9 water parameters that the water shader
  does not have, and Godot ignored them with no warning.

The test also checks that the Python path rules (content.py) and the
engine twin (util/asset_path.gd) list the same extensions, so the two
cannot drift.

Run:  python3 -m tools.validators.tests.test_host_neutral
"""

import json
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import content  # noqa: E402
import validate_host_neutral as hn  # noqa: E402

ASSET_PATH_GD = content.REPO / "godot" / "scripts" / "engine" / "util" / "asset_path.gd"
SHADER_LIB_GD = content.REPO / "godot" / "scripts" / "engine" / "util" / "shader_lib.gd"

CASES = [
    ("relative path that exists", {"mesh": "assets/hero.glb"}, 0),
    ("library path that exists", {"texture": "@lib/textures/grass.png"}, 0),
    ("res:// path", {"mesh": "res://data/demo_t/assets/hero.glb"}, 1),
    ("user:// path", {"save": "user://slot.json"}, 1),
    ("path into another game", {"mesh": "../demo_other/assets/hero.glb"}, 1),
    ("absolute path", {"mesh": "/assets/hero.glb"}, 1),
    ("missing file", {"mesh": "assets/gone.glb"}, 1),
    ("Godot scene", {"scene": "scenes/main.tscn"}, 1),
    ("screenshot output name", {"steps": [{"screenshot": "after_move.png"}]}, 0),
    ("prose that ends with an extension", {"_comment": "see the hero.glb"}, 0),
    ("shader name", {"shader": "sky_clouds", "shader_params": {"cloud_coverage": 0.5}}, 0),
    ("unknown shader name", {"shader": "sky_magic"}, 1),
    ("shader file path", {"shader": "@lib/shaders/sky_clouds.gdshader"}, 1),
    ("Godot resource", {"shader": "sky_clouds", "shader_params": {"tex": "@lib/textures/n.tres"}}, 2),
    ("unknown shader parameter", {"shader": "sky_clouds", "shader_params": {"wave_speed": 1}}, 1),
    ("interpreter parameter", {"water": {"shader": "water_stylized", "shader_params": {"plane_size": 80}}}, 1),
    ("shader graph", {"shader_dag": {"stages": {}}, "shader_params": {"anything": 1}}, 0),
]


def run_cases() -> int:
    failures = 0
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "godot" / "data"
        (data / "demo_t" / "assets").mkdir(parents=True)
        (data / "demo_t" / "assets" / "hero.glb").write_bytes(b"x")
        (data / "lib" / "shaders").mkdir(parents=True)
        (data / "lib" / "textures").mkdir(parents=True)
        (data / "lib" / "textures" / "grass.png").write_bytes(b"x")
        (data / "lib" / "shaders" / "sky_clouds.gdshader").write_text(
            "shader_type sky;\nuniform float cloud_coverage = 0.5;\n")
        (data / "lib" / "shaders" / "water_stylized.gdshader").write_text(
            "shader_type spatial;\nuniform float plane_size = 80.0;\n")
        saved = (content.DATA, hn.DATA, hn.REPO)
        content.DATA = hn.DATA = data
        hn.REPO = root
        try:
            for name, doc, want in CASES:
                f = data / "demo_t" / "case.json"
                f.write_text(json.dumps(doc))
                got = len(hn.check_file(f))
                ok = got == want
                print(f"  [{'ok' if ok else 'FAIL'}] {name} -> {got} finding(s)")
                failures += 0 if ok else 1
        finally:
            content.DATA, hn.DATA, hn.REPO = saved
    return failures


def run_twin_check() -> int:
    text = ASSET_PATH_GD.read_text(encoding="utf-8")
    block = text[text.index("const EXTENSIONS"):]
    gd = tuple(re.findall(r'"(\.[a-z0-9]+)"', block[:block.index("]")]))
    ok = set(gd) == set(content.ASSET_EXTENSIONS)
    print(f"  [{'ok' if ok else 'FAIL'}] asset_path.gd and content.py list the same extensions")
    return 0 if ok else 1


def run_shader_twin_check() -> int:
    """content.py reads the names from shader_lib.gd, and each name has a file."""
    ok = "sky_clouds" in content.SHADER_NAMES and "water_normal_tex" in content.INTERPRETER_PARAMS
    real = content.REPO / "godot" / "data" / "lib" / "shaders"
    ok = ok and all((real / f"{n}.gdshader").is_file() for n in content.SHADER_NAMES)
    ok = ok and all(f'"{n}"' in SHADER_LIB_GD.read_text() for n in content.SHADER_NAMES)
    print(f"  [{'ok' if ok else 'FAIL'}] every ShaderLib name has a library shader file")
    return 0 if ok else 1


def main() -> int:
    failures = run_cases() + run_twin_check() + run_shader_twin_check()
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {len(CASES) + 2} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
