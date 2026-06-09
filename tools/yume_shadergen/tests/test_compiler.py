#!/usr/bin/env python3
"""Regression tests for the ADR 0058 Phase B shader DAG compiler.

The compiler (tools/yume_shadergen/compiler.py) generates load-bearing
shaders (e.g. demo_aldenmere's entire ground shader) from a JSON DAG of
primitives — yet had NO test (audit 2026-06-09). This pins the happy path
(a DAG of committed primitives compiles to valid GLSL) and the three
validation raises (unknown primitive / stage mismatch / missing required
input), so a future edit to compiler.py or a primitive can't silently break
shader generation.

Uses the COMMITTED primitives under data/lib/shaders/primitives/ (not a
gitignored demo), so it runs in a fresh clone.

Run:  python3 -m pytest tools/yume_shadergen/tests/test_compiler.py
  or: python3 -m tools.yume_shadergen.tests.test_compiler
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))

from tools.yume_shadergen.compiler import (  # noqa: E402
    load_primitives, compile_dag, CompilerError,
)

PRIMS = load_primitives(REPO / "godot" / "data" / "lib" / "shaders" / "primitives")


def _compile(dag, spec=None):
    return compile_dag(dag, spec or {}, PRIMS).full_source()


def test_primitives_load():
    # The committed primitive set is present + parseable.
    assert "world_pos_from_model" in PRIMS
    assert "heightmap_displace" in PRIMS


def test_happy_single_primitive():
    dag = {"stages": {"vertex": [{"op": "world_pos_from_model", "out": "wp"}]}}
    out = _compile(dag)
    assert "shader_type spatial" in out
    assert "v_world_pos" in out          # the primitive's declared varying
    assert "void vertex()" in out


def test_unknown_primitive_raises():
    dag = {"stages": {"vertex": [{"op": "does_not_exist", "out": "x"}]}}
    try:
        _compile(dag)
        assert False, "expected CompilerError for unknown primitive"
    except CompilerError:
        pass


def test_stage_mismatch_raises():
    # world_pos_from_model is vertex-only; running it in fragment must fail.
    dag = {"stages": {"fragment": [{"op": "world_pos_from_model", "out": "wp"}]}}
    try:
        _compile(dag)
        assert False, "expected CompilerError for stage mismatch"
    except CompilerError:
        pass


def test_missing_required_input_raises():
    # heightmap_displace requires `uv` (vec2) + `map` (sampler2D); omit both.
    dag = {"stages": {"vertex": [{"op": "heightmap_displace", "out": {"normal": "n"}}]}}
    try:
        _compile(dag)
        assert False, "expected CompilerError for missing required input"
    except CompilerError:
        pass


def main() -> int:
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  [ok] {name}")
            except AssertionError as e:
                print(f"  [FAIL] {name}: {e}")
                fails += 1
    print(f"\n{'PASS' if fails == 0 else 'FAIL'}: {fails} failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
