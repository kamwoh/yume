#!/usr/bin/env python3
"""
yume_shadergen — compile a JSON shader DAG (ADR 0058 Phase B) into
a concrete .gdshader.

Reads scene.json under `ground.mesh.shader_dag`. Each DAG node
references a primitive from `data/lib/shaders/primitives/<id>.json`;
the compiler walks the graph (vertex stage then fragment stage),
validates types, stitches the primitives' hand-tuned GLSL
fragments together, and emits the output to
`data/<game>/assets/shaders/ground.gdshader`. The ground renderer
loads the graph from that fixed place (ShaderLib.GRAPH_OUTPUT, ADR
0089), so scene.json holds only the graph.

Per docs/guideline/00_what_yume_is.md, the shader is projection-configuration
= content = JSON-driven. No game-specific GLSL files live in the
repo long-term; per-game compiled .gdshaders are build artifacts
(gitignored).

Usage:
    python3 -m tools.yume_shadergen <game>
    python3 -m tools.yume_shadergen <game> --dry-run
    python3 -m tools.yume_shadergen <game> --force
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

from .compiler import (
    CompilerError, compile_dag, load_primitives,
)


HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"
PRIMITIVES_DIR = DATA_ROOT / "lib" / "shaders" / "primitives"
GRAPH_OUTPUT = "assets/shaders/ground.gdshader"  # ShaderLib.GRAPH_OUTPUT


def load_spec(game: str) -> dict:
    """Read scene.json, return the ground mesh block."""
    scene_path = DATA_ROOT / game / "scene.json"
    if not scene_path.is_file():
        print(f"error: scene.json not found at {scene_path}", file=sys.stderr)
        sys.exit(1)
    scene = json.loads(scene_path.read_text())
    mesh = scene.get("ground", {}).get("mesh", {})
    if "shader_dag" not in mesh:
        print(f"[{game}] no ground.mesh.shader_dag — nothing to compile.")
        sys.exit(0)
    return mesh


def compile_shader(mesh: dict, primitives: dict) -> str:
    """Compile the DAG → final .gdshader source string."""
    dag = mesh["shader_dag"]
    # Spec params: everything in mesh except meta keys, plus all
    # shader_params (where texture paths / runtime uniforms live).
    SKIP = {"shader_dag", "shader", "shader_params", "_comment",
            "_comment_template", "_comment_subdivide", "_comment_color"}
    spec_params = {k: v for k, v in mesh.items() if k not in SKIP}
    # Texture paths live in shader_params — DAG references uniform
    # names via $name, which the compiler resolves to the bare name
    # for sampler2D inputs. We expose shader_params keys here for
    # validation; the actual path is set by the engine at runtime.
    for k, v in mesh.get("shader_params", {}).items():
        if not k.startswith("_") and k not in spec_params:
            spec_params[k] = v
    try:
        compiled = compile_dag(dag, spec_params, primitives)
    except CompilerError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
    return compiled.full_source()


def write_shader(game: str, source: str) -> Path:
    """Write to the fixed place where the ground renderer loads the graph:
    data/<game>/assets/shaders/ground.gdshader (ShaderLib.GRAPH_OUTPUT,
    ADR 0089). scene.json keeps only the graph."""
    fp = DATA_ROOT / game / GRAPH_OUTPUT
    fp.parent.mkdir(parents=True, exist_ok=True)
    fp.write_text(source)
    return fp


def needs_regen(mesh: dict, output_path: Path,
                primitives: dict) -> tuple[bool, str]:
    """Hash the DAG + spec params + every referenced primitive's source.
    Returns (regen_required, new_hash)."""
    h = hashlib.sha256()
    h.update(json.dumps(mesh.get("shader_dag", {}), sort_keys=True).encode())
    # Include relevant spec params
    for k in sorted(mesh.keys()):
        if k in {"shader_dag", "shader", "_comment", "_comment_template",
                 "_comment_subdivide", "_comment_color"}:
            continue
        h.update(f"|{k}={json.dumps(mesh[k], sort_keys=True)}".encode())
    # Include each referenced primitive's source
    referenced: set[str] = set()
    for stage_ops in mesh["shader_dag"].get("stages", {}).values():
        for op in stage_ops:
            if "op" in op:
                referenced.add(op["op"])
    for prim_id in sorted(referenced):
        prim_fp = PRIMITIVES_DIR / f"{prim_id}.json"
        if prim_fp.is_file():
            h.update(prim_fp.read_bytes())
    new_hash = h.hexdigest()[:12]
    if not output_path.is_file():
        return True, new_hash
    existing = output_path.read_text().splitlines()[:2]
    for line in existing:
        if line.startswith("// hash: "):
            return line.split(": ", 1)[1].strip() != new_hash, new_hash
    return True, new_hash


def main() -> int:
    ap = argparse.ArgumentParser(prog="yume_shadergen")
    ap.add_argument("game", help="game folder name (e.g. demo_aldenmere)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the compiled shader to stdout, no writes")
    ap.add_argument("--force", action="store_true",
                    help="regenerate even if hash matches")
    args = ap.parse_args()

    mesh = load_spec(args.game)
    primitives = load_primitives(PRIMITIVES_DIR)
    referenced = sorted({op.get("op", "")
                         for ops in mesh["shader_dag"].get("stages", {}).values()
                         for op in ops})
    print(f"[{args.game}] DAG: {len(referenced)} primitive(s) referenced: "
          f"{referenced}")

    output_path = DATA_ROOT / args.game / GRAPH_OUTPUT
    needs, new_hash = needs_regen(mesh, output_path, primitives)
    if not args.force and not needs and not args.dry_run:
        print(f"[{args.game}] spec unchanged — skipping (cache hit on {new_hash})")
        return 0

    rendered = compile_shader(mesh, primitives)
    rendered = f"// hash: {new_hash}\n// AUTO-GENERATED by tools/yume_shadergen — edit primitives or scene.json shader_dag\n" + rendered

    if args.dry_run:
        sys.stdout.write(rendered)
        return 0

    fp = write_shader(args.game, rendered)
    print(f"[{args.game}] wrote {fp.relative_to(REPO_ROOT)} ({len(rendered)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
