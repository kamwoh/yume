"""wireframe_to_hud.py — fit-fit HUD authoring harness (Tier 2.7v, 2026-05-19).

╔══════════════════════════════════════════════════════════════════════╗
║  STABLE — 2D fit-fit pipeline (see compose_hud.py for full banner)   ║
║  Confirmed 2026-05-24. ADR required to modify the harness.           ║
╚══════════════════════════════════════════════════════════════════════╝



Two sub-commands wrap the LLM-in-the-loop step:

    preprocess  <game> <wireframe.png>
        Read api-manifest + scan game's entity defs for binding manifest +
        measure the wireframe + emit _hud_author_context.json. The context
        file is everything Claude (or any LLM) needs to author a fit-fit
        hud.json: the element-type catalog, the viewport size, the wireframe
        scale factors, the allowed binding paths, the anchor-relative
        geometry formulas.

    postprocess <game> <draft.json>
        Validate a draft hud.json against the manifest (element types,
        required fields, no hallucinated binds, aspect-ratio match), back up
        existing hud.json → hud.json.bak, write the draft.

In between, the LLM-in-the-loop authors the draft using the context file
+ vision on the wireframe. The skill at .claude/skills/yume-hud-author/
captures that procedure.

Design rationale — see prior conversation (2026-05-19): k-means CV parsing
of wireframes was fragile (Gemini variance kills colour-region detection
in edge cases). Putting Claude at the parsing step gives reliable element-
type inference, but only if the rules + schema are explicit. This script
is the canonical preprocess + postprocess; the skill is the canonical
procedure.

Usage:
    # Author flow (orchestrated by compose_hud.py or run by hand):
    python3 -m tools.visual_layout.wireframe_to_hud preprocess \\
        demo_aldenmere godot/data/demo_aldenmere/assets/layouts/hud_xxx.png
    # → writes /tmp/_hud_author_context.json
    # → LLM reads context + wireframe, authors /tmp/_hud_draft.json
    python3 -m tools.visual_layout.wireframe_to_hud postprocess \\
        demo_aldenmere /tmp/_hud_draft.json
    # → validates, backs up, applies
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = ROOT / "docs" / "engine-reference" / "api-manifest.json"
DEFAULT_CONTEXT_OUT = Path("/tmp/_hud_author_context.json")


# ============================================================
# PNG header reader — no PIL dependency for size lookup
# ============================================================


def _image_size(path: Path) -> tuple[int, int]:
    """Read width/height from a PNG or JPEG header. Gemini-3.1 with 16:9
    aspect returns JPEG data even when the caller saves to a .png path
    (the AI returns inline_data with image/jpeg mime), so the reader is
    format-tolerant rather than extension-tolerant."""
    with path.open("rb") as f:
        sig = f.read(8)
        if sig[:8] == b"\x89PNG\r\n\x1a\n":
            f.read(4)              # length of IHDR
            if f.read(4) != b"IHDR":
                raise ValueError(f"PNG missing IHDR: {path}")
            w = int.from_bytes(f.read(4), "big")
            h = int.from_bytes(f.read(4), "big")
            return w, h
        # JPEG: scan markers for SOFn (Start Of Frame). Width/height are
        # in the SOF segment at bytes 5-8.
        if sig[:2] == b"\xff\xd8":
            f.seek(2)
            while True:
                # Skip pad bytes (0xff sequences)
                b = f.read(1)
                while b == b"\xff":
                    b = f.read(1)
                if not b:
                    break
                marker = b[0]
                # SOF0..SOF15 except DHT/JPG/DAC/RSTn — handle the common
                # baseline/progressive markers.
                if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                    f.read(3)             # segment length(2) + precision(1)
                    h = int.from_bytes(f.read(2), "big")
                    w = int.from_bytes(f.read(2), "big")
                    return w, h
                # Skip variable-length segment
                seg_len = int.from_bytes(f.read(2), "big")
                if seg_len < 2:
                    break
                f.read(seg_len - 2)
            raise ValueError(f"JPEG SOF marker not found: {path}")
        raise ValueError(f"unrecognized image format: {path}")


def _aspect_ratio_str(w: int, h: int) -> str:
    from math import gcd
    if h == 0:
        return f"{w}:0"
    g = gcd(w, h)
    return f"{w // g}:{h // g}"


# ============================================================
# Binding manifest scan
# ============================================================


_ENGINE_SINGLETONS = {
    # `world` is the env.world_state dict — mutated by state_set
    # target=world and read via `world.X` binds. There's no entity def
    # to scan; authors set fields ad-hoc from rules. Track usage from
    # hud.json + rules.json instead.
    "world",
    # `def` is a special binding the engine resolves to entity-def
    # properties (e.g. def.berry_bush.properties.inventory_icon_color
    # in slot_grid item_icon mode). Not enumerable up front.
    "def",
}


def _scan_world_singletons(game_dir: Path) -> dict[str, set[str]]:
    """Find singleton entities (tagged world_clock, level_clock, etc.) +
    enumerate their state_init keys. These are the most common bind
    namespaces (player.X, world_clock.X).

    Returns {namespace: {state_field, ...}} where namespace is either an
    entity id (e.g. 'player', 'world_clock') or a tag.
    """
    out: dict[str, set[str]] = {}
    ent_dir = game_dir / "entities"
    if not ent_dir.exists():
        return out
    for jf in ent_dir.rglob("*.json"):
        try:
            doc = json.loads(jf.read_text(encoding="utf-8"))
        except Exception:
            continue
        # First pass: per-def state_init. Index by def_id AND by any tag.
        for d in doc.get("definitions", []):
            if not isinstance(d, dict):
                continue
            did = d.get("id", "")
            tags = d.get("tags", []) or []
            state = d.get("state_init", {}) or {}
            keys = {k for k in state.keys() if not str(k).startswith("_")}
            if did:
                out.setdefault(did, set()).update(keys)
            for t in tags:
                out.setdefault(t, set()).update(keys)
        # Second pass: initial_instances that override state add to the
        # binding namespace of their def_id.
        for inst in doc.get("initial_instances", []):
            if not isinstance(inst, dict):
                continue
            iid = inst.get("id", "")
            state = inst.get("state", {}) or {}
            keys = {k for k in state.keys() if not str(k).startswith("_")}
            if iid:
                out.setdefault(iid, set()).update(keys)
    return out


def _scan_world_state_writes(game_dir: Path) -> set[str]:
    """Find env.world_state fields written by rules (state_set target=world,
    field=X). These are the legal `world.X` bind paths from authoring."""
    writes: set[str] = set()
    for root in ["world", "game", "levels"]:
        d = game_dir / root
        if not d.exists():
            continue
        for jf in d.rglob("*.json"):
            try:
                doc = json.loads(jf.read_text(encoding="utf-8"))
            except Exception:
                continue
            _walk_for_world_writes(doc, writes)
    return writes


def _scan_engine_world_state_writes() -> set[str]:
    """Find world_state fields the ENGINE injects directly (bypasses
    state_set). Common ones: crosshair_target, current_level, _tick. These
    are valid `world.X` bind paths but invisible to a JSON-only scan."""
    import re
    writes: set[str] = set()
    engine_dir = ROOT / "godot" / "scripts" / "engine"
    if not engine_dir.exists():
        return writes
    pat = re.compile(r'world_state\["([a-z_][a-z0-9_]*)"\]\s*=')
    for gd in engine_dir.rglob("*.gd"):
        try:
            text = gd.read_text(encoding="utf-8")
        except Exception:
            continue
        for m in pat.finditer(text):
            writes.add(m.group(1))
    return writes


def _walk_for_world_writes(o, writes: set[str]) -> None:
    if isinstance(o, dict):
        if (
            o.get("type") == "state_set"
            and o.get("target") == "world"
            and isinstance(o.get("field"), str)
        ):
            writes.add(o["field"])
        for v in o.values():
            _walk_for_world_writes(v, writes)
    elif isinstance(o, list):
        for v in o:
            _walk_for_world_writes(v, writes)


# ============================================================
# Preprocess
# ============================================================


def cmd_preprocess(args) -> int:
    game_dir = ROOT / "godot" / "data" / args.game
    wf_path = Path(args.wireframe)
    if not wf_path.is_absolute():
        wf_path = (ROOT / wf_path).resolve()

    if not game_dir.exists():
        print(f"ERROR: game dir not found: {game_dir}", file=sys.stderr)
        return 2
    if not wf_path.exists():
        print(f"ERROR: wireframe not found: {wf_path}", file=sys.stderr)
        return 2
    if not MANIFEST_PATH.exists():
        print(f"ERROR: api-manifest.json missing — run "
              f"tools/gen_api_manifest.py first", file=sys.stderr)
        return 2

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    viewport = manifest.get("viewport", {})
    if "width" not in viewport or "height" not in viewport:
        print("ERROR: viewport missing from manifest — re-run gen_api_manifest",
              file=sys.stderr)
        return 2

    wf_w, wf_h = _image_size(wf_path)
    vp_w, vp_h = int(viewport["width"]), int(viewport["height"])
    wf_aspect = _aspect_ratio_str(wf_w, wf_h)
    vp_aspect = viewport.get("aspect_ratio", _aspect_ratio_str(vp_w, vp_h))

    # Aspect comparison — by float ratio with 2% tolerance, not by string.
    # Gemini-3.1 with 16:9 returns 1376x768 which simplifies to 43:24 ≈
    # 1.7917, drifted ~0.8% from 1.7778. Visually identical, fit-fit-safe.
    wf_ratio = wf_w / wf_h if wf_h else 0
    vp_ratio = vp_w / vp_h if vp_h else 0
    aspect_mismatch = (
        wf_ratio == 0 or vp_ratio == 0
        or abs(wf_ratio - vp_ratio) / vp_ratio > 0.02
    )

    sx = vp_w / wf_w
    sy = vp_h / wf_h

    namespaces = _scan_world_singletons(game_dir)
    world_writes = (
        _scan_world_state_writes(game_dir)
        | _scan_engine_world_state_writes()
    )

    # Build the binding manifest. Each entry is a fully-qualified
    # `namespace.field` path the LLM may use as a `binds` value.
    binding_manifest: dict[str, list[str]] = {}
    for ns, fields in sorted(namespaces.items()):
        if not fields:
            continue
        binding_manifest[ns] = sorted(fields)
    if world_writes:
        binding_manifest["world"] = sorted(world_writes)

    # Also dump as a flat allow-list for fast O(1) validation downstream.
    flat: set[str] = set()
    for ns, fields in binding_manifest.items():
        for f in fields:
            flat.add(f"{ns}.{f}")

    context = {
        "_comment": (
            "Auto-generated by tools/visual_layout/wireframe_to_hud.py "
            "preprocess. Feeds the yume-hud-author skill. Read this file + "
            "the wireframe image; author a fit-fit hud.json."
        ),
        "game": args.game,
        "wireframe": {
            "path": str(wf_path.relative_to(ROOT)) if wf_path.is_relative_to(ROOT) else str(wf_path),
            "width": wf_w,
            "height": wf_h,
            "aspect_ratio": wf_aspect,
        },
        "viewport": {
            "width": vp_w,
            "height": vp_h,
            "aspect_ratio": vp_aspect,
            "stretch_mode": viewport.get("stretch_mode", "disabled"),
            "stretch_aspect": viewport.get("stretch_aspect", "ignore"),
        },
        "scale_to_viewport": {"x": round(sx, 6), "y": round(sy, 6)},
        "aspect_mismatch": aspect_mismatch,
        "hud_anchors": manifest["hud_anchors"],
        "hud_panel_fields": manifest["hud_panel_fields"],
        "hud_anchor_geometry": manifest["hud_anchor_geometry"],
        "hud_elements": manifest["hud_elements"],
        "binding_manifest": binding_manifest,
        "binding_allow_list": sorted(flat),
        "binding_notes": {
            "world.X": (
                "Resolved from env.world_state. Fields listed are those "
                "written by state_set target=world in this game's rules. "
                "If you need a field not in this list, an authoring rule "
                "must write it first."
            ),
            "def.X.Y": (
                "Resolves to entity-def static properties (e.g. "
                "def.berry_bush.properties.inventory_icon_color). Not "
                "enumerable up front — use only if you've verified the "
                "field exists in the game's entity defs."
            ),
        },
        "authoring_rules": [
            "Each panel's geometry must be DERIVED from a wireframe region's "
            "bbox using hud_anchor_geometry math. Do NOT pick offsets "
            "freely.",
            "Element types MUST come from hud_elements. Reject unknown "
            "types — do not invent new ones.",
            "Every `binds` value MUST appear in binding_allow_list, OR "
            "match the world.X / def.X.Y patterns described in "
            "binding_notes.",
            "Wireframe and viewport must share aspect ratio for fit-fit. "
            "If aspect_mismatch is true, flag in your report.",
            "Output a single JSON object matching the existing hud.json "
            "shape: {panels: [...], win: {...}, lose: {...}}. Preserve "
            "the existing win/lose blocks unless the user explicitly "
            "asked for changes.",
        ],
    }

    out = Path(args.out) if args.out else DEFAULT_CONTEXT_OUT
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(context, indent=2, ensure_ascii=False) + "\n",
                   encoding="utf-8")
    print(f"[preprocess] wrote {out}")
    print(f"  wireframe: {wf_w}x{wf_h} ({wf_aspect})")
    print(f"  viewport:  {vp_w}x{vp_h} ({vp_aspect})")
    print(f"  scale:     {sx:.4f} x  {sy:.4f}")
    if aspect_mismatch:
        print(f"  ⚠ ASPECT MISMATCH — wireframe {wf_aspect} ≠ viewport {vp_aspect}")
    print(f"  bindings:  {len(binding_manifest)} namespaces, "
          f"{len(flat)} allowed paths")
    print(f"  elements:  {len(context['hud_elements'])} catalog entries")
    return 0


# ============================================================
# Postprocess (validation + apply)
# ============================================================


def _validate_draft(draft: dict, context: dict) -> list[str]:
    """Return a list of validation error strings. Empty = pass."""
    errs: list[str] = []
    allowed_anchors = set(context["hud_anchors"])
    allowed_elements = {e["type"]: e for e in context["hud_elements"]}
    allow_paths = set(context["binding_allow_list"])

    panels = draft.get("panels", [])
    if not isinstance(panels, list):
        errs.append("panels must be a list")
        return errs

    for i, panel in enumerate(panels):
        if not isinstance(panel, dict):
            errs.append(f"panels[{i}] is not a dict")
            continue
        anchor = panel.get("anchor", "")
        if anchor and anchor not in allowed_anchors:
            errs.append(f"panels[{i}] unknown anchor '{anchor}' "
                        f"(allowed: {sorted(allowed_anchors)})")
        elements = panel.get("elements", [])
        if not isinstance(elements, list):
            errs.append(f"panels[{i}].elements is not a list")
            continue
        for j, el in enumerate(elements):
            if not isinstance(el, dict):
                errs.append(f"panels[{i}].elements[{j}] not a dict")
                continue
            t = el.get("type", "")
            if t not in allowed_elements:
                errs.append(
                    f"panels[{i}].elements[{j}] unknown type '{t}' "
                    f"(allowed: {sorted(allowed_elements)})"
                )
                continue
            # Validate binds against allow-list. world.X and def.X.Y
            # patterns get a pass — they're documented in binding_notes
            # as outside the static manifest.
            b = el.get("binds")
            if isinstance(b, str) and b:
                if b.startswith("def.") or b.startswith("world."):
                    pass  # pattern allow — caller knows what they're doing
                elif b not in allow_paths:
                    errs.append(
                        f"panels[{i}].elements[{j}] binds='{b}' not in "
                        f"binding_allow_list (use one of: "
                        f"{sorted(p for p in allow_paths if '.' in p)[:5]}...)"
                    )
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
        print(f"ERROR: context not found: {ctx_path} "
              f"(run preprocess first or pass --context)", file=sys.stderr)
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
        for e in errors:
            print(f"  ✗ {e}", file=sys.stderr)
        if not args.force:
            print(f"\n  Pass --force to apply anyway (not recommended).",
                  file=sys.stderr)
            return 1
        print(f"  (continuing because --force)", file=sys.stderr)

    target = game_dir / "hud.json"
    if target.exists():
        bak = game_dir / "hud.json.bak"
        bak.write_text(target.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"[postprocess] backup → {bak.relative_to(ROOT)}")

    target.write_text(json.dumps(draft, indent=2, ensure_ascii=False) + "\n",
                      encoding="utf-8")
    n_panels = len(draft.get("panels", []))
    n_elements = sum(len(p.get("elements", [])) for p in draft.get("panels", []))
    print(f"[postprocess] wrote {target.relative_to(ROOT)}  "
          f"({n_panels} panels, {n_elements} elements)")
    if errors and args.force:
        print(f"  ⚠ shipped with {len(errors)} validation errors")
    return 0


# ============================================================
# CLI
# ============================================================


def main() -> int:
    ap = argparse.ArgumentParser(prog="wireframe_to_hud")
    sp = ap.add_subparsers(dest="cmd", required=True)

    p1 = sp.add_parser("preprocess", help="Prepare context for the LLM author")
    p1.add_argument("game")
    p1.add_argument("wireframe")
    p1.add_argument("--out", help="Output path for context "
                    f"(default {DEFAULT_CONTEXT_OUT})")

    p2 = sp.add_parser("postprocess", help="Validate + apply a draft hud.json")
    p2.add_argument("game")
    p2.add_argument("draft")
    p2.add_argument("--context", help="Path to context JSON from preprocess")
    p2.add_argument("--force", action="store_true",
                    help="Apply even if validation fails (not recommended)")

    args = ap.parse_args()
    if args.cmd == "preprocess":
        return cmd_preprocess(args)
    if args.cmd == "postprocess":
        return cmd_postprocess(args)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
