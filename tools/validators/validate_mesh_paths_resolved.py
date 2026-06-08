#!/usr/bin/env python3
"""Static validator: a tripo-class entity def whose generated .glb is on
disk must reference it — `visual.mesh` must be the `res://...glb`, not a
kit/primitive fallback.

Empirical case 2026-06-08: `compose_world` re-emits every entity def from
scratch on each run (`auto_gen.json` is fully overwritten). For an
`asset_source:tripo` class it writes the kit FALLBACK mesh + a
`mesh_prompt` — WIPING the `res://....glb` path that `yume_assetgen`
previously patched in. The generated `.glb` survives on disk (it's never
deleted), but the def now points at the kit primitive, so the scene
silently renders fallback boxes instead of the paid meshes. No error, no
crash — exactly the "value written to a key the consumer ignores" class as
validate_ground_shader_params / state.facing.

The fix (ADR 0067 Assets layer) makes compose_world chain an idempotent,
key-free re-patch (`yume_assetgen <game> --patch-only`) at the end. This
validator is the GATE: if the revert ever ships un-repatched, it fails.

Detection (per entity-def file under entities/, same scope assetgen scans):
  A def has `visual.mesh_prompt` (so it's a tripo class meant to resolve
  to a generated mesh) AND a matching `<id>*.glb` exists under the mesh
  output dir, BUT `visual.mesh` is NOT a `res://...glb` →
  ERROR (the generated asset exists but the def reverted to a fallback).

Remediation printed with the finding: run the patch-only pass.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Where generated meshes land (assetgen config default; see config.py
# mesh_ref / outputs.mesh_dir). Authors don't override this in practice.
MESH_DIR = "assets/meshes"


def _has_generated_glb(game_dir: Path, entity_id: str) -> bool:
    """A generated mesh exists for this def if a `<id>.glb` or
    `<id>_<variant/hash>.glb` is present under the mesh dir."""
    mdir = game_dir / MESH_DIR
    if not mdir.is_dir():
        return False
    if (mdir / f"{entity_id}.glb").exists():
        return True
    return any(mdir.glob(f"{entity_id}_*.glb"))


def validate_game(game_dir: Path) -> list[dict]:
    findings: list[dict] = []
    entities_dir = game_dir / "entities"
    if not entities_dir.is_dir():
        return findings

    for f in sorted(entities_dir.rglob("*.json")):
        try:
            doc = json.loads(f.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue  # other validators own JSON-shape errors
        if not isinstance(doc, dict):
            continue
        for d in doc.get("definitions", []):
            if not isinstance(d, dict):
                continue
            visual = d.get("visual")
            if not isinstance(visual, dict):
                continue
            # Only tripo classes (those carrying a mesh_prompt) are expected
            # to resolve to a generated .glb. Kit/primitive classes legitimately
            # keep a kit mesh and have no mesh_prompt — skip them.
            if not visual.get("mesh_prompt"):
                continue
            entity_id = d.get("id", "")
            if not entity_id or not _has_generated_glb(game_dir, entity_id):
                continue  # nothing generated yet → kit fallback is correct
            mesh = str(visual.get("mesh", ""))
            resolved = mesh.startswith("res://") and mesh.endswith(".glb")
            if not resolved:
                findings.append({
                    "severity": "error",
                    "field": f"{f.name}:{entity_id}",
                    "message": (
                        f"a generated .glb exists under {MESH_DIR}/ for "
                        f"'{entity_id}' but visual.mesh='{mesh}' is a kit/"
                        f"primitive fallback, not the res://...glb. The mesh "
                        f"renders as a fallback. A compose_world re-run likely "
                        f"reverted it — re-resolve with: python3 -m "
                        f"tools.yume_assetgen {game_dir.name} --patch-only"
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
        print(f"[validate_mesh_paths_resolved] skip — not a dir: {game_dir}")
        return 0

    findings = validate_game(game_dir)
    if not findings:
        print("[validate_mesh_paths_resolved] OK — every tripo class with a "
              "generated .glb references it (or none generated yet)")
        return 0

    print("[validate_mesh_paths_resolved] findings:")
    for f in findings:
        print(f"  [{f['severity'].upper():5s}] {f['field']}: {f['message']}")

    any_error = any(f["severity"] == "error" for f in findings)
    if args.strict and findings:
        return 1
    return 1 if any_error else 0


if __name__ == "__main__":
    sys.exit(main())
