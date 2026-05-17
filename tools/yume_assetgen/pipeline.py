"""
pipeline.py — the orchestrator.

Flow:
    1. Load asset_gen.json from the game dir
    2. Walk entity defs under entities/, collect *_prompt fields
    3. For each prompt: assemble (style.global_prefix + entity prompt
       + style.<texture|mesh>_suffix), dispatch to backend
    4. Save output to the configured texture/mesh directory
    5. Optionally patch entity defs with resolved paths (in place,
       preserving the original prompt fields for re-runs)

Prompt fields scanned (in entity.visual):
    - albedo_texture_prompt  → texture PNG
    - mesh_prompt            → .glb mesh

Output naming: <entity_id>.png / <entity_id>.glb (one per def).
Idempotent under skip_existing=true — re-runs skip already-emitted
files.
"""

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from .backends import get_backend, Backend
from .config import AssetGenConfig, load_config


@dataclass
class PromptItem:
    entity_id: str
    kind: str  # "texture" | "mesh"
    raw_prompt: str
    assembled_prompt: str
    out_path: Path
    res_ref: str  # the res:// path entity_def will reference
    source_file: Path  # the entity .json file (for in-place patching)
    visual_key: str  # field name on visual to patch ("albedo_texture" | "mesh")


def scan_prompts(
    game_dir: Path,
    cfg: AssetGenConfig,
    only: str | None = None,
) -> Iterator[PromptItem]:
    """Walk entity-def JSON files under <game_dir>/entities/, yield
    one PromptItem per *_prompt field found.

    `only` filters by kind: "texture" / "mesh" / None (both).
    """
    entities_dir = game_dir / "entities"
    if not entities_dir.exists():
        return iter([])

    # Compute the res:// game-rel prefix (data/<game> portion).
    # Works for both godot/data/<game> and absolute paths.
    repo_data_prefix = "data/" + game_dir.name

    items = []
    for f in sorted(entities_dir.rglob("*.json")):
        try:
            doc = json.loads(f.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        defs = doc.get("definitions", []) if isinstance(doc, dict) else []
        for d in defs:
            if not isinstance(d, dict):
                continue
            entity_id = d.get("id", "")
            visual = d.get("visual")
            if not (entity_id and isinstance(visual, dict)):
                continue

            if (only in (None, "texture")) and visual.get("albedo_texture_prompt"):
                items.append(PromptItem(
                    entity_id=entity_id,
                    kind="texture",
                    raw_prompt=str(visual["albedo_texture_prompt"]),
                    assembled_prompt=_assemble(
                        cfg, str(visual["albedo_texture_prompt"]), "texture"
                    ),
                    out_path=cfg.texture_dir_abs(game_dir) / f"{entity_id}.png",
                    res_ref=cfg.texture_ref(repo_data_prefix, entity_id),
                    source_file=f,
                    visual_key="albedo_texture",
                ))
            if (only in (None, "mesh")) and visual.get("mesh_prompt"):
                items.append(PromptItem(
                    entity_id=entity_id,
                    kind="mesh",
                    raw_prompt=str(visual["mesh_prompt"]),
                    assembled_prompt=_assemble(
                        cfg, str(visual["mesh_prompt"]), "mesh"
                    ),
                    out_path=cfg.mesh_dir_abs(game_dir) / f"{entity_id}.glb",
                    res_ref=cfg.mesh_ref(repo_data_prefix, entity_id),
                    source_file=f,
                    visual_key="mesh",
                ))
    return iter(items)


def _assemble(cfg: AssetGenConfig, raw: str, kind: str) -> str:
    """Concatenate style.global_prefix + raw + style.<kind>_suffix."""
    style = cfg.style or {}
    prefix = style.get("global_prefix", "")
    suffix_key = "texture_suffix" if kind == "texture" else "mesh_suffix"
    suffix = style.get(suffix_key, "")
    return f"{prefix}{raw}{suffix}"


def _patch_entity_file(item: PromptItem) -> bool:
    """Patch the entity-def JSON file in place: add `<visual_key>:
    <res_ref>` to the matching entity's visual block. Preserves
    `*_prompt` fields so re-runs see them again. Returns True if a
    write happened, False if the field already had the same value
    (idempotent / no-op)."""
    doc = json.loads(item.source_file.read_text(encoding="utf-8"))
    if not isinstance(doc, dict):
        return False
    defs = doc.get("definitions", [])
    changed = False
    for d in defs:
        if not isinstance(d, dict) or d.get("id") != item.entity_id:
            continue
        visual = d.get("visual")
        if not isinstance(visual, dict):
            continue
        if visual.get(item.visual_key) == item.res_ref:
            continue
        visual[item.visual_key] = item.res_ref
        changed = True
    if changed:
        item.source_file.write_text(
            json.dumps(doc, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    return changed


def run_pipeline(
    game_dir: Path,
    *,
    only: str | None = None,
    dry_run: bool = False,
    backend_override: str | None = None,
    verbose: bool = True,
) -> dict:
    """Execute the full pipeline. Returns a summary dict with counts.

    `dry_run=True` lists what WOULD be generated without invoking the
    backend or writing files. Useful for verifying scan + prompt
    assembly before paying API calls.
    """
    cfg = load_config(game_dir)
    backend_name = backend_override or cfg.backend
    if dry_run:
        backend = None
    else:
        backend_config = cfg.backend_config.get(backend_name, {})
        backend = get_backend(backend_name, backend_config)

    summary = {
        "game": game_dir.name,
        "backend": backend_name,
        "dry_run": dry_run,
        "scanned": 0,
        "generated": 0,
        "skipped_existing": 0,
        "patched": 0,
        "errors": [],
        "items": [],
    }

    items = list(scan_prompts(game_dir, cfg, only=only))
    summary["scanned"] = len(items)

    for item in items:
        rec = {
            "entity": item.entity_id,
            "kind": item.kind,
            "prompt": item.assembled_prompt,
            "out": str(item.out_path),
        }
        if dry_run:
            rec["status"] = "would_generate"
            summary["items"].append(rec)
            if verbose:
                print(f"  [dry] {item.kind:7s} {item.entity_id:20s} → {item.out_path.name}")
            continue
        if cfg.skip_existing and item.out_path.exists():
            rec["status"] = "skipped_existing"
            summary["skipped_existing"] += 1
            summary["items"].append(rec)
            if verbose:
                print(f"  [skip] {item.kind:7s} {item.entity_id:20s} (exists)")
            continue
        try:
            if item.kind == "texture":
                if not backend.supports_texture():
                    rec["status"] = "backend_lacks_support"
                    summary["errors"].append(rec)
                    if verbose:
                        print(f"  [skip] {item.kind:7s} {item.entity_id} (backend can't gen textures)")
                    continue
                backend.generate_texture(
                    item.assembled_prompt,
                    item.out_path,
                    size=cfg.outputs.get("image_size", (512, 512)),
                )
            else:  # mesh
                if not backend.supports_mesh():
                    rec["status"] = "backend_lacks_support"
                    summary["errors"].append(rec)
                    if verbose:
                        print(f"  [skip] {item.kind:7s} {item.entity_id} (backend can't gen meshes)")
                    continue
                backend.generate_mesh(item.assembled_prompt, item.out_path)
            summary["generated"] += 1
            rec["status"] = "generated"
            if cfg.patch_entities:
                if _patch_entity_file(item):
                    summary["patched"] += 1
                    rec["patched"] = True
            summary["items"].append(rec)
            if verbose:
                print(f"  [gen]  {item.kind:7s} {item.entity_id:20s} → {item.out_path.name}")
        except Exception as e:
            rec["status"] = "error"
            rec["error"] = str(e)
            summary["errors"].append(rec)
            if verbose:
                print(f"  [err]  {item.kind:7s} {item.entity_id}: {e}", file=sys.stderr)

    return summary
