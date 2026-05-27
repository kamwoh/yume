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
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from .backends import get_backend, Backend
from .config import AssetGenConfig, load_config
from .ledger import load_ledger, prompt_hash, is_paid_backend


# Output naming: <entity_id>[_<variant>]_<8char-hash>.<ext>
#
# Per user directive 2026-05-17: NEVER overwrite a generated asset.
# Re-prompting yields a new prompt_hash → a new filename → both old
# and new assets coexist on disk. Authors compare via asset_preview.
#
# `variant` is an optional author-set slug on the entity's visual
# block (e.g. visual.mesh_variant: "autumn") that prefixes the
# hash for human readability. Without it, the filename is just
# <entity_id>_<hash8>.<ext>.
#
# Backward compat: pre-existing un-suffixed files (e.g. conifer_tree
# .glb) keep their names. The ledger lookup is hash-based, so
# their entries still skip correctly on re-runs.

def _slugify(s: str) -> str:
    """Sanitize a variant tag to [a-z0-9_]. Empty → empty."""
    return re.sub(r'[^a-z0-9_]+', '_', (s or "").lower()).strip('_')


def _filename(entity_id: str, kind: str, assembled_prompt: str,
              variant: str | None = None) -> str:
    """Compute the output filename for a generated asset."""
    ext = {"texture": "png", "concept": "png", "mesh": "glb"}[kind]
    h = prompt_hash(assembled_prompt).split(":", 1)[1][:8]
    slug = _slugify(variant) if variant else ""
    if slug:
        return f"{entity_id}_{slug}_{h}.{ext}"
    return f"{entity_id}_{h}.{ext}"


@dataclass
class PromptItem:
    entity_id: str
    kind: str  # "texture" | "mesh" | "concept"
    raw_prompt: str
    assembled_prompt: str
    out_path: Path
    res_ref: str  # the res:// path entity_def will reference (empty for concept)
    source_file: Path  # the entity .json file (for in-place patching)
    visual_key: str  # visual field to patch ("albedo_texture" | "mesh" | "")
    # When set, this mesh prompt consumes a concept image generated
    # upstream in the same run. Pipeline routes concepts FIRST so the
    # reference image exists before the mesh dispatch sees this path.
    reference_image_path: Path | None = None
    # When True, this prompt's output is an intermediate (concept ref)
    # — pipeline doesn't patch the entity def with its path.
    intermediate: bool = False


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

            # Optional human-readable variant tags. albedo_texture_variant
            # applies to the texture prompt; mesh_variant applies to BOTH
            # the concept and mesh prompts (they're a pair). Authors set
            # these to label iterations: e.g. visual.mesh_variant: "autumn"
            # → shelter_lean_to_autumn_<hash>.glb. New filename per
            # prompt-hash guarantees iterations never overwrite priors.
            tex_variant = visual.get("albedo_texture_variant")
            mesh_variant = visual.get("mesh_variant")
            tex_dir = cfg.outputs.get("texture_dir", "assets/textures")
            concept_dir = cfg.outputs.get("concept_dir", "assets/concepts")
            mesh_dir = cfg.outputs.get("mesh_dir", "assets/meshes")

            if (only in (None, "texture")) and visual.get("albedo_texture_prompt"):
                assembled = _assemble(
                    cfg, str(visual["albedo_texture_prompt"]), "texture"
                )
                fname = _filename(entity_id, "texture", assembled, tex_variant)
                items.append(PromptItem(
                    entity_id=entity_id,
                    kind="texture",
                    raw_prompt=str(visual["albedo_texture_prompt"]),
                    assembled_prompt=assembled,
                    out_path=cfg.texture_dir_abs(game_dir) / fname,
                    res_ref=f"res://{repo_data_prefix}/{tex_dir}/{fname}",
                    source_file=f,
                    visual_key="albedo_texture",
                ))

            # Concept image: an intermediate ref fed to Tripo3D's
            # image-to-mesh mode. Yields a "concept" PromptItem; the
            # mesh PromptItem (below) gets `reference_image_path` set
            # so the backend dispatch can read it. Concept comes
            # FIRST in items so the file exists before the mesh runs.
            concept_path: Path | None = None
            if (only in (None, "mesh")) and visual.get("mesh_reference_prompt"):
                assembled = _assemble(
                    cfg, str(visual["mesh_reference_prompt"]), "concept"
                )
                fname = _filename(entity_id, "concept", assembled, mesh_variant)
                concept_path = cfg.concept_dir_abs(game_dir) / fname
                items.append(PromptItem(
                    entity_id=entity_id,
                    kind="concept",
                    raw_prompt=str(visual["mesh_reference_prompt"]),
                    assembled_prompt=assembled,
                    out_path=concept_path,
                    res_ref="",
                    source_file=f,
                    visual_key="",
                    intermediate=True,
                ))

            if (only in (None, "mesh")) and visual.get("mesh_prompt"):
                assembled = _assemble(
                    cfg, str(visual["mesh_prompt"]), "mesh"
                )
                fname = _filename(entity_id, "mesh", assembled, mesh_variant)
                items.append(PromptItem(
                    entity_id=entity_id,
                    kind="mesh",
                    raw_prompt=str(visual["mesh_prompt"]),
                    assembled_prompt=assembled,
                    out_path=cfg.mesh_dir_abs(game_dir) / fname,
                    res_ref=f"res://{repo_data_prefix}/{mesh_dir}/{fname}",
                    source_file=f,
                    visual_key="mesh",
                    reference_image_path=concept_path,
                ))
    return iter(items)


