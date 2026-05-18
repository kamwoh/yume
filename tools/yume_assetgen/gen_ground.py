"""gen_ground.py — generate tileable ground texture set for a Yume game.

Workflow (per ADR 0021 + the asset_gen pipeline conventions):

    1. Read scene.json's `ground.mesh.albedo_texture_prompt` and
       `ground.mesh.heightmap_prompt`. If neither is set, exit.
    2. Call nanobanana for each prompt → albedo PNG + heightmap PNG.
    3. Derive a tangent-space normal map from the heightmap via a
       Sobel filter (deterministic; runs in numpy).
    4. Write all three textures with hash-suffixed filenames into
       assets/textures/.
    5. Record paid calls into the ledger (`(backend, kind,
       prompt_hash)` per existing convention).
    6. Patch scene.json's ground.mesh block with `albedo_texture`,
       `normal_texture`, and `uv1_scale` (preserves prompts).

Skip behavior: if a prompt's ledger entry exists (same hash), the
nanobanana call is skipped. The derived normal map is regenerated
from the matching heightmap file regardless — it's a local Sobel
op, no API call.

Usage:
    python3 -m tools.yume_assetgen.gen_ground <game> [--strength N]

`--strength` (default 4.0) controls the normal-map exaggeration —
higher = bumpier-looking. 2-6 is a reasonable range.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

from .backends import get_backend
from .config import load_config
from .ledger import load_ledger, prompt_hash, is_paid_backend


REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"


def _short_hash(text: str) -> str:
    return prompt_hash(text).split(":", 1)[1][:8]


def _heightmap_to_normal(heightmap_path: Path, normal_path: Path,
                         strength: float = 4.0) -> None:
    """Convert a grayscale heightmap PNG → tangent-space normal map PNG.

    Tangent-space normals encode (X, Y, Z) as RGB where:
      R = (-dH/dx * strength + 1) / 2
      G = ( dH/dy * strength + 1) / 2     (Y flipped for OpenGL convention)
      B = 1.0  (Z always +1 for tangent-space)

    Edges sampled via roll() so the result remains tileable across
    seams (so long as the heightmap was tileable to begin with).
    """
    img = Image.open(heightmap_path).convert("L")  # grayscale
    h = np.asarray(img, dtype=np.float32) / 255.0  # 0..1 height

    # Central differences with wrap → tileable normals.
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5

    # Scale + bias into [0, 1] for RGB. Flip Y for OpenGL normal-map
    # convention (Godot uses OpenGL). Z component is constant +1
    # (perpendicular to the surface) which maps to B=1.0.
    r = (-dx * strength * 0.5) + 0.5
    g = (dy * strength * 0.5) + 0.5
    b = np.ones_like(r)

    rgb = np.stack([r, g, b], axis=-1)
    rgb = np.clip(rgb * 255.0, 0, 255).astype(np.uint8)
    Image.fromarray(rgb, mode="RGB").save(normal_path)


def _assemble(cfg, raw: str, kind: str) -> str:
    """Mirror pipeline._assemble — same prefix/suffix discipline."""
    style = cfg.style or {}
    prefix = style.get("global_prefix", "")
    suffix = style.get({
        "texture": "texture_suffix",
        "heightmap": "texture_suffix",   # reuse texture suffix
        "concept": "concept_suffix",
        "mesh": "mesh_suffix",
    }.get(kind, ""), "")
    return f"{prefix}{raw}{suffix}"


def run(game: str, strength: float = 4.0) -> int:
    game_dir = DATA_ROOT / game
    if not game_dir.exists():
        print(f"error: {game_dir} does not exist", file=sys.stderr)
        return 1

    scene_path = game_dir / "scene.json"
    if not scene_path.exists():
        print(f"error: {scene_path} missing", file=sys.stderr)
        return 1
    scene = json.loads(scene_path.read_text(encoding="utf-8"))
    ground = scene.get("ground", {}) if isinstance(scene, dict) else {}
    mesh_cfg = ground.get("mesh", {}) if isinstance(ground, dict) else {}
    albedo_prompt = mesh_cfg.get("albedo_texture_prompt", "")
    height_prompt = mesh_cfg.get("heightmap_prompt", "")
    if not (albedo_prompt or height_prompt):
        print(f"[{game}] no ground.mesh.*_prompt fields in scene.json — "
              f"nothing to generate.")
        return 0

    cfg = load_config(game_dir)
    ledger = load_ledger(game_dir)
    backend_name = cfg.backend_for("texture")
    backend_config = cfg.backend_config.get(backend_name, {})
    backend = get_backend(backend_name, backend_config)
    tex_dir = game_dir / cfg.outputs.get("texture_dir", "assets/textures")
    tex_dir.mkdir(parents=True, exist_ok=True)
    repo_data_prefix = "data/" + game_dir.name
    res_tex_dir = "res://" + repo_data_prefix + "/" + cfg.outputs.get(
        "texture_dir", "assets/textures")

    summary = {
        "game": game,
        "backend": backend_name,
        "albedo": None,
        "heightmap": None,
        "normal": None,
        "errors": [],
    }

    # Albedo
    albedo_filename = None
    if albedo_prompt:
        assembled = _assemble(cfg, albedo_prompt, "texture")
        p_hash = prompt_hash(assembled)
        h8 = _short_hash(assembled)
        albedo_filename = f"ground_albedo_{h8}.png"
        out_path = tex_dir / albedo_filename
        if is_paid_backend(backend_name) and ledger.has(backend_name, "texture", p_hash):
            print(f"  [ledg] ground_albedo (paid, skip)")
        elif out_path.exists():
            print(f"  [skip] ground_albedo (file exists)")
        else:
            backend.generate_texture(
                assembled, out_path,
                size=cfg.outputs.get("image_size", (1024, 1024)),
            )
            if is_paid_backend(backend_name):
                ledger.add(
                    backend=backend_name, kind="texture",
                    entity_id="@ground", prompt=assembled, p_hash=p_hash,
                    out_path=str(out_path.relative_to(game_dir)),
                )
            print(f"  [gen]  ground_albedo → {albedo_filename}")
        summary["albedo"] = albedo_filename

    # Heightmap
    height_filename = None
    height_path = None
    if height_prompt:
        assembled = _assemble(cfg, height_prompt, "heightmap")
        p_hash = prompt_hash(assembled)
        h8 = _short_hash(assembled)
        height_filename = f"ground_heightmap_{h8}.png"
        height_path = tex_dir / height_filename
        if is_paid_backend(backend_name) and ledger.has(backend_name, "texture", p_hash):
            print(f"  [ledg] ground_heightmap (paid, skip)")
        elif height_path.exists():
            print(f"  [skip] ground_heightmap (file exists)")
        else:
            backend.generate_texture(
                assembled, height_path,
                size=cfg.outputs.get("image_size", (1024, 1024)),
            )
            if is_paid_backend(backend_name):
                ledger.add(
                    backend=backend_name, kind="texture",
                    entity_id="@ground", prompt=assembled, p_hash=p_hash,
                    out_path=str(height_path.relative_to(game_dir)),
                )
            print(f"  [gen]  ground_heightmap → {height_filename}")
        summary["heightmap"] = height_filename

    # Normal map — derived from heightmap. Filename ties to heightmap
    # hash so iterating the heightmap prompt produces a new pair.
    normal_filename = None
    if height_filename:
        h8 = height_filename.removeprefix("ground_heightmap_").removesuffix(".png")
        normal_filename = f"ground_normal_{h8}.png"
        normal_path = tex_dir / normal_filename
        if normal_path.exists():
            print(f"  [skip] ground_normal (file exists)")
        else:
            _heightmap_to_normal(height_path, normal_path, strength=strength)
            print(f"  [drv]  ground_normal → {normal_filename}  (strength={strength})")
        summary["normal"] = normal_filename

    # Patch scene.json's ground.mesh with the resolved paths.
    changed = False
    if albedo_filename:
        ref = f"{res_tex_dir}/{albedo_filename}"
        if mesh_cfg.get("albedo_texture") != ref:
            mesh_cfg["albedo_texture"] = ref
            changed = True
    if normal_filename:
        ref = f"{res_tex_dir}/{normal_filename}"
        if mesh_cfg.get("normal_texture") != ref:
            mesh_cfg["normal_texture"] = ref
            changed = True
    if mesh_cfg.get("uv1_scale") is None:
        # Reasonable default: 30x tiling across the plane → ~13m per
        # tile on a 400m floor. Close-up surface detail without an
        # obvious repeat pattern.
        mesh_cfg["uv1_scale"] = 30
        changed = True
    if changed:
        scene_path.write_text(json.dumps(scene, indent=2, ensure_ascii=False) + "\n",
                              encoding="utf-8")
        print(f"  [patch] scene.json ground.mesh updated")

    ledger.save()
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="gen_ground")
    ap.add_argument("game", help="game folder name (e.g. demo_aldenmere)")
    ap.add_argument("--strength", type=float, default=4.0,
                    help="normal-map exaggeration (default 4.0)")
    args = ap.parse_args(argv)
    return run(args.game, strength=args.strength)


if __name__ == "__main__":
    sys.exit(main())
