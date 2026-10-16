#!/usr/bin/env python3
"""
Regression test for validate_host_neutral.py (ADR 0087, 2026-10-17).

Empirical case: 201 asset references in game JSON were Godot `res://`
paths. 15 pointed into another demo's folder, and 16 named files that did
not exist. A second interpreter cannot read any of them.

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

CASES = [
    ("relative path that exists", {"mesh": "assets/hero.glb"}, 0),
    ("library path that exists", {"shader": "@lib/shaders/toon.gdshader"}, 0),
    ("res:// path", {"mesh": "res://data/demo_t/assets/hero.glb"}, 1),
    ("user:// path", {"save": "user://slot.json"}, 1),
    ("path into another game", {"mesh": "../demo_other/assets/hero.glb"}, 1),
    ("absolute path", {"mesh": "/assets/hero.glb"}, 1),
    ("missing file", {"mesh": "assets/gone.glb"}, 1),
    ("Godot scene", {"scene": "scenes/main.tscn"}, 1),
    ("screenshot output name", {"steps": [{"screenshot": "after_move.png"}]}, 0),
    ("prose that ends with an extension", {"_comment": "see the hero.glb"}, 0),
]


def run_cases() -> int:
    failures = 0
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "godot" / "data"
        (data / "demo_t" / "assets").mkdir(parents=True)
        (data / "demo_t" / "assets" / "hero.glb").write_bytes(b"x")
        (data / "lib" / "shaders").mkdir(parents=True)
        (data / "lib" / "shaders" / "toon.gdshader").write_text("x")
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


def main() -> int:
    failures = run_cases() + run_twin_check()
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {len(CASES) + 1} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
