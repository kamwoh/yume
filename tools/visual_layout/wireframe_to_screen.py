"""wireframe_to_screen.py — fit-fit SCREEN authoring harness (Tier 2.7v).

╔══════════════════════════════════════════════════════════════════════╗
║  STABLE — 2D fit-fit pipeline (see compose_hud.py for full banner)   ║
║  Confirmed 2026-05-24. ADR required to modify the harness.           ║
╚══════════════════════════════════════════════════════════════════════╝



Sibling of wireframe_to_hud.py for screens.json modal/full-cover UIs.
Same preprocess + postprocess pattern; broader catalog (13 element types
vs HUD's 6, including interactive button/slider/checkbox) and additional
validation (transition_screen targets must resolve, effect-chain
destructive-last rule, etc.).

Sub-commands:

    preprocess <game> <wireframe.png> <screen_id>
        Read api-manifest + scan game's screens.json for existing screen
        ids + scan entity defs for binding manifest + measure the
        wireframe + emit /tmp/_screen_author_context.json. The skill
        consumes this + the wireframe via vision.

    postprocess <game> <draft.json> [--screen-id <id>]
        Validate the authored screen against the manifest. Splice into
        the game's screens.json (replacing if id matches an existing
        screen; appending otherwise). Backs up to screens.json.bak.

Reuses tools/visual_layout/wireframe_to_hud.py for shared image-reader,
aspect math, and binding-manifest scan.

Usage:
    python3 -m tools.visual_layout.wireframe_to_screen preprocess \\
        demo_aldenmere godot/data/demo_aldenmere/assets/layouts/screen_inventory_X.png inventory
    # → writes /tmp/_screen_author_context.json
    # → LLM (yume-screen-author) reads context + wireframe, drafts /tmp/_screen_draft.json
    python3 -m tools.visual_layout.wireframe_to_screen postprocess \\
        demo_aldenmere /tmp/_screen_draft.json --screen-id inventory
    # → validates, backs up screens.json, splices.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.visual_layout.wireframe_to_hud import (  # noqa: E402
    _aspect_ratio_str,
    _image_size,
    _scan_engine_world_state_writes,
    _scan_world_singletons,
    _scan_world_state_writes,
)

MANIFEST_PATH = ROOT / "docs" / "engine-reference" / "api-manifest.json"
DEFAULT_CONTEXT_OUT = Path("/tmp/_screen_author_context.json")


# ============================================================
# Screen-id allow-list (for transition_screen target validation)
# ============================================================


def _scan_existing_screen_ids(game_dir: Path) -> list[str]:
    p = game_dir / "screens.json"
    if not p.exists():
        return []
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return []
    return [
        str(s.get("id"))
        for s in doc.get("screens", [])
        if isinstance(s, dict) and s.get("id")
    ]


# ============================================================
# Effect allow-list (for on_click chain validation)
# ============================================================


# Effects that DESTROY the current scene/state. Must be the LAST effect
# in any chain — anything queued after gets silently dropped at
# end-of-frame. See .claude/rules/engine-scripts.md § effect-chain gate.
DESTRUCTIVE_EFFECTS = {
    "transition_level",
    "reload_scene",
    "load_state",
    "quit_app",
}


def _effect_allow_list(manifest: dict) -> set[str]:
    """All effect type strings the engine accepts (from api-manifest)."""
    return {e["type"] for e in manifest.get("effects", [])}


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
        print("ERROR: viewport missing from manifest", file=sys.stderr)
        return 2

    wf_w, wf_h = _image_size(wf_path)
    vp_w, vp_h = int(viewport["width"]), int(viewport["height"])
    wf_aspect = _aspect_ratio_str(wf_w, wf_h)
    vp_aspect = viewport.get("aspect_ratio", _aspect_ratio_str(vp_w, vp_h))

    wf_ratio = wf_w / wf_h if wf_h else 0
    vp_ratio = vp_w / vp_h if vp_h else 0
    aspect_mismatch = (
        wf_ratio == 0 or vp_ratio == 0
        or abs(wf_ratio - vp_ratio) / vp_ratio > 0.02
    )

    sx = vp_w / wf_w
    sy = vp_h / wf_h

    namespaces = _scan_world_singletons(game_dir)
    world_writes = _scan_world_state_writes(game_dir) | _scan_engine_world_state_writes()

    binding_manifest: dict[str, list[str]] = {}
    for ns, fields in sorted(namespaces.items()):
        if not fields:
            continue
        binding_manifest[ns] = sorted(fields)
    if world_writes:
        binding_manifest["world"] = sorted(world_writes)

    flat: set[str] = set()
    for ns, fields in binding_manifest.items():
        for f in fields:
            flat.add(f"{ns}.{f}")

    existing_screen_ids = _scan_existing_screen_ids(game_dir)
    effect_allow = sorted(_effect_allow_list(manifest))

    context = {
        "_comment": (
            "Auto-generated by tools/visual_layout/wireframe_to_screen.py "
            "preprocess. Feeds the yume-screen-author skill. Read this + "
            "the wireframe; author a fit-fit screens.json screen entry."
        ),
        "game": args.game,
        "screen_id": args.screen_id,
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
        },
        "scale_to_viewport": {"x": round(sx, 6), "y": round(sy, 6)},
        "aspect_mismatch": aspect_mismatch,
        "screen_anchors": manifest["screen_anchors"],
        "screen_anchor_geometry": manifest["hud_anchor_geometry"],
        "screen_elements": manifest["screen_elements"],
        "screen_fields": manifest["screen_fields"],
        "interaction_events": manifest["interaction_events"],
        "existing_screen_ids": existing_screen_ids,
        "transition_targets_allow_list": (
            existing_screen_ids + ["@previous", "@root", args.screen_id]
        ),
        "effect_allow_list": effect_allow,
        "destructive_effects": sorted(DESTRUCTIVE_EFFECTS),
        "binding_manifest": binding_manifest,
        "binding_allow_list": sorted(flat),
        "binding_notes": {
            "world.X": (
                "Resolved from env.world_state. Fields listed are those "
                "written by state_set target=world OR engine-injected. If "
                "you need a field not in this list, an authoring rule "
                "must write it first."
            ),
        },
        "authoring_rules": [
            "Each element's geometry must be DERIVED from a wireframe "
            "region's bbox using screen_anchor_geometry math. Do NOT "
            "pick offsets freely.",
            "Element types MUST come from screen_elements catalog.",
            "Every `binds` value MUST appear in binding_allow_list, OR "
            "match `world.X` per binding_notes.",
            "Every `transition_screen` target MUST appear in "
            "transition_targets_allow_list. @previous (pop the modal) "
            "is the standard close-button target.",
            "EFFECT-CHAIN GATE: in any on_click/on_change/on_press chain, "
            "destructive effects (transition_level, reload_scene, "
            "load_state, quit_app) MUST be LAST. Anything after them is "
            "silently dropped. See .claude/rules/engine-scripts.md.",
            "For modals: set freeze_world=true (pauses world simulation) "
            "and background_alpha < 1.0 (dims the world underneath). "
            "Authors of inventory / pause / settings screens usually "
            "want both.",
        ],
    }

    out = Path(args.out) if args.out else DEFAULT_CONTEXT_OUT
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(context, indent=2, ensure_ascii=False) + "\n",
                   encoding="utf-8")
    print(f"[preprocess] wrote {out}")
    print(f"  screen_id: {args.screen_id}")
    print(f"  wireframe: {wf_w}x{wf_h} ({wf_aspect})")
    print(f"  viewport:  {vp_w}x{vp_h} ({vp_aspect})")
    print(f"  scale:     {sx:.4f} x  {sy:.4f}")
    if aspect_mismatch:
        print(f"  ⚠ ASPECT MISMATCH — wireframe {wf_aspect} ≠ viewport {vp_aspect}")
    print(f"  bindings:        {len(binding_manifest)} namespaces, {len(flat)} paths")
    print(f"  elements:        {len(context['screen_elements'])} catalog entries")
    print(f"  existing screens: {len(existing_screen_ids)} "
          f"({', '.join(existing_screen_ids) if existing_screen_ids else '(none)'})")
    return 0


# ============================================================
# Postprocess
# ============================================================


def _validate_draft(draft: dict, context: dict) -> list[str]:
    """Validate a single screen dict. Returns list of error strings."""
    errs: list[str] = []
    allowed_anchors = set(context["screen_anchors"])
    allowed_elements = {e["type"]: e for e in context["screen_elements"]}
    allow_paths = set(context["binding_allow_list"])
    allowed_screens = set(context["transition_targets_allow_list"])
    allowed_effects = set(context["effect_allow_list"])
    destructive = set(context["destructive_effects"])

    if not isinstance(draft, dict):
        errs.append("draft is not a dict")
        return errs

    sid = draft.get("id", "")
    if sid != context["screen_id"]:
        errs.append(
            f"draft id '{sid}' doesn't match expected '{context['screen_id']}'"
        )

    elements = draft.get("elements", [])
    if not isinstance(elements, list):
        errs.append("elements is not a list")
        return errs

    for i, el in enumerate(elements):
        _validate_element(el, f"elements[{i}]", errs, allowed_anchors,
                          allowed_elements, allow_paths, allowed_screens,
                          allowed_effects, destructive)
    return errs


def _validate_element(
    el, path: str, errs: list[str],
    allowed_anchors: set[str], allowed_elements: dict,
    allow_paths: set[str], allowed_screens: set[str],
    allowed_effects: set[str], destructive: set[str],
) -> None:
    if not isinstance(el, dict):
        errs.append(f"{path} is not a dict")
        return
    t = el.get("type", "")
    if t not in allowed_elements:
        errs.append(
            f"{path} unknown type '{t}' "
            f"(allowed: {sorted(allowed_elements)})"
        )
        return
    anchor = el.get("anchor", "")
    if anchor and anchor not in allowed_anchors:
        # Tolerate dash form (control_factory normalizes)
        if anchor.replace("-", "_") not in allowed_anchors:
            errs.append(
                f"{path} unknown anchor '{anchor}' "
                f"(allowed: {sorted(allowed_anchors)})"
            )
    # binds validation (label, progress_bar, slot_grid, etc.)
    b = el.get("binds")
    if isinstance(b, str) and b:
        if b.startswith("def.") or b.startswith("world."):
            pass
        elif b not in allow_paths:
            errs.append(
                f"{path} binds='{b}' not in binding_allow_list"
            )
    # Effect chains: on_click / on_change / on_toggle / on_submit / on_press
    for evt in ("on_click", "on_change", "on_toggle", "on_submit", "on_press"):
        chain = el.get(evt)
        if chain is None:
            continue
        if not isinstance(chain, list):
            errs.append(f"{path}.{evt} is not a list")
            continue
        _validate_chain(chain, f"{path}.{evt}", errs,
                        allowed_screens, allowed_effects, destructive)
    # Recurse into vbox/hbox children
    for child in el.get("children", []) or []:
        _validate_element(child, f"{path}.children[?]", errs,
                          allowed_anchors, allowed_elements, allow_paths,
                          allowed_screens, allowed_effects, destructive)


def _validate_chain(
    chain: list, path: str, errs: list[str],
    allowed_screens: set[str],
    allowed_effects: set[str],
    destructive: set[str],
) -> None:
    destructive_at: list[tuple[int, str]] = []
    for i, eff in enumerate(chain):
        if not isinstance(eff, dict):
            errs.append(f"{path}[{i}] not a dict")
            continue
        et = eff.get("type", "")
        if et not in allowed_effects:
            errs.append(
                f"{path}[{i}] unknown effect type '{et}'"
            )
            continue
        if et == "transition_screen":
            tgt = eff.get("target", "")
            if tgt and tgt not in allowed_screens:
                errs.append(
                    f"{path}[{i}] transition_screen target '{tgt}' not in "
                    f"existing screen ids OR @previous/@root"
                )
        if et in destructive:
            destructive_at.append((i, et))
    # Destructive-effect-last rule
    for i, et in destructive_at:
        if i < len(chain) - 1:
            errs.append(
                f"{path}[{i}] destructive effect '{et}' must be LAST in "
                f"chain — {len(chain) - 1 - i} effect(s) after it will be "
                f"silently dropped (rule: .claude/rules/engine-scripts.md "
                f"§ effect-chain gate)"
            )


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
        for e in errors:
            print(f"  ✗ {e}", file=sys.stderr)
        if not args.force:
            print(f"\n  Pass --force to apply anyway (not recommended).",
                  file=sys.stderr)
            return 1
        print(f"  (continuing because --force)", file=sys.stderr)

    target = game_dir / "screens.json"
    if not target.exists():
        print(f"ERROR: {target} not found — game must have a screens.json "
              f"to splice into", file=sys.stderr)
        return 2

    bak = game_dir / "screens.json.bak"
    bak.write_text(target.read_text(encoding="utf-8"), encoding="utf-8")
    print(f"[postprocess] backup → {bak.relative_to(ROOT)}")

    doc = json.loads(target.read_text(encoding="utf-8"))
    screens = doc.get("screens", [])
    sid = context["screen_id"]
    replaced = False
    for i, s in enumerate(screens):
        if isinstance(s, dict) and s.get("id") == sid:
            screens[i] = draft
            replaced = True
            break
    if not replaced:
        screens.append(draft)
    doc["screens"] = screens
    target.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n",
                      encoding="utf-8")
    n_elements = len(draft.get("elements", []))
    print(f"[postprocess] {'replaced' if replaced else 'appended'} screen "
          f"'{sid}' ({n_elements} elements) in {target.relative_to(ROOT)}")
    if errors and args.force:
        print(f"  ⚠ shipped with {len(errors)} validation errors")
    return 0


# ============================================================
# CLI
# ============================================================


def main() -> int:
    ap = argparse.ArgumentParser(prog="wireframe_to_screen")
    sp = ap.add_subparsers(dest="cmd", required=True)

    p1 = sp.add_parser("preprocess", help="Prepare context for the LLM author")
    p1.add_argument("game")
    p1.add_argument("wireframe")
    p1.add_argument("screen_id", help="Target screen id (e.g. 'inventory')")
    p1.add_argument("--out", help=f"Output path (default {DEFAULT_CONTEXT_OUT})")

    p2 = sp.add_parser("postprocess", help="Validate + splice a draft screen")
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