def _assemble(cfg: AssetGenConfig, raw: str, kind: str) -> str:
    """Concatenate style.global_prefix + raw + style.<kind>_suffix.
    Kinds: "texture", "mesh", "concept". Each gets its own suffix."""
    style = cfg.style or {}
    prefix = style.get("global_prefix", "")
    suffix_key = {
        "texture": "texture_suffix",
        "mesh": "mesh_suffix",
        "concept": "concept_suffix",
    }.get(kind, "")
    suffix = style.get(suffix_key, "") if suffix_key else ""
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

    `dry_run=True` lists what WOULD be generated without invoking any
    backend or writing files. Useful for verifying scan + prompt
    assembly before paying API calls.

    `backend_override` (CLI flag --backend) replaces ALL per-kind
    backend choices in config with this single backend name. Useful
    for forcing 'mock' on a config that's normally nanobanana+tripo3d.
    """
    cfg = load_config(game_dir)

    # Resolve which backend handles each kind. backend_override forces
    # ONE backend for everything (e.g. --backend mock for cheap reruns).
    def _kind_backend(kind: str) -> str:
        if backend_override:
            return backend_override
        return cfg.backend_for(kind)

    # Lazy backend instantiation — only create the ones we'll actually
    # use, so a game with only texture prompts doesn't require
    # TRIPO_API_KEY to be set.
    backends: dict[str, "Backend"] = {}

    def _get(kind: str):
        if dry_run:
            return None
        name = _kind_backend(kind)
        if name not in backends:
            backend_config = cfg.backend_config.get(name, {})
            backends[name] = get_backend(name, backend_config)
        return backends[name]

    # Ledger of paid API calls; gates re-runs independently of whether
    # the output file is still on disk. Mock-only runs skip ledger
    # interaction entirely (mock is free).
    ledger = load_ledger(game_dir)

    summary = {
        "game": game_dir.name,
        "backends": {  # what got USED, populated below
            "texture": _kind_backend("texture"),
            "mesh": _kind_backend("mesh"),
            "concept": _kind_backend("concept"),
        },
        "dry_run": dry_run,
        "scanned": 0,
        "generated": 0,
        "skipped_existing": 0,
        "skipped_ledger": 0,
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
            # Re-patch the def to the existing output even though we skip the
            # gen. An upstream re-run (e.g. compose_world re-emitting the kit
            # FALLBACK + mesh_prompt for an asset_source:tripo class) resets
            # visual.mesh — re-patching keeps it pointing at the generated
            # .glb, so the asset pipeline is idempotent. 2026-05-27.
            if cfg.patch_entities and not item.intermediate and _patch_entity_file(item):
                rec["patched"] = True
                summary["patched"] += 1
            summary["items"].append(rec)
            if verbose:
                print(f"  [skip] {item.kind:7s} {item.entity_id:20s} (exists)")
            continue
        # Ledger check — only for paid backends. Skips re-pay even
        # when the output file was moved/deleted.
        backend_name = _kind_backend(item.kind)
        p_hash = prompt_hash(item.assembled_prompt)
        if is_paid_backend(backend_name):
            hit = ledger.has(backend_name, item.kind, p_hash)
            if hit is not None:
                rec["status"] = "skipped_ledger"
                rec["ledger_timestamp"] = hit.get("timestamp", "")
                summary["skipped_ledger"] += 1
                # Re-patch to the existing output if present (idempotent —
                # same rationale as the skip_existing branch above).
                if (cfg.patch_entities and not item.intermediate
                        and item.out_path.exists() and _patch_entity_file(item)):
                    rec["patched"] = True
                    summary["patched"] += 1
                summary["items"].append(rec)
                if verbose:
                    ts = hit.get("timestamp", "?")
                    print(
                        f"  [ledg] {item.kind:7s} {item.entity_id:20s} "
                        f"(paid {backend_name} @ {ts})"
                    )
                continue
        backend = _get(item.kind)
        try:
            if item.kind in ("texture", "concept"):
                if not backend.supports_texture():
                    rec["status"] = "backend_lacks_support"
                    summary["errors"].append(rec)
                    if verbose:
                        print(
                            f"  [skip] {item.kind:7s} {item.entity_id} "
                            f"(backend can't gen textures)"
                        )
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
                        print(
                            f"  [skip] {item.kind:7s} {item.entity_id} "
                            f"(backend can't gen meshes)"
                        )
                    continue
                # Pass reference_image kwarg if the backend accepts
                # it (Tripo3D image-to-3D mode). MockBackend's signature
                # only takes (prompt, out_path); guard with try/except
                # or feature-test. Cleanest: pass kwarg only if set.
                #
                # Bug-class gate (2026-05-17): if the entity DECLARED a
                # concept reference (mesh_reference_prompt → ref path)
                # but the concept file is missing (likely because the
                # upstream concept call failed), we previously fell
                # through to text-to-3D silently. That hid upstream
                # failures + recorded a ledger entry that LOOKED like a
                # normal image-to-3D run, blocking future regen.
                # Now: skip the mesh + surface the failure. Empirical:
                # 2026-05-17 nanobanana 403 batch silently produced 12
                # text-to-3D meshes labeled as normal generations.
                ref = item.reference_image_path
                if ref is not None and not ref.exists():
                    rec["status"] = "skipped_concept_missing"
                    rec["error"] = (
                        f"declared mesh_reference_prompt but concept "
                        f"file {ref.name} missing — upstream concept "
                        f"call likely failed. Fix the concept backend "
                        f"OR remove mesh_reference_prompt to opt into "
                        f"text-to-3D."
                    )
                    summary["errors"].append(rec)
                    if verbose:
                        print(
                            f"  [skip-concept] {item.kind:7s} "
                            f"{item.entity_id} (concept missing — "
                            f"upstream backend likely failed)"
                        )
                    continue
                if ref is not None and ref.exists():
                    backend.generate_mesh(
                        item.assembled_prompt,
                        item.out_path,
                        reference_image=ref,
                    )
                else:
                    backend.generate_mesh(item.assembled_prompt, item.out_path)
            summary["generated"] += 1
            rec["status"] = "generated"
            # Record paid API calls so a later run doesn't re-pay if
            # the output file was moved/deleted. Mock stays free +
            # untracked (smoke test re-runs against it).
            if is_paid_backend(backend_name):
                try:
                    rel_out = str(item.out_path.relative_to(game_dir))
                except ValueError:
                    rel_out = str(item.out_path)
                ledger.add(
                    backend=backend_name,
                    kind=item.kind,
                    entity_id=item.entity_id,
                    prompt=item.assembled_prompt,
                    p_hash=p_hash,
                    out_path=rel_out,
                )
            if cfg.patch_entities and not item.intermediate:
                if _patch_entity_file(item):
                    summary["patched"] += 1
                    rec["patched"] = True
            summary["items"].append(rec)
            if verbose:
                tag = "gen" if not item.intermediate else "ref"
                print(
                    f"  [{tag:3s}]  {item.kind:7s} {item.entity_id:20s} → {item.out_path.name}"
                )
        except Exception as e:
            rec["status"] = "error"
            rec["error"] = str(e)
            summary["errors"].append(rec)
            if verbose:
                print(
                    f"  [err]  {item.kind:7s} {item.entity_id}: {e}",
                    file=sys.stderr,
                )

    if not dry_run:
        ledger.save()
    return summary
