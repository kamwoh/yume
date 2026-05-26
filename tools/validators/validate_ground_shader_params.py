#!/usr/bin/env python3
"""Static validator: ground shader uniforms must live in
`ground.mesh.shader_params`, not at `ground.mesh` top-level.

Empirical case 2026-05-26: compose_world.py wrote
`ground.mesh.height_scale = 8.0` and `ground.mesh.height_offset =
-0.5` as top-level mesh keys. But ground_renderer.gd:203-215 only
forwards the `shader_params` dict to the ShaderMaterial (plus
auto-sets `plane_size`). Mesh-level keys are never read. The shader
silently fell back to its own `uniform float height_scale = 2.0`
default — so a re-roll bumping height_scale to 8.0 produced ZERO
visible change. Looked like the heightmap wasn't working.

Same bug CLASS as state.facing/state.yaw: a value written to a key
the consumer doesn't read. No error, no crash — the feature just
silently uses defaults.

This validator:
  1. Reads scene.json ground.mesh.
  2. If a `shader` is set, loads the .gdshader and extracts every
     `uniform <type> <name>` declaration.
  3. For each uniform name, if it appears at ground.mesh top-level
     (NOT inside shader_params) → ERROR (it's silently ignored).
     Exception: `plane_size` (ground_renderer auto-sets it from
     cfg.size, so authoring it at mesh-level is harmless/ignored —
     downgraded to a note, not an error).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


# ground_renderer.gd auto-sets these; authoring them anywhere is
# tolerated (the engine overrides).
ENGINE_AUTOSET_UNIFORMS = {"plane_size"}

UNIFORM_RE = re.compile(
    r"^\s*uniform\s+\w+\s+(\w+)", re.MULTILINE
)


def _shader_uniforms(shader_path: Path) -> set[str]:
    if not shader_path.exists():
        return set()
    text = shader_path.read_text()
    return set(UNIFORM_RE.findall(text))


def _resolve_res_path(res_path: str, repo_root: Path) -> Path:
    """res://X → <repo>/godot/X."""
    rel = res_path.removeprefix("res://")
    return repo_root / "godot" / rel


def validate_game(game_dir: Path, repo_root: Path) -> list[dict]:
    findings: list[dict] = []
    scene_path = game_dir / "scene.json"
    if not scene_path.exists():
        return findings
    try:
        scene = json.loads(scene_path.read_text())
    except json.JSONDecodeError as e:
        return [{"severity": "error", "field": "<json>",
                 "message": f"scene.json parse error: {e}"}]

    mesh = scene.get("ground", {}).get("mesh", {})
    shader = str(mesh.get("shader", "")).strip()
    if not shader:
        return findings  # no shader, nothing to check

    shader_file = _resolve_res_path(shader, repo_root)
    uniforms = _shader_uniforms(shader_file)
    if not uniforms:
        findings.append({
            "severity": "warn", "field": "shader",
            "message": (
                f"could not read uniforms from {shader_file} "
                f"(missing or unparseable) — cannot verify shader_params"
            ),
        })
        return findings

    shader_params = mesh.get("shader_params", {})
    if not isinstance(shader_params, dict):
        shader_params = {}

    # Any uniform name appearing at mesh-level (but not in shader_params)
    # is silently ignored by ground_renderer.
    for uname in sorted(uniforms):
        if uname in ENGINE_AUTOSET_UNIFORMS:
            continue
        at_mesh_level = uname in mesh
        in_params = uname in shader_params
        if at_mesh_level and not in_params:
            findings.append({
                "severity": "error", "field": uname,
                "message": (
                    f"shader uniform '{uname}' is at ground.mesh top-level "
                    f"but NOT in ground.mesh.shader_params. "
                    f"ground_renderer.gd only forwards shader_params to the "
                    f"ShaderMaterial — this value is SILENTLY IGNORED and "
                    f"the shader uses its own default. Move it into "
                    f"shader_params."
                ),
            })
    return findings


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("game", help="data/<game> folder name (with/without demo_)")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 on any error or warning")
    args = ap.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    name = args.game if args.game.startswith("demo_") else f"demo_{args.game}"
    game_dir = repo_root / "godot" / "data" / name
    if not game_dir.is_dir():
        print(f"[validate_ground_shader_params] skip — not a dir: {game_dir}")
        return 0

    findings = validate_game(game_dir, repo_root)
    if not findings:
        print("[validate_ground_shader_params] OK — all shader uniforms "
              "in shader_params (or none authored)")
        return 0

    print("[validate_ground_shader_params] findings:")
    for f in findings:
        print(f"  [{f['severity'].upper():5s}] {f['field']}: {f['message']}")

    any_error = any(f["severity"] == "error" for f in findings)
    if args.strict and findings:
        return 1
    return 1 if any_error else 0


if __name__ == "__main__":
    sys.exit(main())
