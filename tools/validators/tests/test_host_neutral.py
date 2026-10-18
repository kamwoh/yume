#!/usr/bin/env python3
"""
Regression test for validate_host_neutral.py (ADR 0087, ADR 0089 and
ADR 0090, 2026-10-18).

Empirical cases:
- 201 asset references in game JSON were Godot `res://` paths. 15 pointed
  into another demo's folder, and 16 named files that did not exist.
- 17 shader references named `.gdshader` files, and one named a `.tres`
  resource. Two games set 5 and 9 water parameters that the water shader
  does not have, and Godot ignored them with no warning.
- Sokoban's music slider set a "Music" bus that did not exist. Ten scenes
  set `lighting.ambient.color` and `energy`, which the engine never read.

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

ROVER = {"body_type": "articulated", "root": "base",
        "links": {"base": {"shape": {"type": "box", "size": [1, 1, 1]}},
                  "wheel": {"shape": {"type": "cylinder", "radius": 0.1, "height": 0.04, "axis": "x"}}},
        "joints": [{"type": "hinge", "parent": "base", "child": "wheel", "at": [0.5, 0, 0], "axis": [1, 0, 0],
                    "motor": {"target_velocity": "self.state.cmd", "max_torque": 2}, "report": "wheel"}]}

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
    # ADR 0090 vocabularies. A fourth item names the file in the game folder.
    ("spec key names", {"actions": [{"name": "jump", "keys": ["Space", "W", "Numpad2"]},
                                    {"name": "fire", "mouse_button": "Left"}]}, 0, "ui/input.json"),
    ("host key name", {"actions": [{"name": "jump", "key": "Kp 2"}]}, 1, "ui/input.json"),
    ("unknown mouse button", {"actions": [{"name": "fire", "mouse_button": "XButton1"}]}, 1, "ui/input.json"),
    ("rebind to a binding", {"type": "set_input_mapping", "action": "jump", "key": "value"}, 0),
    ("rebind to a host key", {"type": "set_input_mapping", "action": "jump", "key": "Kp 2"}, 1),
    ("audio channel", {"type": "set_audio_bus_volume", "bus": "music", "linear": "value"}, 0),
    ("host bus name", {"type": "set_audio_bus_volume", "bus": "Music", "linear": "value"}, 1),
    ("lighting fields", {"lighting": {"ambient": {"color_day": "#fff", "_note": "x"},
                                      "fog": {"density": 0.01}}, "render": {"msaa_3d": "2x"}}, 0, "scene.json"),
    ("dead lighting field", {"lighting": {"ambient": {"color": "#fff", "energy": 0.3}}}, 2, "scene.json"),
    ("lighting field in an entity file", {"lighting": {"glow_radius": 2}}, 0),
    ("physics preset", {"physics": {"$extends": "@lib.physics.bodies.static_wall"}}, 0),
    ("unknown body type", {"physics": {"body_type": "ghost", "collision_shape": {"type": "box"}}}, 1),
    ("unknown layer and raw bits", {"physics": {"body_type": "static", "collision_layer": ["walls"],
                                                "collision_mask": 6}}, 2),
    ("unknown physics field", {"physics": {"$extends": "@lib.physics.bodies.static_wall", "bounce": 1}}, 1),
    # ADR 0091 — articulated bodies.
    ("articulated rover", {"physics": ROVER}, 0),
    ("articulated: root is not a link", {"physics": {**ROVER, "root": "chassis"}}, 1),
    ("articulated: unknown joint type and a slider motor",
     {"physics": {**ROVER, "joints": [{**ROVER["joints"][0], "type": "slider"}]}}, 4),
    ("articulated: unknown link, joint and motor fields",
     {"physics": {**ROVER, "links": {**ROVER["links"], "base": {"shape": {"type": "box"}, "color": "red"}},
                  "joints": [{**ROVER["joints"][0], "spring": 1,
                              "motor": {"target_velocity": 1, "max_force": 2}}]}}, 3),
    ("articulated: a link with no joint", {"physics": {**ROVER, "links": {**ROVER["links"], "spare": {}}}}, 1),
    ("links on a rigid body", {"physics": {"body_type": "rigid", "links": {}}}, 1),
    ("articulated: shape axis", {"physics": {**ROVER, "links": {**ROVER["links"],
                                 "wheel": {"shape": {"type": "cylinder", "axis": "w"}}}}}, 1),
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
            for name, doc, want, *where in CASES:
                f = data / "demo_t" / (where[0] if where else "case.json")
                f.parent.mkdir(parents=True, exist_ok=True)
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
