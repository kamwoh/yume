"""
test_smoke.py — end-to-end smoke for yume_assetgen.

Creates a temp game dir with:
    entities/test.json — 2 entities, each with albedo_texture_prompt
                         and mesh_prompt
    (no asset_gen.json — pipeline uses defaults)

Runs the pipeline with the mock backend (no network), verifies:
    - PNG generated for each texture prompt
    - .glb generated for each mesh prompt
    - Generated PNGs are valid PNGs (sig check)
    - Generated .glbs are valid (parsed by inspect_glb)
    - Entity defs patched with res:// references
    - Re-run with skip_existing skips work

Usage:
    python3 -m tools.yume_assetgen.tests.test_smoke
"""

import json
import shutil
import struct
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))

from tools.yume_assetgen.pipeline import run_pipeline, scan_prompts
from tools.yume_assetgen.config import load_config, save_config_template


def _check(label, ok):
    print(f"  {'✓' if ok else '✗'} {label}")
    return 0 if ok else 1


def _is_valid_png(path: Path) -> bool:
    if not path.exists() or path.stat().st_size < 24:
        return False
    sig = path.read_bytes()[:8]
    return sig == b"\x89PNG\r\n\x1a\n"


def _is_valid_glb(path: Path) -> bool:
    if not path.exists() or path.stat().st_size < 28:
        return False
    data = path.read_bytes()
    magic, version, total_len = struct.unpack_from("<4sII", data, 0)
    return magic == b"glTF" and version == 2 and total_len == len(data)


def _make_game_dir(parent: Path) -> Path:
    """Build a minimal game folder with 2 entities having prompts."""
    game_dir = parent / "demo_assetgen_smoke"
    (game_dir / "entities").mkdir(parents=True)
    entities = {
        "_comment": "smoke test entities",
        "definitions": [
            {
                "id": "wheat_seed",
                "tags": ["plant", "crop"],
                "visual": {
                    "color": "#d4b54a",
                    "albedo_texture_prompt": "golden wheat seed, painterly",
                    "mesh_prompt": "low-poly wheat seed, cylindrical",
                },
            },
            {
                "id": "villager_alice",
                "tags": ["villager", "actor"],
                "visual": {
                    "color": "#a0c0e0",
                    "albedo_texture_prompt": "blue-cloaked villager body, soft cel-shaded",
                    "mesh_prompt": "low-poly humanoid villager, T-pose",
                },
            },
            {
                # No prompts — verify pipeline skips it.
                "id": "log",
                "tags": ["item"],
                "visual": {"color": "#5d3a1e"},
            },
        ],
    }
    (game_dir / "entities" / "test.json").write_text(
        json.dumps(entities, indent=2), encoding="utf-8"
    )
    return game_dir


def test_scan_finds_prompts(game_dir):
    print("[scan]")
    fails = 0
    cfg = load_config(game_dir)
    items = list(scan_prompts(game_dir, cfg))
    # 2 texture + 2 mesh prompts expected (3rd entity has none).
    by_kind = {"texture": 0, "mesh": 0}
    for it in items:
        by_kind[it.kind] = by_kind.get(it.kind, 0) + 1
    fails += _check("scan finds 2 texture prompts", by_kind["texture"] == 2)
    fails += _check("scan finds 2 mesh prompts", by_kind["mesh"] == 2)
    fails += _check("scan skips entities without prompts", len(items) == 4)
    return fails


