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
from tools.yume_assetgen.ledger import (
    LEDGER_FILENAME, Ledger, load_ledger, prompt_hash, is_paid_backend
)


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
    """Build a minimal game folder with 2 entities having prompts +
    one chained entity (mesh_reference_prompt + mesh_prompt)."""
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
                    "mesh_reference_prompt": "elderly villager front view, robe",
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
    # 2 texture + 1 concept + 2 mesh prompts expected
    # (villager_alice has both mesh_reference_prompt + mesh_prompt = 1
    #  concept + 1 mesh; wheat_seed = 1 texture + 1 mesh; villager_alice
    #  also has texture = 1 texture. Total: 2 texture + 1 concept + 2 mesh = 5).
    by_kind = {"texture": 0, "mesh": 0, "concept": 0}
    for it in items:
        by_kind[it.kind] = by_kind.get(it.kind, 0) + 1
    fails += _check("scan finds 2 texture prompts", by_kind["texture"] == 2)
    fails += _check("scan finds 1 concept prompt", by_kind["concept"] == 1)
    fails += _check("scan finds 2 mesh prompts", by_kind["mesh"] == 2)
    fails += _check("scan total = 5 items", len(items) == 5)
    # The villager_alice mesh PromptItem must carry reference_image_path
    # pointing to its concept output (chained mode).
    villager_mesh = next(
        (it for it in items if it.entity_id == "villager_alice" and it.kind == "mesh"),
        None,
    )
    fails += _check(
        "villager_alice mesh has reference_image_path",
        villager_mesh is not None and villager_mesh.reference_image_path is not None,
    )
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
    fails += _check("dry-run scanned 5 prompts", summary["scanned"] == 5)
    fails += _check("dry-run generated 0", summary["generated"] == 0)
    fails += _check("dry-run wrote no PNGs",
                    not any(p.exists() for p in [
                        game_dir / "assets/textures/wheat_seed.png",
                    ]))
    return fails


def _glob_one(parent: Path, pattern: str) -> Path | None:
    """Return the first file matching parent/pattern, or None.
    Hash-suffixed naming means we don't know the exact name."""
    matches = list(parent.glob(pattern))
    return matches[0] if matches else None


def test_generate_with_mock(game_dir):
    print("[generate with mock backend]")
    fails = 0
    # Force --backend mock so the test never tries to hit real APIs.
    summary = run_pipeline(
        game_dir, dry_run=False, verbose=False, backend_override="mock"
    )
    fails += _check("generated 5 items", summary["generated"] == 5)
    fails += _check("0 errors", len(summary["errors"]) == 0)
    # New naming: <entity_id>_<8char-hash>.<ext>; check via glob.
    wheat_png = _glob_one(game_dir / "assets/textures", "wheat_seed_*.png")
    villager_png = _glob_one(game_dir / "assets/textures", "villager_alice_*.png")
    wheat_glb = _glob_one(game_dir / "assets/meshes", "wheat_seed_*.glb")
    villager_glb = _glob_one(game_dir / "assets/meshes", "villager_alice_*.glb")
    villager_concept = _glob_one(
        game_dir / "assets/concepts", "villager_alice_*.png"
    )
    fails += _check("wheat_seed_*.png is valid PNG", bool(wheat_png) and _is_valid_png(wheat_png))
    fails += _check("villager_alice_*.png is valid PNG", bool(villager_png) and _is_valid_png(villager_png))
    fails += _check("wheat_seed_*.glb is valid GLB", bool(wheat_glb) and _is_valid_glb(wheat_glb))
    fails += _check("villager_alice_*.glb is valid GLB", bool(villager_glb) and _is_valid_glb(villager_glb))
    fails += _check("villager_alice concept PNG written", bool(villager_concept) and _is_valid_png(villager_concept))
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
    # New naming: <entity_id>_<8char-hash>.glb; check the prefix.
    fails += _check(
        "wheat.visual.mesh patched to a wheat_seed_*.glb",
        wheat["visual"].get("mesh", "").startswith(
            "res://data/demo_assetgen_smoke/"
        ) and "wheat_seed_" in wheat["visual"].get("mesh", "")
          and wheat["visual"].get("mesh", "").endswith(".glb"),
    )
    fails += _check(
        "original albedo_texture_prompt preserved",
        "albedo_texture_prompt" in wheat["visual"],
    )
    return fails


