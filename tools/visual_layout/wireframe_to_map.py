"""wireframe_to_map.py — fit-fit LEVEL/MAP authoring harness (Tier 2.7v).

Third sibling of wireframe_to_hud.py / wireframe_to_screen.py. Applies
the LLM-as-parser pattern to procedural level generation:

    prompt → gemini-3.1 (1:1 top-down semantic map)
        ↓ wireframe_to_map.py preprocess <game> <map.png> <level_id>
    /tmp/_map_author_context.json (per-game entity catalog,
                                   asset_resolution, scatter_presets,
                                   world bounds, coord transform)
        ↓ [LLM step] yume-map-author reads context + map via vision,
        ↓             writes /tmp/_map_draft.json with initial_instances
        ↓             + patterns
        ↓ wireframe_to_map.py postprocess (validates def_ids exist,
        ↓                                  positions in-bounds, patterns
        ↓                                  reference valid presets;
        ↓                                  splices into levels/<id>/
        ↓                                  entities.json with .bak)
    levels/<level_id>/entities.json with the new/replaced placements

Replaces the CV chain (extract_map + compile_map) for procedural map
generation, same way wireframe_to_hud/screen replaced their CV
predecessors. The CV scripts stay in repo unwired.

Sub-commands:

    preprocess <game> <map.png> <level_id> [--map-size SIZE]
        Emit context file at /tmp/_map_author_context.json.

    postprocess <game> <draft.json> <level_id>
        Validate + splice into data/<game>/levels/<level_id>/
        entities.json.

Usage:
    python3 -m tools.visual_layout.wireframe_to_map preprocess \\
        demo_aldenmere godot/data/demo_aldenmere/assets/layouts/X.png \\
        level_proto_village
    # → /tmp/_map_author_context.json
    # → /yume-map-author authors /tmp/_map_draft.json
    python3 -m tools.visual_layout.wireframe_to_map postprocess \\
        demo_aldenmere /tmp/_map_draft.json level_proto_village
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.visual_layout.wireframe_to_hud import _image_size  # noqa: E402

MANIFEST_PATH = ROOT / "docs" / "engine-reference" / "api-manifest.json"
DEFAULT_CONTEXT_OUT = Path("/tmp/_map_author_context.json")


# ============================================================
# Per-game scans (entity catalog, asset_resolution, scatter presets)
# ============================================================


def _scan_entity_catalog(game_dir: Path) -> list[dict]:
    """Build a richer catalog than just def_ids. Each entry:
    {def_id, tags, key_properties, mesh_kind, is_blocking}. The LLM
    needs the tag info to know e.g. 'tree' tag belongs to forest
    scatter, 'structure' tag to hand-placed anchors.
    """
    out: list[dict] = []
    ent_dir = game_dir / "entities"
    if not ent_dir.exists():
        return out
    for jf in ent_dir.rglob("*.json"):
        try:
            doc = json.loads(jf.read_text(encoding="utf-8"))
        except Exception:
            continue
        for d in doc.get("definitions", []):
            if not (isinstance(d, dict) and d.get("id")):
                continue
            did = str(d["id"])
            tags = [str(t) for t in d.get("tags", []) if not str(t).startswith("_")]
            props = d.get("properties", {}) or {}
            blocking = "blocks_motion" in tags
            entry = {"def_id": did, "tags": tags, "is_blocking": blocking}
            visual = d.get("visual", {}) or {}
            if "mesh" in visual:
                entry["mesh"] = str(visual.get("mesh"))[:60]
            if "color" in visual:
                entry["color"] = str(visual.get("color"))
            if "y_offset" in visual:
                entry["y_offset"] = visual["y_offset"]
            out.append(entry)
    return sorted(out, key=lambda e: e["def_id"])


def _load_asset_resolution(game_dir: Path) -> dict:
    p = game_dir / "visual_layout" / "asset_resolution.json"
    if not p.exists():
        return {"anchors": {}, "zones": {}}
    return json.loads(p.read_text(encoding="utf-8"))


def _load_scatter_presets() -> dict:
    p = ROOT / "tools" / "visual_layout" / "legends" / "scatter_presets.json"
    if not p.exists():
        return {}
    return json.loads(p.read_text(encoding="utf-8")).get("presets", {})


def _world_bounds(game_dir: Path) -> dict:
    """Read scene.json for ground.mesh.size; fall back to 160x160m."""
    sf = game_dir / "scene.json"
    if not sf.exists():
        return {"width": 160.0, "depth": 160.0, "source": "default"}
    try:
        doc = json.loads(sf.read_text(encoding="utf-8"))
    except Exception:
        return {"width": 160.0, "depth": 160.0, "source": "default (parse fail)"}
    g = doc.get("ground", {}) or {}
    sz = (g.get("mesh", {}) or {}).get("size")
    if isinstance(sz, list) and len(sz) >= 2:
        return {
            "width": float(sz[0]),
            "depth": float(sz[1]),
            "source": "scene.json:ground.mesh.size",
        }
    return {"width": 160.0, "depth": 160.0, "source": "default"}


def _hex_to_color_rgba(h: str) -> list[float]:
    """Convert '#RRGGBB' or '#RRGGBBAA' to [r, g, b, a] 0..1 floats.
    Used to produce the shader uniform value for a biome's reference
    color (ADR 0055)."""
    s = h.lstrip("#")
    if len(s) == 6:
        s = s + "ff"
    if len(s) != 8:
        return [0.5, 0.5, 0.5, 1.0]
    try:
        return [
            int(s[0:2], 16) / 255.0,
            int(s[2:4], 16) / 255.0,
            int(s[4:6], 16) / 255.0,
            int(s[6:8], 16) / 255.0,
        ]
    except ValueError:
        return [0.5, 0.5, 0.5, 1.0]


def _existing_instances(game_dir: Path, level_id: str) -> list[dict]:
    """If the level already has an entities.json, return a SUMMARY of
    its placements — informational only, NOT to be preserved."""
    f = game_dir / "levels" / level_id / "entities.json"
    if not f.exists():
        return []
    try:
        doc = json.loads(f.read_text(encoding="utf-8"))
    except Exception:
        return []
    inst = doc.get("initial_instances", []) or []
    pats = doc.get("patterns", []) or []
    summary: list[dict] = []
    for i in inst[:30]:  # cap to keep context small
        summary.append({
            "kind": "anchor",
            "def": i.get("def"),
            "id": i.get("id"),
            "position": i.get("position", []),
        })
    for p in pats[:10]:
        summary.append({
            "kind": "pattern",
            "def": p.get("def"),
            "pattern": p.get("pattern"),
            "count": p.get("count"),
        })
    return summary


# ============================================================
# Preprocess
# ============================================================


def cmd_preprocess(args) -> int:
    game_dir = ROOT / "godot" / "data" / args.game
    map_path = Path(args.map)
    if not map_path.is_absolute():
        map_path = (ROOT / map_path).resolve()

    if not game_dir.exists():
        print(f"ERROR: game dir not found: {game_dir}", file=sys.stderr)
        return 2
    if not map_path.exists():
        print(f"ERROR: map not found: {map_path}", file=sys.stderr)
        return 2
    if not MANIFEST_PATH.exists():
        print(f"ERROR: api-manifest.json missing — run "
              f"tools/gen_api_manifest.py first", file=sys.stderr)
        return 2

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    img_w, img_h = _image_size(map_path)
    bounds = _world_bounds(game_dir)
    # Per-axis scale: image pixels → world units. +X east (image right),
    # +Z south (image down). map center → world origin (0,0,0).
    scale_x = bounds["width"] / img_w
    scale_z = bounds["depth"] / img_h

    catalog = _scan_entity_catalog(game_dir)
    asset_res = _load_asset_resolution(game_dir)
    presets = _load_scatter_presets()
    existing_summary = _existing_instances(game_dir, args.level_id)

    # Build a quick anchor-name → def hint table from asset_resolution
    anchor_hints: dict = {}
    for name, cfg in asset_res.get("anchors", {}).items():
        if isinstance(cfg, dict) and cfg.get("primary"):
            anchor_hints[name] = {
                "def": cfg["primary"],
                "count_policy": cfg.get("count_policy", "single"),
                "scale_min": cfg.get("scale_min"),
                "scale_max": cfg.get("scale_max"),
                "yaw_jitter": cfg.get("yaw_jitter"),
            }
    zone_hints: dict = {}
    for name, cfg in asset_res.get("zones", {}).items():
        if isinstance(cfg, dict) and cfg.get("primary"):
            zone_hints[name] = {
                "def": cfg["primary"],
                "preset": cfg.get("preset"),
            }
    # ADR 0055: biome catalog for multi-biome ground composition.
    # Each entry maps a semantic-map color to (hex, albedo path,
    # shader uniform key). The skill uses this to write the
    # `levels/<id>/scene.json` sparse override.
    biome_config: dict = {}
    for name, cfg in asset_res.get("biomes", {}).items():
        if name.startswith("_"):
            continue
        if isinstance(cfg, dict) and cfg.get("hex"):
            biome_config[name] = {
                "hex": cfg["hex"],
                "albedo": cfg.get("albedo", ""),
                "engine_key": cfg.get("engine_key", f"biome_color_{name}"),
                "color_uniform": _hex_to_color_rgba(cfg["hex"]),
            }

    context = {
        "_comment": (
            "Auto-generated by tools/visual_layout/wireframe_to_map.py "
            "preprocess. Feeds the yume-map-author skill. Read this + "
            "the semantic map; author a fit-fit level entities.json."
        ),
        "game": args.game,
        "level_id": args.level_id,
        "map": {
            "path": str(map_path.relative_to(ROOT)) if map_path.is_relative_to(ROOT) else str(map_path),
            "width": img_w,
            "height": img_h,
        },
        "world_bounds": bounds,
        "coord_transform": {
            "scale_x_per_px": round(scale_x, 6),
            "scale_z_per_px": round(scale_z, 6),
            "formula": (
                "wx = (px_x - image.width/2)  * scale_x_per_px; "
                "wz = (px_y - image.height/2) * scale_z_per_px; "
                "wy = 0.0  (floor-anchored entities)"
            ),
            "_doc": (
                "Map center (px_x = image.width/2, px_y = image.height/2) "
                "maps to world origin (0, 0, 0). +X east (image right), "
                "+Z south (image down)."
            ),
        },
        "map_authoring_concepts": manifest.get("map_authoring_concepts", {}),
        "entity_catalog": catalog,
        "anchor_hints": anchor_hints,
        "zone_hints": zone_hints,
        "scatter_presets": presets,
        "biome_config": biome_config,
        "biome_shader_path": "res://data/lib/shaders/ground_5biome.gdshader",
        "existing_level_summary": existing_summary,
        "authoring_rules": [
            "Every emitted `def` (in initial_instances or patterns) "
            "MUST appear in entity_catalog. If you can't find a def "
            "for what the map shows, emit nothing for that region "
            "and flag in the report — do NOT invent def_ids.",
            "Use anchor_hints + zone_hints from asset_resolution.json "
            "as the PREFERRED mapping (e.g. 'fire_pit' name → "
            "'structure_fire_pit' def). If the map shows something "
            "outside those hints, pick the closest match from "
            "entity_catalog using tags as the matching signal.",
            "Compute world positions DETERMINISTICALLY via "
            "coord_transform.formula. Do NOT pick coordinates by "
            "intuition. Round to 1 decimal.",
            "Every position MUST be inside world_bounds — i.e. "
            "|wx| <= bounds.width/2 and |wz| <= bounds.depth/2.",
            "For ZONE regions: pick a scatter_preset by name (from "
            "scatter_presets), compute count = floor(area_m2 * "
            "density_per_m2), respect max_count cap (default 200).",
            "Existing_level_summary is INFORMATIONAL only — it shows "
            "what was at this level_id before. Your output REPLACES "
            "the level; if the user wants to preserve specific "
            "anchors, they'll re-roll with --edit.",
            "BIOMES (ADR 0055): if biome_config is non-empty, emit a "
            "`_scene_patch` block in the draft (alongside "
            "initial_instances / patterns) containing the "
            "shader_params for ground.mesh. Use biome_shader_path as "
            "the `shader` field. For each biome in biome_config, set "
            "two uniforms: biome_color_<name> (= color_uniform list) "
            "and albedo_<name> (= albedo path string). Unused biome "
            "slots (e.g. game has no `water` biome) should re-point "
            "their albedo at the `dirt` albedo so the math still "
            "blends correctly. Postprocess writes the patch to "
            "levels/<level_id>/scene.json (sparse override).",
        ],
    }

    out = Path(args.out) if args.out else DEFAULT_CONTEXT_OUT
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(context, indent=2, ensure_ascii=False) + "\n",
                   encoding="utf-8")
    print(f"[preprocess] wrote {out}")
    print(f"  level_id:    {args.level_id}")
    print(f"  map:         {img_w}x{img_h}")
    print(f"  world:       {bounds['width']:.0f}x{bounds['depth']:.0f}m  "
          f"(source: {bounds['source']})")
    print(f"  scale:       {scale_x:.4f}m/px x  {scale_z:.4f}m/px")
    print(f"  catalog:     {len(catalog)} entity defs")
    print(f"  anchor hints: {len(anchor_hints)} ({', '.join(sorted(anchor_hints)) or '(none)'})")
    print(f"  zone hints:   {len(zone_hints)} ({', '.join(sorted(zone_hints)) or '(none)'})")
    print(f"  scatter presets: {len(presets)}")
    print(f"  biomes:      {len(biome_config)} ({', '.join(sorted(biome_config)) or '(none)'})")
    print(f"  existing:    {len(existing_summary)} placements (informational only)")
    return 0


# ============================================================
# Postprocess (validation + splice)
# ============================================================


def _validate_draft(draft: dict, context: dict) -> list[str]:
    errs: list[str] = []
    allowed_defs = {e["def_id"] for e in context.get("entity_catalog", [])}
    bounds = context["world_bounds"]
    half_w = bounds["width"] / 2
    half_d = bounds["depth"] / 2
    presets = context.get("scatter_presets", {})

    inst = draft.get("initial_instances", []) or []
    if not isinstance(inst, list):
        errs.append("initial_instances is not a list")
        return errs
    seen_ids: set[str] = set()
    for i, e in enumerate(inst):
        if not isinstance(e, dict):
            errs.append(f"initial_instances[{i}] not a dict")
            continue
        d = e.get("def", "")
        if d not in allowed_defs:
            errs.append(
                f"initial_instances[{i}] def='{d}' not in entity_catalog"
            )
            continue
        iid = e.get("id", "")
        if not iid:
            errs.append(f"initial_instances[{i}] missing 'id'")
        elif iid in seen_ids:
            errs.append(f"initial_instances[{i}] duplicate id '{iid}'")
        else:
            seen_ids.add(iid)
        pos = e.get("position")
        if not (isinstance(pos, list) and len(pos) >= 2):
            errs.append(f"initial_instances[{i}] missing/invalid position")
            continue
        wx = float(pos[0])
        wz = float(pos[2]) if len(pos) >= 3 else float(pos[1])
        if abs(wx) > half_w + 0.5 or abs(wz) > half_d + 0.5:
            errs.append(
                f"initial_instances[{i}] id='{iid}' pos=({wx:.1f}, _, "
                f"{wz:.1f}) outside bounds ±({half_w:.1f}, ±{half_d:.1f})"
            )

    pats = draft.get("patterns", []) or []
    if not isinstance(pats, list):
        errs.append("patterns is not a list")
        return errs
    for i, p in enumerate(pats):
        if not isinstance(p, dict):
            errs.append(f"patterns[{i}] not a dict")
            continue
        d = p.get("def", "")
        if d not in allowed_defs:
            errs.append(
                f"patterns[{i}] def='{d}' not in entity_catalog"
            )
        kind = p.get("pattern", "")
        if kind != "scatter":
            errs.append(
                f"patterns[{i}] pattern='{kind}' — only 'scatter' "
                f"supported in this harness today"
            )
        count = p.get("count", 0)
        if not isinstance(count, int) or count < 1:
            errs.append(f"patterns[{i}] invalid count {count}")
        if count and count > 500:
            errs.append(
                f"patterns[{i}] count={count} > 500 cap — split into "
                f"multiple patterns or use a sparser scatter_preset"
            )
        # min_r / max_r REQUIRED on any scatter with count > 10. Without
        # them engine defaults to min_r=0, max_r=5 — physically can't
        # pack many entities in a 5m disk with min_spacing≥1m. Empirical
        # case 2026-05-20: yume-map-author shipped a 200-tree forest
        # without min_r/max_r; engine silently spawned only ~30 trees
        # in a 5m disk before exhausting placement attempts.
        min_r = p.get("min_r")
        max_r = p.get("max_r")
        if count > 10 and (min_r is None or max_r is None):
            errs.append(
                f"patterns[{i}] count={count} requires both min_r AND "
                f"max_r (annulus bounds in world units) — engine "
                f"default 0..5m can't pack >~30 entities. Pick min_r "
                f"to start outside any inner clearing, max_r inside "
                f"world bounds."
            )
        if min_r is not None and max_r is not None:
            try:
                mn = float(min_r)
                mx = float(max_r)
                half_w = bounds["width"] / 2
                half_d = bounds["depth"] / 2
                world_max_r = min(half_w, half_d)
                if mn < 0:
                    errs.append(f"patterns[{i}] min_r={mn} < 0")
                if mx <= mn:
                    errs.append(f"patterns[{i}] max_r={mx} <= min_r={mn}")
                if mx > world_max_r + 0.5:
                    errs.append(
                        f"patterns[{i}] max_r={mx} > world half-extent "
                        f"{world_max_r:.1f} — scatter would spawn outside bounds"
                    )
            except (TypeError, ValueError):
                errs.append(f"patterns[{i}] min_r/max_r not numeric")
    return errs


def cmd_postprocess(args) -> int:
    game_dir = ROOT / "godot" / "data" / args.game
    draft_path = Path(args.draft)
    if not draft_path.is_absolute():
        draft_path = (ROOT / draft_path).resolve()
    ctx_path = Path(args.context) if args.context else DEFAULT_CONTEXT_OUT

    if not draft_path.exists():
        print(f"ERROR: draft not found: {draft_path}", file=sys.stderr)
        return 2
    if not ctx_path.exists():
        print(f"ERROR: context not found: {ctx_path}", file=sys.stderr)
        return 2
    if not game_dir.exists():
        print(f"ERROR: game dir not found: {game_dir}", file=sys.stderr)
        return 2

    draft = json.loads(draft_path.read_text(encoding="utf-8"))
    context = json.loads(ctx_path.read_text(encoding="utf-8"))

    errors = _validate_draft(draft, context)
    if errors:
        print(f"[postprocess] VALIDATION FAILED ({len(errors)} errors):",
              file=sys.stderr)
        for e in errors[:20]:
            print(f"  ✗ {e}", file=sys.stderr)
        if len(errors) > 20:
            print(f"  (and {len(errors) - 20} more)", file=sys.stderr)
        if not args.force:
            print(f"\n  Pass --force to apply anyway (not recommended).",
                  file=sys.stderr)
            return 1
        print(f"  (continuing because --force)", file=sys.stderr)

    level_id = context["level_id"]
    target_dir = game_dir / "levels" / level_id
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / "entities.json"

    if target.exists():
        bak = target.with_suffix(".json.bak")
        bak.write_text(target.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"[postprocess] backup → {bak.relative_to(ROOT)}")

    # Merge with anything in the draft, but the draft IS the new content
    # (this REPLACES the level; that's the wireframe-is-spec semantic).
    out = {
        "_comment": draft.get("_comment", (
            "Authored by yume-map-author via wireframe_to_map.py "
            "postprocess. Replaces prior level entities."
        )),
        "initial_instances": draft.get("initial_instances", []),
        "initial_relations": draft.get("initial_relations", []),
        "patterns": draft.get("patterns", []),
    }
    target.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n",
                      encoding="utf-8")

    n_inst = len(out["initial_instances"])
    n_pats = len(out["patterns"])
    print(f"[postprocess] wrote {target.relative_to(ROOT)}  "
          f"({n_inst} instances + {n_pats} patterns)")

    # ADR 0055: optional `_scene_patch` block from the LLM author.
    # Sparse override for ground.mesh.shader_params (typically just
    # biome_map pointing at THIS level's semantic map). Written to
    # levels/<level_id>/scene.json — picked up by the engine via
    # GroundRenderer.rebind_shader_params() at transition_level.
    scene_patch = draft.get("_scene_patch")
    if isinstance(scene_patch, dict) and scene_patch:
        scene_target = target_dir / "scene.json"
        if scene_target.exists():
            sb = scene_target.with_suffix(".json.bak")
            sb.write_text(scene_target.read_text(encoding="utf-8"),
                          encoding="utf-8")
            print(f"[postprocess] backup → {sb.relative_to(ROOT)}")
        scene_target.write_text(
            json.dumps(scene_patch, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        n_params = len(
            scene_patch.get("ground", {})
            .get("mesh", {})
            .get("shader_params", {})
        )
        print(f"[postprocess] wrote {scene_target.relative_to(ROOT)}  "
              f"({n_params} shader_params overrides)")

    if errors and args.force:
        print(f"  ⚠ shipped with {len(errors)} validation errors")
    return 0


# ============================================================
# CLI
# ============================================================


def main() -> int:
    ap = argparse.ArgumentParser(prog="wireframe_to_map")
    sp = ap.add_subparsers(dest="cmd", required=True)

    p1 = sp.add_parser("preprocess", help="Prepare context for the LLM author")
    p1.add_argument("game")
    p1.add_argument("map", help="Path to the semantic map PNG")
    p1.add_argument("level_id", help="Target level id (e.g. 'level_proto_village')")
    p1.add_argument("--out", help=f"Output path (default {DEFAULT_CONTEXT_OUT})")

    p2 = sp.add_parser("postprocess", help="Validate + splice a draft level")
    p2.add_argument("game")
    p2.add_argument("draft")
    p2.add_argument("--context", help="Path to context JSON from preprocess")
    p2.add_argument("--force", action="store_true",
                    help="Apply even if validation fails")

    args = ap.parse_args()
    if args.cmd == "preprocess":
        return cmd_preprocess(args)
    if args.cmd == "postprocess":
        return cmd_postprocess(args)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