def test_assemble_prefix_suffix(game_dir):
    print("[assemble]")
    fails = 0
    # Write a styled config.
    (game_dir / "asset_gen.json").write_text(json.dumps({
        "backend": "mock",
        "style": {
            "global_prefix": "low-poly cartoon, ",
            "texture_suffix": ", albedo only",
            "mesh_suffix": ", clean topology",
        },
    }), encoding="utf-8")
    cfg = load_config(game_dir)
    items = list(scan_prompts(game_dir, cfg))
    by_id = {(i.entity_id, i.kind): i for i in items}
    wheat_tex = by_id[("wheat_seed", "texture")]
    fails += _check(
        "global_prefix prepended",
        wheat_tex.assembled_prompt.startswith("low-poly cartoon, "),
    )
    fails += _check(
        "texture_suffix appended",
        wheat_tex.assembled_prompt.endswith(", albedo only"),
    )
    wheat_mesh = by_id[("wheat_seed", "mesh")]
    fails += _check(
        "mesh_suffix appended",
        wheat_mesh.assembled_prompt.endswith(", clean topology"),
    )
    return fails


def test_dry_run(game_dir):
    print("[dry-run]")
    fails = 0
    summary = run_pipeline(game_dir, dry_run=True, verbose=False)
    fails += _check("dry-run scanned 4 prompts", summary["scanned"] == 4)
    fails += _check("dry-run generated 0", summary["generated"] == 0)
    fails += _check("dry-run wrote no PNGs",
                    not any(p.exists() for p in [
                        game_dir / "assets/textures/wheat_seed.png",
                    ]))
    return fails


def test_generate_with_mock(game_dir):
    print("[generate with mock backend]")
    fails = 0
    summary = run_pipeline(game_dir, dry_run=False, verbose=False)
    fails += _check("generated 4 items", summary["generated"] == 4)
    fails += _check("0 errors", len(summary["errors"]) == 0)
    fails += _check(
        "wheat_seed.png is valid PNG",
        _is_valid_png(game_dir / "assets/textures/wheat_seed.png"),
    )
    fails += _check(
        "villager_alice.png is valid PNG",
        _is_valid_png(game_dir / "assets/textures/villager_alice.png"),
    )
    fails += _check(
        "wheat_seed.glb is valid GLB",
        _is_valid_glb(game_dir / "assets/meshes/wheat_seed.glb"),
    )
    fails += _check(
        "villager_alice.glb is valid GLB",
        _is_valid_glb(game_dir / "assets/meshes/villager_alice.glb"),
    )
    return fails


def test_patch_entity_def(game_dir):
    print("[patch entity defs]")
    fails = 0
    doc = json.loads((game_dir / "entities/test.json").read_text())
    wheat = next(d for d in doc["definitions"] if d["id"] == "wheat_seed")
    fails += _check(
        "wheat.visual.albedo_texture patched",
        wheat["visual"].get("albedo_texture", "").startswith("res://data/demo_assetgen_smoke/"),
    )
    fails += _check(
        "wheat.visual.mesh patched to .glb",
        wheat["visual"].get("mesh", "").endswith("wheat_seed.glb"),
    )
    fails += _check(
        "original albedo_texture_prompt preserved",
        "albedo_texture_prompt" in wheat["visual"],
    )
    return fails


def test_skip_existing_on_rerun(game_dir):
    print("[idempotent re-run]")
    fails = 0
    # Re-run; with skip_existing=true (default), should skip all 4.
    summary = run_pipeline(game_dir, dry_run=False, verbose=False)
    fails += _check("re-run generated 0 new", summary["generated"] == 0)
    fails += _check("re-run skipped 4 existing", summary["skipped_existing"] == 4)
    return fails


def main():
    fails = 0
    with tempfile.TemporaryDirectory() as td:
        game_dir = _make_game_dir(Path(td))
        fails += test_scan_finds_prompts(game_dir)
        fails += test_assemble_prefix_suffix(game_dir)
        fails += test_dry_run(game_dir)
        fails += test_generate_with_mock(game_dir)
        fails += test_patch_entity_def(game_dir)
        fails += test_skip_existing_on_rerun(game_dir)
    print()
    if fails == 0:
        print("=== yume_assetgen smoke test: PASSED ===")
        return 0
    print(f"=== yume_assetgen smoke test: {fails} FAILURE(S) ===")
    return 1


if __name__ == "__main__":
    sys.exit(main())