def test_skip_existing_on_rerun(game_dir):
    print("[idempotent re-run]")
    fails = 0
    # Re-run; with skip_existing=true (default), should skip all 5.
    summary = run_pipeline(
        game_dir, dry_run=False, verbose=False, backend_override="mock"
    )
    fails += _check("re-run generated 0 new", summary["generated"] == 0)
    fails += _check("re-run skipped 5 existing", summary["skipped_existing"] == 5)
    return fails


def test_ledger_blocks_paid_rerun(game_dir):
    """Simulate a prior paid Tripo3D call by seeding the ledger, then
    delete the .glb on disk and re-run. With skip_existing AND the
    ledger we should NOT re-pay even though the file is gone."""
    print("[ledger blocks paid re-run]")
    fails = 0
    # Tighten config so wheat_seed's mesh prompt would be routed to
    # tripo3d (paid). We force --backend=tripo3d but never reach the
    # backend — the ledger catches it before dispatch.
    (game_dir / "asset_gen.json").write_text(json.dumps({
        "backend": {"texture": "mock", "mesh": "tripo3d", "concept": "mock"},
    }), encoding="utf-8")

    # Re-scan to get the assembled prompt for wheat_seed.glb.
    cfg = load_config(game_dir)
    items = list(scan_prompts(game_dir, cfg))
    wheat_mesh = next(
        i for i in items if i.entity_id == "wheat_seed" and i.kind == "mesh"
    )

    # Seed the ledger as if a prior Tripo3D call had succeeded.
    ledger = load_ledger(game_dir)
    ledger.add(
        backend="tripo3d",
        kind="mesh",
        entity_id="wheat_seed",
        prompt=wheat_mesh.assembled_prompt,
        p_hash=prompt_hash(wheat_mesh.assembled_prompt),
        out_path="assets/meshes/wheat_seed.glb",
    )
    ledger.save()
    fails += _check(
        "ledger file written",
        (game_dir / LEDGER_FILENAME).exists(),
    )

    # Delete the .glb so skip_existing won't catch this case —
    # only the ledger should.
    glb = game_dir / "assets/meshes/wheat_seed.glb"
    if glb.exists():
        glb.unlink()
    fails += _check("wheat_seed.glb removed on disk", not glb.exists())

    # Re-run. The mesh kind is routed to tripo3d (paid); without the
    # ledger this would call out to the API + fail without an API key.
    summary = run_pipeline(game_dir, dry_run=False, verbose=False)
    fails += _check(
        "wheat_seed mesh blocked by ledger (no re-pay)",
        summary["skipped_ledger"] >= 1,
    )
    fails += _check(
        "no tripo3d error surfaced (we never dispatched)",
        not any(
            e.get("entity") == "wheat_seed" and e.get("kind") == "mesh"
            for e in summary["errors"]
        ),
    )

    # Now mutate the prompt: prompt_hash changes -> ledger MISS ->
    # would attempt dispatch. We don't have a real API key, so we
    # expect either an error OR the prompt being routed to mock if
    # we re-route. Verify the LEDGER miss path by checking the
    # ledger.has() lookup directly.
    new_prompt = wheat_mesh.assembled_prompt + " EDITED"
    fails += _check(
        "ledger MISS when prompt changes",
        ledger.has("tripo3d", "mesh", prompt_hash(new_prompt)) is None,
    )

    # Alias check: nanobanana ↔ gemini_image.
    ledger2 = load_ledger(game_dir)
    ledger2.add(
        backend="nanobanana", kind="texture", entity_id="alias_probe",
        prompt="a test", p_hash=prompt_hash("a test"),
        out_path="assets/textures/alias_probe.png",
    )
    fails += _check(
        "ledger hits across nanobanana ↔ gemini_image alias",
        ledger2.has("gemini_image", "texture", prompt_hash("a test")) is not None,
    )

    return fails


