#!/usr/bin/env python3
"""
yume_shadergen — render a Jinja2 shader template using the per-game
shader spec, write a concrete .gdshader to data/<game>/assets/shaders/,
and patch scene.json.ground.mesh.shader to point at it.

Implements ADR 0058 Phase A. Per docs/00_what_yume_is.md, the shader
is projection-configuration which means it's content — and the
content channel is JSON. The template lives in the shared library
(`data/lib/shaders/templates/`); the compiled output is a per-game
build artifact (gitignored).

Spec format (in scene.json under ground.mesh):
    {
      "ground": {
        "mesh": {
          "size": [80, 80],
          "subdivide": 64,
          "shader_template": "ground_biome",
          "biomes": [
            {"name": "dirt",  "color": [0.66, 0.55, 0.32],
             "roughness": 0.92, "metallic": 0.00},
            {"name": "water", "color": [0.19, 0.44, 0.75],
             "roughness": 0.25, "metallic": 0.05, "animate": true},
            ...
          ],
          "features": {
            "blend_softness": 0.10,
            "uv_tile": 30.0,
            "water_animation": {"speed": 0.15, "amplitude": 0.06},
            "displacement": {"scale": 0.6, "offset": -0.5}
          }
        }
      }
    }

After rendering: writes
`data/<game>/assets/shaders/ground.gdshader`, sets
`scene.json.ground.mesh.shader` to the res:// path.

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

try:
    import jinja2
except ImportError:
    print("error: jinja2 not installed. pip install jinja2", file=sys.stderr)
    sys.exit(1)


HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"
TEMPLATES_DIR = DATA_ROOT / "lib" / "shaders" / "templates"


def load_spec(game: str) -> tuple[dict, Path]:
    """Read scene.json, return (mesh_block, scene_path)."""
    scene_path = DATA_ROOT / game / "scene.json"
    if not scene_path.is_file():
        print(f"error: scene.json not found at {scene_path}", file=sys.stderr)
        sys.exit(1)
    scene = json.loads(scene_path.read_text())
    mesh = scene.get("ground", {}).get("mesh", {})
    if "shader_template" not in mesh:
        print(f"[{game}] no ground.mesh.shader_template — nothing to do.")
        sys.exit(0)
    if "biomes" not in mesh:
        print(f"error: ground.mesh.shader_template set but no biomes list", file=sys.stderr)
        sys.exit(1)
    return mesh, scene_path


def render(mesh: dict) -> str:
    template_name = mesh["shader_template"]
    template_path = TEMPLATES_DIR / f"{template_name}.gdshader.j2"
    if not template_path.is_file():
        print(f"error: template not found at {template_path}", file=sys.stderr)
        sys.exit(1)

    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(TEMPLATES_DIR)),
        trim_blocks=False,
        lstrip_blocks=False,
        keep_trailing_newline=True,
    )
    template = env.get_template(f"{template_name}.gdshader.j2")
    biomes = mesh["biomes"]
    features = mesh.get("features", {})
    return template.render(
        template_path=str(template_path.relative_to(REPO_ROOT)),
        spec_path=f"data/<game>/scene.json (ground.mesh)",
        n_biomes=len(biomes),
        biomes=biomes,
        biome_names=[b["name"] for b in biomes],
        features=features,
    )


def write_shader(game: str, source: str) -> tuple[Path, str]:
    """Write to data/<game>/assets/shaders/ground.gdshader. Returns
    (filesystem path, res:// path)."""
    shaders_dir = DATA_ROOT / game / "assets" / "shaders"
    shaders_dir.mkdir(parents=True, exist_ok=True)
    fp = shaders_dir / "ground.gdshader"
    fp.write_text(source)
    res_path = f"res://data/{game}/assets/shaders/ground.gdshader"
    return fp, res_path


def patch_scene(scene_path: Path, res_path: str) -> bool:
    """Set scene.json.ground.mesh.shader = res_path. Returns True if
    file was modified."""
    scene = json.loads(scene_path.read_text())
    mesh = scene["ground"]["mesh"]
    prior = mesh.get("shader", "")
    if prior == res_path:
        return False
    mesh["shader"] = res_path
    scene_path.write_text(json.dumps(scene, indent=2) + "\n")
    return True


def needs_regen(mesh: dict, output_path: Path) -> bool:
    """Compare a hash of the mesh spec + template against the
    compiled shader's first-line hash sentinel. If they match,
    skip regeneration."""
    if not output_path.is_file():
        return True
    template_path = TEMPLATES_DIR / f"{mesh['shader_template']}.gdshader.j2"
    if not template_path.is_file():
        return True
    spec_hash = hashlib.sha256(
        (json.dumps(mesh, sort_keys=True) + template_path.read_text()).encode()
    ).hexdigest()[:12]
    # Read first 4 lines of compiled shader; expect "// hash: <hash>"
    existing = output_path.read_text().splitlines()[:6]
    for line in existing:
        if line.startswith("// hash: "):
            return line.split(": ", 1)[1].strip() != spec_hash
    return True


def main() -> int:
    ap = argparse.ArgumentParser(prog="yume_shadergen")
    ap.add_argument("game", help="game folder name (e.g. demo_aldenmere)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the rendered shader to stdout, no writes")
    ap.add_argument("--force", action="store_true",
                    help="regenerate even if spec hash matches")
    args = ap.parse_args()

    mesh, scene_path = load_spec(args.game)
    biome_names = [b["name"] for b in mesh["biomes"]]
    print(f"[{args.game}] template={mesh['shader_template']} "
          f"biomes={biome_names} features={list(mesh.get('features', {}).keys())}")

    rendered = render(mesh)
    # Prepend spec-hash sentinel for cache check
    spec_hash = hashlib.sha256(
        (json.dumps(mesh, sort_keys=True) +
         (TEMPLATES_DIR / f"{mesh['shader_template']}.gdshader.j2").read_text()).encode()
    ).hexdigest()[:12]
    rendered = f"// hash: {spec_hash}\n" + rendered

    if args.dry_run:
        sys.stdout.write(rendered)
        return 0

    output_path = DATA_ROOT / args.game / "assets" / "shaders" / "ground.gdshader"
    if not args.force and not needs_regen(mesh, output_path):
        print(f"[{args.game}] spec unchanged — skipping (cache hit on {spec_hash})")
        return 0

    fp, res_path = write_shader(args.game, rendered)
    patched = patch_scene(scene_path, res_path)
    print(f"[{args.game}] wrote {fp.relative_to(REPO_ROOT)} ({len(rendered)} bytes)")
    if patched:
        print(f"[{args.game}] patched scene.json shader → {res_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