def test_ledger_does_not_track_mock(parent_tmp):
    """Verify mock-backend generations DON'T write to the ledger.
    Builds a fresh game dir so the prior ledger state isn't reused."""
    print("[ledger does not track mock]")
    fails = 0
    game_dir = _make_game_dir(parent_tmp / "ledger_mock_isolation")
    summary = run_pipeline(
        game_dir, dry_run=False, verbose=False, backend_override="mock"
    )
    fails += _check("mock run generated > 0", summary["generated"] > 0)
    fails += _check(
        "mock run did NOT write a ledger file",
        not (game_dir / LEDGER_FILENAME).exists(),
    )
    fails += _check("is_paid_backend(mock) is False", not is_paid_backend("mock"))
    fails += _check("is_paid_backend(tripo3d) is True", is_paid_backend("tripo3d"))
    fails += _check("is_paid_backend(nanobanana) is True", is_paid_backend("nanobanana"))
    return fails


def test_backend_routing():
    """Verify per-kind backend resolution from a dict config."""
    from tools.yume_assetgen.config import AssetGenConfig
    print("[backend routing]")
    fails = 0
    cfg_dict_backend = AssetGenConfig(
        backend={"texture": "nanobanana", "mesh": "tripo3d"}
    )
    fails += _check(
        "dict backend: texture routes to nanobanana",
        cfg_dict_backend.backend_for("texture") == "nanobanana",
    )
    fails += _check(
        "dict backend: mesh routes to tripo3d",
        cfg_dict_backend.backend_for("mesh") == "tripo3d",
    )
    fails += _check(
        "dict backend: concept falls back to texture's backend",
        cfg_dict_backend.backend_for("concept") == "nanobanana",
    )
    cfg_string_backend = AssetGenConfig(backend="mock")
    fails += _check(
        "string backend: texture routes to mock",
        cfg_string_backend.backend_for("texture") == "mock",
    )
    fails += _check(
        "string backend: mesh routes to mock",
        cfg_string_backend.backend_for("mesh") == "mock",
    )
    return fails


def test_real_backends_register():
    """Verify nanobanana + tripo3d are in REGISTRY (don't try to call
    them — that would need API keys)."""
    from tools.yume_assetgen.backends import REGISTRY, get_backend
    print("[real backends register]")
    fails = 0
    fails += _check("REGISTRY has nanobanana", "nanobanana" in REGISTRY)
    fails += _check("REGISTRY has gemini_image alias", "gemini_image" in REGISTRY)
    fails += _check("REGISTRY has tripo3d", "tripo3d" in REGISTRY)
    nb = get_backend("nanobanana", {"api_key_env": "GEMINI_API_KEY"})
    fails += _check("nanobanana supports_texture", nb.supports_texture())
    fails += _check("nanobanana does NOT support mesh", not nb.supports_mesh())
    t3d = get_backend("tripo3d", {})
    fails += _check("tripo3d supports_mesh", t3d.supports_mesh())
    fails += _check("tripo3d does NOT support texture", not t3d.supports_texture())
    return fails


def main():
    fails = 0
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        game_dir = _make_game_dir(td_path)
        fails += test_scan_finds_prompts(game_dir)
        fails += test_assemble_prefix_suffix(game_dir)
        fails += test_dry_run(game_dir)
        fails += test_generate_with_mock(game_dir)
        fails += test_patch_entity_def(game_dir)
        fails += test_skip_existing_on_rerun(game_dir)
        fails += test_ledger_blocks_paid_rerun(game_dir)
        fails += test_ledger_does_not_track_mock(td_path)
    fails += test_backend_routing()
    fails += test_real_backends_register()
    print()
    if fails == 0:
        print("=== yume_assetgen smoke test: PASSED ===")
        return 0
    print(f"=== yume_assetgen smoke test: {fails} FAILURE(S) ===")
    return 1


if __name__ == "__main__":
    sys.exit(main())
